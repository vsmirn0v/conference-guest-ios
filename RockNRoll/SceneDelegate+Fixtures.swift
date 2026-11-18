#if DEBUG
import ConferenceCore
import LiveKit
import SwiftUI
import UIKit

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
                window.rootViewController = GuestCallFixtureViewController(model: model)
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
            let liveTranscriptReactions = fixture == "live-transcript-reactions"
            let fixtureTime = Date()
            if fixture == "reactions" || fixture == "reactions-unavailable" || liveTranscriptReactions {
                chat.reactionHistoryAvailable = true
                if fixture == "reactions-unavailable" { chat.canSend = false }
                let history = chat.reactionHistory
                history.beginMeeting(id: UUID())
                if liveTranscriptReactions {
                    history.receive(kind: .heart, participantID: "ani", displayName: "Ani", isOwn: false,
                        providerTimestamp: fixtureTime.addingTimeInterval(-45),
                        receivedAt: fixtureTime.addingTimeInterval(-45))
                    history.receive(kind: .wave, participantID: "narek", displayName: "Narek", isOwn: false,
                        providerTimestamp: fixtureTime.addingTimeInterval(-35),
                        receivedAt: fixtureTime.addingTimeInterval(-35))
                    history.recordLocalSubmission(kind: .like, participantID: "local", displayName: "Rock QA",
                        submissionID: "fixture-local-reaction", at: fixtureTime.addingTimeInterval(-15))
                    history.receive(kind: .applause, participantID: "ani", displayName: "Ani", isOwn: false,
                        providerTimestamp: fixtureTime.addingTimeInterval(-5),
                        receivedAt: fixtureTime.addingTimeInterval(-5))
                } else {
                    for index in 0..<36 {
                        history.receive(kind: index % 3 == 0 ? .heart : .like, participantID: "ani",
                            displayName: "Ani", isOwn: false, receivedAt: fixtureTime.addingTimeInterval(Double(index - 36) * 12))
                    }
                    for index in 0..<3 {
                        history.receive(kind: .like, participantID: "ani", displayName: "Ani", isOwn: false,
                            receivedAt: fixtureTime.addingTimeInterval(Double(index) * 0.1))
                    }
                }
            }
            let store = model.catchUpStore
            store.enter(roomKey: "https://rock.glowsoft.ru/jams/fixture-\(UUID().uuidString)")
            store.begin(.anotherCall)
            if liveTranscriptReactions {
                store.observe(messages: [
                    TranscriptSegment(id: "live-1", speaker: "Ani",
                        text: "We will start with the slower arrangement.", spokenAt: fixtureTime.addingTimeInterval(-60)),
                    TranscriptSegment(id: "live-2", speaker: "Narek",
                        text: "I will bring the amplifier on Friday.", spokenAt: fixtureTime.addingTimeInterval(-20)),
                    TranscriptSegment(id: "live-unknown", speaker: nil,
                        text: "This line arrived without a timestamp.", spokenAt: nil)
                ], canView: true, enabled: true)
            } else {
                store.observe(messages: [TranscriptSegment(id: "line", speaker: "Ani",
                    text: "We will meet Friday at six thirty.", spokenAt: fixtureTime)],
                    canView: fixture != "unavailable", enabled: fixture != "unavailable")
            }
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
                                                                         initialMode: liveTranscriptReactions ? .liveText : .chat,
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

@MainActor
private final class GuestCallFixtureViewController: UIViewController {
    private let model: ConferenceModel
    private let reactions = MeetingReactionsModel()
    private let reactionSubmission = ReactionSubmission(valid: { true })
    private var call: RockCallViewController!
    private var studio: StudioModel?
    private var shareTrack: LocalVideoTrack?
    private var frameTimer: Timer?
    private var setupTask: Task<Void, Never>?

