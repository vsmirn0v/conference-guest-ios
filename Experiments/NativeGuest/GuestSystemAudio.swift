import AVFoundation
import Foundation
import LiveKitWebRTC

/// A track sink, not a second capture or playout path. Only aggregate energy is retained.
final class GuestPCMMeter: NSObject, LKRTCAudioRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var measured = GuestAudioSnapshot()
    private var bufferCount = 0
    private var lastLevel: Float?
    private var lastSampleTime: TimeInterval = 0
    private var callback = GuestStartupAudioCallback()
    var callbackSnapshot: GuestStartupAudioCallback { locked { callback } }
#if DEBUG
    var callbackEvidence: [String: Any] { callbackSnapshot.evidence }
#endif
    var snapshot: GuestAudioSnapshot { locked { measured } }
    var buffers: Int { locked { bufferCount } }
    var level: Float? { locked { ProcessInfo.processInfo.systemUptime - lastSampleTime < 0.5 ? lastLevel : nil } }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    func reset() { locked { measured = GuestAudioSnapshot(); bufferCount = 0; lastLevel = nil; lastSampleTime = 0; callback = .init() } }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let receivedUptime = ProcessInfo.processInfo.systemUptime
        var samples = 0, energy = 0.0
        let format = pcmBuffer.format
        let deliveredFormat = withExtendedLifetime(format) { GuestStartupAudioCallback.Format(format.streamDescription.pointee) }
        for buffer in UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList) {
            guard let data = buffer.mData else { continue }
            let expected = Int(pcmBuffer.frameLength) * Int(buffer.mNumberChannels)
            func accumulate<T>(_ type: T.Type, normalize: (T) -> Double) {
                let count = min(expected, Int(buffer.mDataByteSize) / MemoryLayout<T>.size)
                let values = data.assumingMemoryBound(to: T.self)
                for index in 0..<count {
                    let value = normalize(values[index])
                    if value.isFinite { energy += value * value; samples += 1 }
                }
            }
            switch format.commonFormat {
            case .pcmFormatFloat32: accumulate(Float.self) { Double($0) }
            case .pcmFormatFloat64: accumulate(Double.self) { $0 }
            case .pcmFormatInt16: accumulate(Int16.self) { Double($0) / 32768 }
            case .pcmFormatInt32: accumulate(Int32.self) { Double($0) / 2147483648 }
            default: break
            }
        }
        locked {
            callback = .init(count: UInt64(bufferCount + 1), frames: Int(pcmBuffer.frameLength),
                format: deliveredFormat, uptime: receivedUptime)
            measured.samples += samples; measured.energy += energy; bufferCount += 1
            lastLevel = samples > 0 ? Float(sqrt(energy / Double(samples))) : nil
            lastSampleTime = ProcessInfo.processInfo.systemUptime
        }
    }
}

enum GuestSystemAudioError: LocalizedError {
    case microphonePermissionRequired, setupFailedOrTimedOut, physicalOwnerBusy
    var errorDescription: String? {
        switch self {
        case .microphonePermissionRequired: "Allow microphone access in System Settings before checking or unmuting."
        case .setupFailedOrTimedOut: "Microphone setup did not finish. Stop the check or leave the meeting before trying again."
        case .physicalOwnerBusy: "The active meeting already owns the microphone. Open its Camera & sound panel to check it."
        }
    }
    static func microphoneActivationFailure(authorization: AVAuthorizationStatus) -> Self {
        switch authorization {
        case .denied, .restricted: .microphonePermissionRequired
        default: .setupFailedOrTimedOut
        }
    }
}

/// Native recording startup may reset the SDK's mixer state. Re-establish the
/// privacy barrier after startup and require its affirmative readback.
enum GuestMutedInputPreparation {
    static func start(mute: () -> Bool, makeAvailable: () -> Bool,
                      startRecording: () -> Bool, isMuted: () -> Bool) -> Bool {
        guard mute() else { return false }
        let available = makeAvailable()
        let started = available && startRecording()
        // A failing native start can still have partially changed mixer state.
        let restored = mute(), confirmed = isMuted()
        return available && started && restored && confirmed
    }
}

/// The shared VPIO owner needs its silent output leg to keep physical input
/// running. Sound remains a separate intent, enforced by the output gain gate.
struct GuestPhysicalAudioAvailability: Equatable {
    let input, output: Bool
    /// Local transcription keeps output running while sound is off: WebRTC decodes
    /// remote audio only when playout pulls it. The mixer is then silenced (or the
    /// shared gate is closed), so nothing is heard.
    init(input: Bool, playoutRequested: Bool, sharedNativeOwner: Bool, transcription: Bool = false) {
        self.input = input
        output = playoutRequested || (sharedNativeOwner && input) || transcription
    }
}

/// Positive writes and logical state changes share MainActor. Native graph
/// callbacks can only silence/bind weak nodes; they never restore positive gain.
final class GuestSharedPlayoutGate: @unchecked Sendable {
    private struct Target {
        let identity: ObjectIdentifier
        let setGain: (Double) -> Bool
    }
    private let enabled: Bool
    private let lock = NSLock()
    private var epoch = UUID(), revision: UInt64 = 0
    private var target: Target?
    private var sound = false, ready = false, retired = false
    private var lastGain: Double = 0
    /// Meeting volume applied while sound is on; mute stays an exact zero.
    private var positiveGain: Double = 1
    private var lastPositiveUptime: TimeInterval?
    private var lastWriteSucceeded = true
    init(enabled: Bool) { self.enabled = enabled }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var currentEpoch: UUID? { enabled ? locked { epoch } : nil }
    func matches(_ expected: UUID?) -> Bool { !enabled || locked { expected == epoch && !retired } }
    var evidence: [String: Any] {
        locked { ["enabled": enabled, "epoch": enabled ? epoch.uuidString : "", "soundRequested": sound,
                  "ready": ready, "retired": retired, "mixerBound": target != nil,
                  "lastGain": lastGain, "lastWriteSucceeded": lastWriteSucceeded,
                  "lastPositiveUptime": lastPositiveUptime.map { $0 as Any } ?? NSNull()] }
    }
    func bind(identity: ObjectIdentifier, setGain: @escaping (Double) -> Bool) -> Bool {
        guard enabled else { return true }
        let muted = setGain(0)
        locked {
            target = muted ? Target(identity: identity, setGain: setGain) : nil; revision &+= 1
            lastGain = 0; lastWriteSucceeded = muted
            if !muted { ready = false }
        }
        if locked({ ready && sound && !retired }) {
            Task { @MainActor [weak self] in _ = self?.reconcile() }
        }
        return muted
    }
    func remove(identity: ObjectIdentifier) {
        guard enabled else { return }
        let removed: Target? = locked {
            guard target?.identity == identity else { return nil }
            let old = target; target = nil; revision &+= 1; return old
        }
        _ = removed?.setGain(0)
    }
    @MainActor func reset(sound: Bool) -> Bool {
        guard enabled else { return true }
        locked { epoch = UUID(); ready = false; retired = false; self.sound = sound; revision &+= 1 }
        return reconcile()
    }
    @MainActor func setSound(_ sound: Bool, expected: UUID?) -> Bool {
        guard enabled else { return true }
        guard matches(expected) else { return false }
        locked {
            self.sound = sound
            if sound && target == nil { ready = false }
            revision &+= 1
        }
        return reconcile()
    }
    /// Changes only the level of an open gate; it never opens or closes sound.
    @MainActor func setVolume(_ volume: Double) -> Bool {
        guard enabled else { return true }
        let value = volume.isFinite ? min(1, max(0, volume)) : 1
        locked { positiveGain = value; revision &+= 1 }
        return reconcile()
    }
    @MainActor func close(expected: UUID? = nil, retire: Bool = false) -> Bool {
        guard enabled else { return true }
        if let expected, !matches(expected) { return true }
        locked {
            ready = false
            if retire { epoch = UUID(); sound = false; retired = true }
            revision &+= 1
        }
        return reconcile()
    }
    @MainActor func open(expected: UUID?) -> Bool {
        guard enabled else { return true }
        guard matches(expected), locked({ sound && target != nil }) else { return false }
        locked { ready = true; revision &+= 1 }
        guard reconcile() else { _ = close(expected: expected); return false }
        return isOpen(expected: expected)
    }
    @MainActor func isOpen(expected: UUID?) -> Bool {
        !enabled || locked { expected == epoch && !retired && sound && ready && target != nil &&
            lastGain == positiveGain && lastWriteSucceeded }
    }
#if DEBUG
    @MainActor func permitsSoundOffProof(expected: UUID?) -> Bool {
        enabled && locked { expected == epoch && !retired && ready && !sound && target != nil &&
            lastGain == 0 && lastWriteSucceeded }
    }
#endif
    @MainActor private func reconcile() -> Bool {
        guard enabled else { return true }
        for _ in 0..<3 {
            let state = locked { (target, revision, !retired && ready && sound ? positiveGain : 0.0, !retired && ready && sound) }
            guard let current = state.0 else { return state.2 == 0 }
            let success = current.setGain(state.2) // No AV/SDK calls under the metadata lock.
            let unchanged = locked { () -> Bool in
                guard revision == state.1 else { return false }
                if success && state.3 && state.2 > 0 && lastGain == 0 { lastPositiveUptime = ProcessInfo.processInfo.systemUptime }
                lastGain = state.2; lastWriteSucceeded = success; return true
            }
            if unchanged { return success }
        }
        let fallback = locked { () -> (Target?, UInt64) in ready = false; revision &+= 1; return (target, revision) }
        let muted = fallback.0?.setGain(0) ?? true
        locked { if revision == fallback.1 { lastGain = 0; lastWriteSucceeded = muted } }
        return false
    }
}

