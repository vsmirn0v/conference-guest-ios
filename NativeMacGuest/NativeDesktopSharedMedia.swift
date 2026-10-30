import AppKit
import AVFoundation
import Combine
import Foundation
import LiveKitWebRTC

/// The service's hardware contract also permits deterministic lifecycle tests.
protocol NativeDesktopSharedAudioOwner: AnyObject {
    var profile: GuestAudioProfile { get }
    var startupAudioObservation: GuestStartupAudioObservation { get }
    var microphoneMutedForReadiness: Bool { get }
    func prepareIdleInput(timeout: TimeInterval) async -> Bool
    func resetForRoom(playout: Bool, preparedInput: Bool) async -> Bool
    func refreshSnapshot(timeout: TimeInterval) async -> Bool
    func shutdown(timeout: TimeInterval) async -> Bool
}
extension GuestSystemAudio: NativeDesktopSharedAudioOwner {
    var microphoneMutedForReadiness: Bool { snapshot["microphoneMuted"] as? Bool == true }
}

/// One factory/ADM, one room. A room keeps its reservation across recovery;
/// attempt cleanup detaches audio but cannot release that reservation.
@MainActor final class NativeDesktopSharedMedia<Audio: NativeDesktopSharedAudioOwner> {
    struct Room: Equatable { fileprivate let id = UUID() }
    struct Suspension: Hashable { fileprivate let id = UUID() }
    private enum Reservation: Equatable { case room(Room), suspended(Suspension) }
    private let create: (GuestAudioProfile) async throws -> Audio
    private let authorized: () -> Bool
    private let clock: () -> TimeInterval
    private let sleep: (Duration) async throws -> Void
    private let grace: Duration
    private var owner: Audio?
    private var ownerID: UUID?
    private var reservation: Reservation?
    /// Claims by additional simultaneous meetings that own separate audio.
    private var alongside = Set<Suspension>()
    private var attachedAttempt: UUID?
    private var tail: Task<Bool, Never>?
    private var idleDeadline: Task<Void, Never>?
    private var revision = UUID()
    private var foreground = false
    private var microphone = false
    private var profile = GuestAudioProfile.speech
    private var stability = GuestStartupAudioStability()
    private var stopped = false
    private(set) var cleanupFailed = false
    private var preparing = false
    private var adopted = false
#if DEBUG
    var audioOwnerForTesting: Audio? { owner }
    private var foregroundInputPreparation: [String: Any] = [:]
    private var preparationObservations: [[String: Any]] = []
    private var preparationObservationCount = 0
    private func beginPreparationEvidence(_ owner: Audio, token: UUID, deadline: TimeInterval) {
        foregroundInputPreparation = ["id": UUID().uuidString, "ownerID": ownerID?.uuidString ?? "",
            "profile": owner.profile.rawValue, "revision": token.uuidString, "startedUptime": deadline - 8,
            "deadlineUptime": deadline, "factoryCreationIncluded": false, "state": "preparing"]
        preparationObservations = []; preparationObservationCount = 0
        recordPreparationEvidence(owner, phase: "beforeNativeStart")
    }
    /// Cached witnesses only. Recording must never advance the stability observer
    /// or call a native getter; failure history survives owner retirement.
    private func recordPreparationEvidence(_ owner: Audio, phase: String, state: String? = nil,
                                          reason: String? = nil, nativeSucceeded: Bool? = nil) {
        let time = clock()
        var sample: [String: Any] = ["uptime": time, "phase": phase,
            "microphoneMuted": owner.microphoneMutedForReadiness, "audio": owner.startupAudioObservation.evidence,
            "stability": stability.evidence(at: time), "foreground": foreground, "microphoneEligible": microphone,
            "stopped": stopped, "revision": revision.uuidString, "ownerProfile": owner.profile.rawValue]
        if let nativeSucceeded { sample["nativeSucceeded"] = nativeSucceeded }
        preparationObservationCount += 1; sample["sequence"] = preparationObservationCount
        if phase == "beforeNativeStart" { foregroundInputPreparation["initialObservation"] = sample }
        if phase == "nativeStartCompleted" { foregroundInputPreparation["nativeStartCompletedObservation"] = sample }
        preparationObservations.append(sample)
        if preparationObservations.count > 20 { preparationObservations.removeFirst(preparationObservations.count - 20) }
        foregroundInputPreparation["currentUptime"] = time
        if let state { foregroundInputPreparation["state"] = state; foregroundInputPreparation["completedUptime"] = time }
        if let reason { foregroundInputPreparation["reason"] = reason }
    }
    var foregroundInputPreparationForTesting: [String: Any] {
        var value = foregroundInputPreparation
        value["observations"] = preparationObservations
        value["totalObservations"] = preparationObservationCount
        value["droppedObservations"] = preparationObservationCount - preparationObservations.count
        return value
    }
#endif

