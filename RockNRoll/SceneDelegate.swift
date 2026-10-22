import SwiftUI
import UIKit
import ConferenceCore

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var macMeeting: MacMeetingCoordinator?
    private var conference: ConferenceModel?
    #if DEBUG
    var meetingForTesting: ConferenceModel? { conference }
    var macMeetingForTesting: MacMeetingCoordinator? { macMeeting }
    private var presenterExperiment: MacPresenterQualification?
    private var previewExperiment: PreviewCadenceExperiment?
    #endif

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_RENDERER_RESET_PROBE"] == "1" {
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = RendererResetProbeViewController()
            window.makeKeyAndVisible(); self.window = window
            return
        }
        if let experiment = MacPresenterQualification.make(windowScene: windowScene) {
            presenterExperiment = experiment; window = experiment.window
            experiment.start()
            return
        }
        if let experiment = PreviewCadenceExperiment.make(windowScene: windowScene) {
            previewExperiment = experiment; window = experiment.window
            experiment.start()
            return
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_CLEAR_NAME"] == "1" {
            UserDefaults.standard.removeObject(forKey: "savedDisplayName")
        }
        #endif
        #if DEBUG
        CameraBackgroundTrace.start()
        let backgroundMeeting = BackgroundAudioJoinPrototype.shared.takePreparedForScene()
        let model = backgroundMeeting?.model ?? MeetingSetupUIFixture.makeModel() ?? CalendarUIFixture.makeModel() ?? RoomSyncUIFixture.makeModel()
        RoomSyncUIFixture.configure(model)
        MeetingContinuationUIFixture.configure(model)
        MeetingContinuationLiveFixture.configure(model)
        #else
        let model = ConferenceModel()
        #endif
        let hosting = UIHostingController(rootView: JoinView(model: model,
                                                            catchUp: model.catchUpStore,
                                                            history: model.history,
                                                            sync: model.sync,
                                                            continuation: model.continuation,
                                                            calendar: model.calendar,
                                                            setup: model.setup))
        #if DEBUG
        let controller = backgroundMeeting?.container ?? MeetingContainerViewController()
        #else
        let controller = MeetingContainerViewController()
        #endif
        controller.mountHome(hosting)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        self.conference = model
        model.configure(container: controller)
        model.registerMeetingUnderlay(hosting.view)
        #if DEBUG
        BackgroundAudioJoinPrototype.shared.attach(model, container: controller)
        #endif
        if ProcessInfo.processInfo.isiOSAppOnMac { macMeeting = MacMeetingCoordinator(model: model, window: window) }
        controller.canHideMeeting = { [weak self] in self?.macMeeting?.canHideMeeting == true }
        controller.hideMeeting = { [weak self] in self?.macMeeting?.hideMeeting() }

        #if DEBUG
        if RoomSyncLiveProbe.runIfRequested(window: window) { return }
        if configureFixtures(model: model, controller: controller, window: window) { return }
        #endif

        if let url = connectionOptions.urlContexts.first?.url {
            #if DEBUG
            BackgroundAudioJoinPrototype.shared.supersedeForForeground()
            #endif
            model.receive(url: url)
        } else if let activity = connectionOptions.userActivities.first {
            #if DEBUG
            BackgroundAudioJoinPrototype.shared.supersedeForForeground()
            #endif
            if !model.receiveContinuationActivity(activity), let url = activity.webpageURL { model.receive(url: url) }
        }
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if (environment.keys.contains { $0.hasPrefix("CONFERENCE_TEST_") } && environment["CONFERENCE_TEST_MEETING_SETUP"] == nil) ||
            NSClassFromString("XCTestCase") != nil { model.setup.suspendForMeeting() }
        #endif
        model.setup.finishLaunch(hasMeetingIntent: !connectionOptions.urlContexts.isEmpty || !connectionOptions.userActivities.isEmpty ||
            CalendarReminderBroker.shared.hasPendingIntent || model.calendar.reminders.hasOpenIntent)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        #if DEBUG
        BackgroundAudioJoinPrototype.shared.supersedeForForeground()
        #endif
        conference?.receive(url: url)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        #if DEBUG
        BackgroundAudioJoinPrototype.shared.supersedeForForeground()
        #endif
        if conference?.receiveContinuationActivity(userActivity) == true { return }
        guard let url = userActivity.webpageURL else { return }
        conference?.receive(url: url)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        #if DEBUG
        BackgroundAudioJoinPrototype.shared.foregrounded()
        #endif
        if !ProcessInfo.processInfo.isiOSAppOnMac { conference?.reminderVisibilityChanged(true) }
        conference?.meetingActivityForegrounded()
        macMeeting?.becameActive()
        conference?.calendarForegrounded()
        conference?.sync.foregrounded()
        conference?.continuation.setForeground(true)
        conference?.updateContinuationActivity()
        conference?.restoreFromFloatingVideo()
        conference?.resumeSystemCallIfPossible()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        conference?.reminderVisibilityChanged(false)
        conference?.calendar.backgrounded()
        conference?.prepareToFloat()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        conference?.continuation.setForeground(false)
        conference?.backgroundedWithoutFloatingVideo()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        conference?.reminderVisibilityChanged(false)
        macMeeting?.invalidate()
        macMeeting = nil
        #if DEBUG
        if let conference, BackgroundAudioJoinPrototype.shared.sceneDisconnected(conference) {
            window?.rootViewController = nil; window = nil
        }
        #endif
    }
}
