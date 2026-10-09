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
    var moveActionTitle: String { targetConnected ? L("Keep connected here") : L("Cancel move") }
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
    private struct DepartureAcknowledgement {
        let request: JamTransfer
        let targetSession: UUID
        let quiet: Bool
    }
    private var departureAcknowledgement: DepartureAcknowledgement?
    private var cancellingRequestID: UUID?
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
        departureAcknowledgement = nil
        targetConnected = false; targetSession = nil; destinationInvitation = nil
        let old = prepared; clearPrepared()
        if let old { Task { await resumePreparedSource(old) } }
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
        if let pending = departureAcknowledgement, pending.targetSession != jam?.sessionID {
            departureAcknowledgement = nil
            let expected = revision
            // The destination has ended. Conditional cancellation can release the
            // original if it has not already committed to leaving.
            Task {
                guard expected == revision else { return }
                _ = try? await transport.transition(pending.request, to: .cancelled, actor: deviceID)
            }
        }
        if jam == nil && receiver != nil && targetConnected {
            targetConnected = false; targetDidFail()
        }
        if receiver != nil, let jam, jam.invitation != destinationInvitation || jam.sessionID != targetSession {
            requestCancellation(message: L("Move cancelled because another jam was opened."))
        }
        if changedSession && receiver == nil { status = nil; onStatus?(nil, false) }
        Task { await refresh() }
    }
    func targetDidConnect(invitation: URL?, sessionID: UUID?) {
        guard receiver != nil, invitation == destinationInvitation, sessionID == targetSession, !targetConnected else { return }
        targetConnected = true
        show(L("Connected here. Finishing the move…"))
    }
    func targetDidFail() {
        requestCancellation(message: L("Could not move the jam. Check the other device before retrying."))
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
            let sourceSession = receiver == nil ? current?.sessionID : nil
            let snapshot = try await transport.snapshot(sourceSession: sourceSession)
            let remote = snapshot.jams
            guard expected == revision else { return }
            if refreshFailed && !waitingForMove { show(nil) }
            refreshFailed = false
            candidates = remote.filter { $0.deviceID != deviceID && $0.isVisible(at: now()) }
                .sorted { $0.updatedAt > $1.updatedAt }.prefix(8).map { $0 }
            await refreshDepartureAcknowledgement(expected: expected)
            guard expected == revision else { return }
            if let jam = current, receiver == nil,
               let command = snapshot.command, command.sourceSession == jam.sessionID {
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
                status = L("Active-jam sharing was reset. Enable it again to continue.")
            } else if !moving && prepared == nil { status = L("Active jams could not refresh. Try again when iCloud is available.") }
        }
    }
    private func scheduleTick() {
        guard automatic, enabled, account != nil, foreground || current != nil else { return }
        tick?.cancel()
        let delay = prepared != nil ? 1 : (current == nil ? 30 : 5)
        tick = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.refresh()
        }
    }
    private func handleSource(_ command: JamTransfer, expected: Int) async {
        if let prepared, prepared.id == command.id {
            if command.phase == .cancelled {
                clearPrepared()
                await resumePreparedSource(command)
                show(nil); return
            }
            if command.canComplete(current: current, now: now()) {
                // Preserve this request through updateCurrent(nil) while teardown completes.
                let committed: JamTransfer
                do {
                    committed = command.phase == .finishing ? command :
                        try await transport.transition(command, to: .finishing, actor: deviceID)
                }
                catch { return }
                let left = await onLeaveSource?(command.sourceSession, command.targetLabel) ?? false
                guard left, expected == revision else { return }
                do {
                    _ = try await transport.transition(committed, to: .completed, actor: deviceID)
                    try await transport.withdraw(deviceID: deviceID, sessionID: command.sourceSession)
                    clearPrepared()
                    show(L("Jam moved to %@.", command.targetLabel))
                } catch { clearPrepared(); show(L("Jam left here. Check the other device’s connection.")) }
                return
            }
            if command.expiresAt <= now() {
                checkExpiredHold()
            }
            return
        }
        guard command.canPrepare(current: current, now: now()), prepared == nil else { return }
        do {
            guard current?.isSharingScreen != true || command.allowsStoppingShare else { throw ContinuationError.unavailable }
            if command.connectsBeforePausing != true {
                guard let onPrepareSource else { throw ContinuationError.unavailable }
                try await onPrepareSource(command.sourceSession)
            }
            guard expected == revision, current?.sessionID == command.sourceSession else {
                await resumePreparedSource(command); return
            }
            prepared = command
            holdExpiry?.cancel()
            holdExpiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, command.expiresAt.timeIntervalSinceNow))) } catch { return }
                self?.checkExpiredHold()
            }
            show(command.connectsBeforePausing == true ?
                 L("Connecting on %@… This jam stays active here.", command.targetLabel) :
                 L("Moving jam to %@… Audio paused here.", command.targetLabel))
            let accepted = try await transport.transition(command, to: .prepared, actor: deviceID)
            guard expected == revision, prepared?.id == command.id else { return }
            prepared = accepted
        } catch {
            if prepared?.id == command.id { clearPrepared() }
            await resumePreparedSource(command)
            _ = try? await transport.transition(command, to: .rejected, actor: deviceID)
        }
    }
    func resumeHere() {
        guard let prepared else { return }
        clearPrepared()
        Task { await resumePreparedSource(prepared) }
        show(nil)
    }
    func begin(_ jam: ActiveJam, companion: Bool = false) {
        guard enabled, account != nil, !moving else { return }
        if companion {
            guard jam.supportsCompanion else { return }
            _ = onJoinTarget?(jam, true); return
        }
        guard jam.deviceID != deviceID, jam.isRecent(at: now()) else {
            show(L("This active jam is unconfirmed. Refresh or use Join here.")); return
        }
        moving = true; targetConnected = false
        targetSession = nil; departureAcknowledgement = nil
        quietDestination = jam.supportsCompanion && jam.audioPaused == true
        destinationInvitation = jam.invitation
        let request = JamTransfer(source: jam, targetDevice: deviceID, targetLabel: deviceLabel, now: now(),
                                  connectsBeforePausing: true)
        receiver = request; revision += 1
        let expected = revision
        transferTask = Task { [weak self] in
            guard let self else { return }
            do {
                show(L("Connecting here… The other device stays in the jam."))
                try await transport.claim(request)
                guard ownsTransfer(request, expected: expected), !Task.isCancelled else { return }
                // Joining does not depend on the other device's CloudKit round trip.
                // Mic/camera remain off; source teardown still requires a connected acknowledgement.
                targetSession = onJoinTarget?(jam, quietDestination)
                guard targetSession != nil else { throw ContinuationError.unavailable }
                let prepared = try await waitFor(request, expected: expected, phases: [.prepared, .rejected], limit: 20)
                guard ownsTransfer(request, expected: expected), !Task.isCancelled else { return }
                guard prepared.phase == .prepared else { throw ContinuationError.unavailable }
                for _ in 0..<35 {
                    try Task.checkCancellation()
                    guard expected == revision else { throw CancellationError() }
                    if targetConnected { break }
                    try await Task.sleep(for: .seconds(1))
                }
                guard targetConnected else { throw ContinuationError.expired }
                let connected = try await transport.transition(prepared, to: .connected, actor: deviceID)
                guard ownsTransfer(request, expected: expected), !Task.isCancelled else { return }
                receiver = connected
                show(L("Connected here. Waiting for %@ to leave…", jam.deviceLabel))
                _ = try await waitFor(connected, expected: expected, phases: [.completed], limit: 15)
                guard ownsTransfer(request, expected: expected) else { return }
                clearReceiver()
                show(completionMessage)
                await refresh()
            } catch {
                guard ownsTransfer(request, expected: expected) else { return }
                if targetConnected {
                    keepConnectedDestination(message: L("Connected here. Could not confirm that %@ left. Check the other device.", jam.deviceLabel))
                    await refresh()
                    return
                }
                await cancelTransfer(request, expected: expected,
                                     message: L("Move was not confirmed. Check the other device before retrying."))
            }
        }
    }
    private func waitFor(_ request: JamTransfer, expected: Int, phases: [JamTransfer.Phase], limit: Int) async throws -> JamTransfer {
        for _ in 0..<limit {
            try Task.checkCancellation()
            guard expected == revision else { throw CancellationError() }
            if let value = try await transport.transfer(sourceSession: request.sourceSession) {
                guard ownsTransfer(request, expected: expected), !Task.isCancelled else { throw CancellationError() }
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
            transferTask?.cancel()
            keepConnectedDestination(message: L("Jam stays connected here. Check the other device if its exit was not confirmed."))
            Task { await refresh() }
            return
        }
        requestCancellation(message: L("Move cancelled. The original device stays in the jam."))
    }
    private func requestCancellation(message: String) {
        guard let request = receiver else { return }
        let expected = revision
        transferTask?.cancel()
        Task { await cancelTransfer(request, expected: expected, message: message) }
    }
    private func ownsTransfer(_ request: JamTransfer, expected: Int) -> Bool {
        expected == revision && receiver?.id == request.id
    }
    private func cancelTransfer(_ request: JamTransfer, expected: Int, message: String) async {
        guard ownsTransfer(request, expected: expected), cancellingRequestID != request.id else { return }
        cancellingRequestID = request.id
        defer { if cancellingRequestID == request.id { cancellingRequestID = nil } }
        // Never resume the original while this destination can still produce audio.
        if let destinationInvitation, let targetSession {
            let ended = await onCancelTarget?(destinationInvitation, targetSession)
            guard ownsTransfer(request, expected: expected) else { return }
            if ended == false {
                show(L("Could not end this connection. Leave this jam before resuming on the other device."))
                return
            }
        }
        _ = try? await transport.transition(request, to: .cancelled, actor: deviceID)
        guard ownsTransfer(request, expected: expected) else { return }
        clearReceiver()
        show(message); await refresh()
    }
    private func clearReceiver() {
        receiver = nil; moving = false; transferTask = nil; targetConnected = false
        destinationInvitation = nil
        targetSession = nil
    }
    private func keepConnectedDestination(message: String) {
        if let request = receiver, let targetSession {
            departureAcknowledgement = .init(request: request, targetSession: targetSession, quiet: quietDestination)
        }
        clearReceiver()
        show(message)
    }
    private func refreshDepartureAcknowledgement(expected: Int) async {
        guard let pending = departureAcknowledgement else { return }
        guard current?.sessionID == pending.targetSession,
              pending.request.expiresAt > now() else {
            departureAcknowledgement = nil
            return
        }
        // A missing departure acknowledgement never gates this device's presence
        // heartbeat or its real media connection. Keep the existing warning on failure.
        guard let latest = try? await transport.transfer(sourceSession: pending.request.sourceSession),
              expected == revision, departureAcknowledgement?.request.id == pending.request.id,
              current?.sessionID == pending.targetSession else { return }
        if latest.id == pending.request.id, latest.phase == .completed {
            departureAcknowledgement = nil
            show(completionMessage(quiet: pending.quiet))
        }
    }
    private func show(_ value: String?) {
        status = value; onStatus?(value, moving || prepared != nil)
    }
    private func clearPrepared() {
        prepared = nil; needsManualResume = false; holdExpiry?.cancel(); holdExpiry = nil
    }
    private func resumePreparedSource(_ command: JamTransfer) async {
        guard command.connectsBeforePausing != true else { return }
        await onResumeSource?(command.sourceSession, false)
    }
    private func checkExpiredHold() {
        guard !needsManualResume, let prepared, current?.sessionID == prepared.sourceSession, prepared.expiresAt <= now() else { return }
        if prepared.connectsBeforePausing == true {
            clearPrepared()
            show(L("Move was not confirmed. This jam remains active here."))
            return
        }
        needsManualResume = true
        show(L("Move was not confirmed. Check the other device, then resume here with mic and camera off."))
    }
    private var completionMessage: String {
        completionMessage(quiet: quietDestination)
    }
    private func completionMessage(quiet: Bool) -> String {
        quiet ? L("Quiet connection moved here. Audio, microphone and camera are off.") :
            L("Jam moved here. Microphone and camera are off.")
    }
    func deleteCloudData() async throws {
        guard let account else { return }
        try await transport.connect(account: account); try await transport.clear()
        enabled = false; preferences.set(false, forKey: "shareActiveJams"); stopSharing()
    }
}
