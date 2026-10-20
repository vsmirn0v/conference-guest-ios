import Combine
import SwiftUI
import XCTest
@testable import RockNRoll

@MainActor
final class MeetingActivityTests: XCTestCase {
    private func snapshot(_ id: UUID = UUID(), microphone: MeetingActivityState.Microphone = .muted) -> MeetingActivitySnapshot {
        .init(sessionID: id, state: .init(startedAt: Date(timeIntervalSince1970: 100), connection: .connected,
            microphone: microphone, title: nil, route: "AirPods"))
    }
    func testDeduplicationAndBoundedFreshness() async {
        let driver = ActivityDriverStub(); var date = Date()
        let coordinator = MeetingActivityCoordinator(driver: driver, now: { date }, foreground: { true })
        let value = snapshot()
        coordinator.update(value); await coordinator.task?.value
        for _ in 0..<10 { coordinator.update(value); await coordinator.task?.value }
        XCTAssertEqual(driver.started.count, 1); XCTAssertTrue(driver.updates.isEmpty)
        date.addTimeInterval(61); coordinator.update(value); await coordinator.task?.value
        XCTAssertEqual(driver.updates.count, 1)
        coordinator.update(nil); await coordinator.task?.value
        XCTAssertEqual(driver.ends, ["activity-1"])
    }
    func testLeaveDuringSuspendedUpdateDoesNotResurrectActivity() async {
        let driver = ActivityDriverStub()
        let coordinator = MeetingActivityCoordinator(driver: driver, foreground: { true })
        let first = snapshot(); coordinator.update(first); await coordinator.task?.value
        driver.suspendUpdate = true
        let entered = expectation(description: "update started")
        driver.onUpdate = { entered.fulfill() }
        var changed = first; changed.state.microphone = .on
        coordinator.update(changed)
        await fulfillment(of: [entered], timeout: 2)
        coordinator.update(nil)
        driver.resumeUpdate?.resume(); driver.resumeUpdate = nil
        await coordinator.task?.value
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(driver.started.count, 1); XCTAssertEqual(driver.ends, ["activity-1"])
    }
    func testSwitchDuringSuspendedUpdateEndsOldBeforeStartingNew() async {
        let driver = ActivityDriverStub()
        let coordinator = MeetingActivityCoordinator(driver: driver, foreground: { true })
        let first = snapshot(); coordinator.update(first); await coordinator.task?.value
        driver.suspendUpdate = true
        let entered = expectation(description: "update entered"); driver.onUpdate = { entered.fulfill() }
        var changed = first; changed.state.microphone = .on
        coordinator.update(changed); await fulfillment(of: [entered], timeout: 2)
        let next = snapshot(); coordinator.update(next)
        driver.resumeUpdate?.resume(); driver.resumeUpdate = nil
        await coordinator.task?.value
        XCTAssertEqual(driver.events, ["start", "update", "end", "start"])
        XCTAssertEqual(driver.started.last?.sessionID, next.sessionID)
    }
    func testDismissalSuppressesSameSessionButNotNextMeeting() async {
        let driver = ActivityDriverStub()
        let coordinator = MeetingActivityCoordinator(driver: driver, foreground: { true })
        let value = snapshot(); coordinator.update(value); await coordinator.task?.value
        driver.onDismiss?("activity-1")
        coordinator.foregrounded(); coordinator.update(value); await coordinator.task?.value
        XCTAssertEqual(driver.started.count, 1)
        coordinator.update(snapshot()); await coordinator.task?.value
        XCTAssertEqual(driver.started.count, 2)
    }
    func testInitialOrphansEndBeforeStartingAndBackgroundCreationWaits() async {
        let driver = ActivityDriverStub(); driver.orphans = ["orphan"]
        var active = false
        let coordinator = MeetingActivityCoordinator(driver: driver, foreground: { active })
        let value = snapshot(); coordinator.update(value); await coordinator.task?.value
        XCTAssertEqual(driver.ends, ["orphan"]); XCTAssertTrue(driver.started.isEmpty)
        active = true; coordinator.foregrounded(); coordinator.update(value); await coordinator.task?.value
        XCTAssertEqual(driver.events, ["end", "start"])
    }
    func testAuthorizationLossEndsExistingActivityAndFailureDoesNotLoop() async {
        let driver = ActivityDriverStub()
        let coordinator = MeetingActivityCoordinator(driver: driver, foreground: { true })
        let value = snapshot(); coordinator.update(value); await coordinator.task?.value
        driver.available = false; coordinator.update(value); await coordinator.task?.value
        XCTAssertFalse(coordinator.isRunning); XCTAssertEqual(driver.ends.count, 1)
        driver.available = true; driver.failStart = true
        coordinator.update(value); await coordinator.task?.value
        let attempts = driver.attempts
        coordinator.update(value); await coordinator.task?.value
        XCTAssertEqual(driver.attempts, attempts)
        coordinator.foregrounded(); coordinator.update(value); await coordinator.task?.value
        XCTAssertEqual(driver.attempts, attempts + 1)
    }
    func testActivityURLContainsOnlyOpaqueLocalIDAndNeverAnInvitation() {
        let value = snapshot()
        XCTAssertEqual(MeetingActivitySnapshot.sessionID(from: value.openURL), value.sessionID)
        for text in ["https://salutejazz.ru/calls/123", "conferenceguest://active-meeting/not-a-uuid",
                     value.openURL.absoluteString + "?psw=secret", value.openURL.absoluteString + "/extra"] {
            XCTAssertNil(MeetingActivitySnapshot.sessionID(from: URL(string: text)!))
        }
        let data = try! JSONEncoder().encode(value.state)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("psw"))
        XCTAssertNil(value.state.title)
    }
    func testStaleMicrophoneNeverClaimsMutedOrOn() {
        for microphone in [MeetingActivityState.Microphone.muted, .on, .paused, .unknown] {
            let state = snapshot(microphone: microphone).state
            XCTAssertEqual(state.microphoneSymbol(stale: true), "questionmark.circle")
            XCTAssertEqual(state.microphoneLabel(stale: true), L("Microphone status unavailable"))
            XCTAssertEqual(state.connectionLabel(stale: true), L("Open to check meeting"))
        }
    }
    func testOldActivityCannotJoinOrReplaceCurrentRoom() async {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let model = ConferenceModel(preferences: preferences)
        model.receive(url: snapshot().openURL)
        XCTAssertFalse(model.isJoining); XCTAssertFalse(model.isInConference)
        XCTAssertNil(model.connectedURL); XCTAssertEqual(model.invite, "")
    }
    func testSharedCardFitsCompactWidth() throws {
        guard #available(iOS 16.2, *) else { throw XCTSkip("Activity requires iOS 16.2") }
        let state = snapshot().state
        let host = UIHostingController(rootView: MeetingActivityDetails(state: state, stale: false, openURL: snapshot().openURL))
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 500))
        XCTAssertLessThanOrEqual(size.height, 160)
        XCTAssertLessThanOrEqual(size.width, 320)
    }
    func testLargestTypeAndStaleCardFitSystemHeightInBothAppearances() throws {
        guard #available(iOS 16.2, *) else { throw XCTSkip("Activity requires iOS 16.2") }
        var state = snapshot(microphone: .unknown).state
        state.title = String(repeating: "Длинное название встречи ", count: 6)
        for appearance in [ColorScheme.light, .dark] {
            for stale in [false, true] {
                let content = MeetingActivityDetails(state: state, stale: stale, openURL: snapshot().openURL)
                    .environment(\.dynamicTypeSize, .accessibility5).environment(\.colorScheme, appearance)
                let host = UIHostingController(rootView: content)
                let size = host.sizeThatFits(in: CGSize(width: 320, height: 500))
                XCTAssertLessThanOrEqual(size.height, 160, "System card must not truncate controls at large type")
            }
        }
    }
}

@MainActor
final class ActivityDriverStub: MeetingActivityDriver {
    var available = true
    var onDismiss: ((String) -> Void)?
    var orphans: [String] = []
    var started: [MeetingActivitySnapshot] = []
    var updates: [MeetingActivitySnapshot] = []
    var ends: [String] = []
    var events: [String] = []
    var attempts = 0
    var failStart = false
    var suspendUpdate = false
    var resumeUpdate: CheckedContinuation<Void, Never>?
    var onUpdate: (() -> Void)?
    func existingIDs() -> [String] { orphans }
    func start(_ snapshot: MeetingActivitySnapshot, staleDate: Date) throws -> String {
        attempts += 1
        if failStart { throw CocoaError(.featureUnsupported) }
        started.append(snapshot); events.append("start"); return "activity-\(started.count)"
    }
    func update(_ id: String, snapshot: MeetingActivitySnapshot, staleDate: Date) async {
        updates.append(snapshot); events.append("update")
        if suspendUpdate { await withCheckedContinuation { resumeUpdate = $0; onUpdate?() } }
    }
    func end(_ id: String) async { ends.append(id); events.append("end") }
}
