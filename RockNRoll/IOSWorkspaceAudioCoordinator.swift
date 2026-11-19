import AVFoundation
import CallKit
import Combine
import Foundation
import LiveKit
import LiveKitWebRTC
import MeetingEngine
import UIKit

@MainActor
protocol WorkspaceAudioControllableSession: AnyObject {
    var id: UUID { get }
    var appliedAudioState: (microphoneOn: Bool, playoutOn: Bool) { get }
    func setMicrophone(_ enabled: Bool) async throws
    func setPlayout(_ enabled: Bool) async throws
    func setPhysicalInputPermitted(_ permitted: Bool, keepDeviceWarm: Bool) async -> Bool
    func prepareAudioMuteIntent()
}

extension MeetingSession: WorkspaceAudioControllableSession {
    var appliedAudioState: (microphoneOn: Bool, playoutOn: Bool) {
        (appliedMediaIntent.microphoneOn, appliedMediaIntent.playoutOn ?? true)
    }

    func prepareAudioMuteIntent() {
        prepareLocalMuteIntent(audioMuted: true, videoMuted: nil)
    }
}

/// Owns iOS's single aggregate AVAudioSession + CallKit lease (`0 -> 1 -> N (<= 4) -> 1 -> 0`),
/// exclusive talk handover, synchronous capture-gate muting, and aggregate hold/interruption recovery.
@MainActor
final class IOSWorkspaceAudioCoordinator: ObservableObject {
    static let maxConcurrentSessions = 4

    struct CaptureGate: Sendable {
        var setMuted: @Sendable (Bool) -> Void
        var state: @Sendable () -> UInt64
        var unmuteIfState: @Sendable (UInt64) -> Bool

        static let live = Self(
            setMuted: { LKRTCSetApplicationCaptureMuted($0 ? 1 : 0) },
            state: { LKRTCApplicationCaptureState() },
            unmuteIfState: { LKRTCUnmuteApplicationCaptureIfState($0) }
        )
    }

    private struct SessionEntry {
        let session: any WorkspaceAudioControllableSession
        var title: String
        var connected: Bool
        var soundEnabled: Bool
        var hasAudibleVolume: Bool
        var playoutTask: Task<Void, Error>?
        var playoutRequestID: UUID?
    }

    private static var configuredLiveKitAudio = false

    static func configureLiveKitAudioOnce(sharedAudio: SharedAudioEngine = .shared) {
        if !configuredLiveKitAudio {
            configuredLiveKitAudio = true
            AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        }
        if sharedAudio.hasModule {
            _ = sharedAudio.installIntoLiveKit()
        }
    }

    @Published private(set) var talkSessionID: UUID?
    @Published private(set) var activeSessionCount = 0
    @Published private(set) var isHeld = false
    @Published private(set) var isMuted = true
    @Published private(set) var audioOutput: AudioCoordinator.Output

    let systemCall: SystemCallCoordinator
    let audio: AudioCoordinator

    var onCallStateChanged: (() -> Void)?
    var onAudioInterruptedOrHeld: ((Bool) -> Void)?
    var onSystemEndedAll: (() -> Void)?
    var onStatus: ((String?) -> Void)?
    var onFailure: ((Error) -> Void)?

    private struct ActivationWaiter {
        let sessionID: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let captureGate: CaptureGate
    private let notifyEngineRouteChanged: @MainActor () -> Void
    private var entries: [UUID: SessionEntry] = [:]
    private var sessionOrder: [UUID] = []
    private var preferredForegroundSessionID: UUID?
    private var pausedAllAudioForHoldOrYield = false
    private var talkSwitchRevision: UInt64 = 0
    private var activeLeaseStartCount = 0
    private var isAudioActivated = false
    private var initialLeaseError: Error?
    private var activationWaiters: [UUID: ActivationWaiter] = [:]
    #if DEBUG
    private var leaseReadyWaiters: [CheckedContinuation<Void, Never>] = []
    #endif

    init(systemCall: SystemCallCoordinator? = nil,
         audio: AudioCoordinator? = nil,
         captureGate: CaptureGate = .live,
         sharedAudio: SharedAudioEngine? = .shared,
         configureLiveKit: Bool = true,
         notifications: NotificationCenter = .default) {
        if configureLiveKit, let sharedAudio {
            Self.configureLiveKitAudioOnce(sharedAudio: sharedAudio)
        }
        self.systemCall = systemCall ?? SystemCallCoordinator()
        self.audio = audio ?? AudioCoordinator(notifications: notifications)
        self.captureGate = captureGate
        self.notifyEngineRouteChanged = {
            if let sharedAudio { _ = sharedAudio.engineChanged(.started) }
        }
        self.audioOutput = self.audio.output
        installHandlers()
    }

