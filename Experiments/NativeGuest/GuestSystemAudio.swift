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
    var snapshot: GuestAudioSnapshot { locked { measured } }
    var buffers: Int { locked { bufferCount } }
    var level: Float? { locked { ProcessInfo.processInfo.systemUptime - lastSampleTime < 0.5 ? lastLevel : nil } }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    func reset() { locked { measured = GuestAudioSnapshot(); bufferCount = 0; lastLevel = nil; lastSampleTime = 0 } }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        var samples = 0, energy = 0.0
        let format = pcmBuffer.format
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
final class GuestSystemAudio: NSObject, LKRTCAudioDeviceModuleDelegate, @unchecked Sendable {
    private let audioQueue = DispatchQueue(label: "NativeGuest.system-audio", qos: .userInitiated)
    private let lock = NSLock()
    private let operationTrace = GuestAudioOperationTrace()
    private var microphoneOptIn: Bool
    private var inputActivation: GuestInputActivationPolicy
    let profile: GuestAudioProfile
    private var ownerLease: GuestAudioOwnerLease?
    private let inputMeter = GuestPCMMeter()
    private let playoutMeter = GuestPCMMeter()
    private var inputMeterEnabled = false
    private var ownedFactory: LKRTCPeerConnectionFactory?
    private var cached: [String: Any]
    // The following fields are confined to audioQueue.
    private var playoutEnabled: Bool
    private var closed = false
    private var tappedInput: AVAudioNode?
    private weak var tappedEngine: AVAudioEngine?
    private var tappedPlayout: AVAudioNode?
    private weak var tappedPlayoutEngine: AVAudioEngine?

