import AVFoundation
import Combine
import Foundation
import LiveKitWebRTC

final class NativeRTCPeer: NSObject, LKRTCPeerConnectionDelegate, @unchecked Sendable {
    enum Topology { case split, composite }
    private let topology: Topology
    private static let sslInitialized = LKRTCInitializeSSL()
    // The default RTC audio device is process-wide. Retain one factory so
    // retiring an old connection cannot tear it down under a new call.
    private static let sharedFactory: Result<LKRTCPeerConnectionFactory, Error> = Result {
        guard sslInitialized else { throw NativeRTCError.invalidResponse }
        let encoder = LKRTCDefaultVideoEncoderFactory()
        if let codec = LKRTCDefaultVideoEncoderFactory.supportedCodecs().first(where: { $0.name == "H264" }) { encoder.preferredCodec = codec }
        return LKRTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: NativeH264DecoderFactory(base: NativeVideoDecoderFactory()))
    }
    static func makeFactory() throws -> LKRTCPeerConnectionFactory { try sharedFactory.get() }
    deinit { if let decoderObservation { NotificationCenter.default.removeObserver(decoderObservation) } }
    let target: String
    let factory: LKRTCPeerConnectionFactory
    private(set) var connection: LKRTCPeerConnection!
    private let lock = NSLock()
    private var candidateHandler: (([String: Any]) -> Void)?
    private var trackHandler: ((String, LKRTCVideoTrack) -> Void)?
    private var stateHandler: ((LKRTCIceConnectionState) -> Void)?
    var onDecoderFallback: (() -> Void)?
    private var decoderObservation: NSObjectProtocol?
    // Delegate callbacks arrive on WebRTC threads while teardown clears the
    // handlers on the main actor. Snapshot the closures under the same lock.
    var onCandidate: (([String: Any]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return candidateHandler }
        set { lock.lock(); candidateHandler = newValue; lock.unlock() }
    }
    var onTrack: ((String, LKRTCVideoTrack) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return trackHandler }
        set { lock.lock(); trackHandler = newValue; lock.unlock() }
    }
    var onState: ((LKRTCIceConnectionState) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stateHandler }
        set { lock.lock(); stateHandler = newValue; lock.unlock() }
    }
    private var _sequence = 0
    private var sequence: Int { get { lock.lock(); defer { lock.unlock() }; return _sequence } set { lock.lock(); _sequence = newValue; lock.unlock() } }
    private var candidates: [LKRTCIceCandidate] = []
    private var localCandidates: [[String: Any]] = []
    private var localDescriptionAcknowledged = false
    private var audioTransceiver: LKRTCRtpTransceiver?
    private var videoTransceiver: LKRTCRtpTransceiver?
    private var sharingTransceiver: LKRTCRtpTransceiver?
    private(set) var videoTrack: LKRTCVideoTrack?
    private var camera: LKRTCCameraVideoCapturer?
    @MainActor private var cameraEnergySubscription: AnyCancellable?
    @MainActor private var cameraSource: LKRTCVideoSource?
    private var cameraPosition: AVCaptureDevice.Position
    private(set) var captureDevice: AVCaptureDevice?
    private var audioTrack: LKRTCAudioTrack?
    private var audioProfile: StudioAudioProfile?
    @MainActor private var closed = false

    init(target: String, factory: LKRTCPeerConnectionFactory, ice: [[String: Any]], cameraPosition: AVCaptureDevice.Position = .front, topology: Topology = .split) {
        self.target = target; self.factory = factory; self.cameraPosition = cameraPosition; self.topology = topology
        super.init(); sequence = target == "PUBLISHER" ? 1 : 0
        let decoderGeneration = NativeVideoDecoderPolicy.shared.snapshot.generation
        decoderObservation = NotificationCenter.default.addObserver(forName: NativeVideoDecoderPolicy.fallbackNotification,
            object: NativeVideoDecoderPolicy.shared, queue: .main) { [weak self] notification in
                guard notification.userInfo?["generation"] as? UUID == decoderGeneration else { return }
                self?.onDecoderFallback?()
            }
        let configuration = LKRTCConfiguration(); configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = Self.servers(ice)
        connection = factory.peerConnection(with: configuration,
            constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        if target == "PUBLISHER" { enablePublishing() }
    }
    /// A composite server supplies its receive offer first. Add outbound
    /// transceivers only after answering it to preserve the remote MID order.
    func enablePublishing() {
        guard audioTransceiver == nil else { return }
        let settings = LKRTCRtpTransceiverInit(); settings.direction = .sendOnly
        audioTransceiver = connection.addTransceiver(of: .audio, init: settings)
        videoTransceiver = connection.addTransceiver(of: .video, init: settings)
        // Preserve other codecs as fallbacks when the server declines H.264.
        preferPublishingH264(videoTransceiver)
    }
    private func preferPublishingH264(_ transceiver: LKRTCRtpTransceiver?) {
        let codecs = factory.rtpSenderCapabilities(forKind: "video").codecs
        try? transceiver?.setCodecPreferences(codecs.filter { $0.name == "H264" } + codecs.filter { $0.name != "H264" }, error: ())
    }
    private static func servers(_ values: [[String: Any]]) -> [LKRTCIceServer] {
        values.compactMap { value in
            let urls = value["urls"] as? [String] ?? (value["urls"] as? String).map { [$0] } ?? []
            guard !urls.isEmpty else { return nil }
            return .init(urlStrings: urls, username: value["username"] as? String, credential: value["credential"] as? String)
        }
    }
    func configure(_ value: [String: Any]) throws {
        guard let servers = value["iceServers"] as? [[String: Any]] else { return }
        let config = connection.configuration; config.iceServers = Self.servers(servers)
        guard connection.setConfiguration(config) else { throw NativeRTCError.invalidResponse }
    }
    func answer(_ offer: [String: Any]) async throws -> [String: Any] {
        lock.lock(); localDescriptionAcknowledged = false; lock.unlock()
        guard let sdp = offer["sdp"] as? String,
              let seq = (offer["pcSeq"] as? Int) ?? (topology == .composite ? 0 : nil) else { throw NativeRTCError.invalidResponse }
        guard seq == sequence || connection.remoteDescription == nil else { throw NativeRTCError.disconnected }
        sequence = seq
        try await setDescription(.init(type: .offer, sdp: sdp), local: false)
        if topology == .composite, NativeH264Codec.hardwareDecodingAvailable {
            let codecs = factory.rtpReceiverCapabilities(forKind: "video").codecs
            for transceiver in connection.transceivers where transceiver.mediaType == .video && transceiver.direction != .sendOnly {
                try transceiver.setCodecPreferences(codecs.filter { $0.name == "H264" } + codecs.filter { $0.name != "H264" }, error: ())
            }
        }
        // WebRTC exposes fresh Objective-C wrappers when enumerating transceivers;
        // receiver object identity is therefore not a reliable way to find its MID.
        for transceiver in connection.transceivers { reportTrack(transceiver) }
        let answer = try await description(offer: false)
        try await setDescription(answer, local: true)
        for transceiver in connection.transceivers { reportTrack(transceiver) }
        try await flushCandidates()
        return ["sdp": answer.sdp, "pcSeq": sequence]
    }
    func offer() async throws -> [String: Any] {
        lock.lock(); localDescriptionAcknowledged = false; lock.unlock()
        let offer = try await description(offer: true)
        try await setDescription(offer, local: true)
        var tracks: [[String: Any]] = []
        func append(_ transceiver: LKRTCRtpTransceiver?, kind: String) {
            guard let transceiver, transceiver.sender.track != nil else { return }
            tracks.append(["mid": transceiver.mid, "transceiverMid": transceiver.mid, "kind": kind,
                "priority": 0, "label": kind, "codecs": [:], "groupId": 1, "description": ""])
        }
        append(audioTransceiver, kind: "AUDIO"); append(videoTransceiver, kind: "VIDEO"); append(sharingTransceiver, kind: "DISPLAY_VIDEO")
        return ["sdp": offer.sdp, "pcSeq": sequence, "tracks": tracks]
    }
    func accept(_ answer: [String: Any]) async throws {
        guard let sdp = answer["sdp"] as? String,
              topology == .composite || answer["pcSeq"] as? Int == sequence else { throw NativeRTCError.invalidResponse }
        try await setDescription(.init(type: .answer, sdp: sdp), local: false)
        try await flushCandidates()
    }
    private func description(offer: Bool) async throws -> LKRTCSessionDescription {
        try await withCheckedThrowingContinuation { completion in
            let callback: @Sendable (LKRTCSessionDescription?, Error?) -> Void = { value, error in
                if let error { completion.resume(throwing: error) }
                else if let value { completion.resume(returning: value) }
                else { completion.resume(throwing: NativeRTCError.invalidResponse) }
            }
            let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            if offer { connection.offer(for: constraints, completionHandler: callback) }
            else { connection.answer(for: constraints, completionHandler: callback) }
        }
    }
    private func setDescription(_ description: LKRTCSessionDescription, local: Bool) async throws {
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            let callback: @Sendable (Error?) -> Void = { if let error = $0 { completion.resume(throwing: error) } else { completion.resume() } }
            if local { connection.setLocalDescription(description, completionHandler: callback) }
            else { connection.setRemoteDescription(description, completionHandler: callback) }
        }
    }
    func addCandidate(_ value: [String: Any]) async throws {
        guard topology == .composite || value["pcSeq"] as? Int == sequence, let sdp = value["candidate"] as? String,
              let index = value["sdpMlineIndex"] as? Int, index >= 0, index <= 64 else { return }
        let candidate = LKRTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(index), sdpMid: value["sdpMid"] as? String)
        if connection.remoteDescription == nil {
            guard candidates.count < 64 else { throw NativeRTCError.invalidResponse }; candidates.append(candidate)
        } else { try await add(candidate) }
    }
    private func add(_ candidate: LKRTCIceCandidate) async throws {
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            connection.add(candidate) { if let error = $0 { completion.resume(throwing: error) } else { completion.resume() } }
        }
    }
    private func flushCandidates() async throws {
        let waiting = candidates; candidates.removeAll()
        for candidate in waiting { try await add(candidate) }
    }
    func localSDPSent() {
        lock.lock(); localDescriptionAcknowledged = true; let waiting = localCandidates; localCandidates.removeAll(); lock.unlock()
        for candidate in waiting { onCandidate?(candidate) }
    }
    private var presentationTrack: LKRTCVideoTrack?
    private func updateVideoSender() {
        if topology == .composite { videoTransceiver?.sender.track = presentationTrack ?? videoTrack }
        else { videoTransceiver?.sender.track = videoTrack }
    }
    @MainActor func setSharing(_ track: LKRTCVideoTrack?) {
        if topology == .composite {
            presentationTrack = track; updateVideoSender(); return
        }
        if sharingTransceiver == nil, track != nil {
            let settings = LKRTCRtpTransceiverInit(); settings.direction = .sendOnly
            sharingTransceiver = connection.addTransceiver(of: .video, init: settings)
            preferPublishingH264(sharingTransceiver)
        }
        sharingTransceiver?.sender.track = track
    }
    @MainActor func setMicrophone(_ enabled: Bool, profile: StudioAudioProfile) {
        if !enabled { audioTransceiver?.sender.track = nil; audioTrack = nil; return }
        if audioTrack == nil || audioProfile != profile {
            let source = factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: [
                "googEchoCancellation": "true", "googNoiseSuppression": profile == .conversation ? "true" : "false",
                "googAutoGainControl": profile == .conversation ? "true" : "false"], optionalConstraints: nil))
            audioTrack = factory.audioTrack(with: source, trackId: "microphone")
            audioProfile = profile
        }
        audioTransceiver?.sender.track = audioTrack
    }
    @MainActor func microphoneLevel() async -> Float? {
        guard !closed, let sender = audioTransceiver?.sender, sender.track?.isEnabled == true else { return nil }
        let report: LKRTCStatisticsReport = await withCheckedContinuation { completion in
            connection.statistics(for: sender) { completion.resume(returning: $0) }
        }
        return report.statistics.values.compactMap { entry -> Float? in
            guard entry.type == "media-source", entry.values["kind"] as? String == "audio" else { return nil }
            return (entry.values["audioLevel"] as? NSNumber)?.floatValue
        }.max()
    }
    @MainActor var microphoneSending: Bool { audioTransceiver?.sender.track?.isEnabled == true }
    @MainActor func setCamera(_ enabled: Bool) async throws {
        guard !closed || !enabled else { throw CancellationError() }
        guard enabled != (camera != nil) else { return }
        if !enabled {
            cameraEnergySubscription = nil; cameraSource = nil
            videoTrack = nil; updateVideoSender(); captureDevice = nil
            let old = camera; camera = nil
            if let old { await withCheckedContinuation { completion in old.stopCapture { completion.resume() } } }
            return
        }
        guard let device = LKRTCCameraVideoCapturer.captureDevices().first(where: { $0.position == cameraPosition }) ?? LKRTCCameraVideoCapturer.captureDevices().first else { throw NativeRTCError.invalidResponse }
        let formats = LKRTCCameraVideoCapturer.supportedFormats(for: device)
        guard let format = formats.filter({
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription); return d.width <= 1280 && d.height <= 720
        }).max(by: {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription), b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return a.width * a.height < b.width * b.height
        }) ?? formats.first else { throw NativeRTCError.invalidResponse }
        let source = factory.videoSource()
        let capturer = LKRTCCameraVideoCapturer(delegate: source)
        camera = capturer; captureDevice = device
        let fps = min(24, MediaEnergyBudget.shared.cameraFPS, Int(format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 24))
        do {
            try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
                capturer.startCapture(with: device, format: format, fps: fps) { if let error = $0 { completion.resume(throwing: error) } else { completion.resume() } }
            }
        } catch {
            if camera === capturer { camera = nil; captureDevice = nil }
            await withCheckedContinuation { completion in capturer.stopCapture { completion.resume() } }
            throw error
        }
        if closed || Task.isCancelled || camera !== capturer {
            await withCheckedContinuation { completion in capturer.stopCapture { completion.resume() } }
            throw CancellationError()
        }
        videoTrack = factory.videoTrack(with: source, trackId: "camera")
        cameraSource = source
        cameraEnergySubscription = MediaEnergyBudget.shared.$pressure.removeDuplicates().sink { [weak self, weak capturer] pressure in
            Task { @MainActor [weak self, weak capturer] in
                guard let self, let capturer, self.camera === capturer, !self.closed else { return }
                let fps = pressure == .normal ? 24 : pressure == .constrained ? 15 : 10
                let minimum = Int(ceil(device.activeFormat.videoSupportedFrameRateRanges.map(\.minFrameRate).min() ?? 1))
                let maximum = Int(floor(device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? Double(fps)))
                let rate = max(minimum, min(maximum, fps))
                self.cameraSource?.adaptOutputFormat(toWidth: 1280, height: 720, fps: Int32(rate))
                do {
                    try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(rate))
                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(rate))
                } catch { /* Capture continues at its previously accepted rate. */ }
            }
        }
        updateVideoSender()
    }
    @MainActor func flipCamera() async throws {
        guard camera != nil else { return }
        cameraPosition = cameraPosition == .front ? .back : .front
        try await setCamera(false); try await setCamera(true)
    }
    @MainActor func close() async {
        if let decoderObservation { NotificationCenter.default.removeObserver(decoderObservation) }
        decoderObservation = nil; onDecoderFallback = nil
        closed = true
        setSharing(nil)
        onCandidate = nil; onTrack = nil; onState = nil
        try? await setCamera(false); setMicrophone(false, profile: .conversation); connection.close()
    }
    func peerConnection(_ pc: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: LKRTCPeerConnection) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didChange state: LKRTCIceConnectionState) { onState?(state) }
    func peerConnection(_ pc: LKRTCPeerConnection, didChange state: LKRTCIceGatheringState) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        let value: [String: Any] = ["candidate": candidate.sdp, "sdpMlineIndex": candidate.sdpMLineIndex,
            "sdpMid": candidate.sdpMid ?? "0", "target": target, "pcSeq": sequence]
        lock.lock()
        if !localDescriptionAcknowledged { if localCandidates.count < 64 { localCandidates.append(value) }; lock.unlock(); return }
        lock.unlock(); onCandidate?(value)
    }
    func peerConnection(_ pc: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didAdd receiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        for transceiver in pc.transceivers where transceiver.receiver.receiverId == receiver.receiverId { reportTrack(transceiver) }
    }
    func peerConnection(_ pc: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) { reportTrack(transceiver) }
    private func reportTrack(_ transceiver: LKRTCRtpTransceiver) {
        guard !transceiver.mid.isEmpty, let video = transceiver.receiver.track as? LKRTCVideoTrack else { return }
        onTrack?(transceiver.mid, video)
    }
}

/// Observe publisher input stats without a second capturer. Demand comes from
/// the meeting/PiP meter; a retired request cannot revive its signal.
@MainActor
final class NativeMicrophoneProbe {
    private var task: Task<Void, Never>?
    private var observation: AnyCancellable?
    init(activity: MicrophoneActivity, measure: @escaping @MainActor () async -> Float?) {
        observation = activity.$samplingNeeded.removeDuplicates().sink { [weak self, weak activity] needed in
            guard let self else { return }
            self.task?.cancel(); self.task = nil
            guard needed else { return }
            self.task = Task { [weak activity] in
                while !Task.isCancelled {
                    let level = await measure()
                    guard !Task.isCancelled, let activity, activity.samplingNeeded else { return }
                    if let level { activity.receive(rms: level) }
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                }
            }
        }
    }
    deinit { task?.cancel() }
}
