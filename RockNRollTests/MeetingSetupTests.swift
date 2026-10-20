import ConferenceCore
import XCTest
@testable import RockNRoll

@MainActor final class MeetingSetupTests: XCTestCase {
    private func preferences() -> UserDefaults { UserDefaults(suiteName: "MeetingSetupTests." + UUID().uuidString)! }
    func testLaunchRoutingAndIdleHomeAreRequiredBeforeOffering() {
        let setup = MeetingSetupCoordinator(preferences: preferences())
        XCTAssertTrue(setup.blocksAutomaticJoin)
        setup.offerIfAppropriate(true); XCTAssertFalse(setup.isPresented)
        setup.finishLaunch(hasMeetingIntent: false)
        setup.offerIfAppropriate(false); XCTAssertFalse(setup.isPresented)
        setup.offerIfAppropriate(true); XCTAssertTrue(setup.isPresented)
    }
    func testAdvanceBackAndRelaunchRetainProgressWithoutCompleting() {
        let prefs = preferences(), setup = MeetingSetupCoordinator(preferences: prefs)
        setup.begin(); setup.next(); setup.next(); setup.back()
        XCTAssertEqual(setup.step, .reminders)
        let restored = MeetingSetupCoordinator(preferences: prefs)
        restored.finishLaunch(hasMeetingIntent: false); restored.offerIfAppropriate(true)
        XCTAssertTrue(restored.isPresented); XCTAssertEqual(restored.step, .reminders)
        XCTAssertFalse(restored.completed)
    }
    func testFinishLaterIsNotAnAutomaticOfferOnRelaunchAndSettingsResumes() {
        let prefs = preferences(), setup = MeetingSetupCoordinator(preferences: prefs)
        setup.begin(); setup.next(); setup.finishLater()
        let restored = MeetingSetupCoordinator(preferences: prefs)
        restored.finishLaunch(hasMeetingIntent: false); restored.offerIfAppropriate(true)
        XCTAssertFalse(restored.isPresented); XCTAssertFalse(restored.blocksAutomaticJoin)
        restored.begin(); XCTAssertEqual(restored.step, .reminders)
    }
    func testFinishAndReplayDoNotRestartAutomaticOnboarding() {
        let prefs = preferences(), setup = MeetingSetupCoordinator(preferences: prefs)
        setup.begin(); setup.next(); setup.next(); setup.next()
        XCTAssertTrue(setup.completed); XCTAssertFalse(setup.isPresented)
        let restored = MeetingSetupCoordinator(preferences: prefs)
        restored.finishLaunch(hasMeetingIntent: false); restored.offerIfAppropriate(true)
        XCTAssertFalse(restored.isPresented)
        restored.begin(); XCTAssertEqual(restored.step, .calendar); XCTAssertFalse(restored.completed)
        restored.next(); restored.finishLater()
        let replay = MeetingSetupCoordinator(preferences: prefs)
        replay.begin(); XCTAssertEqual(replay.step, .reminders)
    }
    func testInvitationSuspendsWithoutDeferringProgressAndWinsThatLaunch() {
        let prefs = preferences(), setup = MeetingSetupCoordinator(preferences: prefs)
        setup.begin(); setup.next(); let generation = setup.intentGeneration
        setup.suspendForMeeting(); XCTAssertGreaterThan(setup.intentGeneration, generation)
        setup.finishLaunch(hasMeetingIntent: false); setup.offerIfAppropriate(true)
        XCTAssertFalse(setup.isPresented)
        let restored = MeetingSetupCoordinator(preferences: prefs)
        restored.finishLaunch(hasMeetingIntent: false); restored.offerIfAppropriate(true)
        XCTAssertTrue(restored.isPresented); XCTAssertEqual(restored.step, .reminders)
    }
    func testColdMeetingIntentNeverShowsSetup() {
        let setup = MeetingSetupCoordinator(preferences: preferences())
        setup.finishLaunch(hasMeetingIntent: true); setup.offerIfAppropriate(true)
        XCTAssertFalse(setup.isPresented)
    }
    func testUnknownOrCorruptProgressDoesNotPopupOrOverwrite() {
        for data in [Data("unreadable".utf8), Data(#"{"version":99,"step":0,"completed":false,"deferred":false}"#.utf8)] {
            let prefs = preferences(); prefs.set(data, forKey: MeetingSetupCoordinator.progressKey)
            let setup = MeetingSetupCoordinator(preferences: prefs)
            setup.finishLaunch(hasMeetingIntent: false); setup.offerIfAppropriate(true); XCTAssertFalse(setup.isPresented)
            setup.begin(); setup.next(); setup.finishLater()
            XCTAssertEqual(prefs.data(forKey: MeetingSetupCoordinator.progressKey), data)
        }
    }
    func testNavigationDoesNotEnableFeaturesOrResetExistingSettings() {
        let model = MeetingSetupUIFixture.model(preferences: preferences())
        model.calendar.setAutomaticJoin(true)
        var profile = ReminderProfile(); profile.timing.before = 90; profile.timing.atStart = true
        model.calendar.reminders.setProfile(profile)
        model.setup.begin(); model.setup.next(); model.setup.next(); model.setup.next()
        XCTAssertFalse(model.calendar.enabled); XCTAssertTrue(model.calendar.automaticJoin)
        XCTAssertFalse(model.calendar.reminders.enabled); XCTAssertEqual(model.calendar.reminders.profile, profile)
        XCTAssertFalse(model.sync.enabled)
    }
    func testSetupRetiresLegacyOfferAndMeetingIntentSuspendsIt() {
        let prefs = preferences(), model = MeetingSetupUIFixture.model(preferences: prefs)
        model.setup.begin(); model.setup.next(); model.setup.next()
        XCTAssertTrue(prefs.bool(forKey: "iCloudSyncOfferSeen"))
        model.setup.back()
        model.setup.presentationDidMount()
        model.receive(url: URL(string: "https://salutejazz.ru/calls/setup?psw=fixture")!)
        XCTAssertFalse(model.setup.isPresented); XCTAssertEqual(model.setup.step, .reminders)
        XCTAssertTrue(model.invite.isEmpty)
        model.setup.presentationDidDismiss()
        XCTAssertTrue(model.invite.contains("setup"))
    }
    func testOnlyNewestMeetingIntentRunsAfterTheWholeSetupSheetDismisses() {
        let setup = MeetingSetupCoordinator(preferences: preferences())
        var actions: [Int] = []
        setup.begin(); setup.next(); setup.presentationDidMount()
        setup.performMeetingIntent { actions.append(1) }
        setup.performMeetingIntent { actions.append(2) }
        XCTAssertTrue(actions.isEmpty); XCTAssertFalse(setup.isPresented)
        XCTAssertTrue(setup.blocksAutomaticJoin)
        setup.presentationDidDismiss(); XCTAssertEqual(actions, [2])
        setup.presentationDidDismiss(); XCTAssertEqual(actions, [2])
        setup.performMeetingIntent { actions.append(3) }; XCTAssertEqual(actions, [2, 3])
    }
    func testSameTurnBeginAndMeetingCannotWaitForAnUnmountedSheet() {
        let setup = MeetingSetupCoordinator(preferences: preferences())
        var ran = false
        setup.begin(); setup.performMeetingIntent { ran = true }
        XCTAssertTrue(ran); XCTAssertFalse(setup.isPresented); XCTAssertFalse(setup.needsDismissal)
    }
    func testOnboardingLeavesInitialFeatureDefaultsOff() {
        let model = MeetingSetupUIFixture.model(preferences: preferences())
        model.setup.begin()
        XCTAssertFalse(model.calendar.enabled); XCTAssertFalse(model.calendar.automaticJoin)
        XCTAssertFalse(model.calendar.reminders.enabled); XCTAssertFalse(model.sync.enabled)
        XCTAssertEqual(model.calendar.reminders.profile, ReminderProfile())
        XCTAssertTrue(model.calendar.selected.isEmpty)
    }
    func testPermissionRequestOccursOnlyOnExplicitEnable() async {
        let prefs = preferences(), notifications = MeetingSetupUIFixture.Notifications(denied: false)
        let reminders = CalendarReminderCoordinator(preferences: prefs, storage: MeetingSetupUIFixture.Storage(prefs, "notifications"), notifications: notifications)
        reminders.foregrounded()
        await reminders.waitForReconciliation()
        XCTAssertEqual(notifications.requests, 0)
        await reminders.setEnabled(true)
        XCTAssertEqual(notifications.requests, 1); XCTAssertEqual(reminders.authorization, .allowed)
    }
}
