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

/// Owns one guest PC. All signaling operations are driven by the MainActor engine;
/// every call into the native objects runs on `native`, never on the main thread.
@MainActor
final class GuestPeer: NSObject, LKRTCPeerConnectionDelegate {
    static var diagnosticEventLogDirectory: URL?
    let diagnosticID = UUID().uuidString
    let target: GuestPeerTarget
    let factory: LKRTCPeerConnectionFactory
    let native: GuestNativeCalls
    private(set) var connection: LKRTCPeerConnection!
    let renderer: GuestFrameCounter
    let pcmMeter = GuestPCMMeter()
    private let physicalAudio: Bool
    private let icePolicy: GuestICEPolicy
    private var incomingAudio: [(track: LKRTCAudioTrack, source: GuestStartupPlaybackGain.Source)] = []
    nonisolated private let startupPlaybackGain: GuestStartupPlaybackGain?
    var onIncomingAudioChange: (() -> Void)?
    /// Remote audio tracks with their stream metadata (local transcription taps them).
    var incomingAudioTracks: [(track: LKRTCAudioTrack, source: GuestStartupPlaybackGain.Source)] { incomingAudio }
    private var iceTimeout: Task<Void, Never>?
    private var lastICEState: LKRTCIceConnectionState = .new
    private var activeIncomingMediaDemand = false
    // Initial trickle failure may precede a relay connection. Real demand owns
    // one deadline across checking/failed transitions and demand churn.
    private var hasEstablishedConnection = false
    private var initialRequiredDeadline: TimeInterval?
    private var initialExpiryReported = false
    var sendCandidate: (([String: Any]) async throws -> Void)?
    var onFailure: ((Error) -> Void)?
    private var remoteICE: [LKRTCIceCandidate] = []
    private var localICE: [[String: Any]] = []
    private var localSDPSent = false
    private var closed = false
    private(set) var iceConnected = false
    private(set) var transportConnected = false
    private var incomingVideo: [(video: GuestRemoteVideo, sink: GuestTrackRenderer)] = []
    var onIncomingVideoChange: (([GuestRemoteVideo]) -> Void)? {
        didSet { onIncomingVideoChange?(receivedVideo) }
    }
    var receivedVideo: [GuestRemoteVideo] { incomingVideo.map(\.video) }
    var receivedAudioSources: [GuestStartupPlaybackGain.Source] { incomingAudio.map { $0.source } }
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
    // ICE evidence for diagnostics (counts and types only; release builds log it on stalls).
    private var generatedICECandidates = 0
    private var queuedLocalICECandidates = 0
    private var sentLocalICECandidates = 0
    private var receivedRemoteICECandidates = 0
    private var bufferedRemoteICECandidates = 0
    private var addedRemoteICECandidates = 0
    private var iceGatheringErrors = 0
    private var lastGatheringState = LKRTCIceGatheringState.new
    private let maximumLoggedICEGatheringErrors = 32
    /// Candidate kinds in the last remote description ("host/udp": 2, ...), no addresses.
    private var remoteDescriptionCandidates: [String: Int] = [:]
    private var stallDiagnosticsLogged = false
    /// The ICE transport policy this peer set to relay (the native configuration is not read on main).
    private var relayOnlyConfigured = false
    /// The subscriber never connected before its deadline (receive path stalled).
    var onInitialStall: (() -> Void)?
#if DEBUG
    var iceDiagnosticForTesting: ((String, [String: Any]) -> Void)?
    var iceCandidateEventFinishedForTesting: (() -> Void)?
    var iceGatherEventFinishedForTesting: (() -> Void)?
    var iceWaitForTesting: ((UInt64) async throws -> Void)?
    var iceClockForTesting: (() -> TimeInterval)?
    var transportEventFinishedForTesting: (() -> Void)?
    var iceEventFinishedForTesting: (() -> Void)?
    var iceTimerFinishedForTesting: (() -> Void)?
    private(set) var videoEnableCallsForTesting = 0
    private(set) var receiverAttachmentsForTesting = 0
    private(set) var receiverDetachmentsForTesting = 0
    var receiverEventFinishedForTesting: (() -> Void)?
    var retainedReceiverTracksForTesting: Int { incomingVideo.count + incomingAudio.count }
    struct SoundOffSourceProof {
        let trackID: String
        let gain: @MainActor () -> Double?
        let restore: @MainActor () -> Bool
    }
    func beginSoundOffSourceProofForTesting() -> SoundOffSourceProof? {
        guard !closed, target == .subscriber, physicalAudio, incomingAudio.count == 1 else { return nil }
        let track = incomingAudio[0].track
        track.source.volume = 1
        guard track.source.volume == 1 else { track.source.volume = 0; return nil }
        return .init(trackID: track.trackId, gain: { [weak self, track] in
            guard let self, !self.closed, self.incomingAudio.count == 1,
                  self.incomingAudio[0].track.isEqual(track) else { return nil }
            return track.source.volume
        }, restore: {
            track.source.volume = 0
            return track.source.volume == 0
        })
    }
#endif

