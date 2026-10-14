import ConferenceCore
import AVKit
import Combine
import LiveKit
import ReplayKit
import UIKit

@MainActor
final class RockCallViewController: UIViewController, UIScrollViewDelegate, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var shouldAutorotate: Bool { true }
    private let spacebarShortcut = CallSpacebarShortcut()
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = spacebarShortcut.began(presses, in: view) { self.keyToggleMicrophone() }
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = spacebarShortcut.ended(presses)
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        spacebarShortcut.reset()
        super.pressesCancelled(presses, with: event)
    }
    override var keyCommands: [UIKeyCommand]? {
        CallKeyboardCommands.make(microphone: #selector(keyToggleMicrophone), camera: #selector(keyToggleCamera),
            chat: #selector(keyOpenChat), participants: #selector(keyOpenParticipants), fit: #selector(keyFitScreen), focus: #selector(keyFocus), restore: #selector(keyRestoreControls)) +
            [UIKeyCommand(input: ",", modifierFlags: .command, action: #selector(keyOpenStudio))]
    }
    var onLeave: (() -> Void)?
    var onMicrophone: ((Bool) -> Void)?
    var onCamera: ((Bool) -> Void)?
    var onSpeaker: ((Bool) -> Void)?
    var onShare: ((Bool) -> Void)?
    var onVideoDemandChanged: (() -> Void)?
    var onFloatingChanged: ((Bool) -> Void)?
    var onDisplayMode: ((ConferenceDisplayMode) -> Void)?
    var studio: StudioModel?
    let activeSpeaker = ActiveSpeakerStore()
    private var speakerReceptionAvailable = true

    private let focus = CallFocusController()
    private var headerView: UIStackView?
    private let compactHeader = CompactCallHeader()
    private var toolbar: CallToolbar?
    private let focusButton = UIButton(type: .system)
    private var browsedStream: PinnedStream?
    private var orderedStreams: [PinnedStream] = []
    private let broadcastAppearance = AlignedCallButton(frame: .zero)
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let routeLabel = UILabel()
    private let statusLabel = UILabel()
    private let tiles = CallTileContainer()
    private var layoutMode: MeetingLayoutMode = .grid
    private var explicitLayout = false
    private let layoutControls = MeetingLayoutControls()
    private let participantStrip = MeetingParticipantStrip()
    private var galleryPage = 0
    private var galleryCapacity = 0
    private var gallerySize = CGSize.zero
    private var restoreGalleryPage = true
    private var rosterOrder: [String] = []
    private var identityTiles: [String: UIView] = [:]
    private var identityViews: [String: ParticipantIdentityView] = [:]
    private var tileSelections: [ObjectIdentifier: PinnedStream] = [:]
    private var effectiveLayoutMode: MeetingLayoutMode {
        guard layoutMode == .grid, let key = currentPrimaryKey, let source = streamPinTargets[key],
              source.isScreenShare, !explicitLayout else { return layoutMode }
        return .speaker
    }
    private let streamScroll = UIScrollView()
    private let conversationHost = UIView()
    private var conversationWidth: NSLayoutConstraint?
    private var dockedConversation: ConversationPanelViewController?
    private let microphone = AlignedCallButton(frame: .zero)
    private let camera = AlignedCallButton(frame: .zero)
    private let flipCamera = UIButton(type: .system)
    private let speaker = UIButton(type: .system)
    private let share = AlignedCallButton(frame: .zero)
    private let sharePicker = RPSystemBroadcastPickerView()
    private let shareTitle = UILabel()
    private let displayModeButton = UIButton(type: .system)
    private let conversationButton = UIButton(type: .system)
    private let missedButton = UIButton(type: .system)
    private let participantsButton = UIButton(type: .system)
    private let moreButton = AlignedCallButton(frame: .zero)
    private let fitButton = UIButton(type: .system)
    private let zoomInButton = UIButton(type: .system)
    private let zoomOutButton = UIButton(type: .system)
    private let zoomControls = UIStackView()
    private lazy var zoomVisibility = TransientCallControls(view: zoomControls)
    private let shareOffer = UIButton(type: .system)
    let localSharePreview = LocalSharePreview()
    private lazy var localShareCard = LocalSharePreviewCard(model: localSharePreview)
    private lazy var localShareRenderer = LocalShareTrackPreview(preview: localSharePreview)
    #if DEBUG
    var fixtureParticipants: [ParticipantStatus]?
    var fixtureActions: [UIAction] = [] { didSet { configureMoreMenu() } }
    #endif
    private struct PinnedStream: Equatable {
        let participantID: String
        let isScreenShare: Bool
    }
    private struct VideoTile {
        let tile: UIView
        let zoom: UIScrollView
        let video: CallVideoView
        let badge: ParticipantMediaBadge
        let pin: UIButton
        var viewportSize = CGSize.zero
    }
    private var videoTiles: [String: VideoTile] = [:]
    private var flipCameraConstraints: [NSLayoutConstraint] = []
    private var currentPrimaryKey: String?
    private var floatingVideo: RockVideoPictureInPicture?
    // Scale and normalized viewport center survive rotation and Focus layout changes.
    private var zoomStates: [String: (CGFloat, CGPoint)] = [:]
    private var restoringZoom = false
    private var primaryName: String?
    private weak var primaryZoom: UIScrollView?
    private weak var participantsPanel: ParticipantPanelViewController?
    private var pinnedStreamKey: String?
    private var pinnedStream: PinnedStream?
    private var preservingPinDuringReconnect = false
    private var streamPinTargets: [String: PinnedStream] = [:]
    private var offeredShare: PinnedStream?
    private var participantBadges: [String: [ParticipantMediaBadge]] = [:]
    private var speakingTiles: [String: [UIView]] = [:]
    private var tileOrder: [ObjectIdentifier: String] = [:]
    private let store: CatchUpStore
    private let chat: ChatStore
    let workspace = CallWorkspaceControls()
    var localCameraPreview: CameraCapturePreview?
    private var displayedSnapshot: CallMediaSnapshot?
    var supportsChat = true
    var supportsSharing = true
    var usesNativeShareControl = false
    var sharingAvailable = true {
        didSet {
            share.isEnabled = sharingAvailable || isSharingScreen
            sharePicker.isUserInteractionEnabled = sharingAvailable
        }
    }
    var sharePreview: LocalSharePreview { localSharePreview }
    func setRoomTitle(_ title: String) { titleLabel.text = title; view.setNeedsLayout() }
    #if DEBUG
    var snapshotForTesting: CallMediaSnapshot? { displayedSnapshot }
    #endif
    private var displayMode: ConferenceDisplayMode = .all
    private var localMicrophoneStatus: PiPMicrophoneStatus?
    private var isMicrophoneOn = false
    private var isCameraOn = false
    private var isSpeakerOn = true
    private var isSharingScreen = false
    private var isHeld = false
    private var mediaStatus: String?
    private var subscriptions = Set<AnyCancellable>()
    private let accent = UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1)

    @objc private func keyToggleMicrophone() { microphone.sendActions(for: .touchUpInside) }
    @objc private func keyToggleCamera() { camera.sendActions(for: .touchUpInside) }
    @objc private func keyOpenStudio() {
        guard let studio else { return }
        StudioPresentation.show(studio, from: moreButton)
    }
    @objc private func keyOpenChat() { openConversation(.chat) }
    @objc private func keyOpenParticipants() { participantsButton.sendActions(for: .touchUpInside) }
    @objc private func keyFocus() { focus.toggle() }
    @objc private func keyRestoreControls() { focus.show(); focus.interaction() }
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
        focus.interaction()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutCall()
        onVideoDemandChanged?()
    }

    private func installFocus() {
        // Media, transcript and controls use a common visible-window geometry.
        NSLayoutConstraint.deactivate(view.constraints)
        for item in [headerView!, toolbar!, streamScroll, statusLabel, zoomControls, shareOffer, conversationHost, localShareCard] {
            NSLayoutConstraint.deactivate(item.constraints.filter { $0.firstItem === item && $0.secondItem == nil })
            item.translatesAutoresizingMaskIntoConstraints = true
        }
        focus.onChange = { [weak self] _ in
            guard let self else { return }
            if let snapshot = self.displayedSnapshot { self.render(snapshot: snapshot) }
            self.view.setNeedsLayout()
        }
        focus.canHide = { [weak self] in
            guard let self else { return false }
            return !self.isHeld && self.mediaStatus == nil && self.presentedViewController == nil && self.dockedConversation == nil
        }
        view.addSubview(layoutControls); view.addSubview(participantStrip)
        layoutControls.onLayout = { [weak self] in self?.chooseLayout($0) }
        layoutControls.onAutomatic = { [weak self] in self?.browsedStream = nil; self?.setPin(nil) }
        layoutControls.onPage = { [weak self] in self?.moveGalleryPage($0) }
        participantStrip.onSelect = { [weak self] key in
            guard let self, let target = self.streamPinTargets[key] else { return }; self.setPin(target)
        }
        focusButton.configuration = .tinted()
        focusButton.configuration?.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
        focusButton.accessibilityLabel = L("Hide controls")
        focusButton.addAction(UIAction { [weak self] _ in self?.focus.hide() }, for: .touchUpInside)
        view.addSubview(focusButton)
        view.addSubview(compactHeader)
        focus.installHint(in: view)
        compactHeader.previous.addAction(UIAction { [weak self] _ in self?.browse(-1) }, for: .touchUpInside)
        compactHeader.nextStream.addAction(UIAction { [weak self] _ in self?.browse(1) }, for: .touchUpInside)
        compactHeader.automatic.addAction(UIAction { [weak self] _ in
            self?.browsedStream = nil; self?.setPin(nil)
            self?.focus.interaction()
        }, for: .touchUpInside)
        compactHeader.pin.addAction(UIAction { [weak self] _ in
            guard let self, let key = self.currentPrimaryKey else { return }
            self.videoTiles[key]?.pin.sendActions(for: .touchUpInside)
            self.focus.interaction()
        }, for: .touchUpInside)
        for (button, action) in [(compactHeader.participants, participantsButton),
                                 (compactHeader.missed, missedButton),
                                 (compactHeader.conversation, conversationButton), (compactHeader.focus, focusButton)] {
            button.addAction(UIAction { [weak action] _ in action?.sendActions(for: .touchUpInside) }, for: .touchUpInside)
        }
        compactHeader.details.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.workspace.showDetails(from: self.compactHeader.details, presenter: self,
                title: self.titleLabel.text ?? L("Jam"),
                lines: [self.countLabel.text, self.workspace.roomIdentifier, self.routeLabel.text,
                        self.statusLabel.text].compactMap { $0 })
        }, for: .touchUpInside)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedStage(_:)))
        tap.delegate = self; tap.cancelsTouchesInView = false
        streamScroll.addGestureRecognizer(tap)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedStage(_:)))
            swipe.direction = direction; swipe.delegate = self
            streamScroll.addGestureRecognizer(swipe)
        }
        moreButton.onMenuVisibilityChanged = { [weak self] in self?.focus.menuVisible = $0 }
        updateControlTitles()
        focus.interaction()
    }

    private func layoutCall() {
        guard let toolbar, let header = headerView else { return }
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        toolbar.arrange(rail: false, largeText: large)
        let statusHeight = ceil(statusLabel.font.lineHeight)
        let identityHeight = header.systemLayoutSizeFitting(CGSize(width: view.bounds.width - 24, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let headerHeight = max(80, identityHeight + statusHeight + 8)
        let geometry = CallPresentationGeometry(bounds: view.bounds, insets: view.safeAreaInsets,
            headerHeight: headerHeight, toolbarHeight: toolbar.preferredHeight, hidden: focus.hidden,
            largeText: large, allowsRail: dockedConversation == nil)
        toolbar.arrange(rail: geometry.rail, largeText: large)
        header.frame = geometry.header.insetBy(dx: 4, dy: 0)
        header.frame.size.height = max(0, geometry.header.height - statusHeight - 8)
        toolbar.frame = geometry.toolbar
        var stage = geometry.stage
        if dockedConversation != nil {
            let width = view.bounds.width >= 700 ? min(400, max(320, view.bounds.width * 0.36)) : stage.width
            conversationHost.frame = CGRect(x: stage.maxX - width, y: stage.minY, width: width, height: stage.height)
            stage.size.width = max(0, stage.width - width - 8)
        }
        for entry in videoTiles.values where entry.zoom.window != nil { rememberZoom(entry.zoom) }
        restoringZoom = true
        let layoutAvailable = displayedSnapshot?.remoteParticipants.isEmpty == false && displayMode != .audioOnly
        let layoutFrame = CGRect(x: stage.minX, y: stage.minY, width: stage.width, height: 44)
        layoutControls.isHidden = !layoutAvailable || focus.hidden || geometry.compactHeader
        if !layoutControls.isHidden {
            layoutControls.frame = layoutFrame
            layoutControls.frame.size.width = max(0, layoutFrame.width - 56)
            stage.origin.y += 48; stage.size.height = max(0, stage.height - 48)
        }
        participantStrip.isHidden = effectiveLayoutMode == .grid || !layoutAvailable || focus.hidden
        if !participantStrip.isHidden {
            participantStrip.vertical = stage.width >= 800
            if participantStrip.vertical {
                participantStrip.frame = CGRect(x: stage.maxX - 196, y: stage.minY, width: 196, height: stage.height)
                stage.size.width = max(0, stage.width - 208)
            } else {
                participantStrip.frame = CGRect(x: stage.minX, y: stage.maxY - 52, width: stage.width, height: 52)
                stage.size.height = max(0, stage.height - 60)
            }
        }
        streamScroll.frame = stage
        tiles.arrange(size: stage.size, mode: effectiveLayoutMode)
        if effectiveLayoutMode != .grid { restoreGalleryPage = true }
        if effectiveLayoutMode == .grid, let pagination = tiles.pagination {
            let oldPage = galleryPage
            let geometryChanged = gallerySize != stage.size || galleryCapacity != pagination.capacity
            if galleryCapacity > 0, galleryCapacity != pagination.capacity {
                galleryPage = galleryPage * galleryCapacity / pagination.capacity
            }
            gallerySize = stage.size
            galleryCapacity = pagination.capacity
            galleryPage = min(galleryPage, pagination.pageCount - 1)
            restoreGalleryPage = restoreGalleryPage || geometryChanged || oldPage != galleryPage
        }
        streamScroll.isPagingEnabled = effectiveLayoutMode == .grid
        if effectiveLayoutMode == .grid && restoreGalleryPage && !streamScroll.isDragging && !streamScroll.isDecelerating {
            streamScroll.setContentOffset(CGPoint(x: CGFloat(galleryPage) * stage.width, y: 0), animated: false)
            restoreGalleryPage = false
        }
        refreshLayoutControls()
        streamScroll.layoutIfNeeded()
        for (key, var entry) in videoTiles where entry.zoom.window != nil && entry.zoom.bounds.size != entry.viewportSize {
            restoreZoom(entry.zoom, key: key)
            entry.viewportSize = entry.zoom.bounds.size
            videoTiles[key] = entry
        }
        restoringZoom = false
        streamScroll.isScrollEnabled = effectiveLayoutMode == .grid
        streamScroll.isAccessibilityElement = focus.hidden && primaryZoom == nil
        streamScroll.accessibilityLabel = L("Meeting content")
        streamScroll.accessibilityCustomActions = focus.hidden ? [focus.restoreAccessibilityAction()] : nil
        header.isHidden = focus.hidden || geometry.compactHeader; toolbar.isHidden = focus.hidden
        compactHeader.frame = geometry.header
        compactHeader.isHidden = focus.hidden || !geometry.compactHeader
        let pin = currentPrimaryKey.flatMap { videoTiles[$0]?.pin }
        let sourceName = (primaryName ?? titleLabel.text ?? L("Jam")) +
            (currentPrimaryKey.flatMap { streamPinTargets[$0]?.isScreenShare } == true ? L(" · Screen") : "")
        compactHeader.update(name: isHeld || mediaStatus != nil ? statusLabel.text ?? L("Jam") : sourceName,
            navigation: false, browsing: browsedStream != nil, pinned: pinnedStream != nil,
            pinLabel: pin?.accessibilityLabel, participantsLabel: participantsButton.accessibilityLabel,
            chatValue: chat.unreadCount > 0 ? conversationButton.accessibilityLabel : nil,
            chatCount: chat.unreadCount, missedCount: store.timeline.unreadCount,
            status: isHeld || mediaStatus != nil ? statusLabel.text : nil,
            speaking: activeSpeaker.current, focusAvailable: primaryZoom != nil, chatAvailable: supportsChat)
        compactHeader.setLayout(mode: effectiveLayoutMode, available: layoutAvailable,
            choose: { [weak self] in self?.chooseLayout($0) },
            followSpeaker: { [weak self] in self?.browsedStream = nil; self?.setPin(nil) })
        statusLabel.isHidden = focus.hidden || geometry.compactHeader
        statusLabel.frame = CGRect(x: geometry.header.minX, y: geometry.header.maxY - statusHeight,
            width: geometry.header.width, height: statusHeight)
        zoomControls.frame = CGRect(x: stage.maxX - 150, y: stage.minY + 8, width: 140, height: 44)
        zoomVisibility.setSuppressed(focus.hidden)
        shareOffer.frame = CGRect(x: stage.minX + 56, y: stage.minY + 8, width: max(0, stage.width - 210), height: 44)
        shareOffer.alpha = focus.hidden ? 0 : 1
        focusButton.frame = layoutControls.isHidden ? CGRect(x: stage.minX + 8, y: stage.minY + 8, width: 44, height: 44) :
            CGRect(x: layoutFrame.maxX - 48, y: layoutFrame.minY, width: 44, height: 44)
        focusButton.isHidden = focus.hidden || primaryZoom == nil || geometry.compactHeader
        localShareCard.alpha = focus.hidden ? 0 : 1
        localShareCard.refreshLayout()
        let cardWidth = min(216, stage.width - 8)
        let cardHeight = min(max(0, stage.height - 44), localShareCard.systemLayoutSizeFitting(
            CGSize(width: cardWidth, height: 0), withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height)
        localShareCard.frame = CGRect(x: stage.minX + 4, y: stage.maxY - cardHeight - 44,
            width: cardWidth, height: cardHeight)
        for entry in videoTiles.values {
            entry.zoom.isAccessibilityElement = true
            entry.zoom.accessibilityCustomActions = focus.hidden ? [focus.restoreAccessibilityAction()] : nil
            entry.badge.alpha = focus.hidden ? 0 : 1
            entry.pin.alpha = focus.hidden || effectiveLayoutMode == .grid || (geometry.compactHeader && entry.zoom === primaryZoom) ? 0 : 1
            entry.pin.isUserInteractionEnabled = entry.pin.alpha > 0
            entry.pin.accessibilityElementsHidden = entry.pin.alpha == 0
        }
        flipCamera.alpha = focus.hidden ? 0 : 1
        flipCamera.isHidden = studio?.canFlipCamera != true
        flipCamera.isEnabled = studio?.canFlipCamera == true
    }

    @objc private func tappedStage(_ gesture: UITapGestureRecognizer) {
        if effectiveLayoutMode == .grid && !focus.hidden {
            let point = gesture.location(in: tiles)
            if let tile = tiles.arrangedSubviews.first(where: { $0.frame.contains(point) }),
               let target = tileSelections[ObjectIdentifier(tile)] { setPin(target); return }
        }
        focus.toggle()
        zoomVisibility.activity()
    }
    @objc private func swipedStage(_ gesture: UISwipeGestureRecognizer) {
        if effectiveLayoutMode == .grid { moveGalleryPage(gesture.direction == .left ? 1 : -1) }
        else { browse(gesture.direction == .left ? 1 : -1) }
    }
    private func browse(_ step: Int) {
        guard let snapshot = displayedSnapshot, orderedStreams.count > 1 else { return }
        let selected = pinnedStream ?? browsedStream ?? currentPrimaryKey.flatMap { streamPinTargets[$0] }
        let index = orderedStreams.firstIndex { $0 == selected } ?? 0
        browsedStream = orderedStreams[(index + step + orderedStreams.count) % orderedStreams.count]
        pinnedStream = browsedStream
        render(snapshot: snapshot)
        focus.interaction()
    }
    @objc private func doubleTappedStage(_ gesture: UITapGestureRecognizer) {
        guard let zoom = gesture.view as? UIScrollView, zoom.maximumZoomScale > 1 else { return }
        zoom.setZoomScale(zoom.zoomScale > 1.01 ? 1 : 2, animated: true)
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UISwipeGestureRecognizer { return effectiveLayoutMode != .grid && (primaryZoom?.zoomScale ?? 1) <= 1.01 }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var target = touch.view
        while let current = target {
            if current is UIControl { return false }
            target = current.superview
        }
        return true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.tintColor = .white
        view.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.085, alpha: 1)
        floatingVideo = RockVideoPictureInPicture(sourceView: view, speaker: activeSpeaker)
        floatingVideo?.onPresentationChanged = { [weak self] in self?.onFloatingChanged?($0) }
        if let studio { floatingVideo?.bindMicrophoneActivity(studio.microphoneActivity) }
        activeSpeaker.$current.sink { [weak self] speaker in
            self?.compactHeader.setSpeaker(speaker)
            guard let self, self.layoutMode == .speaker, self.pinnedStream == nil, self.browsedStream == nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let snapshot = self.displayedSnapshot else { return }
                self.render(snapshot: snapshot)
            }
        }.store(in: &subscriptions)
        let identity = UIStackView(arrangedSubviews: [titleLabel, countLabel, routeLabel])
        identity.axis = .vertical
        identity.spacing = 2
        let header = UIStackView(arrangedSubviews: [identity, participantsButton,
                                                    missedButton, conversationButton])
        headerView = header
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
        countLabel.text = L("Connecting…")
        routeLabel.font = .preferredFont(forTextStyle: .caption1)
        routeLabel.textColor = .lightGray
        routeLabel.text = L("Audio output")

        streamScroll.delegate = self
        streamScroll.addSubview(tiles)
        tiles.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tiles.leadingAnchor.constraint(equalTo: streamScroll.contentLayoutGuide.leadingAnchor),
            tiles.trailingAnchor.constraint(equalTo: streamScroll.contentLayoutGuide.trailingAnchor),
            tiles.topAnchor.constraint(equalTo: streamScroll.contentLayoutGuide.topAnchor),
            tiles.bottomAnchor.constraint(equalTo: streamScroll.contentLayoutGuide.bottomAnchor),
            tiles.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ])

        configure(microphone, symbol: "mic.slash.fill", label: L("Unmute microphone"), title: L("Mic off"))
        configure(camera, symbol: "video.slash.fill", label: L("Start video"), title: L("Cam off"))
        configure(share, symbol: "rectangle.on.rectangle", label: L("Share screen"), title: L("Share"))
        if usesNativeShareControl || ProcessInfo.processInfo.isiOSAppOnMac {
            share.isHidden = false
            sharePicker.isHidden = true
            shareTitle.isHidden = true
        } else if #available(iOS 27.0, *) {
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
        sharePicker.accessibilityLabel = L("Share screen")
        shareTitle.text = L("Share")
        shareTitle.font = .preferredFont(forTextStyle: .caption2)
        shareTitle.textColor = accent
        microphone.configuration?.baseForegroundColor = .white
        camera.configuration?.baseForegroundColor = .white
        configure(flipCamera, symbol: "arrow.triangle.2.circlepath.camera", label: L("Flip camera"))
        flipCamera.isEnabled = false
        configure(speaker, symbol: "speaker.wave.2.fill", label: L("Use iPhone speaker"))
        configure(displayModeButton, symbol: displayMode.symbol, label: L("Display: All video"))
        displayModeButton.showsMenuAsPrimaryAction = true
        configureModeMenu()
        configure(conversationButton, symbol: "text.bubble", label: L("Chat"))
        configure(missedButton, symbol: "clock.arrow.circlepath", label: L("Catch up"))
        missedButton.isHidden = true
        missedButton.addAction(UIAction { [weak self] _ in
            self?.openConversation(.catchUp)
        }, for: .touchUpInside)
        configure(participantsButton, symbol: "person.2.fill", label: L("Musicians"))
        configure(moreButton, symbol: "ellipsis.circle.fill", label: L("More call options"), title: L("More"))
        moreButton.showsMenuAsPrimaryAction = true
        configureMoreMenu()
        configure(fitButton, symbol: "arrow.down.right.and.arrow.up.left", label: L("Fit shared screen at 100%"))
        configure(zoomInButton, symbol: "plus.magnifyingglass", label: L("Zoom in shared screen"))
        configure(zoomOutButton, symbol: "minus.magnifyingglass", label: L("Zoom out shared screen"))
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
        let routePicker: UIView
        if ProcessInfo.processInfo.isiOSAppOnMac {
            routePicker = MacAudioRouteButton()
        } else {
            let systemPicker = AVRoutePickerView()
            systemPicker.tintColor = accent
            systemPicker.activeTintColor = accent
            routePicker = systemPicker
        }
        routePicker.accessibilityLabel = ProcessInfo.processInfo.isiOSAppOnMac ? L("Audio devices") : L("Choose audio output")
        let leave = AlignedCallButton(frame: .zero)
        configure(leave, symbol: "phone.down.fill", label: L("Leave"), title: L("Leave"))
        leave.configuration?.baseForegroundColor = .systemRed

        microphone.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onMicrophone?(!self.isMicrophoneOn)
        }, for: .touchUpInside)
        camera.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onCamera?(!self.isCameraOn)
        }, for: .touchUpInside)
        if let studio {
            MicrophoneActivityView.install(on: microphone, model: studio.microphoneActivity)
            studio.enableCamera = { [weak self] in self?.camera.sendActions(for: .touchUpInside) }
            studio.enableMicrophone = { [weak self] in self?.microphone.sendActions(for: .touchUpInside) }
            StudioShortcut.install(on: microphone, pane: .sound, model: studio)
            StudioShortcut.install(on: camera, pane: .camera, model: studio)
            StudioShortcut.install(on: speaker, pane: .sound, model: studio, devices: true)
        }
        if !supportsSharing { share.isHidden = true; sharePicker.isHidden = true }
        conversationButton.isHidden = !supportsChat
        share.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onShare?(!self.isSharingScreen)
        }, for: .touchUpInside)
        flipCamera.addAction(UIAction { [weak self] _ in self?.studio?.flipCamera() }, for: .touchUpInside)
        speaker.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.isSpeakerOn.toggle()
            self.workspace.speakerOn = self.isSpeakerOn
            self.onSpeaker?(self.isSpeakerOn)
            self.speaker.accessibilityLabel = self.isSpeakerOn ? L("Use iPhone receiver") : L("Use iPhone speaker")
        }, for: .touchUpInside)
        conversationButton.addAction(UIAction { [weak self] _ in
            self?.openConversation(.chat)
        }, for: .touchUpInside)
        participantsButton.addAction(UIAction { [weak self] _ in
            guard let self, self.presentedViewController == nil else { return }
            #if DEBUG
            let statuses = self.displayedSnapshot?.participants.map(\.status) ?? self.fixtureParticipants ?? []
            #else
            guard let snapshot = self.displayedSnapshot else { return }
            let statuses = snapshot.participants.map(\.status)
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
        audioControl.accessibilityIdentifier = "call.output"
        routePicker.translatesAutoresizingMaskIntoConstraints = false
        audioControl.addSubview(routePicker)
        let audioTitle = UILabel()
        audioTitle.text = nil
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
        let audioAppearance = AlignedCallButton(frame: .zero)
        configure(audioAppearance, symbol: "speaker.wave.2.fill", label: L("Audio output"), title: L("Audio"))
        audioAppearance.isUserInteractionEnabled = false
        audioAppearance.accessibilityElementsHidden = true
        audioAppearance.backgroundColor = UIColor(red: 0.12, green: 0.14, blue: 0.21, alpha: 1)
        audioAppearance.translatesAutoresizingMaskIntoConstraints = false
        audioControl.addSubview(audioAppearance)
        NSLayoutConstraint.activate([
            audioAppearance.leadingAnchor.constraint(equalTo: audioControl.leadingAnchor),
            audioAppearance.trailingAnchor.constraint(equalTo: audioControl.trailingAnchor),
            audioAppearance.topAnchor.constraint(equalTo: audioControl.topAnchor),
            audioAppearance.bottomAnchor.constraint(equalTo: audioControl.bottomAnchor)
        ])
        audioControl.accessibilityLabel = L("Audio output")
        if let studio { StudioShortcut.install(on: audioControl, pane: .sound, model: studio, devices: true) }
        let shareControl = UIView()
        for item in [share, sharePicker, shareTitle] {
            item.translatesAutoresizingMaskIntoConstraints = false
            shareControl.addSubview(item)
        }
        if let studio, studio.presenter.available {
            // The container also receives holds on the system broadcast button.
            StudioShortcut.install(on: shareControl, pane: .presenter, model: studio,
                accessibilityTargets: [share, sharePicker])
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
        configure(broadcastAppearance, symbol: "rectangle.on.rectangle", label: L("Share screen"), title: L("Share"))
        broadcastAppearance.isUserInteractionEnabled = false
        broadcastAppearance.accessibilityElementsHidden = true
        broadcastAppearance.backgroundColor = UIColor(red: 0.12, green: 0.14, blue: 0.21, alpha: 1)
        broadcastAppearance.isHidden = sharePicker.isHidden
        shareTitle.isHidden = true
        broadcastAppearance.translatesAutoresizingMaskIntoConstraints = false
        shareControl.addSubview(broadcastAppearance)
        NSLayoutConstraint.activate([
            broadcastAppearance.leadingAnchor.constraint(equalTo: shareControl.leadingAnchor),
            broadcastAppearance.trailingAnchor.constraint(equalTo: shareControl.trailingAnchor),
            broadcastAppearance.topAnchor.constraint(equalTo: shareControl.topAnchor),
            broadcastAppearance.bottomAnchor.constraint(equalTo: shareControl.bottomAnchor)
        ])
        let bar = CallToolbar(items: [microphone, camera] + (supportsSharing ? [shareControl] : []) + [audioControl, moreButton, leave])
        toolbar = bar
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .lightGray
        statusLabel.text = L("Microphone and camera are off")
        statusLabel.textAlignment = .center
        conversationHost.isHidden = true
        conversationHost.backgroundColor = .clear
        for item in [header, streamScroll, bar, statusLabel, zoomControls, shareOffer, conversationHost] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        localShareCard.translatesAutoresizingMaskIntoConstraints = false
        localShareCard.onStop = { [weak self] in self?.onShare?(false) }
        localShareCard.onLayoutChanged = { [weak self] in self?.view.setNeedsLayout() }
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
        installFocus()
        Publishers.CombineLatest(chat.$unreadCount, store.$timeline)
            .receive(on: DispatchQueue.main).sink { [weak self] count, timeline in
            guard let self else { return }
            self.conversationButton.configuration?.title = count > 0 ? "\(count)" : nil
            self.missedButton.isHidden = timeline.unreadCount == 0
            self.missedButton.configuration?.title = timeline.unreadCount > 0 ?
                "\(timeline.unreadCount)" : nil
            self.missedButton.accessibilityLabel = L("Catch up, %ld missed sections", timeline.unreadCount)
            self.conversationButton.accessibilityLabel = count > 0 ?
                L("Chat, %ld unread", count) : L("Chat")
            self.view.setNeedsLayout()
        }.store(in: &subscriptions)
    }

    private func openConversation(_ selected: ConversationMode) {
        guard supportsChat || selected != .chat else { return }
        guard presentedViewController == nil else { return }
        if view.bounds.width >= 700 {
            if dockedConversation != nil { return }
            let panel = ConversationPanelViewController(catchUp: store, chat: chat,
                initialMode: selected, call: workspace, docked: true, chatAvailable: supportsChat)
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
            view.setNeedsLayout()
            return
        }
        present(ConversationPanelViewController(catchUp: store, chat: chat,
                                                initialMode: selected, call: workspace, chatAvailable: supportsChat),
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
        view.setNeedsLayout()
    }

    private func changePrimaryZoom(by factor: CGFloat) {
        guard let zoom = primaryZoom else { return }
        zoom.setZoomScale(min(zoom.maximumZoomScale,
                              max(zoom.minimumZoomScale, zoom.zoomScale * factor)), animated: true)
        zoomVisibility.activity()
    }

    private func updateControlTitles() {
        microphone.configuration?.title = L("Mic")
        camera.configuration?.title = L("Video")
        share.configuration?.title = L("Share")
    }

    private func setPin(_ target: PinnedStream?) {
        layoutMode = .speaker; explicitLayout = true
        restoreGalleryPage = true
        pinnedStream = target
        browsedStream = nil
        focus.show()
        if let snapshot = displayedSnapshot { render(snapshot: snapshot) }
    }

    func setConnectionRecovering(_ recovering: Bool) {
        preservingPinDuringReconnect = recovering
        updateSpeakerAvailability()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        focus.menuVisible = true
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        if let animator { animator.addCompletion { [weak self] in self?.focus.menuVisible = false } }
        else { focus.menuVisible = false }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let key = interaction.view?.accessibilityIdentifier,
              let target = streamPinTargets[key] else { return nil }
        let name = interaction.view?.accessibilityLabel ?? L("Musician")
        let selected = pinnedStream == target
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(
                title: selected ? L("Unpin %@", name) : L("Pin %@", name),
                image: UIImage(systemName: selected ? "pin.slash" : "pin")) { _ in
                    self?.setPin(selected ? nil : target)
                }])
        }
    }

    func render(room: Room) { render(snapshot: CallMediaSnapshot(room: room, localCameraPreview: localCameraPreview)) }

    private func streamID(_ target: PinnedStream) -> String {
        target.participantID + (target.isScreenShare ? ".screen" : ".camera")
    }
    private func chooseLayout(_ mode: MeetingLayoutMode) {
        layoutMode = mode; explicitLayout = true
        if mode == .grid { restoreGalleryPage = true }
        focus.show(); focus.interaction()
        if let snapshot = displayedSnapshot { render(snapshot: snapshot) }
    }
    private func moveGalleryPage(_ step: Int) {
        guard effectiveLayoutMode == .grid, let pagination = tiles.pagination else { return }
        galleryPage = max(0, min(pagination.pageCount - 1, galleryPage + step))
        streamScroll.setContentOffset(CGPoint(x: CGFloat(galleryPage) * streamScroll.bounds.width, y: 0), animated: false)
        refreshLayoutControls(); focus.interaction()
    }
    private func refreshLayoutControls() {
        layoutControls.update(mode: effectiveLayoutMode, manual: pinnedStream != nil,
            page: galleryPage, pagination: tiles.pagination, count: tiles.arrangedSubviews.count)
    }
    func render(snapshot: CallMediaSnapshot) {
        displayedSnapshot = snapshot
        let ids = snapshot.participants.map(\.id), existing = Set(rosterOrder)
        rosterOrder.removeAll { !ids.contains($0) }
        rosterOrder.append(contentsOf: ids.filter { !existing.contains($0) })
        let ranks = Dictionary(uniqueKeysWithValues: rosterOrder.enumerated().map { ($1, $0) })
        let participants = snapshot.participants.sorted { ranks[$0.id, default: .max] < ranks[$1.id, default: .max] }
        localShareRenderer.setTrack(snapshot.localShare?.roomTrack)
        let sharing = participants.first { $0.isLocal }?.screenShareOn ?? false
        if isSharingScreen != sharing { setSharing(sharing) }
        if let pin = pinnedStream, !preservingPinDuringReconnect,
           !participants.contains(where: { $0.id == pin.participantID && (!pin.isScreenShare || $0.screenShareOn) }) {
            pinnedStream = nil; layoutMode = .grid
        }
        let identifier = workspace.roomIdentifier.map { " · \($0)" } ?? ""
        countLabel.text = snapshot.remoteParticipants.isEmpty ? L("Only you here%@", identifier) : L("%ld musicians", participants.count) + identifier
        participantsButton.isEnabled = true
        participantsButton.accessibilityLabel = L("Musicians, %ld", participants.count)
        tiles.arrangedSubviews.forEach { $0.removeFromSuperview() }
        participantBadges.removeAll(); speakingTiles.removeAll(); tileOrder.removeAll(); tileSelections.removeAll()
        identityTiles = identityTiles.filter { ids.contains($0.key) }
        identityViews = identityViews.filter { ids.contains($0.key) }
        var streams: [(CallParticipant, CallVideoStream, CallVideoSource)] = []
        orderedStreams = []
        for participant in participants {
            if displayMode != .screenShares { orderedStreams.append(PinnedStream(participantID: participant.id, isScreenShare: false)) }
            for publication in participant.videoTracks where !publication.isMuted &&
                !(participant.isLocal && publication.source == .screenShareVideo) && displayMode != .audioOnly &&
                (displayMode == .all || publication.source == .screenShareVideo) {
                streams.append((participant, publication, publication.track))
                if publication.source == .screenShareVideo { orderedStreams.append(PinnedStream(participantID: participant.id, isScreenShare: true)) }
            }
        }
        if displayMode == .screenShares, pinnedStream?.isScreenShare == false { pinnedStream = nil }
        if let browsedStream, !orderedStreams.contains(browsedStream) { self.browsedStream = nil }
        let activeKeys = Set(streams.map { $0.1.id })
        videoTiles = videoTiles.filter { activeKeys.contains($0.key) }
        streamPinTargets = Dictionary(uniqueKeysWithValues: orderedStreams.map { (streamID($0), $0) })
        for stream in streams { streamPinTargets[stream.1.id] = PinnedStream(participantID: stream.0.id, isScreenShare: stream.1.source == .screenShareVideo) }
        if !streams.contains(where: { $0.0.isLocal && $0.1.source != .screenShareVideo }) {
            NSLayoutConstraint.deactivate(flipCameraConstraints); flipCameraConstraints.removeAll(); flipCamera.removeFromSuperview()
        }
        let requested = pinnedStream ?? browsedStream
        let primary = requested.flatMap { target in streams.first { streamPinTargets[$0.1.id] == target } } ??
            (requested == nil ? streams.first { $0.1.source == .screenShareVideo } ??
                streams.first { $0.0.id == activeSpeaker.current?.id && !$0.0.isLocal } ?? streams.first { !$0.0.isLocal } ?? streams.first : nil)
        pinnedStreamKey = primary.flatMap { requested == nil ? nil : $0.1.id }
        currentPrimaryKey = primary?.1.id
        primaryName = requested.flatMap { target in participants.first { $0.id == target.participantID }?.name } ?? primary?.0.name
        primaryZoom = nil
        if let primary {
            floatingVideo?.show(source: primary.2, name: primary.0.name ?? L("Musician"),
                isScreenShare: primary.1.source == .screenShareVideo,
                mirrored: primary.0.isLocal && primary.1.source == .camera && CameraPreviewPresentation.isMirrored(device: studio?.liveCaptureDevice?()))
        } else { floatingVideo?.clear() }
        let shareStream = streams.first { $0.1.source == .screenShareVideo }
        offeredShare = shareStream.flatMap { streamPinTargets[$0.1.id] }
        shareOffer.isHidden = shareStream == nil || (!explicitLayout && requested == nil) || primary?.1.id == shareStream?.1.id && effectiveLayoutMode != .grid
        shareOffer.configuration?.title = shareStream.map { L("%@ is sharing · View", $0.0.name ?? L("Musician")) }
        let focused = effectiveLayoutMode == .speaker && displayMode != .audioOnly
        if focused {
            if let primary { tiles.addArrangedSubview(videoTile(for: primary.0, publication: primary.1, track: primary.2, primary: true)) }
            else if displayMode == .all, let owner = participants.first(where: { $0.id == requested?.participantID }) ??
                participants.first(where: { $0.id == activeSpeaker.current?.id }) ?? snapshot.remoteParticipants.first {
                primaryName = owner.name; tiles.addArrangedSubview(audioTile(for: owner))
            }
        } else if !snapshot.remoteParticipants.isEmpty || !streams.isEmpty {
            for target in orderedStreams {
                if let stream = streams.first(where: { streamPinTargets[$0.1.id] == target }) {
                    tiles.addArrangedSubview(videoTile(for: stream.0, publication: stream.1, track: stream.2, primary: stream.1.id == primary?.1.id))
                } else if !target.isScreenShare, let owner = participants.first(where: { $0.id == target.participantID }) {
                    tiles.addArrangedSubview(audioTile(for: owner))
                }
            }
        }
        if displayMode == .screenShares && streams.isEmpty {
            let empty = UILabel(); empty.text = L("No screen share is live. Audio continues.")
            empty.textColor = .lightGray; empty.textAlignment = .center; empty.numberOfLines = 0
            tiles.addArrangedSubview(empty)
        }
        if snapshot.remoteParticipants.isEmpty && streams.isEmpty && displayMode == .all { tiles.addArrangedSubview(waitingRoomView()) }
        zoomVisibility.setAvailable(primary?.1.source == .screenShareVideo)
        zoomControls.isHidden = primary?.1.source != .screenShareVideo
        fitButton.isHidden = (primaryZoom?.zoomScale ?? 1) <= 1.01
        participantsPanel?.update(participants.map(\.status), pinnedKey: pinnedStreamKey)
        tiles.arrange(size: streamScroll.bounds.size, mode: effectiveLayoutMode)
        refreshSpeaking(snapshot: snapshot)
        configureMoreMenu(); view.setNeedsLayout()
    }

    private func waitingRoomView() -> UIView {
        let view = UIView()
        let title = UILabel()
        title.text = L("You're connected. Waiting for others.")
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
            invite.configuration?.title = L("Invite musicians")
            invite.configuration?.image = UIImage(systemName: "square.and.arrow.up")
            invite.tintColor = accent
            invite.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.workspace.shareInvitation(from: invite)
            }, for: .touchUpInside)
            let copy = UIButton(type: .system)
            copy.configuration = .plain()
            copy.configuration?.title = L("Copy link")
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

    private func audioTile(for participant: CallParticipant) -> UIView {
        let tile: UIView, identity: ParticipantIdentityView
        if let existing = identityTiles[participant.id], let content = identityViews[participant.id] { tile = existing; identity = content }
        else {
            tile = baseTile(); identity = ParticipantIdentityView(); identity.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(identity)
            NSLayoutConstraint.activate([identity.leadingAnchor.constraint(equalTo: tile.leadingAnchor), identity.trailingAnchor.constraint(equalTo: tile.trailingAnchor), identity.topAnchor.constraint(equalTo: tile.topAnchor), identity.bottomAnchor.constraint(equalTo: tile.bottomAnchor)])
            identityTiles[participant.id] = tile; identityViews[participant.id] = identity
            tile.addInteraction(UIContextMenuInteraction(delegate: self))
        }
        let target = PinnedStream(participantID: participant.id, isScreenShare: false)
        tile.accessibilityIdentifier = "camera-off." + participant.id
        tileSelections[ObjectIdentifier(tile)] = target
        streamPinTargets[tile.accessibilityIdentifier!] = target
        identity.update(name: participant.name ?? L("Musician"), microphoneOn: participant.microphoneOn, speaking: participant.isSpeaking && !isHeld)
        tile.accessibilityCustomActions = [UIAccessibilityCustomAction(name: L("Focus %@", participant.name ?? L("Musician"))) { [weak self] _ in
            self?.setPin(target); return self != nil
        }]
        speakingTiles[participant.id, default: []].append(tile)
        return tile
    }

    private func videoTile(for participant: CallParticipant, publication: CallVideoStream,
                           track: CallVideoSource, primary: Bool) -> UIView {
        let isShare = publication.source == .screenShareVideo
        let key = publication.id
        if var cached = videoTiles[key] {
            configureVideoTile(&cached, participant: participant, track: track,
                               isShare: isShare, primary: primary, key: key)
            videoTiles[key] = cached
            participantBadges[participant.id, default: []].append(cached.badge)
            speakingTiles[participant.id, default: []].append(cached.tile)
            tileOrder[ObjectIdentifier(cached.tile)] = participant.id + (isShare ? ".screen" : ".camera")
            return cached.tile
        }
        let tile = baseTile()
        tile.accessibilityIdentifier = key
        tile.accessibilityLabel = "\(participant.name ?? L("Musician")) \(isShare ? L("screen share") : L("video"))"
        tile.addInteraction(UIContextMenuInteraction(delegate: self))
        let zoom = UIScrollView()
        zoom.minimumZoomScale = 1
        zoom.maximumZoomScale = isShare ? 5 : 1
        zoom.panGestureRecognizer.isEnabled = false
        zoom.bouncesZoom = true
        zoom.delegate = self
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTappedStage(_:)))
        double.numberOfTapsRequired = 2; double.delegate = self
        zoom.addGestureRecognizer(double)
        streamScroll.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }.forEach { $0.require(toFail: double) }
        zoom.accessibilityIdentifier = key
        zoom.accessibilityLabel = isShare ? L("Pinch to zoom screen share") : L("Video stream")
        zoom.accessibilityValue = "100%"
        zoom.translatesAutoresizingMaskIntoConstraints = false
        let video = CallVideoView()
        // Use the same color-managed renderer as the floating video surface.
        video.layoutMode = .fit
        video.track = track
        video.translatesAutoresizingMaskIntoConstraints = false
        zoom.addSubview(video)
        tile.addSubview(zoom)
        let badge = ParticipantMediaBadge()
        badge.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(badge)
        let pin = UIButton(type: .system)
        pin.configuration = .tinted()
        pin.configuration?.image = UIImage(systemName: pinnedStreamKey == key ? "pin.fill" : "pin")
        pin.accessibilityLabel = pinnedStreamKey == key ? L("Unpin %@ %@", participant.name ?? L("Musician"), isShare ? L("screen") : L("video")) :
            L("Pin %@ %@", participant.name ?? L("Musician"), isShare ? L("screen") : L("video"))
        pin.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let target = PinnedStream(participantID: participant.id,
                                      isScreenShare: isShare)
            self.setPin(self.pinnedStream == target ? nil : target)
        }, for: .touchUpInside)
        pin.accessibilityHint = L("Changes only your view")
        pin.showsLargeContentViewer = true
        pin.largeContentTitle = pin.accessibilityLabel
        pin.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(pin)
        speakingTiles[participant.id, default: []].append(tile)
        participantBadges[participant.id, default: []].append(badge)
        tileOrder[ObjectIdentifier(tile)] = participant.id + (isShare ? ".screen" : ".camera")
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
            badge.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 10),
            badge.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -10),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: pin.leadingAnchor, constant: -6),
            pin.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -10),
            pin.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -8),
            pin.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            pin.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        var entry = VideoTile(tile: tile, zoom: zoom, video: video, badge: badge, pin: pin)
        configureVideoTile(&entry, participant: participant, track: track,
                           isShare: isShare, primary: primary, key: key)
        videoTiles[key] = entry
        return tile
    }

    private func configureVideoTile(_ entry: inout VideoTile, participant: CallParticipant,
                                    track: CallVideoSource, isShare: Bool, primary: Bool, key: String) {
        tileSelections[ObjectIdentifier(entry.tile)] = PinnedStream(participantID: participant.id, isScreenShare: isShare)
        if entry.video.track?.identity != track.identity { entry.video.track = track }
        entry.video.layoutMode = .fit
        entry.video.isMirrored = participant.isLocal && !isShare &&
            CameraPreviewPresentation.isMirrored(device: studio?.liveCaptureDevice?())
        entry.badge.update(name: participant.name ?? L("Musician"), microphoneOn: participant.microphoneOn,
                           speaking: participant.isSpeaking && !isHeld)
        entry.pin.configuration?.image = UIImage(systemName: pinnedStreamKey == key ? "pin.fill" : "pin")
        entry.pin.accessibilityLabel = pinnedStreamKey == key
            ? L("Unpin %@ %@", participant.name ?? L("Musician"), isShare ? L("screen") : L("video"))
            : L("Pin %@ %@", participant.name ?? L("Musician"), isShare ? L("screen") : L("video"))
        entry.pin.largeContentTitle = entry.pin.accessibilityLabel
        if primary { primaryZoom = entry.zoom }
        if participant.isLocal && !isShare {
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
            flipCamera.isHidden = studio?.canFlipCamera != true
            flipCamera.isEnabled = studio?.canFlipCamera == true
        }
    }

    func refreshSpeaking(room: Room, speakers: [Participant]? = nil) {
        refreshSpeaking(snapshot: CallMediaSnapshot(room: room, localCameraPreview: localCameraPreview), speakerOrder: speakers?.map { $0.identity?.stringValue ?? $0.sid?.stringValue ?? "local" })
    }

    func refreshSpeaking(snapshot: CallMediaSnapshot, speakerOrder: [String]? = nil) {
        displayedSnapshot = snapshot
        let participants = snapshot.participants.map { participant in
            var value = participant
            if value.isLocal, let localMicrophoneStatus { value.microphoneOn = localMicrophoneStatus == .on }
            value.isSpeaking = ParticipantAudioState(microphoneOn: value.microphoneOn,
                speaking: participant.isSpeaking, receptionAvailable: speakerReceptionAvailable && !isHeld &&
                    !preservingPinDuringReconnect && (!participant.isLocal || isMicrophoneOn)).speaking
            return value
        }
        participantsPanel?.update(participants.map(\.status), pinnedKey: pinnedStreamKey)
        let voices = participants.filter(\.isSpeaking)
        let speaking = speakerOrder.flatMap { order in order.compactMap { id in voices.first { $0.id == id } }.first } ??
            voices.first { $0.id == activeSpeaker.current?.id } ?? voices.first
        activeSpeaker.update(speaking.map { CallSpeaker(id: $0.id, name: $0.name ?? L("Musician"), isLocal: $0.isLocal) })
        let byID = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0) })
        participantStrip.update(orderedStreams.compactMap { target in
            guard let owner = byID[target.participantID] else { return nil }
            return MeetingStripItem(id: streamID(target), name: owner.name ?? L("Musician"), isShare: target.isScreenShare,
                audio: ParticipantAudioState(microphoneOn: owner.microphoneOn, speaking: owner.isSpeaking))
        }, selected: (pinnedStream ?? browsedStream).map(streamID) ?? currentPrimaryKey.flatMap { streamPinTargets[$0] }.map(streamID))
        for participant in participants {
            identityViews[participant.id]?.updateAudio(ParticipantAudioState(microphoneOn: participant.microphoneOn, speaking: participant.isSpeaking))
            for badge in participantBadges[participant.id] ?? [] {
                badge.updateMicrophone(on: participant.microphoneOn, speaking: participant.isSpeaking)
            }
            for tile in speakingTiles[participant.id] ?? [] {
                MeetingTileAppearance.update(tile, speaking: participant.isSpeaking)
            }
        }
    }

    private func baseTile() -> UIView {
        let tile = UIView()
        tile.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1)
        MeetingTileAppearance.update(tile, speaking: false)
        return tile
    }

    private func layoutMenu() -> UIMenu {
        UIMenu(title: L("Layout"), options: .displayInline, children: MeetingLayoutMode.allCases.map { mode in
            UIAction(title: mode.title, image: UIImage(systemName: mode.symbol), state: mode == layoutMode ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.chooseLayout(mode)
            }
        })
    }
    private func configureModeMenu() {
        displayModeButton.menu = UIMenu(children: [layoutMenu()] + ConferenceDisplayMode.allCases.map { option in
            UIAction(title: option.title, image: UIImage(systemName: option.symbol),
                     state: option == displayMode ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.setDisplayMode(option)
            }
        })
    }

    func setDisplayMode(_ mode: ConferenceDisplayMode) {
        displayMode = mode
        displayModeButton.configuration?.image = UIImage(systemName: mode.symbol)
        displayModeButton.accessibilityLabel = L("Display: %@", mode.title)
        configureModeMenu()
        if let snapshot = displayedSnapshot { render(snapshot: snapshot) }
        onDisplayMode?(mode)
    }

    private func configureMoreMenu() {
        moreButton.accessibilityValue = floatingVideo?.canShow == true ? L("Floating video available") : nil
        var items: [UIMenuElement] = [layoutMenu()]
        if let studio {
            items.append(UIAction(title: L("Audio devices"), image: UIImage(systemName: "headphones")) { [weak self] _ in
                guard let self else { return }
                studio.audioSection = .devices
                StudioPresentation.show(studio, from: self.moreButton, pane: .sound)
            })
            items.append(UIAction(title: L("Camera & sound"), image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
                guard let self else { return }
                StudioPresentation.show(studio, from: self.moreButton)
            })
            if studio.presenter.available {
                items.append(UIAction(title: L("Presenter"), image: UIImage(systemName: "person.crop.rectangle")) { [weak self] _ in
                    guard let self else { return }
                    StudioPresentation.show(studio, from: self.moreButton, pane: .presenter)
                })
            }
        }
        if workspace.invitationURL != nil {
            items.append(UIAction(title: L("Invite musicians"), image: UIImage(systemName: "square.and.arrow.up")) {
                [weak self] _ in guard let self else { return }
                self.workspace.shareInvitation(from: self.moreButton)
            })
            items.append(UIAction(title: L("Copy link"), image: UIImage(systemName: "doc.on.doc")) {
                [weak self] _ in self?.workspace.copyInvitation()
            })
        }
        items += [
            UIAction(title: L("Fit shared screen"), image: UIImage(systemName: "arrow.down.right.and.arrow.up.left"),
                     attributes: (primaryZoom?.maximumZoomScale ?? 1) > 1 ? [] : [.disabled]) { [weak self] _ in
                self?.primaryZoom?.setZoomScale(1, animated: true)
            },
            UIAction(title: L("Hide controls"), image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) {
                [weak self] _ in self?.focus.hide()
            },
            UIAction(title: L("Automatically hide controls"), state: focus.automaticallyHides ? .on : .off) {
                [weak self] _ in guard let self else { return }
                self.focus.automaticallyHides.toggle(); self.configureMoreMenu()
            },
            UIAction(title: L("Automatic view"), state: browsedStream == nil && pinnedStream == nil ? .on : .off) {
                [weak self] _ in self?.browsedStream = nil; self?.setPin(nil)
            },
            UIAction(title: L("Show floating video"), image: UIImage(systemName: "pip.enter"),
                     attributes: floatingVideo?.canShow == true && !isHeld ? [] : [.disabled]) {
                [weak self] _ in self?.floatingVideo?.start()
            },
            UIAction(title: L("Floating video when multitasking"),
                     image: UIImage(systemName: "pip"),
                     state: FloatingVideoPreference.enabled ? .on : .off) { [weak self] _ in
                FloatingVideoPreference.enabled.toggle()
                self?.floatingVideo?.refreshPreference()
                self?.configureMoreMenu()
            },
            UIMenu(title: L("View"), children: ConferenceDisplayMode.allCases.map { option in
                UIAction(title: option.title, image: UIImage(systemName: option.symbol),
                         state: option == displayMode ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    self.displayMode = option
                    self.configureMoreMenu()
                    if let snapshot = self.displayedSnapshot { self.render(snapshot: snapshot) }
                    self.onDisplayMode?(option)
                }
            }),
            UIAction(title: isSpeakerOn ? L("Use iPhone receiver") : L("Use iPhone speaker"),
                     image: UIImage(systemName: "speaker.wave.2")) { [weak self] _ in
                guard let self else { return }
                self.isSpeakerOn.toggle()
                self.workspace.speakerOn = self.isSpeakerOn
                self.onSpeaker?(self.isSpeakerOn)
                self.configureMoreMenu()
            },
        ]
        if (studio?.availableCameraCount ?? 0) > 1 {
            items.append(UIAction(title: L("Flip camera"), image: UIImage(systemName: "camera.rotate"),
                attributes: studio?.canFlipCamera == true ? [] : [.disabled]) { [weak self] _ in
                    self?.studio?.flipCamera()
                })
        }
        #if DEBUG
        items = fixtureActions + items
        #endif
        moreButton.menu = UIMenu(children: items)
    }

    func setSharing(_ enabled: Bool) {
        guard supportsSharing else {
            share.isHidden = true; sharePicker.isHidden = true; shareTitle.isHidden = true; broadcastAppearance.isHidden = true
            return
        }
        isSharingScreen = enabled
        share.isEnabled = sharingAvailable || enabled
        if usesNativeShareControl || ProcessInfo.processInfo.isiOSAppOnMac {
            share.isHidden = false
            sharePicker.isHidden = true
            shareTitle.isHidden = true
        } else if #available(iOS 27.0, *) {
            share.isHidden = false
            sharePicker.isHidden = true
            shareTitle.isHidden = true
        } else {
            share.isHidden = !enabled
            sharePicker.isHidden = enabled
            shareTitle.isHidden = enabled
        }
        broadcastAppearance.isHidden = sharePicker.isHidden
        shareTitle.isHidden = true
        share.configuration?.image = UIImage(systemName: enabled ? "rectangle.slash" : "rectangle.on.rectangle")
        updateControlTitles()
        share.configuration?.baseForegroundColor = enabled ? accent : .white
        share.accessibilityLabel = enabled ? L("Stop sharing screen") : L("Share screen")
    }

    func setMicrophone(_ enabled: Bool) {
        isMicrophoneOn = enabled
        if let snapshot = displayedSnapshot { refreshSpeaking(snapshot: snapshot) }
        studio?.microphoneOn = enabled
        workspace.microphoneOn = enabled
        view.setNeedsLayout()
        microphone.configuration?.image = UIImage(systemName: enabled ? "mic.fill" : "mic.slash.fill")
        updateControlTitles()
        microphone.configuration?.baseForegroundColor = enabled ? accent : .white
        microphone.accessibilityLabel = enabled ? L("Mute microphone") : L("Unmute microphone")
        microphone.largeContentTitle = microphone.accessibilityLabel
        updateStatus()
    }

    func setFloatingMicrophoneStatus(_ status: PiPMicrophoneStatus) {
        floatingVideo?.setMicrophoneStatus(status)
        localMicrophoneStatus = status
        if let snapshot = displayedSnapshot { refreshSpeaking(snapshot: snapshot) }
    }

    func setCamera(_ enabled: Bool) {
        isCameraOn = enabled
        studio?.cameraOn = enabled
        workspace.cameraOn = enabled
        flipCamera.isEnabled = studio?.canFlipCamera == true
        configureMoreMenu()
        camera.configuration?.image = UIImage(systemName: enabled ? "video.fill" : "video.slash.fill")
        updateControlTitles()
        camera.configuration?.baseForegroundColor = enabled ? accent : .white
        camera.accessibilityLabel = enabled ? L("Stop video") : L("Start video")
        camera.largeContentTitle = camera.accessibilityLabel
        updateStatus()
    }

    func setHeld(_ held: Bool) {
        isHeld = held
        updateSpeakerAvailability()
        studio?.held = held
        if held { focus.show() }
        workspace.onHold = held
        floatingVideo?.setSuspended(held)
        configureMoreMenu()
        updateStatus()
    }

    /// Stream metadata stays present when its pixels are paused, so browsing and pinning remain available.
    func visibleVideoQualities(foreground: Bool, wantsVideo: Bool) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for (key, tile) in videoTiles {
            let visible = foreground && tile.tile.superview != nil && !tile.tile.isHidden &&
                streamScroll.bounds.intersects(tile.tile.convert(tile.tile.bounds, to: streamScroll))
            tile.video.isEnabled = visible
            if visible { result[key] = key == currentPrimaryKey }
        }
        if wantsVideo, let key = currentPrimaryKey { result[key] = true }
        // Preload adjacent camera tiles while foregrounded to keep swiping responsive.
        if foreground, !focus.hidden, effectiveLayoutMode == .speaker, pinnedStream == nil, let key = currentPrimaryKey, let target = streamPinTargets[key], let index = orderedStreams.firstIndex(of: target) {
            for i in [index - 1, index + 1] where orderedStreams.indices.contains(i) {
                if let next = streamPinTargets.first(where: { $0.value == orderedStreams[i] })?.key, result[next] == nil { result[next] = false }
            }
        }
        return result
    }

    func prepareToFloat() {
        floatingVideo?.setSuspended(isHeld || displayMode == .audioOnly)
    }

    func restoreFromFloatingVideo() { floatingVideo?.foregrounded() }

    func endFloatingVideo() { activeSpeaker.end(); floatingVideo?.end(); localShareRenderer.setTrack(nil); localSharePreview.end() }

    func setSpeakerReceptionAvailable(_ available: Bool) {
        speakerReceptionAvailable = available
        updateSpeakerAvailability()
    }
    private func updateSpeakerAvailability() {
        let available = speakerReceptionAvailable && !isHeld && !preservingPinDuringReconnect
        activeSpeaker.setAvailable(available)
        if let snapshot = displayedSnapshot { refreshSpeaking(snapshot: snapshot) }
    }

    func showMediaStatus(_ message: String?) {
        mediaStatus = message
        if message != nil { focus.show() }
        updateStatus()
    }

    func setAudioRouteName(_ name: String) {
        routeLabel.text = L("Audio · %@", name)
        workspace.routeName = name
    }

    private func updateStatus() {
        statusLabel.text = isHeld ? L("Jam on hold for another call") :
            (mediaStatus ?? L("Microphone %@ · Camera %@", isMicrophoneOn ? L("on") : L("off"), isCameraOn ? L("on") : L("off")))
        statusLabel.textColor = mediaStatus == nil ? .lightGray : .systemOrange
        view.setNeedsLayout()
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
        style.baseForegroundColor = .white
        button.configuration = style
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.accessibilityLabel = label
        button.showsLargeContentViewer = true
        button.largeContentTitle = label
        button.largeContentImage = UIImage(systemName: symbol)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        scrollView === streamScroll ? nil : scrollView.subviews.first { $0 is CallVideoView }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        if scrollView !== streamScroll {
            scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > 1.01
            scrollView.accessibilityValue = "\(Int((scrollView.zoomScale * 100).rounded()))%"
            rememberZoom(scrollView)
            if !restoringZoom && scrollView === primaryZoom { zoomVisibility.activity() }
            if scrollView === primaryZoom { fitButton.isHidden = scrollView.zoomScale <= 1.01 }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === streamScroll {
            onVideoDemandChanged?()
        }
        rememberZoom(scrollView)
    }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { zoomVisibility.beginInteraction() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { zoomVisibility.endInteraction() }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollView !== streamScroll { zoomVisibility.beginInteraction() }
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if scrollView !== streamScroll { zoomVisibility.endInteraction() }
        else if !decelerate { settleGalleryPage() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { if scrollView === streamScroll { settleGalleryPage() } }
    private func settleGalleryPage() {
        guard !restoringZoom, effectiveLayoutMode == .grid, streamScroll.bounds.width > 0 else { return }
        galleryPage = max(0, min((tiles.pagination?.pageCount ?? 1) - 1, Int((streamScroll.contentOffset.x / streamScroll.bounds.width).rounded())))
        refreshLayoutControls()
    }
    private func rememberZoom(_ zoom: UIScrollView) {
        guard !restoringZoom, zoom !== streamScroll, let key = zoom.accessibilityIdentifier,
              let entry = videoTiles[key], entry.zoom === zoom, entry.viewportSize != .zero,
              entry.viewportSize == zoom.bounds.size, zoom.window != nil,
              zoom.contentSize.width > 0, zoom.contentSize.height > 0 else { return }
        zoomStates[key] = (zoom.zoomScale, CGPoint(
            x: (zoom.contentOffset.x + zoom.bounds.width / 2) / zoom.contentSize.width,
            y: (zoom.contentOffset.y + zoom.bounds.height / 2) / zoom.contentSize.height))
    }
    private func restoreZoom(_ zoom: UIScrollView, key: String) {
        guard let state = zoomStates[key] else { return }
        zoom.setZoomScale(state.0, animated: false)
        zoom.contentOffset = CGPoint(
            x: min(max(0, state.1.x * zoom.contentSize.width - zoom.bounds.width / 2), max(0, zoom.contentSize.width - zoom.bounds.width)),
            y: min(max(0, state.1.y * zoom.contentSize.height - zoom.bounds.height / 2), max(0, zoom.contentSize.height - zoom.bounds.height)))
    }
}
