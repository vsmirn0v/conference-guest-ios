#if os(macOS)
import AppKit
#endif
import AVFoundation
import Foundation
import LiveKitWebRTC

// R4 (docs/r4-shared-engine-plan.md): one process-wide audio engine for every meeting.
// `SharedAudioEngine` owns the one physical owner (factory, module, VPIO unit, observer)
// and arbitrates between meetings; each meeting holds a `MeetingAudioAttachment`.
// Production uses this engine for all meetings. Debug and comparison builds can select the legacy path.

/// What the shared engine needs from its single physical owner. `GuestSystemAudio`
/// provides it in the app; tests use a fake.
@MainActor public protocol SharedAudioModule: AnyObject {
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
    func playVoiceReply(_ buffer: AVAudioPCMBuffer, localGain: Float) async -> Bool
    func setVoiceReplyMonitorGain(_ gain: Float)
    var hasParticipationVoiceGraph: Bool { get }
    var participationVoiceGateClosed: Bool { get }
    func playParticipationVoice(_ buffer: AVAudioPCMBuffer, permit: GuestAutonomousVoicePlayback,
                                canStart: @escaping @MainActor () -> Bool, localGain: @escaping @MainActor () -> Float?,
                                onStarted: @escaping @MainActor () -> Void) async -> GuestAutonomousVoicePlayback.Outcome
    func shutdown(timeout: TimeInterval) async -> Bool
    /// Engine stops/starts the owner did not ask for (device or route change); any thread.
    var onSpontaneousEngineChange: ((GuestEngineChange) -> Void)? { get set }
}

extension GuestSystemAudio: SharedAudioModule {}

public extension SharedAudioModule {
    func playVoiceReply(_ buffer: AVAudioPCMBuffer, localGain: Float) async -> Bool { await playVoiceReply(buffer) }
    func setVoiceReplyMonitorGain(_ gain: Float) {}
    var hasParticipationVoiceGraph: Bool { false }
    var participationVoiceGateClosed: Bool { false }
    func playParticipationVoice(_ buffer: AVAudioPCMBuffer, permit: GuestAutonomousVoicePlayback,
                                canStart: @escaping @MainActor () -> Bool, localGain: @escaping @MainActor () -> Float?,
                                onStarted: @escaping @MainActor () -> Void) async -> GuestAutonomousVoicePlayback.Outcome { .notStarted }
}

/// A meeting's microphone sender. Disabled, it sends silence whatever the module does.
public protocol MeetingAudioSender: AnyObject {
    var isEnabled: Bool { get set }
}
extension LKRTCAudioTrack: MeetingAudioSender {}

public enum SharedAudioEngineError: LocalizedError, Equatable {
    case cleanupFailed, setupFailed, detached
    public var errorDescription: String? {
        switch self {
        case .cleanupFailed: L("Audio could not be released cleanly. Quit and reopen the app to use audio again.")
        case .setupFailed: L("Audio could not be started.")
        case .detached: L("This meeting has already left the audio engine.")
        }
    }
}

@MainActor public final class SharedAudioEngine {
    /// Production always uses the shared engine, regardless of an obsolete saved preference.
    /// Debug and explicit comparison builds retain the legacy route for testing.
    public static let enabledAtLaunch: Bool = {
#if DEBUG || NATIVE_LEGACY_AUDIO
        if let value = ProcessInfo.processInfo.environment["R4_SHARED_AUDIO_ENGINE"] { return value == "1" }
#endif
        return true
    }()
    /// The app's one engine; its owner is created when the first meeting attaches.
    public static let shared: SharedAudioEngine = {
        let engine = SharedAudioEngine.live(installIntoLiveKitOnCreate: true)
        engine.observeSystemSleep()
        return engine
    }()

    public struct Timeouts {
        public var mute: TimeInterval = 2
        public var activation: TimeInterval = 8
        public var playout: TimeInterval = 2
        public var shutdown: TimeInterval = 2
        public init(mute: TimeInterval = 2, activation: TimeInterval = 8, playout: TimeInterval = 2, shutdown: TimeInterval = 2) {
            self.mute = mute; self.activation = activation; self.playout = playout; self.shutdown = shutdown
        }
    }

