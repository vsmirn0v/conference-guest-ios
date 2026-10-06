import AVFoundation
import Combine

@MainActor
protocol PrivateMicrophoneCapturing: AnyObject {
    func start(standalone: Bool, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws
    func beginRecording()
    func finishRecording() -> Data?
    func stop()
}

/// No tracks, encoder, room or network references. The bounded clip stays in RAM.
@MainActor
final class PrivateMicrophoneCapture: PrivateMicrophoneCapturing {
    private var engine: AVAudioEngine?
    private let clip = SoundCheckClip()
    private var tapped = false
    private var standalone = false
    func start(standalone: Bool, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        let session = AVAudioSession.sharedInstance()
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        guard allowed else { throw SoundCheckError.permission }
        try Task.checkCancellation()
        stop()
        self.standalone = standalone
        if standalone {
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
            try session.setActive(true)
        }
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else { throw SoundCheckError.input }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [clip] buffer, _ in
            clip.append(buffer)
            onBuffer(buffer)
        }
        tapped = true
        do { try engine.start() } catch { stop(); throw error }
    }
    func beginRecording() { clip.begin() }
    func finishRecording() -> Data? { clip.finish() }
    func stop() {
        if tapped { engine?.inputNode.removeTap(onBus: 0); tapped = false }
        engine?.stop(); engine = nil
        clip.clear()
        if standalone { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); standalone = false }
    }
}

enum SoundCheckError: LocalizedError {
    case permission, input, mute
    var errorDescription: String? {
        switch self {
        case .permission: return L("Allow microphone access in Settings to test your sound.")
        case .input: return L("Microphone input is unavailable. Check your audio device and try again.")
        case .mute: return L("The meeting microphone could not be muted. Try again before testing.")
        }
    }
}

/// Downmix a maximum of five seconds. No unbounded buffers or audio files.
final class SoundCheckClip: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var rate: Double = 0
    private var recording = false
    func begin() { lock.lock(); defer { lock.unlock() }; samples.removeAll(keepingCapacity: true); rate = 0; recording = true }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard recording, let data = buffer.floatChannelData, !buffer.format.isInterleaved,
              buffer.format.sampleRate <= 192_000, buffer.format.sampleRate > 0 else { return }
        if rate == 0 { rate = buffer.format.sampleRate; samples.reserveCapacity(Int(rate * 5)) }
        guard rate == buffer.format.sampleRate else { recording = false; return }
        let count = min(Int(buffer.frameLength), Int(rate * 5) - samples.count)
        let channels = Int(buffer.format.channelCount)
        guard channels > 0, count > 0 else { return }
        for i in 0..<count {
            var value: Float = 0
            for c in 0..<channels { value += data[c][i] }
            value /= Float(channels)
            samples.append(value.isFinite ? Int16(max(-32768, min(32767, value * 32767))) : 0)
        }
    }
    func finish() -> Data? {
        lock.lock(); defer { lock.unlock() }
        recording = false
        guard !samples.isEmpty else { return nil }
        var result = Data()
        func word<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
        result.append(contentsOf: "RIFF".utf8); word(UInt32(36 + samples.count * 2)); result.append(contentsOf: "WAVEfmt ".utf8)
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(rate)); word(UInt32(rate) * 2)
        word(UInt16(2)); word(UInt16(16)); result.append(contentsOf: "data".utf8); word(UInt32(samples.count * 2))
        samples.withUnsafeBytes { result.append(contentsOf: $0) }
        samples.removeAll(keepingCapacity: false)
        return result
    }
    func clear() { lock.lock(); defer { lock.unlock() }; recording = false; samples.removeAll(keepingCapacity: false); rate = 0 }
}

@MainActor
final class PrivateSoundCheck: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum State: Equatable { case idle, starting, listening, recording, sampleReady, playing, failed }
    @Published private(set) var state: State = .idle
    @Published private(set) var error: String?
    let activity = MicrophoneActivity()
    var verifyMuted: (() async throws -> Void)?
    private let capture: PrivateMicrophoneCapturing
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var sample: Data?
    private var player: AVAudioPlayer?
    private var sink: MicrophoneSampleSink?
    private var standalone = false
    private var interruptions: [NSObjectProtocol] = []
    init(capture: PrivateMicrophoneCapturing? = nil) { self.capture = capture ?? PrivateMicrophoneCapture(); super.init()
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification] {
            interruptions.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, self.state != .idle else { return }
                    if notification.name == AVAudioSession.interruptionNotification,
                       (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue != AVAudioSession.InterruptionType.began.rawValue { return }
                    if notification.name == AVAudioSession.routeChangeNotification,
                       (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue == AVAudioSession.RouteChangeReason.categoryChange.rawValue { return }
                    self.stop()
                }
            })
        }
    }
    deinit { interruptions.forEach { NotificationCenter.default.removeObserver($0) } }
    var capturing: Bool { state == .listening || state == .recording }
    var running: Bool { capturing || state == .starting }
    func start(standalone: Bool) {
        stop()
        guard standalone || verifyMuted != nil else {
            state = .failed; error = SoundCheckError.mute.localizedDescription; return
        }
        self.standalone = standalone
        state = .starting; error = nil
        let epoch = generation
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.verifyMuted?()
                try Task.checkCancellation()
                guard self.generation == epoch else { return }
                let sink = MicrophoneSampleSink { [weak self] rms in
                    Task { @MainActor in guard let self, self.generation == epoch, self.running else { return }; self.activity.receive(rms: rms) }
                }
                self.sink = sink
                try await self.capture.start(standalone: standalone) { sink.receive($0) }
                try Task.checkCancellation()
                guard self.generation == epoch else { return }
                self.activity.setStatus(.on); self.state = .listening
            } catch is CancellationError {
            } catch {
                guard self.generation == epoch else { return }
                self.capture.stop(); self.activity.setStatus(.unavailable)
                self.error = error.localizedDescription; self.state = .failed
            }
        }
    }
    func record() {
        guard state == .listening else { return }
        capture.beginRecording(); state = .recording
        let epoch = generation
        operation = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.generation == epoch else { return }
            self.sample = self.capture.finishRecording()
            self.capture.stop(); self.sink = nil; self.activity.setStatus(.muted)
            self.state = self.sample == nil ? .failed : .sampleReady
            if self.sample == nil { self.error = SoundCheckError.input.localizedDescription }
        }
    }
    func play() {
        guard state == .sampleReady, let sample else { return }
        do {
            // Recording has stopped before playback. Never monitor the mic live.
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(data: sample); player?.delegate = self
            guard player?.play() == true else { throw SoundCheckError.input }
            state = .playing
        } catch { self.error = error.localizedDescription; state = .failed }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in guard self?.player === player else { return }; self?.player = nil; self?.state = .sampleReady }
    }
    func stop() {
        generation = UUID(); operation?.cancel(); operation = nil
        player?.stop(); player = nil; sample = nil; sink = nil
        capture.stop(); activity.setStatus(.muted); activity.clear()
        if standalone { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); standalone = false }
        state = .idle; error = nil
    }
}
