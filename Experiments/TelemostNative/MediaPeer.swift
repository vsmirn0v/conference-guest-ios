import Foundation
import CoreVideo
import LiveKitWebRTC

enum CodecPolicy: String {
    case serverDefault, preferH264, h264Only, h264Level31, vp9Only, hevcOnly
}

let experimentalHEVC = LKRTCVideoCodecInfo(name: "H265", parameters: ["profile-id": "1", "tier-flag": "0", "level-id": "93", "tx-mode": "SRST"])
final class HEVCEncoderFactory: NSObject, LKRTCVideoEncoderFactory {
    private let base = LKRTCDefaultVideoEncoderFactory()
    func supportedCodecs() -> [LKRTCVideoCodecInfo] { [experimentalHEVC] + base.supportedCodecs() }
    func createEncoder(_ info: LKRTCVideoCodecInfo) -> (any LKRTCVideoEncoder)? {
        info.name == "H265" ? LKRTCVideoEncoderH265(codecInfo: info) : base.createEncoder(info)
    }
}
final class HEVCDecoderFactory: NSObject, LKRTCVideoDecoderFactory {
    private let base = LKRTCDefaultVideoDecoderFactory()
    func supportedCodecs() -> [LKRTCVideoCodecInfo] { [experimentalHEVC] + base.supportedCodecs() }
    func createDecoder(_ info: LKRTCVideoCodecInfo) -> (any LKRTCVideoDecoder)? {
        info.name == "H265" ? LKRTCVideoDecoderH265() : base.createDecoder(info)
    }
}

/// Diagnostic only. Preserve the profile and packetization mode while capping
/// its level. Store exactly this description locally before transmitting it.
func cappedH264Level(_ sdp: String) -> String {
    sdp.components(separatedBy: "\r\n").map { line in
        guard line.hasPrefix("a=fmtp:"), let separator = line.firstIndex(of: " ") else { return line }
        let parameters = line[line.index(after: separator)...].split(separator: ";").map { parameter -> String in
            let fields = parameter.split(separator: "=", maxSplits: 1)
            guard fields.count == 2, fields[0].trimmingCharacters(in: .whitespaces) == "profile-level-id",
                  fields[1].count == 6, let level = Int(fields[1].suffix(2), radix: 16), level > 31 else { return String(parameter) }
            return String(fields[0]) + "=" + fields[1].prefix(4) + "1f"
        }
        return String(line[...separator]) + parameters.joined(separator: ";")
    }.joined(separator: "\r\n")
}