    var factory: LKRTCPeerConnectionFactory {
        locked {
            guard let ownedFactory else { preconditionFailure("System audio factory is unavailable") }
            return ownedFactory
        }
    }
    /// Cached only: reading diagnostics never calls the native worker or accesses a device.
    var snapshot: [String: Any] { locked { cached }.merging(operationTrace.snapshot()) { _, value in value } }
    var canUnmuteMicrophone: Bool {
        snapshot["microphoneOptIn"] as? Bool == true && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    var privateInputLevel: Float? { locked { inputMeterEnabled } ? inputMeter.level : nil }
    var privateInputMeterEvidence: [String: Any] { meterEvidence(inputMeter).merging(["enabled": locked { inputMeterEnabled }]) { _, new in new } }
    var playoutMeterEvidence: [String: Any] { meterEvidence(playoutMeter) }
    private func meterEvidence(_ meter: GuestPCMMeter) -> [String: Any] {
        let value = meter.snapshot
        return ["buffers": meter.buffers, "samples": value.samples, "energy": value.energy, "rms": value.rms,
                "recentLevel": meter.level.map { $0 as Any } ?? NSNull()]
    }
    func setPrivateInputMeterEnabled(_ enabled: Bool) {
        locked { inputMeterEnabled = enabled }; inputMeter.reset()
    }

    private init(microphoneEnabled: Bool, playoutEnabled: Bool, profile: GuestAudioProfile, lease: GuestAudioOwnerLease) {
        microphoneOptIn = microphoneEnabled
        inputActivation = .init(persistent: microphoneEnabled)
        self.profile = profile; ownerLease = lease
        self.playoutEnabled = playoutEnabled
        cached = ["mode": "system", "module": "audioEngine", "microphoneOptIn": microphoneEnabled,
                  "playoutOptIn": playoutEnabled, "microphoneMutedRequested": !microphoneEnabled,
                  "playoutEnabledRequested": playoutEnabled, "cleanupSucceeded": false,
                  "microphoneAvailabilityPolicy": "explicit-authorized-activation-until-shutdown",
                  "pcmEvidence": "track-renderer-energy-separate-from-hardware-state"]
        super.init()
    }

    deinit {
        // Even an incompletely constructed/failed owner releases its native factory off the UI thread.
        let remaining = ownedFactory
        let lease = ownerLease
        ownedFactory = nil
        ownerLease = nil
        if let remaining { audioQueue.async { withExtendedLifetime((remaining, lease)) {} } }
    }

    static func create(microphoneEnabled: Bool, playoutEnabled: Bool,
                       voiceProcessingEnabled: Bool = true, profile: GuestAudioProfile = .speech,
                       privateCheckOnly: Bool = false, timeout: TimeInterval = 3) async throws -> GuestSystemAudio {
        if microphoneEnabled && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            throw GuestSystemAudioError.microphonePermissionRequired
        }
        guard let lease = GuestAudioOwnerLease(privateCheck: privateCheckOnly) else { throw GuestSystemAudioError.physicalOwnerBusy }
        let owner = GuestSystemAudio(microphoneEnabled: microphoneEnabled, playoutEnabled: playoutEnabled, profile: profile, lease: lease)
        let voiceProcessingEnabled = voiceProcessingEnabled && profile.usesPlatformVoiceProcessing
        let success = await owner.perform("create", timeout: timeout) {
            let factory = owner.nativeCall("create-factory") { LKRTCPeerConnectionFactory(audioDeviceModuleType: .audioEngine,
                bypassVoiceProcessing: !voiceProcessingEnabled, encoderFactory: LKRTCDefaultVideoEncoderFactory(),
                decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioProcessingModule: nil) }
            owner.locked { owner.ownedFactory = factory }
            let module = factory.audioDeviceModule
            owner.nativeCall("set-observer") { module.observer = owner }
            guard owner.nativeCall("set-platform-processing", { module.setPlatformVoiceProcessingAllowed(voiceProcessingEnabled) }) == 0 else { return false }
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

    /// Only a prejoin exclusive owner calls this. There is no peer, sender or audio track.
    /// A raw-input tap measures aggregate energy before the muted input mixer.
    func startStandalonePrivateInputCheck(timeout: TimeInterval = 2) async -> Bool {
        setPrivateInputMeterEnabled(true)
        let success = await perform("private-input-check", timeout: timeout) {
            guard !self.closed, self.ownerLease?.privateCheck == true, let module = self.currentModule,
                  AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return false }
            self.inputActivation.beginCheck(); self.microphoneOptIn = self.inputActivation.inputAvailable
            let muted = self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0
            let available = self.applyAvailability(module)
            let recording = self.nativeCall("start-recording", { module.initAndStartRecording(audioProcessingOptions: nil) }) == 0
            self.readSnapshot(module)
            return muted && available && recording && module.isMicrophoneMuted
        }
        if !success { setPrivateInputMeterEnabled(false) }
        return success
    }

    /// Borrows this owner's input; never changes its sender or mute intent.
    func beginPrivateInputCheck(timeout: TimeInterval = 2) async -> Bool {
        let success = await perform("private-input-borrow", timeout: timeout) {
            guard !self.closed, let module = self.currentModule,
                  AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return false }
            self.inputActivation.beginCheck(); self.microphoneOptIn = self.inputActivation.inputAvailable
            let success = self.applyAvailability(module)
            if !success { self.inputActivation.endCheck(); self.microphoneOptIn = self.inputActivation.inputAvailable; _ = self.applyAvailability(module) }
            self.readSnapshot(module)
            return success
        }
        if success { setPrivateInputMeterEnabled(true) }
        return success
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
    func activateMicrophone(timeout: TimeInterval = 2) async -> Bool {
        await perform("microphone-activate", timeout: timeout) {
            guard !self.closed, let module = self.currentModule,
                  AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                self.update(["lastRejectedOperation": "microphone-not-authorized"]); return false
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
        await perform("microphone-mute", timeout: timeout) {
            guard !self.closed, let module = self.currentModule else { return false }
            guard muted || (self.microphoneOptIn && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized) else {
                self.update(["lastRejectedOperation": "microphone-not-authorized"]); return false
            }
            self.update(["microphoneMutedRequested": muted])
            let changed = self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(muted) }) == 0
            let success = changed && module.isMicrophoneMuted == muted
            self.readSnapshot(module)
            return success
        }
    }