/// Cached timing only: inspecting a stalled operation never calls the ADM worker.
final class GuestAudioOperationTrace: @unchecked Sendable {
    private struct Entry {
        let id: Int, name: String
        let queuedAt: TimeInterval, deadlineAt: TimeInterval
        var startedAt: TimeInterval?, finishedAt: TimeInterval?, timedOutAt: TimeInterval?
        var succeeded: Bool?
        var nativeCall: String?, nativeStartedAt: TimeInterval?, nativeFinishedAt: TimeInterval?
        var nativeResult: String?
        var nativeCalls: [[String: Any]] = []
        func evidence(at now: TimeInterval) -> [String: Any] {
            var value: [String: Any] = ["id": id, "name": name, "queuedAt": queuedAt,
                "deadlineAt": deadlineAt, "callerTimedOut": timedOutAt != nil,
                "stage": finishedAt != nil ? "finished" : startedAt == nil ? "queued" :
                    nativeStartedAt != nil && nativeFinishedAt == nil ? "native-call" : "running"]
            if let startedAt { value["startedAt"] = startedAt; value["queueSeconds"] = startedAt - queuedAt }
            if let finishedAt { value["finishedAt"] = finishedAt }
            if let timedOutAt { value["timedOutAt"] = timedOutAt }
            if let succeeded { value["succeeded"] = succeeded }
            if let nativeCall { value["nativeCall"] = nativeCall }
            if let nativeStartedAt {
                value["nativeStartedAt"] = nativeStartedAt
                value["nativeSeconds"] = (nativeFinishedAt ?? now) - nativeStartedAt
            }
            if let nativeResult { value["nativeResult"] = nativeResult }
            value["nativeCalls"] = nativeCalls
            if let startedAt { value["runSeconds"] = (finishedAt ?? now) - startedAt }
            return value
        }
    }
    private let lock = NSLock()
    private var nextID = 0
    private var entries: [Entry] = []
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    func enqueue(_ name: String, timeout: TimeInterval, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int {
        locked {
            nextID += 1
            entries.removeAll { $0.finishedAt != nil && $0.id < nextID - 16 }
            entries.append(Entry(id: nextID, name: name, queuedAt: now, deadlineAt: now + max(0.01, timeout)))
            return nextID
        }
    }
    func start(_ id: Int, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        locked { if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].startedAt = now } }
    }
    func timedOut(_ id: Int, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        locked { if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].timedOutAt = now } }
    }
    func finish(_ id: Int, succeeded: Bool, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        locked {
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].finishedAt = now; entries[index].succeeded = succeeded
            }
        }
    }
    func beginNativeCall(_ name: String, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        locked {
            if let index = entries.firstIndex(where: { $0.startedAt != nil && $0.finishedAt == nil }) {
                entries[index].nativeCall = name; entries[index].nativeStartedAt = now
                entries[index].nativeFinishedAt = nil; entries[index].nativeResult = nil
            }
        }
    }
    func endNativeCall(result: String, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        locked {
            if let index = entries.firstIndex(where: { $0.startedAt != nil && $0.finishedAt == nil }) {
                entries[index].nativeFinishedAt = now; entries[index].nativeResult = result
                if let name = entries[index].nativeCall, let startedAt = entries[index].nativeStartedAt {
                    entries[index].nativeCalls.append(["name": name, "startedAt": startedAt,
                        "seconds": now - startedAt, "result": result])
                    entries[index].nativeCalls = Array(entries[index].nativeCalls.suffix(16))
                }
            }
        }
    }
    func snapshot(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [String: Any] {
        locked {
            ["audioOperations": entries.map { $0.evidence(at: now) },
             "audioQueuedOperations": entries.filter { $0.startedAt == nil && $0.finishedAt == nil }.count,
             "audioActiveOperation": entries.first { $0.startedAt != nil && $0.finishedAt == nil }?.evidence(at: now) ?? [:]]
        }
    }
}

/// This owner belongs only to the native probe process. Availability is an explicit privacy gate.
/// Native ADM calls can block internally, so none run on the main actor and every caller has a deadline.
/// An engine stop or start the owner did not ask for (device or route change, sleep).
enum GuestEngineChange: Sendable { case stopped, started }

