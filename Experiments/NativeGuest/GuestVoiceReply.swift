import AVFoundation
import Foundation

/// This permit and AVAudioPlayerNode scheduling share the main actor with
/// meeting consent and media control. Cancelling stops already scheduled audio
/// synchronously and prevents a prepared buffer from starting later.
@MainActor final class GuestAutonomousVoicePlayback {
    enum Outcome: Equatable { case notStarted, completed, interrupted, unknown }

    struct CaptureAdmission {
        let open: () -> Bool
        let isOpen: () -> Bool
        let close: () -> Void
    }

    private let deadline: Date
    private var stopped = false
    private var resolve: ((Outcome) -> Void)?
    private var stopPlayer: (() -> Void)?
    private var localGain: ((Float) -> Void)?
    private var capture: CaptureAdmission?
    private(set) var started = false

    init(deadline: Date) { self.deadline = deadline }

    var canStart: Bool { !stopped && !started && Date() < deadline }

    func cancel() { finish(started ? .interrupted : .notStarted, stopping: true) }
    func setLocalGain(_ gain: Float) { localGain?(gain) }

    func bindCapture(_ admission: CaptureAdmission) -> Bool {
        guard canStart, capture == nil else { return false }
        capture = admission
        return true
    }
    fileprivate func openCapture() -> Bool { capture?.open() ?? true }
    var captureIsOpen: Bool { capture?.isOpen() ?? true }

    fileprivate func start(stop: @escaping () -> Void, localGain: @escaping (Float) -> Void,
                           resolve: @escaping (Outcome) -> Void) {
        started = true
        stopPlayer = stop
        self.localGain = localGain
        self.resolve = resolve
    }

    fileprivate func finish(_ outcome: Outcome, stopping: Bool = false) {
        guard !stopped else { return }
        stopped = true
        let resolve = resolve, stop = stopPlayer
        self.resolve = nil; stopPlayer = nil; localGain = nil
        let capture = capture
        self.capture = nil
        capture?.close()
        if stopping { stop?() }
        resolve?(outcome)
    }
}

/// The voice-reply part of an audio engine's input graph:
///
///     microphone ─► gate ─┐
///                         ├─► input mixer ─► what the meeting receives
///     reply player ───────┘
///
/// The gate removes your microphone (its volume is exactly 0 or 1) while the
/// player keeps playing. The module's own mute acts on the input mixer, after
/// both, so a muted meeting hears neither. Nodes are attached to one engine
/// and reconnected each time that engine configures its input.
final class GuestVoiceReplyGraph: @unchecked Sendable {
    /// The mixer ramps volume changes; a closed gate reaches exact silence within
    /// this time (measured offline in MicrophoneMoveTests). Wait this long after
    /// closing before anything unmutes.
    static let gateSettleMilliseconds = 150
    let gate = AVAudioMixerNode()
    /// An unplayed second input keeps the microphone gate in mixer mode under VPIO,
    /// matching LiveKit's microphone mixer rather than a single-input pass-through.
    private let gateActivity = AVAudioPlayerNode()
    let player = AVAudioPlayerNode()
    private let monitor = AVAudioPlayerNode()
    private(set) weak var engine: AVAudioEngine?
    private weak var source: AVAudioNode?
    private weak var inputMixer: AVAudioNode?
    private(set) var playerFormat: AVAudioFormat?
    private let lock = NSLock()
    private let playbackLock = NSLock()
    private var monitorFormat: AVAudioFormat?
    private weak var monitorMixer: AVAudioMixerNode?
    private var autonomous: (id: UUID, interrupted: @Sendable () -> Void)?
    private enum ApprovedRoute: Sendable { case outgoing, local }
    private var approved: (id: UUID, complete: @Sendable (Bool) -> Void, outgoing: Bool, local: Bool)?
#if DEBUG
    /// Native topology only: no audio content is retained.
    var evidence: [String: Any] {
        guard let engine, gate.engine === engine, gateActivity.engine === engine, player.engine === engine,
              inputMixer?.engine === engine else { return ["attached": false, "gateOpen": gateOpen] }
        func identity(_ node: AVAudioNode?) -> String {
            guard let node else { return "nil" }
            return "\(type(of: node)):\(ObjectIdentifier(node).hashValue)"
        }
        func destinations(for node: AVAudioNode?) -> [String] {
            guard let node else { return [] }
            return engine.outputConnectionPoints(for: node, outputBus: 0).map { identity($0.node) }
        }
        let mixerInputs = inputMixer.map { mixer in
            (0..<mixer.numberOfInputs).compactMap { engine.inputConnectionPoint(for: mixer, inputBus: $0)?.node }
                .map { identity($0) }
        } ?? []
        return ["attached": gate.engine === engine && player.engine === engine,
                "engineRunning": engine.isRunning, "gateOpen": gateOpen,
                "gateVolume": gate.outputVolume, "source": identity(source), "gate": identity(gate),
                "sourceConnected": destinations(for: source), "gateConnected": destinations(for: gate),
                "engineInput": identity(engine.inputNode), "engineInputConnected": destinations(for: engine.inputNode),
                "inputMixer": identity(inputMixer), "inputMixerSources": mixerInputs]
    }
#endif

