import AppKit
import AVFoundation
import Foundation
import LiveKitWebRTC

// R4 (docs/r4-shared-engine-plan.md): one process-wide audio engine for every meeting.
// `SharedAudioEngine` owns the one physical owner (factory, module, VPIO unit, observer)
// and arbitrates between meetings; each meeting holds a `MeetingAudioAttachment`.
// Behind the "One audio engine for all meetings" flag, read once at launch.

/// What the shared engine needs from its single physical owner. `GuestSystemAudio`
/// provides it in the app; tests use a fake.
@MainActor protocol SharedAudioModule: AnyObject {
    var factory: LKRTCPeerConnectionFactory { get }
    func prepareIdleInput(timeout: TimeInterval) async -> Bool
    func activateMicrophone(timeout: TimeInterval?) async -> Bool
    func setMicrophoneMuted(_ muted: Bool, timeout: TimeInterval) async -> Bool
    func suppressMicrophone()
    func setInputPermitted(_ permitted: Bool, keepWarm: Bool, timeout: TimeInterval) async -> Bool
    func setPlayoutEnabled(_ enabled: Bool, timeout: TimeInterval, expectedEpoch: UUID?) async -> Bool
    func setTranscriptionOutput(_ keep: Bool, timeout: TimeInterval) async -> Bool
    func beginPrivateInputCheck(timeout: TimeInterval?) async -> Bool
    func endPrivateInputCheck(timeout: TimeInterval) async -> Bool
    func setInputTranscriptionSink(_ sink: ((AVAudioPCMBuffer) -> Void)?)
    func setMicrophoneGate(open: Bool) -> Bool
    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool
    func shutdown(timeout: TimeInterval) async -> Bool
    /// Engine stops/starts the owner did not ask for (device or route change); any thread.
    var onSpontaneousEngineChange: ((GuestEngineChange) -> Void)? { get set }
}

extension GuestSystemAudio: SharedAudioModule {}

/// A meeting's microphone sender. Disabled, it sends silence whatever the module does.
protocol MeetingAudioSender: AnyObject {
    var isEnabled: Bool { get set }
}
extension LKRTCAudioTrack: MeetingAudioSender {}

enum SharedAudioEngineError: LocalizedError, Equatable {
    case cleanupFailed, setupFailed, detached
    var errorDescription: String? {
        switch self {
        case .cleanupFailed: L("Audio could not be released cleanly. Quit and reopen the app to use audio again.")
        case .setupFailed: L("Audio could not be started.")
        case .detached: L("This meeting has already left the audio engine.")
        }
    }
}

@MainActor final class SharedAudioEngine {
    static let flagKey = "nativeDesktop.sharedAudioEngine"
    /// Read once: Rock's factory is fixed for the process, so a change needs a relaunch.
    /// Debug builds also take `R4_SHARED_AUDIO_ENGINE=1|0` so suites can run either way.
    static let enabledAtLaunch: Bool = {
#if DEBUG
        if let value = ProcessInfo.processInfo.environment["R4_SHARED_AUDIO_ENGINE"] { return value == "1" }
#endif
        return UserDefaults.standard.bool(forKey: flagKey)
    }()
    /// The app's one engine; its owner is created when the first meeting attaches.
    static let shared: SharedAudioEngine = {
        let engine = SharedAudioEngine.live()
        engine.observeSystemSleep()
        return engine
    }()

    struct Timeouts {
        var mute: TimeInterval = 2
        var activation: TimeInterval = 8
        var playout: TimeInterval = 2
        var shutdown: TimeInterval = 2
    }

