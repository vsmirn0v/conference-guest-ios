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
        let model = ConferenceModel()
        let hosting = UIHostingController(rootView: JoinView(model: model,
                                                            catchUp: model.catchUpStore,
                                                            history: model.history))
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
        if configureFixtures(model: model, controller: controller, window: window) { return }
        #endif

        if let url = connectionOptions.urlContexts.first?.url {
            model.receive(url: url)
        } else if let url = connectionOptions.userActivities.first?.webpageURL {
            model.receive(url: url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        conference?.receive(url: url)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard let url = userActivity.webpageURL else { return }
        conference?.receive(url: url)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        conference?.restoreFromFloatingVideo()
        conference?.resumeSystemCallIfPossible()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        conference?.prepareToFloat()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        conference?.backgroundedWithoutFloatingVideo()
    }

}
