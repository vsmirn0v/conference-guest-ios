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
            if fixture == "reminder-call" { window.rootViewController = ReminderCallFixture(); return true }
            if fixture == "meeting-activity", #available(iOS 16.2, *) {
                window.rootViewController = MeetingActivityFixture()
                return true
            }
            if fixture == "plain-zoom-control" {
                window.rootViewController = PlainZoomControl()
                return true
            }
            if fixture == "meeting-gallery" {
                window.rootViewController = MeetingGalleryFixture()
                return true
            }
            if fixture == "participant-badges" {
                window.rootViewController = ParticipantBadgeFixture()
                return true
            }
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
            if fixture == "reactions" || fixture == "reactions-unavailable" {
                chat.reactionHistoryAvailable = true
                if fixture == "reactions-unavailable" { chat.canSend = false }
                let history = chat.reactionHistory
                history.beginMeeting(id: UUID())
                for index in 0..<36 {
                    history.receive(kind: index % 3 == 0 ? .heart : .like, participantID: "ani",
                        displayName: "Ani", isOwn: false, receivedAt: Date().addingTimeInterval(Double(index - 36) * 12))
                }
                let time = Date()
                for index in 0..<3 {
                    history.receive(kind: .like, participantID: "ani", displayName: "Ani", isOwn: false,
                        receivedAt: time.addingTimeInterval(Double(index) * 0.1))
                }
            }
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
            if ProcessInfo.processInfo.environment["CONFERENCE_TEST_NATIVE_PICKERS"] == "1" {
                call.usesBroadcastPickerForTesting = true
            }
            if ProcessInfo.processInfo.environment["CONFERENCE_TEST_SPEAKER"] == "1" {
                call.fixtureActions = SpeakerFixtureActions.make(call.activeSpeaker)
            }
            if ProcessInfo.processInfo.environment["CONFERENCE_TEST_STUDIO"] == "1" {
                let studio = StudioModel(audioControl: .fullProcessing, privateCamera: StudioCameraFixture(), privateMicrophone: StudioMicrophoneFixture())
                studio.applyProfile = { _ in }
                studio.soundCheck.verifyMuted = { [weak call] in call?.setMicrophone(false) }
                studio.presenter.startSharing = { _, _ in }
                studio.presenter.sendSample = { _ in }
                studio.presenter.stopSharing = {}
                call.studio = studio
                if ProcessInfo.processInfo.environment["CONFERENCE_TEST_MIC_ACTIVITY"] == "1" {
                    call.fixtureActions = MicrophoneActivityFixture(activity: studio.microphoneActivity).actions
                }
                call.onCamera = { [weak call] in call?.setCamera($0) }
                call.onMicrophone = { [weak call, weak studio] in call?.setMicrophone($0); studio?.microphoneActivity.setStatus($0 ? .on : .muted) }
                call.onShare = { [weak call] in call?.setSharing($0) }
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
/// Independent native input control for simulator gesture qualification.
private final class PlainZoomControl: UIViewController, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private let content = UIView(frame: CGRect(x: 0, y: 0, width: 1058, height: 595))
    private var viewportSize = CGSize.zero
    override func loadView() {
        view = scroll
        scroll.delegate = self
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 4
        scroll.accessibilityIdentifier = "plain.zoom"
        scroll.accessibilityValue = "100%"
        content.backgroundColor = .orange
        content.accessibilityIdentifier = "plain.zoom.content"
        scroll.addSubview(content); scroll.contentSize = content.bounds.size
        let zoom = UIButton(type: .system)
        zoom.setTitle("Zoom control", for: .normal)
        zoom.accessibilityIdentifier = "plain.zoom.programmatic"
        zoom.addTarget(self, action: #selector(zoomControl), for: .touchUpInside)
        zoom.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(zoom)
        NSLayoutConstraint.activate([
            zoom.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            zoom.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            zoom.widthAnchor.constraint(equalToConstant: 140), zoom.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if viewportSize != scroll.bounds.size {
            viewportSize = scroll.bounds.size
            scroll.setZoomScale(1, animated: false)
            content.frame = CGRect(origin: .zero, size: scroll.bounds.size)
            scroll.contentSize = content.bounds.size
        }
    }
    @objc private func zoomControl() { scroll.setZoomScale(2, animated: false) }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { scroll.accessibilityValue = String(format: "%.0f%%", scroll.zoomScale * 100) }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { scrollViewDidZoom(scrollView) }
}
#endif

#if DEBUG
import AVFoundation

/// Standalone qualification process: real capture, engine and lifecycle with an
/// independently decoded receiver. Opt-in; never changes stored profile/history.
@MainActor final class MacPresenterQualification {
    let window: UIWindow
    private let container = UIViewController()
    private let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    private let link: String
    private var timer: Timer?
    private var frames = 0
    private var ages = [Double]()
    private var elapsed: TimeInterval = 0
    private var sharingStarted = false
    private var publishedAt: TimeInterval?
    private var starting = false
    private let evidenceURL: URL?
    static func make(windowScene: UIWindowScene) -> MacPresenterQualification? {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              let link = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PRESENTER_INVITE"],
              ProcessInfo.processInfo.environment["ROCKNROLL_TEST_CAPTURE_WINDOW"] != nil else { return nil }
        return MacPresenterQualification(scene: windowScene, link: link)
    }
    private init(scene: UIWindowScene, link: String) {
        self.link = link; window = UIWindow(windowScene: scene)
        evidenceURL = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PRESENTER_EVIDENCE"].map { URL(fileURLWithPath: $0) }
        window.rootViewController = container; window.makeKeyAndVisible()
    }
    func start() {
        Task {
            do {
                let target = try JoinTarget.parse(link)
                let endpoint = try await VendorEndpointResolver.make().resolve(for: target)
                try engine.configure(container: container, networkURL: endpoint, displayName: "Presenter capture QA")
                try engine.join(target: target, displayName: "Presenter capture QA")
                for _ in 0..<600 {
                    if engine.readyForPresenterForTesting { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard engine.readyForPresenterForTesting else { throw CocoaError(.featureUnsupported) }
                let model = engine.studioForTesting.presenter
                let create = model.makeScreenSource!
                model.makeScreenSource = { [weak self] frame, effect, selection, end in
                    create({ sample in
                        if let self {
                            self.frames += 1
                            let age = (ProcessInfo.processInfo.systemUptime - sample.presentationTimeStamp.seconds) * 1000
                            if age.isFinite && age >= 0 && age < 1000 { self.ages.append(age) }
                        }
                        frame(sample)
                    }, effect, selection, end)
                }
                engine.studioForTesting.open(.presenter)
                let panel = UIHostingController(rootView: StudioPanel(model: engine.studioForTesting))
                container.present(panel, animated: false)
                model.includeCamera = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PRESENTER_CAMERA"] != "0"
                if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PRESENTER_CANVAS"] == "1" {
                    model.selectCanvas(); model.scene.backdrop = .warm
                } else { model.selectScreen() }
                let began = ProcessInfo.processInfo.systemUptime
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick(began: began) }
                }
            } catch { print("PRESENTER_QUALIFICATION_ERROR \(error)") }
        }
    }
    private func tick(began: TimeInterval) {
        elapsed = ProcessInfo.processInfo.systemUptime - began
        let model = engine.studioForTesting.presenter
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PRESENTER_CANVAS"] == "1" {
            model.scene.backdrop = Int(elapsed / 2) % 2 == 0 ? .warm : .stage
        }
        if !sharingStarted && !starting && model.canStartSharing {
            starting = true
            Task {
                await model.start(); sharingStarted = model.running; starting = false
                if sharingStarted { publishedAt = ProcessInfo.processInfo.systemUptime }
            }
        }
        var report = model.cameraEvidenceForTesting
        report["elapsed"] = elapsed; report["captureFrames"] = frames
        report["running"] = model.running; report["error"] = model.error ?? ""
        report["compositions"] = model.compositionCount; report["heartbeats"] = model.heartbeatCount
        let sorted = ages.sorted()
        report["captureAgeMedianMs"] = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        report["captureAgeP95Ms"] = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            if let evidenceURL { try? data.write(to: evidenceURL, options: .atomic) }
            print("PRESENTER_QUALIFICATION \(String(decoding: data, as: UTF8.self))")
        }
        if let publishedAt, ProcessInfo.processInfo.systemUptime - publishedAt > 600 { timer?.invalidate(); timer = nil; engine.leave() }
    }
}
#endif
