import Foundation
import CoreVideo
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import LiveKitWebRTC

enum GuestPeerError: Error { case malformed, closed, candidateOverflow, unsupportedCodec, iceFailed }
enum GuestPeerTarget: String { case publisher = "PUBLISHER", subscriber = "SUBSCRIBER" }

/// Stable for one receiver attachment; native renderers must detach when it disappears.
struct GuestRemoteVideo {
    let id: String
    let track: LKRTCVideoTrack
    var streamIDs: [String]
    var participantName: String?
    var participantID: String?
    var source: String?
}

/// Owns one guest PC. All signaling operations are driven by the MainActor engine.
@MainActor
final class GuestPeer: NSObject, LKRTCPeerConnectionDelegate {
    static var diagnosticEventLogDirectory: URL?
    let diagnosticID = UUID().uuidString
    let target: GuestPeerTarget
    let factory: LKRTCPeerConnectionFactory
    private(set) var connection: LKRTCPeerConnection!
    let renderer: GuestFrameCounter
    let pcmMeter = GuestPCMMeter()
    private let physicalAudio: Bool
    private let icePolicy: GuestICEPolicy
    private var incomingAudio: [LKRTCAudioTrack] = []
    private var iceTimeout: Task<Void, Never>?
    private var lastICEState: LKRTCIceConnectionState = .new
    var sendCandidate: (([String: Any]) async throws -> Void)?
    var onFailure: ((Error) -> Void)?
    private var remoteICE: [LKRTCIceCandidate] = []
    private var localICE: [[String: Any]] = []
    private var localSDPSent = false
    private var closed = false
    private(set) var iceConnected = false
    private var incomingVideo: [(video: GuestRemoteVideo, sink: GuestTrackRenderer)] = []
    var onIncomingVideoChange: (([GuestRemoteVideo]) -> Void)? {
        didSet { onIncomingVideoChange?(receivedVideo) }
    }
    var receivedVideo: [GuestRemoteVideo] { incomingVideo.map(\.video) }
    var localVideoTrack: LKRTCVideoTrack? { videoTrack }
    var localScreenVideoTrack: LKRTCVideoTrack? { screenTrack }
    private(set) var screenSource: LKRTCVideoSource?
    private var screenTrack: LKRTCVideoTrack?
    private var screenSender: LKRTCRtpSender?
    private var screenProfile = GuestVideoProfile.camera
    private var patternTask: Task<Void, Never>?
    private var generatedFrames = 0
    private var generatedLastUptime: Double = 0
    private var audioTrack: LKRTCAudioTrack?
    private var videoTrack: LKRTCVideoTrack?
    private var videoSender: LKRTCRtpSender?
    private var videoProfile = GuestVideoProfile.pattern
    private(set) var source: LKRTCVideoSource?
#if DEBUG
    private var generatedICECandidates = 0
    private var queuedLocalICECandidates = 0
    private var sentLocalICECandidates = 0
    private var receivedRemoteICECandidates = 0
    private var bufferedRemoteICECandidates = 0
    private var addedRemoteICECandidates = 0
    private var iceGatheringErrors = 0
    private var lastGatheringState = LKRTCIceGatheringState.new
    private let maximumLoggedICEGatheringErrors = 32
    var iceDiagnosticForTesting: ((String, [String: Any]) -> Void)?
    var iceCandidateEventFinishedForTesting: (() -> Void)?
    var iceGatherEventFinishedForTesting: (() -> Void)?
    var iceWaitForTesting: ((UInt64) async throws -> Void)?
    var iceEventFinishedForTesting: (() -> Void)?
    var iceTimerFinishedForTesting: (() -> Void)?
    private(set) var videoEnableCallsForTesting = 0
    private(set) var receiverAttachmentsForTesting = 0
    private(set) var receiverDetachmentsForTesting = 0
    var receiverEventFinishedForTesting: (() -> Void)?
    var retainedReceiverTracksForTesting: Int { incomingVideo.count + incomingAudio.count }
#endif