// Log only SDP's formal codec fields, never ICE credentials or addresses.
func logCodecs(_ sdp: String, target: String, phase: String) {
    var video = false, mid = "", payloads: [String] = []
    var maps: [String: String] = [:], parameters: [String: String] = [:]
    func flush() {
        guard video else { return }
        probeLog("sdp-codecs", ["target": target, "phase": phase, "mid": mid,
            "codecs": payloads.compactMap { payload -> [String: String]? in
                guard let map = maps[payload] else { return nil }
                return ["payload": payload, "codec": map, "parameters": parameters[payload] ?? ""]
            }])
    }
    for line in sdp.components(separatedBy: .newlines) {
        if line.hasPrefix("m=") {
            flush(); video = line.hasPrefix("m=video "); mid = ""; maps = [:]; parameters = [:]
            payloads = line.split(separator: " ").dropFirst(3).map(String.init)
        } else if video, line.hasPrefix("a=mid:") {
            mid = String(line.dropFirst(6))
        } else if video, line.hasPrefix("a=rtpmap:") || line.hasPrefix("a=fmtp:") {
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2, let payload = fields[0].split(separator: ":").last else { continue }
            if line.hasPrefix("a=rtpmap:") { maps[String(payload)] = String(fields[1]) }
            else { parameters[String(payload)] = String(fields[1]) }
        }
    }
    flush()
}

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
    private var lastDimensions: (Int32, Int32) = (0, 0)
    var receivedDimensions: (Int32, Int32) { lock.lock(); defer { lock.unlock() }; return lastDimensions }
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

    @MainActor func answer(_ offer: [String: Any]) async throws -> [String: Any] {
        guard let sdp = offer["sdp"] as? String else { throw ProbeError.invalidPayload }
        logCodecs(sdp, target: target, phase: "remote-offer")
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
        logCodecs(answer.sdp, target: target, phase: "local-answer")
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
    func publishPattern(sharing: Bool, codecPolicy: CodecPolicy, scalabilityMode: String? = nil, width: Int = 640, height: Int = 360, fps: Int = 10) async throws -> [String: Any] {
        let audioSettings = LKRTCRtpTransceiverInit(); audioSettings.direction = .sendOnly
        let audioSource = factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: ["googEchoCancellation": "false", "googNoiseSuppression": "false", "googAutoGainControl": "false"], optionalConstraints: nil))
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "synthetic-audio")
        guard let audioTransceiver = connection.addTransceiver(with: audioTrack, init: audioSettings) else { throw ProbeError.invalidPayload }
        let source = factory.videoSource()
        source.adaptOutputFormat(toWidth: Int32(width), height: Int32(height), fps: Int32(fps))
        let track = factory.videoTrack(with: source, trackId: "synthetic-video")
        let settings = LKRTCRtpTransceiverInit(); settings.direction = .sendOnly
        if let scalabilityMode {
            let encoding = LKRTCRtpEncodingParameters(); encoding.scalabilityMode = scalabilityMode
            settings.sendEncodings = [encoding]
        }
        guard let transceiver = connection.addTransceiver(with: track, init: settings) else { throw ProbeError.invalidPayload }
        if codecPolicy != .serverDefault {
            let codecs = factory.rtpSenderCapabilities(forKind: "video").codecs
            let name = codecPolicy == .vp9Only ? "VP9" : (codecPolicy == .hevcOnly ? "H265" : "H264")
            let preferred = codecs.filter { $0.name == name } +
                (codecPolicy == .preferH264 ? codecs.filter { $0.name != "H264" } : [])
            try transceiver.setCodecPreferences(preferred, error: ())
        }
        var offer: LKRTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: ProbeError.invalidPayload) }
            }
        }
        if codecPolicy == .h264Level31 { offer = LKRTCSessionDescription(type: .offer, sdp: cappedH264Level(offer.sdp)) }
        try await setLocal(offer)
        logCodecs(offer.sdp, target: target, phase: "local-offer")
        let capturer = LKRTCVideoCapturer(delegate: source)
        syntheticTask = Task {
            // Precompute immutable input pixels so sender CPU/load cannot change
            // the source cadence during a matched receiving-energy comparison.
            var frames: [CVPixelBuffer] = []
            for count in 0..<16 {
                var pixelBuffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
                if let buffer = pixelBuffer {
                    CVPixelBufferLockBaseAddress(buffer, [])
                    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                    let stride = CVPixelBufferGetBytesPerRow(buffer)
                    for y in 0..<height { for x in 0..<width {
                        let i = y * stride + x * 4
                        bytes[i] = UInt8((x + count * 8) % 256)
                        bytes[i + 1] = UInt8(y % 256)
                        bytes[i + 2] = UInt8((count * 9) % 256)
                        bytes[i + 3] = 255
                    } }
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    frames.append(buffer)
                }
            }
            guard !frames.isEmpty else { return }
            var count = 0
            var next = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: frames[count % frames.count]), rotation: ._0,
                    timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
                source.capturer(capturer, didCapture: frame)
                count += 1
                next = max(next + 1 / Double(fps), ProcessInfo.processInfo.systemUptime)
                try? await Task.sleep(nanoseconds: UInt64(max(0, next - ProcessInfo.processInfo.systemUptime) * 1_000_000_000))
            }
        }
        return ["sdp": offer.sdp, "pcSeq": sequence, "tracks": [["mid": audioTransceiver.mid, "transceiverMid": audioTransceiver.mid, "kind": "AUDIO", "priority": 0, "label": "Synthetic tone", "codecs": [:], "groupId": 1, "description": ""], ["mid": transceiver.mid, "transceiverMid": transceiver.mid, "kind": sharing ? "DISPLAY_VIDEO" : "VIDEO", "priority": 0, "label": "Synthetic native pattern", "codecs": [:], "groupId": sharing ? 2 : 1, "description": ""]]]
    }
    @MainActor func acceptAnswer(_ value: [String: Any]) async throws {
        guard let sdp = value["sdp"] as? String else { throw ProbeError.invalidPayload }
        logCodecs(sdp, target: target, phase: "remote-answer")
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
    @MainActor func candidate(_ value: [String: Any]) async throws {
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
    @discardableResult func stats() async -> Int {
        let report: LKRTCStatisticsReport = await withCheckedContinuation { continuation in
            connection.statistics { continuation.resume(returning: $0) }
        }
        for stat in report.statistics.values where ["inbound-rtp", "outbound-rtp", "codec"].contains(stat.type) {
            let keys = ["kind", "mid", "bytesReceived", "bytesSent", "packetsReceived", "packetsSent", "framesDecoded", "framesEncoded", "totalAudioEnergy", "mimeType", "codecId", "sdpFmtpLine", "frameWidth", "frameHeight", "framesPerSecond", "totalEncodeTime", "totalDecodeTime", "qualityLimitationReason", "decoderImplementation", "encoderImplementation", "powerEfficientEncoder", "powerEfficientDecoder"]
            var summary: [String: Any] = ["target": target, "type": stat.type, "id": stat.id]
            for key in keys { if let value = stat.values[key] { summary[key] = value } }
            probeLog("rtc-stats", summary)
        }
        probeLog("render-summary", ["target": target, "frames": receivedFrames])
        probeLog("hardware-vp9", ["decoders": NativeVideoDecoderFactory.evidenceForTesting])
        return report.statistics.values.filter { $0.type == "outbound-rtp" && $0.values["kind"] as? String == "video" }
            .reduce(0) { $0 + (($1.values["framesEncoded"] as? NSNumber)?.intValue ?? 0) }
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
        lock.lock(); frameCount += 1; let count = frameCount; let changed = frame.timeStampNs != lastFrameTimestamp; lastFrameTimestamp = frame.timeStampNs; lastDimensions = (frame.width, frame.height); lock.unlock()
        if count == 1 || count % 60 == 0 { probeLog("decoded-frame", ["count": count, "width": frame.width, "height": frame.height, "newTimestamp": changed]) }
    }
}