    func setPlayoutEnabled(_ enabled: Bool, timeout: TimeInterval = 2) async -> Bool {
        await perform("playout", timeout: timeout) {
            guard !self.closed, let module = self.currentModule else { return false }
            self.playoutEnabled = enabled
            self.update(["playoutEnabledRequested": enabled])
            let success = self.applyAvailability(module)
            self.readSnapshot(module)
            return success
        }
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
        let success = await perform("shutdown", timeout: timeout) {
            if self.closed { return self.snapshot["cleanupSucceeded"] as? Bool == true }
            self.closed = true
            guard let module = self.currentModule else { self.update(["cleanupSucceeded": true]); return true }
            self.playoutEnabled = false
            var unavailable = LKRTCAudioEngineAvailability()
            unavailable.isInputAvailable = false; unavailable.isOutputAvailable = false
            let gated = self.nativeCall("set-engine-unavailable", { module.setEngineAvailability(unavailable) }) == 0
            let recording = self.nativeCall("stop-recording", { module.stopRecording() }) == 0
            let playout = self.nativeCall("stop-playout", { module.stopPlayout() }) == 0
            let prepared = self.nativeCall("set-recording-prepared", { module.setRecordingAlwaysPreparedMode(false) }) == 0
            let stopped = self.nativeCall("verify-stopped") { !module.isEngineRunning && !module.isRecording && !module.isPlaying }
            self.readSnapshot(module)
            self.nativeCall("remove-observer") { module.observer = nil }
            let retiredFactory = self.locked {
                let retired = self.ownedFactory; self.ownedFactory = nil; return retired
            }
            let success = gated && recording && playout && prepared && stopped
            self.update(["cleanupSucceeded": success, "microphoneMutedRequested": true, "playoutEnabledRequested": false])
            withExtendedLifetime(retiredFactory) {}
            if success { self.ownerLease = nil }
            return success
        }
        if !success { GuestAudioOwnerLease.reportFailedStop() }
        return success
    }

    private var currentModule: LKRTCAudioDeviceModule? { locked { ownedFactory?.audioDeviceModule } }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    private func update(_ values: [String: Any]) { locked { cached.merge(values) { _, value in value } } }

    private func applyAvailability(_ module: LKRTCAudioDeviceModule) -> Bool {
        var availability = LKRTCAudioEngineAvailability()
        availability.isInputAvailable = ObjCBool(microphoneOptIn)
        availability.isOutputAvailable = ObjCBool(playoutEnabled)
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
                let result = body()
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
        update(["speechActivityEvent": event.rawValue])
    }
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, didCreateEngine engine: AVAudioEngine) -> Int {
        locked { cached["enginesCreated"] = (cached["enginesCreated"] as? Int ?? 0) + 1 }; return 0
    }
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, willEnableEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool, isVoiceProcessingEnabled: Bool) -> Int {
        update(["voiceProcessingEnabled": isVoiceProcessingEnabled]); return 0
    }
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, willStartEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        locked { cached["engineStarts"] = (cached["engineStarts"] as? Int ?? 0) + 1 }; return 0
    }
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, didStopEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        locked { cached["engineStops"] = (cached["engineStops"] as? Int ?? 0) + 1 }; return 0
    }
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int { 0 }
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) -> Int {
        if let tappedInput, tappedEngine === engine {
            tappedInput.removeTap(onBus: 0); self.tappedInput = nil; tappedEngine = nil
        }
        if let tappedPlayout, tappedPlayoutEngine === engine {
            tappedPlayout.removeTap(onBus: 0); self.tappedPlayout = nil; tappedPlayoutEngine = nil
        }
        locked { cached["enginesReleased"] = (cached["enginesReleased"] as? Int ?? 0) + 1 }; return 0
    }
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, engine: AVAudioEngine,
                           configureInputFromSource source: AVAudioNode?, toDestination destination: AVAudioNode,
                           format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        update(["inputSampleRate": format.sampleRate, "inputChannels": Int(format.channelCount)])
        if let source, source !== tappedInput, format.sampleRate > 0, format.channelCount > 0 {
            tappedInput?.removeTap(onBus: 0)
            tappedInput = source; tappedEngine = engine
            source.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self, self.locked({ self.inputMeterEnabled }) else { return }
                self.inputMeter.render(pcmBuffer: buffer)
            }
        }
        return 0
    }
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, engine: AVAudioEngine,
                           configureOutputFromSource source: AVAudioNode, toDestination destination: AVAudioNode?,
                           format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        update(["outputSampleRate": format.sampleRate, "outputChannels": Int(format.channelCount)])
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
        locked { cached["deviceUpdates"] = (cached["deviceUpdates"] as? Int ?? 0) + 1 }
    }
}
