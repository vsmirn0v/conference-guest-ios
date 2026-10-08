import Foundation
import CoreVideo
import LiveKitWebRTC

final class MediaPeer: NSObject, LKRTCPeerConnectionDelegate, LKRTCVideoRenderer, @unchecked Sendable {
    let target: String
    let factory: LKRTCPeerConnectionFactory
    var connection: LKRTCPeerConnection!
    private var _sequence = 0
    var sequence: Int {
        get { lock.lock(); defer { lock.unlock() }; return _sequence }
        set { lock.lock(); defer { lock.unlock() }; _sequence = newValue }
    }
    var sendCandidate: (([String: Any]) -> Void)?
    private var remoteCandidates: [LKRTCIceCandidate] = []
    private var tracks: [LKRTCVideoTrack] = []
    private var syntheticTask: Task<Void, Never>?
    private let lock = NSLock()
    private(set) var frameCount = 0
    private(set) var lastFrameTimestamp: Int64 = -1
    var receivedFrames: Int { lock.lock(); defer { lock.unlock() }; return frameCount }
    var isConnected: Bool { [.connected, .completed].contains(connection.iceConnectionState) }

    init(target: String, ice: [[String: Any]], factory: LKRTCPeerConnectionFactory) {
        self.target = target; self.factory = factory
        self._sequence = target == "PUBLISHER" ? 1 : 0
        super.init()
        let configuration = LKRTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = ice.compactMap { value in
            guard let urls = value["urls"] as? [String] else { return nil }
            return LKRTCIceServer(urlStrings: urls, username: value["username"] as? String,
                                 credential: value["credential"] as? String)
        }
        connection = factory.peerConnection(with: configuration, constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
    }

    func applyConfiguration(_ value: [String: Any]) throws {
        guard let servers = value["iceServers"] as? [[String: Any]] else { return }
        let configuration = connection.configuration
        configuration.iceServers = servers.compactMap { value in
            let urls = value["urls"] as? [String] ?? (value["urls"] as? String).map { [$0] } ?? []
            guard !urls.isEmpty else { return nil }
            return LKRTCIceServer(urlStrings: urls, username: value["username"] as? String,
                                 credential: value["credential"] as? String)
        }
        guard connection.setConfiguration(configuration) else { throw ProbeError.invalidPayload }
    }

    func answer(_ offer: [String: Any]) async throws -> [String: Any] {
        guard let sdp = offer["sdp"] as? String else { throw ProbeError.invalidPayload }
        sequence = (offer["pcSeq"] as? Int) ?? 0
        try await setRemote(.init(type: .offer, sdp: sdp))
        let answer: LKRTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            connection.answer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: ProbeError.invalidPayload) }
            }
        }
        try await setLocal(answer)
        for candidate in remoteCandidates { try await add(candidate) }; remoteCandidates = []
        return ["sdp": answer.sdp, "pcSeq": sequence]
    }
    func setRemote(_ description: LKRTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func publishPattern(sharing: Bool, preferH264: Bool) async throws -> [String: Any] {
        let audioSettings = LKRTCRtpTransceiverInit(); audioSettings.direction = .sendOnly
        let audioSource = factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: ["googEchoCancellation": "false", "googNoiseSuppression": "false", "googAutoGainControl": "false"], optionalConstraints: nil))
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "synthetic-audio")
        guard let audioTransceiver = connection.addTransceiver(with: audioTrack, init: audioSettings) else { throw ProbeError.invalidPayload }
        let source = factory.videoSource()
        source.adaptOutputFormat(toWidth: 640, height: 360, fps: 10)
        let track = factory.videoTrack(with: source, trackId: "synthetic-video")
        let settings = LKRTCRtpTransceiverInit(); settings.direction = .sendOnly
        guard let transceiver = connection.addTransceiver(with: track, init: settings) else { throw ProbeError.invalidPayload }
        if preferH264 {
            let codecs = factory.rtpSenderCapabilities(forKind: "video").codecs
            let preferred = codecs.filter { $0.name == "H264" } + codecs.filter { $0.name != "H264" }
            try transceiver.setCodecPreferences(preferred, error: ())
        }
        let offer: LKRTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: ProbeError.invalidPayload) }
            }
        }
        try await setLocal(offer)
        let capturer = LKRTCVideoCapturer(delegate: source)
        syntheticTask = Task {
            var count = 0
            while !Task.isCancelled {
                var pixelBuffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
                if let buffer = pixelBuffer {
                    CVPixelBufferLockBaseAddress(buffer, [])
                    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                    let stride = CVPixelBufferGetBytesPerRow(buffer)
                    for y in 0..<360 { for x in 0..<640 {
                        let i = y * stride + x * 4
                        bytes[i] = UInt8((x + count * 8) % 256)
                        bytes[i + 1] = UInt8(y % 256)
                        bytes[i + 2] = UInt8((count * 9) % 256)
                        bytes[i + 3] = 255
                    } }
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
                    source.capturer(capturer, didCapture: frame)
                }
                count += 1
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return ["sdp": offer.sdp, "pcSeq": sequence, "tracks": [["mid": audioTransceiver.mid, "transceiverMid": audioTransceiver.mid, "kind": "AUDIO", "priority": 0, "label": "Synthetic tone", "codecs": [:], "groupId": 1, "description": ""], ["mid": transceiver.mid, "transceiverMid": transceiver.mid, "kind": sharing ? "DISPLAY_VIDEO" : "VIDEO", "priority": 0, "label": "Synthetic native pattern", "codecs": [:], "groupId": sharing ? 2 : 1, "description": ""]]]
    }
    func acceptAnswer(_ value: [String: Any]) async throws {
        guard let sdp = value["sdp"] as? String else { throw ProbeError.invalidPayload }
        try await setRemote(.init(type: .answer, sdp: sdp))
        for candidate in remoteCandidates { try await add(candidate) }; remoteCandidates = []
    }
    func setLocal(_ description: LKRTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func candidate(_ value: [String: Any]) async throws {
        guard let sdp = value["candidate"] as? String else { return }
        let candidate = LKRTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(value["sdpMlineIndex"] as? Int ?? 0), sdpMid: value["sdpMid"] as? String)
        if connection.remoteDescription == nil { remoteCandidates.append(candidate) } else { try await add(candidate) }
    }
    private func add(_ candidate: LKRTCIceCandidate) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.add(candidate) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func stats() async {
        let report: LKRTCStatisticsReport = await withCheckedContinuation { continuation in
            connection.statistics { continuation.resume(returning: $0) }
        }
        for stat in report.statistics.values where ["inbound-rtp", "outbound-rtp", "codec"].contains(stat.type) {
            let keys = ["kind", "bytesReceived", "bytesSent", "packetsReceived", "packetsSent", "framesDecoded", "framesEncoded", "totalAudioEnergy", "mimeType", "codecId", "decoderImplementation", "encoderImplementation", "powerEfficientEncoder", "powerEfficientDecoder"]
            var summary: [String: Any] = ["target": target, "type": stat.type]
            for key in keys { if let value = stat.values[key] { summary[key] = value } }
            probeLog("rtc-stats", summary)
        }
        probeLog("render-summary", ["target": target, "frames": receivedFrames])
    }
    func close() {
        syntheticTask?.cancel(); syntheticTask = nil
        lock.lock(); let oldTracks = tracks; tracks = []; lock.unlock()
        oldTracks.forEach { $0.remove(self) }; connection.close()
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        probeLog("ice-state", ["target": target, "state": newState.rawValue])
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        sendCandidate?(["candidate": candidate.sdp, "sdpMlineIndex": candidate.sdpMLineIndex,
                        "sdpMid": candidate.sdpMid ?? "0", "target": target, "pcSeq": sequence])
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        probeLog("incoming-track", ["kind": rtpReceiver.track?.kind ?? "unknown", "target": target])
        if let video = rtpReceiver.track as? LKRTCVideoTrack { lock.lock(); tracks.append(video); lock.unlock(); video.add(self) }
    }
    func setSize(_ size: CGSize) { probeLog("video-size", ["width": size.width, "height": size.height]) }
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        lock.lock(); frameCount += 1; let count = frameCount; let changed = frame.timeStampNs != lastFrameTimestamp; lastFrameTimestamp = frame.timeStampNs; lock.unlock()
        if count == 1 || count % 60 == 0 { probeLog("decoded-frame", ["count": count, "width": frame.width, "height": frame.height, "newTimestamp": changed]) }
    }
}
