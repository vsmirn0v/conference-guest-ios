import AVKit
import Combine
import LiveKit
import ReplayKit
import UIKit

@MainActor
final class RockCallViewController: UIViewController, UIScrollViewDelegate, UIContextMenuInteractionDelegate {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var shouldAutorotate: Bool { true }
    override var keyCommands: [UIKeyCommand]? { [
        UIKeyCommand(title: "Mute or unmute microphone", action: #selector(keyToggleMicrophone),
                     input: "a", modifierFlags: [.command, .shift]),
        UIKeyCommand(title: "Start or stop video", action: #selector(keyToggleCamera),
                     input: "v", modifierFlags: [.command, .shift]),
        UIKeyCommand(title: "Open chat", action: #selector(keyOpenChat),
                     input: "c", modifierFlags: [.command, .shift]),
        UIKeyCommand(title: "Show musicians", action: #selector(keyOpenParticipants),
                     input: "p", modifierFlags: [.command, .shift]),
        UIKeyCommand(title: "Fit shared screen", action: #selector(keyFitScreen),
                     input: "0", modifierFlags: [.command])
    ] }
    var onLeave: (() -> Void)?
    var onMicrophone: ((Bool) -> Void)?
    var onCamera: ((Bool) -> Void)?
    var onFlipCamera: (() -> Void)?
    var onSpeaker: ((Bool) -> Void)?
    var onShare: ((Bool) -> Void)?
    var onDisplayMode: ((ConferenceDisplayMode) -> Void)?

    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let routeLabel = UILabel()
    private let statusLabel = UILabel()
    private let tiles = UIStackView()
    private let streamScroll = UIScrollView()
    private let conversationHost = UIView()
    private var conversationWidth: NSLayoutConstraint?
    private var dockedConversation: ConversationPanelViewController?
    private let microphone = UIButton(type: .system)
    private let camera = UIButton(type: .system)
    private let flipCamera = UIButton(type: .system)
    private let speaker = UIButton(type: .system)
    private let share = UIButton(type: .system)
    private let sharePicker = RPSystemBroadcastPickerView()
    private let shareTitle = UILabel()
    private let displayModeButton = UIButton(type: .system)
    private let conversationButton = UIButton(type: .system)
    private let missedButton = UIButton(type: .system)
    private let participantsButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let fitButton = UIButton(type: .system)
    private let zoomInButton = UIButton(type: .system)
    private let zoomOutButton = UIButton(type: .system)
    private let zoomControls = UIStackView()
    private let shareOffer = UIButton(type: .system)
    let localSharePreview = LocalSharePreview()
    private lazy var localShareCard = LocalSharePreviewCard(model: localSharePreview)
    private lazy var localShareRenderer = LocalShareTrackPreview(preview: localSharePreview)
    #if DEBUG
    var fixtureParticipants: [ParticipantStatus]?
    #endif
    private struct PinnedStream: Equatable {
        let participantID: String
        let isScreenShare: Bool
    }
    private struct VideoTile {
        let tile: UIView
        let zoom: UIScrollView
        let video: VideoView
        let name: UILabel
        let pin: UIButton
        var heightConstraint: NSLayoutConstraint?
    }
    private var videoTiles: [String: VideoTile] = [:]
    private var flipCameraConstraints: [NSLayoutConstraint] = []
    private var currentPrimaryKey: String?
    private var floatingVideo: RockVideoPictureInPicture?
    private var zoomStates: [String: (CGFloat, CGPoint)] = [:]
    private weak var primaryZoom: UIScrollView?
    private weak var participantsPanel: ParticipantPanelViewController?
    private var pinnedStreamKey: String?
    private var pinnedStream: PinnedStream?
    private var preservingPinDuringReconnect = false
    private var streamPinTargets: [String: PinnedStream] = [:]
    private var offeredShare: PinnedStream?
    private var speakingLabels: [String: UILabel] = [:]
    private var speakingTiles: [String: [UIView]] = [:]
    private let store: CatchUpStore
    private let chat: ChatStore
    private let workspace = CallWorkspaceControls()
    private weak var displayedRoom: Room?
    private var displayMode: ConferenceDisplayMode = .all
    private var isMicrophoneOn = false
    private var isCameraOn = false
    private var isSpeakerOn = true
    private var isSharingScreen = false
    private var compactControls = false
    private var isHeld = false
    private var mediaStatus: String?
    private var subscriptions = Set<AnyCancellable>()
    private let accent = UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1)

    @objc private func keyToggleMicrophone() { microphone.sendActions(for: .touchUpInside) }
    @objc private func keyToggleCamera() { camera.sendActions(for: .touchUpInside) }
    @objc private func keyOpenChat() { openConversation(.chat) }
    @objc private func keyOpenParticipants() { participantsButton.sendActions(for: .touchUpInside) }
    @objc private func keyFitScreen() { primaryZoom?.setZoomScale(1, animated: true) }

    init(title: String, catchUp: CatchUpStore, chat: ChatStore,
         invitationURL: URL? = nil, roomIdentifier: String? = nil) {
        store = catchUp
        self.chat = chat
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        titleLabel.text = title
        workspace.invitationURL = invitationURL
        workspace.roomIdentifier = roomIdentifier
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        floatingVideo?.refreshPreference()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        localShareCard.refreshLayout()
        let compact = view.bounds.width < 390
        if compact != compactControls {
            compactControls = compact
            updateControlTitles()
        }
        guard dockedConversation != nil else { return }
        conversationWidth?.constant = view.bounds.width >= 700
            ? min(400, max(320, view.bounds.width * 0.36))
            : max(0, view.bounds.width - 32)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.085, alpha: 1)
        floatingVideo = RockVideoPictureInPicture(sourceView: view)
        let identity = UIStackView(arrangedSubviews: [titleLabel, countLabel, routeLabel])
        identity.axis = .vertical
        identity.spacing = 2
        let header = UIStackView(arrangedSubviews: [identity, participantsButton,
                                                    missedButton, conversationButton])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 4
        header.setContentHuggingPriority(.required, for: .vertical)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .preferredFont(forTextStyle: .subheadline)
        countLabel.textColor = .lightGray
        countLabel.text = "Connecting…"
        routeLabel.font = .preferredFont(forTextStyle: .caption1)
        routeLabel.textColor = .lightGray
        routeLabel.text = "Audio output"

        tiles.axis = .vertical
        tiles.spacing = 10
        streamScroll.addSubview(tiles)
        tiles.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tiles.leadingAnchor.constraint(equalTo: streamScroll.contentLayoutGuide.leadingAnchor),
            tiles.trailingAnchor.constraint(equalTo: streamScroll.contentLayoutGuide.trailingAnchor),
            tiles.topAnchor.constraint(equalTo: streamScroll.contentLayoutGuide.topAnchor),
            tiles.bottomAnchor.constraint(equalTo: streamScroll.contentLayoutGuide.bottomAnchor),
            tiles.widthAnchor.constraint(equalTo: streamScroll.frameLayoutGuide.widthAnchor)
        ])

        configure(microphone, symbol: "mic.slash.fill", label: "Unmute microphone", title: "Mic off")
        configure(camera, symbol: "video.slash.fill", label: "Start video", title: "Cam off")
        configure(share, symbol: "rectangle.on.rectangle", label: "Share screen", title: "Share")
        if #available(iOS 27.0, *) {
            share.isHidden = false
            sharePicker.isHidden = true
            shareTitle.isHidden = true
        } else {
            share.isHidden = true
        }
        sharePicker.preferredExtension = Bundle.main.bundleIdentifier.map { "\($0).broadcast" }
        sharePicker.showsMicrophoneButton = false
        sharePicker.tintColor = accent
        sharePicker.isAccessibilityElement = true
        sharePicker.accessibilityTraits = .button
        sharePicker.accessibilityLabel = "Share screen"
        shareTitle.text = "Share"
        shareTitle.font = .preferredFont(forTextStyle: .caption2)
        shareTitle.textColor = accent
        microphone.configuration?.baseForegroundColor = .white
        camera.configuration?.baseForegroundColor = .white
        configure(flipCamera, symbol: "arrow.triangle.2.circlepath.camera", label: "Flip camera")
        flipCamera.isEnabled = false
        configure(speaker, symbol: "speaker.wave.2.fill", label: "Use iPhone speaker")
        configure(displayModeButton, symbol: displayMode.symbol, label: "Display: All video")
        displayModeButton.showsMenuAsPrimaryAction = true
        configureModeMenu()
        configure(conversationButton, symbol: "text.bubble", label: "Chat")
        configure(missedButton, symbol: "clock.arrow.circlepath", label: "Catch up")
        missedButton.isHidden = true
        missedButton.addAction(UIAction { [weak self] _ in
            self?.openConversation(.catchUp)
        }, for: .touchUpInside)
        configure(participantsButton, symbol: "person.2.fill", label: "Musicians")
        configure(moreButton, symbol: "ellipsis.circle.fill", label: "More call options", title: "More")
        moreButton.showsMenuAsPrimaryAction = true
        configureMoreMenu()
        configure(fitButton, symbol: "arrow.down.right.and.arrow.up.left", label: "Fit shared screen at 100%")
        configure(zoomInButton, symbol: "plus.magnifyingglass", label: "Zoom in shared screen")
        configure(zoomOutButton, symbol: "minus.magnifyingglass", label: "Zoom out shared screen")
        zoomControls.axis = .horizontal
        zoomControls.spacing = 4
        zoomControls.addArrangedSubview(zoomOutButton)
        zoomControls.addArrangedSubview(fitButton)
        zoomControls.addArrangedSubview(zoomInButton)
        zoomControls.isHidden = true
        fitButton.isHidden = true
        fitButton.addAction(UIAction { [weak self] _ in
            self?.primaryZoom?.setZoomScale(1, animated: true)
        }, for: .touchUpInside)
        zoomInButton.addAction(UIAction { [weak self] _ in
            self?.changePrimaryZoom(by: 1.5)
        }, for: .touchUpInside)
        zoomOutButton.addAction(UIAction { [weak self] _ in
            self?.changePrimaryZoom(by: 1 / 1.5)
        }, for: .touchUpInside)
        shareOffer.configuration = .tinted()
        shareOffer.configuration?.image = UIImage(systemName: "rectangle.on.rectangle")
        shareOffer.isHidden = true
        shareOffer.addAction(UIAction { [weak self] _ in
            guard let self, let offer = self.offeredShare else { return }
            self.setPin(offer)
        }, for: .touchUpInside)
        #if DEBUG
        participantsButton.isEnabled = fixtureParticipants != nil
        #else
        participantsButton.isEnabled = false
        #endif
        let routePicker = AVRoutePickerView()
        routePicker.tintColor = accent
        routePicker.activeTintColor = accent
        routePicker.accessibilityLabel = "Choose audio output"
        let leave = UIButton(type: .system)
        configure(leave, symbol: "phone.down.fill", label: "Leave", title: "Leave")
        leave.configuration?.baseForegroundColor = .systemRed

        microphone.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onMicrophone?(!self.isMicrophoneOn)
        }, for: .touchUpInside)
        camera.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onCamera?(!self.isCameraOn)
        }, for: .touchUpInside)
        share.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onShare?(!self.isSharingScreen)
        }, for: .touchUpInside)
        flipCamera.addAction(UIAction { [weak self] _ in self?.onFlipCamera?() }, for: .touchUpInside)
        speaker.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.isSpeakerOn.toggle()
            self.workspace.speakerOn = self.isSpeakerOn
            self.onSpeaker?(self.isSpeakerOn)
            self.speaker.accessibilityLabel = self.isSpeakerOn ? "Use iPhone receiver" : "Use iPhone speaker"
        }, for: .touchUpInside)
        conversationButton.addAction(UIAction { [weak self] _ in
            self?.openConversation(.chat)
        }, for: .touchUpInside)
        participantsButton.addAction(UIAction { [weak self] _ in
            guard let self, self.presentedViewController == nil else { return }
            #if DEBUG
            let statuses = self.displayedRoom.map(self.statuses(in:)) ?? self.fixtureParticipants ?? []
            #else
            guard let room = self.displayedRoom else { return }
            let statuses = self.statuses(in: room)
            #endif
            let panel = ParticipantPanelViewController()
            panel.onPin = { [weak self] key in
                guard let self else { return }
                self.setPin(key.flatMap { self.streamPinTargets[$0] })
            }
            self.participantsPanel = panel
            panel.update(statuses, pinnedKey: self.pinnedStreamKey)
            let navigation = UINavigationController(rootViewController: panel)
            navigation.sheetPresentationController?.detents = [.medium(), .large()]
            self.present(navigation, animated: true)
        }, for: .touchUpInside)
        leave.addAction(UIAction { [weak self] _ in self?.onLeave?() }, for: .touchUpInside)
        workspace.toggleMicrophone = { [weak self] in self?.microphone.sendActions(for: .touchUpInside) }
        workspace.toggleCamera = { [weak self] in self?.camera.sendActions(for: .touchUpInside) }
        workspace.toggleSpeaker = { [weak self] in self?.speaker.sendActions(for: .touchUpInside) }
        workspace.leave = { [weak self] in leave.sendActions(for: .touchUpInside); self?.workspace.onHold = false }

        let audioControl = UIView()
        routePicker.translatesAutoresizingMaskIntoConstraints = false
        audioControl.addSubview(routePicker)
        let audioTitle = UILabel()
        audioTitle.text = "Audio"
        audioTitle.font = .preferredFont(forTextStyle: .caption2)
        audioTitle.textColor = .white
        audioTitle.translatesAutoresizingMaskIntoConstraints = false
        audioControl.addSubview(audioTitle)
        NSLayoutConstraint.activate([
            routePicker.centerXAnchor.constraint(equalTo: audioControl.centerXAnchor),
            routePicker.centerYAnchor.constraint(equalTo: audioControl.centerYAnchor, constant: -7),
            routePicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            routePicker.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            audioTitle.centerXAnchor.constraint(equalTo: audioControl.centerXAnchor),
            audioTitle.bottomAnchor.constraint(equalTo: audioControl.bottomAnchor, constant: -4)
        ])
        audioControl.accessibilityLabel = "Audio output"
        let shareControl = UIView()
        for item in [share, sharePicker, shareTitle] {
            item.translatesAutoresizingMaskIntoConstraints = false
            shareControl.addSubview(item)
        }
        NSLayoutConstraint.activate([
            share.leadingAnchor.constraint(equalTo: shareControl.leadingAnchor),
            share.trailingAnchor.constraint(equalTo: shareControl.trailingAnchor),
            share.topAnchor.constraint(equalTo: shareControl.topAnchor),
            share.bottomAnchor.constraint(equalTo: shareControl.bottomAnchor),
            sharePicker.centerXAnchor.constraint(equalTo: shareControl.centerXAnchor),
            sharePicker.centerYAnchor.constraint(equalTo: shareControl.centerYAnchor, constant: -7),
            sharePicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            sharePicker.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            shareTitle.centerXAnchor.constraint(equalTo: shareControl.centerXAnchor),
            shareTitle.bottomAnchor.constraint(equalTo: shareControl.bottomAnchor, constant: -4)
        ])
        let bar = UIStackView(arrangedSubviews: [microphone, camera, audioControl, shareControl, moreButton, leave])
        bar.axis = .horizontal
        bar.distribution = .fillEqually
        bar.spacing = 4
        bar.backgroundColor = UIColor(red: 0.12, green: 0.14, blue: 0.21, alpha: 0.96)
        bar.layer.cornerRadius = 16
        bar.isLayoutMarginsRelativeArrangement = true
        bar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .lightGray
        statusLabel.text = "Microphone and camera are off"
        statusLabel.textAlignment = .center
        conversationHost.isHidden = true
        conversationHost.backgroundColor = .clear
        for item in [header, streamScroll, bar, statusLabel, zoomControls, shareOffer, conversationHost] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        localShareCard.translatesAutoresizingMaskIntoConstraints = false
        localShareCard.onStop = { [weak self] in self?.onShare?(false) }
        view.addSubview(localShareCard)
        NSLayoutConstraint.activate([
            localShareCard.leadingAnchor.constraint(equalTo: streamScroll.leadingAnchor, constant: 4),
            localShareCard.bottomAnchor.constraint(equalTo: streamScroll.bottomAnchor, constant: -4),
            localShareCard.widthAnchor.constraint(equalToConstant: 216),
            localShareCard.topAnchor.constraint(greaterThanOrEqualTo: streamScroll.topAnchor)
        ])
        let dockWidth = conversationHost.widthAnchor.constraint(equalToConstant: 0)
        conversationWidth = dockWidth
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            participantsButton.widthAnchor.constraint(equalToConstant: 48),
            participantsButton.heightAnchor.constraint(equalToConstant: 48),
            missedButton.widthAnchor.constraint(equalToConstant: 48).withPriority(.defaultHigh),
            missedButton.heightAnchor.constraint(equalToConstant: 48),
            conversationButton.widthAnchor.constraint(equalToConstant: 48),
            conversationButton.heightAnchor.constraint(equalToConstant: 48),
            streamScroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            streamScroll.trailingAnchor.constraint(equalTo: conversationHost.leadingAnchor, constant: -8),
            streamScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            streamScroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -5),
            statusLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -5),
            bar.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            bar.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -16).withPriority(.defaultHigh),
            bar.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            bar.heightAnchor.constraint(equalToConstant: 62),
            zoomControls.topAnchor.constraint(equalTo: streamScroll.topAnchor, constant: 12),
            zoomControls.trailingAnchor.constraint(equalTo: streamScroll.trailingAnchor, constant: -12),
            zoomOutButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            zoomOutButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            fitButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            fitButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            zoomInButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            zoomInButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            shareOffer.centerXAnchor.constraint(equalTo: streamScroll.centerXAnchor),
            shareOffer.topAnchor.constraint(equalTo: streamScroll.topAnchor, constant: 12),
            shareOffer.leadingAnchor.constraint(greaterThanOrEqualTo: streamScroll.leadingAnchor, constant: 8),
            shareOffer.trailingAnchor.constraint(lessThanOrEqualTo: streamScroll.trailingAnchor, constant: -8),
            shareOffer.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            dockWidth,
            conversationHost.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            conversationHost.topAnchor.constraint(equalTo: streamScroll.topAnchor),
            conversationHost.bottomAnchor.constraint(equalTo: streamScroll.bottomAnchor)
        ])
        Publishers.CombineLatest(chat.$unreadCount, store.$timeline)
            .receive(on: DispatchQueue.main).sink { [weak self] count, timeline in
            guard let self else { return }
            self.conversationButton.configuration?.title = count > 0 ? "\(count)" : nil
            self.missedButton.isHidden = timeline.unreadCount == 0
            self.missedButton.configuration?.title = timeline.unreadCount > 0 ?
                "\(timeline.unreadCount)" : nil
            self.missedButton.accessibilityLabel = "Catch up, \(timeline.unreadCount) missed " +
                (timeline.unreadCount == 1 ? "section" : "sections")
            self.conversationButton.accessibilityLabel = count > 0 ?
                "Chat, \(count) unread" : "Chat"
        }.store(in: &subscriptions)
    }

    private func openConversation(_ selected: ConversationMode) {
        guard presentedViewController == nil else { return }
        if view.bounds.width >= 700 {
            if dockedConversation != nil { return }
            let panel = ConversationPanelViewController(catchUp: store, chat: chat,
                initialMode: selected, call: workspace, docked: true)
            panel.onClose = { [weak self] in self?.closeDockedConversation() }
            addChild(panel)
            conversationHost.addSubview(panel.view)
            panel.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                panel.view.leadingAnchor.constraint(equalTo: conversationHost.leadingAnchor),
                panel.view.trailingAnchor.constraint(equalTo: conversationHost.trailingAnchor),
                panel.view.topAnchor.constraint(equalTo: conversationHost.topAnchor),
                panel.view.bottomAnchor.constraint(equalTo: conversationHost.bottomAnchor)
            ])
            panel.didMove(toParent: self)
            dockedConversation = panel
            conversationHost.isHidden = false
            conversationWidth?.constant = min(400, max(320, view.bounds.width * 0.36))
            return
        }
        present(ConversationPanelViewController(catchUp: store, chat: chat,
                                                initialMode: selected, call: workspace),
                animated: true)
    }

    private func closeDockedConversation() {
        guard let panel = dockedConversation else { return }
        panel.willMove(toParent: nil)
        panel.view.removeFromSuperview()
        panel.removeFromParent()
        dockedConversation = nil
        conversationWidth?.constant = 0
        conversationHost.isHidden = true
    }

    private func changePrimaryZoom(by factor: CGFloat) {
        guard let zoom = primaryZoom else { return }
        zoom.setZoomScale(min(zoom.maximumZoomScale,
                              max(zoom.minimumZoomScale, zoom.zoomScale * factor)), animated: true)
    }

    private func updateControlTitles() {
        microphone.configuration?.title = compactControls ? "Mic" : (isMicrophoneOn ? "Mic on" : "Mic off")
        camera.configuration?.title = compactControls ? "Cam" : (isCameraOn ? "Cam on" : "Cam off")
        share.configuration?.title = compactControls ? (isSharingScreen ? "Stop" : "Share") :
            (isSharingScreen ? "Stop share" : "Share")
    }

    private func setPin(_ target: PinnedStream?) {
        pinnedStream = target
        if let room = displayedRoom { render(room: room) }
    }

    func setConnectionRecovering(_ recovering: Bool) {
        preservingPinDuringReconnect = recovering
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let key = interaction.view?.accessibilityIdentifier,
              let target = streamPinTargets[key] else { return nil }
        let name = interaction.view?.accessibilityLabel ?? "Musician"
        let selected = pinnedStream == target
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(
                title: selected ? "Unpin \(name)" : "Pin \(name)",
                image: UIImage(systemName: selected ? "pin.slash" : "pin")) { _ in
                    self?.setPin(selected ? nil : target)
                }])
        }
    }

    func render(room: Room) {
        displayedRoom = room
        let participants: [Participant] = [room.localParticipant] + room.remoteParticipants.values.sorted {
            ($0.identity?.stringValue ?? "") < ($1.identity?.stringValue ?? "")
        }
        let localTrack = room.localParticipant.videoTracks.first {
            $0.source == .screenShareVideo && !$0.isMuted
        }?.track as? VideoTrack
        localShareRenderer.setTrack(localTrack)
        let sharing = room.localParticipant.videoTracks.contains {
            $0.source == .screenShareVideo && !$0.isMuted
        }
        if isSharingScreen != sharing { setSharing(sharing) }
        if let pin = pinnedStream {
            if let owner = participants.first(where: { participantID($0) == pin.participantID }) {
                if pin.isScreenShare && !owner.videoTracks.contains(where: { $0.source == .screenShareVideo }) {
                    pinnedStream = nil
                }
            } else if !preservingPinDuringReconnect {
                pinnedStream = nil
            }
        }
        pinnedStreamKey = pinnedStream.flatMap { pin in
            participants.first(where: { participantID($0) == pin.participantID })?
                .videoTracks.first(where: { ($0.source == .screenShareVideo) == pin.isScreenShare &&
                    !$0.isMuted && $0.track is VideoTrack })?.sid.stringValue
        }
        let identifier = workspace.roomIdentifier.map { " · \($0)" } ?? ""
        countLabel.text = room.remoteParticipants.isEmpty ? "Only you here\(identifier)" :
            "\(participants.count) musicians\(identifier)"
        participantsButton.isEnabled = true
        participantsButton.accessibilityLabel = "Musicians, \(participants.count)"
        participantsPanel?.update(statuses(in: room), pinnedKey: pinnedStreamKey)
        tiles.arrangedSubviews.forEach { $0.removeFromSuperview() }
        speakingLabels.removeAll()
        speakingTiles.removeAll()
        var streams: [(Participant, TrackPublication, VideoTrack)] = []
        for participant in participants {
            let publications = participant.videoTracks.filter {
                !$0.isMuted && $0.track is VideoTrack &&
                    !(participant === room.localParticipant && $0.source == .screenShareVideo)
            }
                .filter { displayMode == .all ||
                    (displayMode == .screenShares && $0.source == .screenShareVideo) }
            if displayMode == .audioOnly ||
                (displayMode == .all && publications.isEmpty && !room.remoteParticipants.isEmpty) {
                tiles.addArrangedSubview(audioTile(for: participant))
            }
            for publication in publications where displayMode != .audioOnly {
                guard let track = publication.track as? VideoTrack else { continue }
                streams.append((participant, publication, track))
            }
        }
        let activeKeys = Set(streams.map { $0.1.sid.stringValue })
        videoTiles = videoTiles.filter { activeKeys.contains($0.key) }
        streamPinTargets = Dictionary(uniqueKeysWithValues: streams.map { stream in
            (stream.1.sid.stringValue, PinnedStream(participantID: participantID(stream.0),
                                                    isScreenShare: stream.1.source == .screenShareVideo))
        })
        if !streams.contains(where: { $0.0 === room.localParticipant && $0.1.source != .screenShareVideo }) {
            NSLayoutConstraint.deactivate(flipCameraConstraints)
            flipCameraConstraints.removeAll()
            flipCamera.removeFromSuperview()
        }
        let pausedCameraPin = displayMode == .all && pinnedStream != nil &&
            pinnedStream?.isScreenShare == false && pinnedStreamKey == nil
        let primary = pausedCameraPin ? nil :
            streams.first { $0.1.sid.stringValue == pinnedStreamKey } ??
            streams.first { $0.1.source == .screenShareVideo } ??
            streams.first { $0.0 is RemoteParticipant } ?? streams.first
        if let pin = pinnedStream, !pin.isScreenShare,
           let share = streams.first(where: { $0.1.source == .screenShareVideo }),
           let offer = streamPinTargets[share.1.sid.stringValue], offer != pin,
           displayMode == .all {
            offeredShare = offer
            shareOffer.configuration?.title = "\(share.0.name ?? "Musician") is sharing · View"
            shareOffer.accessibilityLabel = "View \(share.0.name ?? "Musician") screen share"
            shareOffer.isHidden = false
        } else {
            offeredShare = nil
            shareOffer.isHidden = true
        }
        if pausedCameraPin, let pin = pinnedStream,
           let owner = participants.first(where: { participantID($0) == pin.participantID }) {
            let placeholder = baseTile()
            let name = UILabel()
            name.text = "\(owner.name ?? "Musician") · Camera off · Pinned"
            name.textColor = .white
            name.textAlignment = .center
            name.numberOfLines = 0
            let unpin = UIButton(type: .system)
            unpin.configuration = .tinted()
            unpin.configuration?.title = "Unpin"
            unpin.addAction(UIAction { [weak self] _ in self?.setPin(nil) }, for: .touchUpInside)
            let column = UIStackView(arrangedSubviews: [name, unpin])
            column.axis = .vertical
            column.alignment = .center
            column.spacing = 12
            column.translatesAutoresizingMaskIntoConstraints = false
            placeholder.addSubview(column)
            NSLayoutConstraint.activate([
                placeholder.heightAnchor.constraint(equalTo: streamScroll.frameLayoutGuide.heightAnchor),
                column.centerXAnchor.constraint(equalTo: placeholder.centerXAnchor),
                column.centerYAnchor.constraint(equalTo: placeholder.centerYAnchor),
                column.leadingAnchor.constraint(greaterThanOrEqualTo: placeholder.leadingAnchor, constant: 16),
                column.trailingAnchor.constraint(lessThanOrEqualTo: placeholder.trailingAnchor, constant: -16)
            ])
            tiles.insertArrangedSubview(placeholder, at: 0)
            floatingVideo?.clear()
            currentPrimaryKey = nil
            primaryZoom = nil
            fitButton.isHidden = true
            zoomControls.isHidden = true
            for stream in streams {
                let tile = videoTile(for: stream.0, publication: stream.1,
                                     track: stream.2, primary: false)
                tiles.addArrangedSubview(tile)
                setVideoTileHeight(for: stream.1.sid.stringValue, primary: false,
                                   isShare: stream.1.source == .screenShareVideo)
            }
        } else if let primary {
            let primaryKey = primary.1.sid.stringValue
            zoomControls.isHidden = primary.1.source != .screenShareVideo
            fitButton.isHidden = (videoTiles[primaryKey]?.zoom.zoomScale ?? 1) <= 1.01
            floatingVideo?.show(track: primary.0 is RemoteParticipant ? primary.2 : nil,
                                name: primary.0.name ?? "Musician",
                                isScreenShare: primary.1.source == .screenShareVideo)
            // The selected stream fills the available viewing area. Other streams remain below it.
            let primaryTile = videoTile(for: primary.0, publication: primary.1,
                                        track: primary.2, primary: true)
            tiles.insertArrangedSubview(primaryTile, at: 0)
            setVideoTileHeight(for: primaryKey, primary: true, isShare: primary.1.source == .screenShareVideo)
            for stream in streams where stream.1.sid != primary.1.sid {
                let tile = videoTile(for: stream.0, publication: stream.1,
                                     track: stream.2, primary: false)
                tiles.addArrangedSubview(tile)
                setVideoTileHeight(for: stream.1.sid.stringValue, primary: false,
                                   isShare: stream.1.source == .screenShareVideo)
            }
            if currentPrimaryKey != primaryKey { streamScroll.setContentOffset(.zero, animated: false) }
            currentPrimaryKey = primaryKey
        } else {
            floatingVideo?.clear()
            currentPrimaryKey = nil
            primaryZoom = nil
            fitButton.isHidden = true
            zoomControls.isHidden = true
        }
        if displayMode == .screenShares && streams.isEmpty {
            let empty = UILabel()
            empty.text = "No screen share is live. Audio continues."
            empty.textColor = .lightGray
            empty.textAlignment = .center
            empty.numberOfLines = 0
            tiles.addArrangedSubview(empty)
            empty.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        }
        if room.remoteParticipants.isEmpty && streams.isEmpty && displayMode == .all {
            let waiting = waitingRoomView()
            tiles.addArrangedSubview(waiting)
            waiting.heightAnchor.constraint(equalTo: streamScroll.frameLayoutGuide.heightAnchor).isActive = true
        }
        refreshSpeaking(room: room)
        configureMoreMenu()
    }

    private func waitingRoomView() -> UIView {
        let view = UIView()
        let title = UILabel()
        title.text = "You're connected. Waiting for others."
        title.textColor = .white
        title.font = .preferredFont(forTextStyle: .title3)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        title.textAlignment = .center
        let column = UIStackView(arrangedSubviews: [title])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 12
        if workspace.invitationURL != nil {
            let invite = UIButton(type: .system)
            invite.configuration = .tinted()
            invite.configuration?.title = "Invite musicians"
            invite.configuration?.image = UIImage(systemName: "square.and.arrow.up")
            invite.tintColor = accent
            invite.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.workspace.shareInvitation(from: invite)
            }, for: .touchUpInside)
            let copy = UIButton(type: .system)
            copy.configuration = .plain()
            copy.configuration?.title = "Copy link"
            copy.tintColor = accent
            copy.addAction(UIAction { [weak self] _ in self?.workspace.copyInvitation() },
                           for: .touchUpInside)
            column.addArrangedSubview(invite)
            column.addArrangedSubview(copy)
        }
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16)
        ])
        return view
    }

    private func audioTile(for participant: Participant) -> UIView {
        let tile = baseTile()
        let name = UILabel()
        name.text = participant.name ?? "Musician"
        name.textColor = .white
        name.font = .systemFont(ofSize: 16, weight: .semibold)
        let state = UILabel()
        state.text = participant.audioTracks.contains { !$0.isMuted } ? "Microphone on" : "Microphone off"
        state.textColor = .lightGray
        state.font = .preferredFont(forTextStyle: .caption1)
        let id = participantID(participant)
        speakingLabels[id] = state
        speakingTiles[id, default: []].append(tile)
        let column = UIStackView(arrangedSubviews: [name, state])
        column.axis = .vertical
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(column)
        NSLayoutConstraint.activate([
            tile.heightAnchor.constraint(equalToConstant: 72),
            column.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -14),
            column.centerYAnchor.constraint(equalTo: tile.centerYAnchor)
        ])
        return tile
    }

    private func videoTile(for participant: Participant, publication: TrackPublication,
                           track: VideoTrack, primary: Bool) -> UIView {
        let isShare = publication.source == .screenShareVideo
        let key = publication.sid.stringValue
        if var cached = videoTiles[key] {
            configureVideoTile(&cached, participant: participant, track: track,
                               isShare: isShare, primary: primary, key: key)
            videoTiles[key] = cached
            speakingTiles[participantID(participant), default: []].append(cached.tile)
            return cached.tile
        }
        let tile = baseTile()
        tile.accessibilityIdentifier = key
        tile.accessibilityLabel = "\(participant.name ?? "Musician") \(isShare ? "screen share" : "video")"
        tile.addInteraction(UIContextMenuInteraction(delegate: self))
        let zoom = UIScrollView()
        zoom.minimumZoomScale = 1
        zoom.maximumZoomScale = isShare ? 5 : 2
        zoom.bouncesZoom = true
        zoom.delegate = self
        zoom.accessibilityIdentifier = key
        zoom.accessibilityLabel = isShare ? "Pinch to zoom screen share" : "Video stream"
        zoom.accessibilityValue = "100%"
        zoom.translatesAutoresizingMaskIntoConstraints = false
        let video = VideoView()
        // Use the same color-managed renderer as the floating video surface.
        video.renderMode = .sampleBuffer
        video.layoutMode = isShare ? .fit : .fill
        video.track = track
        video.translatesAutoresizingMaskIntoConstraints = false
        zoom.addSubview(video)
        tile.addSubview(zoom)
        let name = UILabel()
        name.text = "  \(participant.name ?? "Musician") · \(isShare ? "Screen" : "Video") · \(pinnedStreamKey == key ? "Pinned" : "Auto")  "
        name.textColor = .white
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        name.layer.cornerRadius = 7
        name.clipsToBounds = true
        name.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(name)
        let pin = UIButton(type: .system)
        pin.configuration = .tinted()
        pin.configuration?.image = UIImage(systemName: pinnedStreamKey == key ? "pin.fill" : "pin")
        pin.accessibilityLabel = pinnedStreamKey == key ? "Unpin \(participant.name ?? "Musician") \(isShare ? "screen" : "video")" :
            "Pin \(participant.name ?? "Musician") \(isShare ? "screen" : "video")"
        pin.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let target = PinnedStream(participantID: self.participantID(participant),
                                      isScreenShare: isShare)
            self.setPin(self.pinnedStream == target ? nil : target)
        }, for: .touchUpInside)
        pin.accessibilityHint = "Changes only your view"
        pin.showsLargeContentViewer = true
        pin.largeContentTitle = pin.accessibilityLabel
        pin.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(pin)
        speakingTiles[participantID(participant), default: []].append(tile)
        NSLayoutConstraint.activate([
            zoom.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            zoom.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            zoom.topAnchor.constraint(equalTo: tile.topAnchor),
            zoom.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
            video.leadingAnchor.constraint(equalTo: zoom.contentLayoutGuide.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: zoom.contentLayoutGuide.trailingAnchor),
            video.topAnchor.constraint(equalTo: zoom.contentLayoutGuide.topAnchor),
            video.bottomAnchor.constraint(equalTo: zoom.contentLayoutGuide.bottomAnchor),
            video.widthAnchor.constraint(equalTo: zoom.frameLayoutGuide.widthAnchor),
            video.heightAnchor.constraint(equalTo: zoom.frameLayoutGuide.heightAnchor),
            name.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 10),
            name.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -10),
            pin.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -10),
            pin.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -8),
            pin.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            pin.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        if let state = zoomStates[key] {
            DispatchQueue.main.async { [weak zoom] in
                guard let zoom, zoom.window != nil else { return }
                zoom.setZoomScale(state.0, animated: false)
                zoom.setContentOffset(state.1, animated: false)
            }
        }
        var entry = VideoTile(tile: tile, zoom: zoom, video: video, name: name, pin: pin)
        configureVideoTile(&entry, participant: participant, track: track,
                           isShare: isShare, primary: primary, key: key)
        videoTiles[key] = entry
        return tile
    }

    private func configureVideoTile(_ entry: inout VideoTile, participant: Participant,
                                    track: VideoTrack, isShare: Bool, primary: Bool, key: String) {
        if entry.video.track !== track { entry.video.track = track }
        entry.video.layoutMode = isShare ? .fit : .fill
        entry.name.text = "  \(participant.name ?? "Musician") · \(isShare ? "Screen" : "Video") · \(pinnedStreamKey == key ? "Pinned" : "Auto")  "
        entry.pin.configuration?.image = UIImage(systemName: pinnedStreamKey == key ? "pin.fill" : "pin")
        entry.pin.accessibilityLabel = pinnedStreamKey == key
            ? "Unpin \(participant.name ?? "Musician") \(isShare ? "screen" : "video")"
            : "Pin \(participant.name ?? "Musician") \(isShare ? "screen" : "video")"
        entry.pin.largeContentTitle = entry.pin.accessibilityLabel
        if primary { primaryZoom = entry.zoom }
        if participant === displayedRoom?.localParticipant && !isShare {
            if flipCamera.superview !== entry.tile {
                NSLayoutConstraint.deactivate(flipCameraConstraints)
                flipCamera.translatesAutoresizingMaskIntoConstraints = false
                entry.tile.addSubview(flipCamera)
                flipCameraConstraints = [
                    flipCamera.topAnchor.constraint(equalTo: entry.tile.topAnchor, constant: 8),
                    flipCamera.trailingAnchor.constraint(equalTo: entry.tile.trailingAnchor, constant: -8),
                    flipCamera.widthAnchor.constraint(equalToConstant: 44),
                    flipCamera.heightAnchor.constraint(equalToConstant: 44)
                ]
                NSLayoutConstraint.activate(flipCameraConstraints)
            }
            flipCamera.isHidden = !isCameraOn
        }
    }

    private func setVideoTileHeight(for key: String, primary: Bool, isShare: Bool) {
        guard var entry = videoTiles[key] else { return }
        entry.heightConstraint?.isActive = false
        entry.heightConstraint = primary
            ? entry.tile.heightAnchor.constraint(equalTo: streamScroll.frameLayoutGuide.heightAnchor)
            : entry.tile.heightAnchor.constraint(equalToConstant: isShare ? 240 : 185)
        entry.heightConstraint?.isActive = true
        videoTiles[key] = entry
    }

    private func participantID(_ participant: Participant) -> String {
        participant.identity?.stringValue ?? participant.sid?.stringValue ?? "local"
    }

    private func statuses(in room: Room) -> [ParticipantStatus] {
        let participants: [Participant] = [room.localParticipant] + room.remoteParticipants.values.sorted {
            ($0.name ?? "") < ($1.name ?? "")
        }
        return participants.map { participant in
            let videos = participant.videoTracks.filter { !$0.isMuted }
            return ParticipantStatus(id: participantID(participant),
                name: participant.name ?? "Musician", isLocal: participant === room.localParticipant,
                microphoneOn: participant.audioTracks.contains { !$0.isMuted },
                cameraOn: videos.contains { $0.source != .screenShareVideo },
                screenShareOn: videos.contains { $0.source == .screenShareVideo },
                isSpeaking: participant.isSpeaking,
                videoKey: videos.first { $0.source != .screenShareVideo && $0.track is VideoTrack }?.sid.stringValue,
                shareKey: participant === room.localParticipant ? nil :
                    videos.first { $0.source == .screenShareVideo && $0.track is VideoTrack }?.sid.stringValue)
        }
    }

    func refreshSpeaking(room: Room) {
        participantsPanel?.update(statuses(in: room), pinnedKey: pinnedStreamKey)
        for participant in [room.localParticipant] + Array(room.remoteParticipants.values) {
            let id = participantID(participant)
            if let label = speakingLabels[id] {
                label.text = participant.isSpeaking ? "Speaking" :
                    (participant.audioTracks.contains { !$0.isMuted } ? "Microphone on" : "Microphone off")
                label.textColor = participant.isSpeaking ? .systemGreen : .lightGray
            }
            for tile in speakingTiles[id] ?? [] {
                tile.layer.borderWidth = participant.isSpeaking ? 3 : 0
                tile.layer.borderColor = UIColor.systemGreen.cgColor
            }
        }
    }

    private func baseTile() -> UIView {
        let tile = UIView()
        tile.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1)
        tile.layer.cornerRadius = 14
        tile.clipsToBounds = true
        return tile
    }

    private func configureModeMenu() {
        displayModeButton.menu = UIMenu(children: ConferenceDisplayMode.allCases.map { option in
            UIAction(title: option.title, image: UIImage(systemName: option.symbol),
                     state: option == displayMode ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.displayMode = option
                self.displayModeButton.configuration?.image = UIImage(systemName: option.symbol)
                self.displayModeButton.accessibilityLabel = "Display: \(option.title)"
                self.configureModeMenu()
                if let room = self.displayedRoom { self.render(room: room) }
                self.onDisplayMode?(option)
            }
        })
    }

    private func configureMoreMenu() {
        moreButton.accessibilityValue = floatingVideo?.canShow == true ? "Floating video available" : nil
        var items: [UIMenuElement] = []
        if workspace.invitationURL != nil {
            items.append(UIAction(title: "Invite musicians", image: UIImage(systemName: "square.and.arrow.up")) {
                [weak self] _ in guard let self else { return }
                self.workspace.shareInvitation(from: self.moreButton)
            })
            items.append(UIAction(title: "Copy link", image: UIImage(systemName: "doc.on.doc")) {
                [weak self] _ in self?.workspace.copyInvitation()
            })
        }
        items += [
            UIAction(title: "Show floating video", image: UIImage(systemName: "pip.enter"),
                     attributes: floatingVideo?.canShow == true && !isHeld ? [] : [.disabled]) {
                [weak self] _ in self?.floatingVideo?.start()
            },
            UIAction(title: "Floating video when multitasking",
                     image: UIImage(systemName: "pip"),
                     state: FloatingVideoPreference.enabled ? .on : .off) { [weak self] _ in
                FloatingVideoPreference.enabled.toggle()
                self?.floatingVideo?.refreshPreference()
                self?.configureMoreMenu()
            },
            UIMenu(title: "View", children: ConferenceDisplayMode.allCases.map { option in
                UIAction(title: option.title, image: UIImage(systemName: option.symbol),
                         state: option == displayMode ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    self.displayMode = option
                    self.configureMoreMenu()
                    if let room = self.displayedRoom { self.render(room: room) }
                    self.onDisplayMode?(option)
                }
            }),
            UIAction(title: isSpeakerOn ? "Use iPhone receiver" : "Use iPhone speaker",
                     image: UIImage(systemName: "speaker.wave.2")) { [weak self] _ in
                guard let self else { return }
                self.isSpeakerOn.toggle()
                self.workspace.speakerOn = self.isSpeakerOn
                self.onSpeaker?(self.isSpeakerOn)
                self.configureMoreMenu()
            },
            UIAction(title: "Flip camera", image: UIImage(systemName: "camera.rotate"),
                     attributes: isCameraOn ? [] : [.disabled]) { [weak self] _ in
                self?.onFlipCamera?()
            }
        ]
        moreButton.menu = UIMenu(children: items)
    }

    func setSharing(_ enabled: Bool) {
        isSharingScreen = enabled
        if #available(iOS 27.0, *) {
            share.isHidden = false
            sharePicker.isHidden = true
            shareTitle.isHidden = true
        } else {
            share.isHidden = !enabled
            sharePicker.isHidden = enabled
            shareTitle.isHidden = enabled
        }
        share.configuration?.image = UIImage(systemName: enabled ? "rectangle.slash" : "rectangle.on.rectangle")
        updateControlTitles()
        share.configuration?.baseForegroundColor = enabled ? accent : .white
        share.accessibilityLabel = enabled ? "Stop sharing screen" : "Share screen"
    }

    func setMicrophone(_ enabled: Bool) {
        isMicrophoneOn = enabled
        workspace.microphoneOn = enabled
        microphone.configuration?.image = UIImage(systemName: enabled ? "mic.fill" : "mic.slash.fill")
        updateControlTitles()
        microphone.configuration?.baseForegroundColor = enabled ? accent : .white
        microphone.accessibilityLabel = enabled ? "Mute microphone" : "Unmute microphone"
        microphone.largeContentTitle = microphone.accessibilityLabel
        updateStatus()
    }

    func setFloatingMicrophoneStatus(_ status: PiPMicrophoneStatus) {
        floatingVideo?.setMicrophoneStatus(status)
    }

    func setCamera(_ enabled: Bool) {
        isCameraOn = enabled
        workspace.cameraOn = enabled
        flipCamera.isEnabled = enabled
        configureMoreMenu()
        camera.configuration?.image = UIImage(systemName: enabled ? "video.fill" : "video.slash.fill")
        updateControlTitles()
        camera.configuration?.baseForegroundColor = enabled ? accent : .white
        camera.accessibilityLabel = enabled ? "Stop video" : "Start video"
        camera.largeContentTitle = camera.accessibilityLabel
        updateStatus()
    }

    func setHeld(_ held: Bool) {
        isHeld = held
        workspace.onHold = held
        floatingVideo?.setSuspended(held)
        configureMoreMenu()
        updateStatus()
    }

    func prepareToFloat() {
        floatingVideo?.setSuspended(isHeld || displayMode == .audioOnly)
    }

    func restoreFromFloatingVideo() { floatingVideo?.foregrounded() }

    func endFloatingVideo() { floatingVideo?.clear(); localShareRenderer.setTrack(nil); localSharePreview.end() }

    func showMediaStatus(_ message: String?) {
        mediaStatus = message
        updateStatus()
    }

    func setAudioRouteName(_ name: String) {
        routeLabel.text = "Audio · \(name)"
        workspace.routeName = name
    }

    private func updateStatus() {
        statusLabel.text = isHeld ? "Jam on hold for another call" :
            (mediaStatus ?? "Microphone \(isMicrophoneOn ? "on" : "off") · Camera \(isCameraOn ? "on" : "off")")
        statusLabel.textColor = mediaStatus == nil ? .lightGray : .systemOrange
    }

    private func configure(_ button: UIButton, symbol: String, label: String, title: String? = nil) {
        var style = UIButton.Configuration.plain()
        style.image = UIImage(systemName: symbol)
        style.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 19)
        style.title = title
        style.imagePlacement = .top
        style.imagePadding = 2
        style.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0)
        style.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 12, weight: .medium)
            return attributes
        }
        style.baseForegroundColor = accent
        button.configuration = style
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.accessibilityLabel = label
        button.showsLargeContentViewer = true
        button.largeContentTitle = label
        button.largeContentImage = UIImage(systemName: symbol)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        scrollView === streamScroll ? nil : scrollView.subviews.first { $0 is VideoView }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        if scrollView !== streamScroll {
            scrollView.accessibilityValue = "\(Int((scrollView.zoomScale * 100).rounded()))%"
            if let key = scrollView.accessibilityIdentifier {
                zoomStates[key] = (scrollView.zoomScale, scrollView.contentOffset)
            }
            if scrollView === primaryZoom { fitButton.isHidden = scrollView.zoomScale <= 1.01 }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView !== streamScroll, let key = scrollView.accessibilityIdentifier else { return }
        zoomStates[key] = (scrollView.zoomScale, scrollView.contentOffset)
    }
}
