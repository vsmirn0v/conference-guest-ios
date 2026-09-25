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
        if let fixture = ProcessInfo.processInfo.environment["CONFERENCE_TEST_UI_FIXTURE"] {
            if fixture == "guest-zoom" {
                window.rootViewController = GuestStreamViewportFixtureViewController()
                return
            }
            let invitation = URL(string: "https://rock.glowsoft.ru/jams/test")!
            if fixture == "home" {
                let marker = ProcessInfo.processInfo.environment["CONFERENCE_TEST_FIXTURE_ROOM_ID"] ?? "test"
                let savedURL = URL(string: "https://meeting.example.test/calls/\(marker)?psw=fixture")!
                model.history.record(url: savedURL, title: "Open rehearsal \(marker)", identifier: marker)
                if model.history.rooms.first(where: { $0.invitationURL == savedURL })?.isStarred == false {
                    model.history.toggleStar(savedURL)
                }
                return
            }
            if fixture == "participants" {
                let panel = ParticipantPanelViewController()
                panel.onPin = { _ in }
                panel.update([
                    ParticipantStatus(id: "local", name: "Musician", isLocal: true,
                                      microphoneOn: false, cameraOn: false, screenShareOn: false,
                                      isSpeaking: false, videoKey: nil, shareKey: nil),
                    ParticipantStatus(id: "remote", name: "Alexander Petrosyan — acoustic guitar",
                                      isLocal: false, microphoneOn: true, cameraOn: true,
                                      screenShareOn: true, isSpeaking: true, videoKey: "video", shareKey: "share")
                ], pinnedKey: "share")
                window.rootViewController = UINavigationController(rootViewController: panel)
                return
            }
            let chat = model.chat
            chat.canSend = fixture != "unavailable"
            chat.onSend = { [weak chat] message in
                chat?.append(ChatEntry(id: UUID().uuidString, sender: "You", text: message,
                                       sentAt: Date(), isOwn: true))
            }
            chat.onRetry = { [weak chat] entry in chat?.setDelivery(.sent, for: entry.id) }
            chat.replace([
                ChatEntry(id: "1", sender: "Ani", text: "Shall we start with the slower version today?",
                          sentAt: Date().addingTimeInterval(-200), isOwn: false),
                ChatEntry(id: "2", sender: "You", text: "I have the chords ready.",
                          sentAt: Date().addingTimeInterval(-180), isOwn: true),
                ChatEntry(id: "3", sender: "You", text: "I can bring the amplifier on Friday.",
                          sentAt: Date().addingTimeInterval(-150), isOwn: true, delivery: .failed),
                ChatEntry(id: "4", sender: "Alexander Petrosyan — acoustic guitar",
                          text: "Here is the arrangement: https://rock.glowsoft.ru/community",
                          sentAt: Date().addingTimeInterval(-100), isOwn: false)
            ])
            let store = model.catchUpStore
            store.enter(roomKey: "https://rock.glowsoft.ru/jams/fixture-\(UUID().uuidString)")
            store.begin(.anotherCall)
            store.observe(messages: [TranscriptSegment(id: "line", speaker: "Ani",
                text: "We will meet Friday at six thirty.", spokenAt: Date())],
                canView: fixture != "unavailable", enabled: fixture != "unavailable")
            store.end(.anotherCall)
            if fixture == "transcript" {
                let lines = (0..<30).map { index in
                    TranscriptSegment(id: "sample-\(index)", speaker: "Musician \(index % 3 + 1)",
                        text: "Rehearsal note \(index + 1): repeat the bridge after the guitar solo.",
                        spokenAt: Date().addingTimeInterval(Double(index - 30) * 15))
                }
                store.observe(messages: lines, canView: true, enabled: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    store.observe(messages: [TranscriptSegment(id: "new-live-line", speaker: "Ani",
                        text: "New line received while reading earlier notes.", spokenAt: Date())],
                        canView: true, enabled: true)
                }
            }
            let controls = CallWorkspaceControls()
            controls.invitationURL = invitation
            controls.roomIdentifier = "test"
            controls.toggleMicrophone = { controls.microphoneOn.toggle() }
            controls.toggleCamera = { controls.cameraOn.toggle() }
            controls.toggleSpeaker = { controls.speakerOn.toggle() }
            window.rootViewController = ConversationPanelViewController(catchUp: store, chat: chat,
                                                                         call: controls)
            return
        }
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_LAYOUT_FIXTURE"] == "rock" {
            controller.present(RockCallViewController(title: "Open rehearsal",
                catchUp: model.catchUpStore, chat: model.chat), animated: false)
            return
        }
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_LAYOUT_FIXTURE"] == "rock-unread" {
            model.catchUpStore.enter(roomKey: "https://rock.glowsoft.ru/jams/fixture")
            model.catchUpStore.begin(.anotherCall)
            model.catchUpStore.end(.anotherCall)
            model.chat.append(ChatEntry(id: "incoming", sender: "Ani", text: "Are you here?",
                                       sentAt: Date(), isOwn: false))
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
