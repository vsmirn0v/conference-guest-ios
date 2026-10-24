import Foundation
import CoreVideo
import WebRTC
import Darwin
#if os(iOS)
import UIKit
#endif

enum ProbeError: Error { case missing(String) }

// Deliberately uses only the common public API. Passing this probe does not
// qualify Jazz wrapper ABI, our audio lifecycle repairs or LiveKit fork APIs.
final class Peer: NSObject, RTCPeerConnectionDelegate, RTCVideoRenderer {
    var connection: RTCPeerConnection!
    weak var remote: Peer?
    private var pending: [RTCIceCandidate] = [] // Accessed on the main queue.
    private var tracks: [RTCVideoTrack] = []
    private let lock = NSLock()
    private var frames = 0
    private var sizes: Set<String> = []
    private var sizeCounts: [String: Int] = [:]
    private var lastTimestamp: Int64 = -1
    private var advancing = 0
    private var lastArrival = 0.0
    private var maxGap = 0.0

    init(_ factory: RTCPeerConnectionFactory) {
        super.init()
        let config = RTCConfiguration(); config.sdpSemantics = .unifiedPlan
        connection = factory.peerConnection(with: config,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
    }

    @MainActor func set(_ sdp: RTCSessionDescription, local: Bool) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let done: @Sendable (Error?) -> Void = { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
            if local { connection.setLocalDescription(sdp, completionHandler: done) }
            else { connection.setRemoteDescription(sdp, completionHandler: done) }
        }
        if !local { pending.forEach { connection.add($0) { _ in } }; pending = [] }
    }

    @MainActor func description(offer: Bool) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { c in
            let done: @Sendable (RTCSessionDescription?, Error?) -> Void = { value, error in
                if let error { c.resume(throwing: error) }
                else if let value { c.resume(returning: value) }
                else { c.resume(throwing: ProbeError.missing("SDP")) }
            }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            if offer { connection.offer(for: constraints, completionHandler: done) }
            else { connection.answer(for: constraints, completionHandler: done) }
        }
    }

    func stats() async -> [[String: Any]] {
        let report: RTCStatisticsReport = await withCheckedContinuation { c in
            connection.statistics { c.resume(returning: $0) }
        }
        let keys = ["kind", "mimeType", "framesEncoded", "framesDecoded", "codecId", "packetsLost",
                    "encoderImplementation", "decoderImplementation", "powerEfficientEncoder", "powerEfficientDecoder"]
        return report.statistics.values.filter { ["codec", "inbound-rtp", "outbound-rtp"].contains($0.type) }.map { stat in
            var result: [String: Any] = ["type": stat.type, "id": stat.id]
            for key in keys { if let value = stat.values[key] { result[key] = value } }
            return result
        }
    }

    var evidence: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["frames": frames, "advancingTimestamps": advancing, "sizes": sizes.sorted(),
                "sizeCounts": sizeCounts, "maxArrivalGapMs": maxGap * 1000]
    }

    func close() {
        lock.lock(); let old = tracks; tracks = []; lock.unlock()
        old.forEach { $0.remove(self) }; connection.close()
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        DispatchQueue.main.async { [weak self] in
            guard let remote = self?.remote else { return }
            if remote.connection.remoteDescription == nil { remote.pending.append(candidate) }
            else { remote.connection.add(candidate) { _ in } }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd receiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        if let video = receiver.track as? RTCVideoTrack {
            lock.lock(); tracks.append(video); lock.unlock(); video.add(self)
        }
    }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        let size = "\(frame.width)x\(frame.height)"
        frames += 1; sizes.insert(size); sizeCounts[size, default: 0] += 1
        if frame.timeStampNs > lastTimestamp { advancing += 1 }; lastTimestamp = frame.timeStampNs
        if lastArrival > 0 { maxGap = max(maxGap, now - lastArrival) }; lastArrival = now
    }
}

