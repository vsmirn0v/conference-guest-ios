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
    func restoreMacMeetingForTesting() {
        guard let conference, let window else { return }
        macMeeting = MacMeetingCoordinator(model: conference, window: window)
    }
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
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_RESET_BACKGROUND_EXPERIMENTS"] == "1" {
            UserDefaults.standard.removeObject(forKey: BackgroundExperimentPreferences.audioJoinKey)
            UserDefaults.standard.removeObject(forKey: BackgroundExperimentPreferences.firstPiPKey)
            BackgroundAudioJoinPrototype.shared.preferencesChanged()
        }
        #endif
        let backgroundMeeting = BackgroundAudioJoinPrototype.shared.takePreparedForScene()
        #if DEBUG
        CameraBackgroundTrace.start()
        let model = backgroundMeeting?.model ?? MeetingSetupUIFixture.makeModel() ?? CalendarUIFixture.makeModel() ?? RoomSyncUIFixture.makeModel()
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
        if ProcessInfo.processInfo.isiOSAppOnMac { macMeeting = MacMeetingCoordinator(model: model, window: window) }
        controller.canHideMeeting = { [weak self] in self?.macMeeting?.canHideMeeting == true }
        controller.hideMeeting = { [weak self] in self?.macMeeting?.hideMeeting() }

        #if DEBUG
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
        if (environment.keys.contains { $0.hasPrefix("CONFERENCE_TEST_") } && environment["CONFERENCE_TEST_MEETING_SETUP"] == nil) ||
            NSClassFromString("XCTestCase") != nil { model.setup.suspendForMeeting() }
        #endif
        model.setup.finishLaunch(hasMeetingIntent: !connectionOptions.urlContexts.isEmpty || !connectionOptions.userActivities.isEmpty ||
            CalendarReminderBroker.shared.hasPendingIntent || model.calendar.reminders.hasOpenIntent)
        #if DEBUG
        if CalendarUIFixture.mode == "mac-idle-schedule" { qualifyIdleScheduling(model) }
        #endif
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
        if let conference, BackgroundAudioJoinPrototype.shared.sceneDisconnected(conference) {
            window?.rootViewController = nil; window = nil
        }
    }
    #if DEBUG
    private func qualifyIdleScheduling(_ model: ConferenceModel) {
        guard ProcessInfo.processInfo.isiOSAppOnMac else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rock-mac-idle-calendar-qa.json")
        func record(_ values: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: file, options: .atomic)
                FileHandle.standardError.write(data + Data("\n".utf8))
            }
            NSLog("MAC_IDLE_QUALIFICATION %@", file.path)
        }
        model.setup.suspendForMeeting()
        model.calendar.canAutomaticallyJoin = { _ in true }
        let fresh = !MacCallActivity.shared.hasActivityForTesting && NSClassFromString("XCTestCase") == nil
        var frontmost: Int?
        model.calendar.onScheduledJoin = { [weak self, weak model] meeting in
            guard let model else { return }
            let state = self?.macMeeting?.stateForTesting ?? [:]
            model.calendar.finishScheduledTransportPreparation()
            record(["stage": "completed", "freshWithoutMediaOrXCTest": fresh,
                "latenessSeconds": Date().timeIntervalSince(meeting.start), "hidden": state["hidden"] as? Bool ?? false,
                "frontmostUnchanged": frontmost == state["frontmostPID"] as? Int,
                "graphicsActivity": MacCallActivity.shared.hasActivityForTesting,
                "pid": getpid(), "schedulingAvailable": state["schedulingAvailable"] as? Bool ?? false])
        }
        Task { @MainActor [weak self] in
            for _ in 0..<30 {
                guard let self, let desktop = self.macMeeting else { return }
                desktop.becameActive()
                if desktop.canHideMeeting {
                    desktop.closeForTesting()
                    model.calendar.backgrounded()
                    try? await Task.sleep(for: .milliseconds(300))
                    frontmost = desktop.stateForTesting["frontmostPID"] as? Int
                    record(["stage": "armed", "freshWithoutMediaOrXCTest": fresh, "pid": getpid(),
                        "hidden": desktop.stateForTesting["hidden"] as? Bool ?? false,
                        "frontmostPID": frontmost ?? 0])
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            record(["stage": "failed-binding", "pid": getpid()])
        }
    }
    #endif
}