    private let makeModule: @MainActor () async throws -> SharedAudioModule
    private let timeouts: Timeouts
    private let grace: Duration
    private let authorized: () -> Bool
    private let sleep: (Duration) async throws -> Void
    private var module: SharedAudioModule?
    private var participationPlayback: GuestAutonomousVoicePlayback?
    private var participationSender: GuestAutonomousVoicePlayback?
    private var attachments: [UUID: MeetingAudioAttachment] = [:]
    private var order: [UUID] = []
    private let work = SharedAudioSerialWork()
    private let inputSink = SharedAudioSinkBox()
    /// The meeting whose sender may be enabled; changes bump the epoch so a stale
    /// meeting's unmute is refused.
    public private(set) var talkMeetingID: UUID?
    /// The legacy companion has no UI for cross-workspace handover. While it owns
    /// talk, reject other attachments until it has fully detached.
    private var exclusiveTalkMeetingID: UUID?
    public private(set) var talkEpoch: UInt64 = 0
    public private(set) var moduleMuted = true
    /// The module's last native mute succeeded and nothing has tried to unmute it since.
    /// `moduleMuted` alone is set even when the native mute timed out.
    public private(set) var muteConfirmed = false
    public private(set) var privateCheckActive = false
    public private(set) var playoutOn = false
    public private(set) var transcriptionOutputOn = false
    /// A failed release quarantines the engine: no new meeting may attach.
    public private(set) var cleanupFailed = false
    /// Keep the device and voice processing running when the talk role leaves (warm move).
    public var keepInputWarm = false
    /// The talk meeting's last confirmed unmute; recovery restores exactly this.
    public private(set) var talkUnmuted = false
    /// Between an engine stop the app did not ask for and the next start (guarantee 9).
    public private(set) var rebuilding = false
    public private(set) var recoveries = 0
    /// The talk meeting whose unmute could not be restored after a rebuild (it stays muted).
    public var onRecoveryFailed: ((UUID) -> Void)?
    private var sleepObservers: [NSObjectProtocol] = []
    public private(set) var foreground = false
    public private(set) var foregroundMicrophone = false
    private var foregroundPrepared = false
    private var idleSuspended = false
    private var idleRevision = UUID()
    private var idleDeadline: Task<Void, Never>?

    private let reportFailedStop: () -> Void
    private let installIntoLiveKitOnCreate: Bool

    /// `reportFailedStop` blocks every new physical owner in the process (tests replace it).
    public init(timeouts: Timeouts = .init(), grace: Duration = .seconds(2),
         authorized: @escaping () -> Bool = { GuestSystemAudio.microphoneAuthorized },
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         reportFailedStop: @escaping () -> Void = { GuestAudioOwnerLease.reportFailedStop() },
         installIntoLiveKitOnCreate: Bool = false,
         makeModule: @escaping @MainActor () async throws -> SharedAudioModule) {
        self.timeouts = timeouts; self.grace = grace; self.authorized = authorized; self.sleep = sleep
        self.reportFailedStop = reportFailedStop; self.installIntoLiveKitOnCreate = installIntoLiveKitOnCreate
        self.makeModule = makeModule
    }

    /// The app's engine: one non-exclusive `GuestSystemAudio` owner whose factory
    /// LiveKit adopts up front when `installIntoLiveKitOnCreate` is true.
    public static func live(manualRenderingForTesting: Bool = false,
                     installIntoLiveKitOnCreate: Bool = false) -> SharedAudioEngine {
        SharedAudioEngine(installIntoLiveKitOnCreate: installIntoLiveKitOnCreate) {
            try await GuestSystemAudio.create(microphoneEnabled: false, playoutEnabled: false,
                profile: manualRenderingForTesting ? .speech : .saved, concurrent: true,
                manualRendering: manualRenderingForTesting, keepOutputAvailableWithInput: true,
                makeFactory: { SharedAudioEngine.liveKitFactory(voiceProcessing: $0) })
        }
    }