    init(grace: Duration = .seconds(2), authorized: @escaping () -> Bool,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         create: @escaping (GuestAudioProfile) async throws -> Audio) {
        self.grace = grace; self.authorized = authorized; self.clock = clock; self.sleep = sleep; self.create = create
    }
    var foregroundActive: Bool { foreground && !stopped }
    var busy: Bool { reservation != nil || cleanupFailed || !alongside.isEmpty }
    var evidence: [String: Any] {
        var value: [String: Any] = ["foreground": foreground, "microphoneEligible": microphone,
            "roomReserved": reservation.map { if case .room = $0 { return true }; return false } ?? false,
            "suspended": reservation.map { if case .suspended = $0 { return true }; return false } ?? false,
            "preparing": preparing, "cleanupFailed": cleanupFailed, "adopted": adopted,
            "microphoneMuted": owner?.microphoneMutedForReadiness ?? false,
            "ready": inputReady, "ownerID": ownerID?.uuidString ?? "", "profile": owner?.profile.rawValue ?? ""]
#if DEBUG
        value["audio"] = owner?.startupAudioObservation.evidence ?? [:]
        value["foregroundInputPreparation"] = foregroundInputPreparationForTesting
#endif
        return value
    }
    private var inputReady: Bool {
        guard let owner, owner.profile == profile, authorized() else { return false }
        guard owner.microphoneMutedForReadiness else { stability = .init(); return false }
        return stability.observe(owner.startupAudioObservation, input: true, output: false, at: clock())
    }
    private func enqueue(_ action: @escaping @MainActor () async -> Bool) -> Task<Bool, Never> {
        let previous = tail
        let task = Task { @MainActor in
            _ = await previous?.value
            return await action()
        }
        tail = task; return task
    }
    /// Updates idle policy only. A live room's current graph/intent is untouched.
    func setForeground(_ active: Bool, microphone: Bool, profile: GuestAudioProfile) {
        guard !stopped, foreground != active || self.microphone != microphone || self.profile != profile else { return }
        foreground = active; self.microphone = microphone; self.profile = profile
        revision = UUID(); idleDeadline?.cancel(); idleDeadline = nil
        guard reservation == nil, alongside.isEmpty else { return }
        if active { schedulePreparation() }
        else {
            let token = revision
            idleDeadline = Task { [weak self, sleep, grace] in
                do { try await sleep(grace) } catch { return }
                guard let self, revision == token, !foreground, reservation == nil else { return }
                _ = await enqueue {
                    guard self.revision == token, !self.foreground, self.reservation == nil else { return true }
                    return await self.retireOwner()
                }.value
            }
        }
    }
    private func schedulePreparation() {
        guard foreground, reservation == nil, alongside.isEmpty, !stopped, !cleanupFailed else { return }
        let token = revision
        _ = enqueue { [self] in
            guard revision == token, foreground, reservation == nil, alongside.isEmpty, !stopped, !cleanupFailed else { return true }
            preparing = true; defer { preparing = false }
            do {
                try await ensureOwner(profile)
                // Allocation may finish after an app/policy change. Never start
                // physical input from an obsolete foreground request.
                guard revision == token, foreground, reservation == nil, !stopped else { return true }
                guard let owner else { return false }
                if microphone && authorized() {
                    // Start and physical stabilization share the existing input
                    // budget. A fast start leaves its time for native rebuilds;
                    // a slow start cannot add a second validation allowance.
                    let deadline = clock() + 8
                    let remaining = deadline - clock()
#if DEBUG
                    beginPreparationEvidence(owner, token: token, deadline: deadline)
#endif
                    guard remaining > 0 else {
#if DEBUG
                        recordPreparationEvidence(owner, phase: "nativeStart", state: "failed", reason: "deadlineBeforeStart")
#endif
                        return await retireOwner()
                    }
                    let prepared = await owner.prepareIdleInput(timeout: remaining)
#if DEBUG
                    recordPreparationEvidence(owner, phase: "nativeStartCompleted", state: prepared ? nil : "failed",
                        reason: prepared ? nil : "nativePreparationFailed", nativeSucceeded: prepared)
#endif
                    guard prepared, await validateInput(owner, token: token, deadline: deadline) else {
                        return await retireOwner()
                    }
                } else {
                    stability = .init()
                    guard await owner.resetForRoom(playout: false, preparedInput: false), owner.microphoneMutedForReadiness else { return fail() }
                }
                return true
            } catch { return await retireOwner() }
        }
    }
    private func ensureOwner(_ profile: GuestAudioProfile) async throws {
        guard !cleanupFailed else { throw NativeDesktopRTCError.cleanupFailed }
        if let owner, owner.profile != profile {
            guard await retireOwner() else { throw NativeDesktopRTCError.cleanupFailed }
        }
        if owner == nil {
            owner = try await create(profile); ownerID = UUID(); stability = .init()
        }
    }
    private func validateInput(_ owner: Audio, token: UUID, deadline: TimeInterval) async -> Bool {
        stability = .init()
        while clock() < deadline {
            if revision != token || !foreground || !microphone || !authorized() || stopped {
#if DEBUG
                recordPreparationEvidence(owner, phase: "validation", state: "superseded", reason: "eligibilityWithdrawn")
#endif
                return true
            }
            let remaining = deadline - clock()
            guard remaining > 0 else {
#if DEBUG
                recordPreparationEvidence(owner, phase: "validation", state: "failed", reason: "deadlineBeforeRead")
#endif
                return false
            }
            let refreshed = await owner.refreshSnapshot(timeout: remaining)
            guard refreshed, clock() < deadline else {
#if DEBUG
                recordPreparationEvidence(owner, phase: "nativeReadCompleted", state: "failed",
                    reason: refreshed ? "deadlineAfterRead" : "nativeReadFailed", nativeSucceeded: refreshed)
#endif
                return false
            }
            guard owner.microphoneMutedForReadiness else {
#if DEBUG
                recordPreparationEvidence(owner, phase: "validation", state: "failed", reason: "microphoneNotMuted")
#endif
                stability = .init(); return false
            }
            let ready = inputReady
#if DEBUG
            recordPreparationEvidence(owner, phase: "validation", state: ready ? "ready" : nil)
#endif
            if ready { return true }
            do { try await sleep(.milliseconds(50)) } catch {
#if DEBUG
                recordPreparationEvidence(owner, phase: "validation", state: "failed", reason: "sleepCancelled")
#endif
                return false
            }
        }
#if DEBUG
        recordPreparationEvidence(owner, phase: "validation", state: "failed", reason: "validationDeadline")
#endif
        return false
    }
    func reserveRoom(profile: GuestAudioProfile) async throws -> Room {
        guard !stopped, !cleanupFailed, reservation == nil, alongside.isEmpty else { throw GuestSystemAudioError.physicalOwnerBusy }
        let room = Room(); reservation = .room(room); revision = UUID(); idleDeadline?.cancel()
        let task = enqueue { [self] in
            do { try await ensureOwner(profile); return true } catch { return false }
        }
        guard await task.value, !cleanupFailed else { reservation = nil; throw NativeDesktopRTCError.cleanupFailed }
        if Task.isCancelled { _ = await releaseRoom(room, clean: true); throw CancellationError() }
        return room
    }
    func attach(_ room: Room, attempt: UUID, playout: Bool, preparedInput: Bool) async throws -> Audio {
        guard reservation == .room(room), attachedAttempt == nil, !cleanupFailed else { throw NativeDesktopRTCError.cleanupFailed }
        attachedAttempt = attempt
        let task = enqueue { [self] in
            guard reservation == .room(room), attachedAttempt == attempt, let owner, !cleanupFailed else { return false }
            adopted = preparedInput && inputReady
            // An existing prepared graph can be retained; a cold input is
            // activated later by GuestSession under its bounded startup policy.
            let clean = await owner.resetForRoom(playout: playout, preparedInput: preparedInput && authorized()) && owner.microphoneMutedForReadiness
            return clean || fail()
        }
        guard await task.value, let owner else { throw NativeDesktopRTCError.cleanupFailed }
        return owner
    }
    func detach(_ room: Room, attempt: UUID, clean: Bool) async -> Bool {
        guard reservation == .room(room), attachedAttempt == attempt else { return !cleanupFailed }
        return await enqueue { [self] in
            guard reservation == .room(room), attachedAttempt == attempt else { return !cleanupFailed }
            guard clean, let owner else { return fail() }
            // Keep the room's current input availability through recovery.
            // Its sender/peers are already gone and the mixer is muted here.
            let keepInput = owner.startupAudioObservation.topology.inputAvailable
            guard await owner.resetForRoom(playout: false, preparedInput: keepInput), owner.microphoneMutedForReadiness else { return fail() }
            attachedAttempt = nil; stability = .init(); return true
        }.value
    }
    func releaseRoom(_ room: Room, clean: Bool) async -> Bool {
        guard reservation == .room(room) else { return !cleanupFailed }
        let result = await enqueue { [self] in
            guard reservation == .room(room) else { return !cleanupFailed }
            guard clean, attachedAttempt == nil, !cleanupFailed else { return fail() }
            // Hold the room's exclusion until a required retirement has
            // finished. Its completion cannot retire a subsequently claimed room.
            if !foreground || stopped || !alongside.isEmpty {
                guard await retireOwner() else { return false }
            }
            reservation = nil; adopted = false
            return true
        }.value
        if result {
            if foreground && !stopped { schedulePreparation() }
        }
        return result && !cleanupFailed
    }
    /// Holds exclusion while another backend/private check owns physical media.
    func suspendIfDrained() -> Suspension? {
        guard !stopped, !cleanupFailed, owner == nil, !preparing, reservation == nil, alongside.isEmpty else { return nil }
        let token = Suspension(); reservation = .suspended(token); revision = UUID(); idleDeadline?.cancel()
        return token
    }
    func suspend() async throws -> Suspension {
        guard !stopped, !cleanupFailed, reservation == nil, alongside.isEmpty else { throw GuestSystemAudioError.physicalOwnerBusy }
        let token = Suspension(); reservation = .suspended(token); revision = UUID(); idleDeadline?.cancel()
        guard await enqueue({ await self.retireOwner() }).value else { throw NativeDesktopRTCError.cleanupFailed }
        if Task.isCancelled { resume(token, clean: true); throw CancellationError() }
        return token
    }
    /// A concurrent meeting owns separate audio. The shared owner neither prepares idle
    /// input nor admits a new room while any such claim exists; a live room continues.
    func suspendAlongside() async throws -> Suspension {
        guard !stopped, !cleanupFailed else { throw GuestSystemAudioError.physicalOwnerBusy }
        let token = Suspension(); alongside.insert(token); revision = UUID(); idleDeadline?.cancel()
        if reservation == nil {
            guard await enqueue({ self.reservation != nil ? true : await self.retireOwner() }).value else {
                alongside.remove(token); throw NativeDesktopRTCError.cleanupFailed
            }
        }
        if Task.isCancelled { resume(token, clean: true); throw CancellationError() }
        return token
    }
    func resume(_ token: Suspension, clean: Bool) {
        if alongside.remove(token) != nil {
            guard clean else { _ = fail(); return }
            if alongside.isEmpty, reservation == nil, foreground, !stopped { schedulePreparation() }
            return
        }
        guard reservation == .suspended(token) else { return }
        guard clean else { _ = fail(); return }
        reservation = nil
        if foreground && !stopped { schedulePreparation() }
    }
    func shutdown() async -> Bool {
        stopped = true; foreground = false; revision = UUID(); idleDeadline?.cancel(); idleDeadline = nil
        guard reservation == nil, alongside.isEmpty else { return false }
        return await enqueue { await self.retireOwner() }.value
    }
    private func fail() -> Bool { cleanupFailed = true; return false }
    private func retireOwner() async -> Bool {
        guard !cleanupFailed else { return false }
        guard let owner else { return true }
        guard await owner.shutdown(timeout: 3) else { return fail() }
        self.owner = nil; ownerID = nil; stability = .init(); return true
    }
    func waitForWork() async { _ = await tail?.value }
}