final class GuestSystemAudio: NSObject, LKRTCAudioDeviceModuleDelegate, @unchecked Sendable {
    private static let quarantineLock = NSLock()
    private static var quarantined: [ObjectIdentifier: GuestSystemAudio] = [:]
    private static func retainFailedOwner(_ owner: GuestSystemAudio) {
        quarantineLock.lock(); defer { quarantineLock.unlock() }
        quarantined[ObjectIdentifier(owner)] = owner
    }
    private let audioQueue = DispatchQueue(label: "NativeGuest.system-audio", qos: .userInitiated)
    private let lock = NSLock()
    private let operationTrace = GuestAudioOperationTrace()
    private var microphoneOptIn: Bool
    private var inputActivation: GuestInputActivationPolicy
    private let sharedNativeOwner: Bool
    private let sharedPlayoutGate: GuestSharedPlayoutGate
    let profile: GuestAudioProfile
    private var ownerLease: GuestAudioOwnerLease?
    private let inputMeter = GuestPCMMeter()
    private let playoutMeter = GuestPCMMeter()
    private var inputCallback = GuestStartupAudioCallback()
    private var inputMeterEnabled = false
    /// Local transcription of your own microphone: a copy of each input buffer.
    private var inputTranscriptionSink: ((AVAudioPCMBuffer) -> Void)?
    /// Voice replies (experimental setting): the input graph's gate and player.
    static let voiceRepliesKey = "nativeDesktop.voiceReplies"
    static var voiceRepliesEnabled: Bool { UserDefaults.standard.bool(forKey: voiceRepliesKey) }
    private var voiceReply: GuestVoiceReplyGraph?
    /// Tests only (manual rendering): set once at creation, before any native work.
    private var manualRenderingMode = false
    /// Native work this owner runs itself; engine stops/starts outside it come from the
    /// system (device or route change, sleep) and are reported to `onSpontaneousEngineChange`.
    private var operationDepth = 0
    private var spontaneousChangeHandler: ((GuestEngineChange) -> Void)?
    /// Called on the native audio worker; the handler must return at once.
    var onSpontaneousEngineChange: ((GuestEngineChange) -> Void)? {
        get { locked { spontaneousChangeHandler } }
        set { locked { spontaneousChangeHandler = newValue } }
    }
    private func reportSpontaneous(_ change: GuestEngineChange) {
        let handler = locked { operationDepth == 0 ? spontaneousChangeHandler : nil }
        handler?(change)
    }
    /// Microphone permission as every check here sees it (debug tests may override it,
    /// together with manual rendering, to run without the test host's permission).
    static var microphoneAuthorized: Bool {
#if DEBUG
        if let microphoneAuthorizationOverrideForTesting { return microphoneAuthorizationOverrideForTesting }
#endif
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
#if DEBUG
    nonisolated(unsafe) static var microphoneAuthorizationOverrideForTesting: Bool?
#endif
    /// R4: another observer of this module (LiveKit's, when its factory is shared) receives
    /// every module event first. While set, that observer wires the input graph, so this
    /// owner only taps it and builds no voice-reply graph of its own.
    private weak var forwardObserverStorage: LKRTCAudioDeviceModuleDelegate?
    var forwardObserver: LKRTCAudioDeviceModuleDelegate? {
        get { locked { forwardObserverStorage } }
        set { locked { forwardObserverStorage = newValue } }
    }
    /// Survives engine rebuilds: a graph built during a reply starts closed.
    private var microphoneGateOpen = true
    private var ownedFactory: LKRTCPeerConnectionFactory?
    private var cached: [String: Any]
    // The following fields are confined to audioQueue.
    private var playoutEnabled: Bool
    private var closed = false
    private var mediaContext: LKRTCPeerConnection?
    // Simultaneous meetings: only the talk meeting may hold physical input. A
    // withdrawn permit releases input; activation requested meanwhile is deferred
    // to the next permitted unmute. Mirrored into `cached` for readers.
    private var inputPermitted = true
    private var deferredActivation = false
    private var tappedInput: AVAudioNode?
    private weak var tappedEngine: AVAudioEngine?
    private var tappedPlayout: AVAudioNode?
    private weak var tappedPlayoutEngine: AVAudioEngine?
    // Meeting volume for owners without the shared gate; read under the state lock.
    private var meetingVolume: Double = 1
    private weak var volumeMixer: AVAudioMixerNode?
    /// Sound is off: the mixer stays at exactly zero even while output runs for transcription.
    private var outputSilenced = false
    // Confined to audioQueue: output runs while sound is off for local transcription.
    private var transcriptionOutput = false

    /// App-only meeting level (0...1). macOS output volume is never changed;
    /// mute and sound-on intent remain separate.
    @MainActor func setMeetingVolume(_ volume: Double) -> Bool {
        let value = volume.isFinite ? min(1, max(0, volume)) : 1
        if sharedNativeOwner { return sharedPlayoutGate.setVolume(value) }
        let (mixer, silenced) = locked { () -> (AVAudioMixerNode?, Bool) in meetingVolume = value; return (volumeMixer, outputSilenced) }
        mixer?.outputVolume = silenced ? 0 : Float(value)
        return true
    }
    /// Keeps output running while sound is off so remote audio is decoded for
    /// local transcription. Sound stays off: the mixer or shared gate is at zero.
    func setTranscriptionOutput(_ keep: Bool, timeout: TimeInterval = 2) async -> Bool {
        await perform("transcription-output", timeout: timeout) {
            guard !self.closed, let module = self.currentModule else { return false }
            self.transcriptionOutput = keep
            self.update(["transcriptionOutput": keep])
            let success = self.applyAvailability(module)
            self.readSnapshot(module)
            return success
        }
    }

    var factory: LKRTCPeerConnectionFactory {
        locked {
            guard let ownedFactory else { preconditionFailure("System audio factory is unavailable") }
            return ownedFactory
        }
    }
    /// Cached only: reading diagnostics never calls the native worker or accesses a device.
    var snapshot: [String: Any] {
        locked { cached }.merging(operationTrace.snapshot()) { _, value in value }
            .merging(["sharedPlayoutGate": sharedPlayoutGate.evidence]) { _, value in value }
    }
    var playoutEpoch: UUID? { sharedPlayoutGate.currentEpoch }
    @MainActor func openSharedPlayout(expected: UUID?) -> Bool { sharedPlayoutGate.open(expected: expected) }
    @MainActor func setSharedSoundIntent(_ sound: Bool, expected: UUID?) -> Bool {
        sharedPlayoutGate.setSound(sound, expected: expected)
    }
    @MainActor func closeSharedPlayout(expected: UUID?) -> Bool {
        if sharedNativeOwner && expected == nil { return true }
        return sharedPlayoutGate.close(expected: expected)
    }
    @MainActor func sharedPlayoutIsOpen(expected: UUID?) -> Bool { sharedPlayoutGate.isOpen(expected: expected) }
    var canUnmuteMicrophone: Bool {
        let value = snapshot
        return value["inputPermitted"] as? Bool != false &&
            (value["microphoneOptIn"] as? Bool == true || value["deferredActivation"] as? Bool == true) &&
            GuestSystemAudio.microphoneAuthorized
    }
    var privateInputLevel: Float? { locked { inputMeterEnabled } ? inputMeter.level : nil }
    var privateInputMeterEvidence: [String: Any] { meterEvidence(inputMeter).merging(["enabled": locked { inputMeterEnabled }]) { _, new in new } }
    var playoutMeterEvidence: [String: Any] { meterEvidence(playoutMeter) }
#if DEBUG
    var sharedPlayoutGateForTesting: GuestSharedPlayoutGate { sharedPlayoutGate }
    var startupCallbackEvidence: [String: Any] {
        ["input": locked { inputCallback }.evidence, "output": playoutMeter.callbackEvidence]
    }
#endif
    var startupAudioObservation: GuestStartupAudioObservation {
        let value = snapshot
        let input = locked { inputCallback }, output = playoutMeter.callbackSnapshot
        return .init(snapshot: value, inputCallbacks: input.count, outputCallbacks: output.count,
            inputCallback: input, outputCallback: output)
    }
    private func meterEvidence(_ meter: GuestPCMMeter) -> [String: Any] {
        let value = meter.snapshot
        return ["buffers": meter.buffers, "samples": value.samples, "energy": value.energy, "rms": value.rms,
                "recentLevel": meter.level.map { $0 as Any } ?? NSNull()]
    }
    func setPrivateInputMeterEnabled(_ enabled: Bool) {
        locked { inputMeterEnabled = enabled }; inputMeter.reset()
    }
    /// Receives your microphone's buffers on the audio thread; the sink must copy
    /// and return at once. Whether the meeting is unmuted is the caller's gate.
    func setInputTranscriptionSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) {
        locked { inputTranscriptionSink = sink }
    }
    /// Opens or closes the microphone gate. True when the gate now matches, or
    /// when no input graph exists yet (it will be built in that state).
    func setMicrophoneGate(open: Bool) -> Bool {
        let graph = locked { () -> GuestVoiceReplyGraph? in microphoneGateOpen = open; return voiceReply }
        graph?.setGate(open: open)
        update(["microphoneGateOpen": open])
#if DEBUG
        if let graph { update(["voiceReplyTopology": graph.evidence]) }
#endif
        return graph.map { $0.gateOpen == open } ?? true
    }
    /// Plays a reply into what the meeting receives. False without an input graph.
    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool {
        guard let graph = locked({ voiceReply }) else { return false }
        return await graph.play(buffer)
    }

