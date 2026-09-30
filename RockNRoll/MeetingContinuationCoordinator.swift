import Combine
import ConferenceCore
import Foundation

/// Cross-device coordination is independent of the media transport. Every action
/// is scoped to one source session and conditional CloudKit request revision.
@MainActor
final class MeetingContinuationCoordinator: ObservableObject {
    static weak var active: MeetingContinuationCoordinator?
    @Published private(set) var enabled: Bool
    @Published private(set) var candidates: [ActiveJam] = []
    @Published private(set) var status: String?
    @Published private(set) var moving = false
    @Published private(set) var needsManualResume = false
    var waitingForMove: Bool { moving || prepared != nil }
    var moveActionTitle: String { targetConnected ? "Keep connected here" : "Cancel move" }
    var isAvailable: Bool { enabled && account != nil }
    var onActivityChanged: (() -> Void)?
    var onPrepareSource: ((UUID) async throws -> Void)?
    var onResumeSource: ((UUID, Bool) async -> Void)?
    var onLeaveSource: ((UUID, String) async -> Bool)?
    var onJoinTarget: ((ActiveJam, Bool) -> UUID?)?
    var onCancelTarget: ((URL, UUID?) async -> Bool)?
    var onSnapshot: (() -> ActiveJam?)?
    var onStatus: ((String?, Bool) -> Void)?
    private(set) var current: ActiveJam?
    let deviceID: String
    let deviceLabel: String
    private let preferences: UserDefaults
    private let transport: any MeetingContinuationTransport
    private let automatic: Bool
    private let now: () -> Date
    private var account: String?
    private var busy = false
    private var pendingRefresh = false
    private var foreground = true
    private var tick: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?
    private var receiver: JamTransfer?
    private var prepared: JamTransfer?
    private var holdExpiry: Task<Void, Never>?
    private var revision = 0
    private var published: ActiveJam?
    private var lastPublished = Date.distantPast
    private var targetConnected = false
    private var quietDestination = false
    private var targetSession: UUID?
    private(set) var destinationInvitation: URL?
    private var hasWithdrawn = false
    private var refreshFailed = false