    var canRestoreAudio: Bool { systemCall.canRestoreAudio }
    var isAwaitingAudioRecovery: Bool { systemCall.isAwaitingAudioRecovery }
    var hasRegisteredSystemCall: Bool { systemCall.hasRegisteredSystemCall }
    var hasCompetingCall: Bool { systemCall.hasCompetingCall }

    func isTalkSession(_ id: UUID) -> Bool { talkSessionID == id }

    func setPreferredForegroundSession(_ id: UUID?) {
        preferredForegroundSessionID = id
    }

    func registerSession(_ session: any WorkspaceAudioControllableSession, title: String, backgroundJoin: Bool = false,
                         soundEnabled: Bool? = nil, hasAudibleVolume: Bool = true) {
        let cleanTitle = Self.sanitizedTitle(title)
        if var existing = entries[session.id] {
            existing.title = cleanTitle
            entries[session.id] = existing
            updateLocalizedCallTitle()
            return
        }
        guard sessionOrder.count < Self.maxConcurrentSessions else { return }
        let wasEmpty = sessionOrder.isEmpty
        entries[session.id] = SessionEntry(session: session, title: cleanTitle, connected: false,
                                           soundEnabled: soundEnabled ?? session.appliedAudioState.playoutOn,
                                           hasAudibleVolume: hasAudibleVolume)
        sessionOrder.append(session.id)
        activeSessionCount = sessionOrder.count
        updateProximityRouting()

        if wasEmpty {
            talkSessionID = session.id
            isHeld = false
            isMuted = true
            pausedAllAudioForHoldOrYield = false
            isAudioActivated = false
            initialLeaseError = nil
            captureGate.setMuted(true)
            startAggregateLease(backgroundJoin: backgroundJoin)
        } else {
            updateLocalizedCallTitle()
            if talkSessionID != session.id {
                Task { _ = await session.setPhysicalInputPermitted(false, keepDeviceWarm: true) }
            }
        }
    }

    func waitUntilAudioReady(for sessionID: UUID) async throws {
        guard entries[sessionID] != nil else { throw CancellationError() }
        if let error = initialLeaseError { throw error }
        if isAudioActivated && !isHeld { return }
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard self.entries[sessionID] != nil else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let error = self.initialLeaseError {
                    continuation.resume(throwing: error)
                    return
                }
                if self.isAudioActivated && !self.isHeld {
                    continuation.resume(returning: ())
                    return
                }
                self.activationWaiters[token] = ActivationWaiter(sessionID: sessionID, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if let removed = self?.activationWaiters.removeValue(forKey: token) {
                    removed.continuation.resume(throwing: CancellationError())
                }
            }
        }
        guard entries[sessionID] != nil, !Task.isCancelled else { throw CancellationError() }
    }

    func updateSessionTitle(id: UUID, title: String) {
        guard var entry = entries[id] else { return }
        entry.title = Self.sanitizedTitle(title)
        entries[id] = entry
        updateLocalizedCallTitle()
    }

    func markSessionConnected(id: UUID) {
        guard var entry = entries[id] else { return }
        entry.connected = true
        entries[id] = entry
        if systemCall.callID != nil {
            systemCall.markConnected()
            updateLocalizedCallTitle()
        }
    }

    func unregisterSession(id: UUID) {
        cancelActivationWaiters(for: id)
        guard let removed = entries.removeValue(forKey: id) else { return }
        removed.playoutTask?.cancel()
        updateProximityRouting()
        sessionOrder.removeAll { $0 == id }
        activeSessionCount = sessionOrder.count

        if sessionOrder.isEmpty {
            activeLeaseStartCount &+= 1
            talkSessionID = nil
            isHeld = false
            isMuted = true
            pausedAllAudioForHoldOrYield = false
            isAudioActivated = false
            initialLeaseError = nil
            resumeAllActivationWaiters(with: .failure(CancellationError()))
            #if DEBUG
            let waiters = leaseReadyWaiters
            leaseReadyWaiters.removeAll()
            waiters.forEach { $0.resume() }
            #endif
            captureGate.setMuted(true)
            audio.endSession()
            if systemCall.callID != nil { systemCall.end() }
            return
        }

        if talkSessionID == id {
            let replacementID = (preferredForegroundSessionID.flatMap { entries[$0] != nil ? $0 : nil }) ?? sessionOrder[0]
            talkSessionID = replacementID
            isMuted = true
            captureGate.setMuted(true)
            systemCall.setMuted(true)
            if let replacement = entries[replacementID]?.session {
                Task { _ = await replacement.setPhysicalInputPermitted(true, keepDeviceWarm: true) }
            }
        }
        updateLocalizedCallTitle()
    }