    init(target: GuestPeerTarget, factory: LKRTCPeerConnectionFactory, physicalAudio: Bool = false, icePolicy: GuestICEPolicy = .automatic, verifyReceivedPixels: Bool = true) throws {
        self.target = target; self.factory = factory; self.physicalAudio = physicalAudio; self.icePolicy = icePolicy
        renderer = GuestFrameCounter(verifyPixels: verifyReceivedPixels)
        super.init()
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        guard let pc = factory.peerConnection(with: config,
            constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        else { throw GuestPeerError.malformed }
        connection = pc
        if let directory = Self.diagnosticEventLogDirectory {
            let path = directory.appendingPathComponent("\(target.rawValue)-\(diagnosticID).rtc").path
            guard pc.startRtcEventLog(withFilePath: path, maxSizeInBytes: 8 * 1024 * 1024) else { pc.close(); throw GuestPeerError.malformed }
        }
    }

    func configure(_ value: [String: Any]) throws {
        guard !closed else { throw GuestPeerError.closed }
        let config = connection.configuration
        let icePolicy = self.icePolicy.forTarget(target)
        let servers = try icePolicy.servers(value["iceServers"] as? [[String: Any]] ?? [])
        if value["iceServers"] is [[String: Any]] || icePolicy != .automatic {
            config.iceServers = servers.compactMap { server in
                let urls = server["urls"] as? [String] ?? (server["urls"] as? String).map { [$0] } ?? []
                guard !urls.isEmpty else { return nil }
                return LKRTCIceServer(urlStrings: urls, username: server["username"] as? String,
                    credential: server["credential"] as? String)
            }
        }
        if icePolicy != .automatic || value["iceTransportPolicy"] as? String == "relay" { config.iceTransportPolicy = .relay }
        guard connection.setConfiguration(config) else { throw GuestPeerError.malformed }
    }

    func answer(_ description: [String: Any]) async throws -> [String: Any] {
        guard let sdp = description["sdp"] as? String, sdp.utf8.count < 1_000_000 else { throw GuestPeerError.malformed }
        localSDPSent = false
        try await setRemote(.init(type: .offer, sdp: sdp))
        let answer = try await descriptionForOffer(false)
        try await setLocal(answer)
        probeLog("video-negotiation", ["target": target.rawValue, "remote": GuestSDPSummary.video(sdp), "local": GuestSDPSummary.video(answer.sdp)])
        return ["type": "answer", "sdp": answer.sdp]
    }

    func acceptAnswer(_ description: [String: Any]) async throws {
        guard let sdp = description["sdp"] as? String, sdp.utf8.count < 1_000_000 else { throw GuestPeerError.malformed }
        try await setRemote(.init(type: .answer, sdp: sdp))
        probeLog("video-negotiation", ["target": target.rawValue, "remote": GuestSDPSummary.video(sdp), "local": GuestSDPSummary.video(connection.localDescription?.sdp ?? "")])
    }

    func makeOffer() async throws -> [String: Any] {
        guard !closed else { throw GuestPeerError.closed }
        localSDPSent = false
        let offer = try await descriptionForOffer(true)
        try await setLocal(offer)
        return ["type": "offer", "sdp": offer.sdp]
    }

    func didSendDescription() async throws {
        guard !closed else { throw GuestPeerError.closed }
        localSDPSent = true
        let values = localICE; localICE.removeAll()
        for value in values {
            if let sendCandidate {
                try await sendCandidate(value)
#if DEBUG
                if sentLocalICECandidates < Int.max { sentLocalICECandidates += 1 }
#endif
            }
        }
    }

    func addCandidates(_ values: [[String: Any]]) async throws {
        for value in values where value["target"] as? String == target.rawValue {
            guard !closed else { throw GuestPeerError.closed }
            guard let sdp = value["candidate"] as? String, sdp.utf8.count < 16_384 else { throw GuestPeerError.malformed }
#if DEBUG
            if receivedRemoteICECandidates < Int.max { receivedRemoteICECandidates += 1 }
#endif
            let candidate = LKRTCIceCandidate(sdp: sdp,
                sdpMLineIndex: (value["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0,
                sdpMid: value["sdpMid"] as? String)
            if connection.remoteDescription == nil {
                guard remoteICE.count < 256 else { throw GuestPeerError.candidateOverflow }
                remoteICE.append(candidate)
#if DEBUG
                if bufferedRemoteICECandidates < Int.max { bufferedRemoteICECandidates += 1 }
#endif
            } else {
                try await add(candidate)
#if DEBUG
                if addedRemoteICECandidates < Int.max { addedRemoteICECandidates += 1 }
#endif
            }
        }
    }

    func prepareAudio(cid: String, profile: GuestAudioProfile = .speech) -> LKRTCAudioTrack {
        let constraints = physicalAudio ? profile.audioConstraints : [
            "googEchoCancellation": "false", "googNoiseSuppression": "false", "googAutoGainControl": "false"]
        let source = factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: constraints, optionalConstraints: nil))
        return factory.audioTrack(with: source, trackId: cid)
    }

    func prepareVideo(cid: String, profile: GuestVideoProfile = .pattern, screenCast: Bool = false) -> LKRTCVideoTrack {
        videoProfile = profile
        let source = screenCast ? factory.videoSource(forScreenCast: true) : factory.videoSource()
        source.adaptOutputFormat(toWidth: profile.width, height: profile.height, fps: profile.fps)
        self.source = source
        return factory.videoTrack(with: source, trackId: cid)
    }

    func prepareScreenVideo(cid: String, profile: GuestVideoProfile) -> LKRTCVideoTrack {
        let source = factory.videoSource(forScreenCast: true)
        screenSource = source; screenProfile = profile
        source.adaptOutputFormat(toWidth: profile.width, height: profile.height, fps: profile.fps)
        let track = factory.videoTrack(with: source, trackId: cid)
        track.isEnabled = false
        return track
    }

    func updateScreenProfile(_ profile: GuestVideoProfile) {
        screenProfile = profile
        screenSource?.adaptOutputFormat(toWidth: profile.width, height: profile.height, fps: profile.fps)
        if let screenSender {
            let parameters = screenSender.parameters
            parameters.encodings.forEach {
                $0.maxBitrateBps = NSNumber(value: profile.maximumBitrate)
                $0.maxFramerate = NSNumber(value: profile.fps)
            }
            screenSender.parameters = parameters
        }
    }

    func attachScreenVideo(_ track: LKRTCVideoTrack, codec: String) throws {
        guard !closed, screenSender == nil else { throw GuestPeerError.closed }
        let capabilities = factory.rtpSenderCapabilities(forKind: "video").codecs
        let matches = capabilities.filter { $0.name.lowercased() == codec.lowercased() }
        guard !matches.isEmpty else { throw GuestPeerError.unsupportedCodec }
        let config = LKRTCRtpTransceiverInit(); config.direction = .sendOnly
        config.sendEncodings = [screenProfile.encoding()]
        guard let transceiver = connection.addTransceiver(with: track, init: config) else { throw GuestPeerError.malformed }
        try transceiver.setCodecPreferences(matches + capabilities.filter { $0.name.lowercased() == "rtx" }, error: ())
        screenTrack = track; screenSender = transceiver.sender
    }

    func setScreenMuted(_ muted: Bool) throws {
        guard !closed, let screenSender, let screenTrack else { throw GuestPeerError.closed }
        if muted { screenTrack.isEnabled = false }
        let parameters = screenSender.parameters
        guard !parameters.encodings.isEmpty else { throw GuestPeerError.malformed }
        parameters.encodings.forEach { $0.isActive = !muted }
        if !muted { screenTrack.isEnabled = true }
        screenSender.parameters = parameters
        guard screenSender.parameters.encodings.allSatisfy({ $0.isActive == !muted }) else {
            screenTrack.isEnabled = false; throw GuestPeerError.malformed
        }
    }

    func suppressScreenVideo() {
        screenTrack?.isEnabled = false
        if screenSender != nil { try? setScreenMuted(true) }
    }

    @discardableResult func removeScreenVideo() throws -> Bool {
        suppressScreenVideo()
        guard let screenSender else { screenSource = nil; screenTrack = nil; return false }
        guard !closed, connection.removeTrack(screenSender) else { throw GuestPeerError.closed }
        self.screenSender = nil; screenTrack = nil; screenSource = nil
        return true
    }

    func waitForStableSignaling() async throws {
        for _ in 0..<100 {
            try Task.checkCancellation()
            guard !closed, connection.signalingState != .closed else { throw GuestPeerError.closed }
            if connection.signalingState == .stable { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw GuestTransportError.timedOut
    }

    func attach(_ track: LKRTCMediaStreamTrack, codec: String) throws {
        guard !closed else { throw GuestPeerError.closed }
        let config = LKRTCRtpTransceiverInit(); config.direction = .sendOnly
        if track.kind == "video" { config.sendEncodings = [videoProfile.encoding()] }
        guard let transceiver = connection.addTransceiver(with: track, init: config) else { throw GuestPeerError.malformed }
        if track.kind == "video" {
            let capabilities = factory.rtpSenderCapabilities(forKind: "video").codecs
            let matches = capabilities.filter { $0.name.lowercased() == codec.lowercased() }
            guard !matches.isEmpty else { throw GuestPeerError.unsupportedCodec }
            // Native codec negotiation creates the RTX apt association. Filtering
            // only the primary codec silently disables repair payloads.
            let repair = capabilities.filter { $0.name.lowercased() == "rtx" }
            // The guest SFU learns its publisher codec table from the first
            // video m-section. Advertise later content capability there without
            // starting its encoder or changing the H264 camera registration.
            let contentCapability = codec.lowercased() == "h264"
                ? capabilities.filter { $0.name.lowercased() == "vp9" } : []
            try transceiver.setCodecPreferences(matches + contentCapability + repair, error: ())
            videoTrack = track as? LKRTCVideoTrack
            videoSender = transceiver.sender
        } else { audioTrack = track as? LKRTCAudioTrack }
    }

    func setMuted(_ mute: Bool, video: Bool) throws {
#if DEBUG
        if !mute && video { videoEnableCallsForTesting += 1 }
#endif
        guard !closed else { throw GuestPeerError.closed }
        if video {
            guard let videoSender, let videoTrack else { throw GuestPeerError.malformed }
            // Stop RTP before advertising mute. Reactivation reinitializes the
            // encoder layer, producing an independently decodable resume frame.
            if mute { videoTrack.isEnabled = false }
            let parameters = videoSender.parameters
            guard !parameters.encodings.isEmpty else { throw GuestPeerError.malformed }
            parameters.encodings.forEach { $0.isActive = !mute }
            if !mute { videoTrack.isEnabled = true }
            videoSender.parameters = parameters
            guard videoSender.parameters.encodings.allSatisfy({ $0.isActive == !mute }) else {
                videoTrack.isEnabled = false
                throw GuestPeerError.malformed
            }
        } else { audioTrack?.isEnabled = !mute }
    }

    func suppress(video: Bool) {
        if video {
            videoTrack?.isEnabled = false
            if videoSender != nil { try? setMuted(true, video: true) }
        } else { audioTrack?.isEnabled = false }
    }

    func stopPattern() { patternTask?.cancel(); patternTask = nil }

    func startPattern() throws {
        guard let source, !closed else { throw GuestPeerError.closed }
        if patternTask != nil { return }
        let capturer = LKRTCVideoCapturer(delegate: source)
        var frames: [CVPixelBuffer] = []
        for phase in 0..<12 {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
                let buffer else { throw GuestPeerError.malformed }
            CVPixelBufferLockBaseAddress(buffer, [])
            let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<360 { for x in 0..<640 {
                let i = y * stride + x * 4
                p[i] = UInt8((x + phase * 20) % 256); p[i+1] = UInt8(y % 256)
                p[i+2] = UInt8(phase * 20); p[i+3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            frames.append(buffer)
        }
        patternTask = Task {
            var index = 0
            while !Task.isCancelled {
                let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: frames[index % frames.count]),
                    rotation: ._0, timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
                source.capturer(capturer, didCapture: frame)
                generatedFrames += 1; generatedLastUptime = ProcessInfo.processInfo.systemUptime
                index += 1
                do { try await Task.sleep(nanoseconds: 66_666_667) } catch { break }
            }
        }
    }

    var publicationIdentity: [String: String] {
        guard let videoSender else { return [:] }
        let mid = connection.transceivers.first { $0.sender.senderId == videoSender.senderId }?.mid ?? "pending"
        return ["sender": videoSender.senderId, "mid": mid]
    }

    var localVideoState: [String: Any] {
        ["generatedFrames": generatedFrames, "generatedLastUptime": generatedLastUptime,
            "enabled": videoTrack?.isEnabled ?? false, "encodingActive": videoSender?.parameters.encodings.map(\.isActive) ?? [],
            "negotiatedCodecs": videoSender?.parameters.codecs.map(\.name) ?? [],
            "encodingMaximumBitrates": videoSender?.parameters.encodings.map { $0.maxBitrateBps?.intValue ?? -1 } ?? [],
            "encodingMaximumFrameRates": videoSender?.parameters.encodings.map { $0.maxFramerate?.intValue ?? -1 } ?? [],
            "registeredProfile": videoProfile.layer,
            "localSDPVideoCodecs": Self.videoCodecNames(connection.localDescription?.sdp),
            "remoteSDPVideoCodecs": Self.videoCodecNames(connection.remoteDescription?.sdp)]
    }

    /// Sanitized formal SDP metadata only; never emit descriptions, ICE or addresses.
    private static func videoCodecNames(_ sdp: String?) -> [String] {
        guard let sdp else { return [] }
        var video = false, names = Set<String>()
        for line in sdp.components(separatedBy: .newlines) {
            if line.hasPrefix("m=") { video = line.split(separator: " ").first == "m=video" }
            else if video && line.hasPrefix("a=rtpmap:") {
                let fields = line.dropFirst(9).split(separator: " ")
                if fields.count == 2, let name = fields[1].split(separator: "/").first, name.count <= 64 {
                    names.insert(name.lowercased())
                }
            }
        }
        return names.sorted()
    }

    func stats() async -> [[String: Any]]? {
        guard !closed else { return nil }
        guard let report: LKRTCStatisticsReport = try? await guestAwait(timeout: 3, { done in
            self.connection.statistics { done(.success($0)) }
        }) else { return nil }
        let keys = ["kind", "mid", "bytesReceived", "bytesSent", "packetsReceived", "packetsSent",
            "frames", "framesSent", "framesDecoded", "framesEncoded",
            "qualityLimitationReason", "qualityLimitationDurations", "qualityLimitationResolutionChanges",
            "totalEncodeTime", "qpSum", "targetBitrate", "totalPacketSendDelay",
            "jitterBufferDelay", "jitterBufferEmittedCount", "totalAssemblyTime", "framesAssembledFromMultiplePackets",
            "headerBytesReceived", "headerBytesSent", "retransmittedBytesSent", "firCount", "packetsDiscarded", "totalInterFrameDelay", "totalSquaredInterFrameDelay", "totalProcessingDelay",
            "roundTripTime", "fractionLost", "currentRoundTripTime", "availableOutgoingBitrate",
            "dtlsState", "iceState", "selectedCandidatePairId", "localCandidateId", "remoteCandidateId", "protocol", "candidateType", "relayProtocol", "totalAudioEnergy", "mimeType", "codecId", "frameWidth", "frameHeight",
            "keyFramesEncoded", "keyFramesDecoded", "framesReceived", "pliCount", "nackCount",
            "packetsLost", "jitter", "framesDropped", "totalDecodeTime", "freezeCount", "totalFreezesDuration",
            "retransmittedPacketsSent", "retransmittedPacketsReceived",
            "audioLevel", "totalSamplesDuration", "totalSamplesReceived", "framesPerSecond", "encoderImplementation", "decoderImplementation", "powerEfficientEncoder", "powerEfficientDecoder"]
        let selectedPairs = Set(report.statistics.values.filter { $0.type == "transport" }
            .compactMap { $0.values["selectedCandidatePairId"] as? String })
        let candidateIDs = Set(report.statistics.values.filter { selectedPairs.contains($0.id) }
            .flatMap { [$0.values["localCandidateId"] as? String, $0.values["remoteCandidateId"] as? String].compactMap { $0 } })
        return report.statistics.values.filter {
            ["inbound-rtp", "outbound-rtp", "remote-inbound-rtp", "codec", "media-source", "transport"].contains($0.type) ||
            selectedPairs.contains($0.id) || candidateIDs.contains($0.id)
        }.map { stat in
            var value: [String: Any] = ["target": target.rawValue, "type": stat.type, "id": stat.id, "sampleUptime": ProcessInfo.processInfo.systemUptime, "nativeTimestampUS": stat.timestamp_us]
            for key in keys { if let item = stat.values[key] { value[key] = item } }
            return value
        }
    }

    func close() {
        guard !closed else { return }; closed = true
        patternTask?.cancel(); patternTask = nil
        iceTimeout?.cancel(); iceTimeout = nil
        audioTrack?.isEnabled = false; videoTrack?.isEnabled = false; screenTrack?.isEnabled = false
        incomingVideo.forEach { $0.sink.stop(); $0.video.track.remove($0.sink) }; incomingVideo.removeAll()
        onIncomingVideoChange?([]); onIncomingVideoChange = nil
        incomingAudio.forEach { $0.remove(pcmMeter) }; incomingAudio.removeAll()
        localICE.removeAll(); remoteICE.removeAll(); sendCandidate = nil
        connection.stopRtcEventLog()
        connection.close(); connection.delegate = nil
        audioTrack = nil; videoTrack = nil; videoSender = nil; source = nil
        screenTrack = nil; screenSender = nil; screenSource = nil
    }

    private func descriptionForOffer(_ offer: Bool) async throws -> LKRTCSessionDescription {
        guard !closed else { throw GuestPeerError.closed }
        let result: LKRTCSessionDescription = try await guestAwait { done in
            let completion: @Sendable (LKRTCSessionDescription?, Error?) -> Void = { value, error in
                if let error { done(.failure(error)) }
                else if let value { done(.success(value)) }
                else { done(.failure(GuestPeerError.malformed)) }
            }
            let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            if offer { self.connection.offer(for: constraints, completionHandler: completion) }
            else { self.connection.answer(for: constraints, completionHandler: completion) }
        }
        guard !closed else { throw GuestPeerError.closed }
        return result
    }
    private func setLocal(_ value: LKRTCSessionDescription) async throws {
        guard !closed else { throw GuestPeerError.closed }
        let _: Void = try await guestAwait { done in
            self.connection.setLocalDescription(value) { error in
                done(error.map { .failure($0) } ?? .success(()))
            }
        }
        guard !closed else { throw GuestPeerError.closed }
    }
    private func setRemote(_ value: LKRTCSessionDescription) async throws {
        guard !closed else { throw GuestPeerError.closed }
        let _: Void = try await guestAwait { done in
            self.connection.setRemoteDescription(value) { error in
                done(error.map { .failure($0) } ?? .success(()))
            }
        }
        guard !closed else { throw GuestPeerError.closed }
        let pending = remoteICE; remoteICE.removeAll()
        for value in pending {
            try await add(value)
#if DEBUG
            if addedRemoteICECandidates < Int.max { addedRemoteICECandidates += 1 }
#endif
        }
    }
    private func add(_ value: LKRTCIceCandidate) async throws {
        guard !closed else { throw GuestPeerError.closed }
        let _: Void = try await guestAwait { done in
            self.connection.add(value) { error in done(error.map { .failure($0) } ?? .success(())) }
        }
        guard !closed else { throw GuestPeerError.closed }
    }

    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        Task { @MainActor [weak self] in
            guard let self else { return }
#if DEBUG
            defer { self.iceCandidateEventFinishedForTesting?() }
#endif
            guard !closed else { return }
#if DEBUG
            if generatedICECandidates < Int.max { generatedICECandidates += 1 }
#endif
            let value: [String: Any] = ["candidate": candidate.sdp, "sdpMLineIndex": candidate.sdpMLineIndex,
                "sdpMid": candidate.sdpMid ?? "0", "target": target.rawValue]
            do {
                if localSDPSent {
                    if let sendCandidate {
                        try await sendCandidate(value)
#if DEBUG
                        if sentLocalICECandidates < Int.max { sentLocalICECandidates += 1 }
#endif
                    }
                } else {
                    guard localICE.count < 256 else { throw GuestPeerError.candidateOverflow }; localICE.append(value)
#if DEBUG
                    if queuedLocalICECandidates < Int.max { queuedLocalICECandidates += 1 }
#endif
                }
            } catch { onFailure?(error) }
        }
    }
#if DEBUG
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didFailToGatherIceCandidate event: LKRTCIceCandidateErrorEvent) {
        // Deliberately copy only the numeric code. Do not retain/log the event,
        // which also contains server URL, local address and implementation text.
        let errorCode = event.errorCode
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.iceGatherEventFinishedForTesting?() }
            guard !closed else { return }
            if iceGatheringErrors < Int.max { iceGatheringErrors += 1 }
            if iceGatheringErrors <= maximumLoggedICEGatheringErrors {
                logICEDiagnostic("ice-gather-error", ["errorCode": errorCode])
            }
        }
    }

    private func logICEDiagnostic(_ event: String, _ fields: [String: Any]) {
        var fields = fields
        fields["peerID"] = diagnosticID
        fields["target"] = target.rawValue
        probeLog(event, fields)
        iceDiagnosticForTesting?(event, fields)
    }

    private func logICEFailureDiagnostics(reason: String, state: LKRTCIceConnectionState) {
        logICEDiagnostic("ice-failure-diagnostics", ["reason": reason, "state": state.rawValue,
            "generatedCandidates": generatedICECandidates,
            "queuedLocalCandidates": queuedLocalICECandidates,
            "sentLocalCandidates": sentLocalICECandidates,
            "receivedRemoteCandidates": receivedRemoteICECandidates,
            "bufferedRemoteCandidates": bufferedRemoteICECandidates,
            "addedRemoteCandidates": addedRemoteICECandidates,
            "pendingLocalCandidates": localICE.count, "pendingRemoteCandidates": remoteICE.count,
            "gatheringState": lastGatheringState.rawValue, "gatheringErrors": iceGatheringErrors,
            "gatheringErrorsLogged": min(iceGatheringErrors, maximumLoggedICEGatheringErrors)])
        // Request bounded, allowlisted native evidence without delaying recovery.
        let diagnosticID = diagnosticID, targetName = target.rawValue
        connection.statistics { report in
            let summary = Self.failedChecklistSummary(report.statistics.values.map { stat -> [String: Any] in
                var row: [String: Any] = ["type": stat.type, "id": stat.id]
                for key in ["state", "nominated", "writable", "requestsSent", "responsesReceived", "selectedCandidatePairId",
                            "protocol", "candidateType", "relayProtocol", "localCandidateId", "remoteCandidateId"] {
                    if let value = stat.values[key] { row[key] = value }
                }
                return row
            })
            probeLog("ice-failed-checklist", ["peerID": diagnosticID, "target": targetName,
                "reason": reason, "state": state.rawValue, "summary": summary])
        }
    }

    /// No candidate strings, addresses, server URLs or credentials leave this
    /// allowlist. Counts remain complete; individual pairs are bounded.
    nonisolated static func failedChecklistSummary(_ stats: [[String: Any]]) -> [String: Any] {
        let pairs = stats.filter { $0["type"] as? String == "candidate-pair" }
        let candidates = stats.filter { $0["type"] as? String == "local-candidate" || $0["type"] as? String == "remote-candidate" }
        var byID: [String: [String: Any]] = [:]
        for candidate in candidates { if let id = candidate["id"] as? String { byID[id] = candidate } }
        let selected = Set(stats.filter { $0["type"] as? String == "transport" }
            .compactMap { $0["selectedCandidatePairId"] as? String })
        func tag(_ value: Any?, allowed: Set<String>) -> String {
            guard let value = value as? String, allowed.contains(value) else { return "other" }
            return value
        }
        func count(_ value: Any?) -> Int {
            let number = (value as? NSNumber)?.intValue ?? (value as? Int) ?? 0
            return max(0, min(number, 1_000_000_000))
        }
        let states: Set<String> = ["frozen", "waiting", "in-progress", "failed", "succeeded"]
        let types: Set<String> = ["host", "srflx", "prflx", "relay"]
        let protocols: Set<String> = ["udp", "tcp"]
        let relayProtocols: Set<String> = ["udp", "tcp", "tls"]
        let details = pairs.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }.prefix(16).map { pair -> [String: Any] in
            let local = byID[pair["localCandidateId"] as? String ?? ""] ?? [:]
            let remote = byID[pair["remoteCandidateId"] as? String ?? ""] ?? [:]
            return ["state": tag(pair["state"], allowed: states),
                    "selected": selected.contains(pair["id"] as? String ?? ""),
                    "nominated": pair["nominated"] as? Bool ?? false,
                    "writable": pair["writable"] as? Bool ?? false,
                    "requestsSent": count(pair["requestsSent"]),
                    "responsesReceived": count(pair["responsesReceived"]),
                    "localType": tag(local["candidateType"], allowed: types),
                    "localProtocol": tag(local["protocol"], allowed: protocols),
                    "localRelayProtocol": tag(local["relayProtocol"], allowed: relayProtocols),
                    "remoteType": tag(remote["candidateType"], allowed: types),
                    "remoteProtocol": tag(remote["protocol"], allowed: protocols)]
        }
        // WebRTC reports remote-candidate stats only for formed candidate
        // pairs. This is not a count of candidates received through signaling.
        return ["pairCount": pairs.count, "recordedPairs": details.count,
                "localCandidateStats": candidates.filter { $0["type"] as? String == "local-candidate" }.count,
                "pairedRemoteCandidateStats": candidates.filter { $0["type"] as? String == "remote-candidate" }.count,
                "pairs": Array(details)]
    }
#endif

    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didAdd receiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        Task { @MainActor [weak self] in
            guard let self, !closed else { return }
#if DEBUG
            defer { self.receiverEventFinishedForTesting?() }
#endif
            // receiver.track returns a new wrapper on each read. isEqual compares
            // native track identity, including when callbacks repeat on reconnect.
            if let track = receiver.track as? LKRTCVideoTrack {
                let streamIDs = streams.map(\.streamId)
                if let index = incomingVideo.firstIndex(where: { $0.video.track.isEqual(track) }) {
                    // Unified Plan may reuse the receiver when a publication is replaced.
                    if incomingVideo[index].video.streamIDs != streamIDs {
                        incomingVideo[index].video.streamIDs = streamIDs
                        onIncomingVideoChange?(receivedVideo)
                    }
                } else {
                    let sink = GuestTrackRenderer(counter: renderer)
                    incomingVideo.append((GuestRemoteVideo(id: UUID().uuidString, track: track,
                        streamIDs: streamIDs), sink)); track.add(sink)
                    onIncomingVideoChange?(receivedVideo)
#if DEBUG
                    receiverAttachmentsForTesting += 1
#endif
                }
            }
            if let track = receiver.track as? LKRTCAudioTrack, !incomingAudio.contains(where: { $0.isEqual(track) }) {
                incomingAudio.append(track); track.add(pcmMeter)
#if DEBUG
                receiverAttachmentsForTesting += 1
#endif
            }
            probeLog("remote-track", ["target": target.rawValue, "kind": receiver.track?.kind ?? "unknown"])
        }
    }
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didRemove receiver: LKRTCRtpReceiver) {
        Task { @MainActor [weak self] in
            guard let self, !closed else { return }
#if DEBUG
            defer { self.receiverEventFinishedForTesting?() }
#endif
            guard let track = receiver.track else { return }
            if let index = incomingVideo.firstIndex(where: { $0.video.track.isEqual(track) }) {
                let removed = incomingVideo.remove(at: index)
                removed.sink.stop(); removed.video.track.remove(removed.sink)
                onIncomingVideoChange?(receivedVideo)
#if DEBUG
                receiverDetachmentsForTesting += 1
#endif
            }
            if let index = incomingAudio.firstIndex(where: { $0.isEqual(track) }) {
                incomingAudio.remove(at: index).remove(pcmMeter)
#if DEBUG
                receiverDetachmentsForTesting += 1
#endif
            }
        }
    }
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ pc: LKRTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, !closed else { return }
#if DEBUG
            defer { self.iceEventFinishedForTesting?() }