    init(target: GuestPeerTarget, factory: LKRTCPeerConnectionFactory, physicalAudio: Bool = false, icePolicy: GuestICEPolicy = .automatic, verifyReceivedPixels: Bool = true,
         startupPlaybackGain: GuestStartupPlaybackGain? = nil) throws {
        self.target = target; self.factory = factory; self.physicalAudio = physicalAudio; self.icePolicy = icePolicy
        self.startupPlaybackGain = startupPlaybackGain
        renderer = GuestFrameCounter(verifyPixels: verifyReceivedPixels)
        native = GuestNativeCalls(label: target.rawValue.lowercased())
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

    func configure(_ value: [String: Any]) async throws {
        guard !closed else { throw GuestPeerError.closed }
        let icePolicy = self.icePolicy.forTarget(target)
        let advertised = value["iceServers"] as? [[String: Any]] ?? []
        let servers = try icePolicy.servers(advertised)
        let replaceServers = value["iceServers"] is [[String: Any]] || icePolicy != .automatic
        let relay = icePolicy.relayOnly(advertised) || value["iceTransportPolicy"] as? String == "relay"
        let connection = connection!
        let applied = try await native.run("set-configuration") { () -> Bool in
            let config = connection.configuration
            if replaceServers {
                config.iceServers = servers.compactMap { server in
                    let urls = server["urls"] as? [String] ?? (server["urls"] as? String).map { [$0] } ?? []
                    guard !urls.isEmpty else { return nil }
                    return LKRTCIceServer(urlStrings: urls, username: server["username"] as? String,
                        credential: server["credential"] as? String)
                }
            }
            if relay { config.iceTransportPolicy = .relay }
            return connection.setConfiguration(config)
        }
        guard applied else { throw GuestPeerError.malformed }
        if relay { relayOnlyConfigured = true }
    }

    /// The active configuration, read on the native queue (tests and diagnostics).
    func currentConfiguration() async throws -> LKRTCConfiguration {
        let connection = connection!
        return try await native.run("configuration") { connection.configuration }
    }

    func answer(_ description: [String: Any]) async throws -> [String: Any] {
        guard let sdp = description["sdp"] as? String, sdp.utf8.count < 1_000_000 else { throw GuestPeerError.malformed }
        localSDPSent = false
        remoteDescriptionCandidates = Self.candidateKinds(sdp)
        try await setRemote(.init(type: .offer, sdp: sdp))
        let answer = try await descriptionForOffer(false)
        try await setLocal(answer)
        probeLog("video-negotiation", ["target": target.rawValue, "remote": GuestSDPSummary.video(sdp), "local": GuestSDPSummary.video(answer.sdp)])
        return ["type": "answer", "sdp": answer.sdp]
    }

    func acceptAnswer(_ description: [String: Any]) async throws {
        guard let sdp = description["sdp"] as? String, sdp.utf8.count < 1_000_000 else { throw GuestPeerError.malformed }
        remoteDescriptionCandidates = Self.candidateKinds(sdp)
        try await setRemote(.init(type: .answer, sdp: sdp))
        let connection = connection!
        let local = (try? await native.run("local-description") { connection.localDescription?.sdp }) ?? nil
        probeLog("video-negotiation", ["target": target.rawValue, "remote": GuestSDPSummary.video(sdp), "local": GuestSDPSummary.video(local ?? "")])
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
                if sentLocalICECandidates < Int.max { sentLocalICECandidates += 1 }
            }
        }
    }

    func addCandidates(_ values: [[String: Any]]) async throws {
        for value in values where value["target"] as? String == target.rawValue {
            guard !closed else { throw GuestPeerError.closed }
            guard let sdp = value["candidate"] as? String, sdp.utf8.count < 16_384 else { throw GuestPeerError.malformed }
            if receivedRemoteICECandidates < Int.max { receivedRemoteICECandidates += 1 }
            let candidate = LKRTCIceCandidate(sdp: sdp,
                sdpMLineIndex: (value["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0,
                sdpMid: value["sdpMid"] as? String)
            let connection = connection!
            let hasRemoteDescription = try await native.run("has-remote-description") { connection.remoteDescription != nil }
            guard !closed else { throw GuestPeerError.closed }
            if !hasRemoteDescription {
                guard remoteICE.count < 256 else { throw GuestPeerError.candidateOverflow }
                remoteICE.append(candidate)
                if bufferedRemoteICECandidates < Int.max { bufferedRemoteICECandidates += 1 }
            } else {
                try await add(candidate)
                if addedRemoteICECandidates < Int.max { addedRemoteICECandidates += 1 }
            }
        }
    }

    func prepareAudio(cid: String, profile: GuestAudioProfile = .speech) async throws -> LKRTCAudioTrack {
        let constraints = physicalAudio ? profile.audioConstraints : [
            "googEchoCancellation": "false", "googNoiseSuppression": "false", "googAutoGainControl": "false"]
        let factory = factory
        return try await native.run("prepare-audio") {
            let source = factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: constraints, optionalConstraints: nil))
            // WebRTC creates tracks enabled. Disable before anyone can attach it, so a
            // microphone track never sends until an unmute enables it.
            let track = factory.audioTrack(with: source, trackId: cid)
            track.isEnabled = false
            return track
        }
    }

    /// `enabled: false` returns the track already disabled, before anyone can attach it.
    func prepareVideo(cid: String, profile: GuestVideoProfile = .pattern, screenCast: Bool = false,
                      enabled: Bool = true) async throws -> LKRTCVideoTrack {
        videoProfile = profile
        let factory = factory
        let (source, track) = try await native.run("prepare-video") { () -> (LKRTCVideoSource, LKRTCVideoTrack) in
            let source = screenCast ? factory.videoSource(forScreenCast: true) : factory.videoSource()
            source.adaptOutputFormat(toWidth: profile.width, height: profile.height, fps: profile.fps)
            let track = factory.videoTrack(with: source, trackId: cid)
            if !enabled { track.isEnabled = false }
            return (source, track)
        }
        self.source = source
        return track
    }

    func prepareScreenVideo(cid: String, profile: GuestVideoProfile) async throws -> LKRTCVideoTrack {
        let factory = factory
        let (source, track) = try await native.run("prepare-screen-video") { () -> (LKRTCVideoSource, LKRTCVideoTrack) in
            let source = factory.videoSource(forScreenCast: true)
            source.adaptOutputFormat(toWidth: profile.width, height: profile.height, fps: profile.fps)
            let track = factory.videoTrack(with: source, trackId: cid)
            track.isEnabled = false
            return (source, track)
        }
        screenSource = source; screenProfile = profile
        return track
    }

    func updateScreenProfile(_ profile: GuestVideoProfile) {
        screenProfile = profile
        let source = screenSource, sender = screenSender
        native.post("update-screen-profile") {
            source?.adaptOutputFormat(toWidth: profile.width, height: profile.height, fps: profile.fps)
            guard let sender else { return }
            let parameters = sender.parameters
            parameters.encodings.forEach {
                $0.maxBitrateBps = NSNumber(value: profile.maximumBitrate)
                $0.maxFramerate = NSNumber(value: profile.fps)
            }
            sender.parameters = parameters
        }
    }

    func attachScreenVideo(_ track: LKRTCVideoTrack, codec: String) async throws {
        guard !closed, screenSender == nil else { throw GuestPeerError.closed }
        let factory = factory, connection = connection!, encoding = screenProfile.encoding()
        let sender = try await native.run("attach-screen-video") { () -> LKRTCRtpSender in
            let capabilities = factory.rtpSenderCapabilities(forKind: "video").codecs
            let matches = capabilities.filter { $0.name.lowercased() == codec.lowercased() }
            guard !matches.isEmpty else { throw GuestPeerError.unsupportedCodec }
            let config = LKRTCRtpTransceiverInit(); config.direction = .sendOnly
            config.sendEncodings = [encoding]
            guard let transceiver = connection.addTransceiver(with: track, init: config) else { throw GuestPeerError.malformed }
            try transceiver.setCodecPreferences(matches + capabilities.filter { $0.name.lowercased() == "rtx" }, error: ())
            if codec.lowercased() == "h264" {
                let parameters = transceiver.sender.parameters
                parameters.degradationPreference = NSNumber(value: LKRTCDegradationPreference.maintainResolution.rawValue)
                transceiver.sender.parameters = parameters
            }
            return transceiver.sender
        }
        guard !closed else { throw GuestPeerError.closed }
        screenTrack = track; screenSender = sender
    }

    func setScreenMuted(_ muted: Bool) async throws {
        guard !closed, let screenSender, let screenTrack else { throw GuestPeerError.closed }
        try await native.run(muted ? "mute-screen" : "unmute-screen") {
            try Self.setSending(!muted, track: screenTrack, sender: screenSender)
        }
    }

    /// Stops or starts one sender's RTP. Muting stops the track before the
    /// encodings; unmuting activates the encodings first. Native queue only.
    nonisolated private static func setSending(_ sending: Bool, track: LKRTCVideoTrack, sender: LKRTCRtpSender) throws {
        if !sending { track.isEnabled = false }
        let parameters = sender.parameters
        guard !parameters.encodings.isEmpty else { throw GuestPeerError.malformed }
        parameters.encodings.forEach { $0.isActive = sending }
        if sending { track.isEnabled = true }
        sender.parameters = parameters
        guard sender.parameters.encodings.allSatisfy({ $0.isActive == sending }) else {
            track.isEnabled = false
            throw GuestPeerError.malformed
        }
    }

    /// Synchronous privacy barrier: queued ahead of any later native call.
    func suppressScreenVideo() {
        let track = screenTrack, sender = screenSender
        native.post("suppress-screen") {
            track?.isEnabled = false
            if let track, let sender { try? Self.setSending(false, track: track, sender: sender) }
        }
    }

    @discardableResult func removeScreenVideo() async throws -> Bool {
        suppressScreenVideo()
        guard let screenSender else { screenSource = nil; screenTrack = nil; return false }
        guard !closed else { throw GuestPeerError.closed }
        let connection = connection!
        let removed = try await native.run("remove-screen-video") { connection.removeTrack(screenSender) }
        guard !closed, removed else { throw GuestPeerError.closed }
        self.screenSender = nil; screenTrack = nil; screenSource = nil
        return true
    }

    func waitForStableSignaling() async throws {
        let connection = connection!
        for _ in 0..<100 {
            try Task.checkCancellation()
            guard !closed else { throw GuestPeerError.closed }
            let state = try await native.run("signaling-state") { connection.signalingState }
            guard !closed, state != .closed else { throw GuestPeerError.closed }
            if state == .stable { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw GuestTransportError.timedOut
    }

    func attach(_ track: LKRTCMediaStreamTrack, codec: String) async throws {
        guard !closed else { throw GuestPeerError.closed }
        let factory = factory, connection = connection!, encoding = videoProfile.encoding()
        let (video, sender) = try await native.run("attach") { () -> (Bool, LKRTCRtpSender) in
            let video = track.kind == "video"
            let config = LKRTCRtpTransceiverInit(); config.direction = .sendOnly
            if video { config.sendEncodings = [encoding] }
            guard let transceiver = connection.addTransceiver(with: track, init: config) else { throw GuestPeerError.malformed }
            if video {
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
            }
            return (video, transceiver.sender)
        }
        guard !closed else { throw GuestPeerError.closed }
        if video {
            videoTrack = track as? LKRTCVideoTrack
            videoSender = sender
        } else { audioTrack = track as? LKRTCAudioTrack }
    }

    func setMuted(_ mute: Bool, video: Bool) async throws {
#if DEBUG
        if !mute && video { videoEnableCallsForTesting += 1 }
#endif
        guard !closed else { throw GuestPeerError.closed }
        if video {
            guard let videoSender, let videoTrack else { throw GuestPeerError.malformed }
            // Stop RTP before advertising mute. Reactivation reinitializes the
            // encoder layer, producing an independently decodable resume frame.
            try await native.run(mute ? "mute-video" : "unmute-video") {
                try Self.setSending(!mute, track: videoTrack, sender: videoSender)
            }
        } else {
            let track = audioTrack
            try await native.run(mute ? "mute-audio" : "unmute-audio") { track?.isEnabled = !mute }
        }
    }

    /// Synchronous privacy barrier: queued ahead of any later native call,
    /// so a pending unmute that completes late is turned off again.
    func suppress(video: Bool) {
        if video {
            let track = videoTrack, sender = videoSender
            native.post("suppress-video") {
                track?.isEnabled = false
                if let track, let sender { try? Self.setSending(false, track: track, sender: sender) }
            }
        } else {
            let track = audioTrack
            native.post("suppress-audio") { track?.isEnabled = false }
        }
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

    func localVideoState() async -> [String: Any] {
        var state: [String: Any] = ["generatedFrames": generatedFrames, "generatedLastUptime": generatedLastUptime,
                                    "registeredProfile": videoProfile.layer]
        guard !closed else { return state }
        let track = videoTrack, sender = videoSender, connection = connection!
        let native = try? await self.native.run("local-video-state", timeout: 3) { () -> [String: Any] in
            let parameters = sender?.parameters
            return ["enabled": track?.isEnabled ?? false, "encodingActive": parameters?.encodings.map(\.isActive) ?? [],
                    "negotiatedCodecs": parameters?.codecs.map(\.name) ?? [],
                    "encodingMaximumBitrates": parameters?.encodings.map { $0.maxBitrateBps?.intValue ?? -1 } ?? [],
                    "encodingMaximumFrameRates": parameters?.encodings.map { $0.maxFramerate?.intValue ?? -1 } ?? [],
                    "localSDPVideoCodecs": Self.videoCodecNames(connection.localDescription?.sdp),
                    "remoteSDPVideoCodecs": Self.videoCodecNames(connection.remoteDescription?.sdp)]
        }
        state.merge(native ?? ["nativeStateUnavailable": true]) { _, value in value }
        return state
    }

#if DEBUG
    /// Scalar correlation only: this must never query a native track or sender.
    var videoTraceStateForTesting: [String: Any] {
        ["peerID": diagnosticID, "target": target.rawValue, "generatedFrames": generatedFrames,
         "generatedLastUptime": generatedLastUptime, "transportConnected": transportConnected, "closed": closed,
         "receiverAttachments": receiverAttachmentsForTesting, "receiverDetachments": receiverDetachmentsForTesting,
         "retainedVideoReceivers": incomingVideo.count, "videoEnableCalls": videoEnableCallsForTesting]
    }
#endif

    /// Sanitized formal SDP metadata only; never emit descriptions, ICE or addresses.
    nonisolated private static func videoCodecNames(_ sdp: String?) -> [String] {
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
        let connection = connection!
        guard let report: LKRTCStatisticsReport = try? await native.call("statistics", timeout: 3, { done in
            connection.statistics { done(.success($0)) }
        }) else { return nil }
        var keys = ["kind", "mid", "bytesReceived", "bytesSent", "packetsReceived", "packetsSent",
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
#if DEBUG
        // RTCP report progress distinguishes a fresh downstream observation from
        // an old cumulative loss value. Unsupported fields remain absent.
        keys += ["localId", "remoteId", "ssrc", "reportsReceived", "roundTripTimeMeasurements",
            "state", "nominated", "writable", "requestsSent", "responsesReceived", "totalRoundTripTime"]
#endif
        let selectedPairs = Set(report.statistics.values.filter { $0.type == "transport" }
            .compactMap { $0.values["selectedCandidatePairId"] as? String })
        let candidateIDs = Set(report.statistics.values.filter { selectedPairs.contains($0.id) }
            .flatMap { [$0.values["localCandidateId"] as? String, $0.values["remoteCandidateId"] as? String].compactMap { $0 } })
        return report.statistics.values.filter {
            ["inbound-rtp", "outbound-rtp", "remote-inbound-rtp", "codec", "media-source", "transport"].contains($0.type) ||
            selectedPairs.contains($0.id) || candidateIDs.contains($0.id)
        }.map { stat in
            var value: [String: Any] = ["target": target.rawValue, "type": stat.type, "id": stat.id, "sampleUptime": ProcessInfo.processInfo.systemUptime, "nativeTimestampUS": stat.timestamp_us]
#if DEBUG
            value["peerID"] = diagnosticID
            if stat.values["candidateType"] as? String == "relay" {
                // These identify the allocated relay socket, not the TURN server.
                if let address = stat.values["address"] as? String, address.utf8.count <= 255,
                   !address.contains(where: { $0.isWhitespace }) { value["relayAllocationAddress"] = address }
                if let port = stat.values["port"] as? NSNumber, (1...65_535).contains(port.intValue),
                   port.doubleValue == Double(port.intValue) { value["relayAllocationPort"] = port }
            }
            if stat.type == "local-candidate" {
                value["turnServerEndpoint"] = (stat.values["url"] as? String)
                    .flatMap(GuestICEPolicy.diagnosticTurnServer).map { $0 as Any } ?? NSNull()
            }
#endif
            for key in keys { if let item = stat.values[key] { value[key] = item } }
            return value
        }
    }

    /// An idle subscriber may remain checking until the SFU has media to send.
    /// Muted subscriptions retained for warm resumption are not active demand.
    func setActiveIncomingMediaDemand(_ active: Bool) {
        guard target == .subscriber, !closed, activeIncomingMediaDemand != active else { return }
        activeIncomingMediaDemand = active
        if active, !hasEstablishedConnection, initialRequiredDeadline == nil { initialRequiredDeadline = iceNow() + 10 }
        if lastICEState == .checking || lastICEState == .failed { refreshICETimeout() }
        probeLog("ice-incoming-demand", ["target": target.rawValue, "active": active])
    }

    func close() {
        guard !closed else { return }; closed = true
#if DEBUG
        probeLog("video-peer-close", ["peerID": diagnosticID, "target": target.rawValue,
            "videoReceivers": incomingVideo.count, "audioReceivers": incomingAudio.count])
#endif
        transportConnected = false
        patternTask?.cancel(); patternTask = nil
        iceTimeout?.cancel(); iceTimeout = nil
        // Sinks stop at once; native detach and close are queued in order and never
        // wait on WebRTC threads here (they can be stuck behind the audio device).
        let tracks: [LKRTCMediaStreamTrack?] = [audioTrack, videoTrack, screenTrack]
        let videoSinks = incomingVideo.map { ($0.video.track, $0.sink) }
        let audioTracks = incomingAudio.map(\.track), meter = pcmMeter
        incomingVideo.forEach { $0.sink.stop() }; incomingVideo.removeAll()
        onIncomingVideoChange?([]); onIncomingVideoChange = nil
        incomingAudio.removeAll()
        onIncomingAudioChange = nil
        localICE.removeAll(); remoteICE.removeAll(); sendCandidate = nil
        let connection = connection!
        native.post("close") {
            tracks.forEach { $0?.isEnabled = false }
            videoSinks.forEach { track, sink in track.remove(sink) }
            audioTracks.forEach { $0.remove(meter) }
            connection.stopRtcEventLog()
            connection.close(); connection.delegate = nil
        }
        audioTrack = nil; videoTrack = nil; videoSender = nil; source = nil
        screenTrack = nil; screenSender = nil; screenSource = nil
    }

    private func descriptionForOffer(_ offer: Bool) async throws -> LKRTCSessionDescription {
        guard !closed else { throw GuestPeerError.closed }
        let connection = connection!
        let result: LKRTCSessionDescription = try await native.call(offer ? "create-offer" : "create-answer") { done in
            let completion: @Sendable (LKRTCSessionDescription?, Error?) -> Void = { value, error in
                if let error { done(.failure(error)) }
                else if let value { done(.success(value)) }
                else { done(.failure(GuestPeerError.malformed)) }
            }
            let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            if offer { connection.offer(for: constraints, completionHandler: completion) }
            else { connection.answer(for: constraints, completionHandler: completion) }
        }
        guard !closed else { throw GuestPeerError.closed }
        return result
    }
    private func setLocal(_ value: LKRTCSessionDescription) async throws {
        guard !closed else { throw GuestPeerError.closed }
        let connection = connection!
        let _: Void = try await native.call("set-local-description") { done in
            connection.setLocalDescription(value) { error in
                done(error.map { .failure($0) } ?? .success(()))
            }
        }
        guard !closed else { throw GuestPeerError.closed }
    }
    private func setRemote(_ value: LKRTCSessionDescription) async throws {
        guard !closed else { throw GuestPeerError.closed }
        let connection = connection!
        let _: Void = try await native.call("set-remote-description") { done in
            connection.setRemoteDescription(value) { error in
                done(error.map { .failure($0) } ?? .success(()))
            }
        }
        guard !closed else { throw GuestPeerError.closed }
        let pending = remoteICE; remoteICE.removeAll()
        for value in pending {
            try await add(value)
            if addedRemoteICECandidates < Int.max { addedRemoteICECandidates += 1 }
        }
    }
    private func add(_ value: LKRTCIceCandidate) async throws {
        guard !closed else { throw GuestPeerError.closed }
        let connection = connection!
        let _: Void = try await native.call("add-candidate") { done in
            connection.add(value) { error in done(error.map { .failure($0) } ?? .success(())) }
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
            if generatedICECandidates < Int.max { generatedICECandidates += 1 }
            let value: [String: Any] = ["candidate": candidate.sdp, "sdpMLineIndex": candidate.sdpMLineIndex,
                "sdpMid": candidate.sdpMid ?? "0", "target": target.rawValue]
            do {
                if localSDPSent {
                    if let sendCandidate {
                        try await sendCandidate(value)
                        if sentLocalICECandidates < Int.max { sentLocalICECandidates += 1 }
                    }
                } else {
                    guard localICE.count < 256 else { throw GuestPeerError.candidateOverflow }; localICE.append(value)
                    if queuedLocalICECandidates < Int.max { queuedLocalICECandidates += 1 }
                }
            } catch { onFailure?(error) }
        }
    }
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didFailToGatherIceCandidate event: LKRTCIceCandidateErrorEvent) {
        // Deliberately copy only the numeric code. Do not retain/log the event,
        // which also contains server URL, local address and implementation text.
        let errorCode = event.errorCode
        Task { @MainActor [weak self] in
            guard let self else { return }
#if DEBUG
            defer { self.iceGatherEventFinishedForTesting?() }
#endif
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
#if DEBUG
        iceDiagnosticForTesting?(event, fields)
#endif
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
            "gatheringErrorsLogged": min(iceGatheringErrors, maximumLoggedICEGatheringErrors),
            "policy": icePolicy.forTarget(target).rawValue, "relayOnly": relayOnlyConfigured,
            "remoteDescriptionCandidates": remoteDescriptionCandidates])
        // Request bounded, allowlisted native evidence without delaying recovery.
        let diagnosticID = diagnosticID, targetName = target.rawValue, connection = connection!
        native.post("ice-failure-statistics") {
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

    /// Candidate kinds in an SDP ("host/udp" -> count). Types and protocols only.
    nonisolated static func candidateKinds(_ sdp: String) -> [String: Int] {
        let types: Set<String> = ["host", "srflx", "prflx", "relay"]
        var kinds: [String: Int] = [:]
        for line in sdp.split(whereSeparator: \.isNewline) where line.hasPrefix("a=candidate:") {
            let fields = line.split(separator: " ")
            guard fields.count > 7 else { kinds["other", default: 0] += 1; continue }
            let proto = fields[2].lowercased() == "tcp" ? "tcp" : fields[2].lowercased() == "udp" ? "udp" : "other"
            let type = fields.firstIndex(of: "typ").flatMap { $0 + 1 < fields.count ? String(fields[$0 + 1]) : nil }
            kinds["\((type.map { types.contains($0) ? $0 : "other" }) ?? "other")/\(proto)", default: 0] += 1
        }
        return kinds
    }

    /// Once per peer: why a receive path has not connected (no addresses or URLs).
    func logStallDiagnostics(reason: String) {
        guard !stallDiagnosticsLogged, !closed else { return }
        stallDiagnosticsLogged = true
        logICEFailureDiagnostics(reason: reason, state: lastICEState)
    }

    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didAdd receiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        // Native reads happen here, on WebRTC's own thread; the main actor only
        // compares identities and queues sink changes on the native queue.
        let receivedTrack = receiver.track, streamIDs = streams.map(\.streamId)
        let kind = receivedTrack?.kind ?? "unknown", audioTrackID = (receivedTrack as? LKRTCAudioTrack)?.trackId
        if let track = receivedTrack as? LKRTCAudioTrack { startupPlaybackGain?.register(track, streamIDs: streamIDs) }
        Task { @MainActor [weak self] in
            guard let self, !closed else { return }
            self.startupPlaybackGain?.reconcile()
#if DEBUG
            defer { self.receiverEventFinishedForTesting?() }
#endif
            // receiver.track returns a new wrapper on each read. isEqual compares
            // native track identity, including when callbacks repeat on reconnect.
            if let track = receivedTrack as? LKRTCVideoTrack {
                if let index = incomingVideo.firstIndex(where: { $0.video.track.isEqual(track) }) {
                    // Unified Plan may reuse the receiver when a publication is replaced.
                    if incomingVideo[index].video.streamIDs != streamIDs {
                        incomingVideo[index].video.streamIDs = streamIDs
                        onIncomingVideoChange?(receivedVideo)
                    }
                } else {
                    let sink = GuestTrackRenderer(counter: renderer)
                    incomingVideo.append((GuestRemoteVideo(id: UUID().uuidString, track: track,
                        streamIDs: streamIDs), sink))
                    native.post("add-video-sink") { track.add(sink) }
                    onIncomingVideoChange?(receivedVideo)
#if DEBUG
                    receiverAttachmentsForTesting += 1
#endif
                }
            }
            if let track = receivedTrack as? LKRTCAudioTrack {
                let source = GuestStartupPlaybackGain.Source(trackID: audioTrackID ?? "", streamIDs: streamIDs)
                if let index = incomingAudio.firstIndex(where: { $0.track.isEqual(track) }) {
                    incomingAudio[index].source = source
                } else {
                    incomingAudio.append((track, source))
                    let meter = pcmMeter
                    native.post("add-audio-sink") { track.add(meter) }
#if DEBUG
                    receiverAttachmentsForTesting += 1
#endif
                }
                onIncomingAudioChange?()
            }
            var fields: [String: Any] = ["target": target.rawValue, "kind": kind]
#if DEBUG
            fields["peerID"] = diagnosticID; fields["streamIDs"] = streamIDs
            fields["receiverAttachments"] = receiverAttachmentsForTesting
#endif
            probeLog("remote-track", fields)
        }
    }
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didRemove receiver: LKRTCRtpReceiver) {
        let removedTrack = receiver.track, removedTrackID = removedTrack?.trackId ?? ""
        if let track = removedTrack as? LKRTCAudioTrack { startupPlaybackGain?.remove(track) }
        Task { @MainActor [weak self] in
            guard let self, !closed else { return }
#if DEBUG
            defer { self.receiverEventFinishedForTesting?() }
#endif
            guard let track = removedTrack else { return }
            if let index = incomingVideo.firstIndex(where: { $0.video.track.isEqual(track) }) {
                let removed = incomingVideo.remove(at: index)
                removed.sink.stop()
                native.post("remove-video-sink") { removed.video.track.remove(removed.sink) }
                onIncomingVideoChange?(receivedVideo)
#if DEBUG
                receiverDetachmentsForTesting += 1
#endif
            }
            if let index = incomingAudio.firstIndex(where: { $0.track.isEqual(track) }) {
                let audio = incomingAudio.remove(at: index).track, meter = pcmMeter
                native.post("remove-audio-sink") { audio.remove(meter) }
                onIncomingAudioChange?()
#if DEBUG
                receiverDetachmentsForTesting += 1
#endif
            }
#if DEBUG
            probeLog("remote-track-removed", ["peerID": diagnosticID, "target": target.rawValue,
                "trackID": removedTrackID, "receiverDetachments": receiverDetachmentsForTesting])
#endif
        }
    }
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, !closed else { return }
#if DEBUG
            defer { self.transportEventFinishedForTesting?() }
#endif
            transportConnected = newState == .connected
            if target == .subscriber, newState == .connected, !hasEstablishedConnection {
                hasEstablishedConnection = true; initialRequiredDeadline = nil
                iceTimeout?.cancel(); iceTimeout = nil
            }
            probeLog("peer-transport-state", ["target": target.rawValue, "state": newState.rawValue])
        }
    }
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ pc: LKRTCPeerConnection) {}
    private func iceNow() -> TimeInterval {
#if DEBUG
        if let iceClockForTesting { return iceClockForTesting() }
#endif
        return ProcessInfo.processInfo.systemUptime
    }
    private func reportInitialICEExpiry(_ state: LKRTCIceConnectionState) {
        guard !initialExpiryReported else { return }
        initialExpiryReported = true
        probeLog("ice-timeout", ["target": target.rawValue, "state": state.rawValue])
        logStallDiagnostics(reason: "deadline")
        if target == .subscriber { onInitialStall?() }
        onFailure?(GuestPeerError.iceFailed)
    }
    private func refreshICETimeout() {
        iceTimeout?.cancel(); iceTimeout = nil
        let state = lastICEState
        guard !closed, !iceConnected else { return }
        let establishmentDeadline: TimeInterval?
        let delay: UInt64
        if target == .subscriber, !hasEstablishedConnection, state == .checking || state == .failed {
            guard activeIncomingMediaDemand, let deadline = initialRequiredDeadline, !initialExpiryReported else { return }
            let remaining = deadline - iceNow()
            guard remaining > 0 else { reportInitialICEExpiry(state); return }
            establishmentDeadline = deadline
            delay = UInt64(max(1, ceil(remaining * 1_000_000_000)))
        } else {
            guard state == .checking || state == .disconnected else { return }
            guard state != .checking || target != .subscriber || activeIncomingMediaDemand else { return }
            establishmentDeadline = nil
            delay = state == .checking ? 10_000_000_000 : 5_000_000_000
        }
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
            guard !Task.isCancelled, let self, !closed, !iceConnected else { return }
            if let establishmentDeadline {
                guard !hasEstablishedConnection, activeIncomingMediaDemand,
                      initialRequiredDeadline == establishmentDeadline,
                      lastICEState == .checking || lastICEState == .failed else { return }
                guard iceNow() >= establishmentDeadline else { refreshICETimeout(); return }
                reportInitialICEExpiry(lastICEState); return
            }
            guard lastICEState == state,
                  state != .checking || target != .subscriber || activeIncomingMediaDemand else { return }
            probeLog("ice-timeout", ["target": target.rawValue, "state": state.rawValue])
            logStallDiagnostics(reason: "deadline")
            onFailure?(GuestPeerError.iceFailed)
        }
    }
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, !closed else { return }
#if DEBUG
            defer { self.iceEventFinishedForTesting?() }
#endif
            guard newState != lastICEState else { return }
            lastICEState = newState
            iceConnected = newState == .connected || newState == .completed
            if iceConnected { hasEstablishedConnection = true; initialRequiredDeadline = nil }
            refreshICETimeout()
            probeLog("ice-state", ["target": target.rawValue, "state": newState.rawValue])
            if newState == .failed { logStallDiagnostics(reason: "native-failed") }
            if newState == .closed || (newState == .failed && (target != .subscriber || hasEstablishedConnection)) {
                onFailure?(GuestPeerError.iceFailed)
            }
        }
    }
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        Task { @MainActor [weak self] in
            guard let self, !closed, newState != lastGatheringState else { return }
            lastGatheringState = newState
            logICEDiagnostic("ice-gathering-state", ["state": newState.rawValue])
        }
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