    init(model: ConferenceModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let scenario = ProcessInfo.processInfo.environment["CONFERENCE_TEST_GUEST_SCENARIO"]
        model.catchUpStore.enter(roomKey: "guest-layout-\(UUID().uuidString)")
        model.catchUpStore.begin(.anotherCall)
        model.catchUpStore.end(.anotherCall)
        if scenario == "notices" {
            model.catchUpStore.observe(messages: [], canView: true, enabled: true)
        }
        model.chat.canSend = true
        model.chat.onSend = { [weak chat = model.chat] message in
            chat?.append(ChatEntry(id: UUID().uuidString, sender: "You", text: message,
                                   sentAt: Date(), isOwn: true))
        }
        let call = RockCallViewController(
            title: "Open rehearsal",
            catchUp: model.catchUpStore,
            chat: model.chat,
            invitationURL: URL(string: "https://rock.glowsoft.ru/jams/test"),
            roomIdentifier: "fixture"
        )
        self.call = call
        if scenario == "studio" { call.usesNativeShareControl = true }

        var configuredStudio: StudioModel?
        if ["studio", "reactions"].contains(scenario) {
            let studio = StudioModel(
                audioControl: .noiseSuppression,
                privateCamera: StudioCameraFixture(),
                privateMicrophone: StudioMicrophoneFixture()
            )
            studio.soundCheck.verifyMuted = { [weak call] in call?.setMicrophone(false) }
            studio.observeNoiseSuppression(true)
            studio.applyProfile = { [weak studio] profile in
                studio?.observeNoiseSuppression(profile == .conversation)
            }
            if ProcessInfo.processInfo.environment["CONFERENCE_TEST_PRESENTER_DELAY"] == "1" {
                studio.presenter.startSharing = { _, _ in
                    try await Task.sleep(nanoseconds: 6_000_000_000)
                }
            } else {
                studio.presenter.startSharing = { _, _ in }
            }
            studio.presenter.sendSample = { _ in }
            studio.presenter.stopSharing = {}
            if ProcessInfo.processInfo.environment["CONFERENCE_TEST_PRESENTER_WARM"] == "1" {
                studio.presenter.scene.backdrop = .warm
            }
            if ProcessInfo.processInfo.environment["CONFERENCE_TEST_PRESENTER_CAMERA_LAYER"] == "1" {
                studio.presenter.makePrivateCamera = { _ in StudioCameraFixture() }
                studio.presenter.scene.placement = PresenterPlacement()
                studio.presenter.scene.layout = .card
                studio.presenter.includeCamera = true
            }
            call.studio = studio
            self.studio = studio
            configuredStudio = studio
            if ProcessInfo.processInfo.environment["CONFERENCE_TEST_MIC_ACTIVITY"] == "1" {
                call.fixtureActions = MicrophoneActivityFixture(activity: studio.microphoneActivity).actions
            }
        }

        call.onCamera = { [weak call] in call?.setCamera($0) }
        call.onMicrophone = { [weak call, weak configuredStudio] enabled in
            call?.setMicrophone(enabled)
            configuredStudio?.microphoneActivity.setStatus(enabled ? .on : .muted)
        }
        call.onShare = { [weak call] in call?.setSharing($0) }

        if scenario == "reactions" {
            reactions.available = true
            reactions.ready = true
            configuredStudio?.reactions = reactions
            call.reactions = reactions
            call.exposeReactionOverlayForTesting = true
            model.chat.reactionHistoryAvailable = true
            model.chat.reactionHistory.beginMeeting(id: UUID())
            model.chat.reactionHistory.receive(
                kind: .heart,
                participantID: "ani",
                displayName: "Ani",
                isOwn: false
            )
            reactionSubmission.onAccepted = { [weak self, weak chat = model.chat] kind, id in
                self?.reactions.trackSubmission(kind, id: id)
                chat?.reactionHistory.recordLocalSubmission(
                    kind: kind,
                    participantID: "self",
                    displayName: "You",
                    submissionID: id
                )
            }
            reactionSubmission.onTransmitted = { [weak self] kind, id in
                self?.reactions.finishSubmission(id: id, succeeded: true)
                self?.call.showReaction(kind, from: "You")
            }
            reactions.sender = { [weak self] kind in
                self?.reactionSubmission.send(kind) { done in
                    done(true)
                    return true
                } ?? false
            }
            call.fixtureActions = [
                UIAction(title: "Fixture incoming Heart") { [weak call] _ in
                    call?.showReaction(.heart, from: "Ani")
                }
            ]
        }

        let solo = scenario == "solo"
        call.fixtureParticipants = solo
            ? [ParticipantStatus(id: "local", name: "Your contact", isLocal: true,
                                 microphoneOn: false, cameraOn: false, screenShareOn: false,
                                 isSpeaking: false, videoKey: nil, shareKey: nil)]
            : [ParticipantStatus(id: "local", name: "Rock QA", isLocal: true,
                                 microphoneOn: false, cameraOn: false, screenShareOn: false,
                                 isSpeaking: false, videoKey: nil, shareKey: nil),
               ParticipantStatus(id: "ani", name: "Ani’s arrangement", isLocal: false,
                                 microphoneOn: true, cameraOn: false, screenShareOn: true,
                                 isSpeaking: false, videoKey: nil, shareKey: "share"),
               ParticipantStatus(id: "aram", name: "Aram", isLocal: false,
                                 microphoneOn: true, cameraOn: false, screenShareOn: false,
                                 isSpeaking: true, videoKey: nil, shareKey: nil)]

        addChild(call)
        call.view.frame = view.bounds
        call.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(call.view)
        call.didMove(toParent: self)

        guard !solo else {
            call.render(snapshot: CallMediaSnapshot(participants: [
                CallParticipant(id: "local", name: "Your contact", isLocal: true,
                                microphoneOn: false, cameraOn: false, screenShareOn: false,
                                isSpeaking: false, videoTracks: [])
            ]))
            return
        }

        setupTask = Task { @MainActor [weak self] in
            let track = await LocalVideoTrack.createBufferTrack()
            guard let self, !Task.isCancelled else { return }
            self.shareTrack = track
            try? await track.start()
            guard !Task.isCancelled else {
                try? await track.stop()
                return
            }
            self.drawCheckerboardFrame(into: track)
            self.call.render(snapshot: CallMediaSnapshot(participants: [
                CallParticipant(id: "local", name: "Rock QA", isLocal: true,
                                microphoneOn: false, cameraOn: false, screenShareOn: false,
                                isSpeaking: false, videoTracks: []),
                CallParticipant(id: "ani", name: "Ani’s arrangement", isLocal: false,
                                microphoneOn: true, cameraOn: false, screenShareOn: true,
                                isSpeaking: false,
                                videoTracks: [CallVideoStream(id: "share", source: .screenShareVideo, track: .room(track))]),
                CallParticipant(id: "aram", name: "Aram", isLocal: false,
                                microphoneOn: true, cameraOn: false, screenShareOn: false,
                                isSpeaking: true, videoTracks: [])
            ]))
            self.frameTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let track = self.shareTrack else { return }
                    self.drawCheckerboardFrame(into: track)
                }
            }
        }
    }

    private func drawCheckerboardFrame(into track: LocalVideoTrack) {
        guard let capturer = track.capturer as? BufferCapturer else { return }
        let width = 320, height = 180
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                let rowOffset = row * bytesPerRow
                for column in 0..<width {
                    let value: UInt8 = (column / 32 + row / 18).isMultiple(of: 2) ? 60 : 170
                    let offset = rowOffset + column * 4
                    pixels[offset] = value
                    pixels[offset + 1] = value
                    pixels[offset + 2] = value
                    pixels[offset + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        capturer.capture(buffer)
    }

    deinit {
        setupTask?.cancel()
        frameTimer?.invalidate()
        if let track = shareTrack {
            Task { try? await track.stop() }
        }
    }
}
#endif
