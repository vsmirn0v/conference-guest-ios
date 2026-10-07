#if DEBUG
import SwiftUI
import UIKit
import ConferenceCore

extension SceneDelegate {
    func configureFixtures(model: ConferenceModel, controller: UIViewController, window: UIWindow) -> Bool {
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_RESET_FLOATING_VIDEO"] == "1" {
            FloatingVideoPreference.enabled = true
        }
        if let fixture = ProcessInfo.processInfo.environment["CONFERENCE_TEST_UI_FIXTURE"] {
            if fixture == "mac-audio" {
                if ProcessInfo.processInfo.environment["CONFERENCE_TEST_MAC_AUDIO_VERIFY_DEFAULTS"] == "1" {
                    MacAudioLiveProbe.verifyCurrentDefaults()
                }
                let devices = ProcessInfo.processInfo.isiOSAppOnMac ? MacAudioDevices.shared
                    : MacAudioDevices(isMac: true, hardware: MacAudioFixtureHardware())
                window.rootViewController = UINavigationController(rootViewController: MacAudioDevicePicker(devices: devices))
                return true
            }
            if fixture == "pip-microphone" {
                window.rootViewController = PiPMicrophoneFixtureViewController()
                return true
            }
            if fixture == "speaker-pip" {
                window.rootViewController = SpeakerPiPFixtureViewController()
                return true
            }
            if fixture == "room-pip-energy" {
                window.rootViewController = RoomFloatingVideoFixture()
                return true
            }
            if fixture == "guest-call" {
                window.rootViewController = GuestCallLayoutFixture()
                return true
            }
            if fixture == "guest-color" {
                window.rootViewController = GuestColorFixtureViewController()
                return true
            }
            if fixture == "guest-zoom" {
                window.rootViewController = GuestStreamViewportFixtureViewController()
                return true
            }
            let invitation = URL(string: "https://rock.glowsoft.ru/jams/test")!
            if fixture == "ambiguous-link" {
                let marker = UUID().uuidString
                for host in ["meet-one.example.test", "meet-two.example.test"] {
                    model.history.record(url: URL(string: "https://\(host)/team/\(marker)?psw=fixture")!,
                        title: "Rehearsal", identifier: marker)
                }
                model.guestWebsiteOrigin = "https://meet-one.example.test"
                model.receive(url: URL(string: "jcp://jazz?code=\(marker)&psw=fixture")!)
                return true
            }
            if fixture == "home" {
                let marker = ProcessInfo.processInfo.environment["CONFERENCE_TEST_FIXTURE_ROOM_ID"] ?? "test"
                let savedURL = URL(string: "https://meeting.example.test/calls/\(marker)?psw=fixture")!
                model.history.record(url: savedURL, title: "Open rehearsal \(marker)", identifier: marker)
                if model.history.rooms.first(where: { $0.invitationURL == savedURL })?.isStarred == false {
                    model.history.toggleStar(savedURL)
                }
                return true
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
                return true
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
            return true
        }
        if let fixture = ProcessInfo.processInfo.environment["CONFERENCE_TEST_LAYOUT_FIXTURE"],
           fixture == "rock" || fixture == "local-share" {
            model.chat.canSend = true
            model.chat.onSend = { [weak chat = model.chat] message in
                chat?.append(ChatEntry(id: UUID().uuidString, sender: "You", text: message,
                                       sentAt: Date(), isOwn: true))
            }
            model.catchUpStore.enter(roomKey: "layout-fixture")
            model.catchUpStore.begin(.anotherCall)
            model.catchUpStore.end(.anotherCall)
            let call = RockCallViewController(title: "Open rehearsal",
                catchUp: model.catchUpStore, chat: model.chat)
            if ProcessInfo.processInfo.environment["CONFERENCE_TEST_SPEAKER"] == "1" {
                call.fixtureActions = SpeakerFixtureActions.make(call.activeSpeaker)
            }
            if ProcessInfo.processInfo.environment["CONFERENCE_TEST_STUDIO"] == "1" {
                let studio = StudioModel(audioControl: .fullProcessing, privateCamera: StudioCameraFixture(), privateMicrophone: StudioMicrophoneFixture())
                studio.applyProfile = { _ in }
                studio.soundCheck.verifyMuted = { [weak call] in call?.setMicrophone(false) }
                call.studio = studio
                if ProcessInfo.processInfo.environment["CONFERENCE_TEST_MIC_ACTIVITY"] == "1" {
                    call.fixtureActions = MicrophoneActivityFixture(activity: studio.microphoneActivity).actions
                }
                call.onCamera = { [weak call] in call?.setCamera($0) }
                call.onMicrophone = { [weak call, weak studio] in call?.setMicrophone($0); studio?.microphoneActivity.setStatus($0 ? .on : .muted) }
            }
            call.fixtureParticipants = [ParticipantStatus(id: "local", name: "Rock QA", isLocal: true,
                microphoneOn: false, cameraOn: false, screenShareOn: false, isSpeaking: false,
                videoKey: nil, shareKey: nil)]
            controller.present(call, animated: false)
            if fixture == "local-share" {
                call.localSharePreview.begin()
                call.localSharePreview.setForeground(false)
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180))
                call.localSharePreview.acceptThumbnail(renderer.image { context in
                    UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
                    NSString(string: "Shared rehearsal notes").draw(at: CGPoint(x: 18, y: 60),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 22), .foregroundColor: UIColor.white])
                })
                call.localSharePreview.setForeground(true)
                call.onShare = { [weak call] enabled in if !enabled { call?.localSharePreview.end() } }
                if ProcessInfo.processInfo.environment["CONFERENCE_TEST_MAC_PREVIEW_FRAMES"] == "1" {
                    var pixels: CVPixelBuffer?
                    CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
                    if let pixels {
                        CVPixelBufferLockBaseAddress(pixels, [])
                        if let base = CVPixelBufferGetBaseAddress(pixels) {
                            memset(base, 128, CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
                        }
                        CVPixelBufferUnlockBaseAddress(pixels, [])
                        Task { @MainActor [weak call] in
                            while let call, call.localSharePreview.active {
                                call.localSharePreview.accept(pixels)
                                try? await Task.sleep(nanoseconds: 500_000_000)
                            }
                        }
                    }
                }
            }
            return true
        }
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_LAYOUT_FIXTURE"] == "rock-unread" {
            model.catchUpStore.enter(roomKey: "https://rock.glowsoft.ru/jams/fixture")
            model.catchUpStore.begin(.anotherCall)
            model.catchUpStore.end(.anotherCall)
            model.chat.append(ChatEntry(id: "incoming", sender: "Ani", text: "Are you here?",
                                       sentAt: Date(), isOwn: false))
            controller.present(RockCallViewController(title: "Open rehearsal",
                catchUp: model.catchUpStore, chat: model.chat), animated: false)
            return true
        }
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_LAYOUT_FIXTURE"] == "notice" {
            controller.present(NoticeLayoutFixtureViewController(), animated: false)
            return true
        }
        if let raw = ProcessInfo.processInfo.environment["CONFERENCE_TEST_INVITE"],
           let url = URL(string: raw) {
            model.testDisplayNameOverride = ProcessInfo.processInfo.environment["CONFERENCE_TEST_NAME"]
            model.receive(url: url)
            model.join()
            if let rawLink = ProcessInfo.processInfo.environment["CONFERENCE_TEST_LINK_WHILE_ACTIVE"],
               let link = URL(string: rawLink) {
                Task { @MainActor in
                    guard await self.waitForConnectedJam(model, after: nil) else { return }
                    model.receive(url: link)
                }
            }
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
            return true
        }
        return false
    }

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
}
#endif