    private let makeModule: @MainActor () async throws -> SharedAudioModule
    private let timeouts: Timeouts
    private let grace: Duration
    private let authorized: () -> Bool
    private let sleep: (Duration) async throws -> Void
    private var module: SharedAudioModule?
    private var attachments: [UUID: MeetingAudioAttachment] = [:]
    private var order: [UUID] = []
    private let work = SharedAudioSerialWork()
    private let inputSink = SharedAudioSinkBox()
    /// The meeting whose sender may be enabled; changes bump the epoch so a stale
    /// meeting's unmute is refused.
    private(set) var talkMeetingID: UUID?
    private(set) var talkEpoch: UInt64 = 0
    private(set) var moduleMuted = true
    private(set) var privateCheckActive = false
    private(set) var playoutOn = false
    private(set) var transcriptionOutputOn = false
    /// A failed release quarantines the engine: no new meeting may attach.
    private(set) var cleanupFailed = false
    /// Keep the device and voice processing running when the talk role leaves (warm move).
    var keepInputWarm = false
    /// The talk meeting's last confirmed unmute; recovery restores exactly this.
    private(set) var talkUnmuted = false
    /// Between an engine stop the app did not ask for and the next start (guarantee 9).
    private(set) var rebuilding = false
    private(set) var recoveries = 0
    /// The talk meeting whose unmute could not be restored after a rebuild (it stays muted).
    var onRecoveryFailed: ((UUID) -> Void)?
    private var sleepObservers: [NSObjectProtocol] = []
    private(set) var foreground = false
    private(set) var foregroundMicrophone = false
    private var foregroundPrepared = false
    private var idleSuspended = false
    private var idleRevision = UUID()
    private var idleDeadline: Task<Void, Never>?

    private let reportFailedStop: () -> Void

    /// `reportFailedStop` blocks every new physical owner in the process (tests replace it).
    init(timeouts: Timeouts = .init(), grace: Duration = .seconds(2),
         authorized: @escaping () -> Bool = { GuestSystemAudio.microphoneAuthorized },
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         reportFailedStop: @escaping () -> Void = { GuestAudioOwnerLease.reportFailedStop() },
         makeModule: @escaping @MainActor () async throws -> SharedAudioModule) {
        self.timeouts = timeouts; self.grace = grace; self.authorized = authorized; self.sleep = sleep
        self.reportFailedStop = reportFailedStop; self.makeModule = makeModule
    }

    /// The app's engine: one non-exclusive `GuestSystemAudio` owner whose factory
    /// LiveKit can adopt (Rock, `installIntoLiveKit`).
    static func live(manualRenderingForTesting: Bool = false) -> SharedAudioEngine {
        SharedAudioEngine {
            try await GuestSystemAudio.create(microphoneEnabled: false, playoutEnabled: false,
                profile: manualRenderingForTesting ? .speech : .saved, concurrent: true,
                manualRendering: manualRenderingForTesting, keepOutputAvailableWithInput: true,
                makeFactory: { SharedAudioEngine.liveKitFactory(voiceProcessing: $0) })
        }
    }

    /// Set once LiveKit holds the owner's factory: the owner then lives for the process
    /// and the last meeting out only idles it (devices and output off).
    private(set) var pinnedForProcess = false
    func pinForProcess() { pinnedForProcess = true }

    var factory: LKRTCPeerConnectionFactory? { module?.factory }
    /// The physical owner when it is the app's `GuestSystemAudio` (diagnostics, snapshots).
    var guestOwner: GuestSystemAudio? { module as? GuestSystemAudio }
    var hasModule: Bool { module != nil }
    var busy: Bool { !attachments.isEmpty || privateCheckActive || cleanupFailed || idleSuspended }
    var meetingIDs: [UUID] { order }
    func attachment(_ id: UUID) -> MeetingAudioAttachment? { attachments[id] }
    func waitForWork() async { await work.wait() }

    private var shouldPrepareForegroundInput: Bool {
        foreground && foregroundMicrophone && !idleSuspended && !cleanupFailed && authorized()
    }

    // MARK: Foreground readiness

    /// Prepares the muted microphone while the app is active with a visible window,
    /// and releases the idle owner after `grace` when the app leaves the foreground.
    func setForeground(_ active: Bool, microphone: Bool) {
        guard foreground != active || foregroundMicrophone != microphone else { return }
        foreground = active; foregroundMicrophone = microphone
        idleRevision = UUID(); idleDeadline?.cancel(); idleDeadline = nil
        guard attachments.isEmpty, !privateCheckActive, !idleSuspended, !cleanupFailed else { return }
        if active {
            scheduleForegroundPreparation()
        } else {
            let token = idleRevision
            idleDeadline = Task { [weak self, sleep, grace] in
                do { try await sleep(grace) } catch { return }
                guard let self, self.idleRevision == token, !self.foreground, self.attachments.isEmpty, !self.privateCheckActive else { return }
                _ = await self.work.run {
                    guard self.idleRevision == token, !self.foreground, self.attachments.isEmpty, !self.privateCheckActive else { return true }
                    return await self.retireIdleLocked()
                }
            }
        }
    }

