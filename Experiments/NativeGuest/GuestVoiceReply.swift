import AVFoundation
import Foundation

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
    private(set) weak var engine: AVAudioEngine?
    private weak var source: AVAudioNode?
    private weak var inputMixer: AVAudioNode?
    private(set) var playerFormat: AVAudioFormat?
    private let lock = NSLock()
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
        engine.attach(gate); engine.attach(gateActivity); engine.attach(player)
        gate.outputVolume = gateOpen ? 1 : 0
    }

    /// Wires microphone → gate → input mixer and player → input mixer.
    /// Returns false when the formats cannot be built.
    @discardableResult func connect(source: AVAudioNode?, inputMixer: AVAudioNode, format: AVAudioFormat) -> Bool {
        guard let engine, let playerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                                           channels: format.channelCount, interleaved: false) else { return false }
        lock.lock(); self.playerFormat = playerFormat; self.source = source; self.inputMixer = inputMixer; lock.unlock()
        if let source { engine.connect(source, to: gate, format: format) }
        engine.connect(gateActivity, to: gate, format: playerFormat)
        engine.connect(gate, to: inputMixer, format: format)
        engine.connect(player, to: inputMixer, format: playerFormat)
        return true
    }

    func setGate(open: Bool) { gate.outputVolume = open ? 1 : 0 }
    var gateOpen: Bool { gate.outputVolume != 0 }

    func detach() {
        player.stop()
        guard let engine else { return }
        if player.engine === engine { engine.detach(player) }
        if gateActivity.engine === engine { engine.detach(gateActivity) }
        if gate.engine === engine { engine.detach(gate) }
    }

    /// Converts and schedules one buffer; `completion` runs once it has been played.
    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) -> TimeInterval? {
        lock.lock(); let format = playerFormat; lock.unlock()
        guard let format, player.engine != nil, let converted = Self.convert(buffer, to: format) else { return nil }
        player.scheduleBuffer(converted, completionCallbackType: .dataPlayedBack) { _ in completion() }
        if let engine, engine.isRunning || engine.isInManualRenderingMode, !player.isPlaying { player.play() }
        return Double(converted.frameLength) / format.sampleRate
    }

    /// Plays one buffer; true once it was played back, false when it could not
    /// start or did not finish within its length plus `grace` seconds.
    func play(_ buffer: AVAudioPCMBuffer, grace: TimeInterval = 2) async -> Bool {
        guard let engine, engine.isRunning else { return false }
        return await withCheckedContinuation { continuation in
            let once = Once()
            guard let seconds = schedule(buffer, completion: { once.run { continuation.resume(returning: true) } }) else {
                continuation.resume(returning: false); return
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds + grace) {
                once.run { continuation.resume(returning: false) }
            }
        }
    }

    func stop() { player.stop() }

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

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock(); let first = !done; done = true; lock.unlock()
            if first { body() }
        }
    }
}