#endif
            guard newState != lastICEState else { return }
            lastICEState = newState
            iceConnected = newState == .connected || newState == .completed
            iceTimeout?.cancel(); iceTimeout = nil
            if newState == .checking || newState == .disconnected {
                let delay: UInt64 = newState == .checking ? 10_000_000_000 : 5_000_000_000
#if DEBUG
                let testWait = iceWaitForTesting
#endif
                iceTimeout = Task { [weak self] in
#if DEBUG
                    defer { self?.iceTimerFinishedForTesting?() }
#endif
                    do {
#if DEBUG
                        if let testWait { try await testWait(delay) }
                        else { try await Task.sleep(nanoseconds: delay) }
#else
                        try await Task.sleep(nanoseconds: delay)
#endif
                    } catch { return }
                    guard !Task.isCancelled, let self, !closed, !iceConnected, lastICEState == newState else { return }
                    probeLog("ice-timeout", ["target": target.rawValue, "state": newState.rawValue])
#if DEBUG
                    logICEFailureDiagnostics(reason: "deadline", state: newState)
#endif
                    onFailure?(GuestPeerError.iceFailed)
                }
            }
            probeLog("ice-state", ["target": target.rawValue, "state": newState.rawValue])
#if DEBUG
            if newState == .failed {
                logICEFailureDiagnostics(reason: "native-failed", state: newState)
            }