    private func scheduleForegroundPreparation() {
        let token = idleRevision
        work.enqueue { [self] in
            guard idleRevision == token, foreground, attachments.isEmpty, !privateCheckActive, !idleSuspended, !cleanupFailed else { return true }
            if shouldPrepareForegroundInput {
                guard case .success(let module) = await ensureModuleLocked() else { return false }
                guard idleRevision == token, foreground, attachments.isEmpty, !privateCheckActive, !idleSuspended else {
                    return await retireIdleLocked()
                }
                guard await module.prepareIdleInput(timeout: timeouts.activation) else {
                    _ = await retireIdleLocked()
                    return false
                }
                foregroundPrepared = true
                moduleMuted = true
                return true
            } else {
                return await retireIdleLocked()
            }
        }
    }

    /// Suspends idle foreground preparation and releases an unattached, unpinned owner.
    func suspendIdle() async -> Bool {
        guard !cleanupFailed, attachments.isEmpty, !privateCheckActive else { return false }
        idleSuspended = true; idleRevision = UUID(); idleDeadline?.cancel(); idleDeadline = nil
        return await work.run { [self] in
            guard attachments.isEmpty, !privateCheckActive else { return false }
            return await retireIdleLocked()
        }
    }

    func suspendIdleIfDrained() -> Bool {
        guard !cleanupFailed, attachments.isEmpty, !privateCheckActive, module == nil, !idleSuspended else { return false }
        idleSuspended = true; idleRevision = UUID(); idleDeadline?.cancel(); idleDeadline = nil
        return true
    }

    func resumeIdle(clean: Bool) {
        guard idleSuspended else { return }
        idleSuspended = false; idleRevision = UUID(); idleDeadline?.cancel(); idleDeadline = nil
        guard clean else { quarantine(); return }
        if foreground, attachments.isEmpty, !privateCheckActive, !cleanupFailed {
            scheduleForegroundPreparation()
        }
    }

    func shutdownIdle() async -> Bool {
        foreground = false; foregroundMicrophone = false; idleSuspended = true
        idleRevision = UUID(); idleDeadline?.cancel(); idleDeadline = nil
        guard attachments.isEmpty, !privateCheckActive else { return false }
        return await work.run { [self] in await retireIdleLocked() }
    }

    // MARK: Attach / detach

    func attach(meetingID: UUID) async throws -> MeetingAudioAttachment {
        idleRevision = UUID(); idleDeadline?.cancel(); idleDeadline = nil
        var result: Result<MeetingAudioAttachment, Error> = .failure(SharedAudioEngineError.setupFailed)
        _ = await work.run { [self] in
            guard !cleanupFailed else { result = .failure(SharedAudioEngineError.cleanupFailed); return false }
            if let existing = attachments[meetingID] { result = .success(existing); return true }
            switch await ensureModuleLocked() {
            case .success: break
            case .failure(let error): result = .failure(error); return false
            }
            let attachment = MeetingAudioAttachment(meetingID: meetingID, engine: self)
            attachments[meetingID] = attachment; order.append(meetingID)
            result = .success(attachment)
            return true
        }
        return try result.get()
    }

    /// Senders are disabled and received audio silenced before anything else.
    /// The last meeting out shuts the module down, which releases the device, unless
    /// foreground microphone readiness keeps the idle module warm.
    @discardableResult func detach(_ attachment: MeetingAudioAttachment) async -> Bool {
        attachment.disableSenders(); attachment.silenceReceived()
        return await work.run { [self] in
            guard attachments[attachment.meetingID] === attachment else { return true }
            var success = true
            let lastAttachment = attachments.count == 1
            if talkMeetingID == attachment.meetingID {
                success = await releaseTalkLocked(keepForegroundWarm: lastAttachment && shouldPrepareForegroundInput) && success
            }
            attachments[attachment.meetingID] = nil; order.removeAll { $0 == attachment.meetingID }
            attachment.markDetached()
            if attachments.isEmpty, shouldPrepareForegroundInput, let module {
                success = await applyOutputLocked() && success
                let prepared = await module.prepareIdleInput(timeout: timeouts.activation)
                foregroundPrepared = prepared
                moduleMuted = true
                success = prepared && success
            } else if attachments.isEmpty {
                success = await retireIdleLocked() && success
            } else {
                success = await applyOutputLocked() && success
            }
            if !success { quarantine() }
            return success
        }
    }

