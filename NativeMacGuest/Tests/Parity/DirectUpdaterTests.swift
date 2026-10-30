#if NATIVE_DIRECT_UPDATES
import AppKit
import ConferenceCore
import Sparkle
import XCTest
@testable import RockNativeDesktop

private final class DirectUpdaterStorage: RoomHistoryStorage, ReminderStorage, @unchecked Sendable {
    var value: Data?
    func read() -> Data? { value }
    func write(_ data: Data) throws { value = data }
}
private actor DirectUpdaterCalendar: CalendarReading {
    func access() -> CalendarAccess { .notDetermined }
    func requestAccess() -> Bool { false }
    func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) -> CalendarSnapshot {
        .init(calendars: [], meetings: [])
    }
}
@MainActor private final class DirectUpdaterNotifications: ReminderNotifying {
    func authorization() async -> ReminderAuthorization { .notDetermined }
    func request(sensitive: Bool) async throws -> Bool { false }
    func pending() async -> [String: String] { [:] }
    func add(_ reminder: ReminderNotification) async throws {}
    func removePending(_ ids: [String]) {}
    func removeDelivered(occurrenceIDs: Set<String>) async {}
    func removeAllDelivered() async {}
}

/// Calls the actual Sparkle delegate and owner methods without starting SPUUpdater,
/// displaying the standard driver, checking a feed, or invoking an installer block.
@MainActor final class DirectUpdaterTests: XCTestCase {
    @MainActor private struct Fixture {
        let safety: NativeUpdateSafety
        let updates: NativeDesktopUpdates
        let directory: URL
        var fenceExists: Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(NativeUpdateSafety.fenceFileName).path)
        }
    }
    private let failure = NSError(domain: "DirectUpdaterTests", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Fixture updater failure"])

    private func fixture(recovery: Bool = false, mediaGate: NativeDesktopUpdateMediaGate? = nil) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("direct-updater-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        if recovery {
            let original = try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100)
            try original.prepareUpdate(targetBuild: 101)
        }
        let safety = try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100)
        let mediaGate = mediaGate ?? .init(claimIfDrained: { _ in true }, drain: { _ in true }, release: { _ in })
        return Fixture(safety: safety, updates: NativeDesktopUpdates(safety: safety, mediaGate: mediaGate), directory: directory)
    }

    private func item(_ version: String = "101") throws -> SUAppcastItem {
        // This public initializer is deprecated only for system/application-dependent
        // properties; these fixtures use its documented version/enclosure fields.
        try XCTUnwrap(SUAppcastItem(dictionary: [
            "sparkle:version": version,
            "enclosure": ["url": "https://example.test/RockNRoll-\(version).dmg",
                          "length": "1", "sparkle:version": version]
        ]))
    }

    private func begin(_ fixture: Fixture, check: SPUUpdateCheck = .updates) throws {
        try fixture.updates.updater(fixture.updates.updater, mayPerform: check)
    }

    private func prepare(_ fixture: Fixture) throws -> SUAppcastItem {
        try begin(fixture)
        let item = try item()
        XCTAssertTrue(fixture.updates.prepareChoice(item))
        XCTAssertTrue(fixture.fenceExists)
        return item
    }

    func testFinalSparkleRelaunchDelegateVetoesBusyMeetingAndReservesBeforeAllowing() throws {
        let fixture = try fixture(), updates = fixture.updates
        var busy = true; updates.busy = { busy }
        _ = try prepare(fixture)
        XCTAssertFalse(updates.updaterShouldRelaunchApplication(updates.updater))
        XCTAssertFalse(fixture.safety.installationReserved)
        XCTAssertTrue(updates.mayStartMeeting)
        busy = false
        XCTAssertTrue(updates.updaterShouldRelaunchApplication(updates.updater))
        XCTAssertTrue(fixture.safety.installationReserved)
        XCTAssertFalse(updates.mayStartMeeting)
    }

    func testActualDelegateReservationBlocksManualCalendarAndContinuationAdmission() throws {
        let fixture = try fixture(), updates = fixture.updates
        updates.busy = { false }
        _ = try prepare(fixture)
        let domain = "direct-updater-workspace-\(UUID())", preferences = UserDefaults(suiteName: domain)!
        addTeardownBlock { preferences.removePersistentDomain(forName: domain) }
        let reminders = CalendarReminderCoordinator(preferences: preferences, storage: DirectUpdaterStorage(),
                                                     notifications: DirectUpdaterNotifications())
        let calendar = CalendarMeetingStore(reader: DirectUpdaterCalendar(), detector: MeetingEngineDetector(serviceName: "unused"),
            preferences: preferences, storage: DirectUpdaterStorage(), reminders: reminders, isMac: true)
        let library = NativeDesktopLibrary(preferences: preferences,
            history: RoomHistoryStore(storage: DirectUpdaterStorage()), syncStorage: DirectUpdaterStorage(), calendar: calendar)
        library.displayName = "Updater fixture"; library.setup.suspendForMeeting()
        var detections = 0
        let workspace = NativeDesktopWorkspace(library: library, detect: { url in
            detections += 1; return .verified(.guest(endpoint: url))
        })
        workspace.mayAdmitMeeting = { updates.mayStartMeeting }
        updates.busy = { workspace.busyForUpdate }
        XCTAssertTrue(library.canAutomaticallyJoin())
        XCTAssertTrue(updates.updaterShouldRelaunchApplication(updates.updater))
        let url = URL(string: "https://example.test/calls/update-fence")!
        workspace.join(url)
        XCTAssertFalse(library.canAutomaticallyJoin())
        let jam = ActiveJam(deviceID: "phone", sessionID: UUID(), invitation: url,
            title: "Fixture", name: "Fixture", deviceLabel: "Phone")
        XCTAssertNil(library.continuation.onJoinTarget?(jam, false))
        XCTAssertEqual(detections, 0)
        XCTAssertFalse(workspace.preparing)
        XCTAssertNil(workspace.meeting)
        XCTAssertTrue(library.recent.isEmpty)
    }

    func testPostStage2ErrorFinishAndTerminationKeepReservationAndDurableFence() throws {
        let fixture = try fixture(), updates = fixture.updates
        updates.busy = { false }
        let item = try prepare(fixture)
        updates.updater(updates.updater, willExtractUpdate: item)
        XCTAssertTrue(updates.updaterShouldRelaunchApplication(updates.updater))
        updates.updater(updates.updater, willInstallUpdate: item)
        updates.updater(updates.updater, didAbortWithError: failure)
        updates.updater(updates.updater, didFinishUpdateCycleFor: .updates, error: failure)
        updates.willTerminate()
        XCTAssertTrue(fixture.safety.installationReserved)
        XCTAssertFalse(updates.mayStartMeeting)
        XCTAssertTrue(fixture.fenceExists)
        XCTAssertThrowsError(try begin(fixture), "A new cycle cannot reopen admission after stage 2")
    }

    func testPreStage2AbortReleasesOnlyCurrentProcessReservationAndRetainsExtractedFence() throws {
        let fixture = try fixture(), updates = fixture.updates
        updates.busy = { false }
        let item = try prepare(fixture)
        updates.updater(updates.updater, willExtractUpdate: item)
        XCTAssertTrue(updates.updaterShouldRelaunchApplication(updates.updater))
        updates.updater(updates.updater, didAbortWithError: failure)
        updates.updater(updates.updater, didFinishUpdateCycleFor: .updates, error: failure)
        XCTAssertFalse(fixture.safety.installationReserved)
        XCTAssertTrue(updates.mayStartMeeting)
        XCTAssertTrue(fixture.fenceExists)
        XCTAssertFalse(updates.updaterShouldRelaunchApplication(updates.updater))
    }

    func testLateInstallerCallbacksAfterAbortCannotReserveOrSurviveNewCycle() async throws {
        let fixture = try fixture(), updates = fixture.updates
        updates.busy = { false }
        let item = try prepare(fixture)
        updates.updater(updates.updater, willExtractUpdate: item)
        updates.updater(updates.updater, didAbortWithError: failure)
        updates.updater(updates.updater, didFinishUpdateCycleFor: .updates, error: failure)
        var replies = 0, installerBlocks = 0
        updates.installChoice(.install) { _ in replies += 1 }
        _ = updates.updater(updates.updater, willInstallUpdateOnQuit: item,
                            immediateInstallationBlock: { installerBlocks += 1 })
        XCTAssertFalse(updates.updaterShouldRelaunchApplication(updates.updater))
        XCTAssertFalse(updates.prepareChoice(item), "A stale UI choice cannot rearm a completed cycle")
        XCTAssertThrowsError(try updates.updater(updates.updater, shouldProceedWithUpdate: item, updateCheck: .updates))
        updates.activityChanged()
        await Task.yield()
        XCTAssertEqual(replies, 0)
        XCTAssertEqual(installerBlocks, 0)
        XCTAssertFalse(fixture.safety.installationReserved)
        try begin(fixture, check: .updatesInBackground)
        XCTAssertTrue(updates.prepareChoice(item))
        updates.activityChanged()
        await Task.yield()
        XCTAssertEqual(replies, 0)
        XCTAssertEqual(installerBlocks, 0)
        XCTAssertFalse(fixture.safety.installationReserved)
    }
    func testAbortBeforeQueuedMediaDrainCannotCreateALateSuspension() async throws {
        var drains = 0, replies = 0
        let fixture = try fixture(mediaGate: .init(claimIfDrained: { _ in false }, drain: { _ in drains += 1; return true }, release: { _ in }))
        let updates = fixture.updates; updates.busy = { false }
        _ = try prepare(fixture)
        updates.installChoice(.install) { _ in replies += 1 }
        updates.updater(updates.updater, didAbortWithError: failure)
        updates.updater(updates.updater, didFinishUpdateCycleFor: .updates, error: failure)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(drains, 0); XCTAssertEqual(replies, 0)
        XCTAssertFalse(fixture.safety.installationReserved)
    }
    func testAbortRetainsPendingDrainUntilCompletionAndReleasesOnlyItsEpoch() async throws {
        var pending: CheckedContinuation<Void, Never>?, drainingID: UUID?, heldID: UUID?
        var replies = 0, mayClaim = false
        let fixture = try fixture(mediaGate: .init(claimIfDrained: { id in
            guard mayClaim else { return false }; heldID = id; return true
        }, drain: { id in
            drainingID = id; heldID = id
            await withCheckedContinuation { pending = $0 }; return true
        }, release: { id in if heldID == id { heldID = nil } }))
        let updates = fixture.updates; updates.busy = { false }
        _ = try prepare(fixture)
        updates.installChoice(.install) { _ in replies += 1 }
        for _ in 0..<100 { if pending != nil { break }; await Task.yield() }
        XCTAssertNotNil(pending)
        updates.updater(updates.updater, didAbortWithError: failure)
        updates.updater(updates.updater, didFinishUpdateCycleFor: .updates, error: failure)
        XCTAssertEqual(heldID, drainingID, "Cancellation cannot release a native operation that is still draining")
        mayClaim = true; _ = try prepare(fixture)
        updates.installChoice(.install) { _ in replies += 1 }
        let freshID = heldID
        XCTAssertNotEqual(freshID, drainingID)
        pending?.resume(); pending = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(heldID, freshID, "An old drain completion cannot release a newer update reservation")
        XCTAssertEqual(replies, 1); XCTAssertTrue(fixture.safety.installationReserved)
    }

    func testHeldInstallReplyFromAbortedCycleDoesNotReserveNextCycle() throws {
        let fixture = try fixture(), updates = fixture.updates
        var busy = true; updates.busy = { busy }
        let item = try prepare(fixture)
        var oldReplies = 0, freshReplies = 0
        updates.installChoice(.install) { _ in oldReplies += 1 }
        XCTAssertEqual(oldReplies, 0)
        updates.updater(updates.updater, didAbortWithError: failure)
        updates.updater(updates.updater, didFinishUpdateCycleFor: .updates, error: failure)
        try begin(fixture)
        XCTAssertTrue(updates.prepareChoice(item))
        busy = false; updates.activityChanged()
        XCTAssertEqual(oldReplies, 0)
        XCTAssertFalse(fixture.safety.installationReserved)
        updates.installChoice(.install) { _ in freshReplies += 1 }
        XCTAssertEqual(freshReplies, 1)
        XCTAssertEqual(oldReplies, 0)
        XCTAssertTrue(fixture.safety.installationReserved)
    }

    func testDeferredActionsStopDrainingWhenFirstActionAdmitsMeeting() throws {
        let fixture = try fixture(), updates = fixture.updates
        try begin(fixture)
        var busy = true, actions: [Int] = []
        updates.busy = { busy }
        updates.showWhenIdle { actions.append(1); busy = true }
        updates.showWhenIdle { actions.append(2) }
        updates.showWhenIdle { actions.append(3) }
        busy = false; updates.activityChanged()
        XCTAssertEqual(actions, [1])
        busy = false; updates.activityChanged()
        XCTAssertEqual(actions, [1, 2, 3])
    }

    func testDeferredActionsStopDrainingWhenFirstActionReservesInstaller() throws {
        let fixture = try fixture(), updates = fixture.updates
        _ = try prepare(fixture)
        var busy = true, actions: [Int] = []
        updates.busy = { busy }
        updates.showWhenIdle {
            actions.append(1)
            XCTAssertTrue(updates.updaterShouldRelaunchApplication(updates.updater))
        }
        updates.showWhenIdle { actions.append(2) }
        busy = false; updates.activityChanged(); updates.activityChanged()
        XCTAssertEqual(actions, [1])
        XCTAssertTrue(fixture.safety.installationReserved)
    }

    func testAbortDiscardsDeferredPresentationsAndHeldInstallBlocks() async throws {
        let fixture = try fixture(), updates = fixture.updates
        var busy = true; updates.busy = { busy }
        let item = try prepare(fixture)
        var presentations = 0, installerBlocks = 0
        updates.showWhenIdle { presentations += 1 }
        _ = updates.updater(updates.updater, willInstallUpdateOnQuit: item,
                            immediateInstallationBlock: { installerBlocks += 1 })
        updates.updater(updates.updater, didAbortWithError: failure)
        updates.updater(updates.updater, didFinishUpdateCycleFor: .updates, error: failure)
        busy = false; updates.activityChanged()
        await Task.yield()
        XCTAssertEqual(presentations, 0)
        XCTAssertEqual(installerBlocks, 0)
        XCTAssertFalse(fixture.safety.installationReserved)
    }

    func testPendingInstallReservesBeforeReplyAndPreventsDeferredPresentationFlush() throws {
        let fixture = try fixture(), updates = fixture.updates
        var busy = true; updates.busy = { busy }
        _ = try prepare(fixture)
        var presentations = 0, replies = 0
        updates.showWhenIdle { presentations += 1 }
        updates.installChoice(.install) { choice in
            XCTAssertEqual(choice, .install)
            XCTAssertTrue(fixture.safety.installationReserved)
            XCTAssertFalse(updates.mayStartMeeting)
            replies += 1
        }
        busy = false; updates.activityChanged(); updates.activityChanged()
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(presentations, 0)
    }

    func testResumedUpdateUsesActualCycleAndPrepareGateWithoutAdmittingOldBuild() throws {
        let fixture = try fixture(recovery: true), updates = fixture.updates
        var busy = true; updates.busy = { busy }
        let item = try item()
        XCTAssertFalse(updates.mayStartMeeting)
        XCTAssertFalse(updates.prepareChoice(item), "Recovery alone must not authenticate a stale SDK cycle")
        try begin(fixture, check: .updatesInBackground)
        try updates.updater(updates.updater, shouldProceedWithUpdate: item, updateCheck: .updatesInBackground)
        XCTAssertFalse(updates.mayStartMeeting)
        XCTAssertTrue(fixture.fenceExists)
        XCTAssertFalse(updates.updaterShouldRelaunchApplication(updates.updater))
        busy = false
        XCTAssertTrue(updates.updaterShouldRelaunchApplication(updates.updater))
        XCTAssertFalse(updates.mayStartMeeting)
        updates.updater(updates.updater, didAbortWithError: failure)
        updates.updater(updates.updater, didFinishUpdateCycleFor: .updatesInBackground, error: failure)
        XCTAssertFalse(updates.mayStartMeeting)
        XCTAssertTrue(fixture.fenceExists)
        XCTAssertEqual(fixture.safety.recoveryTargetBuild, 101)
    }

    func testOnlyActiveCycleCanPrepareNumericNewBuild() throws {
        let fixture = try fixture(), updates = fixture.updates
        XCTAssertFalse(updates.prepareChoice(try item()))
        XCTAssertFalse(fixture.fenceExists)
        try begin(fixture)
        XCTAssertFalse(updates.prepareChoice(try item("release-101")))
        XCTAssertFalse(updates.prepareChoice(try item("100")))
        XCTAssertFalse(fixture.fenceExists)
        XCTAssertTrue(updates.mayStartMeeting)
        let item = try item()
        try updates.updater(updates.updater, shouldProceedWithUpdate: item, updateCheck: .updates)
        XCTAssertTrue(fixture.fenceExists)
        updates.updater(updates.updater, didFinishUpdateCycleFor: .updates, error: nil)
        XCTAssertFalse(fixture.fenceExists, "A normal pre-installer decline may retire its own fence")
        XCTAssertFalse(updates.prepareChoice(item))
    }

    func testNextCycleAndSuccessfulFinishClearStaleErrorWithoutClaimingCurrency() throws {
        let fixture = try fixture(), updates = fixture.updates
        let idleStatus = updates.status
        try begin(fixture)
        updates.updater(updates.updater, didAbortWithError: failure)
        updates.updater(updates.updater, didFinishUpdateCycleFor: .updates, error: failure)
        XCTAssertEqual(updates.status, failure.localizedDescription)
        try begin(fixture)
        XCTAssertEqual(updates.status, "Checking for updates…")
        updates.updater(updates.updater, didFinishUpdateCycleFor: .updates, error: nil)
        XCTAssertEqual(updates.status, idleStatus, "A completed cycle restores neutral status; it does not prove this build is current")
        XCTAssertTrue(updates.mayStartMeeting)
        XCTAssertFalse(fixture.fenceExists)
    }
}
#endif