    private init(microphoneEnabled: Bool, playoutEnabled: Bool, profile: GuestAudioProfile,
                 lease: GuestAudioOwnerLease, sharedNativeOwner: Bool) {
        microphoneOptIn = microphoneEnabled
        inputActivation = .init(persistent: microphoneEnabled)
        self.profile = profile; ownerLease = lease
        self.sharedNativeOwner = sharedNativeOwner
        sharedPlayoutGate = GuestSharedPlayoutGate(enabled: sharedNativeOwner)
        self.playoutEnabled = playoutEnabled
        cached = ["mode": "system", "module": "audioEngine", "microphoneOptIn": microphoneEnabled,
                  "playoutOptIn": playoutEnabled, "microphoneMutedRequested": !microphoneEnabled,
                  "playoutEnabledRequested": playoutEnabled, "cleanupSucceeded": false,
                  "sharedInputOutputDependency": sharedNativeOwner,
                  "microphoneAvailabilityPolicy": "explicit-authorized-activation-until-shutdown",
                  "pcmEvidence": "track-renderer-energy-separate-from-hardware-state"]
        super.init()
        GuestAudioEngineGate.shared.register(ObjectIdentifier(self)) { [weak self] in self?.drainNativeWorker() }
    }

    /// Blocks until this owner's native audio worker has run what was queued
    /// before the call (module reads are blocking calls on that worker).
    private func drainNativeWorker() {
        guard let module = currentModule else { return }
        _ = module.engineState; _ = module.isEngineRunning
    }

    deinit {
        let id = ObjectIdentifier(self)
        GuestAudioEngineGate.shared.unregister(id)
        // Even an incompletely constructed/failed owner releases its native factory off the UI thread,
        // and inside the gate, since releasing it tears down its audio engine.
        var remaining: (LKRTCPeerConnectionFactory, GuestAudioOwnerLease?, LKRTCPeerConnection?)? =
            ownedFactory.map { ($0, ownerLease, mediaContext) }
        ownedFactory = nil
        ownerLease = nil
        mediaContext = nil
        if remaining != nil {
            let release = { () -> Void in remaining?.2?.close(); remaining = nil }
            audioQueue.async { GuestAudioEngineGate.shared.run(for: id, release) }
        }
    }