    // MARK: Talk role

    /// Moves the talk role. Every sender is disabled and the module muted first; the
    /// new talk meeting starts muted and must unmute itself.
    @discardableResult func assignTalk(to attachment: MeetingAudioAttachment) async -> Bool {
        await work.run { [self] in
            guard attachments[attachment.meetingID] === attachment, !cleanupFailed else { return false }
            if talkMeetingID == attachment.meetingID { return true }
            guard await muteEverythingLocked() else { return false }
            talkUnmuted = false
            talkMeetingID = attachment.meetingID; talkEpoch &+= 1
            inputSink.set(attachment.inputSinkHandler)
            _ = module?.setMicrophoneGate(open: true)
            return await module?.setInputPermitted(true, keepWarm: false, timeout: timeouts.mute) ?? false
        }
    }

    @discardableResult func releaseTalk(from attachment: MeetingAudioAttachment) async -> Bool {
        await work.run { [self] in
            guard talkMeetingID == attachment.meetingID else { return true }
            return await releaseTalkLocked()
        }
    }

    // MARK: Mute (guarantees 1 and 2)

    /// Muting always succeeds locally: senders off at once, module muted in order.
    /// Unmuting needs the talk role, the epoch it was granted at, no private check,
    /// and every other meeting's sender off before the module opens.
    @discardableResult func setMuted(_ muted: Bool, for attachment: MeetingAudioAttachment, epoch: UInt64) async -> Bool {
        if muted { attachment.disableSenders() }
        return await work.run { [self] in
            guard let module, attachments[attachment.meetingID] === attachment else { return muted }
            let isTalk = talkMeetingID == attachment.meetingID
            if muted {
                attachment.disableSenders()
                guard isTalk else { return true }
                talkUnmuted = false
                return await muteModuleLocked(module)
            }
            guard isTalk, epoch == talkEpoch, !privateCheckActive, !cleanupFailed else { return false }
            let unmuted = await unmuteLocked(attachment, module: module, epoch: epoch)
            if unmuted { talkUnmuted = true }
            return unmuted
        }
    }

    // MARK: Recovery (guarantee 9)

    /// An engine stop the app did not ask for (device or route change, sleep): every sender
    /// off at once, the module muted in order. The next start restores the talk meeting's
    /// last confirmed unmute, through the same ordered path as a user's unmute.
    @discardableResult func engineChanged(_ change: GuestEngineChange) -> Task<Bool, Never>? {
        switch change {
        case .stopped:
            guard !rebuilding else { return nil }
            rebuilding = true
            for attachment in attachments.values { attachment.disableSenders() }
            return Task { await work.run { [self] in
                guard let module else { return true }
                return await muteModuleLocked(module)
            } }
        case .started:
            guard rebuilding else { return nil }
            return Task { await work.run { [self] in
                guard rebuilding else { return true }
                rebuilding = false; recoveries += 1
                guard talkUnmuted, let id = talkMeetingID, let talk = attachments[id], let module,
                      !privateCheckActive, !cleanupFailed else { return true }
                let restored = await unmuteLocked(talk, module: module, epoch: talkEpoch)
                if !restored { talkUnmuted = false; onRecoveryFailed?(id) }
                return restored
            } }
        }
    }

