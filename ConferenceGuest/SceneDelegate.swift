import SwiftUI
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var conference: ConferenceModel?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let model = ConferenceModel()
        let controller = UIHostingController(rootView: JoinView(model: model))
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        self.conference = model
        model.configure(container: controller)

        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["CONFERENCE_TEST_INVITE"],
           let url = URL(string: raw) {
            model.displayName = ProcessInfo.processInfo.environment["CONFERENCE_TEST_NAME"] ?? "Conference Guest QA"
            model.receive(url: url)
            model.join()
            if let rawDelay = ProcessInfo.processInfo.environment["CONFERENCE_TEST_LEAVE_AFTER_SECONDS"],
               let delay = UInt64(rawDelay), (1...600).contains(delay) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    model.leave()
                }
            }
            return
        }
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
        conference?.resumeSystemCallIfPossible()
    }
}
