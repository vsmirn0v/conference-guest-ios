import ConferenceCore
import UIKit
import UserNotifications
import XCTest
@testable import RockNRoll

@MainActor final class BackgroundAudioJoinTests: XCTestCase {
    final class Execution: BackgroundJoinExecution {
        var expired: (() -> Void)?
        var available = true, starts = 0, ends = 0
        func begin(expired: @escaping @MainActor () -> Void) -> Bool {
            starts += 1; self.expired = expired; return available
        }
        func end() { ends += 1 }
    }
    final class Session: BackgroundAudioJoinSession {
        var occurrence = BackgroundAudioJoinTests.occurrence()
        var resolution: CheckedContinuation<ReminderOccurrence?, Never>?
        var delayResolution = false, resolves = 0, starts = 0
        var start: BackgroundJoinStart = .started(42)
        var progress: BackgroundJoinProgress = .waiting
        var cancelled: [UInt64] = []
        func resolveBackgroundJoin(reference: String) async -> ReminderOccurrence? {
            resolves += 1
            if delayResolution { return await withCheckedContinuation { resolution = $0 } }
            return occurrence
        }
        func beginBackgroundJoin(_ occurrence: ReminderOccurrence, access: BackgroundJoinAccess) -> BackgroundJoinStart {
            starts += 1; return start
        }
        func backgroundJoinProgress(token: UInt64) -> BackgroundJoinProgress { progress }
        func cancelBackgroundJoin(token: UInt64) { cancelled.append(token) }
    }
    static func occurrence(engine: MeetingEngineKind = .guest, end: TimeInterval = 600) -> ReminderOccurrence {
        var meeting = CalendarMeeting(id: "event", seriesID: "series", calendarID: "work", calendarTitle: "Work",
            title: "Background audio", start: Date().addingTimeInterval(-60), end: Date().addingTimeInterval(end))
        meeting.invitation = URL(string: "https://meeting.example.test/calls/room?psw=private")!
        meeting.engine = engine
        return ReminderOccurrence(meeting: meeting)!
    }
    private let access = BackgroundJoinAccess(protectedData: true, microphone: true, systemControls: false)
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
    func testSuccessWaitsForMediaReadinessAndBalancesAssertion() async throws {
        let execution = Execution(), session = Session()
        let attempt = BackgroundAudioJoinAttempt(execution: execution)
        let task = Task { await attempt.join(reference: "r", session: session) }
        try await wait { session.starts == 1 }
        XCTAssertTrue(attempt.isPending)
        XCTAssertEqual(execution.ends, 0)
        session.progress = .ready
        let result = await task.value
        XCTAssertEqual(result, .connected); XCTAssertEqual(execution.ends, 1)
        XCTAssertTrue(session.cancelled.isEmpty); XCTAssertFalse(attempt.isPending)
        execution.expired?(); XCTAssertEqual(execution.ends, 1)
    }
    func testDuplicateActionsShareOneJoinAndOneOutcome() async throws {
        let execution = Execution(), session = Session()
        let attempt = BackgroundAudioJoinAttempt(execution: execution)
        var outcomes = 0; attempt.onFinished = { _, _ in outcomes += 1 }
        let first = Task { await attempt.join(reference: "r", session: session) }
        let second = Task { await attempt.join(reference: "r", session: session) }
        try await wait { session.starts == 1 }
        session.progress = .ready
        let one = await first.value, two = await second.value
        XCTAssertEqual(one, .connected); XCTAssertEqual(two, .connected)
        XCTAssertEqual(session.resolves, 1); XCTAssertEqual(execution.starts, 1); XCTAssertEqual(outcomes, 1)
    }
    func testAnotherActionCannotReplacePendingMeeting() async throws {
        let execution = Execution(), session = Session()
        let attempt = BackgroundAudioJoinAttempt(execution: execution)
        let first = Task { await attempt.join(reference: "first", session: session) }
        try await wait { session.starts == 1 }
        let result = await attempt.join(reference: "other", session: Session())
        XCTAssertEqual(result, .openApp); XCTAssertTrue(session.cancelled.isEmpty)
        attempt.cancel(); _ = await first.value
        XCTAssertEqual(session.cancelled, [42])
    }
    func testExpirationDuringCalendarResolutionCannotStartLateTransport() async throws {
        let execution = Execution(), session = Session(); session.delayResolution = true
        let attempt = BackgroundAudioJoinAttempt(execution: execution)
        let task = Task { await attempt.join(reference: "r", session: session) }
        try await wait { session.resolution != nil }
        execution.expired?()
        let result = await task.value
        XCTAssertEqual(result, .openApp); XCTAssertEqual(execution.ends, 1)
        session.resolution?.resume(returning: session.occurrence); session.resolution = nil
        await Task.yield()
        XCTAssertEqual(session.starts, 0); XCTAssertTrue(session.cancelled.isEmpty)
    }
    func testTimeoutCancelsOwnedTransportAndFinishesWithoutWaitingForTeardown() async {
        let execution = Execution(), session = Session()
        let attempt = BackgroundAudioJoinAttempt(execution: execution, timeout: .milliseconds(30))
        let result = await attempt.join(reference: "r", session: session)
        XCTAssertEqual(result, .openApp); XCTAssertEqual(session.cancelled, [42]); XCTAssertEqual(execution.ends, 1)
        execution.expired?(); XCTAssertEqual(session.cancelled, [42])
    }
    func testOldExpirationCannotCancelNextAttempt() async throws {
        let execution = Execution(), session = Session()
        let attempt = BackgroundAudioJoinAttempt(execution: execution)
        let first = Task { await attempt.join(reference: "a", session: session) }
        try await wait { session.starts == 1 }
        let oldExpiration = execution.expired
        attempt.cancel(); _ = await first.value
        let next = Session()
        let second = Task { await attempt.join(reference: "b", session: next) }
        try await wait { next.starts == 1 }
        oldExpiration?()
        XCTAssertTrue(attempt.isPending); XCTAssertTrue(next.cancelled.isEmpty)
        next.progress = .ready; _ = await second.value
        XCTAssertEqual(execution.ends, 2)
    }
    func testUnavailableBackgroundTimeAndExpiredOccurrenceDoNotStart() async {
        for expired in [false, true] {
            let execution = Execution(), session = Session()
            execution.available = expired
            if expired { session.occurrence = Self.occurrence(end: -1) }
            let attempt = BackgroundAudioJoinAttempt(execution: execution)
            let result = await attempt.join(reference: "r", session: session)
            XCTAssertEqual(result, .openApp); XCTAssertEqual(session.starts, 0); XCTAssertEqual(execution.ends, 1)
        }
    }
    func testForegroundTransferPreservesStartedMeetingAndCancelsDeadline() async throws {
        let execution = Execution(), session = Session()
        let attempt = BackgroundAudioJoinAttempt(execution: execution)
        let task = Task { await attempt.join(reference: "r", session: session) }
        try await wait { session.starts == 1 }
        XCTAssertNil(attempt.foregrounded())
        let result = await task.value
        XCTAssertEqual(result, .foregrounded); XCTAssertTrue(session.cancelled.isEmpty)
        execution.expired?(); XCTAssertTrue(session.cancelled.isEmpty); XCTAssertEqual(execution.ends, 1)
    }
    func testForegroundTransferDuringResolutionReturnsExplicitReference() async throws {
        let execution = Execution(), session = Session(); session.delayResolution = true
        let attempt = BackgroundAudioJoinAttempt(execution: execution)
        let task = Task { await attempt.join(reference: "r", session: session) }
        try await wait { session.resolution != nil }
        XCTAssertEqual(attempt.foregrounded(), "r")
        _ = await task.value
        session.resolution?.resume(returning: session.occurrence); session.resolution = nil
        await Task.yield(); XCTAssertEqual(session.starts, 0)
    }
    func testExplicitForegroundIntentConsumesUnresolvedRequestWithoutReplayingIt() async throws {
        let execution = Execution(), session = Session(); session.delayResolution = true
        let attempt = BackgroundAudioJoinAttempt(execution: execution)
        let task = Task { await attempt.join(reference: "old", session: session) }
        try await wait { session.resolution != nil }
        // Explicit URL/notification B has its own dispatch; discard A's replay.
        _ = attempt.foregrounded()
        XCTAssertNil(attempt.foregrounded())
        _ = await task.value
        session.resolution?.resume(returning: session.occurrence); session.resolution = nil
        await Task.yield(); XCTAssertEqual(session.starts, 0)
    }
    func testFallbackEnqueuesBeforeEndingExecutionAndReturningToSystem() async throws {
        let execution = Execution(), session = Session()
        let attempt = BackgroundAudioJoinAttempt(execution: execution)
        var notices = 0
        attempt.onFinished = { _, result in
            XCTAssertEqual(result, .openApp); XCTAssertEqual(execution.ends, 0); notices += 1
        }
        let task = Task { await attempt.join(reference: "r", session: session) }
        try await wait { session.starts == 1 }
        execution.expired?(); _ = await task.value
        XCTAssertEqual(notices, 1); XCTAssertEqual(execution.ends, 1)
    }
    func testColdOwnerRetainsExactModelAndContainerAfterSceneAdoption() async throws {
        let (model, _) = model(), container = MeetingContainerViewController()
        let attempt = BackgroundAudioJoinAttempt(execution: Execution())
        let prototype = BackgroundAudioJoinPrototype(attempt: attempt, enabled: { true },
            makePrepared: { .init(model: model, container: container) }, notify: { _ in })
        await prototype.join(reference: "unavailable")
        let first = prototype.takePreparedForScene()
        XCTAssertTrue(first?.model === model); XCTAssertTrue(first?.container === container)
        XCTAssertNil(prototype.takePreparedForScene())
        prototype.attach(model, container: container)
        // Simulate a live logical session, without invoking a media engine.
        model.joinTransportForTesting = { _, complete in complete(.active) }
        _ = model.beginBackgroundJoin(Self.occurrence(), access: access)
        try await wait { model.isInConference }
        XCTAssertTrue(prototype.sceneDisconnected(model))
        let next = prototype.takePreparedForScene()
        XCTAssertTrue(next?.model === model); XCTAssertTrue(next?.container === container)
        model.leave()
        withExtendedLifetime(container) {}
    }
    func testAlreadyConnectedAndEndedAttemptsBalanceExecution() async {
        for already in [false, true] {
            let execution = Execution(), session = Session()
            session.start = already ? .alreadyConnected : .started(42); session.progress = .ended
            let attempt = BackgroundAudioJoinAttempt(execution: execution)
            let result = await attempt.join(reference: "r", session: session)
            XCTAssertEqual(result, already ? .alreadyConnected : .openApp)
            XCTAssertEqual(execution.ends, 1); XCTAssertEqual(session.cancelled.count, already ? 0 : 1)
        }
    }
    func testFallbackContainsNoMeetingSecretsAndCannotOfferBackgroundRetry() {
        let request = BackgroundAudioJoinPrototype.fallback(reference: "opaque-reference")
        XCTAssertEqual(request.content.categoryIdentifier, BackgroundAudioJoinPrototype.fallbackCategory)
        XCTAssertNotEqual(request.content.categoryIdentifier, CalendarReminderBroker.category)
        XCTAssertEqual(request.content.userInfo["reference"] as? String, "opaque-reference")
        XCTAssertFalse(request.content.body.contains("private")); XCTAssertNil(request.content.sound)
        let action = BackgroundAudioJoinPrototype.notificationAction
        XCTAssertFalse(action.options.contains(.foreground)); XCTAssertTrue(action.options.contains(.authenticationRequired))
        let category = BackgroundAudioJoinPrototype.notificationCategory
        XCTAssertFalse(category.actions.contains { $0.identifier == BackgroundAudioJoinPrototype.action })
        XCTAssertTrue(category.actions.allSatisfy { $0.options.contains(.foreground) })
    }
    private func model() -> (ConferenceModel, UIViewController) {
        let originalReminders = CalendarReminderBroker.shared.sharedCoordinator
        let originalSync = RoomSyncCoordinator.active
        let originalContinuation = MeetingContinuationCoordinator.active
        let suite = "BackgroundJoin-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set("Test listener", forKey: "savedDisplayName")
        let detector = VendorEndpointResolver.makeDetector()
        let reminders = CalendarReminderCoordinator(preferences: preferences,
            storage: CalendarReminderTests.Storage(), notifications: CalendarReminderTests.Notifications())
        let calendar = CalendarMeetingStore(reader: CalendarMeetingStoreTests.Reader(events: []),
            detector: detector, preferences: preferences, storage: RoomSyncCoordinatorTests.Storage(), reminders: reminders)
        let model = ConferenceModel(history: RoomHistoryStore(storage: RoomSyncCoordinatorTests.Storage()),
            preferences: preferences, engineDetector: detector, calendar: calendar)
        model.installSyncFixture(RoomSyncCoordinator(history: model.history, name: model.displayName,
            preferences: preferences, storage: RoomSyncCoordinatorTests.Storage(), transport: RoomSyncCoordinatorTests.Cloud()))
        model.installContinuationFixture(model.makeContinuationCoordinator(preferences: preferences))
        addTeardownBlock { @MainActor in
            model.leave(); calendar.setEnabled(false)
            await reminders.waitForReconciliation()
            RoomSyncCoordinator.active = originalSync
            MeetingContinuationCoordinator.active = originalContinuation
            CalendarReminderBroker.shared.attach(originalReminders)
            preferences.removePersistentDomain(forName: suite)
        }
        let container = UIViewController(); model.configure(container: container)
        model.setup.suspendForMeeting()
        return (model, container)
    }
    func testModelRejectsMissingPermissionLockedDataCallControlsAndUnsupportedEngine() {
        let (model, container) = model()
        for blocked in [BackgroundJoinAccess(protectedData: false, microphone: true, systemControls: false),
                        .init(protectedData: true, microphone: false, systemControls: false),
                        .init(protectedData: true, microphone: true, systemControls: true)] {
            guard case .openApp = model.beginBackgroundJoin(Self.occurrence(), access: blocked) else { return XCTFail("Unsafe background join") }
        }
        for kind in [MeetingEngineKind.community, .telemost, .trueconf] {
            guard case .openApp = model.beginBackgroundJoin(Self.occurrence(engine: kind), access: access) else { return XCTFail("Unsupported engine") }
        }
        model.displayName = ""
        guard case .openApp = model.beginBackgroundJoin(Self.occurrence(), access: access) else { return XCTFail("Missing name") }
        XCTAssertFalse(model.isJoining); XCTAssertNil(container.presentedViewController)
    }
    func testModelSignalingIsNotMediaSuccessAndDifferentRoomCannotReplaceIt() async throws {
        let (model, container) = model()
        var event: ((CallEvent) -> Void)?
        model.joinTransportForTesting = { _, completion in event = completion }
        guard case .started(let token) = model.beginBackgroundJoin(Self.occurrence(), access: access) else { return XCTFail("Expected join") }
        try await wait { event != nil }
        event?(.active)
        XCTAssertEqual(model.backgroundJoinProgress(token: token), .waiting)
        guard case .alreadyConnected = model.beginBackgroundJoin(Self.occurrence(), access: access) else { return XCTFail("Same room no-op") }
        var other = Self.occurrence(); other.invitation = URL(string: "https://meeting.example.test/calls/other")!
        guard case .openApp = model.beginBackgroundJoin(other, access: access) else { return XCTFail("Different room replaced active call") }
        model.cancelBackgroundJoin(token: token &+ 1)
        XCTAssertTrue(model.isInConference)
        model.cancelBackgroundJoin(token: token)
        XCTAssertFalse(model.isInConference); XCTAssertNil(container.presentedViewController)
        withExtendedLifetime(container) {}
    }
}