    /// Sleep and wake go through the same path as an engine rebuild.
    func observeSystemSleep() {
        guard sleepObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.engineChanged(.stopped) }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.engineChanged(.started) }
            },
        ]
    }

    /// Starts the microphone muted for the talk meeting after an explicit microphone
    /// action; another meeting's request waits for its next unmute with the talk role.
    func activateInput(for attachment: MeetingAudioAttachment) async -> Bool {
        await work.run { [self] in
            guard let module, attachments[attachment.meetingID] === attachment, !cleanupFailed else { return false }
            guard talkMeetingID == attachment.meetingID else { return true }
            return await module.activateMicrophone(timeout: timeouts.activation)
        }
    }

    /// Recovery (S5): every sender off and the module muted until each meeting re-confirms.
    @discardableResult func disableAllSenders() async -> Bool {
        await work.run { [self] in await muteEverythingLocked() }
    }

    // MARK: Private microphone check (guarantee 4)

    /// Only while no sender is enabled and the module is muted; unmuting is refused meanwhile.
    func beginPrivateCheck() async -> Bool {
        await work.run { [self] in
            guard let module, !privateCheckActive, moduleMuted,
                  attachments.values.allSatisfy({ !$0.anySenderEnabled }) else { return false }
            // Without a talk meeting input is withdrawn; the check permits it for itself.
            if talkMeetingID == nil, !(await module.setInputPermitted(true, keepWarm: false, timeout: timeouts.mute)) { return false }
            guard await module.beginPrivateInputCheck(timeout: nil) else {
                if talkMeetingID == nil { _ = await module.setInputPermitted(false, keepWarm: false, timeout: timeouts.activation) }
                return false
            }
            privateCheckActive = true
            return true
        }
    }

    @discardableResult func endPrivateCheck() async -> Bool {
        await work.run { [self] in
            guard privateCheckActive, let module else { return true }
            privateCheckActive = false
            let ended = await module.endPrivateInputCheck(timeout: timeouts.mute)
            guard talkMeetingID == nil else { return ended }
            let keepWarm = keepInputWarm || (attachments.isEmpty && shouldPrepareForegroundInput)
            return await module.setInputPermitted(false, keepWarm: keepWarm, timeout: timeouts.activation) && ended
        }
    }

    // MARK: Output

    /// Playout runs while any meeting has sound on; otherwise output runs silenced
    /// while any meeting transcribes. Per-meeting sound is the received tracks' volume.
    @discardableResult func outputChanged() async -> Bool {
        await work.run { [self] in await applyOutputLocked() }
    }

    // MARK: Voice replies (talk meeting only)

    func setMicrophoneGate(open: Bool, for attachment: MeetingAudioAttachment) -> Bool {
        guard talkMeetingID == attachment.meetingID, let module else { return false }
        return module.setMicrophoneGate(open: open)
    }

    func playVoiceReply(_ buffer: AVAudioPCMBuffer, for attachment: MeetingAudioAttachment) async -> Bool {
        guard talkMeetingID == attachment.meetingID, let module else { return false }
        return await module.playVoiceReply(buffer)
    }

    // MARK: Internals (run inside `work`)

    /// Every other sender off, input active, then this meeting's senders and the module.
    private func unmuteLocked(_ attachment: MeetingAudioAttachment, module: SharedAudioModule, epoch: UInt64) async -> Bool {
        for other in attachments.values where other !== attachment { other.disableSenders() }
        guard attachments.values.allSatisfy({ $0 === attachment || !$0.anySenderEnabled }) else { return false }
        guard await module.activateMicrophone(timeout: timeouts.activation) else { return false }
        // Still the talk meeting at the same epoch after the (possibly slow) activation.
        guard talkMeetingID == attachment.meetingID, epoch == talkEpoch else { return false }
        attachment.enableSenders()
        guard await module.setMicrophoneMuted(false, timeout: timeouts.mute) else {
            attachment.disableSenders(); module.suppressMicrophone(); moduleMuted = true
            return false
        }
        moduleMuted = false
        return true
    }

    private func muteEverythingLocked() async -> Bool {
        for attachment in attachments.values { attachment.disableSenders() }
        guard let module else { return true }
        return await muteModuleLocked(module)
    }

    private func muteModuleLocked(_ module: SharedAudioModule) async -> Bool {
        moduleMuted = true
        guard await module.setMicrophoneMuted(true, timeout: timeouts.mute) else {
            module.suppressMicrophone(); return false
        }
        return true
    }

    private func ensureModuleLocked() async -> Result<SharedAudioModule, Error> {
        if let module { return .success(module) }
        do {
            let created = try await makeModule()
            created.setInputTranscriptionSink { [inputSink] buffer in inputSink.deliver(buffer) }
            created.onSpontaneousEngineChange = { [weak self] change in
                Task { @MainActor in self?.engineChanged(change) }
            }
            module = created
            return .success(created)
        } catch {
            return .failure(error)
        }
    }

    private func retireIdleLocked() async -> Bool {
        guard attachments.isEmpty, !privateCheckActive else { return true }
        guard let module else { foregroundPrepared = false; return true }
        inputSink.set(nil)
        if pinnedForProcess {
            // LiveKit holds the factory: idle (the talk role already released input,
            // or foreground preparation must now release input).
            var success = true
            if foregroundPrepared {
                foregroundPrepared = false
                success = await module.setInputPermitted(false, keepWarm: false, timeout: timeouts.activation) && success
            }
            moduleMuted = true
            return await applyOutputLocked() && success
        }
        foregroundPrepared = false
        let stopped = await module.shutdown(timeout: timeouts.shutdown)
        self.module = nil
        playoutOn = false; transcriptionOutputOn = false; moduleMuted = true; privateCheckActive = false
        if !stopped { quarantine() }
        return stopped
    }

    private func releaseTalkLocked(keepForegroundWarm: Bool = false) async -> Bool {
        let muted = await muteEverythingLocked()
        talkUnmuted = false
        talkMeetingID = nil; talkEpoch &+= 1
        inputSink.set(nil)
        guard let module else { return muted }
        let released = await module.setInputPermitted(false, keepWarm: keepInputWarm || keepForegroundWarm, timeout: timeouts.activation)
        return muted && released
    }

    private func applyOutputLocked() async -> Bool {
        let sound = attachments.values.contains { $0.soundOn }
        let transcription = !sound && attachments.values.contains { $0.transcriptionOutput }
        for attachment in attachments.values { attachment.applyReceivedVolumes() }
        guard let module else { return true }
        var success = true
        if transcription != transcriptionOutputOn {
            success = await module.setTranscriptionOutput(transcription, timeout: timeouts.playout) && success
            transcriptionOutputOn = transcription
        }
        if sound != playoutOn {
            success = await module.setPlayoutEnabled(sound, timeout: timeouts.playout, expectedEpoch: nil) && success
            playoutOn = sound
        }
        return success
    }

    private func quarantine() {
        cleanupFailed = true
        reportFailedStop()
    }
}