    static func create(microphoneEnabled: Bool, playoutEnabled: Bool,
                       voiceProcessingEnabled: Bool = true, profile: GuestAudioProfile = .speech,
                       privateCheckOnly: Bool = false, exclusive: Bool = false, concurrent: Bool = false,
                       manualRendering: Bool = false,
                       makeFactory: ((_ voiceProcessing: Bool) -> LKRTCPeerConnectionFactory)? = nil,
                       timeout: TimeInterval = 3) async throws -> GuestSystemAudio {
        NativeScreenEncoderQuality.prepare()
        if exclusive || concurrent { _ = LKRTCInitializeSSL() }
        if microphoneEnabled && !GuestSystemAudio.microphoneAuthorized {
            throw GuestSystemAudioError.microphonePermissionRequired
        }
        guard let lease = GuestAudioOwnerLease(privateCheck: privateCheckOnly, exclusive: exclusive,
                                               concurrent: concurrent) else { throw GuestSystemAudioError.physicalOwnerBusy }
        let owner = GuestSystemAudio(microphoneEnabled: microphoneEnabled, playoutEnabled: playoutEnabled,
            profile: profile, lease: lease, sharedNativeOwner: exclusive)
        // Manual rendering (tests) has no device for the platform's voice processing to run on.
        let voiceProcessingEnabled = voiceProcessingEnabled && profile.usesPlatformVoiceProcessing && !manualRendering
        let success = await owner.perform("create", timeout: timeout) {
            let factory = owner.nativeCall("create-factory") {
                makeFactory?(voiceProcessingEnabled) ?? LKRTCPeerConnectionFactory(audioDeviceModuleType: .audioEngine,
                    bypassVoiceProcessing: !voiceProcessingEnabled, encoderFactory: LKRTCDefaultVideoEncoderFactory(),
                    decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioProcessingModule: nil)
            }
            owner.locked { owner.ownedFactory = factory }
            if exclusive || concurrent {
                // The first media peer initializes WebRtcVoiceEngine and binds
                // its audio transport. Doing this after manual recording starts
                // fails RegisterAudioCallback while the SDK buffer is active.
                // This peer has no media, descriptions, data channels or ICE pool.
                let configuration = LKRTCConfiguration()
                configuration.sdpSemantics = .unifiedPlan
                configuration.iceServers = []
                configuration.iceCandidatePoolSize = 0
                let context = owner.nativeCall("prepare-media-context") {
                    factory.peerConnection(with: configuration,
                        constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil)
                }
                owner.mediaContext = context
                guard let context, context.localDescription == nil, context.remoteDescription == nil,
                      context.senders.isEmpty, context.receivers.isEmpty, context.transceivers.isEmpty,
                      context.iceGatheringState == .new else { return false }
                owner.update(["mediaContextPrepared": true, "mediaContextGeneration": UUID().uuidString,
                    "mediaContextSenders": 0, "mediaContextReceivers": 0, "mediaContextTransceivers": 0,
                    "mediaContextGatheringNew": true])
            }
            let module = factory.audioDeviceModule
            owner.nativeCall("set-observer") { module.observer = owner }
            if manualRendering {
                // Tests only: the engine renders offline, so no device is opened. Its render
                // thread pulls the output side, which therefore always stays available.
                guard owner.nativeCall("set-manual-rendering", { module.setManualRenderingMode(true) }) == 0 else { return false }
                owner.manualRenderingMode = true
                owner.update(["manualRendering": true])
            }
            guard owner.nativeCall("set-platform-processing", { module.setPlatformVoiceProcessingAllowed(voiceProcessingEnabled && !manualRendering) }) == 0 else { return false }
            owner.update(["voiceProcessingRequested": voiceProcessingEnabled])
            let prepared = owner.nativeCall("set-recording-prepared", { module.setRecordingAlwaysPreparedMode(false) }) == 0
            let muteMode = owner.nativeCall("set-mute-mode", { module.setMuteMode(.inputMixer) }) == 0
            let muted = owner.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(!microphoneEnabled) }) == 0
            let available = owner.applyAvailability(module)
            owner.readSnapshot(module)
            return prepared && muteMode && muted && available
        }
        guard success else {
            probeLog("physical-audio-setup-failed", owner.snapshot)
            _ = await owner.shutdown(timeout: timeout)
            throw GuestSystemAudioError.setupFailedOrTimedOut
        }
        return owner
    }

    /// Only a prejoin private owner calls this. There is no room, sender or audio track.
    /// A raw-input tap measures aggregate energy before the muted input mixer.
    func startStandalonePrivateInputCheck(timeout: TimeInterval = 8) async -> Bool {
        setPrivateInputMeterEnabled(true)
        let success = await perform("private-input-check", timeout: timeout) {
            guard !self.closed, self.ownerLease?.privateCheck == true, let module = self.currentModule,
                  GuestSystemAudio.microphoneAuthorized else { return false }
            self.inputActivation.beginCheck(); self.microphoneOptIn = self.inputActivation.inputAvailable
            let success = GuestMutedInputPreparation.start(
                mute: { self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0 },
                makeAvailable: { self.applyAvailability(module) },
                startRecording: { self.nativeCall("start-recording", { module.initAndStartRecording(audioProcessingOptions: nil) }) == 0 },
                isMuted: { module.isMicrophoneMuted })
            self.readSnapshot(module)
            return success
        }
        if !success { setPrivateInputMeterEnabled(false) }
        return success
    }

    /// Borrows this owner's input; never changes its sender or mute intent.
    func beginPrivateInputCheck(timeout: TimeInterval? = nil) async -> Bool {
        let success = await perform("private-input-borrow", timeout: timeout ?? inputStartupBudget) {
            guard !self.closed, self.inputPermitted, let module = self.currentModule,
                  GuestSystemAudio.microphoneAuthorized else { return false }
            self.inputActivation.beginCheck(); self.microphoneOptIn = self.inputActivation.inputAvailable
            let success = self.applyAvailability(module)
            if !success { self.inputActivation.endCheck(); self.microphoneOptIn = self.inputActivation.inputAvailable; _ = self.applyAvailability(module) }
            self.readSnapshot(module)
            return success
        }
        if success { setPrivateInputMeterEnabled(true) }
        return success
    }

    /// App readiness owns this same ADM and its inert software context, with no
    /// room sender or publishable track.
    /// Explicit recording demand retains the muted physical graph for adoption.
    func prepareIdleInput(timeout: TimeInterval = 8) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        setPrivateInputMeterEnabled(false)
        if sharedNativeOwner, !(await sharedPlayoutGate.reset(sound: false)) { _ = await shutdown(); return false }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        return await perform("foreground-input-prepare", timeout: remaining) {
            guard !self.closed, self.inputPermitted, let module = self.currentModule,
                  GuestSystemAudio.microphoneAuthorized else { return false }
            self.inputActivation = .init(persistent: true); self.microphoneOptIn = true
            self.playoutEnabled = false
            let success = GuestMutedInputPreparation.start(
                mute: { self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0 },
                makeAvailable: { self.applyAvailability(module) },
                startRecording: { self.nativeCall("start-recording", { module.initAndStartRecording(audioProcessingOptions: nil) }) == 0 },
                isMuted: { module.isMicrophoneMuted })
            self.readSnapshot(module)
            return success
        }
    }

    /// Peers are detached before this privacy barrier. A room never inherits
    /// another room's activation or unmute choice.
    func resetForRoom(playout: Bool, preparedInput: Bool) async -> Bool {
        setPrivateInputMeterEnabled(false)
        if sharedNativeOwner, !(await sharedPlayoutGate.reset(sound: playout)) { _ = await shutdown(); return false }
        return await perform("room-audio-reset", timeout: 8) {
            guard !self.closed, let module = self.currentModule else { return false }
            // A new room or recovery attempt starts permitted; the meeting reapplies
            // its own withdrawal before any session can activate input.
            self.inputPermitted = true
            let input = preparedInput && GuestSystemAudio.microphoneAuthorized
            self.inputActivation = .init(persistent: input); self.microphoneOptIn = input
            self.deferredActivation = false; self.update(["deferredActivation": false, "inputPermitted": true])
            self.playoutEnabled = playout
            let muted = self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0
            let available = self.applyAvailability(module)
            let recording = input || self.nativeCall("stop-recording", { module.stopRecording() }) == 0
            let restored = self.nativeCall("restore-microphone-muted", { module.setMicrophoneMuted(true) }) == 0
            self.readSnapshot(module)
            return muted && restored && module.isMicrophoneMuted && available && recording
        }
    }

    /// Restores capture-off only when the check was the sole activation reason.
    func endPrivateInputCheck(timeout: TimeInterval = 2) async -> Bool {
        setPrivateInputMeterEnabled(false)
        return await perform("private-input-release", timeout: timeout) {
            guard !self.closed, let module = self.currentModule else { return true }
            self.inputActivation.endCheck(); self.microphoneOptIn = self.inputActivation.inputAvailable
            let success = self.applyAvailability(module)
            self.readSnapshot(module)
            return success
        }
    }

    /// The UI calls this only after an explicit, authorized microphone action.
    /// Availability changes while InputMixer remains muted; activation alone sends no input.
    private var inputStartupBudget: TimeInterval {
        // First input activation also initializes the system voice-processing unit.
        // That asynchronous work is separate from an already-running mute change.
        snapshot["inputAvailable"] as? Bool == true ? 2 : 8
    }
    func activateMicrophone(timeout: TimeInterval? = nil) async -> Bool {
        await perform("microphone-activate", timeout: timeout ?? inputStartupBudget) {
            guard !self.closed, let module = self.currentModule,
                  GuestSystemAudio.microphoneAuthorized else {
                self.update(["lastRejectedOperation": "microphone-not-authorized"]); return false
            }
            // Another meeting holds the microphone: remember the request without input.
            guard self.inputPermitted else {
                self.deferredActivation = true; self.update(["deferredActivation": true]); return true
            }
            let wasActivated = self.inputActivation
            self.inputActivation.activate(); self.microphoneOptIn = self.inputActivation.inputAvailable
            let success = self.applyAvailability(module)
            if !success { self.inputActivation = wasActivated; self.microphoneOptIn = self.inputActivation.inputAvailable; _ = self.applyAvailability(module) }
            self.update(["microphoneOptIn": self.microphoneOptIn])
            self.readSnapshot(module)
            return success
        }
    }

    /// Enqueue the privacy barrier immediately, before a later unmute can enqueue.
    /// The sender track is suppressed synchronously by the engine as well.
    func suppressMicrophone() {
        audioQueue.async {
            guard !self.closed, let module = self.currentModule else { return }
            self.update(["microphoneMutedRequested": true])
            let muted = self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0 && module.isMicrophoneMuted
            self.readSnapshot(module)
            self.update(["lastCompletedOperation": "microphone-suppress", "lastOperationSucceeded": muted])
        }
    }

    /// Only opted-in capture remains available while muted. InputMixer avoids restarting playout.
    func setMicrophoneMuted(_ muted: Bool, timeout: TimeInterval = 2) async -> Bool {
        // Re-activating released input first initializes the voice-processing unit again.
        let reactivates = !muted && snapshot["deferredActivation"] as? Bool == true
        return await perform("microphone-mute", timeout: reactivates ? max(timeout, 8) : timeout) {
            guard !self.closed, let module = self.currentModule else { return false }
            guard muted || self.inputPermitted else {
                self.update(["lastRejectedOperation": "microphone-input-not-permitted"]); return false
            }
            if !muted, !self.microphoneOptIn, self.deferredActivation,
               GuestSystemAudio.microphoneAuthorized {
                let wasActivated = self.inputActivation
                self.inputActivation.activate(); self.microphoneOptIn = self.inputActivation.inputAvailable
                guard self.applyAvailability(module) else {
                    self.inputActivation = wasActivated; self.microphoneOptIn = self.inputActivation.inputAvailable
                    _ = self.applyAvailability(module); self.readSnapshot(module); return false
                }
                self.deferredActivation = false
                self.update(["deferredActivation": false, "microphoneOptIn": self.microphoneOptIn])
            }
            guard muted || (self.microphoneOptIn && GuestSystemAudio.microphoneAuthorized) else {
                self.update(["lastRejectedOperation": "microphone-not-authorized"]); return false
            }
            self.update(["microphoneMutedRequested": muted])
            let changed = self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(muted) }) == 0
            let success = changed && module.isMicrophoneMuted == muted
            self.readSnapshot(module)
            return success
        }
    }

    /// Withdrawing the permit mutes and makes physical input unavailable;
    /// granting it starts nothing. A later unmute re-activates input explicitly.
    /// With `keepWarm` the permit is withdrawn and the microphone muted, but the
    /// device and voice processing keep running, so moving back skips their
    /// restart. Unmuting is refused until the permit returns, as without it.
    func setInputPermitted(_ permitted: Bool, keepWarm: Bool = false, timeout: TimeInterval = 8) async -> Bool {
        if !permitted { setPrivateInputMeterEnabled(false) }
        return await perform(permitted ? "input-permit" : keepWarm ? "input-release-warm" : "input-release", timeout: timeout) {
            guard !self.closed, let module = self.currentModule else { return !permitted }
            guard !permitted else {
                self.inputPermitted = true; self.update(["inputPermitted": true, "inputKeptWarm": false]); return true
            }
            if keepWarm {
                self.inputPermitted = false
                self.update(["microphoneMutedRequested": true])
                let muted = self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0
                self.update(["inputPermitted": false, "inputKeptWarm": true])
                self.readSnapshot(module)
                return muted && module.isMicrophoneMuted
            }
            self.deferredActivation = self.deferredActivation || self.microphoneOptIn
            self.inputPermitted = false
            self.update(["microphoneMutedRequested": true])
            let muted = self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0
            self.inputActivation = .init(persistent: false); self.microphoneOptIn = false
            // Unavailable input releases the device, as a finished private check does.
            // WebRTC's recording demand stays, so a later activation resumes sending.
            let available = self.applyAvailability(module)
            self.update(["inputPermitted": false, "deferredActivation": self.deferredActivation, "microphoneOptIn": false])
            self.readSnapshot(module)
            return muted && module.isMicrophoneMuted && available
        }
    }

    /// Experimental warm microphone for a meeting without the talk role: starts the
    /// device and voice processing muted, the state a warm release leaves, so the
    /// first move here skips that startup. The permit stays withdrawn, so nothing
    /// can be unmuted or sent until the talk role moves here.
    func prewarmInput(timeout: TimeInterval = 8) async -> Bool {
        await perform("input-prewarm", timeout: timeout) {
            guard !self.closed, let module = self.currentModule, !self.inputPermitted,
                  GuestSystemAudio.microphoneAuthorized else { return false }
            if self.microphoneOptIn { return module.isMicrophoneMuted }
            self.update(["microphoneMutedRequested": true])
            guard self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0,
                  module.isMicrophoneMuted else { self.readSnapshot(module); return false }
            let wasActivated = self.inputActivation
            self.inputActivation.activate(); self.microphoneOptIn = self.inputActivation.inputAvailable
            guard self.applyAvailability(module) else {
                self.inputActivation = wasActivated; self.microphoneOptIn = self.inputActivation.inputAvailable
                _ = self.applyAvailability(module); self.readSnapshot(module); return false
            }
            self.deferredActivation = false
            self.update(["inputKeptWarm": true, "deferredActivation": false, "microphoneOptIn": self.microphoneOptIn])
            self.readSnapshot(module)
            return module.isMicrophoneMuted
        }
    }

    func setPlayoutEnabled(_ enabled: Bool, timeout: TimeInterval = 2, expectedEpoch: UUID? = nil) async -> Bool {
        if sharedNativeOwner {
            guard await sharedPlayoutGate.setSound(enabled, expected: expectedEpoch) else {
                if sharedPlayoutGate.matches(expectedEpoch) { _ = await shutdown() }
                return false
            }
        }
        let success = await perform("playout", timeout: timeout) {
            guard !self.closed, let module = self.currentModule else { return false }
            guard self.sharedPlayoutGate.matches(expectedEpoch) else { return false }
            self.playoutEnabled = enabled
            self.update(["playoutEnabledRequested": enabled])
            let success = self.applyAvailability(module)
            self.readSnapshot(module)
            return success
        }
        if sharedNativeOwner, !success, !(await sharedPlayoutGate.close(expected: expectedEpoch)) { _ = await shutdown() }
        return success
    }

    /// Explicit acoustic comparison only. The native knob couples AEC, NS and AGC.
    /// Ordinary duplex runs never call this; failures are followed by mute/Leave.
    func setVoiceProcessingBypassedForTesting(_ bypassed: Bool) async -> Bool {
        await perform("diagnostic-processing-bypass", timeout: 2) {
            guard !self.closed, let module = self.currentModule,
                  self.snapshot["voiceProcessingRequested"] as? Bool == true else { return false }
            self.nativeCall("set-processing-bypass") { module.isVoiceProcessingBypassed = bypassed }
            self.readSnapshot(module)
            let state = self.snapshot
            return state["voiceProcessingActive"] as? Bool == true &&
                state["voiceProcessingBypassedActive"] as? Bool == bypassed &&
                state["echoCancellationActive"] as? Bool == !bypassed
        }
    }

    @discardableResult
    func refreshSnapshot(timeout: TimeInterval = 2) async -> Bool {
        await perform("snapshot", timeout: timeout) {
            guard !self.closed, let module = self.currentModule else { return false }
            self.readSnapshot(module); return true
        }
    }

    /// Close peers and remove track renderers first. A false result means cleanup is unproven.
    func shutdown(timeout: TimeInterval = 2) async -> Bool {
        if sharedNativeOwner { _ = await sharedPlayoutGate.close(retire: true) }
        let success = await perform("shutdown", timeout: timeout) {
            if self.closed { return self.snapshot["cleanupSucceeded"] as? Bool == true }
            self.closed = true
            guard let module = self.currentModule else { self.update(["cleanupSucceeded": true]); return true }
            self.playoutEnabled = false
            let muted = self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0 && module.isMicrophoneMuted
            var unavailable = LKRTCAudioEngineAvailability()
            unavailable.isInputAvailable = false; unavailable.isOutputAvailable = false
            let gated = self.nativeCall("set-engine-unavailable", { module.setEngineAvailability(unavailable) }) == 0
            let recording = self.nativeCall("stop-recording", { module.stopRecording() }) == 0
            let playout = self.nativeCall("stop-playout", { module.stopPlayout() }) == 0
            let prepared = self.nativeCall("set-recording-prepared", { module.setRecordingAlwaysPreparedMode(false) }) == 0
            let stopped = self.nativeCall("verify-stopped") { !module.isEngineRunning && !module.isRecording && !module.isPlaying }
            guard muted && gated && recording && playout && prepared && stopped else {
                self.readSnapshot(module)
                self.update(["cleanupSucceeded": false, "mediaContextClosed": false,
                             "microphoneMutedRequested": true, "playoutEnabledRequested": false])
                // The AudioState owns the installed AudioTransport callback.
                // Dropping it while a buffer may remain active is unsafe.
                return false
            }
            // Release the last software media reference only after both native
            // buffers stop, so transport deregistration cannot race capture.
            self.nativeCall("close-media-context") { self.mediaContext?.close(); self.mediaContext = nil }
            let contextClosed = self.mediaContext == nil
            self.readSnapshot(module)
            self.nativeCall("remove-observer") { module.observer = nil }
            let retiredFactory = self.locked {
                let retired = self.ownedFactory; self.ownedFactory = nil; return retired
            }
            let success = muted && gated && recording && playout && prepared && stopped && contextClosed
            self.update(["cleanupSucceeded": success, "mediaContextClosed": contextClosed,
                         "microphoneMutedRequested": true, "playoutEnabledRequested": false])
            withExtendedLifetime(retiredFactory) {}
            if success { self.ownerLease = nil }
            return success
        }
        if !success {
            GuestAudioOwnerLease.reportFailedStop()
            // A timed-out creator can lose its last caller while native work
            // is still pending. Keep its observer, context, factory and lease
            // alive until process exit rather than leaving a dangling callback.
            Self.retainFailedOwner(self)
        }
        return success
    }

    private var currentModule: LKRTCAudioDeviceModule? { locked { ownedFactory?.audioDeviceModule } }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    private func update(_ values: [String: Any]) { locked { cached.merge(values) { _, value in value } } }

    private func applyAvailability(_ module: LKRTCAudioDeviceModule) -> Bool {
        // Silence before output can become available; unsilence only with sound on.
        if !sharedNativeOwner {
            let (mixer, volume) = locked { () -> (AVAudioMixerNode?, Double) in
                outputSilenced = !playoutEnabled; return (volumeMixer, playoutEnabled ? meetingVolume : 0)
            }
            mixer?.outputVolume = Float(volume)
        }
        let physical = GuestPhysicalAudioAvailability(input: microphoneOptIn,
            playoutRequested: playoutEnabled, sharedNativeOwner: sharedNativeOwner, transcription: transcriptionOutput)
        var availability = LKRTCAudioEngineAvailability()
        availability.isInputAvailable = ObjCBool(physical.input)
        availability.isOutputAvailable = ObjCBool(physical.output || manualRenderingMode)
        return nativeCall("set-engine-availability", { module.setEngineAvailability(availability) }) == 0
    }

    private func readSnapshot(_ module: LKRTCAudioDeviceModule) {
        operationTrace.beginNativeCall("read-native-snapshot")
        defer { operationTrace.endNativeCall(result: "complete") }
        // input/outputRunning and isRecording/isPlaying are raw WebRTC demand.
        // Availability and actual engine state are reported separately.
        let state = module.engineState, availability = module.engineAvailability
        let processing = module.platformAudioProcessingState
        update(["inputAvailable": availability.isInputAvailable.boolValue, "outputAvailable": availability.isOutputAvailable.boolValue,
                "inputEnabled": state.inputEnabled.boolValue, "inputRunning": state.inputRunning.boolValue,
                "outputEnabled": state.outputEnabled.boolValue, "outputRunning": state.outputRunning.boolValue,
                "microphoneMuted": module.isMicrophoneMuted, "muteMode": state.muteMode.rawValue,
                "engineRunning": module.isEngineRunning, "recording": module.isRecording, "playing": module.isPlaying,
                "inputDeviceCount": module.inputDevices.count, "outputDeviceCount": module.outputDevices.count,
                "recordingAlwaysPrepared": module.isRecordingAlwaysPreparedMode,
                "voiceProcessingActive": processing.isVoiceProcessingEnabledActive,
                "voiceProcessingBypassedActive": processing.isVoiceProcessingBypassedActive,
                "echoCancellationActive": processing.echoCancellation.isActive,
                "snapshotUptime": ProcessInfo.processInfo.systemUptime])
    }

    private func nativeCall<Result>(_ name: String, _ body: () -> Result) -> Result {
        operationTrace.beginNativeCall(name)
        let result = body()
        // Factories are recorded by stage only; native status calls retain their exact result.
        operationTrace.endNativeCall(result: result is LKRTCPeerConnectionFactory ? "created" : String(describing: result))
        return result
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ result: Bool, beforeResume: () -> Void = {}) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            if let pending { beforeResume(); pending.resume(returning: result) }
        }
    }

    private func perform(_ name: String, timeout: TimeInterval, _ body: @escaping @Sendable () -> Bool) async -> Bool {
        let operationID = operationTrace.enqueue(name, timeout: timeout)
        return await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0.01, timeout)) {
                completion.finish(false) {
                    self.operationTrace.timedOut(operationID)
                    self.update(["lastTimedOutOperation": name, "cleanupSucceeded": false])
                    probeLog("physical-audio-operation-timeout", self.snapshot)
                }
            }
            audioQueue.async {
                self.operationTrace.start(operationID)
                // One owner's native audio work at a time, after others' queued work.
                self.locked { self.operationDepth += 1 }
                let result = GuestAudioEngineGate.shared.run(for: ObjectIdentifier(self), body)
                self.locked { self.operationDepth -= 1 }
                self.operationTrace.finish(operationID, succeeded: result)
                self.update(["lastCompletedOperation": name, "lastOperationSucceeded": result])
                if !result { probeLog("physical-audio-operation-failed", self.snapshot) }
                completion.finish(result)
            }
        }
    }

    // Observer callbacks run on the native audio worker. They only update small cached values;
    // they must not call the blocking ADM API or synchronously dispatch to audioQueue.
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, didReceiveSpeechActivityEvent event: LKRTCSpeechActivityEvent) {
        forwardObserver?.audioDeviceModule(audioDeviceModule, didReceiveSpeechActivityEvent: event)
        update(["speechActivityEvent": event.rawValue])
    }
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, didCreateEngine engine: AVAudioEngine) -> Int {
        let forwarded = forwardObserver?.audioDeviceModule(audioDeviceModule, didCreateEngine: engine) ?? 0
        locked { cached["enginesCreated"] = (cached["enginesCreated"] as? Int ?? 0) + 1 }; return forwarded
    }
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, willEnableEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool, isVoiceProcessingEnabled: Bool) -> Int {
        let forwarded = forwardObserver?.audioDeviceModule?(audioDeviceModule, willEnableEngine: engine, isPlayoutEnabled: isPlayoutEnabled,
            isRecordingEnabled: isRecordingEnabled, isVoiceProcessingEnabled: isVoiceProcessingEnabled) ?? 0
        update(["voiceProcessingEnabled": isVoiceProcessingEnabled]); return forwarded
    }
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, willStartEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        let forwarded = forwardObserver?.audioDeviceModule(audioDeviceModule, willStartEngine: engine,
            isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
        locked { cached["engineStarts"] = (cached["engineStarts"] as? Int ?? 0) + 1 }
        reportSpontaneous(.started); return forwarded
    }
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, didStopEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        let forwarded = forwardObserver?.audioDeviceModule(audioDeviceModule, didStopEngine: engine,
            isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
        locked { cached["engineStops"] = (cached["engineStops"] as? Int ?? 0) + 1 }
        reportSpontaneous(.stopped); return forwarded
    }
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        forwardObserver?.audioDeviceModule(audioDeviceModule, didDisableEngine: engine,
            isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) -> Int {
        let forwarded = forwardObserver?.audioDeviceModule(audioDeviceModule, willReleaseEngine: engine) ?? 0
        if let tappedInput, tappedEngine === engine {
            tappedInput.removeTap(onBus: 0); self.tappedInput = nil; tappedEngine = nil
        }
        if let tappedPlayout, tappedPlayoutEngine === engine {
            sharedPlayoutGate.remove(identity: ObjectIdentifier(tappedPlayout))
            tappedPlayout.removeTap(onBus: 0); self.tappedPlayout = nil; tappedPlayoutEngine = nil
        }
        // A reply in progress ends with its engine; the gate state is kept for the next one.
        let graph = locked { () -> GuestVoiceReplyGraph? in
            guard let current = voiceReply, current.engine === engine else { return nil }
            voiceReply = nil; return current
        }
        graph?.detach()
        locked { cached["enginesReleased"] = (cached["enginesReleased"] as? Int ?? 0) + 1 }
        reportSpontaneous(.stopped); return forwarded
    }
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, engine: AVAudioEngine,
                           configureInputFromSource source: AVAudioNode?, toDestination destination: AVAudioNode,
                           format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        // The other observer wires the input first; this owner then only taps the source.
        let forwarding = forwardObserver
        let forwarded = forwarding?.audioDeviceModule(audioDeviceModule, engine: engine, configureInputFromSource: source,
            toDestination: destination, format: format, context: context) ?? 0
        update(["inputSampleRate": format.sampleRate, "inputChannels": Int(format.channelCount), "inputASBD": Self.signature(format)])
        if let source, source !== tappedInput, format.sampleRate > 0, format.channelCount > 0 {
            tappedInput?.removeTap(onBus: 0)
            tappedInput = source; tappedEngine = engine
            source.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                let receivedUptime = ProcessInfo.processInfo.systemUptime, deliveredFormat = buffer.format
                let signature = withExtendedLifetime(deliveredFormat) { GuestStartupAudioCallback.Format(deliveredFormat.streamDescription.pointee) }
                self.locked {
                    self.inputCallback = .init(count: self.inputCallback.count + 1, frames: Int(buffer.frameLength),
                        format: signature, uptime: receivedUptime)
                    self.cached["inputCallbacks"] = self.inputCallback.count
                }
                let (metering, sink) = self.locked { (self.inputMeterEnabled, self.inputTranscriptionSink) }
                sink?(buffer)
                guard metering else { return }
                self.inputMeter.render(pcmBuffer: buffer)
            }
        }
        // Voice replies: microphone → gate → input mixer ← player. Built only
        // when the experimental setting is on; otherwise the default wiring stays.
        if forwarding == nil, Self.voiceRepliesEnabled, let inputMixer = context[kLKRTCAudioEngineInputMixerNodeKey] as? AVAudioMixerNode {
            let graph: GuestVoiceReplyGraph = locked {
                if let existing = voiceReply, existing.engine === engine { return existing }
                let created = GuestVoiceReplyGraph(engine: engine, gateOpen: microphoneGateOpen)
                voiceReply = created; return created
            }
            let connected = graph.connect(source: source, inputMixer: inputMixer, format: format)
            update(["voiceReplyGraph": connected, "microphoneGateOpen": graph.gateOpen])
        }
        return forwarded
    }
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, engine: AVAudioEngine,
                           configureOutputFromSource source: AVAudioNode, toDestination destination: AVAudioNode?,
                           format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        let forwarded = forwardObserver?.audioDeviceModule(audioDeviceModule, engine: engine, configureOutputFromSource: source,
            toDestination: destination, format: format, context: context) ?? 0
        guard forwarded == 0 else { return forwarded }
        if sharedNativeOwner {
            guard let mixer = source as? AVAudioMixerNode,
                  sharedPlayoutGate.bind(identity: ObjectIdentifier(mixer), setGain: { [weak mixer] value in
                      guard let mixer else { return value == 0 }
                      mixer.outputVolume = Float(value)
                      return mixer.outputVolume == Float(value)
                  }) else { return -1 }
        } else if let mixer = source as? AVAudioMixerNode {
            let volume = locked { () -> Double in volumeMixer = mixer; return outputSilenced ? 0 : meetingVolume }
            mixer.outputVolume = Float(volume)
        }
        update(["outputSampleRate": format.sampleRate, "outputChannels": Int(format.channelCount), "outputASBD": Self.signature(format)])
        // Hardware's existing output pull drives this aggregate meter. No
        // recorder, second engine, audio-file storage or monitoring route exists.
        if destination != nil, source !== tappedPlayout, format.sampleRate > 0, format.channelCount > 0 {
            tappedPlayout?.removeTap(onBus: 0)
            tappedPlayout = source; tappedPlayoutEngine = engine
            source.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.playoutMeter.render(pcmBuffer: buffer)
            }
        }
        return 0
    }
    func audioDeviceModuleDidUpdateDevices(_ audioDeviceModule: LKRTCAudioDeviceModule) {
        forwardObserver?.audioDeviceModuleDidUpdateDevices(audioDeviceModule)
        locked { cached["deviceUpdates"] = (cached["deviceUpdates"] as? Int ?? 0) + 1 }
    }
    private static func signature(_ format: AVAudioFormat) -> [Double] {
        let s = format.streamDescription.pointee
        return [s.mSampleRate, Double(s.mFormatID), Double(s.mFormatFlags), Double(s.mBytesPerPacket),
            Double(s.mFramesPerPacket), Double(s.mBytesPerFrame), Double(s.mChannelsPerFrame), Double(s.mBitsPerChannel), Double(s.mReserved)]
    }
}
