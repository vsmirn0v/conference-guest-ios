import ConferenceCore
import XCTest
@testable import RockNRoll

@MainActor
final class MeetingContinuationCoordinatorTests: XCTestCase {
    final class Cloud: MeetingContinuationTransport {
        var records: [String: ActiveJam] = [:]
        var requests: [UUID: JamTransfer] = [:]
        var onChange: (() -> Void)?
        var available = true
        var publishes = 0
        var suspendConnect = false
        var connectWaiter: CheckedContinuation<Void, Never>?
        var failConnectedTransferReads = false
        var transferReads: [UUID: Int] = [:]
        var transitionGate: ((JamTransfer, JamTransfer.Phase) async -> Void)?
        var snapshotReads = 0
        var snapshotHandler: ((Int) async throws -> [ActiveJam])?
        var clearHandler: (() async throws -> Void)?
        func connect(account: String) async throws {
            if suspendConnect { await withCheckedContinuation { connectWaiter = $0 } }
            if !available { throw ContinuationError.unavailable }
        }
        func jams() async throws -> [ActiveJam] { if !available { throw ContinuationError.unavailable }; return Array(records.values) }
        func snapshot(sourceSession: UUID?) async throws -> (jams: [ActiveJam], command: JamTransfer?) {
            snapshotReads += 1
            let rooms: [ActiveJam]
            if let snapshotHandler { rooms = try await snapshotHandler(snapshotReads) }
            else { rooms = try await jams() }
            let command: JamTransfer?
            if let sourceSession { command = try await transfer(sourceSession: sourceSession) } else { command = nil }
            return (rooms, command)
        }
        func publish(_ jam: ActiveJam) async throws { records[jam.deviceID] = jam; publishes += 1 }
        func withdraw(deviceID: String, sessionID: UUID?) async throws {
            if records[deviceID]?.sessionID == sessionID { records[deviceID] = nil }
        }
        func claim(_ value: JamTransfer) async throws {
            if let old = requests[value.sourceSession], !old.isTerminal, old.expiresAt > Date(), old.id != value.id {
                throw ContinuationError.conflict
            }
            requests[value.sourceSession] = value; onChange?()
        }
        func transfer(sourceSession: UUID) async throws -> JamTransfer? {
            transferReads[sourceSession, default: 0] += 1
            if failConnectedTransferReads, requests[sourceSession]?.phase == .connected {
                throw ContinuationError.unavailable
            }
            return requests[sourceSession]
        }
        func transition(_ value: JamTransfer, to phase: JamTransfer.Phase, actor: String) async throws -> JamTransfer {
            guard var stored = requests[value.sourceSession], stored.id == value.id,
                  stored.permitsTransition(to: phase, actor: actor, now: Date()) else { throw ContinuationError.conflict }
            stored.phase = phase; requests[value.sourceSession] = stored
            await transitionGate?(stored, phase)
            onChange?(); return stored
        }
        func clear() async throws { try await clearHandler?(); records = [:]; requests = [:] }
    }
    private func make(_ cloud: Cloud, _ device: String, now: @escaping () -> Date = Date.init) -> MeetingContinuationCoordinator {
        let preferences = UserDefaults(suiteName: "ContinuationTests-" + UUID().uuidString)!
        preferences.set(true, forKey: "shareActiveJams")
        let value = MeetingContinuationCoordinator(deviceID: device, deviceLabel: device, preferences: preferences,
                                                   transport: cloud, automatic: false, now: now)
        value.setCloudAccount("account-A")
        return value
    }
    private func jam(_ device: String = "mac") -> ActiveJam {
        .init(deviceID: device, invitation: URL(string: "https://guest.example.test/room?psw=secret")!,
              title: "Quartet", name: "Ani", deviceLabel: device)
    }
    private func eventually(_ condition: () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
    @MainActor private final class SnapshotGate {
        var reads: [Int: CheckedContinuation<[ActiveJam], Error>] = [:]
        func read(_ pass: Int) async throws -> [ActiveJam] {
            try await withCheckedThrowingContinuation { reads[pass] = $0 }
        }
        func release(_ pass: Int, _ rooms: [ActiveJam]) {
            guard let continuation = reads.removeValue(forKey: pass) else { XCTFail("Snapshot pass was not waiting"); return }
            continuation.resume(returning: rooms)
        }
        func cancelAll() {
            let pending = reads; reads = [:]
            pending.values.forEach { $0.resume(throwing: CancellationError()) }
        }
    }
    func testFreshLookupWaitsForNextPassWhenCloudReadIsAlreadyInFlight() async throws {
        let cloud = Cloud(), gate = SnapshotGate()
        cloud.snapshotHandler = { try await gate.read($0) }
        let target = make(cloud, "phone")
        defer { target.setEnabled(false); gate.cancelAll() }
        await eventually { gate.reads[1] != nil }
        var started = false, finished = false
        let lookup = Task {
            started = true; defer { finished = true }
            return try await target.refreshAndWait(timeout: .seconds(5))
        }
        await eventually { started }
        let old = jam("old-mac"), fresh = jam("new-mac")
        gate.release(1, [old])
        await eventually { gate.reads[2] != nil }
        XCTAssertFalse(finished, "A pass already running before the lookup cannot certify freshness")
        XCTAssertEqual(target.candidates, [old])
        gate.release(2, [fresh])
        let result = try await lookup.value
        XCTAssertEqual(result, [fresh]); XCTAssertTrue(finished)
    }
    func testFreshLookupUnavailableDoesNotReadCloudOrReturnCachedSuccess() async {
        let cloud = Cloud(), preferences = UserDefaults(suiteName: "UnavailableContinuation-" + UUID().uuidString)!
        let target = MeetingContinuationCoordinator(deviceID: "phone", deviceLabel: "phone", preferences: preferences,
            transport: cloud, automatic: false)
        for enabled in [false, true] {
            target.setEnabled(enabled)
            do { _ = try await target.refreshAndWait(); XCTFail("Missing cloud account cannot produce a fresh snapshot") }
            catch ContinuationError.unavailable { }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        target.setEnabled(false)
        XCTAssertEqual(cloud.snapshotReads, 0)
    }
    func testFreshLookupAccountChangeAndDisableInvalidateWaitersBeforeCloudReturns() async {
        for disable in [false, true] {
            let cloud = Cloud(), gate = SnapshotGate()
            cloud.snapshotHandler = { try await gate.read($0) }
            let target = make(cloud, "phone")
            defer { target.setEnabled(false); gate.cancelAll() }
            await eventually { gate.reads[1] != nil }
            var started = false
            let lookup = Task {
                started = true
                return try await target.refreshAndWait(timeout: .seconds(5))
            }
            await eventually { started }
            if disable { target.setEnabled(false) } else { target.setCloudAccount("account-B") }
            do { _ = try await lookup.value; XCTFail("An invalidated lookup must not return a snapshot") }
            catch is CancellationError { }
            catch { XCTFail("Expected immediate revision invalidation, not a deadline: \(error)") }
            XCTAssertNotNil(gate.reads[1], "The waiter's cancellation does not need a CloudKit response")
        }
    }
    func testCancellingOneFreshLookupPreservesAnotherAndTheSharedRefresh() async throws {
        let cloud = Cloud(), gate = SnapshotGate()
        cloud.snapshotHandler = { try await gate.read($0) }
        let target = make(cloud, "phone")
        defer { target.setEnabled(false); gate.cancelAll() }
        await eventually { gate.reads[1] != nil }
        var started = 0, secondFinished = false
        let first = Task { started += 1; return try await target.refreshAndWait(timeout: .seconds(5)) }
        let second = Task {
            started += 1; defer { secondFinished = true }
            return try await target.refreshAndWait(timeout: .seconds(5))
        }
        await eventually { started == 2 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled lookup returned a snapshot") }
        catch is CancellationError { }
        XCTAssertFalse(secondFinished); XCTAssertNotNil(gate.reads[1])
        gate.release(1, [])
        await eventually { gate.reads[2] != nil }
        let fresh = jam(); gate.release(2, [fresh])
        let result = try await second.value
        XCTAssertEqual(result, [fresh])
    }
    func testFreshLookupDeadlineDoesNotCancelTheSharedCloudRead() async throws {
        let cloud = Cloud(), gate = SnapshotGate()
        cloud.snapshotHandler = { try await gate.read($0) }
        let target = make(cloud, "phone")
        defer { target.setEnabled(false); gate.cancelAll() }
        await eventually { gate.reads[1] != nil }
        do { _ = try await target.refreshAndWait(timeout: .milliseconds(30)); XCTFail("Blocked cloud lookup must time out") }
        catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        XCTAssertNotNil(gate.reads[1])
        var started = false
        let retry = Task { started = true; return try await target.refreshAndWait(timeout: .seconds(5)) }
        await eventually { started }
        gate.release(1, [])
        await eventually { gate.reads[2] != nil }
        let fresh = jam(); gate.release(2, [fresh])
        let result = try await retry.value
        XCTAssertEqual(result, [fresh])
    }
    func testFailedFreshLookupNeverReturnsPreviouslyCachedCandidates() async throws {
        let cloud = Cloud(), target = make(cloud, "phone"), previous = jam()
        defer { target.setEnabled(false) }
        cloud.records[previous.deviceID] = previous
        let initial = try await target.refreshAndWait()
        XCTAssertEqual(initial, [previous])
        cloud.available = false
        do { _ = try await target.refreshAndWait(); XCTFail("A failed fresh read cannot return its old cache") }
        catch ContinuationError.unavailable { }
        XCTAssertEqual(target.candidates, [previous], "Existing background-refresh cache behavior is unchanged")
    }
    func testFreshLookupRechecksAccountAfterSnapshotBeforeResumingCaller() async throws {
        let cloud = Cloud(), source = make(cloud, "mac"), active = jam()
        defer { source.setEnabled(false) }
        source.updateCurrent(active); _ = try await source.refreshAndWait()
        let request = JamTransfer(source: active, targetDevice: "phone", targetLabel: "phone", connectsBeforePausing: true)
        try await cloud.claim(request); _ = try await source.refreshAndWait()
        let prepared = try XCTUnwrap(cloud.requests[active.sessionID])
        _ = try await cloud.transition(prepared, to: .connected, actor: "phone")
        var departed = false
        source.onLeaveSource = { _, _ in
            departed = true
            // Source actions run after candidates have been delivered to lookup
            // waiters, but before this actor releases their suspended callers.
            source.setCloudAccount(nil)
            return false
        }
        do { _ = try await source.refreshAndWait(); XCTFail("A result from the previous account must be rejected") }
        catch is CancellationError { }
        XCTAssertTrue(departed); XCTAssertTrue(source.candidates.isEmpty)
    }
    func testCloudDeletionInvalidatesLookupAndFencesLateSnapshot() async throws {
        let cloud = Cloud(), gate = SnapshotGate()
        var returned = false
        cloud.snapshotHandler = { pass in
            let rooms = try await gate.read(pass); returned = true; return rooms
        }
        let target = make(cloud, "phone")
        defer { target.setEnabled(false); gate.cancelAll() }
        await eventually { gate.reads[1] != nil }
        var started = false, activityWithdrawn = false
        target.onActivityChanged = { activityWithdrawn = !target.isAvailable }
        let lookup = Task { started = true; return try await target.refreshAndWait(timeout: .seconds(5)) }
        await eventually { started }
        try await target.deleteCloudData()
        do { _ = try await lookup.value; XCTFail("Deleted cloud data cannot resolve a pending lookup") }
        catch is CancellationError { }
        gate.release(1, [jam()])
        await eventually { returned }
        do { _ = try await target.refreshAndWait(); XCTFail("Deletion must disable continuation") }
        catch ContinuationError.unavailable { }
        XCTAssertFalse(target.enabled); XCTAssertTrue(activityWithdrawn)
        XCTAssertTrue(target.candidates.isEmpty); XCTAssertEqual(cloud.snapshotReads, 1)
    }
    func testOldCloudDeletionCannotDisableReplacementAccount() async throws {
        let cloud = Cloud(), target = make(cloud, "phone")
        defer { target.setEnabled(false) }
        _ = try await target.refreshAndWait()
        var clearing: CheckedContinuation<Void, Never>?
        cloud.clearHandler = { await withCheckedContinuation { clearing = $0 } }
        let deleting = Task { try await target.deleteCloudData() }
        await eventually { clearing != nil }
        target.setCloudAccount("account-B")
        clearing?.resume(); clearing = nil
        do { try await deleting.value; XCTFail("Old account deletion must not disable a replacement account") }
        catch is CancellationError { }
        XCTAssertTrue(target.enabled); XCTAssertTrue(target.isAvailable)
    }
    func testSuccessfulTransferKeepsSourceActiveAndLeavesOnlyAfterTargetConnected() async throws {
        let cloud = Cloud(), source = make(cloud, "mac"), target = make(cloud, "phone")
        let active = jam(); var prepared = false; var left = false
        source.onPrepareSource = { _ in prepared = true; XCTFail("New transfers must not pause the original before connecting") }
        source.onLeaveSource = { id, _ in
            XCTAssertFalse(prepared); XCTAssertEqual(id, active.sessionID)
            left = true; source.updateCurrent(nil); return true
        }
        source.updateCurrent(active); await source.refresh(); await target.refresh()
        cloud.onChange = { Task { await source.refresh() } }
        target.onJoinTarget = { value, quiet in
            XCTAssertFalse(prepared); XCTAssertFalse(left); XCTAssertFalse(quiet)
            var local = self.jam("phone"); local.updatedAt = Date()
            Task { target.targetDidConnect(invitation: value.invitation, sessionID: local.sessionID); target.updateCurrent(local) }
            return local.sessionID
        }
        target.onCancelTarget = { _, _ in XCTFail("Successful move should not cancel target"); return true }
        target.begin(active)
        await eventually({ !target.moving && left })
        XCTAssertTrue(target.status?.contains("moved here") == true)
        XCTAssertNil(cloud.records["mac"])
        XCTAssertEqual(cloud.records["phone"]?.name, "Ani")
    }
    func testJoinHereDoesNotTransferHoldOrLeaveOriginalDevice() async {
        let cloud = Cloud(), source = make(cloud, "mac"), target = make(cloud, "phone")
        let active = jam()
        XCTAssertFalse(active.supportsCompanion, "Joining normally works for every engine")
        source.onPrepareSource = { _ in XCTFail("Join here must not hold the source") }
        source.onLeaveSource = { _, _ in XCTFail("Join here must not leave the source"); return false }
        source.updateCurrent(active); await source.refresh(); await target.refresh()
        var joined: ActiveJam?
        target.onJoinTarget = { value, quiet in
            joined = value
            XCTAssertFalse(quiet, "Join here plays audio like an ordinary join")
            return UUID()
        }
        target.joinHere(active)
        XCTAssertEqual(joined, active)
        XCTAssertFalse(target.moving)
        XCTAssertFalse(target.waitingForMove)
        XCTAssertTrue(cloud.requests.isEmpty)
        await source.refresh()
        XCTAssertEqual(source.current?.sessionID, active.sessionID)
        XCTAssertEqual(cloud.records["mac"]?.sessionID, active.sessionID)
    }
    func testFailedDestinationEndsWithoutChangingOriginalAudio() async throws {
        let cloud = Cloud(), source = make(cloud, "mac"), target = make(cloud, "phone")
        let active = jam(); var cancelledTarget = false; var resumed = false
        source.onPrepareSource = { _ in }
        source.onResumeSource = { _, restore in XCTAssertTrue(cancelledTarget); XCTAssertFalse(restore); resumed = true }
        source.onLeaveSource = { _, _ in XCTFail("Original must not leave on a failed join"); return false }
        source.updateCurrent(active); await source.refresh()
        cloud.onChange = { Task { await source.refresh() } }
        target.onJoinTarget = { _, _ in Task { target.targetDidFail() }; return UUID() }
        target.onCancelTarget = { _, _ in cancelledTarget = true; return true }
        target.begin(active)
        await eventually({ !target.moving && cancelledTarget })
        XCTAssertFalse(resumed, "Original was never paused and must not have its microphone changed")
        XCTAssertFalse(target.moving)
        XCTAssertNotNil(source.current)
    }
    func testDestinationDisconnectBeforeAcknowledgementDoesNotEndOriginal() async {
        let cloud = Cloud(), source = make(cloud, "mac"), target = make(cloud, "phone")
        let active = jam(); var resumed = false
        source.onPrepareSource = { _ in }
        source.onResumeSource = { _, restore in XCTAssertFalse(restore); resumed = true }
        source.onLeaveSource = { _, _ in XCTFail("Destination already disconnected"); return false }
        source.updateCurrent(active); await source.refresh()
        cloud.onChange = { Task { await source.refresh() } }
        target.onJoinTarget = { value, _ in
            let local = self.jam("phone")
            Task {
                target.targetDidConnect(invitation: value.invitation, sessionID: local.sessionID)
                target.updateCurrent(local); target.updateCurrent(nil)
            }
            return local.sessionID
        }
        target.onCancelTarget = { _, _ in true }
        target.begin(active)
        await eventually { !target.moving }
        XCTAssertFalse(resumed)
        XCTAssertNotNil(source.current)
        XCTAssertFalse(target.moving)
    }
    func testStaleRequestCannotHoldOrLeaveReplacementSession() async throws {
        let cloud = Cloud(), source = make(cloud, "mac")
        let old = jam(), replacement = jam()
        source.onPrepareSource = { _ in XCTFail("Wrong source session") }
        source.onLeaveSource = { _, _ in XCTFail("Wrong source session"); return false }
        var command = JamTransfer(source: old, targetDevice: "phone", targetLabel: "phone")
        command.phase = .connected; cloud.requests[old.sessionID] = command
        source.updateCurrent(replacement); await source.refresh()
        XCTAssertEqual(source.current?.sessionID, replacement.sessionID)
    }
    func testExpiredPreparationOffersManualResumeEvenWhenCloudFails() async throws {
        let cloud = Cloud(); var date = Date()
        let source = make(cloud, "mac", now: { date }), active = jam()
        source.onPrepareSource = { _ in }
        source.updateCurrent(active); await source.refresh()
        let command = JamTransfer(source: active, targetDevice: "phone", targetLabel: "phone")
        cloud.requests[active.sessionID] = command; await source.refresh()
        XCTAssertEqual(cloud.requests[active.sessionID]?.phase, .prepared)
        date = date.addingTimeInterval(80); cloud.available = false
        await source.refresh()
        XCTAssertTrue(source.needsManualResume)
    }
    func testHeartbeatCoalescesAndAccountLossHidesOtherDevices() async {
        let cloud = Cloud(), source = make(cloud, "mac"), active = jam()
        source.updateCurrent(active); await source.refresh()
        let count = cloud.publishes
        source.onSnapshot = {
            var snapshot = active; snapshot.updatedAt = Date(); return snapshot
        }
        await source.refresh(); await source.refresh(); XCTAssertEqual(cloud.publishes, count)
        cloud.records["phone"] = jam("phone"); await source.refresh()
        XCTAssertEqual(source.candidates.count, 1)
        source.setCloudAccount(nil); XCTAssertTrue(source.candidates.isEmpty)
    }
    func testExpiredHoldCanResumeWhileACloudRefreshIsStillWaiting() async {
        let cloud = Cloud(); var date = Date(); var resumed = false
        let source = make(cloud, "mac", now: { date }), active = jam()
        source.onPrepareSource = { _ in }
        source.onResumeSource = { _, restore in XCTAssertFalse(restore); resumed = true }
        source.updateCurrent(active); await source.refresh()
        cloud.requests[active.sessionID] = JamTransfer(source: active, targetDevice: "phone", targetLabel: "phone")
        await source.refresh()
        cloud.suspendConnect = true
        let waiting = Task { await source.refresh() }
        await eventually { cloud.connectWaiter != nil }
        date = date.addingTimeInterval(80)
        await source.refresh()
        XCTAssertTrue(source.needsManualResume)
        source.resumeHere(); await eventually { resumed }
        cloud.suspendConnect = false; cloud.connectWaiter?.resume(); cloud.connectWaiter = nil
        await waiting.value
        XCTAssertFalse(source.needsManualResume)
    }
    func testCompanionDoesNotRequestOriginalToLeave() async {
        let cloud = Cloud(), target = make(cloud, "phone")
        var active = jam(); active.supportsCompanion = true
        var quiet = false
        target.onJoinTarget = { _, isQuiet in quiet = isQuiet; return UUID() }
        target.begin(active, companion: true)
        XCTAssertTrue(quiet); XCTAssertTrue(cloud.requests.isEmpty)
    }
    func testMovingQuietCompanionKeepsAudioDisabled() async {
        let cloud = Cloud(), source = make(cloud, "mac"), target = make(cloud, "phone")
        var active = jam(); active.supportsCompanion = true; active.audioPaused = true
        source.onPrepareSource = { _ in }
        source.onLeaveSource = { _, _ in source.updateCurrent(nil); return true }
        source.updateCurrent(active); await source.refresh()
        cloud.onChange = { Task { await source.refresh() } }
        target.onJoinTarget = { value, quiet in
            XCTAssertTrue(quiet)
            let local = self.jam("phone")
            Task { target.targetDidConnect(invitation: value.invitation, sessionID: local.sessionID); target.updateCurrent(local) }
            return local.sessionID
        }
        target.onCancelTarget = { _, _ in true }
        target.begin(active)
        await eventually { !target.moving }
        XCTAssertTrue(target.status?.contains("Quiet connection moved") == true)
    }
    func testFailedClaimDoesNotEndAnUnrelatedConnection() async {
        let cloud = Cloud(), target = make(cloud, "phone"), active = jam()
        cloud.requests[active.sessionID] = JamTransfer(source: active, targetDevice: "another-phone", targetLabel: "phone")
        target.onJoinTarget = { _, _ in XCTFail("Source is already claimed"); return nil }
        target.onCancelTarget = { _, _ in XCTFail("This request never started a connection"); return false }
        target.begin(active)
        await eventually { !target.moving }
        XCTAssertEqual(cloud.requests[active.sessionID]?.targetDevice, "another-phone")
    }

    func testOldCancellationCannotClearAReplacementMove() async {
        let cloud = Cloud(), firstSource = make(cloud, "mac"), nextSource = make(cloud, "ipad"), target = make(cloud, "phone")
        let first = jam(), next = jam("ipad")
        var originalResumed = false
        firstSource.onPrepareSource = { _ in }
        firstSource.onResumeSource = { _, _ in originalResumed = true }
        nextSource.onPrepareSource = { _ in }
        firstSource.updateCurrent(first); nextSource.updateCurrent(next)
        await firstSource.refresh(); await nextSource.refresh()
        cloud.onChange = { Task { await firstSource.refresh(); await nextSource.refresh() } }
        var cancellation: CheckedContinuation<Void, Never>?
        cloud.transitionGate = { request, phase in
            if request.sourceSession == first.sessionID, phase == .cancelled {
                await withCheckedContinuation { cancellation = $0 }
            }
        }
        var joins = 0
        target.onJoinTarget = { _, _ in
            joins += 1
            if joins == 1 { Task { target.targetDidFail() } }
            return UUID()
        }
        target.onCancelTarget = { _, _ in true }
        target.begin(first)
        await eventually { cancellation != nil }
        target.setEnabled(false); target.setEnabled(true); target.begin(next)
        await eventually { joins == 2 }
        XCTAssertTrue(target.moving)
        cancellation?.resume(); cancellation = nil
        await eventually { !firstSource.waitingForMove }
        XCTAssertFalse(originalResumed)
        XCTAssertTrue(target.moving, "Old cancellation must not clear the new transfer")
        XCTAssertEqual(target.destinationInvitation, next.invitation)
        target.cancel(); await eventually { !target.moving }
    }

    func testUnconfirmedDestinationPublishesPresenceAndExpiresOnlyItsAcknowledgement() async {
        let cloud = Cloud(); var date = Date()
        let source = make(cloud, "mac"), target = make(cloud, "phone", now: { date }), active = jam()
        var local = jam("phone")
        local = .init(deviceID: local.deviceID, sessionID: local.sessionID, invitation: active.invitation,
                      title: active.title, name: active.name, deviceLabel: "phone")
        source.onPrepareSource = { _ in }
        source.updateCurrent(active); await source.refresh()
        cloud.onChange = { Task { await source.refresh() } }
        cloud.failConnectedTransferReads = true
        target.onJoinTarget = { value, _ in
            Task { target.targetDidConnect(invitation: value.invitation, sessionID: local.sessionID); target.updateCurrent(local) }
            return local.sessionID
        }
        target.onCancelTarget = { _, _ in XCTFail("Connected destination must stay connected"); return false }
        target.begin(active)
        await eventually { !target.moving && target.status?.contains("Could not confirm") == true }
        await target.refresh()
        XCTAssertEqual(cloud.records["phone"]?.sessionID, local.sessionID)
        XCTAssertEqual(target.current?.sessionID, local.sessionID)
        let reads = cloud.transferReads[active.sessionID]
        date = date.addingTimeInterval(80)
        await target.refresh(); await target.refresh()
        XCTAssertEqual(cloud.transferReads[active.sessionID], reads,
                       "Expired acknowledgements must not keep polling the old source")
        XCTAssertEqual(cloud.records["phone"]?.sessionID, local.sessionID)
        XCTAssertTrue(target.status?.contains("Could not confirm") == true)
        target.setEnabled(false); source.setEnabled(false)
    }

    func testLateDepartureAcknowledgementDoesNotChangeReplacementSessionStatus() async {
        let cloud = Cloud(), source = make(cloud, "mac"), target = make(cloud, "phone"), active = jam()
        let local = jam("phone")
        source.onPrepareSource = { _ in }
        source.updateCurrent(active); await source.refresh()
        cloud.onChange = { Task { await source.refresh() } }
        cloud.failConnectedTransferReads = true
        target.onJoinTarget = { value, _ in
            Task { target.targetDidConnect(invitation: value.invitation, sessionID: local.sessionID); target.updateCurrent(local) }
            return local.sessionID
        }
        target.begin(active)
        await eventually { !target.moving && target.status?.contains("Could not confirm") == true }
        let replacement = jam("phone")
        target.updateCurrent(replacement)
        cloud.requests[active.sessionID]?.phase = .completed
        cloud.failConnectedTransferReads = false
        await target.refresh()
        XCTAssertNil(target.status)
        XCTAssertEqual(target.current?.sessionID, replacement.sessionID)
        XCTAssertEqual(cloud.records["phone"]?.sessionID, replacement.sessionID)
        target.setEnabled(false); source.setEnabled(false)
    }

    func testUnconfirmedDestinationCanAcknowledgeDepartureLater() async {
        let cloud = Cloud(), source = make(cloud, "mac"), target = make(cloud, "phone"), active = jam()
        let local = jam("phone")
        var left = false
        source.onPrepareSource = { _ in }
        source.onLeaveSource = { _, _ in left = true; source.updateCurrent(nil); return true }
        source.updateCurrent(active); await source.refresh()
        cloud.onChange = { Task { await source.refresh() } }
        cloud.failConnectedTransferReads = true
        target.onJoinTarget = { value, _ in
            Task { target.targetDidConnect(invitation: value.invitation, sessionID: local.sessionID); target.updateCurrent(local) }
            return local.sessionID
        }
        target.begin(active)
        await eventually { !target.moving && target.status?.contains("Could not confirm") == true }
        XCTAssertFalse(left)
        cloud.failConnectedTransferReads = false
        await source.refresh(); await target.refresh()
        XCTAssertTrue(left)
        XCTAssertTrue(target.status?.contains("Jam moved here") == true)
        XCTAssertEqual(cloud.records["phone"]?.sessionID, local.sessionID)
        target.setEnabled(false); source.setEnabled(false)
    }

    func testUnconfirmedDestinationDepartureResumesOriginalWithoutTouchingReplacement() async {
        let cloud = Cloud(), source = make(cloud, "mac"), target = make(cloud, "phone"), active = jam()
        let local = jam("phone"), replacement = jam("phone")
        var resumed = false
        source.onPrepareSource = { _ in }
        source.onResumeSource = { _, restore in XCTAssertFalse(restore); resumed = true }
        source.onLeaveSource = { _, _ in XCTFail("Original must not leave after destination ends"); return false }
        source.updateCurrent(active); await source.refresh()
        cloud.onChange = { Task { await source.refresh() } }
        cloud.failConnectedTransferReads = true
        target.onJoinTarget = { value, _ in
            Task { target.targetDidConnect(invitation: value.invitation, sessionID: local.sessionID); target.updateCurrent(local) }
            return local.sessionID
        }
        target.begin(active)
        await eventually { !target.moving && target.status?.contains("Could not confirm") == true }
        target.updateCurrent(replacement)
        await eventually { cloud.requests[active.sessionID]?.phase == .cancelled && !source.waitingForMove }
        XCTAssertFalse(resumed)
        XCTAssertEqual(cloud.requests[active.sessionID]?.phase, .cancelled)
        XCTAssertEqual(target.current?.sessionID, replacement.sessionID)
        XCTAssertNil(target.status)
        target.setEnabled(false); source.setEnabled(false)
    }

    func testTargetStartsWhileSourceAcknowledgementIsStillPending() async throws {
        let cloud = Cloud(), source = make(cloud, "mac"), target = make(cloud, "phone")
        let active = jam(), local = jam("phone")
        var joined = false, left = false
        source.updateCurrent(active); await source.refresh()
        source.onPrepareSource = { _ in XCTFail("Original must remain active") }
        source.onLeaveSource = { _, _ in left = true; source.updateCurrent(nil); return true }
        target.onJoinTarget = { _, quiet in joined = true; XCTAssertFalse(quiet); return local.sessionID }
        target.begin(active)
        await eventually { joined }
        XCTAssertEqual(cloud.requests[active.sessionID]?.phase, .requested)
        XCTAssertFalse(left)
        await source.refresh()
        XCTAssertEqual(cloud.requests[active.sessionID]?.phase, .prepared)
        XCTAssertFalse(left)
        cloud.onChange = { Task { await source.refresh() } }
        target.targetDidConnect(invitation: active.invitation, sessionID: local.sessionID)
        target.updateCurrent(local)
        await eventually { left && !target.moving }
    }

    func testSourceRetriesFinishingWithoutAttemptingTheSameTransitionAgain() async throws {
        let cloud = Cloud(), source = make(cloud, "mac"), active = jam()
        source.updateCurrent(active); await source.refresh()
        let request = JamTransfer(source: active, targetDevice: "phone", targetLabel: "phone", connectsBeforePausing: true)
        try await cloud.claim(request); await source.refresh()
        let prepared = try XCTUnwrap(cloud.requests[active.sessionID])
        _ = try await cloud.transition(prepared, to: .connected, actor: "phone")
        var attempts = 0
        source.onLeaveSource = { _, _ in
            attempts += 1
            if attempts == 1 { return false }
            source.updateCurrent(nil); return true
        }
        await source.refresh()
        XCTAssertEqual(cloud.requests[active.sessionID]?.phase, .finishing)
        await source.refresh()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(cloud.requests[active.sessionID]?.phase, .completed)
    }
}
