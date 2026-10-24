import AVFoundation
import Foundation
import LiveKitWebRTC

enum NativeDesktopRTCError: Error, Equatable { case closed, invalidResponse, cleanupFailed, permissionDenied }

/// A peer borrows one session-owned native audio factory. It never initializes
/// the iOS audio session or starts a second audio device.
@MainActor
final class NativeDesktopRTCPeer: NSObject, LKRTCPeerConnectionDelegate {
    enum Topology { case split, composite }
    let target: String
    let topology: Topology
    let factory: LKRTCPeerConnectionFactory
    private let audioProfile: GuestAudioProfile
    private(set) var connection: LKRTCPeerConnection!
    var onCandidate: (([String: Any]) -> Void)?
    var onTrack: ((String, LKRTCVideoTrack) -> Void)?
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
         audioProfile: GuestAudioProfile = .speech) throws {
        self.target = target; self.factory = factory; self.topology = topology; self.audioProfile = audioProfile
        sequence = target == "PUBLISHER" ? 1 : 0
        super.init()
        let config = LKRTCConfiguration(); config.sdpSemantics = .unifiedPlan
        config.iceServers = Self.servers(ice)
        connection = factory.peerConnection(with: config,
            constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        guard connection != nil else { throw NativeDesktopRTCError.invalidResponse }
        if target == "PUBLISHER" { try enablePublishing() }
    }
    private static func servers(_ values: [[String: Any]]) -> [LKRTCIceServer] {
        values.compactMap { value in
            let urls = value["urls"] as? [String] ?? (value["urls"] as? String).map { [$0] } ?? []
            guard !urls.isEmpty else { return nil }
            return .init(urlStrings: urls, username: value["username"] as? String, credential: value["credential"] as? String)
        }
    }
    func configure(_ fields: [String: Any]) throws {
        try check()
        guard let values = fields["iceServers"] as? [[String: Any]] else { return }
        let config = connection.configuration; config.iceServers = Self.servers(values)
        guard connection.setConfiguration(config) else { throw NativeDesktopRTCError.invalidResponse }
    }
    /// TrueConf must answer its receive offer before appending send transceivers.
    func enablePublishing() throws {
        try check(); guard audioTransceiver == nil else { return }
        let options = LKRTCRtpTransceiverInit(); options.direction = .sendOnly
        let source = factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: audioProfile.audioConstraints, optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "microphone"); track.isEnabled = false
        guard let audio = connection.addTransceiver(with: track, init: options),
              let video = connection.addTransceiver(of: .video, init: options) else { throw NativeDesktopRTCError.invalidResponse }
        audioTrack = track; audioTransceiver = audio; videoTransceiver = video
        preferH264(video)
    }
    private func preferH264(_ transceiver: LKRTCRtpTransceiver) {
        let codecs = factory.rtpSenderCapabilities(forKind: "video").codecs
        try? transceiver.setCodecPreferences(codecs.filter { $0.name == "H264" } + codecs.filter { $0.name != "H264" }, error: ())
    }
    func setMicrophone(_ enabled: Bool) { audioTrack?.isEnabled = enabled && !closed }
    var microphoneSending: Bool { !closed && audioTrack?.isEnabled == true }
    func microphoneLevel() async -> Float? {
        guard microphoneSending, let sender = audioTransceiver?.sender else { return nil }
        let report: LKRTCStatisticsReport? = try? await guestAwait(timeout: 2) { [connection] done in
            connection?.statistics(for: sender) { done(.success($0)) }
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
            cameraRevision &+= 1; videoTrack?.isEnabled = false; videoTrack = nil
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
        let source = factory.videoSource(); source.adaptOutputFormat(toWidth: 1280, height: 720, fps: 30)
        let selected = UserDefaults.standard.string(forKey: "nativeDesktop.cameraID").flatMap { $0.isEmpty ? nil : $0 }
        let capture = GuestCamera(source: source, deviceID: selected); camera = capture
        do {
            _ = try await capture.start()
            try check(); guard cameraRevision == revision, camera === capture else { throw CancellationError() }
            let track = factory.videoTrack(with: source, trackId: "camera")
            videoTrack = track; applyVideo(); onLocalCamera?(track)
        } catch {
            capture.cancel()
            do { try await capture.stop() } catch { captureCleanupFailed = true }
            if camera === capture { camera = nil; videoTrack = nil; applyVideo(); onLocalCamera?(nil) }
            if captureCleanupFailed { throw NativeDesktopRTCError.cleanupFailed }
            throw error
        }
    }
    private func applyVideo() { videoTransceiver?.sender.track = topology == .composite ? (shareTrack ?? videoTrack) : videoTrack }
    func setScreenTrack(_ track: LKRTCVideoTrack?) throws {
        if track != nil { try check() }
        if topology == .composite {
            shareTrack = track; applyVideo()
            configureSender(videoTransceiver?.sender, sharing: track != nil)
            return
        }
        if track != nil, shareTransceiver == nil {
            let options = LKRTCRtpTransceiverInit(); options.direction = .sendOnly
            guard let value = connection.addTransceiver(of: .video, init: options) else { throw NativeDesktopRTCError.invalidResponse }
            shareTransceiver = value; preferH264(value)
        }
        shareTrack = track; shareTransceiver?.sender.track = track
        configureSender(shareTransceiver?.sender, sharing: true)
    }
    private func configureSender(_ sender: LKRTCRtpSender?, sharing: Bool) {
        guard let sender else { return }
        let parameters = sender.parameters
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = NSNumber(value: sharing ? 18_000_000 : 2_500_000)
            encoding.maxFramerate = 30
        }
        parameters.degradationPreference = NSNumber(value: (sharing ? LKRTCDegradationPreference.maintainResolution : .balanced).rawValue)
        sender.parameters = parameters
    }
    func answer(_ fields: [String: Any]) async throws -> [String: Any] {
        try check(); localSent = false
        guard let sdp = fields["sdp"] as? String, let seq = fields["pcSeq"] as? Int ?? (topology == .composite ? 0 : nil),
              seq == sequence || connection.remoteDescription == nil else { throw NativeDesktopRTCError.invalidResponse }
        sequence = seq
        try await setDescription(.init(type: .offer, sdp: sdp), local: false)
        let answer = try await description(offer: false)
        try await setDescription(answer, local: true)
        for transceiver in connection.transceivers { reportTrack(transceiver) }
        try await flushRemote()
        return ["sdp": answer.sdp, "pcSeq": sequence]
    }
    func offer() async throws -> [String: Any] {
        try check(); localSent = false
        let value = try await description(offer: true); try await setDescription(value, local: true)
        var tracks: [[String: Any]] = []
        for (transceiver, kind) in [(audioTransceiver, "AUDIO"), (videoTransceiver, "VIDEO"), (shareTransceiver, "DISPLAY_VIDEO")] {
            guard let transceiver, transceiver.sender.track != nil else { continue }
            tracks.append(["mid": transceiver.mid, "transceiverMid": transceiver.mid, "kind": kind,
                "priority": 0, "label": kind, "codecs": [:], "groupId": 1, "description": ""])
        }
        return ["sdp": value.sdp, "pcSeq": sequence, "tracks": tracks]
    }
    func accept(_ fields: [String: Any]) async throws {
        try check()
        guard let sdp = fields["sdp"] as? String, topology == .composite || fields["pcSeq"] as? Int == sequence else { throw NativeDesktopRTCError.invalidResponse }
        try await setDescription(.init(type: .answer, sdp: sdp), local: false); try await flushRemote()
        if shareTrack != nil { configureSender(topology == .composite ? videoTransceiver?.sender : shareTransceiver?.sender, sharing: true) }
    }
    private func description(offer: Bool) async throws -> LKRTCSessionDescription {
        let value: LKRTCSessionDescription = try await guestAwait { [connection] done in
            let callback: @Sendable (LKRTCSessionDescription?, Error?) -> Void = { value, error in
                if let error { done(.failure(error)) } else if let value { done(.success(value)) }
                else { done(.failure(NativeDesktopRTCError.invalidResponse)) }
            }
            let options = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            if offer { connection?.offer(for: options, completionHandler: callback) }
            else { connection?.answer(for: options, completionHandler: callback) }
        }
        try check(); return value
    }
    private func setDescription(_ value: LKRTCSessionDescription, local: Bool) async throws {
        try await guestAwait { [connection] (done: @escaping (Result<Void, Error>) -> Void) in
            let callback: @Sendable (Error?) -> Void = { error in done(error.map(Result.failure) ?? .success(())) }
            if local { connection?.setLocalDescription(value, completionHandler: callback) }
            else { connection?.setRemoteDescription(value, completionHandler: callback) }
        }
        try check()
    }
    func addCandidate(_ fields: [String: Any]) async throws {
        try check()
        guard topology == .composite || fields["pcSeq"] as? Int == sequence,
              let sdp = fields["candidate"] as? String,
              let index = fields["sdpMlineIndex"] as? Int, (0...64).contains(index) else { return }
        let value = LKRTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(index), sdpMid: fields["sdpMid"] as? String)
        if connection.remoteDescription == nil {
            guard remoteCandidates.count < 256 else { throw NativeDesktopRTCError.invalidResponse }
            remoteCandidates.append(value)
        } else { try await add(value) }
    }
    private func add(_ value: LKRTCIceCandidate) async throws {
        try await guestAwait { [connection] (done: @escaping (Result<Void, Error>) -> Void) in
            connection?.add(value) { error in done(error.map(Result.failure) ?? .success(())) }
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
        closed = true; audioTrack?.isEnabled = false; shareTrack = nil; applyVideo()
        onCandidate = nil; onTrack = nil; onState = nil
        var clean = true
        do { try await setCamera(false) } catch { clean = false }
        onLocalCamera = nil; connection.close(); localCandidates = []; remoteCandidates = []
        return clean && !captureCleanupFailed
    }
    private func reportTrack(_ transceiver: LKRTCRtpTransceiver) {
        guard !closed, !transceiver.mid.isEmpty, let track = transceiver.receiver.track as? LKRTCVideoTrack else { return }
        onTrack?(transceiver.mid, track)
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
        Task { @MainActor [weak self] in
            guard let self, !closed else { return }
            for value in pc.transceivers where value.receiver.receiverId == receiver.receiverId { reportTrack(value) }
        }
    }
    nonisolated func peerConnection(_ pc: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {
        Task { @MainActor [weak self] in self?.reportTrack(transceiver) }
    }
}
