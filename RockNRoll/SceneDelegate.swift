import SwiftUI
import UIKit
import ConferenceCore

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var conference: ConferenceModel?
    #if DEBUG
    var meetingForTesting: ConferenceModel? { conference }
    private var backgroundJoinFixture: BackgroundJoinDeviceFixture?
    #endif

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_COLD_JOIN_CLEANUP"] == "1" {
            let window = UIWindow(windowScene: windowScene)
            let controller = UIViewController()
            let label = UILabel(frame: CGRect(x: 30, y: 120, width: 300, height: 60))
            label.text = "Cleaning owned fixture"
            controller.view.addSubview(label); window.rootViewController = controller
            window.makeKeyAndVisible(); self.window = window
            Task { @MainActor in
                await ColdJoinDeviceFixture.cleanupIfRequested()
                label.text = ColdJoinDeviceFixture.cleanupSucceeded ? "cold-join-cleaned" : "cold-join-cleanup-failed"
            }
            return
        }
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_RENDERER_RESET_PROBE"] == "1" {
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = RendererResetProbeViewController()
            window.makeKeyAndVisible(); self.window = window
            return
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_CLEAR_NAME"] == "1" {
            UserDefaults.standard.removeObject(forKey: "savedDisplayName")
        }
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_RESET_BACKGROUND_EXPERIMENTS"] == "1" {
            UserDefaults.standard.removeObject(forKey: BackgroundAudioJoinPrototype.enabledKey)
            BackgroundAudioJoinPrototype.shared.preferencesChanged()
        }
        #endif
        let backgroundMeeting = BackgroundAudioJoinPrototype.shared.takePreparedForScene()
        #if DEBUG
        CameraBackgroundTrace.start()
        let model = backgroundMeeting?.model ?? RoomSyncUIFixture.makeBackgroundJoinModel() ?? MeetingSetupUIFixture.makeModel() ?? CalendarUIFixture.makeModel() ?? RoomSyncUIFixture.makeModel()
        RoomSyncUIFixture.configure(model)
        MeetingContinuationUIFixture.configure(model)
        MeetingContinuationLiveFixture.configure(model)
        #else
        let model = backgroundMeeting?.model ?? ConferenceModel()
        #endif
        let hosting = UIHostingController(rootView: JoinView(model: model,
                                                            catchUp: model.catchUpStore,
                                                            history: model.history,
                                                            sync: model.sync,
                                                            continuation: model.continuation,
                                                            calendar: model.calendar,
                                                            setup: model.setup))
        let controller = backgroundMeeting?.container ?? MeetingContainerViewController()
        controller.mountHome(hosting)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        self.conference = model
        model.configure(container: controller)
        model.registerMeetingUnderlay(hosting.view)
        BackgroundAudioJoinPrototype.shared.attach(model, container: controller)

        #if DEBUG
        ColdJoinDeviceFixture.prepareIfRequested(model: model)
        backgroundJoinFixture = BackgroundJoinDeviceFixture.make(model: model, window: window)
        if RoomSyncLiveProbe.runIfRequested(window: window) { return }
        if configureFixtures(model: model, controller: controller, window: window) { return }
        #endif

        if let url = connectionOptions.urlContexts.first?.url {
            BackgroundAudioJoinPrototype.shared.supersedeForForeground()
            model.receive(url: url)
        } else if let activity = connectionOptions.userActivities.first {
            BackgroundAudioJoinPrototype.shared.supersedeForForeground()
            if !model.receiveContinuationActivity(activity), let url = activity.webpageURL { model.receive(url: url) }
        }
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if !ColdJoinDeviceFixture.active &&
            ((environment.keys.contains { $0.hasPrefix("CONFERENCE_TEST_") } && environment["CONFERENCE_TEST_MEETING_SETUP"] == nil) ||
             NSClassFromString("XCTestCase") != nil) { model.setup.suspendForMeeting() }
        #endif
        model.setup.finishLaunch(hasMeetingIntent: !connectionOptions.urlContexts.isEmpty || !connectionOptions.userActivities.isEmpty ||
            CalendarReminderBroker.shared.hasPendingIntent || model.calendar.reminders.hasOpenIntent)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        BackgroundAudioJoinPrototype.shared.supersedeForForeground()
        conference?.receive(url: url)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        BackgroundAudioJoinPrototype.shared.supersedeForForeground()
        if conference?.receiveContinuationActivity(userActivity) == true { return }
        guard let url = userActivity.webpageURL else { return }
        conference?.receive(url: url)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        BackgroundAudioJoinPrototype.shared.foregrounded()
        #if DEBUG
        backgroundJoinFixture?.foregrounded()
        #endif
        conference?.reminderVisibilityChanged(true)
        conference?.meetingActivityForegrounded()
        conference?.calendarForegrounded()
        conference?.sync.foregrounded()
        conference?.workspace.scheduleSync(delayMilliseconds: 250)
        conference?.continuation.setForeground(true)
        conference?.updateContinuationActivity()
        conference?.restoreFromFloatingVideo()
        conference?.resumeSystemCallIfPossible()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        conference?.reminderVisibilityChanged(false)
        conference?.calendar.backgrounded()
        conference?.prepareToFloat()
        if let workspace = conference?.workspace {
            Task { await workspace.flushNotesNow() }
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        conference?.continuation.setForeground(false)
        conference?.backgroundedWithoutFloatingVideo()
        if let workspace = conference?.workspace {
            Task { await workspace.flushNotesNow() }
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        conference?.reminderVisibilityChanged(false)
        if let conference, BackgroundAudioJoinPrototype.shared.sceneDisconnected(conference) {
            window?.rootViewController = nil; window = nil
        }
    }
}
