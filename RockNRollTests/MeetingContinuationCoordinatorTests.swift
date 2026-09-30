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
        func connect(account: String) async throws {
            if suspendConnect { await withCheckedContinuation { connectWaiter = $0 } }
            if !available { throw ContinuationError.unavailable }
        }
        func jams() async throws -> [ActiveJam] { if !available { throw ContinuationError.unavailable }; return Array(records.values) }
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
        func transfer(sourceSession: UUID) async throws -> JamTransfer? { requests[sourceSession] }
        func transition(_ value: JamTransfer, to phase: JamTransfer.Phase, actor: String) async throws -> JamTransfer {
            guard var stored = requests[value.sourceSession], stored.id == value.id,
                  stored.permitsTransition(to: phase, actor: actor, now: Date()) else { throw ContinuationError.conflict }
            stored.phase = phase; requests[value.sourceSession] = stored; onChange?(); return stored
        }
        func clear() async throws { records = [:]; requests = [:] }
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
    func testSuccessfulTransferPreparesSourceBeforeJoiningAndLeavesOnlyAfterTargetConnected() async throws {
        let cloud = Cloud(), source = make(cloud, "mac"), target = make(cloud, "phone")
        let active = jam(); var prepared = false; var left = false
        source.onPrepareSource = { id in XCTAssertEqual(id, active.sessionID); prepared = true }
        source.onLeaveSource = { id, _ in
            XCTAssertTrue(prepared); XCTAssertEqual(id, active.sessionID)
            left = true; source.updateCurrent(nil); return true
        }
        source.updateCurrent(active); await source.refresh(); await target.refresh()
        cloud.onChange = { Task { await source.refresh() } }
        target.onJoinTarget = { value, quiet in
            XCTAssertTrue(prepared); XCTAssertFalse(left); XCTAssertFalse(quiet)
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
    func testFailedDestinationEndsBeforeOriginalResumesAndKeepsSendingOff() async throws {
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
        await eventually({ resumed })
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
        await eventually { resumed }
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
}
