import SwiftUI
import UIKit
import ConferenceCore

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var conference: ConferenceModel?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_CLEAR_NAME"] == "1" {
            UserDefaults.standard.removeObject(forKey: "savedDisplayName")
        }
        #endif
        #if DEBUG
        let model = RoomSyncUIFixture.makeModel()
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
                                                            continuation: model.continuation))
        let controller = UIViewController()
        controller.addChild(hosting)
        controller.view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: controller.view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor)
        ])
        hosting.didMove(toParent: controller)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        self.conference = model
        model.configure(container: controller)

        #if DEBUG
        if RoomSyncLiveProbe.runIfRequested(window: window) { return }
        if configureFixtures(model: model, controller: controller, window: window) { return }
        #endif

        if let url = connectionOptions.urlContexts.first?.url {
            model.receive(url: url)
        } else if let activity = connectionOptions.userActivities.first {
            if !model.receiveContinuationActivity(activity), let url = activity.webpageURL { model.receive(url: url) }
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        conference?.receive(url: url)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if conference?.receiveContinuationActivity(userActivity) == true { return }
        guard let url = userActivity.webpageURL else { return }
        conference?.receive(url: url)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        conference?.sync.foregrounded()
        conference?.continuation.setForeground(true)
        conference?.updateContinuationActivity()
        conference?.restoreFromFloatingVideo()
        conference?.resumeSystemCallIfPossible()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        conference?.prepareToFloat()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        conference?.continuation.setForeground(false)
        conference?.backgroundedWithoutFloatingVideo()
    }

}