    init(deviceID: String, deviceLabel: String, preferences: UserDefaults = .standard,
         transport: (any MeetingContinuationTransport)? = nil, automatic: Bool = true, now: @escaping () -> Date = Date.init) {
        self.deviceID = deviceID; self.deviceLabel = deviceLabel; self.preferences = preferences
        self.transport = transport ?? MeetingContinuationCloud(); self.automatic = automatic; self.now = now
        enabled = preferences.bool(forKey: "shareActiveJams")
        Self.active = self
    }
    deinit { tick?.cancel(); transferTask?.cancel(); holdExpiry?.cancel() }
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value; preferences.set(value, forKey: "shareActiveJams")
        revision += 1; transferTask?.cancel(); transferTask = nil
        if value { transport.resetConnection(); Task { await refresh() } }
        else { stopSharing() }
        onActivityChanged?()
    }
    func setCloudAccount(_ value: String?) {
        guard account != value else { return }
        revision += 1; transferTask?.cancel(); transferTask = nil
        if account != nil { stopSharing(withdraw: false) }
        account = value; transport.resetConnection()
        onActivityChanged?()
        if value != nil && enabled { Task { await refresh() } }
    }
    private func stopSharing(withdraw: Bool = true) {
        let abandoned = targetConnected ? nil : receiver
        let invitation = destinationInvitation, targetID = targetSession
        tick?.cancel(); tick = nil; candidates = []; moving = false; receiver = nil
        let old = prepared; clearPrepared()
        if let old { Task { await onResumeSource?(old.sourceSession, false) } }
        let expected = revision
        if let abandoned { Task {
            if let invitation, let targetID, await onCancelTarget?(invitation, targetID) == false { return }
            guard withdraw, expected == revision else { return }
            _ = try? await transport.transition(abandoned, to: .cancelled, actor: deviceID)
        } }
        let session = published?.sessionID ?? current?.sessionID
        if withdraw && account != nil { Task {
            guard expected == revision else { return }
            try? await transport.withdraw(deviceID: deviceID, sessionID: session)
        } }
        published = nil; status = nil; onStatus?(nil, false)
    }
    func setForeground(_ value: Bool) {
        foreground = value
        tick?.cancel(); tick = nil
        if value { Task { await refresh() } } else { scheduleTick() }
    }
    func updateCurrent(_ jam: ActiveJam?) {
        let changedSession = current?.sessionID != jam?.sessionID
        if let jam, let prepared, jam.sessionID != prepared.sourceSession {
            clearPrepared()
        }
        current = jam
        if jam == nil && receiver != nil && targetConnected {
            targetConnected = false; targetDidFail()
        }
        if receiver != nil, let jam, jam.invitation != destinationInvitation || jam.sessionID != targetSession {
            transferTask?.cancel()
            Task { await cancelTransfer(message: "Move cancelled because another jam was opened.") }
        }
        if changedSession && receiver == nil { status = nil; onStatus?(nil, false) }
        Task { await refresh() }
    }
    func targetDidConnect(invitation: URL?, sessionID: UUID?) {
        guard receiver != nil, invitation == destinationInvitation, sessionID == targetSession else { return }
        targetConnected = true
    }
    func targetDidFail() {
        guard receiver != nil else { return }
        transferTask?.cancel()
        Task { await cancelTransfer(message: "Could not move the jam. Check the other device before retrying.") }
    }
    func refresh() async {
        guard enabled, let account else { return }
        checkExpiredHold()
        if busy { pendingRefresh = true; return }
        busy = true; pendingRefresh = false
        let expected = revision
        defer {
            busy = false
            if pendingRefresh { Task { await refresh() } }
            scheduleTick()
        }
        do {
            try await transport.connect(account: account)
            guard expected == revision else { return }
            if let onSnapshot { current = onSnapshot() }
            if var jam = current, receiver == nil {
                // A snapshot is made now, but its timestamp is a lease heartbeat,
                // not a content change. Avoid publishing on every five-second poll.
                jam.updatedAt = published?.updatedAt ?? jam.updatedAt
                if published != jam || now().timeIntervalSince(lastPublished) >= 60 {
                    jam.updatedAt = now(); current = jam
                    try await transport.publish(jam)
                    guard expected == revision else { return }
                    published = jam; lastPublished = now()
                    hasWithdrawn = false
                    onActivityChanged?()
                }
            } else if current == nil && receiver == nil && !hasWithdrawn {
                try await transport.withdraw(deviceID: deviceID, sessionID: published?.sessionID)
                published = nil
                hasWithdrawn = true
            }
            let remote = try await transport.jams()
            guard expected == revision else { return }
            if refreshFailed && !waitingForMove { show(nil) }
            refreshFailed = false
            candidates = remote.filter { $0.deviceID != deviceID && $0.isVisible(at: now()) }
                .sorted { $0.updatedAt > $1.updatedAt }.prefix(8).map { $0 }
            if let receiver, targetConnected, !moving,
               let latest = try await transport.transfer(sourceSession: receiver.sourceSession),
               latest.id == receiver.id, latest.phase == .completed {
                self.receiver = nil; destinationInvitation = nil
                show(completionMessage); pendingRefresh = true
            }
            if let jam = current, receiver == nil,
               let command = try await transport.transfer(sourceSession: jam.sessionID) {
                guard expected == revision, current?.sessionID == jam.sessionID else { return }
                await handleSource(command, expected: expected)
            }
        } catch {
            guard expected == revision else { return }
            refreshFailed = true
            #if DEBUG
            let detail = error as NSError
            print("Active-jam refresh failed: \(detail.domain) \(detail.code)")
            #endif
            if error is ContinuationError, case ContinuationError.expired = error {
                enabled = false; preferences.set(false, forKey: "shareActiveJams"); stopSharing()
                status = "Active-jam sharing was reset. Enable it again to continue."
            } else if !moving && prepared == nil { status = "Active jams could not refresh. Try again when iCloud is available." }
        }
    }
    private func scheduleTick() {
        guard automatic, enabled, account != nil, foreground || current != nil else { return }
        tick?.cancel()
        let delay = current == nil ? 30 : 5
        tick = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.refresh()
        }
    }
    private func handleSource(_ command: JamTransfer, expected: Int) async {
        if let prepared, prepared.id == command.id {
            if command.phase == .cancelled {
                clearPrepared()
                await onResumeSource?(command.sourceSession, false)
                show(nil); return
            }
            if command.canComplete(current: current, now: now()) {
                // Preserve this request through updateCurrent(nil) while teardown completes.
                let committed: JamTransfer
                do { committed = try await transport.transition(command, to: .finishing, actor: deviceID) }
                catch { return }
                let left = await onLeaveSource?(command.sourceSession, command.targetLabel) ?? false
                guard left, expected == revision else { return }
                do {
                    _ = try await transport.transition(committed, to: .completed, actor: deviceID)
                    try await transport.withdraw(deviceID: deviceID, sessionID: command.sourceSession)
                    clearPrepared()
                    show("Jam moved to \(command.targetLabel).")
                } catch { clearPrepared(); show("Jam left here. Check the other device’s connection.") }
                return
            }
            if command.expiresAt <= now() {
                checkExpiredHold()
            }
            return
        }
        guard command.canPrepare(current: current, now: now()), prepared == nil else { return }
        do {
            guard current?.isSharingScreen != true || command.allowsStoppingShare,
                  let onPrepareSource else { throw ContinuationError.unavailable }
            try await onPrepareSource(command.sourceSession)
            guard expected == revision, current?.sessionID == command.sourceSession else {
                await onResumeSource?(command.sourceSession, false); return
            }
            prepared = command
            holdExpiry?.cancel()
            holdExpiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, command.expiresAt.timeIntervalSinceNow))) } catch { return }
                self?.checkExpiredHold()
            }
            show("Moving jam to \(command.targetLabel)… Audio paused here.")
            let accepted = try await transport.transition(command, to: .prepared, actor: deviceID)
            guard expected == revision, prepared?.id == command.id else { return }
            prepared = accepted
        } catch {
            if prepared?.id == command.id { clearPrepared() }
            await onResumeSource?(command.sourceSession, false)
            _ = try? await transport.transition(command, to: .rejected, actor: deviceID)
        }
    }
    func resumeHere() {
        guard let prepared else { return }
        clearPrepared()
        Task { await onResumeSource?(prepared.sourceSession, false) }
        show(nil)
    }
    func begin(_ jam: ActiveJam, companion: Bool = false) {
        guard enabled, account != nil, !moving else { return }
        if companion {
            guard jam.supportsCompanion else { return }
            _ = onJoinTarget?(jam, true); return
        }
        guard jam.deviceID != deviceID, jam.isRecent(at: now()) else {
            show("This active jam is unconfirmed. Refresh or use Join here."); return
        }
        moving = true; targetConnected = false
        quietDestination = jam.supportsCompanion && jam.audioPaused == true
        destinationInvitation = jam.invitation
        let request = JamTransfer(source: jam, targetDevice: deviceID, targetLabel: deviceLabel, now: now())
        receiver = request; revision += 1
        let expected = revision
        transferTask = Task { [weak self] in
            guard let self else { return }
            do {
                show("Preparing to move jam from \(jam.deviceLabel)…")
                try await transport.claim(request)
                let prepared = try await waitFor(request, expected: expected, phases: [.prepared, .rejected], limit: 20)
                guard prepared.phase == .prepared else { throw ContinuationError.unavailable }
                show("Connecting here… The other device stays in the jam.")
                targetSession = onJoinTarget?(jam, quietDestination)
                guard targetSession != nil else { throw ContinuationError.unavailable }
                for _ in 0..<35 {
                    try Task.checkCancellation()
                    guard expected == revision else { throw CancellationError() }
                    if targetConnected { break }
                    try await Task.sleep(for: .seconds(1))
                }
                guard targetConnected else { throw ContinuationError.expired }
                let connected = try await transport.transition(prepared, to: .connected, actor: deviceID)
                receiver = connected
                show("Connected here. Waiting for \(jam.deviceLabel) to leave…")
                _ = try await waitFor(connected, expected: expected, phases: [.completed], limit: 15)
                guard expected == revision else { return }
                receiver = nil; moving = false; transferTask = nil
                show(completionMessage)
                await refresh()
            } catch {
                guard expected == revision else { return }
                if targetConnected {
                    moving = false; transferTask = nil
                    show("Connected here. Could not confirm that \(jam.deviceLabel) left. Check the other device.")
                    return
                }
                await cancelTransfer(message: "Move was not confirmed. Check the other device before retrying.")
            }
        }
    }
    private func waitFor(_ request: JamTransfer, expected: Int, phases: [JamTransfer.Phase], limit: Int) async throws -> JamTransfer {
        for _ in 0..<limit {
            try Task.checkCancellation()
            guard expected == revision else { throw CancellationError() }
            if let value = try await transport.transfer(sourceSession: request.sourceSession) {
                guard value.id == request.id else { throw ContinuationError.conflict }
                guard value.phase == .completed || value.expiresAt > now() else { throw ContinuationError.expired }
                if phases.contains(value.phase) { return value }
                if value.phase == .cancelled || value.phase == .rejected { throw ContinuationError.unavailable }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ContinuationError.expired
    }
    func cancel() {
        if targetConnected {
            moving = false
            show("Jam stays connected here. Check the other device if its exit was not confirmed.")
            return
        }
        transferTask?.cancel()
        Task { await cancelTransfer(message: "Move cancelled. The original device stays in the jam.") }
    }
    private func cancelTransfer(message: String) async {
        guard let request = receiver else { return }
        // Never resume the original while this destination can still produce audio.
        if let destinationInvitation, let targetSession, await onCancelTarget?(destinationInvitation, targetSession) == false {
            show("Could not end this connection. Leave this jam before resuming on the other device.")
            return
        }
        _ = try? await transport.transition(request, to: .cancelled, actor: deviceID)
        receiver = nil; moving = false; transferTask = nil; targetConnected = false
        destinationInvitation = nil
        targetSession = nil
        show(message); await refresh()
    }
    private func show(_ value: String?) {
        status = value; onStatus?(value, moving || prepared != nil)
    }
    private func clearPrepared() {
        prepared = nil; needsManualResume = false; holdExpiry?.cancel(); holdExpiry = nil
    }
    private func checkExpiredHold() {
        guard !needsManualResume, let prepared, current?.sessionID == prepared.sourceSession, prepared.expiresAt <= now() else { return }
        needsManualResume = true
        show("Move was not confirmed. Check the other device, then resume here with mic and camera off.")
    }
    private var completionMessage: String {
        quietDestination ? "Quiet connection moved here. Audio, microphone and camera are off." :
            "Jam moved here. Microphone and camera are off."
    }
    func deleteCloudData() async throws {
        guard let account else { return }
        try await transport.connect(account: account); try await transport.clear()
        enabled = false; preferences.set(false, forKey: "shareActiveJams"); stopSharing()
    }
}
