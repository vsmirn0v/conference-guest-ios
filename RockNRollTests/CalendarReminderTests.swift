import ConferenceCore
import UserNotifications
import XCTest
@testable import RockNRoll

@MainActor final class CalendarReminderTests: XCTestCase {
    final class Storage: ReminderStorage {
        var data: Data?
        var fails = false
        func read() throws -> Data? { if fails { throw CocoaError(.fileReadNoPermission) }; return data }
        func write(_ data: Data) throws { if fails { throw CocoaError(.fileWriteNoPermission) }; self.data = data }
    }
    final class Notifications: ReminderNotifying {
        var permission: ReminderAuthorization = .allowed
        var items: [String: ReminderNotification] = [:]
        var removed: Set<String> = []
        var additions = 0
        var failsAdd = false
        var delayed = false
        var continuation: CheckedContinuation<Void, Never>?
        var delayAuthorization = false
        var authorizationContinuation: CheckedContinuation<Void, Never>?
        var onAdd: ((ReminderNotification) -> Void)?
        var foreign: [String: String] = [:]
        var delivered: Set<String> = []
        func authorization() async -> ReminderAuthorization {
            if delayAuthorization {
                delayAuthorization = false
                await withCheckedContinuation { authorizationContinuation = $0 }
            }
            return permission
        }
        func request(sensitive: Bool) -> Bool { permission = .allowed; return true }
        func pending() -> [String: String] { items.mapValues(\.fingerprint).merging(foreign) { first, _ in first } }
        func add(_ reminder: ReminderNotification) async throws {
            if failsAdd { throw CocoaError(.fileWriteUnknown) }
            additions += 1
            if delayed { await withCheckedContinuation { continuation = $0 } }
            onAdd?(reminder)
            items[reminder.plan.id] = reminder
        }
        func removePending(_ ids: [String]) { for id in ids { items[id] = nil } }
        func removeDelivered(occurrenceIDs: Set<String>) { removed.formUnion(occurrenceIDs) }
        func removeAllDelivered() { delivered = delivered.filter { !$0.hasPrefix(PlannedReminder.namespace) } }
    }
    private let now = Date()
    private func meeting(_ id: String = "event", offset: Double = 600, end: Double = 1800,
                         room: String = "room", password: String = "secret") -> CalendarMeeting {
        var meeting = CalendarMeeting(id: id, seriesID: "series", calendarID: "work", calendarTitle: "Calendar", title: "Test meeting",
            start: now.addingTimeInterval(offset), end: now.addingTimeInterval(offset + end))
        meeting.invitation = URL(string: "https://salutejazz.ru/calls/\(room)?psw=\(password)")!; meeting.engine = .guest
        return meeting
    }
    private func preferences() -> UserDefaults {
        let value = UserDefaults(suiteName: "ReminderTests." + UUID().uuidString)!
        value.set(true, forKey: "calendarMeetings.enabled"); value.set(["work"], forKey: "calendarMeetings.selected")
        return value
    }
    func testNotificationTapAndJoinUseSameDirectJoinIntentWarmAndAfterColdReplay() async throws {
        for cold in [false, true] {
            for action in [UNNotificationDefaultActionIdentifier, CalendarReminderBroker.join] {
                let owner = CalendarReminderCoordinator(preferences: preferences(), storage: Storage(), notifications: Notifications())
                await owner.setEnabled(true)
                owner.update(meetings: [meeting()], available: true)
                let occurrence = try XCTUnwrap(owner.repository.occurrences.first)
                owner.beforeOpen = { true }
                let opened = expectation(description: "Direct notification join")
                owner.onOpen = { resolved, join in
                    XCTAssertEqual(resolved?.reference, occurrence.reference)
                    XCTAssertTrue(join)
                    opened.fulfill()
                }
                let broker = CalendarReminderBroker()
                if !cold { broker.attach(owner) }
                await broker.respond(reference: occurrence.reference, action: action)
                if cold {
                    XCTAssertTrue(broker.hasPendingIntent)
                    // The default tap and explicit action are the same intent.
                    await broker.respond(reference: occurrence.reference, action: CalendarReminderBroker.join)
                    broker.attach(owner)
                }
                await fulfillment(of: [opened], timeout: 2)
                XCTAssertFalse(broker.hasPendingIntent)
                await broker.respond(reference: occurrence.reference, action: UNNotificationDismissActionIdentifier)
                XCTAssertFalse(broker.hasPendingIntent)
            }
        }
    }
    func testOlderDeferredSnoozeDetailsCannotReplaceNewNotificationJoin() async throws {
        for resolvesBeforeForeground in [false, true] {
            let owner = CalendarReminderCoordinator(preferences: preferences(), storage: Storage(), notifications: Notifications())
            await owner.setEnabled(true)
            owner.update(meetings: [meeting("old", offset: -60, end: 120), meeting("new", room: "new")], available: true)
            await owner.waitForReconciliation()
            let old = try XCTUnwrap(owner.repository.occurrences.first { $0.eventID == "old" })
            let next = try XCTUnwrap(owner.repository.occurrences.first { $0.eventID == "new" })
            await owner.action(reference: old.reference, snooze: true)
            XCTAssertEqual(owner.repository.pendingOpen, old.reference)
            let opened = expectation(description: "Newer explicit intent wins")
            opened.assertForOverFulfill = true
            owner.beforeOpen = { true }
            owner.onOpen = { occurrence, join in
                XCTAssertEqual(occurrence?.reference, next.reference); XCTAssertTrue(join); opened.fulfill()
            }
            owner.open(reference: next.reference, join: true)
            XCTAssertNil(owner.repository.pendingOpen)
            XCTAssertNil(owner.repository.pendingOpenDate)
            if resolvesBeforeForeground { await fulfillment(of: [opened], timeout: 2) }
            owner.foregrounded()
            if !resolvesBeforeForeground { await fulfillment(of: [opened], timeout: 2) }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertNil(owner.repository.pendingOpen)
        }
    }
    func testNoDuplicateReconciliationAndPersistenceAcrossRelaunch() async throws {
        let storage = Storage(), notifications = Notifications(), preferences = preferences()
        let coordinator = CalendarReminderCoordinator(preferences: preferences, storage: storage, notifications: notifications)
        await coordinator.setEnabled(true); coordinator.update(meetings: [meeting()], available: true)
        await coordinator.waitForReconciliation()
        XCTAssertEqual(notifications.items.count, 1); let additions = notifications.additions
        coordinator.update(meetings: [meeting()], available: true); await coordinator.waitForReconciliation()
        XCTAssertEqual(notifications.additions, additions)
        let restored = CalendarReminderCoordinator(preferences: preferences, storage: storage, notifications: notifications)
        restored.update(meetings: [meeting()], available: true); await restored.waitForReconciliation()
        XCTAssertTrue(restored.enabled); XCTAssertEqual(notifications.additions, additions)
        await restored.setEnabled(false); await restored.waitForReconciliation()
        XCTAssertTrue(notifications.items.isEmpty)
    }
    func testLateAddCannotRestoreNotificationAfterDisable() async throws {
        let notifications = Notifications()
        let owner = CalendarReminderCoordinator(preferences: preferences(), storage: Storage(), notifications: notifications)
        await owner.setEnabled(true); await owner.waitForReconciliation()
        notifications.delayed = true; owner.update(meetings: [meeting()], available: true)
        for _ in 0..<100 where notifications.continuation == nil { await Task.yield() }
        XCTAssertNotNil(notifications.continuation)
        await owner.setEnabled(false)
        notifications.delayed = false; notifications.continuation?.resume(); notifications.continuation = nil
        await owner.waitForReconciliation()
        XCTAssertTrue(notifications.items.isEmpty)
    }
    func testReadFailureNeverOverwritesExistingProtectedData() async throws {
        let storage = Storage(); storage.data = Data("unavailable data".utf8); storage.fails = true
        let coordinator = CalendarReminderCoordinator(preferences: preferences(), storage: storage, notifications: Notifications())
        await coordinator.setEnabled(true); coordinator.update(meetings: [meeting()], available: true)
        XCTAssertNotNil(coordinator.error); XCTAssertEqual(storage.data, Data("unavailable data".utf8))
    }
    func testDisableCancelsEvenWhenWritingLocalStoreFailsAndSurvivesRelaunch() async throws {
        let storage = Storage(), notifications = Notifications(), preferences = preferences()
        let coordinator = CalendarReminderCoordinator(preferences: preferences, storage: storage, notifications: notifications)
        await coordinator.setEnabled(true); coordinator.update(meetings: [meeting()], available: true)
        await coordinator.waitForReconciliation(); XCTAssertEqual(notifications.items.count, 1)
        storage.fails = true
        await coordinator.setEnabled(false); await coordinator.waitForReconciliation()
        XCTAssertTrue(notifications.items.isEmpty); XCTAssertNotNil(coordinator.error)
        storage.fails = false
        let restored = CalendarReminderCoordinator(preferences: preferences, storage: storage, notifications: notifications)
        restored.update(meetings: [meeting()], available: true); await restored.waitForReconciliation()
        XCTAssertFalse(restored.enabled); XCTAssertTrue(notifications.items.isEmpty)
    }
    func testColdUnreadableStoreStillAllowsDisableWithoutTouchingForeignNotifications() async throws {
        let storage = Storage(), notifications = Notifications(), preferences = preferences()
        let coordinator = CalendarReminderCoordinator(preferences: preferences, storage: storage, notifications: notifications)
        await coordinator.setEnabled(true); coordinator.update(meetings: [meeting()], available: true)
        await coordinator.waitForReconciliation()
        let original = storage.data
        notifications.foreign = ["other-feature": "unchanged"]
        notifications.delivered = [PlannedReminder.namespace + "old", "other-feature"]
        storage.fails = true
        let cold = CalendarReminderCoordinator(preferences: preferences, storage: storage, notifications: notifications)
        XCTAssertTrue(cold.enabled, "Device enable flag must remain truthful even when the file cannot be read")
        await cold.setEnabled(false); await cold.waitForReconciliation()
        XCTAssertTrue(notifications.items.isEmpty); XCTAssertEqual(notifications.foreign.count, 1)
        XCTAssertEqual(notifications.delivered, ["other-feature"]); XCTAssertEqual(storage.data, original)
        XCTAssertNotNil(cold.error)
        storage.fails = false
        let restored = CalendarReminderCoordinator(preferences: preferences, storage: storage, notifications: notifications)
        restored.update(meetings: [meeting()], available: true); await restored.waitForReconciliation()
        XCTAssertFalse(restored.enabled); XCTAssertTrue(notifications.items.isEmpty)
    }
    func testBoundaryRefreshKeepsAcceptedDuePhaseForDelayedForegroundCallback() async throws {
        let storage = Storage(), notifications = Notifications(), preferences = preferences()
        let event = meeting(offset: 110)
        var repository = CalendarReminderRepository(); repository.enabled = true
        repository.update([event], at: now)
        let occurrence = try XCTUnwrap(repository.occurrences.first)
        let plan = PlannedReminder(occurrence: occurrence, phase: .before, date: now.addingTimeInterval(-10))
        repository.scheduled = [plan]; storage.data = try JSONEncoder().encode(repository)
        let coordinator = CalendarReminderCoordinator(preferences: preferences, storage: storage, notifications: notifications)
        coordinator.foregrounded(); coordinator.update(meetings: [event], available: true); await coordinator.waitForReconciliation()
        var deliveries = 0; coordinator.scene = { .init(visible: true) }
        coordinator.onPresentation = { events in deliveries += events.filter { !coordinator.wasPresented($0) }.count; return Set(events.map(\.id)) }
        let notification = ReminderNotification(plan: plan, occurrence: occurrence, profile: .init())
        coordinator.foregroundReminder(reference: occurrence.reference, requestID: plan.id, fingerprint: notification.fingerprint)
        await coordinator.waitForReconciliation()
        XCTAssertEqual(deliveries, 1); XCTAssertTrue(notifications.items.isEmpty)
    }
    func testLaterDisableWinsOverSuspendedEnableAuthorization() async throws {
        let notifications = Notifications()
        let coordinator = CalendarReminderCoordinator(preferences: preferences(), storage: Storage(), notifications: notifications)
        notifications.delayAuthorization = true
        let enabling = Task { await coordinator.setEnabled(true) }
        for _ in 0..<100 where notifications.authorizationContinuation == nil { await Task.yield() }
        XCTAssertNotNil(notifications.authorizationContinuation)
        await coordinator.setEnabled(false)
        notifications.authorizationContinuation?.resume(); notifications.authorizationContinuation = nil
        await enabling.value; await coordinator.waitForReconciliation()
        XCTAssertFalse(coordinator.enabled); XCTAssertTrue(notifications.items.isEmpty)
    }
    func testDeliveryDuringAddIsRecognizedAndDoesNotScheduleAnotherAlert() async throws {
        let notifications = Notifications()
        let coordinator = CalendarReminderCoordinator(preferences: preferences(), storage: Storage(), notifications: notifications)
        await coordinator.setEnabled(true); await coordinator.waitForReconciliation()
        var deliveries = 0
        coordinator.scene = { .init(visible: true) }
        coordinator.onPresentation = { events in deliveries += events.filter { !coordinator.wasPresented($0) }.count; return Set(events.map(\.id)) }
        notifications.onAdd = { [weak coordinator] reminder in
            coordinator?.foregroundReminder(reference: reminder.plan.reference, requestID: reminder.plan.id, fingerprint: reminder.fingerprint)
        }
        defer { notifications.onAdd = nil }
        coordinator.update(meetings: [meeting()], available: true)
        await coordinator.waitForReconciliation()
        XCTAssertEqual(deliveries, 1); XCTAssertTrue(notifications.items.isEmpty); XCTAssertNil(coordinator.error)
    }
    func testSkipSnoozeAndSuccessfulEarlyJoinRemainSuppressed() async throws {
        let storage = Storage(), notifications = Notifications()
        let coordinator = CalendarReminderCoordinator(preferences: preferences(), storage: storage, notifications: notifications)
        await coordinator.setEnabled(true); coordinator.update(meetings: [meeting()], available: true)
        await coordinator.waitForReconciliation()
        let occurrence = try XCTUnwrap(coordinator.repository.occurrences.first)
        await coordinator.action(reference: occurrence.reference, snooze: true)
        XCTAssertTrue(notifications.items.values.contains { $0.plan.phase == .snooze })
        await coordinator.action(reference: occurrence.reference, snooze: false)
        XCTAssertTrue(notifications.items.isEmpty)
        coordinator.setOverride(.init(mode: .defaults), for: occurrence); await coordinator.waitForReconciliation()
        XCTAssertEqual(notifications.items.count, 1)
        coordinator.joined(room: try XCTUnwrap(occurrence.room), eventID: occurrence.eventID); await coordinator.waitForReconciliation()
        XCTAssertTrue(notifications.items.isEmpty)
        coordinator.update(meetings: [meeting(password: "new")], available: true); await coordinator.waitForReconciliation()
        XCTAssertTrue(notifications.items.isEmpty)
    }
    func testMovedOccurrenceAndChangedRoomInvalidateOldReferenceButPasswordDoesNot() throws {
        var repository = CalendarReminderRepository()
        repository.update([meeting()], at: now)
        let original = try XCTUnwrap(repository.occurrences.first)
        repository.joined(room: original.room!, eventID: original.eventID, at: now)
        repository.update([meeting(password: "new")], at: now)
        XCTAssertEqual(repository.occurrences.first?.reference, original.reference)
        XCTAssertTrue(repository.states[original.id]?.attended == true)
        repository.update([meeting(offset: 7200)], at: now)
        XCTAssertNotEqual(repository.occurrences.first?.id, original.id)
        let moved = try XCTUnwrap(repository.occurrences.first)
        repository.update([meeting(offset: 7200, room: "other")], at: now)
        XCTAssertNotEqual(repository.occurrences.first?.reference, moved.reference)
    }
    func testDuplicateCopiesDeletedEventsAndPruning() {
        var repository = CalendarReminderRepository()
        repository.update([meeting("one"), meeting("two"), meeting("tomorrow", offset: 86400)], at: now)
        XCTAssertEqual(repository.occurrences.count, 2)
        repository.update([], at: now); XCTAssertTrue(repository.occurrences.isEmpty)
        repository.update([meeting(offset: -90000, end: 1800)], at: now)
        XCTAssertTrue(repository.occurrences.isEmpty)
    }
    func testRemoteAttendanceUsesFreshLeaseAndAccountAndLatchesAfterDeparture() throws {
        var repository = CalendarReminderRepository(); repository.update([meeting(offset: -60)], at: now)
        let occurrence = try XCTUnwrap(repository.occurrences.first)
        var jam = ActiveJam(deviceID: "remote", invitation: occurrence.invitation, title: "Meeting", name: "Name", deviceLabel: "Mac")
        jam.updatedAt = now.addingTimeInterval(-400)
        repository.observe([jam], account: "account", now: now)
        XCTAssertNil(repository.states[occurrence.id]?.remoteAccount)
        jam.updatedAt = now
        repository.observe([jam], account: "account", now: now)
        XCTAssertEqual(repository.states[occurrence.id]?.remoteAccount, "account")
        repository.observe([], account: "account", now: now.addingTimeInterval(500))
        XCTAssertEqual(repository.states[occurrence.id]?.remoteAccount, "account")
        repository.observe([], account: "different", now: now)
        XCTAssertNil(repository.states[occurrence.id]?.remoteAccount)
    }
    func testPrivateContentAndNativeTriggerContainNoInvitationSecrets() throws {
        let occurrence = try XCTUnwrap(ReminderOccurrence(meeting: meeting()))
        let plan = PlannedReminder(occurrence: occurrence, phase: .before, date: now.addingTimeInterval(30))
        var profile = ReminderProfile(); profile.details = false
        let content = ReminderNotification(plan: plan, occurrence: occurrence, profile: profile)
        let request = SystemReminderNotifications.request(content)
        XCTAssertFalse([request.identifier, request.content.threadIdentifier, request.content.title, request.content.subtitle,
                        request.content.body, String(describing: request.content.userInfo)].joined().contains("secret"))
        XCTAssertFalse(request.content.body.contains("salutejazz")); XCTAssertFalse(request.content.title.contains("Test meeting"))
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertFalse(trigger.repeats)
        XCTAssertEqual(try XCTUnwrap(trigger.nextTriggerDate()).timeIntervalSince1970, ceil(plan.date.timeIntervalSince1970), accuracy: 0.1)
    }
    func testTitleContainingInvitationIsRedactedEvenWhenDetailsAreEnabled() throws {
        var event = meeting()
        event = CalendarMeeting(id: event.id, seriesID: event.seriesID, calendarID: event.calendarID, calendarTitle: event.calendarTitle,
            title: "Join https://salutejazz.ru/calls/room?psw=secret", start: event.start, end: event.end)
        event.invitation = meeting().invitation; event.engine = .guest
        let occurrence = try XCTUnwrap(ReminderOccurrence(meeting: event))
        let reminder = ReminderNotification(plan: .init(occurrence: occurrence, phase: .before, date: now.addingTimeInterval(30)), occurrence: occurrence, profile: .init())
        XCTAssertFalse(reminder.title.contains("secret")); XCTAssertTrue(reminder.title.contains("salutejazz.ru"))
    }
    func testUnresolvedRefreshRetainsSkipAndCustomAndDuplicateCopyUsesSameOverride() throws {
        var repository = CalendarReminderRepository(); repository.update([meeting()], at: now)
        let occurrence = try XCTUnwrap(repository.occurrences.first)
        repository.setOverride(.init(mode: .custom, custom: .init(before: 30)), id: occurrence.id)
        repository.skip(reference: occurrence.reference)
        var unresolved = meeting(); unresolved.engine = nil; unresolved.invitation = nil
        repository.update([unresolved], at: now)
        XCTAssertEqual(repository.occurrences.first?.id, occurrence.id)
        XCTAssertEqual(repository.occurrences.first?.eligible, false)
        XCTAssertTrue(repository.states[occurrence.id]?.skipped == true)
        repository.update([meeting()], at: now)
        XCTAssertTrue(repository.states[occurrence.id]?.skipped == true)
        XCTAssertEqual(repository.states[occurrence.id]?.override?.custom.before, 30)
        let coordinator = CalendarReminderCoordinator(preferences: preferences(), storage: Storage(), notifications: Notifications())
        let first = coordinator.occurrence(for: meeting("one"))
        let copy = coordinator.occurrence(for: meeting("two"))
        XCTAssertEqual(first?.id, copy?.id)
    }
    func testExplicitAttendanceDoesNotSuppressNextSameRoomOccurrence() throws {
        var repository = CalendarReminderRepository()
        repository.update([meeting("current", offset: -1200, end: 1800), meeting("next", offset: 600)], at: now)
        let room = try XCTUnwrap(repository.occurrences.first?.room)
        repository.joined(room: room, at: now)
        let current = try XCTUnwrap(repository.occurrences.first { $0.eventID == "current" })
        let next = try XCTUnwrap(repository.occurrences.first { $0.eventID == "next" })
        XCTAssertTrue(repository.states[current.id]?.attended == true)
        XCTAssertNotEqual(repository.states[next.id]?.attended, true)
        repository.joined(room: room, eventID: "next", at: now.addingTimeInterval(-3600))
        XCTAssertTrue(repository.states[next.id]?.attended == true, "Explicit early joins count for their selected occurrence")
    }
    func testOldDeliveredReferenceCannotConsumeRescheduledPhase() throws {
        var repository = CalendarReminderRepository(); repository.update([meeting()], at: now)
        let old = try XCTUnwrap(repository.occurrences.first)
        repository.states[old.id, default: .init()].consumed = [.before]
        repository.scheduled = [.init(occurrence: old, phase: .before, date: now.addingTimeInterval(-1))]
        repository.update([meeting(offset: 900)], at: now)
        XCTAssertFalse(repository.states[old.id]?.consumed.contains(.before) ?? false)
        XCTAssertEqual(CalendarReminderPlanner.plan(occurrences: repository.occurrences, states: repository.states, profile: .init(), now: now).count, 1)
    }
    func testUnavailableSnoozePersistsDetailsIntentWithoutSchedulingAfterEnd() async throws {
        let storage = Storage(), notifications = Notifications()
        let coordinator = CalendarReminderCoordinator(preferences: preferences(), storage: storage, notifications: notifications)
        await coordinator.setEnabled(true); coordinator.update(meetings: [meeting(offset: -60, end: 120)], available: true)
        let occurrence = try XCTUnwrap(coordinator.repository.occurrences.first)
        await coordinator.action(reference: occurrence.reference, snooze: true)
        let restored = CalendarReminderCoordinator(preferences: preferences(), storage: storage, notifications: notifications)
        XCTAssertEqual(restored.repository.pendingOpen, occurrence.reference)
        XCTAssertFalse(notifications.items.values.contains { $0.plan.phase == .snooze })
    }
    func testCancelledRefreshDoesNotResolveStaleNotification() async throws {
        let notifications = Notifications()
        let coordinator = CalendarReminderCoordinator(preferences: preferences(), storage: Storage(), notifications: notifications)
        await coordinator.setEnabled(true); coordinator.update(meetings: [meeting()], available: true)
        await coordinator.waitForReconciliation()
        let occurrence = try XCTUnwrap(coordinator.repository.occurrences.first)
        coordinator.beforeOpen = { false }
        let resolved = await coordinator.resolve(reference: occurrence.reference)
        XCTAssertNil(resolved)
        await coordinator.action(reference: occurrence.reference, snooze: true)
        await coordinator.waitForReconciliation()
        XCTAssertFalse(notifications.items.values.contains { $0.plan.phase == .snooze })
    }
    func testActualSystemPendingRequestCanBeReadBackAndCancelled() async throws {
        let occurrence = try XCTUnwrap(ReminderOccurrence(meeting: meeting(), id: "test-" + UUID().uuidString))
        let plan = PlannedReminder(occurrence: occurrence, phase: .before, date: now.addingTimeInterval(600))
        let notifications = SystemReminderNotifications()
        guard await notifications.authorization() == .allowed else { throw XCTSkip("Native notification permission is exercised by the fresh Simulator UI check first.") }
        defer { notifications.removePending([plan.id]) }
        let reminder = ReminderNotification(plan: plan, occurrence: occurrence, profile: .init())
        try await notifications.add(reminder)
        let pending = await notifications.pending(); XCTAssertEqual(pending[plan.id], reminder.fingerprint)
        notifications.removePending([plan.id])
        let removed = await notifications.pending(); XCTAssertNil(removed[plan.id])
    }
    func testConditionalMountAcknowledgementAndRelaunchPersistence() async throws {
        let storage = Storage(), notifications = Notifications(), prefs = preferences()
        var instant = now
        let owner = CalendarReminderCoordinator(preferences: prefs, storage: storage, notifications: notifications, clock: { instant })
        let other = MeetingRoomIdentity(URL(string: "https://salutejazz.ru/calls/current")!, engine: .guest)!
        var visible = true, usable = false
        owner.scene = { .init(visible: visible, room: other) }
        var mounted: [ReminderForegroundEvent] = []
        owner.onPresentation = { events in
            mounted = events
            return usable ? Set(events.map(\.id)) : []
        }
        await owner.setEnabled(true)
        owner.update(meetings: [meeting(offset: -121)], available: true)
        await owner.waitForReconciliation()
        let occurrence = try XCTUnwrap(owner.repository.occurrences.first)
        XCTAssertEqual(mounted.count, 1)
        XCTAssertNil(owner.repository.states[occurrence.id]?.presentation, "Blocked mounting must not consume the conditional phase")
        XCTAssertTrue(notifications.items.isEmpty)
        usable = true; owner.refreshPresentation()
        let event = try XCTUnwrap(owner.repository.states[occurrence.id]?.presentation)
        XCTAssertTrue(owner.wasPresented(event))
        visible = false; owner.backgrounded(); instant = instant.addingTimeInterval(10)
        owner.refreshPresentation(); XCTAssertTrue(mounted.isEmpty)
        visible = true; owner.foregrounded(); await owner.waitForReconciliation(); XCTAssertEqual(mounted, [event])
        let restored = CalendarReminderCoordinator(preferences: prefs, storage: storage, notifications: notifications, clock: { instant })
        XCTAssertTrue(restored.wasPresented(event)); XCTAssertEqual(restored.repository.schema, 2)
        owner.joined(room: try XCTUnwrap(occurrence.room), eventID: occurrence.eventID)
        XCTAssertTrue(mounted.isEmpty)
    }
    func testConditionalSnoozeKeepsScopeAndPermissionDisableInvalidates() async throws {
        let notifications = Notifications(), storage = Storage()
        var instant = now
        let owner = CalendarReminderCoordinator(preferences: preferences(), storage: storage, notifications: notifications, clock: { instant })
        owner.scene = { .init(visible: true, room: MeetingRoomIdentity(URL(string: "https://salutejazz.ru/calls/other")!, engine: .guest)) }
        var shown: [ReminderForegroundEvent] = []
        owner.onPresentation = { events in shown = events; return Set(events.map(\.id)) }
        await owner.setEnabled(true); owner.update(meetings: [meeting(offset: -121)], available: true)
        await owner.waitForReconciliation()
        let occurrence = try XCTUnwrap(owner.repository.occurrences.first)
        await owner.action(reference: occurrence.reference, snooze: true, scope: .anotherMeeting)
        XCTAssertTrue(shown.isEmpty); XCTAssertTrue(notifications.items.isEmpty)
        XCTAssertEqual(owner.repository.states[occurrence.id]?.snoozeScope, .anotherMeeting)
        instant = instant.addingTimeInterval(120); owner.refreshPresentation()
        XCTAssertEqual(shown.first?.plan.phase, .snooze)
        await owner.setEnabled(false); await owner.waitForReconciliation()
        XCTAssertTrue(shown.isEmpty); XCTAssertTrue(notifications.items.isEmpty)
    }
    func testSchemaOneRepositoryPreservesOffAndCustomChoices() throws {
        var repository = CalendarReminderRepository(); repository.schema = 1; repository.profile.schema = 1
        repository.enabled = true; repository.update([meeting()], at: now)
        let id = try XCTUnwrap(repository.occurrences.first?.id)
        var state = ReminderOccurrenceState(); state.skipped = true
        state.override = .init(mode: .custom, custom: .init(after: 90))
        repository.states[id] = state
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(repository)) as? [String: Any])
        var profile = try XCTUnwrap(object["profile"] as? [String: Any])
        var value = try XCTUnwrap(profile["value"] as? [String: Any])
        value["timing"] = ["atStart": false, "rememberedAfter": 300]
        profile["value"] = value; object["profile"] = profile
        let storage = Storage(); storage.data = try JSONSerialization.data(withJSONObject: object)
        let owner = CalendarReminderCoordinator(preferences: preferences(), storage: storage, notifications: Notifications())
        XCTAssertEqual(owner.profile.timing.followUp, .init(mode: .off, delay: 300))
        XCTAssertTrue(owner.enabled); XCTAssertEqual(owner.repository.states[id]?.skipped, true)
        XCTAssertEqual(owner.repository.states[id]?.override?.custom.followUp, .init(mode: .always, delay: 90))
        XCTAssertEqual(owner.repository.profile.schema, 2)
    }

    func testNativeForegroundSnoozeMountsWithoutCalendarBoundaryRefresh() async throws {
        let notifications = Notifications()
        var instant = now
        let owner = CalendarReminderCoordinator(preferences: preferences(), storage: Storage(), notifications: notifications, clock: { instant })
        owner.scene = { .init(visible: true) }
        var shown: [ReminderForegroundEvent] = []
        owner.onPresentation = { events in shown = events; return Set(events.map(\.id)) }
        await owner.setEnabled(true); owner.update(meetings: [meeting(offset: -121)], available: true)
        await owner.waitForReconciliation()
        let occurrence = try XCTUnwrap(owner.repository.occurrences.first)
        await owner.action(reference: occurrence.reference, snooze: true)
        let request = try XCTUnwrap(notifications.items.values.first { $0.plan.phase == .snooze })
        instant = request.plan.date
        owner.foregroundReminder(reference: occurrence.reference, requestID: request.plan.id, fingerprint: request.fingerprint)
        XCTAssertEqual(shown.first?.plan.phase, .snooze)
        XCTAssertNil(owner.repository.states[occurrence.id]?.snooze)
    }

    func testPermissionRevocationOnReturnCannotPresentUsingCachedPermission() async throws {
        let notifications = Notifications()
        let owner = CalendarReminderCoordinator(preferences: preferences(), storage: Storage(), notifications: notifications)
        var visible = true
        owner.scene = { .init(visible: visible, room: MeetingRoomIdentity(URL(string: "https://salutejazz.ru/calls/other")!, engine: .guest)) }
        var shown: [ReminderForegroundEvent] = []
        owner.onPresentation = { events in shown = events; return Set(events.map(\.id)) }
        await owner.setEnabled(true)
        visible = false; owner.backgrounded()
        owner.update(meetings: [meeting(offset: -121)], available: true); await owner.waitForReconciliation()
        notifications.permission = .denied; notifications.delayAuthorization = true
        visible = true; owner.foregrounded(); owner.refreshPresentation()
        XCTAssertTrue(shown.isEmpty)
        for _ in 0..<100 where notifications.authorizationContinuation == nil { await Task.yield() }
        notifications.authorizationContinuation?.resume(); notifications.authorizationContinuation = nil
        await owner.waitForReconciliation()
        XCTAssertEqual(owner.authorization, .denied); XCTAssertTrue(shown.isEmpty)
    }

    func testFailedNativeSnoozePreservesDetailsIntentInsteadOfSilentlyDisappearing() async throws {
        let notifications = Notifications(), storage = Storage()
        let owner = CalendarReminderCoordinator(preferences: preferences(), storage: storage, notifications: notifications)
        await owner.setEnabled(true); owner.update(meetings: [meeting()], available: true)
        await owner.waitForReconciliation()
        let occurrence = try XCTUnwrap(owner.repository.occurrences.first)
        notifications.failsAdd = true
        await owner.action(reference: occurrence.reference, snooze: true)
        XCTAssertNil(owner.repository.states[occurrence.id]?.snooze)
        XCTAssertEqual(owner.repository.pendingOpen, occurrence.reference)
    }

    func testLeavingAnEarlyJoinedRoomDuringItsScheduledIntervalRecordsAttendance() async throws {
        var instant = now
        let owner = CalendarReminderCoordinator(preferences: preferences(), storage: Storage(), notifications: Notifications(), clock: { instant })
        let event = meeting(offset: 30)
        var room = event.roomIdentity
        owner.scene = { .init(visible: true, room: room) }
        await owner.setEnabled(true); owner.update(meetings: [event], available: true); await owner.waitForReconciliation()
        let occurrence = try XCTUnwrap(owner.repository.occurrences.first)
        XCTAssertNotEqual(owner.repository.states[occurrence.id]?.attended, true)
        instant = instant.addingTimeInterval(35); room = nil; owner.refreshPresentation()
        XCTAssertEqual(owner.repository.states[occurrence.id]?.attended, true)
    }

    func testSceneAttendanceCancelsNativeRequestsAndFencesADelayedAdd() async throws {
        for delayed in [false, true] {
            let notifications = Notifications()
            let owner = CalendarReminderCoordinator(preferences: preferences(), storage: Storage(), notifications: notifications)
            var current = MeetingRoomIdentity(URL(string: "https://salutejazz.ru/calls/other")!, engine: .guest)
            owner.scene = { .init(visible: true, room: current) }
            var profile = owner.profile; profile.timing.followUp = .init(mode: .always, delay: 300); owner.setProfile(profile)
            await owner.setEnabled(true); await owner.waitForReconciliation()
            notifications.delayed = delayed
            let event = meeting(offset: -121)
            owner.update(meetings: [event], available: true)
            if delayed {
                for _ in 0..<100 where notifications.continuation == nil { await Task.yield() }
                XCTAssertNotNil(notifications.continuation)
            } else { await owner.waitForReconciliation(); XCTAssertEqual(notifications.items.count, 1) }
            current = event.roomIdentity; owner.refreshPresentation()
            notifications.delayed = false; notifications.continuation?.resume(); notifications.continuation = nil
            await owner.waitForReconciliation()
            XCTAssertTrue(notifications.items.isEmpty)
        }
    }

}