#endif
            if newState == .failed || newState == .closed { onFailure?(GuestPeerError.iceFailed) }
        }
    }
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
#if DEBUG
        Task { @MainActor [weak self] in
            guard let self, !closed, newState != lastGatheringState else { return }
            lastGatheringState = newState
            logICEDiagnostic("ice-gathering-state", ["state": newState.rawValue])
        }
#endif
    }
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
}

/// One timestamp epoch per native track; stopped sinks reject queued old callbacks.
final class GuestTrackRenderer: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private let counter: GuestFrameCounter
    private let sourceID = UUID()
    private var active = true
    init(counter: GuestFrameCounter) { self.counter = counter; super.init() }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        counter.renderFrame(frame, sourceID: sourceID)
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        active = false; counter.endSource(sourceID)
    }
}

final class GuestFrameCounter: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private let verifyPixels: Bool
    init(verifyPixels: Bool = true) { self.verifyPixels = verifyPixels; super.init() }
    private var frames = 0, advancing = 0, changes = 0
    private let defaultSourceID = UUID()
    private var lastTimestamps: [UUID: Int64] = [:]
    private var lastDigest: UInt64 = 0
    private var lastArrival: Double = 0, longestGap: Double = 0
    private var timeline = GuestFrameTimeline()
    func window(from start: Double, to end: Double) -> GuestFrameWindow {
        lock.lock(); defer { lock.unlock() }
        return timeline.measure(from: start, to: end)
    }
    private var size = CGSize.zero
    private var latest: LKRTCVideoFrame?
    var evidence: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["frames": frames, "advancingFrames": advancing, "pixelChanges": changes,
            "width": size.width, "height": size.height,
            "lastFrameAge": lastArrival > 0 ? ProcessInfo.processInfo.systemUptime - lastArrival : -1,
            "longestFrameGap": longestGap, "pixelVerification": verifyPixels]
    }
    /// Explicit snapshot conversion and file I/O run outside the render callback.
    func savePNG(_ path: String) throws {
        lock.lock(); let frame = latest; lock.unlock()
        guard let frame else { throw GuestEngineError.mediaMissing }
        // Use the same range/matrix-preserving conversion as the companion view.
        // Each explicit snapshot owns its converter; concurrent snapshots share
        // no pool. Optional receive pixel digests keep their existing behavior.
        guard let buffer = NativeVideoPixelBuffer().convert(frame) else { throw GuestPeerError.malformed }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace,
                                          .cacheIntermediates: false])
        let input = CIImage(cvPixelBuffer: buffer)
        guard let cg = context.createCGImage(input, from: input.extent, format: .RGBA8, colorSpace: colorSpace),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw GuestPeerError.malformed }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw GuestPeerError.malformed }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        probeLog("receiver-image-saved", ["width": width, "height": height, "rotation": frame.rotation.rawValue])
    }
    func setSize(_ size: CGSize) {}
    func endSource(_ sourceID: UUID) {
        lock.lock(); defer { lock.unlock() }
        lastTimestamps.removeValue(forKey: sourceID)
    }
    func renderFrame(_ frame: LKRTCVideoFrame?) { renderFrame(frame, sourceID: defaultSourceID) }
    func renderFrame(_ frame: LKRTCVideoFrame?, sourceID: UUID) {
        guard let frame else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var digest: UInt64?
        if verifyPixels {
            let i420 = frame.buffer.toI420()
            var value: UInt64 = 1469598103934665603
            for y in stride(from: 0, to: Int(i420.height), by: 24) {
                for x in stride(from: 0, to: Int(i420.width), by: 24) {
                    value = (value ^ UInt64(i420.dataY[y * Int(i420.strideY) + x])) &* 1099511628211
                }
            }
            digest = value
        }
        lock.lock(); defer { lock.unlock() }
        if frame.timeStampNs > (lastTimestamps[sourceID] ?? -1) {
            lastTimestamps[sourceID] = frame.timeStampNs
            advancing += 1
            if lastArrival > 0 { longestGap = max(longestGap, now - lastArrival) }
            lastArrival = now; timeline.record(now)
        }
        latest = frame
        frames += 1
        if let digest {
            if frames > 1 && digest != lastDigest { changes += 1 }; lastDigest = digest
        }
        size = CGSize(width: Int(frame.width), height: Int(frame.height))
    }
}