/// One meeting on the shared engine: its microphone senders, received tracks,
/// mute intent, sound and volume.
@MainActor final class MeetingAudioAttachment {
    let meetingID: UUID
    private weak var engine: SharedAudioEngine?
    private var senders: [ObjectIdentifier: MeetingAudioSender] = [:]
    private var received: [String: (setVolume: (Double) -> Void, participant: Double)] = [:]
    private(set) var detached = false
    private(set) var soundOn = false
    private(set) var transcriptionOutput = false
    private(set) var meetingVolume: Double = 1
    private let inputSink = SharedAudioSinkBox()

    fileprivate init(meetingID: UUID, engine: SharedAudioEngine) {
        self.meetingID = meetingID; self.engine = engine
    }

    var factory: LKRTCPeerConnectionFactory? { engine?.factory }
    var isTalk: Bool { engine?.talkMeetingID == meetingID }
    /// The epoch to pass when unmuting; refreshed each time the talk role arrives.
    var talkEpoch: UInt64? { isTalk ? engine?.talkEpoch : nil }
    var anySenderEnabled: Bool { senders.values.contains { $0.isEnabled } }

    // Senders: registered disabled; only the engine enables them.
    func addSender(_ sender: MeetingAudioSender) {
        sender.isEnabled = false
        guard !detached else { return }
        senders[ObjectIdentifier(sender)] = sender
    }
    func removeSender(_ sender: MeetingAudioSender) {
        sender.isEnabled = false
        senders[ObjectIdentifier(sender)] = nil
    }
    /// A finished connection attempt: its tracks are off and forgotten.
    func removeAllSenders() { disableSenders(); senders.removeAll() }
    /// Privacy barrier: senders off now, the module mute follows in order.
    func suppress() {
        disableSenders()
        Task { await setMuted(true) }
    }
    var moduleMuted: Bool { engine?.moduleMuted ?? true }
    var privateCheckActive: Bool { engine?.privateCheckActive ?? false }