    /// Set once LiveKit holds the owner's factory: the owner then lives for the process
    /// and the last meeting out only idles it (devices and output off).
    public private(set) var pinnedForProcess = false
    public func pinForProcess() { pinnedForProcess = true }

    public var factory: LKRTCPeerConnectionFactory? { module?.factory }
    /// The physical owner when it is the app's `GuestSystemAudio` (diagnostics, snapshots).
    public var guestOwner: GuestSystemAudio? { module as? GuestSystemAudio }
    public var hasModule: Bool { module != nil }
    public var busy: Bool { !attachments.isEmpty || privateCheckActive || cleanupFailed || idleSuspended }
    public var meetingIDs: [UUID] { order }
    public func attachment(_ id: UUID) -> MeetingAudioAttachment? { attachments[id] }
    /// A bounded, content-free snapshot, sampled only on explicit diagnostics.
    /// Object identifiers are process-local hashes, not addresses or persistent IDs.
    public var ownershipDiagnostics: [String: Any] {
        let entries = order.prefix(16).compactMap { id -> [String: Any]? in
            guard let attachment = attachments[id] else { return nil }
            return ["attachment": id.uuidString, "talk": id == talkMeetingID,
                    "senderEnabled": "unavailable", "soundOn": attachment.soundOn,
                    "registeredSenderCount": attachment.registeredSenderCount,
                    "lastAttachmentSenderCommand": attachment.lastSenderCommand,
                    "transcriptionOutput": attachment.transcriptionOutput]
        }
        let ownerSnapshot = guestOwner?.snapshot ?? [:]
        return ["owner": module.map { String(ObjectIdentifier($0).hashValue) } ?? "none",
                "ownerIdentityScope": "shared-module-wrapper-not-adm",
                "ownerLeaseID": ownerSnapshot["ownerLeaseID"] as? String ?? "unavailable",
                "ownerGeneration": ownerSnapshot["ownerGeneration"] as? String ?? "unavailable",
                "factoryGeneration": ownerSnapshot["factoryGeneration"] as? String ?? "unavailable",
                "audioModuleGeneration": ownerSnapshot["audioModuleGeneration"] as? String ?? "unavailable",
                "graphCreateCount": ownerSnapshot["enginesCreated"] ?? NSNull(),
                "graphStartCount": ownerSnapshot["engineStarts"] ?? NSNull(),
                "graphReleaseCount": ownerSnapshot["enginesReleased"] ?? NSNull(),
                "factoryPurpose": "shared-audio-and-native-peers",
                "attachmentCount": attachments.count, "attachments": entries,
                "attachmentsTruncated": max(0, order.count - entries.count),
                "talkEpoch": String(talkEpoch), "moduleMuted": moduleMuted,
                "muteConfirmed": muteConfirmed, "pinnedForProcess": pinnedForProcess,
                "privateCheckActive": privateCheckActive, "rebuilding": rebuilding,
                "cleanupFailed": cleanupFailed]
    }
    public func waitForWork() async { await work.wait() }

    private var shouldPrepareForegroundInput: Bool {
        foreground && foregroundMicrophone && !idleSuspended && !cleanupFailed && authorized()
    }

    // MARK: Foreground readiness