    init(engine: AVAudioEngine, gateOpen: Bool) {
        self.engine = engine
        engine.attach(gate); engine.attach(gateActivity); engine.attach(player); engine.attach(monitor)
        gate.outputVolume = gateOpen ? 1 : 0
    }

    /// Wires microphone → gate → input mixer and player → input mixer.
    /// Returns false when the formats cannot be built.
    @discardableResult func connect(source: AVAudioNode?, inputMixer: AVAudioNode, format: AVAudioFormat) -> Bool {
        guard let engine, let playerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                                           channels: format.channelCount, interleaved: false) else { return false }
        lock.lock(); self.playerFormat = nil; lock.unlock()
        stop()
        if let source { engine.connect(source, to: gate, format: format) }
        engine.connect(gateActivity, to: gate, format: playerFormat)
        engine.connect(gate, to: inputMixer, format: format)
        engine.connect(player, to: inputMixer, format: playerFormat)
        lock.lock(); self.playerFormat = playerFormat; self.source = source; self.inputMixer = inputMixer; lock.unlock()
        return true
    }

    @discardableResult func setGate(open: Bool) -> Bool {
        playbackLock.lock(); defer { playbackLock.unlock() }
        // The process PCM path may be open for a muted user's reply. A raw
        // gate request must wait until that playback has released it.
        guard !open || autonomous == nil else { return false }
        gate.outputVolume = open ? 1 : 0
        return gateOpen == open
    }
    var gateOpen: Bool { gate.outputVolume != 0 }
    var isConnected: Bool {
        guard let engine, player.engine === engine else { return false }
        return currentPlayerFormat() != nil
    }

    func connectMonitor(to mixer: AVAudioMixerNode, format: AVAudioFormat) {
        playbackLock.lock()
        guard let engine, mixer !== inputMixer, mixer.engine === engine, monitor.engine === engine,
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                      channels: format.channelCount, interleaved: false),
              monitorMixer !== mixer || monitorFormat != pcm else { playbackLock.unlock(); return }
        let interrupted = stopLocked()
        engine.connect(monitor, to: mixer, format: pcm)
        monitorMixer = mixer
        monitorFormat = pcm
        playbackLock.unlock()
        interrupted?()
    }

    func detach() {
        playbackLock.lock()
        let interrupted = stopLocked()
        if let engine {
            if player.engine === engine { engine.detach(player) }
            if monitor.engine === engine { engine.detach(monitor) }
            if gateActivity.engine === engine { engine.detach(gateActivity) }
            if gate.engine === engine { engine.detach(gate) }
        }
        monitorMixer = nil; monitorFormat = nil
        playbackLock.unlock()
        interrupted?()
    }

    /// Converts and schedules one buffer; `completion` runs after rendering into the input mixer.
    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) -> TimeInterval? {
        lock.lock(); let format = playerFormat; lock.unlock()
        guard let format, player.engine != nil, let converted = Self.convert(buffer, to: format) else { return nil }
        player.scheduleBuffer(converted, completionCallbackType: .dataRendered) { _ in completion() }
        if let engine, engine.isRunning || engine.isInManualRenderingMode, !player.isPlaying { player.play() }
        return Double(converted.frameLength) / format.sampleRate
    }

    /// Plays one buffer; true once it was played back, false when it could not
    /// start or did not finish within its length plus `grace` seconds.
    func play(_ buffer: AVAudioPCMBuffer, localGain: Float? = nil, grace: TimeInterval = 2) async -> Bool {
        guard !Task.isCancelled, let engine, engine.isRunning,
              let format = currentPlayerFormat(), let converted = Self.convert(buffer, to: format) else { return false }
        let seconds = Double(converted.frameLength) / format.sampleRate
        guard seconds.isFinite, seconds > 0 else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                playbackLock.lock()
                guard !Task.isCancelled, engine.isRunning, player.engine === engine, approved == nil, autonomous == nil else {
                    playbackLock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                let mirror = localGain.flatMap { gain -> AVAudioPCMBuffer? in
                    guard gain > 0, !gateOpen, let monitorFormat, monitorMixer?.engine === engine else { return nil }
                    return Self.convert(buffer, to: monitorFormat)
                }
                guard localGain == nil || mirror != nil else {
                    playbackLock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                approved = (id, { continuation.resume(returning: $0) }, true, mirror != nil)
                player.scheduleBuffer(converted, completionCallbackType: .dataRendered) { [weak self] _ in
                    DispatchQueue.global(qos: .userInitiated).async {
                        self?.finishApproved(id, rendered: .outgoing)
                    }
                }
                if let mirror, let localGain {
                    monitor.volume = localGain
                    monitor.scheduleBuffer(mirror, completionCallbackType: .dataRendered) { [weak self] _ in
                        DispatchQueue.global(qos: .userInitiated).async {
                            self?.finishApproved(id, rendered: .local)
                        }
                    }
                    monitor.play()
                }
                if !player.isPlaying { player.play() }
                playbackLock.unlock()
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds + max(0, grace)) { [weak self] in
                    self?.finishApproved(id)
                }
            }
        } onCancel: { [weak self] in
            self?.finishApproved(id)
        }
    }

    private func finishApproved(_ id: UUID, rendered route: ApprovedRoute? = nil) {
        playbackLock.lock()
        guard var current = approved, current.id == id else { playbackLock.unlock(); return }
        let completed = route != nil && engine?.isRunning == true && player.engine === engine
        if completed {
            if route == .outgoing { current.outgoing = false } else { current.local = false }
            if current.outgoing || current.local {
                approved = current
                playbackLock.unlock()
                return
            }
        }
        approved = nil
        player.stop()
        monitor.stop()
        playbackLock.unlock()
        current.complete(completed)
    }

    func setApprovedLocalGain(_ gain: Float) {
        playbackLock.lock(); defer { playbackLock.unlock() }
        if approved?.local == true { monitor.volume = gain }
    }

    @MainActor func playAutonomous(_ buffer: AVAudioPCMBuffer, permit: GuestAutonomousVoicePlayback,
                                  canStart: @MainActor () -> Bool = { true },
                                  localGain: @MainActor () -> Float? = { nil },
                                  captureReady: @MainActor () -> Bool = { true },
                                  onStarted: @MainActor () -> Void = {},
                                  grace: TimeInterval = 2) async -> GuestAutonomousVoicePlayback.Outcome {
        guard !Task.isCancelled, permit.canStart, let engine, engine.isRunning,
              let format = currentPlayerFormat(), let converted = Self.convert(buffer, to: format) else { return .notStarted }
        let seconds = Double(converted.frameLength) / format.sampleRate
        guard seconds.isFinite, seconds > 0 else { return .notStarted }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, permit.canStart, canStart(), engine.isRunning,
                      player.engine === engine else {
                    continuation.resume(returning: .notStarted)
                    return
                }
                let gain = localGain(), id = UUID()
                playbackLock.lock()
                guard engine.isRunning, player.engine === engine, autonomous == nil, approved == nil, !gateOpen else {
                    playbackLock.unlock()
                    continuation.resume(returning: .notStarted)
                    return
                }
                let mirror = gain.flatMap { gain -> AVAudioPCMBuffer? in
                    guard gain > 0, let monitorFormat, monitorMixer?.engine === engine else { return nil }
                    return Self.convert(buffer, to: monitorFormat)
                }
                guard gain == nil || mirror != nil, permit.openCapture(), captureReady() else {
                    playbackLock.unlock()
                    permit.cancel()
                    continuation.resume(returning: .notStarted)
                    return
                }
                player.stop()
                autonomous = (id, { Task { @MainActor in permit.cancel() } })
                permit.start(stop: { [weak self] in self?.stopAutonomous(id) },
                    localGain: { [weak self] gain in self?.updateMonitorGain(gain, id: id) }) {
                        continuation.resume(returning: $0)
                    }
                player.scheduleBuffer(converted, completionCallbackType: .dataRendered) { _ in
                    Task { @MainActor in
                        let outcome: GuestAutonomousVoicePlayback.Outcome = if !self.isAutonomous(id) || !permit.captureIsOpen { .interrupted }
                            else if engine.isRunning, self.player.engine === engine { .completed }
                            else { .unknown }
                        permit.finish(outcome, stopping: true)
                    }
                }
                if let mirror, let gain {
                    monitor.volume = gain
                    monitor.scheduleBuffer(mirror, completionHandler: nil)
                    monitor.play()
                }
                player.play()
                playbackLock.unlock()
                onStarted()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(seconds + max(0, grace)))
                    permit.finish(.unknown, stopping: true)
                }
            }
        } onCancel: {
            Task { @MainActor in permit.cancel() }
        }
    }

    private func currentPlayerFormat() -> AVAudioFormat? {
        lock.lock(); defer { lock.unlock() }
        return playerFormat
    }

    func stop() {
        playbackLock.lock(); let interrupted = stopLocked(); playbackLock.unlock()
        interrupted?()
    }

    private func stopLocked() -> (@Sendable () -> Void)? {
        let interrupted = autonomous?.interrupted
        let stopped = approved?.complete
        autonomous = nil
        approved = nil
        player.stop()
        monitor.stop()
        stopped?(false)
        return interrupted
    }

    private func stopAutonomous(_ id: UUID) {
        playbackLock.lock(); defer { playbackLock.unlock() }
        guard autonomous?.id == id else { return }
        _ = stopLocked()
    }

    private func isAutonomous(_ id: UUID) -> Bool {
        playbackLock.lock(); defer { playbackLock.unlock() }
        return autonomous?.id == id
    }

    private func updateMonitorGain(_ gain: Float, id: UUID) {
        playbackLock.lock(); defer { playbackLock.unlock() }
        guard autonomous?.id == id, monitor.isPlaying else { return }
        if gain > 0 { monitor.volume = gain }
        else { monitor.stop() }
    }

    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

}
