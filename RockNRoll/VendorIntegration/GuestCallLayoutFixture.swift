#if DEBUG
import JazzSDK
import UIKit
import WebRTC

/// Exercises the production stage and controls without live-room timing.
final class GuestCallLayoutFixture: UIViewController {
    private let streams = GuestStreamViews()
    private let processor = GuestVideoFrameProcessor()
    private var controls: CallControls!
    private var renderers: [String: RTCMTLVideoView] = [:]
    private var timer: Timer?
    private var selectedName = ""
    private var views: [String: UIView] = [:]
    private let meetingStatus = MeetingHeaderStatus()
    private let reactions = MeetingReactionsModel()
    private let chat = ChatStore()

    override func viewDidLoad() {
        super.viewDidLoad()
        // A visibly different SDK underlay detects accidental duplicate exposure.
        view.backgroundColor = .systemPurple
        let preview = LocalSharePreview()
        let catchUp = CatchUpStore()
        catchUp.enter(roomKey: "guest-layout-\(UUID().uuidString)")
        let scenario = ProcessInfo.processInfo.environment["CONFERENCE_TEST_GUEST_SCENARIO"]
        let activeSpeaker = ActiveSpeakerStore()
        let studio = ["studio", "reactions"].contains(scenario) ? StudioModel(audioControl: .noiseSuppression, privateCamera: StudioCameraFixture(), privateMicrophone: StudioMicrophoneFixture()) : nil
        if scenario == "reactions" {
            reactions.available = true; reactions.ready = true; studio?.reactions = reactions
            chat.reactionHistoryAvailable = true; chat.reactionHistory.beginMeeting()
            chat.reactionHistory.receive(kind: .heart, participantID: "ani", displayName: "Ani", isOwn: false)
            reactions.sender = { [weak chat] kind in
                chat?.reactionHistory.recordLocalSubmission(kind: kind, participantID: "self", displayName: "You", submissionID: UUID().uuidString)
                return true
            }
        }
        studio?.soundCheck.verifyMuted = { [weak self] in self?.controls.setFixtureMedia(microphone: false) }
        studio?.observeNoiseSuppression(true)
        studio?.applyProfile = { [weak studio] profile in studio?.observeNoiseSuppression(profile == .conversation) }
        studio?.presenter.startSharing = { _ in }
        studio?.presenter.sendSample = { _ in }
        studio?.presenter.stopSharing = {}
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_PRESENTER_WARM"] == "1" {
            studio?.presenter.scene.backdrop = .warm
        }
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_PRESENTER_CAMERA_LAYER"] == "1" {
            studio?.presenter.makePrivateCamera = { _ in StudioCameraFixture() }
            studio?.presenter.scene.placement = PresenterPlacement()
            studio?.presenter.scene.layout = .card
            studio?.presenter.includeCamera = true
        }
        if scenario == "notices" { catchUp.observe(messages: [], canView: true, enabled: true) }
        let solo = scenario == "solo"
        controls = CallControls(localPreview: preview, state: nil, coordinator: nil, router: nil,
            catchUp: catchUp, chat: chat, initialDisplayMode: .all,
            invitationURL: URL(string: "https://rock.glowsoft.ru/jams/test"), roomIdentifier: "fixture",
            onDisplayMode: { [weak self] mode in self?.streams.displayMode = mode },
            onFloat: {}, onFloatingPreferenceChanged: {}, onLeave: {}, onScreenShare: { _ in },
            onMicrophoneState: { [weak self] in self?.controls.setFixtureMedia(microphone: $0) },
            onCameraState: { [weak self] in self?.controls.setFixtureMedia(camera: $0) },
            usesNativeParticipants: scenario == "participants" || ProcessInfo.processInfo.isiOSAppOnMac,
            studio: studio, activeSpeaker: activeSpeaker,
            reactions: scenario == "reactions" ? reactions : nil, meetingStatus: meetingStatus)
        if let studio, ProcessInfo.processInfo.environment["CONFERENCE_TEST_MIC_ACTIVITY"] == "1" {
            controls.fixtureActions = MicrophoneActivityFixture(activity: studio.microphoneActivity).actions
        }
        if scenario == "speaker" { controls.fixtureActions = SpeakerFixtureActions.make(activeSpeaker) }
        if scenario == "notices" {
            meetingStatus.updatePrivacy(transcribing: true, recording: false)
            controls.showNotices([InCallNotice(title: L("The organizer is transcribing this meeting."), actionTitle: nil, action: nil)])
            controls.fixtureActions = [
                UIAction(title: "Routine notice in focus") { [weak self] _ in
                    self?.scheduleStatus { self?.meetingStatus.updateNotices([InCallNotice(title: "Link copied", actionTitle: nil, action: nil)]) }
                },
                UIAction(title: "Recording in focus") { [weak self] _ in
                    self?.scheduleStatus { self?.meetingStatus.updatePrivacy(transcribing: true, recording: true) }
                },
                UIAction(title: "Provider action") { [weak self] _ in
                    self?.meetingStatus.updateNotices([InCallNotice(title: "Please confirm", actionTitle: "Continue", action: {
                        self?.meetingStatus.updateNotices([])
                        self?.controls.showMediaStatus("Action completed")
                    })])
                }
            ]
        }
        let entries: [(String, String, Bool)] = scenario == "gallery" ?
            [("ani", "Ani", false), ("aram", "Aram", false), ("mariam", "Mariam", false), ("vahan", "Vahan", false)] : solo ? [("self", "Your contact", false)] :
            [("share", "Ani’s arrangement", true), ("camera", "Aram", false)]
        for (id, name, share) in entries {
            let renderer = RTCMTLVideoView()
            renderers[id] = renderer
            let model = JazzParticipantViewModel(name: name, isAudioOn: !solo, isVideoOn: !solo && !share,
                isPinned: false, isSharingScreen: share, isLocal: solo, id: id,
                isDominantSpeaker: false, shouldShowParticipantInfo: true,
                isZoomable: share, watermarkState: .hidden,
                displayMode: scenario == "compact" && !share ? .pip : .speaker)
            let tile = streams.makeView(model: model, video: renderer)
            views[id] = tile
            tile.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
            view.addSubview(tile)
            if scenario == "compact" && !share { tile.frame = .zero; tile.isHidden = true }
        }
        let roster = entries.map { id, name, share in
            GuestStreamViews.Participant(id: id, name: name, isLocal: solo,
                microphoneOn: !solo, cameraOn: !solo && !share, sharing: share)
        }
        streams.updateParticipants(roster)
        controls.updateParticipantRoster(roster, speaking: solo ? nil : "camera")
        streams.onStagePresentation = { [weak self] presentation in
            guard let self else { return }
            self.controls.setStagePresentation(presentation, pinnedParticipant: self.streams.pinnedTarget)
        }
        streams.onPreferredVideo = { [weak self] _, name, _ in self?.selectedName = name }
        controls.onBrowse = { [weak self] in self?.streams.browse($0) }
        controls.onAutomaticView = { [weak self] in self?.streams.useAutomaticView() }
        controls.onPinStage = { [weak self] in self?.streams.toggleSelectedPin() }
        controls.onPinParticipant = { [weak self] in self?.streams.setPin($0) }
        if scenario == "gallery" { controls.bindStreams(streams) }
        controls.frame = view.bounds
        controls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if ["participants", "studio", "reactions", "notices"].contains(scenario) {
            // The real SDK overlay can be hosted by a zero-sized child controller.
            // Panels must present from the visible meeting above that host.
            let host = UIViewController()
            addChild(host)
            view.addSubview(host.view)
            host.view.frame = .zero
            host.didMove(toParent: self)
            host.view.addSubview(controls)
        } else {
            view.addSubview(controls)
        }
        controls.setWaitingForOthers(solo)
        if solo {
            // A late SDK self-tile update must not cover the invitation.
            controls.setStagePresentation(.init(target: .init(participant: "self", isShare: false),
                name: "Your contact", microphoneOn: false, watermark: nil, active: false,
                automatic: true, count: 1, browsing: false))
        }
        processor.onSample = { [weak self] sample, _, rotation in self?.controls.showStageFrame(sample, rotation: rotation) }
        processor.setEnabled(true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let width = 320, height = 180
            let buffer = RTCMutableI420Buffer(width: Int32(width), height: Int32(height))
            for row in 0..<height {
                for column in 0..<width {
                    buffer.mutableDataY[row * Int(buffer.strideY) + column] =
                        self.selectedName == "Aram" ? 90 : ((column / 32 + row / 18).isMultiple(of: 2) ? 40 : 170)
                }
            }
            for row in 0..<height / 2 {
                for column in 0..<width / 2 {
                    buffer.mutableDataU[row * Int(buffer.strideU) + column] = 128
                    buffer.mutableDataV[row * Int(buffer.strideV) + column] = 128
                }
            }
            self.processor.submit(RTCVideoFrame(buffer: buffer, rotation: ._0,
                timeStampNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000)))
        }
        streams.refreshSelection()
    }
    private func scheduleStatus(_ action: @escaping () -> Void) {
        // Give the test time to close the menu and hide controls first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: action)
    }
    deinit { timer?.invalidate(); processor.setEnabled(false) }
}
#endif