    func switchTalk(to sessionID: UUID) async {
        guard let nextEntry = entries[sessionID] else { return }
        if talkSessionID == sessionID {
            _ = await nextEntry.session.setPhysicalInputPermitted(true, keepDeviceWarm: true)
            updateLocalizedCallTitle()
            return
        }

        let revision = talkSwitchRevision &+ 1
        talkSwitchRevision = revision
        captureGate.setMuted(true)
        isMuted = true
        systemCall.setMuted(true)

        let previousID = talkSessionID
        talkSessionID = sessionID
        updateLocalizedCallTitle()

        if let previousID, let previous = entries[previousID]?.session {
            previous.prepareAudioMuteIntent()
            try? await previous.setMicrophone(false)
            _ = await previous.setPhysicalInputPermitted(false, keepDeviceWarm: true)
        }

        guard entries[sessionID] != nil, talkSwitchRevision == revision else { return }
        _ = await nextEntry.session.setPhysicalInputPermitted(true, keepDeviceWarm: true)
    }

    /// Immediately closes the hardware capture gate and marks outgoing audio muted before async teardown runs.
    func suppressMicrophoneImmediately(for sessionID: UUID) {
        guard talkSessionID == sessionID || talkSessionID == nil else { return }
        captureGate.setMuted(true)
        entries[sessionID]?.session.prepareAudioMuteIntent()
        isMuted = true
        systemCall.setMuted(true)
    }

    func setTalkMicrophone(_ enabled: Bool, for sessionID: UUID? = nil) async throws {
        guard let targetID = sessionID ?? talkSessionID ?? sessionOrder.first,
              let target = entries[targetID]?.session else {
            throw MeetingSessionError.notConnected
        }
        if enabled && isHeld {
            throw MeetingSessionError.unavailable(L("Cannot unmute while the call is on hold."))
        }
        if talkSessionID != targetID {
            await switchTalk(to: targetID)
            guard entries[targetID] != nil, talkSessionID == targetID else { throw CancellationError() }
        }
        if !enabled {
            captureGate.setMuted(true)
            target.prepareAudioMuteIntent()
            isMuted = true
            systemCall.setMuted(true)
            try await target.setMicrophone(false)
            return
        }

        let expectedState = captureGate.state()
        try await target.setMicrophone(true)
        guard !isHeld, entries[targetID] != nil, talkSessionID == targetID,
              captureGate.unmuteIfState(expectedState) else {
            captureGate.setMuted(true)
            target.prepareAudioMuteIntent()
            try? await target.setMicrophone(false)
            isMuted = true
            systemCall.setMuted(true)
            throw CancellationError()
        }
        isMuted = false
        systemCall.setMuted(false)
    }

    func resumeSystemCallIfPossible() {
        systemCall.resumeIfPossible()
    }

    func setTransferHeld(_ held: Bool) async throws {
        try await systemCall.setTransferHeld(held)
    }

    // MARK: - Private Aggregate Lease & CallKit Handlers

    private func startAggregateLease(backgroundJoin: Bool = false) {
        activeLeaseStartCount &+= 1
        let generation = activeLeaseStartCount
        audio.start(preserveCurrentRoute: backgroundJoin, ready: { [weak self] in
            guard let self, self.activeLeaseStartCount == generation, self.activeSessionCount > 0 else { return }
            let allowRetry = !backgroundJoin && UIApplication.shared.applicationState != .background
            self.systemCall.start(allowInitialActivationRetry: allowRetry)
            self.updateLocalizedCallTitle()
            if self.entries.values.contains(where: \.connected) {
                self.systemCall.markConnected()
            }
            #if DEBUG
            let waiters = self.leaseReadyWaiters
            self.leaseReadyWaiters.removeAll()
            waiters.forEach { $0.resume() }
            #endif
        }, failure: { [weak self] error in
            guard let self, self.activeLeaseStartCount == generation, self.activeSessionCount > 0 else { return }
            self.isAudioActivated = false
            self.initialLeaseError = error
            self.resumeAllActivationWaiters(with: .failure(error))
            #if DEBUG
            let waiters = self.leaseReadyWaiters
            self.leaseReadyWaiters.removeAll()
            waiters.forEach { $0.resume() }
            #endif
            self.onStatus?(error.localizedDescription)
            self.onFailure?(error)
        })
    }