    /// Prepares the muted microphone while the app is active with a visible window,
    /// and releases the idle owner after `grace` when the app leaves the foreground.
    public func setForeground(_ active: Bool, microphone: Bool) {
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
                rebuilding = false
                return true
            } else {
                return await retireIdleLocked()
            }
        }
    }

    /// Suspends idle foreground preparation and releases an unattached, unpinned owner.
    public func suspendIdle() async -> Bool {
        guard !cleanupFailed, attachments.isEmpty, !privateCheckActive else { return false }
        idleSuspended = true; idleRevision = UUID(); idleDeadline?.cancel(); idleDeadline = nil
        return await work.run { [self] in
            guard attachments.isEmpty, !privateCheckActive else { return false }
            return await retireIdleLocked()
        }
    }

    public func suspendIdleIfDrained() -> Bool {
        guard !cleanupFailed, attachments.isEmpty, !privateCheckActive, module == nil, !idleSuspended else { return false }
        idleSuspended = true; idleRevision = UUID(); idleDeadline?.cancel(); idleDeadline = nil
        return true
    }

    public func resumeIdle(clean: Bool) {
        guard idleSuspended else { return }
        idleSuspended = false; idleRevision = UUID(); idleDeadline?.cancel(); idleDeadline = nil
        guard clean else { quarantine(); return }
        if foreground, attachments.isEmpty, !privateCheckActive, !cleanupFailed {
            scheduleForegroundPreparation()
        }
    }

    public func shutdownIdle() async -> Bool {
        foreground = false; foregroundMicrophone = false; idleSuspended = true
        idleRevision = UUID(); idleDeadline?.cancel(); idleDeadline = nil
        guard attachments.isEmpty, !privateCheckActive else { return false }
        return await work.run { [self] in await retireIdleLocked() }
    }

    // MARK: Attach / detach

    public func retirePrewarmedOwnerBeforeLiveKit() async -> Bool {
        await work.run { [self] in
            guard !pinnedForProcess, attachments.isEmpty, guestOwner?.hasCreatedAudioEngines == true else { return true }
            return await retireIdleLocked()
        }
    }

    public func attach(meetingID: UUID) async throws -> MeetingAudioAttachment {
        idleRevision = UUID(); idleDeadline?.cancel(); idleDeadline = nil
        var result: Result<MeetingAudioAttachment, Error> = .failure(SharedAudioEngineError.setupFailed)
        _ = await work.run { [self] in
            guard !cleanupFailed else { result = .failure(SharedAudioEngineError.cleanupFailed); return false }
            if let existing = attachments[meetingID] { result = .success(existing); return true }
            guard exclusiveTalkMeetingID == nil else { result = .failure(SharedAudioEngineError.setupFailed); return false }
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
    @discardableResult public func detach(_ attachment: MeetingAudioAttachment) async -> Bool {
        if talkMeetingID == attachment.meetingID { cancelParticipationVoice() }
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
                if prepared { rebuilding = false }
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
    @discardableResult public func assignTalk(to attachment: MeetingAudioAttachment, exclusively: Bool = false) async -> Bool {
        await work.run { [self] in
            guard attachments[attachment.meetingID] === attachment, !cleanupFailed,
                  exclusiveTalkMeetingID == nil || exclusiveTalkMeetingID == attachment.meetingID else { return false }
            if exclusively {
                guard attachments.count == 1, talkMeetingID == nil || talkMeetingID == attachment.meetingID else { return false }
            }
            if talkMeetingID == attachment.meetingID {
                if exclusively { exclusiveTalkMeetingID = attachment.meetingID }
                return true
            }
            guard await muteEverythingLocked() else { return false }
            talkUnmuted = false
            talkMeetingID = attachment.meetingID; talkEpoch &+= 1
            inputSink.set(attachment.inputSinkHandler)
            _ = module?.setMicrophoneGate(open: true)
            let permitted = await module?.setInputPermitted(true, keepWarm: false, timeout: timeouts.mute) ?? false
            if permitted && exclusively { exclusiveTalkMeetingID = attachment.meetingID }
            return permitted
        }
    }

    @discardableResult public func releaseTalk(from attachment: MeetingAudioAttachment) async -> Bool {
        await work.run { [self] in
            guard talkMeetingID == attachment.meetingID else { return true }
            return await releaseTalkLocked()
        }
    }

    // MARK: Mute (guarantees 1 and 2)

    /// Muting always succeeds locally: senders off at once, module muted in order.
    /// Unmuting needs the talk role, the epoch it was granted at, no private check,
    /// and every other meeting's sender off before the module opens.
    @discardableResult public func setMuted(_ muted: Bool, for attachment: MeetingAudioAttachment, epoch: UInt64) async -> Bool {
        if talkMeetingID == attachment.meetingID { cancelParticipationVoice() }
        if muted { attachment.disableSenders() }
        return await work.run { [self] in
            guard let module, attachments[attachment.meetingID] === attachment else { return muted }
            let isTalk = talkMeetingID == attachment.meetingID
            if muted {
                attachment.disableSenders()
                guard isTalk else { return true }
                participationSender = nil
                talkUnmuted = false
                return await muteModuleLocked(module)
            }
            guard isTalk, epoch == talkEpoch, !privateCheckActive, !cleanupFailed else { return false }
            guard participationSender == nil else { return false }
            let unmuted = await unmuteLocked(attachment, module: module, epoch: epoch)
            if unmuted { talkUnmuted = true }
            return unmuted
        }
    }

    // MARK: Recovery (guarantee 9)

    /// An engine stop the app did not ask for (device or route change, sleep): every sender
    /// off at once, the module muted in order. The next start restores the talk meeting's
    /// last confirmed unmute, through the same ordered path as a user's unmute.
    @discardableResult public func engineChanged(_ change: GuestEngineChange) -> Task<Bool, Never>? {
        switch change {
        case .stopped:
            guard !rebuilding else { return nil }
            rebuilding = true
            cancelParticipationVoice()
            for attachment in attachments.values { attachment.disableSenders() }
            return Task { await work.run { [self] in
                guard let module else { return true }
                // Already confirmed muted with senders off: a native mute now only waits on
                // the rebuilding ADM worker (beta 84, Bluetooth → built-in: >2 s, then a
                // timeout and a queued suppress behind it) and changes nothing.
                if muteConfirmed, moduleMuted, !talkUnmuted, !privateCheckActive { return true }
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
#if os(macOS)
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.engineChanged(.stopped) }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.engineChanged(.started) }
            },
        ]
#elseif os(iOS)
        let center = NotificationCenter.default
        sleepObservers = [
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    _ = self?.engineChanged(.stopped)
                    _ = self?.engineChanged(.started)
                }
            },
        ]
#endif
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
    public func beginPrivateCheck() async -> Bool {
        await work.run { [self] in
            guard !privateCheckActive, moduleMuted,
                  attachments.values.allSatisfy({ !$0.anySenderEnabled }) else { return false }
            let ensured: SharedAudioModule
            if let existing = self.module {
                ensured = existing
            } else {
                guard case .success(let created) = await ensureModuleLocked() else { return false }
                ensured = created
            }
            let createdIdle = attachments.isEmpty && !foregroundPrepared && !pinnedForProcess
            // Without a talk meeting input is withdrawn; the check permits it for itself.
            if talkMeetingID == nil, !(await ensured.setInputPermitted(true, keepWarm: false, timeout: timeouts.mute)) {
                if createdIdle { _ = await retireIdleLocked() }
                return false
            }
            guard await ensured.beginPrivateInputCheck(timeout: nil) else {
                if talkMeetingID == nil { _ = await ensured.setInputPermitted(false, keepWarm: false, timeout: timeouts.activation) }
                if createdIdle { _ = await retireIdleLocked() }
                return false
            }
            privateCheckActive = true
            muteConfirmed = false
            return true
        }
    }

    @discardableResult public func endPrivateCheck() async -> Bool {
        await work.run { [self] in
            guard privateCheckActive, let module else { return true }
            privateCheckActive = false
            let ended = await module.endPrivateInputCheck(timeout: timeouts.mute)
            guard talkMeetingID == nil else { return ended }
            let keepWarm = keepInputWarm || (attachments.isEmpty && shouldPrepareForegroundInput)
            let released = await module.setInputPermitted(false, keepWarm: keepWarm, timeout: timeouts.activation) && ended
            if attachments.isEmpty, !shouldPrepareForegroundInput {
                return await retireIdleLocked() && released
            }
            return released
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
        guard talkMeetingID == attachment.meetingID, attachment.soundOn, attachment.meetingVolume > 0,
              let module else { return false }
        return await module.playVoiceReply(buffer, localGain: Float(attachment.meetingVolume))
    }

    func setVoiceReplyMonitorGain(for attachment: MeetingAudioAttachment) {
        guard attachments[attachment.meetingID] === attachment, talkMeetingID == attachment.meetingID else { return }
        module?.setVoiceReplyMonitorGain(attachment.soundOn ? Float(attachment.meetingVolume) : 0)
    }

    func hasParticipationVoiceGraph(for attachment: MeetingAudioAttachment) -> Bool {
        attachments[attachment.meetingID] === attachment && module?.hasParticipationVoiceGraph == true
    }

    func participationVoiceGateClosed(for attachment: MeetingAudioAttachment) -> Bool {
        talkMeetingID == attachment.meetingID && attachments[attachment.meetingID] === attachment
            && module?.participationVoiceGateClosed == true
    }

    func setParticipationSenderMuted(_ muted: Bool, for attachment: MeetingAudioAttachment,
                                    permit: GuestAutonomousVoicePlayback) async -> Bool {
        let epoch = talkEpoch
        if muted, participationSender === permit { attachment.disableSenders() }
        return await work.run { [self] in
            guard let module, attachments[attachment.meetingID] === attachment,
                  talkMeetingID == attachment.meetingID, talkEpoch == epoch else {
                return muted && !attachment.anySenderEnabled
            }
            if muted {
                guard !talkUnmuted, participationSender == nil || participationSender === permit else { return false }
                attachment.disableSenders()
                participationSender = nil
                return await muteModuleLocked(module)
            }
            guard permit.canStart, !talkUnmuted, participationSender == nil, !rebuilding, !privateCheckActive,
                  !cleanupFailed, module.participationVoiceGateClosed,
                  attachments.values.allSatisfy({ !$0.anySenderEnabled }) else { return false }
            participationSender = permit
            muteConfirmed = false
            guard await module.setMicrophoneMuted(false, timeout: timeouts.mute),
                  permit.canStart, !rebuilding, module.participationVoiceGateClosed else {
                participationSender = nil
                _ = await muteModuleLocked(module)
                return false
            }
            moduleMuted = false
            attachment.enableSenders()
            return true
        }
    }

    func playParticipationVoice(_ buffer: AVAudioPCMBuffer, for attachment: MeetingAudioAttachment,
                                permit: GuestAutonomousVoicePlayback, canStart: @escaping @MainActor () -> Bool,
                                localGain: @escaping @MainActor () -> Float?,
                                onStarted: @escaping @MainActor () -> Void) async -> GuestAutonomousVoicePlayback.Outcome {
        let epoch = talkEpoch
        guard let module, participationPlayback == nil, permitsParticipationVoice(attachment, epoch: epoch, permit: permit) else {
            return .notStarted
        }
        participationPlayback = permit
        defer { if participationPlayback === permit { participationPlayback = nil } }
        return await module.playParticipationVoice(buffer, permit: permit, canStart: {
            self.participationPlayback === permit && self.permitsParticipationVoice(attachment, epoch: epoch, permit: permit) && canStart()
        }, localGain: localGain, onStarted: onStarted)
    }

    private func permitsParticipationVoice(_ attachment: MeetingAudioAttachment, epoch: UInt64,
                                           permit: GuestAutonomousVoicePlayback) -> Bool {
        attachments[attachment.meetingID] === attachment && talkMeetingID == attachment.meetingID && talkEpoch == epoch
            && (talkUnmuted || participationSender === permit) && !moduleMuted && !muteConfirmed
            && attachment.anySenderEnabled && !rebuilding && !privateCheckActive
            && attachments.values.allSatisfy { $0 === attachment || !$0.anySenderEnabled }
    }

    private func cancelParticipationVoice() {
        participationPlayback?.cancel()
        participationSender?.cancel()
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
        muteConfirmed = false
        guard await module.setMicrophoneMuted(false, timeout: timeouts.mute) else {
            attachment.disableSenders(); module.suppressMicrophone(); moduleMuted = true
            return false
        }
        moduleMuted = false
        rebuilding = false
        return true
    }

    private func muteEverythingLocked() async -> Bool {
        cancelParticipationVoice()
        participationSender = nil
        for attachment in attachments.values { attachment.disableSenders() }
        guard let module else { return true }
        return await muteModuleLocked(module)
    }

    private func muteModuleLocked(_ module: SharedAudioModule) async -> Bool {
        moduleMuted = true
        guard await module.setMicrophoneMuted(true, timeout: timeouts.mute) else {
            muteConfirmed = false
            module.suppressMicrophone(); return false
        }
        muteConfirmed = true
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
            if installIntoLiveKitOnCreate, !pinnedForProcess {
                _ = installIntoLiveKit()
            }
            return .success(created)
        } catch {
            return .failure(error)
        }
    }

    private func retireIdleLocked() async -> Bool {
        guard attachments.isEmpty, !privateCheckActive else { return true }
        guard let module else { foregroundPrepared = false; rebuilding = false; return true }
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
            let outputApplied = await applyOutputLocked()
            if outputApplied && success { rebuilding = false }
            return outputApplied && success
        }
        foregroundPrepared = false
        let stopped = await module.shutdown(timeout: timeouts.shutdown)
        self.module = nil
        playoutOn = false; transcriptionOutputOn = false; moduleMuted = true; muteConfirmed = false; privateCheckActive = false
        if stopped { rebuilding = false } else { quarantine() }
        return stopped
    }

    private func releaseTalkLocked(keepForegroundWarm: Bool = false) async -> Bool {
        let muted = await muteEverythingLocked()
        talkUnmuted = false
        talkMeetingID = nil; exclusiveTalkMeetingID = nil; talkEpoch &+= 1
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
@MainActor public final class MeetingAudioAttachment {
    public let meetingID: UUID
    private weak var engine: SharedAudioEngine?
    private var senders: [ObjectIdentifier: MeetingAudioSender] = [:]
    private var received: [String: (setVolume: (Double) -> Void, participant: Double)] = [:]
    public private(set) var detached = false
    public private(set) var soundOn = false
    public private(set) var transcriptionOutput = false
    public private(set) var meetingVolume: Double = 1
    private let inputSink = SharedAudioSinkBox()

    fileprivate init(meetingID: UUID, engine: SharedAudioEngine) {
        self.meetingID = meetingID; self.engine = engine
    }

    public var factory: LKRTCPeerConnectionFactory? { engine?.factory }
    public var isTalk: Bool { engine?.talkMeetingID == meetingID }
    /// The epoch to pass when unmuting; refreshed each time the talk role arrives.
    public var talkEpoch: UInt64? { isTalk ? engine?.talkEpoch : nil }
    public var anySenderEnabled: Bool { senders.values.contains { $0.isEnabled } }
    /// Last completed wrapper operation, not observed SDK state or remote media.
    public private(set) var lastSenderCommand = "none"
    public var registeredSenderCount: Int { senders.count }

    // Senders: registered disabled; only the engine enables them.
    public func addSender(_ sender: MeetingAudioSender) {
        sender.isEnabled = false
        lastSenderCommand = "register-disabled"
        guard !detached else { return }
        senders[ObjectIdentifier(sender)] = sender
    }
    public func removeSender(_ sender: MeetingAudioSender) {
        sender.isEnabled = false
        senders[ObjectIdentifier(sender)] = nil
        lastSenderCommand = "remove-disabled"
    }
    /// A finished connection attempt: its tracks are off and forgotten.
    public func removeAllSenders() { disableSenders(); senders.removeAll(); lastSenderCommand = "remove-all" }
    /// Privacy barrier: senders off now, the module mute follows in order.
    public func suppress() {
        disableSenders()
        Task { await setMuted(true) }
    }
    public var moduleMuted: Bool { engine?.moduleMuted ?? true }
    public var privateCheckActive: Bool { engine?.privateCheckActive ?? false }

    // Received tracks: volume = meeting volume × participant volume, 0 with sound off.
    public func addReceived(id: String, participantVolume: Double = 1, setVolume: @escaping (Double) -> Void) {
        guard !detached else { setVolume(0); return }
        received[id] = (setVolume, participantVolume)
        setVolume(effectiveVolume(participantVolume))
    }
    public func removeReceived(id: String) { received[id] = nil }
    public func removeAllReceived() { received.removeAll() }
    public func setParticipantVolume(_ volume: Double, id: String) {
        guard var entry = received[id] else { return }
        entry.participant = Self.clamp(volume); received[id] = entry
        entry.setVolume(effectiveVolume(entry.participant))
    }
    public func setMeetingVolume(_ volume: Double) {
        meetingVolume = Self.clamp(volume); applyReceivedVolumes()
        engine?.setVoiceReplyMonitorGain(for: self)
    }
    @discardableResult public func setSound(_ on: Bool) async -> Bool {
        soundOn = on && !detached
        engine?.setVoiceReplyMonitorGain(for: self)
        return await engine?.outputChanged() ?? !on
    }
    @discardableResult public func setTranscriptionOutput(_ keep: Bool) async -> Bool {
        transcriptionOutput = keep && !detached
        return await engine?.outputChanged() ?? !keep
    }

    /// Your microphone's buffers while this meeting has the talk role (audio thread;
    /// copy and return). Whether the meeting is unmuted is the caller's gate.
    public func setInputTranscriptionSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) { inputSink.set(sink) }
    fileprivate var inputSinkHandler: (AVAudioPCMBuffer) -> Void { { [inputSink] in inputSink.deliver($0) } }

    // Talk and mute go through the engine's serial order.
    @discardableResult public func assumeTalk() async -> Bool { await engine?.assignTalk(to: self) ?? false }
    @discardableResult public func assumeTalkExclusively() async -> Bool { await engine?.assignTalk(to: self, exclusively: true) ?? false }
    @discardableResult public func relinquishTalk() async -> Bool { await engine?.releaseTalk(from: self) ?? true }
    @discardableResult public func setMuted(_ muted: Bool, epoch: UInt64? = nil) async -> Bool {
        guard let engine else { if muted { disableSenders() }; return muted }
        return await engine.setMuted(muted, for: self, epoch: epoch ?? talkEpoch ?? .max)
    }
    public func setMicrophoneGate(open: Bool) -> Bool { engine?.setMicrophoneGate(open: open, for: self) ?? false }
    public func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool { await engine?.playVoiceReply(buffer, for: self) ?? false }
    public var hasParticipationVoiceGraph: Bool { engine?.hasParticipationVoiceGraph(for: self) == true }
    public var participationVoiceGateClosed: Bool { engine?.participationVoiceGateClosed(for: self) == true }
    public func setParticipationSenderMuted(_ muted: Bool, permit: GuestAutonomousVoicePlayback) async -> Bool {
        await engine?.setParticipationSenderMuted(muted, for: self, permit: permit) ?? false
    }
    public func playParticipationVoice(_ buffer: AVAudioPCMBuffer, permit: GuestAutonomousVoicePlayback,
                                canStart: @escaping @MainActor () -> Bool, localGain: @escaping @MainActor () -> Float?,
                                onStarted: @escaping @MainActor () -> Void) async -> GuestAutonomousVoicePlayback.Outcome {
        await engine?.playParticipationVoice(buffer, for: self, permit: permit, canStart: canStart,
                                             localGain: localGain, onStarted: onStarted) ?? .notStarted
    }
    @discardableResult public func detach() async -> Bool { await engine?.detach(self) ?? true }

    fileprivate func enableSenders() {
        for sender in senders.values { sender.isEnabled = true }
        lastSenderCommand = "enable-all"
    }
    fileprivate func disableSenders() {
        for sender in senders.values { sender.isEnabled = false }
        lastSenderCommand = "disable-all"
    }
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
