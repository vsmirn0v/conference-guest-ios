import AVFoundation
import Foundation
import LiveKitWebRTC

enum NativeDesktopRTCError: Error, Equatable { case closed, invalidResponse, cleanupFailed, permissionDenied }

/// A peer borrows one session-owned native audio factory. It never initializes
/// the iOS audio session or starts a second audio device. Every call into the
/// native objects after creation runs on `native`, never on the main thread
/// (WebRTC can be stuck for seconds behind the audio device).
@MainActor
final class NativeDesktopRTCPeer: NSObject, LKRTCPeerConnectionDelegate {
    enum Topology { case split, composite }
    let target: String
    let topology: Topology
    let factory: LKRTCPeerConnectionFactory
    let native: GuestNativeCalls
    private let audioProfile: GuestAudioProfile
    private(set) var connection: LKRTCPeerConnection!
    var onCandidate: (([String: Any]) -> Void)?
    var onTrack: ((String, LKRTCVideoTrack) -> Void)?
    /// A received (not sent) audio track by transceiver mid, for local transcription.
    var onAudioTrack: ((String, LKRTCAudioTrack) -> Void)?
    var onState: ((LKRTCIceConnectionState) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    private(set) var closed = false
    private(set) var videoTrack: LKRTCVideoTrack?
    private var audioTrack: LKRTCAudioTrack?
    private var camera: GuestCamera?
    func cameraCaptureDevice() async -> AVCaptureDevice? {
        guard !closed, let current = camera else { return nil }
        let device = await current.captureDevice()
        return !closed && camera === current ? device : nil
    }
    #if DEBUG
    func selectedCameraDeviceIDForTesting() async -> String? {
        guard !closed, let current = camera else { return nil }
        let id = await current.selectedDeviceIDForTesting()
        return !closed && camera === current ? id : nil
    }
    /// Exercises the real close -> setCamera(false) drain without opening a
    /// capture device. The supplied task represents an already-started stop.
    func installCameraStopForTesting(_ stop: Task<Bool, Never>) { cameraStop = stop }
    #endif
    private var cameraRevision: UInt64 = 0
    private var cameraStop: Task<Bool, Never>?
    private var captureCleanupFailed = false
    private var audioTransceiver: LKRTCRtpTransceiver?
    private var videoTransceiver: LKRTCRtpTransceiver?
    private var shareTransceiver: LKRTCRtpTransceiver?
    private var shareTrack: LKRTCVideoTrack?
    private var sequence: Int
    private var localSent = false
    private var localCandidates: [[String: Any]] = []
    private var remoteCandidates: [LKRTCIceCandidate] = []

    init(target: String, factory: LKRTCPeerConnectionFactory, ice: [[String: Any]], topology: Topology = .split,
         audioProfile: GuestAudioProfile = .speech) async throws {
        self.target = target; self.factory = factory; self.topology = topology; self.audioProfile = audioProfile
        sequence = target == "PUBLISHER" ? 1 : 0
        native = GuestNativeCalls(label: "external-\(target.lowercased())")
        super.init()
        // Creation waits on WebRTC's threads too, so it runs on the native queue.
        let servers = Self.servers(ice), publisher = target == "PUBLISHER"
        let (pc, publishing) = try await native.run("create-peer-connection") { [self] () -> (LKRTCPeerConnection, Publishing?) in
            let config = LKRTCConfiguration(); config.sdpSemantics = .unifiedPlan
            config.iceServers = servers
            guard let pc = factory.peerConnection(with: config,
                constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
            else { throw NativeDesktopRTCError.invalidResponse }
            let publishing = publisher ? try Self.makePublishing(factory: factory, connection: pc, audioProfile: audioProfile) : nil
            return (pc, publishing)
        }
        connection = pc
        if let publishing { installPublishing(publishing) }
    }
    private static func servers(_ values: [[String: Any]]) -> [LKRTCIceServer] {
        values.compactMap { value in
            let urls = value["urls"] as? [String] ?? (value["urls"] as? String).map { [$0] } ?? []
            guard !urls.isEmpty else { return nil }
            return .init(urlStrings: urls, username: value["username"] as? String, credential: value["credential"] as? String)
        }
    }
    func configure(_ fields: [String: Any]) async throws {
        try check()
        guard let values = fields["iceServers"] as? [[String: Any]] else { return }
        let connection = connection!, servers = Self.servers(values)
        let applied = try await native.run("set-configuration") { () -> Bool in
            let config = connection.configuration; config.iceServers = servers
            return connection.setConfiguration(config)
        }
        guard applied else { throw NativeDesktopRTCError.invalidResponse }
    }
    private typealias Publishing = (track: LKRTCAudioTrack, audio: LKRTCRtpTransceiver, video: LKRTCRtpTransceiver)
    /// Creates the disabled microphone track and the send transceivers. Native queue (or creation) only.
    nonisolated private static func makePublishing(factory: LKRTCPeerConnectionFactory, connection: LKRTCPeerConnection,
                                                   audioProfile: GuestAudioProfile) throws -> Publishing {
        let options = LKRTCRtpTransceiverInit(); options.direction = .sendOnly
        let source = factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: audioProfile.audioConstraints, optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "microphone"); track.isEnabled = false
        guard let audio = connection.addTransceiver(with: track, init: options),
              let video = connection.addTransceiver(of: .video, init: options) else { throw NativeDesktopRTCError.invalidResponse }
        preferH264(video, factory: factory)
        return (track, audio, video)
    }
    private func installPublishing(_ value: Publishing) {
        audioTrack = value.track; audioTransceiver = value.audio; videoTransceiver = value.video
        onMicrophoneTrack?(value.track)
    }
    /// TrueConf must answer its receive offer before appending send transceivers.
    func enablePublishing() async throws {
        try check(); guard audioTransceiver == nil else { return }
        let factory = factory, connection = connection!, profile = audioProfile
        let value = try await native.run("enable-publishing") {
            try Self.makePublishing(factory: factory, connection: connection, audioProfile: profile)
        }
        try check(); guard audioTransceiver == nil else { return }
        installPublishing(value)
    }
    /// The microphone track once publishing is enabled (created disabled).
    var microphoneTrack: LKRTCAudioTrack? { audioTrack }
    /// Called when publishing creates the microphone track after the peer was handed out.
    var onMicrophoneTrack: ((LKRTCAudioTrack) -> Void)?
    nonisolated private static func preferH264(_ transceiver: LKRTCRtpTransceiver, factory: LKRTCPeerConnectionFactory) {
        let codecs = factory.rtpSenderCapabilities(forKind: "video").codecs
        try? transceiver.setCodecPreferences(codecs.filter { $0.name == "H264" } + codecs.filter { $0.name != "H264" }, error: ())
    }
    /// Queued in order with every other native call; a later `false` always wins.
    func setMicrophone(_ enabled: Bool) {
        let enabled = enabled && !closed, track = audioTrack
        microphoneEnabled = enabled
        native.post(enabled ? "enable-microphone" : "disable-microphone") { track?.isEnabled = enabled }
    }
    private var microphoneEnabled = false
    var microphoneSending: Bool { !closed && audioTrack != nil && microphoneEnabled }
    func microphoneLevel() async -> Float? {
        guard microphoneSending, let sender = audioTransceiver?.sender else { return nil }
        let connection = connection!
        let report: LKRTCStatisticsReport? = try? await native.call("microphone-statistics", timeout: 2) { done in
            connection.statistics(for: sender) { done(.success($0)) }
        }
        guard !closed else { return nil }
        return report?.statistics.values.compactMap { row -> Float? in
            guard row.type == "media-source", row.values["kind"] as? String == "audio" else { return nil }
            return (row.values["audioLevel"] as? NSNumber)?.floatValue
        }.max()
    }
    func setCamera(_ enabled: Bool) async throws {
        guard !closed || !enabled else { throw NativeDesktopRTCError.closed }
        if enabled && captureCleanupFailed { throw NativeDesktopRTCError.cleanupFailed }
        if !enabled {
            cameraRevision &+= 1
            let track = videoTrack; native.post("disable-camera-track") { track?.isEnabled = false }
            videoTrack = nil
            applyVideo(); onLocalCamera?(nil)
            if let capture = camera {
                camera = nil; capture.cancel()
                cameraStop = Task { do { try await capture.stop(); return true } catch { return false } }
            }
            if await cameraStop?.value == false { captureCleanupFailed = true; throw NativeDesktopRTCError.cleanupFailed }
            return
        }
        guard camera == nil else { return }
        let revision = cameraRevision
        guard await cameraStop?.value != false else { throw NativeDesktopRTCError.cleanupFailed }
        try check(); guard cameraRevision == revision else { throw CancellationError() }
        let factory = factory
        let source = try await native.run("camera-source") { () -> LKRTCVideoSource in
            let source = factory.videoSource(); source.adaptOutputFormat(toWidth: 1280, height: 720, fps: 30); return source
        }
        try check(); guard cameraRevision == revision else { throw CancellationError() }
        let selected = UserDefaults.standard.string(forKey: "nativeDesktop.cameraID").flatMap { $0.isEmpty ? nil : $0 }
        let capture = GuestCamera(source: source, deviceID: selected); camera = capture
        do {
            _ = try await capture.start()
            try check(); guard cameraRevision == revision, camera === capture else { throw CancellationError() }
            let track = try await native.run("camera-track") { factory.videoTrack(with: source, trackId: "camera") }
            try check(); guard cameraRevision == revision, camera === capture else { throw CancellationError() }
            videoTrack = track; applyVideo(); onLocalCamera?(track)
        } catch {
            capture.cancel()
            do { try await capture.stop() } catch { captureCleanupFailed = true }
            if camera === capture { camera = nil; videoTrack = nil; applyVideo(); onLocalCamera?(nil) }
            if captureCleanupFailed { throw NativeDesktopRTCError.cleanupFailed }
            throw error
        }
    }
    private func applyVideo() {
        let transceiver = videoTransceiver, track = topology == .composite ? (shareTrack ?? videoTrack) : videoTrack
        native.post("apply-video") { transceiver?.sender.track = track }
    }
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {
        if track != nil { try check() }
        if topology == .composite {
            shareTrack = track; applyVideo()
            configureSender(videoTransceiver, sharing: track != nil)
            return
        }
        if track != nil, shareTransceiver == nil {
            let connection = connection!, factory = factory
            let value = try await native.run("add-share-transceiver") { () -> LKRTCRtpTransceiver in
                let options = LKRTCRtpTransceiverInit(); options.direction = .sendOnly
                guard let value = connection.addTransceiver(of: .video, init: options) else { throw NativeDesktopRTCError.invalidResponse }
                Self.preferH264(value, factory: factory); return value
            }
            if track != nil { try check() }
            if shareTransceiver == nil { shareTransceiver = value }
        }
        shareTrack = track
        let transceiver = shareTransceiver
        native.post("set-share-track") { transceiver?.sender.track = track }
        configureSender(transceiver, sharing: true)
    }
    private func configureSender(_ transceiver: LKRTCRtpTransceiver?, sharing: Bool) {
        guard let transceiver else { return }
        native.post("configure-sender") {
            let sender = transceiver.sender
            let parameters = sender.parameters
            for encoding in parameters.encodings {
                encoding.maxBitrateBps = NSNumber(value: sharing ? 18_000_000 : 2_500_000)
                encoding.maxFramerate = 30
            }
            parameters.degradationPreference = NSNumber(value: (sharing ? LKRTCDegradationPreference.maintainResolution : .balanced).rawValue)
            sender.parameters = parameters
        }
    }
    func answer(_ fields: [String: Any]) async throws -> [String: Any] {
        try check(); localSent = false
        guard let sdp = fields["sdp"] as? String, let seq = fields["pcSeq"] as? Int ?? (topology == .composite ? 0 : nil)
        else { throw NativeDesktopRTCError.invalidResponse }
        let connection = connection!
        let hasRemote = try await native.run("has-remote-description") { connection.remoteDescription != nil }
        try check()
        guard seq == sequence || !hasRemote else { throw NativeDesktopRTCError.invalidResponse }
        sequence = seq
        try await setDescription(.init(type: .offer, sdp: sdp), local: false)
        let answer = try await description(offer: false)
        try await setDescription(answer, local: true)
        let reports = try await native.run("received-tracks") { connection.transceivers.compactMap(Self.trackReport) }
        try check(); reports.forEach(deliver)
        try await flushRemote()
        return ["sdp": answer.sdp, "pcSeq": sequence]
    }
    func offer() async throws -> [String: Any] {
        try check(); localSent = false
        let value = try await description(offer: true); try await setDescription(value, local: true)
        let senders = [(audioTransceiver, "AUDIO"), (videoTransceiver, "VIDEO"), (shareTransceiver, "DISPLAY_VIDEO")]
        let sending = try await native.run("sending-tracks") { () -> [(String, String)] in
            senders.compactMap { transceiver, kind in
                guard let transceiver, transceiver.sender.track != nil else { return nil }
                return (transceiver.mid, kind)
            }
        }
        try check()
        let tracks: [[String: Any]] = sending.map { mid, kind in
            ["mid": mid, "transceiverMid": mid, "kind": kind,
             "priority": 0, "label": kind, "codecs": [:] as [String: Any], "groupId": 1, "description": ""]
        }
        return ["sdp": value.sdp, "pcSeq": sequence, "tracks": tracks]
    }
    func accept(_ fields: [String: Any]) async throws {
        try check()
        guard let sdp = fields["sdp"] as? String, topology == .composite || fields["pcSeq"] as? Int == sequence else { throw NativeDesktopRTCError.invalidResponse }
        try await setDescription(.init(type: .answer, sdp: sdp), local: false); try await flushRemote()
        if shareTrack != nil { configureSender(topology == .composite ? videoTransceiver : shareTransceiver, sharing: true) }
    }
    private func description(offer: Bool) async throws -> LKRTCSessionDescription {
        let connection = connection!
        let value: LKRTCSessionDescription = try await native.call(offer ? "create-offer" : "create-answer") { done in
            let callback: @Sendable (LKRTCSessionDescription?, Error?) -> Void = { value, error in
                if let error { done(.failure(error)) } else if let value { done(.success(value)) }
                else { done(.failure(NativeDesktopRTCError.invalidResponse)) }
            }
            let options = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            if offer { connection.offer(for: options, completionHandler: callback) }
            else { connection.answer(for: options, completionHandler: callback) }
        }
        try check(); return value
    }
    private func setDescription(_ value: LKRTCSessionDescription, local: Bool) async throws {
        let connection = connection!
        try await native.call(local ? "set-local-description" : "set-remote-description") { (done: @escaping (Result<Void, Error>) -> Void) in
            let callback: @Sendable (Error?) -> Void = { error in done(error.map(Result.failure) ?? .success(())) }
            if local { connection.setLocalDescription(value, completionHandler: callback) }
            else { connection.setRemoteDescription(value, completionHandler: callback) }
        }
        try check()
    }
    func addCandidate(_ fields: [String: Any]) async throws {
        try check()
        guard topology == .composite || fields["pcSeq"] as? Int == sequence,
              let sdp = fields["candidate"] as? String,
              let index = fields["sdpMlineIndex"] as? Int, (0...64).contains(index) else { return }
        let value = LKRTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(index), sdpMid: fields["sdpMid"] as? String)
        let connection = connection!
        let hasRemote = try await native.run("has-remote-description") { connection.remoteDescription != nil }
        try check()
        if !hasRemote {
            guard remoteCandidates.count < 256 else { throw NativeDesktopRTCError.invalidResponse }
            remoteCandidates.append(value)
        } else { try await add(value) }
    }
    private func add(_ value: LKRTCIceCandidate) async throws {
        let connection = connection!
        try await native.call("add-candidate") { (done: @escaping (Result<Void, Error>) -> Void) in
            connection.add(value) { error in done(error.map(Result.failure) ?? .success(())) }
        }; try check()
    }
    private func flushRemote() async throws {
        let values = remoteCandidates; remoteCandidates.removeAll()
        for value in values { try await add(value) }
    }
    func localSDPSent() {
        guard !closed else { return }; localSent = true
        let values = localCandidates; localCandidates.removeAll()
        for value in values { onCandidate?(value) }
    }
    private func check() throws { if closed || Task.isCancelled { throw CancellationError() } }
    func close() async -> Bool {
        closed = true; microphoneEnabled = false
        let microphone = audioTrack; native.post("close-microphone") { microphone?.isEnabled = false }
        shareTrack = nil; applyVideo()
        onCandidate = nil; onTrack = nil; onAudioTrack = nil; onState = nil
        var clean = true
        do { try await setCamera(false) } catch { clean = false }
        onLocalCamera = nil; localCandidates = []; remoteCandidates = []
        let connection = connection!; native.post("close") { connection.close() }
        return clean && !captureCleanupFailed
    }
    /// A received track by mid, read on a WebRTC or native thread, never on main.
    private enum TrackReport { case video(String, LKRTCVideoTrack), audio(String, LKRTCAudioTrack) }
    nonisolated private static func trackReport(_ transceiver: LKRTCRtpTransceiver) -> TrackReport? {
        let mid = transceiver.mid
        guard !mid.isEmpty else { return nil }
        if let track = transceiver.receiver.track as? LKRTCVideoTrack { return .video(mid, track) }
        if let track = transceiver.receiver.track as? LKRTCAudioTrack, transceiver.direction != .sendOnly,
           transceiver.direction != .inactive { return .audio(mid, track) }
        return nil
    }
    private func deliver(_ report: TrackReport) {
        guard !closed else { return }
        switch report {
        case .video(let mid, let track): onTrack?(mid, track)
        case .audio(let mid, let track): onAudioTrack?(mid, track)
        }
    }
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ pc: LKRTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didChange state: LKRTCIceConnectionState) {
        Task { @MainActor [weak self] in guard let self, !closed else { return }; onState?(state) }
    }
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didChange state: LKRTCIceGatheringState) {}
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        Task { @MainActor [weak self] in
            guard let self, !closed else { return }
            let value: [String: Any] = ["candidate": candidate.sdp, "sdpMlineIndex": Int(candidate.sdpMLineIndex),
                "sdpMid": candidate.sdpMid ?? "0", "target": target, "pcSeq": sequence]
            if localSent { onCandidate?(value) }
            else if localCandidates.count < 256 { localCandidates.append(value) }
            else { onState?(.failed) }
        }
    }
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didAdd receiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        // Delegate callbacks run on WebRTC's signaling thread: native reads happen here.
        let id = receiver.receiverId
        let reports = pc.transceivers.filter { $0.receiver.receiverId == id }.compactMap(Self.trackReport)
        Task { @MainActor [weak self] in
            guard let self, !closed else { return }
            reports.forEach(deliver)
        }
    }
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {
        let report = Self.trackReport(transceiver)
        Task { @MainActor [weak self] in if let report { self?.deliver(report) } }
    }
}