    private func resumeAllActivationWaiters(with result: Result<Void, Error>) {
        guard !activationWaiters.isEmpty else { return }
        let waiters = activationWaiters.values
        activationWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(with: result)
        }
    }

    private func cancelActivationWaiters(for sessionID: UUID) {
        let matchingKeys = activationWaiters.compactMap { $0.value.sessionID == sessionID ? $0.key : nil }
        for key in matchingKeys {
            if let waiter = activationWaiters.removeValue(forKey: key) {
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
    }

    #if DEBUG
    func waitForAggregateLeaseForTesting() async {
        if systemCall.callID != nil || activeSessionCount == 0 { return }
        await withCheckedContinuation { leaseReadyWaiters.append($0) }
    }
    #endif

    private func updateLocalizedCallTitle() {
        guard !sessionOrder.isEmpty else { return }
        let primaryTitle: String
        if let talkSessionID, let talkEntry = entries[talkSessionID] {
            primaryTitle = talkEntry.title
        } else if let firstID = sessionOrder.first, let first = entries[firstID] {
            primaryTitle = first.title
        } else {
            primaryTitle = L("Jam")
        }
        let localized = sessionOrder.count > 1
            ? "\(primaryTitle) (+\(sessionOrder.count - 1))"
            : primaryTitle
        systemCall.updateLocalizedTitle(localized)
    }

    private func installHandlers() {
        audio.onServicesChanged = { [weak self] available in
            self?.systemCall.audioServicesChanged(available)
        }
        audio.onStatus = { [weak self] message in
            self?.onStatus?(message)
        }
        audio.onRouteChanged = { [weak self] in
            guard let self else { return }
            self.audioOutput = self.audio.output
            if self.activeSessionCount > 0 { self.notifyEngineRouteChanged() }
        }
        audio.onInterruptionChanged = { [weak self] interrupted in
            guard let self, self.activeSessionCount > 0 else { return }
            if interrupted {
                self.pauseAllSessionsForHoldOrYield()
                self.audio.preserveOutputForInterruption()
            } else {
                self.systemCall.audioSessionInterrupted(false)
                if !self.systemCall.isAwaitingAudioRecovery {
                    self.restoreAllSessionsFromHoldOrYield()
                }
            }
        }
        systemCall.onCallStateChanged = { [weak self] in
            self?.onCallStateChanged?()
        }
        systemCall.onAudioYield = { [weak self] in
            guard let self else { return }
            self.audio.suspendConfiguration()
            self.pauseAllSessionsForHoldOrYield()
        }
        systemCall.onDeactivated = { [weak self] in
            guard let self else { return }
            self.isAudioActivated = false
            self.audio.preserveOutputForInterruption()
            self.pauseAllSessionsForHoldOrYield()
            self.onAudioInterruptedOrHeld?(true)
            self.onCallStateChanged?()
        }
        systemCall.onActivated = { [weak self] in
            guard let self, self.activeSessionCount > 0 else { return }
            self.isAudioActivated = true
            self.initialLeaseError = nil
            self.audio.callAudioDidActivate()
            self.audioOutput = self.audio.output
            self.notifyEngineRouteChanged()
            if !self.isHeld {
                self.resumeAllActivationWaiters(with: .success(()))
                self.restoreAllSessionsFromHoldOrYield()
            }
            self.systemCall.resumeIfPossible()
            self.onCallStateChanged?()
        }
        systemCall.onHoldChanged = { [weak self] held in
            guard let self, self.activeSessionCount > 0 else { return }
            self.isHeld = held
            if held {
                self.audio.preserveOutputForInterruption()
                self.pauseAllSessionsForHoldOrYield()
                self.onAudioInterruptedOrHeld?(true)
            } else if self.systemCall.canRestoreAudio || !self.systemCall.hasRegisteredSystemCall {
                if self.isAudioActivated {
                    self.resumeAllActivationWaiters(with: .success(()))
                }
                self.restoreAllSessionsFromHoldOrYield()
            }
            self.onCallStateChanged?()
        }
        systemCall.onMuteChanged = { [weak self] muted in
            guard let self, self.activeSessionCount > 0 else { return }
            if muted {
                self.captureGate.setMuted(true)
                self.isMuted = true
                if let talkID = self.talkSessionID, let talk = self.entries[talkID]?.session {
                    talk.prepareAudioMuteIntent()
                }
                Task { [weak self] in try? await self?.setTalkMicrophone(false) }
            } else {
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.setTalkMicrophone(true)
                    } catch {
                        self.captureGate.setMuted(true)
                        self.isMuted = true
                        self.systemCall.setMuted(true)
                    }
                }
            }
        }
        systemCall.onEnded = { [weak self] _ in
            guard let self else { return }
            self.captureGate.setMuted(true)
            self.isMuted = true
            self.isHeld = false
            self.pausedAllAudioForHoldOrYield = false
            self.isAudioActivated = false
            self.initialLeaseError = nil
            self.resumeAllActivationWaiters(with: .failure(CancellationError()))
            self.audio.endSession()
            guard !self.sessionOrder.isEmpty else { return }
            self.entries.removeAll()
            self.sessionOrder.removeAll()
            self.activeSessionCount = 0
            self.talkSessionID = nil
            self.onSystemEndedAll?()
        }
        systemCall.onFailure = { [weak self] error in
            guard let self else { return }
            self.captureGate.setMuted(true)
            self.isMuted = true
            self.isAudioActivated = false
            self.initialLeaseError = error
            self.resumeAllActivationWaiters(with: .failure(error))
            self.audio.endSession()
            self.onFailure?(error)
        }
    }

    func setMeetingSoundEnabled(_ enabled: Bool, for id: UUID) async throws {
        guard let entry = entries[id], !pausedAllAudioForHoldOrYield else { throw CancellationError() }
        entries[id]?.soundEnabled = enabled
        do {
            try await queuePlayout(for: id)?.value
            guard entries[id] != nil else { throw CancellationError() }
            updateProximityRouting()
        } catch {
            if entries[id]?.soundEnabled == enabled {
                entries[id]?.soundEnabled = entry.soundEnabled
                // Some providers update reconnect intent before acknowledging the hardware change.
                _ = try? await queuePlayout(for: id)?.value
                updateProximityRouting()
            }
            throw error
        }
    }

    /// Serialize app and CallKit writes for each meeting so a late restore cannot reopen muted audio.
    private func queuePlayout(for id: UUID) -> Task<Void, Error>? {
        guard var entry = entries[id] else { return nil }
        let previous = entry.playoutTask
        let requestID = UUID()
        entry.playoutRequestID = requestID
        let sound = entry.soundEnabled && !pausedAllAudioForHoldOrYield
        let task = Task { @MainActor [weak self, session = entry.session] in
            _ = await previous?.result
            guard let self, entries[id]?.playoutRequestID == requestID else { return }
            defer {
                if entries[id]?.playoutRequestID == requestID { entries[id]?.playoutTask = nil }
            }
            try await session.setPlayout(sound)
        }
        entry.playoutTask = task
        entries[id] = entry
        return task
    }

    func setHasAudibleVolume(_ audible: Bool, for id: UUID) {
        guard let entry = entries[id], entry.hasAudibleVolume != audible else { return }
        entries[id]?.hasAudibleVolume = audible
        updateProximityRouting()
    }

    private func updateProximityRouting() {
        let audible = entries.values.contains { $0.soundEnabled && $0.hasAudibleVolume }
        audio.setProximityRoutingNeeded(!pausedAllAudioForHoldOrYield && audible)
    }

    private func pauseAllSessionsForHoldOrYield() {
        captureGate.setMuted(true)
        isMuted = true
        systemCall.setMuted(true)
        pausedAllAudioForHoldOrYield = true
        updateProximityRouting()
        let snapshot = sessionOrder.compactMap { entries[$0]?.session }
        for session in snapshot {
            session.prepareAudioMuteIntent()
            _ = queuePlayout(for: session.id)
        }
        Task { [snapshot] in
            for session in snapshot {
                try? await session.setMicrophone(false)
            }
        }
    }

    private func restoreAllSessionsFromHoldOrYield() {
        captureGate.setMuted(true)
        isMuted = true
        systemCall.setMuted(true)
        let shouldRestore = pausedAllAudioForHoldOrYield
        pausedAllAudioForHoldOrYield = false
        guard shouldRestore else { return }
        updateProximityRouting()
        let restored = sessionOrder.compactMap { queuePlayout(for: $0) }
        Task { @MainActor [weak self] in
            for task in restored { _ = await task.result }
            guard let self, !pausedAllAudioForHoldOrYield else { return }
            onAudioInterruptedOrHeld?(false)
        }
    }

    private static func sanitizedTitle(_ title: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? L("Jam") : clean
    }
}
