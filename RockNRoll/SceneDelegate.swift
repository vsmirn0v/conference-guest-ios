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
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_LAYOUT_FIXTURE"] == "rock" {
            controller.present(RockCallViewController(title: "Open rehearsal",
                catchUp: model.catchUpStore, chat: model.chat), animated: false)
            return
        }
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_LAYOUT_FIXTURE"] == "notice" {
            controller.present(NoticeLayoutFixtureViewController(), animated: false)
            return
        }
        if let raw = ProcessInfo.processInfo.environment["CONFERENCE_TEST_INVITE"],
           let url = URL(string: raw) {
            model.testDisplayNameOverride = ProcessInfo.processInfo.environment["CONFERENCE_TEST_NAME"]
            model.receive(url: url)
            model.join()
            if let rawLinks = ProcessInfo.processInfo.environment["CONFERENCE_TEST_SWITCH_URLS"],
               let data = rawLinks.data(using: .utf8),
               let links = try? JSONDecoder().decode([URL].self, from: data),
               (1...4).contains(links.count) {
                Task { @MainActor in
                    var previousLink: String?
                    if ProcessInfo.processInfo.environment["CONFERENCE_TEST_SWITCH_MODE"] == "rapid" {
                        previousLink = model.invite
                        for link in links { model.receive(url: link) }
                    } else {
                        for link in links {
                            guard await self.waitForConnectedJam(model, after: previousLink) else {
                                print("Switch test: timed out before next link")
                                return
                            }
                            previousLink = model.invite
                            model.receive(url: link)
                        }
                    }
                    guard await self.waitForConnectedJam(model, after: previousLink) else {
                        print("Switch test: timed out before final join")
                        return
                    }
                    print("Switch test: all rooms connected")
                    model.testSwitchSequenceCompleted = true
                    model.leave()
                }
            }
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

    #if DEBUG
    @MainActor
    private func waitForConnectedJam(_ model: ConferenceModel, after previousLink: String?) async -> Bool {
        let deadline = Date().addingTimeInterval(75)
        while Date() < deadline {
            if let connected = model.connectedURL?.absoluteString,
               connected == model.invite,
               connected != previousLink { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }
    #endif
}
