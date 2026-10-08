import AVFoundation
import Combine

@MainActor
protocol PrivateMicrophoneCapturing: AnyObject {
    func start(standalone: Bool, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws
    func stop()
}

/// Local metering only. No tracks, encoder, recording buffers or network references.
@MainActor
final class PrivateMicrophoneCapture: PrivateMicrophoneCapturing {
    private var engine: AVAudioEngine?
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
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            onBuffer(buffer)
        }
        tapped = true
        do { try engine.start() } catch { stop(); throw error }
    }
    func stop() {
        if tapped { engine?.inputNode.removeTap(onBus: 0); tapped = false }
        engine?.stop(); engine = nil
        if standalone { standalone = false; try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
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

@MainActor
final class PrivateSoundCheck: NSObject, ObservableObject {
    enum State: Equatable { case idle, starting, listening, failed }
    @Published private(set) var state: State = .idle
    @Published private(set) var error: String?
    let activity = MicrophoneActivity()
    var verifyMuted: (() async throws -> Void)?
    private let capture: PrivateMicrophoneCapturing
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var sink: MicrophoneSampleSink?
    private var interruptions: [NSObjectProtocol] = []
    init(capture: PrivateMicrophoneCapturing? = nil) { self.capture = capture ?? PrivateMicrophoneCapture(); super.init()
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification] {
            interruptions.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, self.state != .idle else { return }
                    if notification.name == AVAudioSession.interruptionNotification,
                       (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue != AVAudioSession.InterruptionType.began.rawValue { return }
                    if notification.name == AVAudioSession.routeChangeNotification,
                       (self.state == .starting || (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue == AVAudioSession.RouteChangeReason.categoryChange.rawValue) { return }
                    self.stop()
                }
            })
        }
    }
    deinit { interruptions.forEach { NotificationCenter.default.removeObserver($0) } }
    var capturing: Bool { state == .listening }
    var running: Bool { capturing || state == .starting }
    func start(standalone: Bool) {
        stop()
        guard standalone || verifyMuted != nil else {
            state = .failed; error = SoundCheckError.mute.localizedDescription; return
        }
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
                guard self.generation == epoch else { return }
                self.stop()
            } catch {
                guard self.generation == epoch else { return }
                self.capture.stop(); self.activity.setStatus(.unavailable)
                self.error = error.localizedDescription; self.state = .failed
            }
        }
    }
    func stop() {
        generation = UUID(); operation?.cancel(); operation = nil
        sink = nil
        // Deactivation can synchronously deliver another route notification.
        // Retire the state first so it cannot recursively stop this capture.
        state = .idle; error = nil
        activity.setStatus(.muted); activity.clear(); capture.stop()
    }
}