@MainActor enum NativeDesktopMediaService {
    static let shared = NativeDesktopSharedMedia<GuestSystemAudio>(
        authorized: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
        create: { profile in
            _ = LKRTCInitializeSSL()
            return try await GuestSystemAudio.create(microphoneEnabled: false, playoutEnabled: false,
                profile: profile, exclusive: true)
        })
    /// A separate room service for an additional simultaneous Guest meeting. It is
    /// never foregrounded, so its owner retires with the room and never idles input.
    static func makeConcurrentGuestMedia() -> NativeDesktopSharedMedia<GuestSystemAudio> {
        .init(authorized: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
            create: { profile in
                _ = LKRTCInitializeSSL()
                return try await GuestSystemAudio.create(microphoneEnabled: false, playoutEnabled: false,
                    profile: profile, concurrent: true)
            })
    }
}

/// App activity AND a visible window are required. Menu-bar residency alone
/// cannot start sensors. Camera metadata has no capture and retains its barrier.
@MainActor final class NativeDesktopForegroundMedia {
    static let shared = NativeDesktopForegroundMedia()
    private let power = NativeDesktopPowerMonitor()
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    private var stopped = false
    private var metadata: Task<Void, Never>?
    private var updateSuspension: (id: UUID, token: NativeDesktopSharedMedia<GuestSystemAudio>.Suspension)?
    private weak var homeWindow: NSWindow?
    private var foregroundWindowVisible: Bool { NSApp.isActive && homeWindow?.isVisible == true && homeWindow?.isMiniaturized == false }
    func setHomeWindow(_ window: NSWindow) {
        homeWindow = window
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
    func start() {
        guard !started else { return }; started = true
        power.start { [weak self] in self?.refresh() }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.willCloseNotification, UserDefaults.didChangeNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                // Visibility notifications can precede the actual state change.
                DispatchQueue.main.async { self?.refresh() }
            }.store(in: &subscriptions)
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in NativeDesktopCameraMetadataPreparation.shared.invalidate(); self?.refresh() }
            }.store(in: &subscriptions)
        }
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
    func refresh() {
        guard !stopped else { return }
        let foreground = foregroundWindowVisible
        let policy = NativeDesktopJoinReadinessPolicy.current(), state = power.snapshot
        NativeDesktopMediaService.shared.setForeground(foreground, microphone: policy.microphone.allows(state), profile: .saved)
        guard foreground, !NativeDesktopMediaService.shared.busy, policy.camera.allows(state), metadata == nil else { return }
        metadata = Task { [weak self] in
            defer { self?.metadata = nil }
            _ = try? await NativeDesktopCameraMetadataPreparation.shared.prepare(eligible: {
                self?.stopped == false && !NativeDesktopMediaService.shared.busy && self?.foregroundWindowVisible == true &&
                    NativeDesktopJoinReadinessPolicy.current().camera.allows(self?.power.snapshot ?? state)
            }, deviceID: UserDefaults.standard.string(forKey: "nativeDesktop.cameraID"))
        }
    }
    func shutdown() async -> Bool {
        stopped = true; subscriptions.removeAll(); power.stop(); metadata?.cancel()
        if let value = updateSuspension {
            NativeDesktopMediaService.shared.resume(value.token, clean: true); updateSuspension = nil
        }
        return await NativeDesktopMediaService.shared.shutdown()
    }
    func prepareForUpdate(_ id: UUID) async -> Bool {
        if let value = updateSuspension { return value.id == id }
        do { updateSuspension = (id, try await NativeDesktopMediaService.shared.suspend()); return true }
        catch { return false }
    }
    func prepareForUpdateIfDrained(_ id: UUID) -> Bool {
        if let value = updateSuspension { return value.id == id }
        guard let token = NativeDesktopMediaService.shared.suspendIfDrained() else { return false }
        updateSuspension = (id, token); return true
    }
    func cancelUpdatePreparation(_ id: UUID) {
        if let value = updateSuspension, value.id == id {
            NativeDesktopMediaService.shared.resume(value.token, clean: true); updateSuspension = nil
        }
    }
}