    // Received tracks: volume = meeting volume × participant volume, 0 with sound off.
    func addReceived(id: String, participantVolume: Double = 1, setVolume: @escaping (Double) -> Void) {
        guard !detached else { setVolume(0); return }
        received[id] = (setVolume, participantVolume)
        setVolume(effectiveVolume(participantVolume))
    }
    func removeReceived(id: String) { received[id] = nil }
    func removeAllReceived() { received.removeAll() }
    func setParticipantVolume(_ volume: Double, id: String) {
        guard var entry = received[id] else { return }
        entry.participant = Self.clamp(volume); received[id] = entry
        entry.setVolume(effectiveVolume(entry.participant))
    }
    func setMeetingVolume(_ volume: Double) {
        meetingVolume = Self.clamp(volume); applyReceivedVolumes()
    }
    @discardableResult func setSound(_ on: Bool) async -> Bool {
        soundOn = on && !detached
        return await engine?.outputChanged() ?? !on
    }
    @discardableResult func setTranscriptionOutput(_ keep: Bool) async -> Bool {
        transcriptionOutput = keep && !detached
        return await engine?.outputChanged() ?? !keep
    }

    /// Your microphone's buffers while this meeting has the talk role (audio thread;
    /// copy and return). Whether the meeting is unmuted is the caller's gate.
    func setInputTranscriptionSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) { inputSink.set(sink) }
    fileprivate var inputSinkHandler: (AVAudioPCMBuffer) -> Void { { [inputSink] in inputSink.deliver($0) } }

    // Talk and mute go through the engine's serial order.
    @discardableResult func assumeTalk() async -> Bool { await engine?.assignTalk(to: self) ?? false }
    @discardableResult func relinquishTalk() async -> Bool { await engine?.releaseTalk(from: self) ?? true }
    @discardableResult func setMuted(_ muted: Bool, epoch: UInt64? = nil) async -> Bool {
        guard let engine else { if muted { disableSenders() }; return muted }
        return await engine.setMuted(muted, for: self, epoch: epoch ?? talkEpoch ?? .max)
    }
    func setMicrophoneGate(open: Bool) -> Bool { engine?.setMicrophoneGate(open: open, for: self) ?? false }
    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool { await engine?.playVoiceReply(buffer, for: self) ?? false }
    @discardableResult func detach() async -> Bool { await engine?.detach(self) ?? true }

    fileprivate func enableSenders() { for sender in senders.values { sender.isEnabled = true } }
    fileprivate func disableSenders() { for sender in senders.values { sender.isEnabled = false } }
    fileprivate func silenceReceived() { for entry in received.values { entry.setVolume(0) } }
    fileprivate func applyReceivedVolumes() { for entry in received.values { entry.setVolume(effectiveVolume(entry.participant)) } }
    fileprivate func markDetached() {
        detached = true; soundOn = false; transcriptionOutput = false
        disableSenders(); silenceReceived(); inputSink.set(nil)
    }
    private func effectiveVolume(_ participant: Double) -> Double { soundOn && !detached ? meetingVolume * participant : 0 }
    private static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 1 }
}

/// Runs the engine's operations one at a time, in call order.
@MainActor private final class SharedAudioSerialWork {
    private var tail: Task<Bool, Never>?
    @discardableResult func enqueue(_ body: @escaping @MainActor () async -> Bool) -> Task<Bool, Never> {
        let previous = tail
        let task = Task { @MainActor in
            _ = await previous?.value
            return await body()
        }
        tail = task
        return task
    }
    func run(_ body: @escaping @MainActor () async -> Bool) async -> Bool {
        await enqueue(body).value
    }
    func wait() async { _ = await tail?.value }
}

/// An audio-thread sink that can be swapped from the main thread.
private final class SharedAudioSinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    func set(_ value: ((AVAudioPCMBuffer) -> Void)?) { lock.lock(); sink = value; lock.unlock() }
    func deliver(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let current = sink; lock.unlock()
        current?(buffer)
    }
}