@MainActor func runProbe() async throws -> [String: Any] {
    RTCInitializeSSL()
    let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    var results: [[String: Any]] = []
    for codec in ["H264", "VP8", "VP9"] {
        let sender = Peer(factory), receiver = Peer(factory)
        sender.remote = receiver; receiver.remote = sender
        defer { sender.close(); receiver.close() }
        guard sender.connection.setBweMinBitrateBps(2_000_000, currentBitrateBps: 3_000_000, maxBitrateBps: 5_000_000) else {
            throw ProbeError.missing("bitrate range")
        }
        let source = factory.videoSource(forScreenCast: true)
        source.adaptOutputFormat(toWidth: 640, height: 360, fps: 30)
        let video = factory.videoTrack(with: source, trackId: "synthetic")
        let settings = RTCRtpTransceiverInit(); settings.direction = .sendOnly
        guard let tx = sender.connection.addTransceiver(with: video, init: settings) else { throw ProbeError.missing("transceiver") }
        let codecs = factory.rtpSenderCapabilities(forKind: "video").codecs.filter { $0.name == codec }
        guard !codecs.isEmpty else { throw ProbeError.missing(codec) }
        try tx.setCodecPreferences(codecs, error: ())
        let offer = try await sender.description(offer: true)
        try await sender.set(offer, local: true); try await receiver.set(offer, local: false)
        let answer = try await receiver.description(offer: false)
        try await receiver.set(answer, local: true); try await sender.set(answer, local: false)
        let capturer = RTCVideoCapturer(delegate: source)
        for n in 0..<150 {
            let width = n < 75 ? 320 : 640, height = n < 75 ? 180 : 360
            var pixel: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else {
                throw ProbeError.missing("pixel buffer")
            }
            CVPixelBufferLockBaseAddress(pixel, [])
            let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            memset(bytes, Int32(n % 255), CVPixelBufferGetBytesPerRow(pixel) * height)
            CVPixelBufferUnlockBaseAddress(pixel, [])
            source.capturer(capturer, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixel), rotation: ._0,
                timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)))
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        var evidence = receiver.evidence
        let senderStats = await sender.stats(), receiverStats = await receiver.stats()
        evidence["requestedCodec"] = codec; evidence["sender"] = senderStats; evidence["receiver"] = receiverStats
        func hasNegotiatedCodec(_ stats: [[String: Any]], rtpType: String) -> Bool {
            stats.contains { item in
                guard item["type"] as? String == rtpType, item["kind"] as? String == "video",
                      let id = item["codecId"] as? String else { return false }
                return stats.contains { $0["id"] as? String == id && $0["mimeType"] as? String == "video/" + codec }
            }
        }
        let counts = evidence["sizeCounts"] as? [String: Int] ?? [:]
        guard (evidence["advancingTimestamps"] as? Int ?? 0) >= 60,
              (counts["320x180"] ?? 0) >= 20, (counts["640x360"] ?? 0) >= 20,
              hasNegotiatedCodec(senderStats, rtpType: "outbound-rtp"),
              hasNegotiatedCodec(receiverStats, rtpType: "inbound-rtp") else { throw ProbeError.missing("codec/decoded frames/resize: \(evidence)") }
        results.append(evidence)
    }
    let classes = ["RTCEAGLVideoView", "RTCFrameCryptor", "RTCFrameCryptorKeyProvider", "RTCDataPacketCryptor"]
    let availability = Dictionary(uniqueKeysWithValues: classes.map { ($0, NSClassFromString($0) != nil) })
    let functions = ["RTCSetConferencePlayoutReserved", "RTCSetApplicationInputMuteIntent", "RTCApplicationInputMuteReconfiguring",
                     "RTCSetApplicationCaptureMuted", "RTCApplicationCaptureMuted", "RTCConfigureScreenShareEncoderQuality",
                     "RTCGetScreenShareEncoderRates", "RTCSetScreenShareSenderResolution"]
    let exports = Dictionary(uniqueKeysWithValues: functions.map { ($0, dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0) != nil) })
    return ["passed": true, "scope": "synthetic video-only loopback; three fresh peer pairs; no SDK wrapper or microphone qualification",
            "classes": availability, "nativeExports": exports,
            "loadedFramework": Bundle(for: RTCPeerConnectionFactory.self).executableURL?.path ?? "unknown", "results": results]
}

@MainActor func finishProbe() async {
    let result: [String: Any]
    do { result = try await runProbe() }
    catch { result = ["passed": false, "error": String(describing: error)] }
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    #if os(iOS)
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.json")
    try! data.write(to: url, options: .atomic)
    #endif
    print(String(decoding: data, as: UTF8.self))
    exit(result["passed"] as? Bool == true ? 0 : 1)
}

#if os(iOS)
@main final class ProbeApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }
}
@objc(ProbeScene) final class ProbeScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible(); self.window = window
        Task { await finishProbe() }
    }
}
#else
@main struct ProbeMain {
    @MainActor static func main() async { await finishProbe() }
}
#endif
