import ConferenceCore
import AVKit
import Combine
import LiveKit
import MeetingEngine
import ReplayKit
import UIKit

@MainActor
final class RockCallViewController: UIViewController, UIScrollViewDelegate, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var shouldAutorotate: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        CallKeyboardCommands.make(microphone: #selector(keyToggleMicrophone), camera: #selector(keyToggleCamera),
            chat: #selector(keyOpenChat), participants: #selector(keyOpenParticipants), fit: #selector(keyFitScreen), focus: #selector(keyFocus), restore: #selector(keyRestoreControls)) +
            [UIKeyCommand(input: ",", modifierFlags: .command, action: #selector(keyOpenStudio)),
             UIKeyCommand(title: L("Reactions"), action: #selector(keyOpenReactions), input: "r", modifierFlags: .command.union(.shift)),
             UIKeyCommand(title: L("View"), action: #selector(keyOpenView), input: "l", modifierFlags: .command.union(.shift)),
             UIKeyCommand(title: L("More"), action: #selector(keyOpenMore), input: "m", modifierFlags: .command.union(.shift))]
    }
    struct SwitcherItem: Equatable {
        let id: UUID
        let title: String
        let subtitle: String
        let isCurrent: Bool
        let isTalk: Bool
    }

    var onLeave: (() -> Void)?
    var onMicrophone: ((Bool) -> Void)?
    var onToggleMicrophone: (() -> Void)?
    var onCamera: ((Bool) -> Void)?
    var onToggleCamera: (() -> Void)?
    var onSpeaker: ((Bool) -> Void)?
    var onChooseAudioOutput: (() -> Void)?
    var onShare: ((Bool) -> Void)?
    var onVideoDemandChanged: (() -> Void)?
    var onFloatingChanged: ((Bool) -> Void)?
    var onDisplayMode: ((ConferenceDisplayMode) -> Void)?
    var onMinimize: (() -> Void)? { didSet { refreshSwitcherChrome() } }
    var activeMeetingsForSwitcher: [SwitcherItem] = [] { didSet { refreshSwitcherChrome() } }
    var isTalkRoom = true { didSet { refreshSwitcherChrome() } }
    var onSelectMeeting: ((UUID) -> Void)?
    var onTalkHere: ((UUID) -> Void)?
    var onLeaveMeeting: ((UUID) -> Void)?
    var onJoinAnotherMeeting: (() -> Void)? { didSet { refreshSwitcherChrome() } }
    var onOpenAssistant: (() -> Void)? { didSet { refreshSwitcherChrome() } }
    var reactions: MeetingReactionsModel?
    var studio: StudioModel?
    private(set) var isFloatingVideoPresenting = false
    let activeSpeaker = ActiveSpeakerStore()
    private var speakerReceptionAvailable = true

    private let focus = CallFocusController()
    private var headerView: UIStackView?
    private let compactHeader = CompactCallHeader()
    private var toolbar: CallToolbar?
    private let accessControls = MeetingAccessControls()
    var reminderHost: MeetingReminderHost { accessControls.reminderHost }
    private let panelOwner = MeetingPanelOwner()
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
    private let sourceSelector = MeetingMenuButton(type: .system)
    private let presenterCompanion = PresenterCompanionView()
    private let presenterPreview = ParticipantPreview(frame: .zero)
    private var presenterSource: (key: String, track: CallVideoSource, mirrored: Bool)?
    private var selectedShare: PinnedStream?
    private var cameraFocusShare: PinnedStream?
    private var retainedShares: [String: CallVideoStream] = [:]
    private var reconnectingShares: Set<String> = []
    private var currentPrimaryTarget: PinnedStream?
    private var pictureInPictureKey: String?
    private var stageApplicationActive = UIApplication.shared.applicationState == .active
    private var stageVisibilityObservers: [NSObjectProtocol] = []
    private let shareReconnectNotice = UILabel()
    private var thumbnailSources: [String: (key: String, track: CallVideoSource, mirrored: Bool)] = [:]
    private var thumbnailViews: [String: ParticipantPreview] = [:]
    private var galleryPage = 0
    private var galleryCapacity = 0
    private var gallerySize = CGSize.zero
    private var restoreGalleryPage = true
    private var rosterOrder: [String] = []
    private var identityTiles: [String: UIView] = [:]
    private var identityViews: [String: ParticipantIdentityView] = [:]
    private var tileSelections: [ObjectIdentifier: PinnedStream] = [:]
    private var effectiveLayoutMode: MeetingLayoutMode {
        guard layoutMode == .grid, let source = currentPrimaryTarget,
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
    private let conversationButton = UIButton(type: .system)
    private let missedButton = UIButton(type: .system)
    private let participantsButton = UIButton(type: .system)
    private let minimizeButton = UIButton(type: .system)
    private let assistantButton = UIButton(type: .system)
    private let switcherButton = UIButton(type: .system)
    private let talkHereButton = UIButton(type: .system)
    private let compactTalkHereButton = UIButton(type: .system)
    private var currentAssistantMode: IOSMeetingAssistantMode = .off
    private var currentAssistantPaused = false
    private var currentAssistantAlertCount = 0
    private var assistantBannerView: UIView?
    private var assistantBannerDismissTask: Task<Void, Never>?
    private var assistantBannerTapHandler: (() -> Void)?
    private let reactionsButton = AlignedCallButton(frame: .zero)
    private let reactionOverlay = ReceivedReactionOverlay()
    private let meetingStatusButton = UIButton(type: .system)
    #if DEBUG
    var exposeReactionOverlayForTesting = false {
        didSet { reactionOverlay.accessibilityElementsHidden = !exposeReactionOverlayForTesting }
    }
    #endif
    func showReaction(_ reaction: MeetingReaction, from name: String) {
        reactionOverlay.show(reaction, from: name)
    }
    private var actionsMenu: UIMenu?
    private let shareOffer = UIButton(type: .system)
    private var textCapture: SharedTextOverlay?
    private lazy var selectTextButton: UIButton = {
        let button = UIButton(type: .system)
        button.configuration = .plain(); button.configuration?.baseForegroundColor = .label
        button.accessibilityLabel = L("Select text")
        button.configuration?.image = UIImage(systemName: "text.viewfinder")
        button.accessibilityIdentifier = "Select shared text"
        button.addAction(UIAction { [weak self] _ in self?.openSharedText() }, for: .touchUpInside)
        return button
    }()
    private func openSharedText(key requested: String? = nil) {
        guard textCapture == nil, let key = requested ?? currentPrimaryKey,
              streamPinTargets[key]?.isScreenShare == true, let entry = videoTiles[key] else { return }
        focus.show(); focus.menuVisible = true
        let name = entry.tile.accessibilityLabel ?? L("Screen share")
        var firstKey: String? = key
        let overlay = SharedTextOverlay(sourceID: key, sourceName: name, initialScale: zoomStates[key]?.0 ?? 1,
            initialCenter: zoomStates[key]?.1 ?? CGPoint(x: 0.5, y: 0.5), initialViewportSize: entry.video.bounds.size) { [weak self] in
            guard let self, let key = firstKey ?? self.currentPrimaryKey, self.streamPinTargets[key]?.isScreenShare == true,
                  let entry = self.videoTiles[key] else { return nil }
            firstKey = nil
            return await SharedTextCapture.make(entry.video.snapshotFrame(), sourceID: key, name: entry.tile.accessibilityLabel ?? L("Screen share"))
        }
        textCapture = overlay; view.addSubview(overlay)
        overlay.onMore = { [weak self] in self?.keyOpenMore() }
        overlay.onClose = { [weak self] in self?.textCapture = nil; self?.focus.menuVisible = false; self?.view.setNeedsLayout() }
        view.setNeedsLayout()
    }

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
        let canvas: UIView
        let video: CallVideoView
        let fitting: [NSLayoutConstraint]
        let overlays: [NSLayoutConstraint]
        let badge: ParticipantMediaBadge
        let pin: UIButton
        var viewportSize = CGSize.zero
        var fittedFrame = CGRect.zero
    }
    /// Borrows decoded pixels from the existing source; an unmounted thumbnail has no render demand.
    private final class ParticipantPreview: UIView {
        let video = CallVideoView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            video.layoutMode = .fit; video.isEnabled = false
            video.frame = bounds; video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(video)
        }
        required init?(coder: NSCoder) { nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            video.isEnabled = window != nil
            if window == nil { video.track = nil }
        }
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
    var supportsSharing = true { didSet { studio?.screenSharingAvailable = supportsSharing && sharingAvailable } }
    var usesNativeShareControl = false
    #if DEBUG
    var usesBroadcastPickerForTesting = false
    #endif
    private var usesBroadcastPicker: Bool {
        guard !usesNativeShareControl else { return false }
        #if DEBUG
        if usesBroadcastPickerForTesting { return true }
        #endif
        if #available(iOS 27.0, *) { return false }
        return true
    }
    var sharingAvailable = true {
        didSet {
            share.isEnabled = sharingAvailable || isSharingScreen
            sharePicker.isUserInteractionEnabled = sharingAvailable
            studio?.screenSharingAvailable = supportsSharing && sharingAvailable
        }
    }
    var sharePreview: LocalSharePreview { localSharePreview }
    func setRoomTitle(_ title: String) { titleLabel.text = title; view.setNeedsLayout() }
    #if DEBUG
    var snapshotForTesting: CallMediaSnapshot? { displayedSnapshot }
    var primarySourceForTesting: String? { currentPrimaryTarget.map(streamID) }
    var pictureInPictureSourceForTesting: String? { pictureInPictureKey }
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
        StudioPresentation.show(studio, from: reactionsButton)
    }
    @objc private func keyOpenChat() { openConversation(.chat) }
    @objc private func keyOpenReactions() { reactionsButton.sendActions(for: .touchUpInside) }
    @objc private func keyOpenView() { focus.show(); accessControls.viewButton.sendActions(for: .touchUpInside) }
    @objc private func keyOpenMore() { focus.show(); accessControls.moreButton.sendActions(for: .touchUpInside) }
    @objc private func keyOpenParticipants() { participantsButton.sendActions(for: .touchUpInside) }
    @objc private func keyFocus() { focus.toggle() }
    @objc private func keyRestoreControls() { if let textCapture { textCapture.finish(); return }; if reminderHost.collapseReminder?() == true { return }; focus.show(); focus.interaction() }
    @objc private func keyFitScreen() { if let textCapture { textCapture.toggleFit(); return }; primaryZoom?.setZoomScale(1, animated: true) }

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
    deinit { stageVisibilityObservers.forEach(NotificationCenter.default.removeObserver) }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reminderHost.changed()
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
        for item in [headerView!, toolbar!, streamScroll, statusLabel, shareOffer, conversationHost, localShareCard] {
            NSLayoutConstraint.deactivate(item.constraints.filter { $0.firstItem === item && $0.secondItem == nil })
            item.translatesAutoresizingMaskIntoConstraints = true
        }
        focus.onChange = { [weak self] _ in
            guard let self else { return }
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
        focus.canHide = { [weak self] in
            guard let self else { return false }
            return !self.isHeld && self.mediaStatus == nil && self.presentedViewController == nil && self.dockedConversation == nil
        }
        view.insertSubview(streamScroll, at: 0)
        view.addSubview(layoutControls); view.addSubview(participantStrip)
        layoutControls.navigationOnly = true
        view.addSubview(accessControls)
        view.addSubview(reactionOverlay)
        sourceSelector.onMenuVisibilityChanged = { [weak self] in self?.focus.menuVisible = $0 }
        layoutControls.onMenuVisibilityChanged = { [weak self] in self?.focus.menuVisible = $0 }
        compactHeader.onMenuVisibilityChanged = { [weak self] in self?.focus.menuVisible = $0 }
        sourceSelector.configuration = .plain()
        sourceSelector.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFontMetrics(forTextStyle: .callout).scaledFont(for: .systemFont(ofSize: 15, weight: .medium), maximumPointSize: 24)
            return attributes
        }
        sourceSelector.titleLabel?.numberOfLines = 1
        sourceSelector.configuration?.image = UIImage(systemName: "rectangle.on.rectangle")
        sourceSelector.configuration?.imagePadding = 6
        sourceSelector.configuration?.titleLineBreakMode = .byTruncatingTail
        MeetingControlMetrics.boundSymbol(in: sourceSelector)
        sourceSelector.accessibilityIdentifier = "Meeting source selector"
        sourceSelector.showsMenuAsPrimaryAction = true
        let sourceSurface = MeetingChromeSurface(cornerRadius: 14)
        sourceSurface.isUserInteractionEnabled = false
        sourceSurface.frame = sourceSelector.bounds
        sourceSurface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sourceSelector.insertSubview(sourceSurface, at: 0)
        view.addSubview(sourceSelector)
        view.addSubview(presenterCompanion)
        presenterCompanion.onFocusCamera = { [weak self] in self?.focusPresenterCamera() }
        presenterCompanion.onReturnToShare = { [weak self] in
            guard let self, let share = self.cameraFocusShare else { return }; self.setPin(share)
        }
        presenterCompanion.onInteraction = { [weak self] in
            self?.focus.interaction(); self?.view.setNeedsLayout(); self?.onVideoDemandChanged?()
        }
        presenterCompanion.onVisibilityChanged = { [weak self] _ in
            guard let self else { return }
            self.updatePresenterDemand(foreground: UIApplication.shared.applicationState != .background)
            self.onVideoDemandChanged?()
        }
        presenterCompanion.onMenuVisibilityChanged = { [weak self] in self?.focus.menuVisible = $0 }
        shareReconnectNotice.text = L("Screen share reconnecting…")
        shareReconnectNotice.font = .preferredFont(forTextStyle: .callout)
        shareReconnectNotice.textAlignment = .center; shareReconnectNotice.textColor = .white
        shareReconnectNotice.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        shareReconnectNotice.layer.cornerRadius = 12; shareReconnectNotice.clipsToBounds = true
        shareReconnectNotice.isHidden = true
        view.addSubview(shareReconnectNotice)
        layoutControls.onLayout = { [weak self] in self?.chooseLayout($0) }
        layoutControls.onAutomatic = { [weak self] in self?.browsedStream = nil; self?.setPin(nil) }
        layoutControls.onPage = { [weak self] in self?.moveGalleryPage($0) }
        participantStrip.onSelect = { [weak self] key in
            guard let self, let target = self.streamPinTargets[key] else { return }; self.setPin(target)
        }
        participantStrip.previewProvider = { [weak self] key in self?.participantPreview(for: key) }
        participantStrip.onPreviewVisibilityChanged = { [weak self] in self?.onVideoDemandChanged?() }
        focusButton.configuration = .tinted()
        focusButton.configuration?.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
        focusButton.accessibilityLabel = L("Hide controls")
        focusButton.addAction(UIAction { [weak self] _ in self?.focus.hide() }, for: .touchUpInside)
        view.addSubview(focusButton)
        var compactTalkConfig = UIButton.Configuration.filled()
        compactTalkConfig.title = L("Talk Here")
        compactTalkConfig.image = UIImage(systemName: "mic.fill")
        compactTalkConfig.imagePadding = 4
        compactTalkConfig.cornerStyle = .capsule
        compactTalkConfig.baseBackgroundColor = accent
        compactTalkConfig.baseForegroundColor = .black
        compactTalkConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        compactTalkHereButton.configuration = compactTalkConfig
        compactTalkHereButton.accessibilityIdentifier = "call.talkHere"
        compactTalkHereButton.isHidden = true
        compactTalkHereButton.addAction(UIAction { [weak self] _ in
            guard let self, let id = self.activeMeetingsForSwitcher.first(where: \.isCurrent)?.id else { return }
            self.onTalkHere?(id)
        }, for: .touchUpInside)
        view.addSubview(compactTalkHereButton)
        view.addSubview(compactHeader)
        focus.installHint(in: view)
        compactHeader.minimize.addAction(UIAction { [weak self] _ in self?.onMinimize?() }, for: .touchUpInside)
        compactHeader.assistant.addAction(UIAction { [weak self] _ in self?.onOpenAssistant?() }, for: .touchUpInside)
        compactHeader.switcher.addAction(UIAction { [weak self] _ in self?.presentSwitcher() }, for: .touchUpInside)
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
                                 (compactHeader.conversation, conversationButton)] {
            button.addAction(UIAction { [weak action] _ in action?.sendActions(for: .touchUpInside) }, for: .touchUpInside)
        }
        compactHeader.focus.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if self.effectiveLayoutMode == .speaker && self.currentPrimaryKey.flatMap({ self.streamPinTargets[$0]?.isScreenShare }) == true { self.toggleShareScale() }
            else { self.focus.hide() }
        }, for: .touchUpInside)
        compactHeader.details.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            var quickActions: [(String, () -> Void)] = []
            if self.onOpenAssistant != nil {
                let label = self.currentAssistantMode == .off
                    ? L("Assistant mode")
                    : L("Assistant mode: %@", self.currentAssistantMode.title)
                quickActions.append((label, { [weak self] in self?.onOpenAssistant?() }))
            }
            if self.activeMeetingsForSwitcher.count > 1 || self.onJoinAnotherMeeting != nil {
                let label = self.activeMeetingsForSwitcher.count > 1 ? L("Active meetings") : L("Join another meeting…")
                quickActions.append((label, { [weak self] in self?.presentSwitcher() }))
            }
            if self.onMinimize != nil {
                quickActions.append((L("Return to Home"), { [weak self] in self?.onMinimize?() }))
            }
            self.workspace.showDetails(from: self.compactHeader.details, presenter: self,
                title: self.titleLabel.text ?? L("Jam"),
                lines: [self.countLabel.text, self.workspace.roomIdentifier, self.routeLabel.text,
                        self.statusLabel.text].compactMap { $0 },
                actions: quickActions)
        }, for: .touchUpInside)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedStage(_:)))
        tap.delegate = self; tap.cancelsTouchesInView = false
        streamScroll.addGestureRecognizer(tap)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedStage(_:)))
            swipe.direction = direction; swipe.delegate = self
            streamScroll.addGestureRecognizer(swipe)
        }
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
            headerHeight: headerHeight, toolbarHeight: toolbar.preferredHeight, hidden: false,
            largeText: large, allowsRail: dockedConversation == nil, floating: true)
        toolbar.arrange(rail: geometry.rail, largeText: large)
        header.frame = geometry.header.insetBy(dx: 4, dy: 0)
        header.frame.size.height = max(0, geometry.header.height - statusHeight - 8)
        let gallery = effectiveLayoutMode == .grid && displayMode != .audioOnly
        let sharedKey = currentPrimaryKey.flatMap { streamPinTargets[$0]?.isScreenShare == true ? $0 : nil }
        selectTextButton.isHidden = sharedKey == nil || effectiveLayoutMode != .speaker || focus.hidden || textCapture != nil
        accessControls.textButton = selectTextButton
        accessControls.capturedTextMode = textCapture != nil
        let accessWidth = MeetingAccessGeometry.availableAccessWidth(base: geometry, gallery: gallery)
        let access = MeetingAccessGeometry(base: geometry, bounds: view.bounds, insets: view.safeAreaInsets,
            accessSize: accessControls.fittingSize(availableWidth: accessWidth), largeText: large, gallery: gallery)
        toolbar.frame = access.toolbar
        toolbar.separatesLast = access.inline
        toolbar.inlineAccessWidth = access.inline ? access.access.width + 8 : 0
        accessControls.frame = access.access
        accessControls.isHidden = focus.hidden
        focus.onReminderChange = { [weak self] in self?.reminderHost.changed() }
        reminderHost.bind(surface: view, access: accessControls, toolbar: toolbar,
            blocked: { [weak self] in self?.focus.menuVisible != false },
            privateContent: { [weak self] in self?.isSharingScreen == true || self?.studio?.presenter.running == true }, studio: studio)
        accessControls.update(MeetingViewState(layout: layoutMode, display: displayMode,
            manualFocus: pinnedStream != nil || browsedStream != nil, effectiveLayout: effectiveLayoutMode))
        var stage = access.stage

        var canvas = view.bounds
        if dockedConversation != nil {
            let width = view.bounds.width >= 700 ? min(400, max(320, view.bounds.width * 0.36)) : stage.width
            conversationHost.frame = CGRect(x: stage.maxX - width, y: stage.minY, width: width, height: stage.height)
            stage.size.width = max(0, stage.width - width - 8)
            canvas.size.width = max(0, conversationHost.frame.minX - canvas.minX - 8)
        }
        textCapture?.frame = canvas
        textCapture?.layoutChrome(status: geometry.header.offsetBy(dx: -canvas.minX, dy: -canvas.minY),
            tools: access.access.offsetBy(dx: -canvas.minX, dy: -canvas.minY))
        textCapture?.updateSource(id: sharedKey, name: sharedKey.flatMap { videoTiles[$0]?.tile.accessibilityLabel })
        for entry in videoTiles.values where entry.zoom.window != nil { rememberZoom(entry.zoom) }
        restoringZoom = true
        let layoutAvailable = displayedSnapshot?.remoteParticipants.isEmpty == false && displayMode != .audioOnly
        let sharing = effectiveLayoutMode == .speaker && currentPrimaryTarget?.isScreenShare == true
        let stripBottom = max(stage.minY, stage.maxY - 48)
        var imageFit = stage
        sourceSelector.isHidden = !sharing || orderedStreams.filter { $0.isScreenShare }.count <= 1 || focus.hidden
        sourceSelector.frame = CGRect(x: stage.minX + 4, y: stage.minY + 4,
            width: min(280, max(0, stage.width - 8)), height: 44)
        if sharing { imageFit = canvas }
        let canShowStrip = stage.height >= 240
        participantStrip.isHidden = effectiveLayoutMode == .grid || !layoutAvailable || focus.hidden || sharing || !canShowStrip
        if effectiveLayoutMode == .speaker && layoutAvailable && !sharing && canShowStrip {
            participantStrip.vertical = stage.width >= 800
            if participantStrip.vertical {
                participantStrip.frame = CGRect(x: stage.maxX - 172, y: stage.minY,
                    width: 168, height: max(0, imageFit.height))
                imageFit.size.width = max(0, imageFit.width - 180)
            } else {
                let stripHeight = min(92, max(44, stage.height * 0.3))
                participantStrip.frame = CGRect(x: stage.minX + 4, y: max(stage.minY, stripBottom - stripHeight - 6),
                    width: max(0, stage.width - 8), height: min(stripHeight, stage.height))
                imageFit.size.height = max(0, participantStrip.frame.minY - stage.minY - 8)
            }
        }
        let gridStage = effectiveLayoutMode == .grid ? imageFit : stage
        streamScroll.frame = effectiveLayoutMode == .grid ? gridStage : canvas
        tiles.arrange(size: streamScroll.bounds.size, mode: effectiveLayoutMode)
        if effectiveLayoutMode != .grid { restoreGalleryPage = true }
        if effectiveLayoutMode == .grid, let pagination = tiles.pagination {
            let oldPage = galleryPage
            let geometryChanged = gallerySize != gridStage.size || galleryCapacity != pagination.capacity
            if galleryCapacity > 0, galleryCapacity != pagination.capacity {
                galleryPage = galleryPage * galleryCapacity / pagination.capacity
            }
            gallerySize = gridStage.size
            galleryCapacity = pagination.capacity
            galleryPage = min(galleryPage, pagination.pageCount - 1)
            restoreGalleryPage = restoreGalleryPage || geometryChanged || oldPage != galleryPage
        }
        streamScroll.isPagingEnabled = effectiveLayoutMode == .grid
        if effectiveLayoutMode == .grid && restoreGalleryPage && !streamScroll.isDragging && !streamScroll.isDecelerating {
            streamScroll.setContentOffset(CGPoint(x: CGFloat(galleryPage) * gridStage.width, y: 0), animated: false)
            restoreGalleryPage = false
        }
        refreshLayoutControls()
        layoutControls.isHidden = !layoutAvailable || focus.hidden || !gallery || (tiles.pagination?.pageCount ?? 1) <= 1
        if gallery {
            layoutControls.frame = CGRect(origin: access.pagination.origin,
                size: layoutControls.fittingSize(availableWidth: access.pagination.width))
        }
        streamScroll.layoutIfNeeded()
        tiles.layoutIfNeeded()
        var resized: [String] = []
        for (key, var entry) in videoTiles where entry.tile.superview != nil {
            let fitted = effectiveLayoutMode == .speaker
                ? imageFit.offsetBy(dx: -canvas.minX, dy: -canvas.minY) : CGRect(origin: .zero, size: entry.zoom.bounds.size)
            if entry.fittedFrame != fitted || entry.viewportSize != entry.zoom.bounds.size { resized.append(key) }
            let values = [fitted.minX, fitted.minY, fitted.width, fitted.height]
            for (constraint, value) in zip(entry.fitting, values) { constraint.constant = value }
            let overlayValues = [fitted.minX + 10, fitted.maxY - entry.tile.bounds.height - 10,
                fitted.maxX - entry.tile.bounds.width - 10, fitted.maxY - entry.tile.bounds.height - 8]
            for (constraint, value) in zip(entry.overlays, overlayValues) { constraint.constant = value }
            if flipCamera.superview === entry.tile {
                flipCameraConstraints.first?.constant = fitted.minY + 8
                flipCameraConstraints.dropFirst().first?.constant = fitted.maxX - entry.tile.bounds.width - 8
            }
            entry.tile.layoutIfNeeded()
            entry.fittedFrame = fitted
            videoTiles[key] = entry
        }
        for key in resized {
            guard var entry = videoTiles[key], entry.zoom.window != nil else { continue }
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
        meetingStatusButton.accessibilityLabel = [titleLabel.text, countLabel.text, routeLabel.text].compactMap { $0 }.joined(separator: ", ")
        compactHeader.frame = geometry.header
        compactHeader.isHidden = focus.hidden || !geometry.compactHeader
        let pin = currentPrimaryKey.flatMap { videoTiles[$0]?.pin }
        let sourceName = (primaryName ?? titleLabel.text ?? L("Jam")) +
            (currentPrimaryTarget?.isScreenShare == true ? L(" · Screen") : "")
        compactHeader.update(name: isHeld || mediaStatus != nil ? statusLabel.text ?? L("Jam") :
            effectiveLayoutMode == .grid ? titleLabel.text ?? L("Jam") : sourceName,
            navigation: false, browsing: browsedStream != nil, pinned: pinnedStream != nil,
            pinLabel: pin?.accessibilityLabel, participantsLabel: participantsButton.accessibilityLabel,
            chatValue: chat.unreadCount > 0 ? conversationButton.accessibilityLabel : nil,
            chatCount: chat.unreadCount, missedCount: store.timeline.unreadCount,
            status: isHeld || mediaStatus != nil ? statusLabel.text : nil,
            speaking: activeSpeaker.current, focusAvailable: primaryZoom != nil, chatAvailable: true,
            meetingName: titleLabel.text)
        // Layout and receive filtering have one stable, visible entry in the dock.
        compactHeader.setLayout(mode: effectiveLayoutMode, available: false, choose: { _ in })
        syncCompactWorkspaceControls()
        updateShareScaleControl()
        statusLabel.isHidden = focus.hidden || geometry.compactHeader
        statusLabel.frame = CGRect(x: geometry.header.minX, y: geometry.header.maxY - statusHeight,
            width: geometry.header.width, height: statusHeight)
        let hideCompactTalkHere = focus.hidden || !geometry.compactHeader || isTalkRoom || activeMeetingsForSwitcher.count <= 1 || textCapture != nil
        compactTalkHereButton.isHidden = hideCompactTalkHere
        if !hideCompactTalkHere {
            let talkSize = compactTalkHereButton.sizeThatFits(CGSize(width: max(0, stage.width - 16), height: 34))
            let talkWidth = min(max(110, ceil(talkSize.width)), max(110, stage.width - 16))
            compactTalkHereButton.frame = CGRect(
                x: floor(stage.midX - talkWidth / 2),
                y: geometry.header.maxY + 8,
                width: talkWidth,
                height: 34
            )
            view.bringSubviewToFront(compactTalkHereButton)
        }
        shareOffer.frame = CGRect(x: stage.minX + 56, y: stage.minY + 8, width: max(0, stage.width - 210), height: 44)
        shareOffer.alpha = focus.hidden ? 0 : 1
        focusButton.frame = CGRect(x: stage.minX + 8, y: stage.minY + 8, width: 44, height: 44)
        focusButton.isHidden = focus.hidden || primaryZoom == nil || geometry.compactHeader || sharing
        localShareCard.alpha = focus.hidden ? 0 : 1
        localShareCard.refreshLayout()
        let cardWidth = min(216, stage.width - 8)
        let cardHeight = min(max(0, stage.height - 44), localShareCard.systemLayoutSizeFitting(
            CGSize(width: cardWidth, height: 0), withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height)
        localShareCard.frame = CGRect(x: stage.minX + 4, y: stage.maxY - cardHeight - 44,
            width: cardWidth, height: cardHeight)
        let companionAvailable = effectiveLayoutMode == .speaker && displayMode == .all &&
            (sharing || cameraFocusShare != nil) && !isHeld
        presenterCompanion.isHidden = !companionAvailable || (presenterSource == nil && cameraFocusShare == nil)
        var fittedShare = CGRect.zero
        if sharing, let key = currentPrimaryKey, let entry = videoTiles[key], entry.video.displaySize.width > 0,
           entry.video.displaySize.height > 0 {
            fittedShare = AVMakeRect(aspectRatio: entry.video.displaySize, insideRect: entry.video.bounds)
            fittedShare = entry.video.convert(fittedShare, to: view)
        }
        let exclusions = [sourceSelector, shareOffer, localShareCard, compactTalkHereButton].filter { !$0.isHidden && $0.alpha > 0 }.map(\.frame)
        presenterCompanion.place(in: stage, fittedShareFrame: fittedShare, avoiding: exclusions)
        presenterCompanion.refreshVisibility()
        shareReconnectNotice.isHidden = !sharing || !reconnectingShares.contains(currentPrimaryTarget?.participantID ?? "")
        shareReconnectNotice.frame = CGRect(x: stage.midX - min(150, stage.width / 2), y: stage.minY + 8,
            width: min(300, stage.width), height: 44)
        for entry in videoTiles.values {
            entry.zoom.isAccessibilityElement = true
            var accessible = focus.hidden ? [focus.restoreAccessibilityAction()] : []
            if entry.zoom.maximumZoomScale > 1 {
                accessible += [UIAccessibilityCustomAction(name: L("Zoom in")) { [weak zoom = entry.zoom] _ in
                        guard let zoom else { return false }; zoom.setZoomScale(min(zoom.maximumZoomScale, zoom.zoomScale * 1.5), animated: true); return true },
                    UIAccessibilityCustomAction(name: L("Zoom out")) { [weak zoom = entry.zoom] _ in
                        guard let zoom else { return false }; zoom.setZoomScale(max(1, zoom.zoomScale / 1.5), animated: true); return true },
                    UIAccessibilityCustomAction(name: L("Fit whole share")) { [weak zoom = entry.zoom] _ in zoom?.setZoomScale(1, animated: true); return zoom != nil },
                    UIAccessibilityCustomAction(name: L("Fill screen")) { [weak zoom = entry.zoom, weak video = entry.video] _ in
                        guard let zoom, let video, let scale = SharedScreenScale.fill(content: video.displaySize, viewport: zoom.bounds.size) else { return false }
                        zoom.maximumZoomScale = max(5, zoom.zoomScale, scale)
                        zoom.setZoomScale(1, animated: false)
                        let size = CGSize(width: zoom.bounds.width / scale, height: zoom.bounds.height / scale)
                        zoom.zoom(to: CGRect(x: (zoom.bounds.width - size.width) / 2, y: (zoom.bounds.height - size.height) / 2,
                            width: size.width, height: size.height), animated: true)
                        return true
                    }]
            }
            entry.zoom.accessibilityCustomActions = accessible.isEmpty ? nil : accessible
            entry.badge.alpha = focus.hidden || effectiveLayoutMode == .speaker ? 0 : 1
            entry.pin.alpha = focus.hidden || (geometry.compactHeader && entry.zoom === primaryZoom && effectiveLayoutMode != .grid) ? 0 : 1
            entry.pin.isUserInteractionEnabled = entry.pin.alpha > 0
            entry.pin.accessibilityElementsHidden = entry.pin.alpha == 0
        }
        flipCamera.alpha = focus.hidden ? 0 : 1
        flipCamera.isHidden = studio?.canFlipCamera != true
        flipCamera.isEnabled = studio?.canFlipCamera == true
        view.bringSubviewToFront(reactionOverlay)
        reactionOverlay.frame = view.bounds
        reactionOverlay.suppressed = focus.hidden || textCapture != nil
        reactionOverlay.presentationRect = ReactionOverlayGeometry.contentRect(
            stage: stage,
            header: geometry.header,
            headerVisible: !header.isHidden || !compactHeader.isHidden
        )
        if let textCapture {
            view.bringSubviewToFront(textCapture)
            view.bringSubviewToFront(toolbar)
            if dockedConversation != nil { view.bringSubviewToFront(conversationHost) }
            header.isHidden = true; compactHeader.isHidden = true; compactTalkHereButton.isHidden = true; accessControls.isHidden = true
        }
    }

    @objc private func tappedStage(_ gesture: UITapGestureRecognizer) {
        guard !focus.menuVisible else { return }
        if effectiveLayoutMode == .grid && !focus.hidden {
            let point = gesture.location(in: tiles)
            if let tile = tiles.arrangedSubviews.first(where: { $0.frame.contains(point) }),
               let target = tileSelections[ObjectIdentifier(tile)] { setPin(target); return }
        }
        focus.toggle()
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
        cameraFocusShare = nil
        if browsedStream?.isScreenShare == true { selectedShare = browsedStream }
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
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UISwipeGestureRecognizer && otherGestureRecognizer is UIPinchGestureRecognizer
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var target = touch.view
        while let current = target {
            if current is UIControl || current is SharedTextOverlay { return false }
            target = current.superview
        }
        return true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeStageVisibility()
        overrideUserInterfaceStyle = .dark
        view.tintColor = .white
        view.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.085, alpha: 1)
        floatingVideo = RockVideoPictureInPicture(sourceView: view, speaker: activeSpeaker)
        floatingVideo?.onPresentationChanged = { [weak self] active in
            self?.isFloatingVideoPresenting = active
            self?.onFloatingChanged?(active)
        }
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
        identity.isUserInteractionEnabled = false
        var statusConfiguration = UIButton.Configuration.plain()
        statusConfiguration.contentInsets = .zero
        meetingStatusButton.configuration = statusConfiguration
        meetingStatusButton.accessibilityIdentifier = "Meeting status"
        meetingStatusButton.accessibilityHint = L("Meeting details")
        meetingStatusButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.workspace.showDetails(from: self.meetingStatusButton, presenter: self,
                title: self.titleLabel.text ?? L("Jam"),
                lines: [self.countLabel.text, self.workspace.roomIdentifier, self.routeLabel.text,
                        self.statusLabel.text].compactMap { $0 })
        }, for: .touchUpInside)
        let identityContainer = UIView()
        meetingStatusButton.translatesAutoresizingMaskIntoConstraints = false
        identity.translatesAutoresizingMaskIntoConstraints = false
        identityContainer.addSubview(meetingStatusButton)
        identityContainer.addSubview(identity)
        NSLayoutConstraint.activate([
            meetingStatusButton.leadingAnchor.constraint(equalTo: identityContainer.leadingAnchor),
            meetingStatusButton.trailingAnchor.constraint(equalTo: identityContainer.trailingAnchor),
            meetingStatusButton.topAnchor.constraint(equalTo: identityContainer.topAnchor),
            meetingStatusButton.bottomAnchor.constraint(equalTo: identityContainer.bottomAnchor),
            identity.leadingAnchor.constraint(equalTo: identityContainer.leadingAnchor),
            identity.trailingAnchor.constraint(equalTo: identityContainer.trailingAnchor),
            identity.topAnchor.constraint(equalTo: identityContainer.topAnchor),
            identity.bottomAnchor.constraint(equalTo: identityContainer.bottomAnchor)
        ])
        let header = UIStackView(arrangedSubviews: [minimizeButton, identityContainer, talkHereButton, assistantButton, switcherButton,
                                                    participantsButton, missedButton, conversationButton])
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
        streamScroll.contentInsetAdjustmentBehavior = .never
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
        share.isHidden = usesBroadcastPicker
        sharePicker.isHidden = !usesBroadcastPicker
        shareTitle.isHidden = !usesBroadcastPicker
        sharePicker.preferredExtension = Bundle.main.bundleIdentifier.map { "\($0).broadcast" }
        sharePicker.showsMicrophoneButton = false
        sharePicker.tintColor = accent
        sharePicker.isAccessibilityElement = true
        sharePicker.accessibilityTraits = .button
        sharePicker.accessibilityLabel = L("Share screen")
        shareTitle.text = L("Share")
        shareTitle.font = .preferredFont(forTextStyle: .caption2)
        shareTitle.textColor = accent
        microphone.configuration?.baseForegroundColor = .label
        camera.configuration?.baseForegroundColor = .label
        configure(flipCamera, symbol: "arrow.triangle.2.circlepath.camera", label: L("Flip camera"))
        flipCamera.isEnabled = false
        configure(speaker, symbol: "speaker.wave.2.fill", label: L("Use iPhone speaker"))
        configure(conversationButton, symbol: "text.bubble", label: L("Chat"))
        configure(missedButton, symbol: "clock.arrow.circlepath", label: L("Catch up"))
        missedButton.isHidden = true
        missedButton.addAction(UIAction { [weak self] _ in
            self?.openConversation(.catchUp)
        }, for: .touchUpInside)
        configure(participantsButton, symbol: "person.2.fill", label: L("Musicians"))
        configure(minimizeButton, symbol: "chevron.down", label: L("Return to Home"))
        minimizeButton.addAction(UIAction { [weak self] _ in self?.onMinimize?() }, for: .touchUpInside)
        configure(assistantButton, symbol: "sparkles", label: L("Assistant mode"))
        assistantButton.addAction(UIAction { [weak self] _ in self?.onOpenAssistant?() }, for: .touchUpInside)
        configure(switcherButton, symbol: "rectangle.stack.badge.plus", label: L("Meetings & join another"))
        switcherButton.addAction(UIAction { [weak self] _ in self?.presentSwitcher() }, for: .touchUpInside)
        var talkConfig = UIButton.Configuration.filled()
        talkConfig.title = L("Talk Here")
        talkConfig.image = UIImage(systemName: "mic.fill")
        talkConfig.imagePadding = 4
        talkConfig.cornerStyle = .capsule
        talkConfig.baseBackgroundColor = accent
        talkConfig.baseForegroundColor = .black
        talkConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        talkHereButton.configuration = talkConfig
        talkHereButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        talkHereButton.addAction(UIAction { [weak self] _ in
            guard let self, let id = self.activeMeetingsForSwitcher.first(where: \.isCurrent)?.id else { return }
            self.onTalkHere?(id)
        }, for: .touchUpInside)
        configure(reactionsButton, symbol: "face.smiling", label: L("Reactions"), title: L("Reactions"))
        reactionsButton.accessibilityIdentifier = "call.reactions"
        let showActions: (Bool) -> Void = { [weak self] more in
            guard let self else { return }
            self.focus.interaction()
            self.configureMoreMenu()
            MeetingActionsController.show(model: self.reactions, menu: self.accessControls.menuWithReminders(self.actionsMenu),
                from: more ? (self.textCapture?.moreAnchor ?? self.accessControls.moreButton) : self.reactionsButton,
                startsWithMore: more, openChat: { [weak self] in
                    guard let self else { return }
                    self.openConversation(self.supportsChat ? .chat : .liveText)
                },
                owner: self.panelOwner, onVisibilityChanged: { [weak self] in self?.focus.menuVisible = $0 || self?.textCapture != nil })
        }
        reactionsButton.addAction(UIAction { _ in showActions(false) }, for: .touchUpInside)
        accessControls.moreButton.addAction(UIAction { _ in showActions(true) }, for: .touchUpInside)
        accessControls.viewButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.focus.interaction()
            MeetingActionsController.showView(state: MeetingViewState(layout: self.layoutMode,
                display: self.displayMode, manualFocus: self.pinnedStream != nil || self.browsedStream != nil,
                effectiveLayout: self.effectiveLayoutMode),
                from: self.accessControls.viewButton, owner: self.panelOwner,
                companionActions: self.displayMode == .all ? self.presenterCompanion.menuActions() : [],
                chooseLayout: { [weak self] in self?.chooseLayout($0) },
                chooseDisplay: { [weak self] in self?.setDisplayMode($0) },
                followSpeaker: { [weak self] in self?.layoutMode = .speaker; self?.explicitLayout = true; self?.browsedStream = nil; self?.setPin(nil) },
                onVisibilityChanged: { [weak self] in self?.focus.menuVisible = $0 || self?.textCapture != nil })
        }, for: .touchUpInside)
        MeetingActionsShortcut.install(on: reactionsButton) { showActions(true) }
        configureMoreMenu()
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
        routePicker.accessibilityLabel = L("Choose audio output")
        MeetingChromeSurface.hidePickerArtwork(in: routePicker)
        routePicker.addGestureRecognizer(AudioRouteInteractionObserver { [weak self] in
            self?.onChooseAudioOutput?()
        })
        let leave = AlignedCallButton(frame: .zero)
        configure(leave, symbol: "phone.down.fill", label: L("Leave"), title: L("Leave"))
        leave.configuration?.baseForegroundColor = .systemRed

        microphone.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if let onToggleMicrophone = self.onToggleMicrophone {
                onToggleMicrophone()
            } else {
                self.onMicrophone?(!self.isMicrophoneOn)
            }
        }, for: .touchUpInside)
        camera.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if let onToggleCamera = self.onToggleCamera {
                onToggleCamera()
            } else {
                self.onCamera?(!self.isCameraOn)
            }
        }, for: .touchUpInside)
        if let studio {
            MicrophoneActivityView.install(on: microphone, model: studio.microphoneActivity)
            studio.screenSharingAvailable = supportsSharing && sharingAvailable
            studio.screenSharing = isSharingScreen
            studio.changeScreenSharing = { [weak self, weak studio] enabled in
                guard let self, let studio, self.studio === studio, studio.active, !self.isHeld,
                      self.viewIfLoaded?.window != nil else { return }
                if enabled { self.performGroupedShareAction() }
                else if self.isSharingScreen { self.onShare?(false) }
            }
            studio.enableCamera = { [weak self] in self?.camera.sendActions(for: .touchUpInside) }
            studio.enableMicrophone = { [weak self] in self?.microphone.sendActions(for: .touchUpInside) }
            StudioShortcut.install(on: microphone, pane: .sound, model: studio)
            StudioShortcut.install(on: camera, pane: .camera, model: studio)
            StudioShortcut.install(on: speaker, pane: .sound, model: studio, devices: true)
        }
        if !supportsSharing { share.isEnabled = false; sharePicker.isHidden = true }
        conversationButton.isHidden = false
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
            guard let self else { return }
            self.openConversation(self.supportsChat ? .chat : .liveText)
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
            panel.onDismiss = { [weak self] in self?.reminderHost.changed() }
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
        workspace.openReactions = { [weak self] anchor, visibility in
            guard let self else { return }
            self.configureMoreMenu()
            MeetingActionsController.show(model: self.reactions, menu: self.accessControls.menuWithReminders(self.actionsMenu), from: anchor,
                openChat: { [weak self] in
                    guard let self else { return }
                    self.openConversation(self.supportsChat ? .chat : .liveText)
                }, owner: self.panelOwner, onVisibilityChanged: { [weak self] shown in
                    self?.focus.menuVisible = shown
                    visibility(shown)
                })
        }
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
        if let studio {
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
        MeetingChromeSurface.hidePickerArtwork(in: sharePicker)
        broadcastAppearance.isUserInteractionEnabled = false
        broadcastAppearance.accessibilityElementsHidden = true
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
        let bar = CallToolbar(share: shareControl, camera: camera, audio: audioControl,
                              microphone: microphone, reactions: reactionsButton, leave: leave)
        toolbar = bar
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .lightGray
        statusLabel.text = L("Microphone and camera are off")
        statusLabel.textAlignment = .center
        conversationHost.isHidden = true
        conversationHost.backgroundColor = .clear
        for item in [header, streamScroll, bar, statusLabel, shareOffer, conversationHost] {
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
            minimizeButton.widthAnchor.constraint(equalToConstant: 42).withPriority(.defaultHigh),
            minimizeButton.heightAnchor.constraint(equalToConstant: 44),
            assistantButton.widthAnchor.constraint(equalToConstant: 40).withPriority(.defaultHigh),
            assistantButton.heightAnchor.constraint(equalToConstant: 44),
            switcherButton.widthAnchor.constraint(equalToConstant: 44).withPriority(.defaultHigh),
            switcherButton.heightAnchor.constraint(equalToConstant: 44),
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
        refreshSwitcherChrome()
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

    private func openConversation(_ requestedMode: ConversationMode) {
        let selected: ConversationMode = (!supportsChat && requestedMode == .chat) ? .liveText : requestedMode
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

    private func updateShareScaleControl() {
        guard effectiveLayoutMode == .speaker, currentPrimaryKey.flatMap({ streamPinTargets[$0]?.isScreenShare }) == true,
              let zoom = primaryZoom else {
            compactHeader.focus.accessibilityIdentifier = nil
            compactHeader.focus.accessibilityLabel = L("Hide controls")
            compactHeader.focus.configuration?.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
            compactHeader.focus.isEnabled = true
            return
        }
        let content = currentPrimaryKey.flatMap { videoTiles[$0]?.video.displaySize } ?? .zero
        let fill = SharedScreenScale.fill(content: content, viewport: zoom.bounds.size)
        if let fill { zoom.maximumZoomScale = max(5, zoom.zoomScale, fill) }
        SharedScreenScale.configure(compactHeader.focus, zoomed: zoom.zoomScale > 1.01,
            available: zoom.zoomScale > 1.01 || (fill ?? 1) > 1.01)
    }
    private func toggleShareScale() {
        guard let zoom = primaryZoom, let key = currentPrimaryKey, let entry = videoTiles[key] else { return }
        if zoom.zoomScale > 1.01 { zoom.setZoomScale(1, animated: true); return }
        guard let scale = SharedScreenScale.fill(content: entry.video.displaySize, viewport: zoom.bounds.size) else { return }
        zoom.maximumZoomScale = max(5, scale)
        let size = CGSize(width: zoom.bounds.width / scale, height: zoom.bounds.height / scale)
        zoom.zoom(to: CGRect(x: entry.fittedFrame.midX - size.width / 2, y: entry.fittedFrame.midY - size.height / 2,
            width: size.width, height: size.height), animated: true)
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
        cameraFocusShare = nil
        if target?.isScreenShare == true { selectedShare = target }
        browsedStream = nil
        focus.show()
        if let snapshot = displayedSnapshot { render(snapshot: snapshot) }
    }

    private func focusPresenterCamera() {
        guard let selectedShare, presenterSource != nil else { return }
        cameraFocusShare = selectedShare
        pinnedStream = PinnedStream(participantID: selectedShare.participantID, isScreenShare: false)
        browsedStream = nil; layoutMode = .speaker; explicitLayout = true
        focus.show()
        if let snapshot = displayedSnapshot { render(snapshot: snapshot) }
    }

    private func updatePresenterDemand(foreground: Bool) {
        let visible = foreground && stageSurfaceVisible && presenterCompanion.isPreviewVisible && displayMode == .all
        presenterPreview.video.isEnabled = visible
        presenterPreview.video.track = visible ? presenterSource?.track : nil
        presenterPreview.video.isMirrored = presenterSource?.mirrored ?? false
    }

    private var stageSurfaceVisible: Bool {
        guard stageApplicationActive, !isHeld, isViewLoaded, view.window != nil else { return false }
        var ancestor: UIView? = view
        while let surface = ancestor {
            if surface.isHidden || surface.alpha == 0 { return false }
            ancestor = surface.superview
        }
        return true
    }

    private func observeStageVisibility() {
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.didBecomeActiveNotification, UIWindow.didBecomeHiddenNotification, UIWindow.didBecomeVisibleNotification] {
            stageVisibilityObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if notification.name == UIApplication.willResignActiveNotification || notification.name == UIApplication.didEnterBackgroundNotification {
                        self.stageApplicationActive = false
                    } else if notification.name == UIApplication.didBecomeActiveNotification {
                        self.stageApplicationActive = true
                    } else if let window = notification.object as? UIWindow, window !== self.view.window { return }
                    // This only changes inline renderers. PiP has its own share sink and demand key.
                    _ = self.visibleVideoQualities(foreground: self.stageApplicationActive, wantsVideo: false)
                    self.onVideoDemandChanged?()
                }
            })
        }
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
            var actions: [UIAction] = [UIAction(
                title: selected ? L("Unpin %@", name) : L("Pin %@", name),
                image: UIImage(systemName: selected ? "pin.slash" : "pin")) { _ in
                    self?.setPin(selected ? nil : target)
                }]
            if target.isScreenShare { actions.append(UIAction(title: L("Select text"), image: UIImage(systemName: "text.viewfinder")) { _ in self?.openSharedText(key: key) }) }
            return UIMenu(children: actions)
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
    private func participantPreview(for id: String) -> UIView? {
        guard let source = thumbnailSources[id] else { return nil }
        let preview = thumbnailViews[id] ?? ParticipantPreview(frame: .zero)
        preview.video.track = source.track
        preview.video.isMirrored = source.mirrored
        thumbnailViews[id] = preview
        return preview
    }
    private func updateSourceSelector(participants: [CallParticipant]) {
        let selected = pinnedStream ?? browsedStream ?? currentPrimaryKey.flatMap { streamPinTargets[$0] }
        let automatic = UIAction(title: L("Follow speaker"), image: UIImage(systemName: "waveform"),
            state: pinnedStream == nil && browsedStream == nil ? .on : .off) { [weak self] _ in self?.setPin(nil) }
        let sources = orderedStreams.compactMap { target -> UIAction? in
            guard let owner = participants.first(where: { $0.id == target.participantID }) else { return nil }
            let name = (owner.name ?? L("Musician")) + (target.isScreenShare ? L(" · Screen") : "")
            return UIAction(title: name, image: UIImage(systemName: target.isScreenShare ? "rectangle.on.rectangle" : "video"),
                identifier: .init(streamID(target)),
                state: selected == target ? .on : .off) { [weak self] _ in self?.setPin(target) }
        }
        sourceSelector.menu = UIMenu(children: [automatic, UIMenu(options: .displayInline, children: sources)])
        sourceSelector.configuration?.title = primaryName ?? L("Screen share")
        sourceSelector.accessibilityLabel = L("Screen share") + ": " + (primaryName ?? L("Musician"))
    }
    func render(snapshot: CallMediaSnapshot) {
        for entry in videoTiles.values where entry.zoom.window != nil { rememberZoom(entry.zoom) }
        displayedSnapshot = snapshot
        let ids = snapshot.participants.map(\.id), existing = Set(rosterOrder)
        let activeIDs = Set(ids)
        rosterOrder.removeAll { !activeIDs.contains($0) }
        rosterOrder.append(contentsOf: ids.filter { !existing.contains($0) })
        let ranks = Dictionary(uniqueKeysWithValues: rosterOrder.enumerated().map { ($1, $0) })
        let participants = snapshot.participants.sorted { ranks[$0.id, default: .max] < ranks[$1.id, default: .max] }
        localShareRenderer.setTrack(snapshot.localShare?.roomTrack)
        let sharing = participants.first { $0.isLocal }?.screenShareOn ?? false
        if isSharingScreen != sharing { setSharing(sharing) }
        if let pin = pinnedStream, !preservingPinDuringReconnect,
           !participants.contains(where: { $0.id == pin.participantID && (!pin.isScreenShare || $0.screenShareOn) }) {
            pinnedStream = nil
            if !pin.isScreenShare { layoutMode = .grid }
        }
        let identifier = workspace.roomIdentifier.map { " · \($0)" } ?? ""
        countLabel.text = snapshot.remoteParticipants.isEmpty ? L("Only you here%@", identifier) : L("%ld musicians", participants.count) + identifier
        participantsButton.isEnabled = true
        participantsButton.accessibilityLabel = L("Musicians, %ld", participants.count)
        tiles.arrangedSubviews.forEach { $0.removeFromSuperview() }
        participantBadges.removeAll(); speakingTiles.removeAll(); tileOrder.removeAll(); tileSelections.removeAll()
        identityTiles = identityTiles.filter { activeIDs.contains($0.key) }
        identityViews = identityViews.filter { activeIDs.contains($0.key) }
        let liveShareOwners = Set(participants.filter { !$0.isLocal && $0.screenShareOn }.map(\.id))
        if !preservingPinDuringReconnect { retainedShares = retainedShares.filter { liveShareOwners.contains($0.key) } }
        if let selectedShare, !liveShareOwners.contains(selectedShare.participantID), !preservingPinDuringReconnect {
            self.selectedShare = nil; cameraFocusShare = nil
        }
        if selectedShare == nil, let owner = participants.first(where: { liveShareOwners.contains($0.id) }) {
            selectedShare = PinnedStream(participantID: owner.id, isScreenShare: true)
        }
        reconnectingShares.removeAll()
        var streams: [(CallParticipant, CallVideoStream, CallVideoSource)] = []
        orderedStreams = []
        for participant in participants {
            if displayMode != .screenShares { orderedStreams.append(PinnedStream(participantID: participant.id, isScreenShare: false)) }
            for publication in participant.videoTracks where !publication.isMuted &&
                !(participant.isLocal && publication.source == .screenShareVideo) && displayMode != .audioOnly &&
                displayMode == .all && publication.source != .screenShareVideo && participant.cameraOn {
                streams.append((participant, publication, publication.track))
            }
            if !participant.isLocal && participant.screenShareOn && displayMode != .audioOnly {
                orderedStreams.append(PinnedStream(participantID: participant.id, isScreenShare: true))
                let live = participant.videoTracks.first { $0.source == .screenShareVideo && !$0.isMuted }
                if let live {
                    if let previous = retainedShares[participant.id], previous.id != live.id {
                        if let tile = videoTiles.removeValue(forKey: previous.id) {
                            tile.tile.accessibilityIdentifier = live.id; tile.zoom.accessibilityIdentifier = live.id
                            videoTiles[live.id] = tile
                        }
                        if let state = zoomStates.removeValue(forKey: previous.id) { zoomStates[live.id] = state }
                    }
                    retainedShares[participant.id] = live
                } else { reconnectingShares.insert(participant.id) }
                if let publication = live ?? retainedShares[participant.id] {
                    streams.append((participant, publication, publication.track))
                }
            }
        }
        if displayMode == .screenShares, pinnedStream?.isScreenShare == false { pinnedStream = nil; cameraFocusShare = nil }
        if let browsedStream, !orderedStreams.contains(browsedStream) { self.browsedStream = nil }
        let activeKeys = Set(streams.map { $0.1.id })
        videoTiles = videoTiles.filter { activeKeys.contains($0.key) }
        let previousThumbnailSources = thumbnailSources
        thumbnailSources = Dictionary(streams.filter { $0.1.source == .camera }.map { participant, publication, track in
            (streamID(PinnedStream(participantID: participant.id, isScreenShare: false)),
             (key: publication.id, track: track, mirrored: participant.isLocal &&
                CameraPreviewPresentation.isMirrored(device: studio?.liveCaptureDevice?())))
        }, uniquingKeysWith: { first, _ in first })
        let thumbnailsChanged = Set(previousThumbnailSources.keys) != Set(thumbnailSources.keys) ||
            thumbnailSources.contains { id, source in
                guard let previous = previousThumbnailSources[id] else { return true }
                return previous.key != source.key || previous.track.identity != source.track.identity || previous.mirrored != source.mirrored
            }
        for (id, preview) in thumbnailViews {
            guard let source = thumbnailSources[id] else { preview.video.track = nil; preview.video.isEnabled = false; continue }
            preview.video.track = participantStrip.visiblePreviewIDs.contains(id) && preview.window != nil ? source.track : nil
            preview.video.isMirrored = source.mirrored
        }
        thumbnailViews = thumbnailViews.filter { thumbnailSources[$0.key] != nil }
        if thumbnailsChanged { participantStrip.reloadPreviews() }
        streamPinTargets = Dictionary(uniqueKeysWithValues: orderedStreams.map { (streamID($0), $0) })
        for stream in streams { streamPinTargets[stream.1.id] = PinnedStream(participantID: stream.0.id, isScreenShare: stream.1.source == .screenShareVideo) }
        if !streams.contains(where: { $0.0.isLocal && $0.1.source != .screenShareVideo }) {
            NSLayoutConstraint.deactivate(flipCameraConstraints); flipCameraConstraints.removeAll(); flipCamera.removeFromSuperview()
        }
        let requested = pinnedStream ?? browsedStream
        let selection = requested ?? (displayMode == .audioOnly ? nil : selectedShare)
        let primary = selection.flatMap { target in streams.first { streamPinTargets[$0.1.id] == target } } ??
            (selection == nil ? streams.first { $0.1.source == .screenShareVideo } ??
                streams.first { $0.0.id == activeSpeaker.current?.id && !$0.0.isLocal } ?? streams.first { !$0.0.isLocal } ?? streams.first : nil)
        pinnedStreamKey = primary.flatMap { requested == nil ? nil : $0.1.id }
        currentPrimaryKey = primary?.1.id
        currentPrimaryTarget = selection ?? primary.flatMap { streamPinTargets[$0.1.id] }
        primaryName = currentPrimaryTarget.flatMap { target in participants.first { $0.id == target.participantID }?.name } ?? primary?.0.name
        updateSourceSelector(participants: participants)
        primaryZoom = nil
        // PiP always carries the chosen screen while an explicit camera occupies the local stage.
        let floatingSource = selectedShare.flatMap { target in streams.first { streamPinTargets[$0.1.id] == target } } ??
            (selectedShare == nil ? primary : nil)
        pictureInPictureKey = floatingSource?.1.id
        if let floatingSource {
            floatingVideo?.show(source: floatingSource.2, name: floatingSource.0.name ?? L("Musician"),
                isScreenShare: floatingSource.1.source == .screenShareVideo,
                mirrored: floatingSource.0.isLocal && floatingSource.1.source == .camera && CameraPreviewPresentation.isMirrored(device: studio?.liveCaptureDevice?()))
        } else { floatingVideo?.clear() }
        let shareOwner = selectedShare.flatMap { target in participants.first { $0.id == target.participantID } }
        offeredShare = selectedShare
        shareOffer.isHidden = shareOwner == nil || (!explicitLayout && requested == nil) || currentPrimaryTarget == selectedShare && effectiveLayoutMode != .grid
        shareOffer.configuration?.title = shareOwner.map { L("%@ is sharing · View", $0.name ?? L("Musician")) }
        let companionShare = currentPrimaryTarget?.isScreenShare == true ? currentPrimaryTarget : cameraFocusShare
        let companionOwner = companionShare.flatMap { target in participants.first { $0.id == target.participantID } }
        presenterSource = companionOwner.flatMap { thumbnailSources[streamID(PinnedStream(participantID: $0.id, isScreenShare: false))] }
        presenterCompanion.configure(name: companionOwner?.name ?? L("Musician"),
            preview: presenterSource == nil ? nil : presenterPreview, cameraFocused: cameraFocusShare != nil)
        updatePresenterDemand(foreground: UIApplication.shared.applicationState != .background)
        let focused = effectiveLayoutMode == .speaker && displayMode != .audioOnly
        if focused {
            if let primary { tiles.addArrangedSubview(videoTile(for: primary.0, publication: primary.1, track: primary.2, primary: true)) }
            else if currentPrimaryTarget?.isScreenShare == true {
                let placeholder = UILabel(); placeholder.text = L("Reconnecting to shared screen…")
                placeholder.textColor = .lightGray; placeholder.textAlignment = .center
                placeholder.accessibilityIdentifier = currentPrimaryTarget.map(streamID)
                tiles.addArrangedSubview(placeholder)
            }
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
        if displayMode == .screenShares && streams.isEmpty && currentPrimaryTarget?.isScreenShare != true {
            let empty = UILabel(); empty.text = L("No screen share is live. Audio continues.")
            empty.textColor = .lightGray; empty.textAlignment = .center; empty.numberOfLines = 0
            tiles.addArrangedSubview(empty)
        }
        if snapshot.remoteParticipants.isEmpty && streams.isEmpty && displayMode == .all { tiles.addArrangedSubview(waitingRoomView()) }
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
        zoom.contentInsetAdjustmentBehavior = .never
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
        video.onDisplaySizeChanged = { [weak self] in self?.updateShareScaleControl(); self?.view.setNeedsLayout() }
        video.track = track
        video.translatesAutoresizingMaskIntoConstraints = false
        let canvas = UIView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        zoom.addSubview(canvas)
        canvas.addSubview(video)
        tile.addSubview(zoom)
        let badge = ParticipantMediaBadge()
        badge.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(badge)
        let pin = UIButton(type: .system)
        pin.configuration = .tinted()
        pin.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        pin.configuration?.contentInsets = .zero
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
        let fitting = [
            video.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            video.topAnchor.constraint(equalTo: canvas.topAnchor),
            video.widthAnchor.constraint(equalToConstant: 0),
            video.heightAnchor.constraint(equalToConstant: 0)
        ]
        let overlays = [
            badge.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 10),
            badge.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -10),
            pin.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -10),
            pin.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -8)
        ]
        NSLayoutConstraint.activate(fitting + overlays + [
            zoom.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            zoom.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            zoom.topAnchor.constraint(equalTo: tile.topAnchor),
            zoom.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: zoom.contentLayoutGuide.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: zoom.contentLayoutGuide.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: zoom.contentLayoutGuide.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: zoom.contentLayoutGuide.bottomAnchor),
            canvas.widthAnchor.constraint(equalTo: zoom.frameLayoutGuide.widthAnchor),
            canvas.heightAnchor.constraint(equalTo: zoom.frameLayoutGuide.heightAnchor),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: pin.leadingAnchor, constant: -6),
            pin.widthAnchor.constraint(equalToConstant: 44),
            pin.heightAnchor.constraint(equalToConstant: 44)
        ])
        var entry = VideoTile(tile: tile, zoom: zoom, canvas: canvas, video: video, fitting: fitting,
            overlays: overlays, badge: badge, pin: pin)
        configureVideoTile(&entry, participant: participant, track: track,
                           isShare: isShare, primary: primary, key: key)
        videoTiles[key] = entry
        return tile
    }

    private func configureVideoTile(_ entry: inout VideoTile, participant: CallParticipant,
                                    track: CallVideoSource, isShare: Bool, primary: Bool, key: String) {
        tileSelections[ObjectIdentifier(entry.tile)] = PinnedStream(participantID: participant.id, isScreenShare: isShare)
        entry.tile.accessibilityLabel = "\(participant.name ?? L("Musician")) \(isShare ? L("screen share") : L("video"))"
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
        let primary = (pinnedStream ?? browsedStream) ?? currentPrimaryTarget
        participantStrip.update(orderedStreams.filter { !$0.isScreenShare && $0 != primary }.compactMap { target in
            guard let owner = byID[target.participantID] else { return nil }
            return MeetingStripItem(id: streamID(target), name: owner.name ?? L("Musician"), isShare: target.isScreenShare,
                audio: ParticipantAudioState(microphoneOn: owner.microphoneOn, speaking: owner.isSpeaking))
        }, selected: primary.map(streamID))
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

    func setDisplayMode(_ mode: ConferenceDisplayMode) {
        displayMode = mode
        if let snapshot = displayedSnapshot { render(snapshot: snapshot) }
        onDisplayMode?(mode)
    }

    private func configureMoreMenu() {
        reactionsButton.accessibilityValue = floatingVideo?.canShow == true ? L("Floating video available") : nil
        var cameraSound: [UIMenuElement] = []
        var sharePresenter: [UIMenuElement] = [
            UIAction(title: isSharingScreen ? L("Stop sharing") : L("Share screen"), image: UIImage(systemName: "rectangle.on.rectangle"),
                attributes: supportsSharing && (sharingAvailable || isSharingScreen) ? [] : [.disabled]) { [weak self] _ in
                    guard let self else { return }
                    self.performGroupedShareAction()
                }
        ]
        var invite: [UIMenuElement] = []
        let assistantTitle = currentAssistantMode == .off
            ? L("Assistant mode")
            : L("Assistant mode: %@", currentAssistantMode.title)
        var meeting: [UIMenuElement] = [UIAction(title: assistantTitle, image: UIImage(systemName: "sparkles")) { [weak self] _ in
            self?.onOpenAssistant?()
        }, UIAction(title: L("Voice reply"), image: UIImage(systemName: "waveform.and.mic"),
                attributes: isHeld ? [.disabled] : []) { [weak self] _ in
            self?.workspace.openVoiceReply?()
        }, UIAction(title: L("Meeting details"), image: UIImage(systemName: "info.circle")) { [weak self] _ in
            guard let self else { return }
            let details = [self.workspace.roomIdentifier, self.workspace.invitationURL?.absoluteString].compactMap { $0 }.joined(separator: "\n")
            let alert = UIAlertController(title: self.titleLabel.text, message: details, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("Done"), style: .default))
            self.reactionsButton.callActionPresenter?.present(alert, animated: true)
        }]
        if activeMeetingsForSwitcher.count < ConferenceModel.maxConcurrentMeetings, onJoinAnotherMeeting != nil {
            meeting.append(UIAction(title: L("Join another meeting…"), image: UIImage(systemName: "plus.circle")) { [weak self] _ in
                self?.onJoinAnotherMeeting?()
            })
        }
        if onMinimize != nil {
            meeting.append(UIAction(title: L("Return to Home"), image: UIImage(systemName: "house")) { [weak self] _ in
                self?.onMinimize?()
            })
        }
        if activeMeetingsForSwitcher.count > 1 {
            let roomActions = activeMeetingsForSwitcher.flatMap { item -> [UIMenuElement] in
                var actions: [UIMenuElement] = []
                if !item.isCurrent {
                    actions.append(UIAction(title: L("Switch to %@", item.title), image: UIImage(systemName: "arrow.left.arrow.right")) { [weak self] _ in
                        self?.onSelectMeeting?(item.id)
                    })
                }
                if !item.isTalk {
                    actions.append(UIAction(title: L("Talk Here (%@)", item.title), image: UIImage(systemName: "mic.fill")) { [weak self] _ in
                        self?.onTalkHere?(item.id)
                    })
                }
                return actions
            }
            if !roomActions.isEmpty {
                meeting.append(UIMenu(title: L("Active meetings"), options: .displayInline, children: roomActions))
            }
        }
        if let studio {
            cameraSound = [UIAction(title: L("Camera & sound"), image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
                guard let self else { return }
                StudioPresentation.show(studio, from: self.reactionsButton)
            }, UIAction(title: L("Audio devices"), image: UIImage(systemName: "headphones")) { [weak self] _ in
                guard let self else { return }
                studio.audioSection = .devices
                StudioPresentation.show(studio, from: self.reactionsButton, pane: .sound)
            }, UIAction(title: L("Transcription & voice"), image: UIImage(systemName: "captions.bubble")) { [weak self] _ in
                self?.workspace.openTranscriptionSettings?()
            }]
            if studio.availableCameraCount > 1 {
                cameraSound.append(UIAction(title: L("Flip camera"), image: UIImage(systemName: "camera.rotate"),
                    attributes: studio.canFlipCamera ? [] : [.disabled]) { [weak self] _ in self?.studio?.flipCamera() })
            }
            sharePresenter.append(UIAction(title: L("Share settings"), image: UIImage(systemName: "rectangle.on.rectangle"),
                attributes: studio.presenter.available ? [] : [.disabled]) { [weak self] _ in
                    guard let self else { return }
                    StudioPresentation.show(studio, from: self.reactionsButton, pane: .presenter)
                })
        }
        cameraSound.append(UIAction(title: isSpeakerOn ? L("Use iPhone receiver") : L("Use iPhone speaker"),
            image: UIImage(systemName: "speaker.wave.2")) { [weak self] _ in
                guard let self else { return }
                self.isSpeakerOn.toggle()
                self.workspace.speakerOn = self.isSpeakerOn
                self.onSpeaker?(self.isSpeakerOn)
                self.configureMoreMenu()
            })
        if workspace.invitationURL != nil {
            invite = [UIAction(title: L("Invite musicians"), image: UIImage(systemName: "square.and.arrow.up")) {
                [weak self] _ in guard let self else { return }
                self.workspace.shareInvitation(from: self.reactionsButton)
            }, UIAction(title: L("Copy link"), image: UIImage(systemName: "doc.on.doc")) {
                [weak self] _ in self?.workspace.copyInvitation()
            }]
        }
        let visibility = UIMenu(title: L("Control visibility"), options: .displayInline, children: [
            UIAction(title: L("Hide controls"), image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [weak self] _ in self?.focus.hide() },
            UIAction(title: L("Automatically hide controls"), state: focus.automaticallyHides ? .on : .off) { [weak self] _ in
                guard let self else { return }; self.focus.automaticallyHides.toggle(); self.configureMoreMenu()
            }
        ])
        let screen = UIMenu(title: L("Screen sharing"), options: .displayInline, children: [
            UIAction(title: L("Fit shared screen"), image: UIImage(systemName: "arrow.down.right.and.arrow.up.left"),
                attributes: (primaryZoom?.maximumZoomScale ?? 1) > 1 ? [] : [.disabled]) { [weak self] _ in self?.primaryZoom?.setZoomScale(1, animated: true) },
            UIAction(title: L("Automatic view"), state: browsedStream == nil && pinnedStream == nil ? .on : .off) { [weak self] _ in
                self?.browsedStream = nil; self?.setPin(nil)
            }
        ])
        let floating = UIMenu(title: L("Floating video"), options: .displayInline, children: [
            UIAction(title: L("Show floating video"), image: UIImage(systemName: "pip.enter"),
                attributes: floatingVideo?.canShow == true && !isHeld ? [] : [.disabled]) { [weak self] _ in self?.floatingVideo?.start() },
            UIAction(title: L("Floating video when multitasking"), image: UIImage(systemName: "pip"),
                state: FloatingVideoPreference.enabled ? .on : .off) { [weak self] _ in
                    FloatingVideoPreference.enabled.toggle(); self?.floatingVideo?.refreshPreference(); self?.configureMoreMenu()
                }
        ])
        #if DEBUG
        meeting = fixtureActions + meeting
        #endif
        var quickActions: [UIMenuElement] = []
        if onOpenAssistant != nil {
            let assistantSymbol = currentAssistantMode == .off ? "sparkles" : currentAssistantMode.symbol
            quickActions.append(UIAction(title: assistantTitle, image: UIImage(systemName: assistantSymbol)) { [weak self] _ in
                self?.onOpenAssistant?()
            })
        }
        if activeMeetingsForSwitcher.count < ConferenceModel.maxConcurrentMeetings, onJoinAnotherMeeting != nil {
            quickActions.append(UIAction(title: L("Join another meeting…"), image: UIImage(systemName: "plus.circle")) { [weak self] _ in
                self?.onJoinAnotherMeeting?()
            })
        }
        if onMinimize != nil {
            quickActions.append(UIAction(title: L("Return to Home"), image: UIImage(systemName: "house")) { [weak self] _ in
                self?.onMinimize?()
            })
        }
        let baseMenu = MeetingActionGroup.make(cameraSound: cameraSound, sharePresenter: sharePresenter,
            view: [visibility, screen, floating], invite: invite, meeting: meeting)
        if quickActions.isEmpty {
            actionsMenu = baseMenu
        } else {
            let quickMenu = UIMenu(title: "", options: .displayInline, children: quickActions)
            actionsMenu = UIMenu(children: [quickMenu] + baseMenu.children)
        }
    }

    func performGroupedShareAction() {
        guard supportsSharing, sharingAvailable || isSharingScreen else { return }
        if isSharingScreen || usesNativeShareControl {
            onShare?(!isSharingScreen)
        } else if #available(iOS 27.0, *) {
            onShare?(true)
        } else {
            // LiveKit's older-iOS path must open ReplayKit's consent picker,
            // exactly as tapping the broadcast control in the dock does.
            (sharePicker.subviews.compactMap { $0 as? UIButton }.first)?.sendActions(for: .touchUpInside)
        }
    }

    func setSharing(_ enabled: Bool) {
        guard supportsSharing else {
            share.isHidden = false; share.isEnabled = false; sharePicker.isHidden = true; shareTitle.isHidden = true; broadcastAppearance.isHidden = true
            return
        }
        isSharingScreen = enabled
        reminderHost.changed()
        studio?.screenSharing = enabled
        studio?.screenSharingAvailable = supportsSharing && sharingAvailable
        share.isEnabled = sharingAvailable || enabled
        share.isHidden = usesBroadcastPicker && !enabled
        sharePicker.isHidden = !usesBroadcastPicker || enabled
        shareTitle.isHidden = sharePicker.isHidden
        broadcastAppearance.isHidden = sharePicker.isHidden
        shareTitle.isHidden = true
        share.configuration?.image = UIImage(systemName: enabled ? "rectangle.slash" : "rectangle.on.rectangle")
        updateControlTitles()
        share.configuration?.baseForegroundColor = enabled ? accent : .label
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
        microphone.configuration?.baseForegroundColor = enabled ? accent : .label
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
        camera.configuration?.baseForegroundColor = enabled ? accent : .label
        camera.accessibilityLabel = enabled ? L("Stop video") : L("Start video")
        camera.largeContentTitle = camera.accessibilityLabel
        updateStatus()
    }

    func setHeld(_ held: Bool) {
        isHeld = held
        if held { presenterCompanion.isHidden = true }
        updatePresenterDemand(foreground: UIApplication.shared.applicationState != .background)
        onVideoDemandChanged?()
        updateSpeakerAvailability()
        studio?.held = held
        if held { focus.show() }
        workspace.onHold = held
        floatingVideo?.setSuspended(held)
        configureMoreMenu()
        updateStatus()
    }

    /// Computes transport video subscription demand for `MeetingEngine` separately from
    /// inline view-level pixel rendering (`visibleVideoQualities`). Never emits an empty
    /// `visibleParticipantIDs` set when foreground video is active, so newly started remote
    /// cameras and screen shares are discovered and subscribed automatically.
    func videoSubscriptionDemand(foreground: Bool, wantsVideo: Bool) -> MeetingEngine.MeetingVideoDemand {
        _ = visibleVideoQualities(foreground: foreground, wantsVideo: wantsVideo)
        guard (foreground || wantsVideo) && !isHeld && displayMode != .audioOnly else {
            return MeetingEngine.MeetingVideoDemand(
                visibleParticipantIDs: [],
                focusedParticipantID: nil,
                preferredScreenParticipantID: nil,
                receivesCameras: false
            )
        }
        let receivesCameras = (displayMode == .all)
        let focusedID = currentPrimaryTarget?.participantID
        let preferredScreenID = currentPrimaryTarget?.isScreenShare == true
            ? currentPrimaryTarget?.participantID
            : selectedShare?.participantID

        let visibleParticipantIDs: Set<String>?
        if !foreground && wantsVideo {
            if let pipParticipantID = (selectedShare ?? currentPrimaryTarget)?.participantID {
                visibleParticipantIDs = [pipParticipantID]
            } else {
                visibleParticipantIDs = nil
            }
        } else if displayMode == .screenShares || (displayedSnapshot?.remoteParticipants.count ?? 0) <= 6 {
            visibleParticipantIDs = nil
        } else {
            var ids = Set<String>()
            if effectiveLayoutMode == .grid {
                if streamScroll.bounds.width > 0 && streamScroll.bounds.height > 0 {
                    for tile in tiles.arrangedSubviews where !tile.isHidden {
                        let rect = tile.convert(tile.bounds, to: streamScroll)
                        if streamScroll.bounds.intersects(rect),
                           let participantID = tileSelections[ObjectIdentifier(tile)]?.participantID {
                            ids.insert(participantID)
                        }
                    }
                }
            } else {
                for candidate in [focusedID,
                                  preferredScreenID,
                                  selectedShare?.participantID,
                                  cameraFocusShare?.participantID,
                                  activeSpeaker.current?.id] {
                    if let candidate { ids.insert(candidate) }
                }
                for stripID in participantStrip.visiblePreviewIDs {
                    if let participantID = streamPinTargets[stripID]?.participantID {
                        ids.insert(participantID)
                    }
                }
                if let target = currentPrimaryTarget, let index = orderedStreams.firstIndex(of: target) {
                    for adjacent in [index - 1, index + 1] where orderedStreams.indices.contains(adjacent) {
                        ids.insert(orderedStreams[adjacent].participantID)
                    }
                }
            }
            if let focusedID { ids.insert(focusedID) }
            if let preferredScreenID { ids.insert(preferredScreenID) }
            visibleParticipantIDs = ids.isEmpty ? nil : ids
        }

        return MeetingEngine.MeetingVideoDemand(
            visibleParticipantIDs: visibleParticipantIDs,
            focusedParticipantID: focusedID,
            preferredScreenParticipantID: preferredScreenID,
            receivesCameras: receivesCameras
        )
    }

    /// Stream metadata stays present when its pixels are paused, so browsing and pinning remain available.
    func visibleVideoQualities(foreground: Bool, wantsVideo: Bool) -> [String: Bool] {
        let inlineVisible = foreground && stageSurfaceVisible
        var result: [String: Bool] = [:]
        for (key, tile) in videoTiles {
            let visible = inlineVisible && tile.tile.superview != nil && !tile.tile.isHidden &&
                streamScroll.bounds.intersects(tile.tile.convert(tile.tile.bounds, to: streamScroll))
            tile.video.isEnabled = visible
            if visible { result[key] = key == currentPrimaryKey }
        }
        if wantsVideo, let key = pictureInPictureKey { result[key] = true }
        presenterCompanion.refreshVisibility()
        updatePresenterDemand(foreground: inlineVisible)
        if inlineVisible, displayMode == .all, presenterCompanion.isPreviewVisible, let source = presenterSource, result[source.key] == nil {
            result[source.key] = false
        }
        for (id, preview) in thumbnailViews {
            let visible = inlineVisible && participantStrip.visiblePreviewIDs.contains(id)
            preview.video.isEnabled = visible
            if visible, let key = thumbnailSources[id]?.key, result[key] == nil { result[key] = false }
        }
        // Preload adjacent camera tiles while foregrounded to keep swiping responsive.
        if inlineVisible, !focus.hidden, effectiveLayoutMode == .speaker, currentPrimaryTarget?.isScreenShare != true,
           cameraFocusShare == nil, pinnedStream == nil, let key = currentPrimaryKey, let target = streamPinTargets[key], let index = orderedStreams.firstIndex(of: target) {
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

    func endFloatingVideo() {
        textCapture?.finish(); panelOwner.retire(); activeSpeaker.end(); floatingVideo?.end(); localShareRenderer.setTrack(nil); localSharePreview.end()
        presenterSource = nil; presenterCompanion.configure(name: "", preview: nil); presenterPreview.video.track = nil
    }

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

    private func refreshSwitcherChrome() {
        guard isViewLoaded else { return }
        minimizeButton.isHidden = onMinimize == nil
        let multiple = activeMeetingsForSwitcher.count > 1
        let canJoinMore = onJoinAnotherMeeting != nil
        switcherButton.isHidden = activeMeetingsForSwitcher.isEmpty && !canJoinMore
        let symbol = multiple ? "rectangle.stack.fill" : "rectangle.stack.badge.plus"
        let label = multiple ? L("Active meetings") : L("Meetings & join another")
        switcherButton.configuration?.image = UIImage(systemName: symbol)
        switcherButton.configuration?.title = multiple ? "\(activeMeetingsForSwitcher.count)" : nil
        switcherButton.accessibilityLabel = label
        switcherButton.largeContentTitle = label
        switcherButton.largeContentImage = UIImage(systemName: symbol)
        talkHereButton.isHidden = isTalkRoom || !multiple
        syncCompactWorkspaceControls()
        configureMoreMenu()
        view.setNeedsLayout()
    }

    private func syncCompactWorkspaceControls() {
        let symbol = currentAssistantMode == .off ? "sparkles" : currentAssistantMode.symbol
        let modeColor: UIColor
        if currentAssistantPaused || currentAssistantAlertCount > 0 {
            modeColor = .systemOrange
        } else {
            switch currentAssistantMode {
            case .off: modeColor = .label
            case .mentions: modeColor = .systemBlue
            case .follow: modeColor = .systemIndigo
            case .participating: modeColor = .systemGreen
            }
        }
        let label = L("Assistant mode: %@", currentAssistantMode.title)
        let activeCount = activeMeetingsForSwitcher.count
        let switcherAvailable = !activeMeetingsForSwitcher.isEmpty || onJoinAnotherMeeting != nil
        compactHeader.setCallWorkspaceControls(
            minimizeAvailable: onMinimize != nil,
            assistantAvailable: onOpenAssistant != nil,
            assistantSymbol: symbol,
            assistantColor: modeColor,
            assistantLabel: label,
            assistantAlertCount: currentAssistantAlertCount,
            switcherAvailable: switcherAvailable,
            activeMeetingCount: activeCount
        )
    }

    private func presentSwitcher() {
        guard presentedViewController == nil,
              !activeMeetingsForSwitcher.isEmpty || onJoinAnotherMeeting != nil || onMinimize != nil else { return }
        let sheet = UIAlertController(title: L("Active meetings"), message: nil, preferredStyle: .actionSheet)
        for item in activeMeetingsForSwitcher {
            let role = item.isTalk ? L("Talk") : L("Listening")
            let label = item.isCurrent ? "\(item.title) · \(role) (\(L("Current")))" : "\(item.title) · \(role)"
            sheet.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                guard let self else { return }
                if !item.isCurrent { self.onSelectMeeting?(item.id) }
            })
            if !item.isTalk {
                sheet.addAction(UIAlertAction(title: L("Talk in %@", item.title), style: .default) { [weak self] _ in
                    self?.onTalkHere?(item.id)
                })
            }
            sheet.addAction(UIAlertAction(title: L("Leave %@", item.title), style: .destructive) { [weak self] _ in
                self?.onLeaveMeeting?(item.id)
            })
        }
        if activeMeetingsForSwitcher.count < ConferenceModel.maxConcurrentMeetings, let onJoinAnotherMeeting {
            sheet.addAction(UIAlertAction(title: L("Join another meeting…"), style: .default) { _ in
                onJoinAnotherMeeting()
            })
        }
        if let onMinimize {
            sheet.addAction(UIAlertAction(title: L("Return to Home"), style: .default) { _ in
                onMinimize()
            })
        }
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        if let popover = sheet.popoverPresentationController {
            let anchor = !compactHeader.isHidden ? compactHeader.switcher : switcherButton
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
        }
        present(sheet, animated: true)
    }

    func updateAssistantBadge(mode: IOSMeetingAssistantMode, isPaused: Bool, alertCount: Int) {
        currentAssistantMode = mode
        currentAssistantPaused = isPaused
        currentAssistantAlertCount = alertCount
        guard isViewLoaded else { return }
        let symbol = mode == .off ? "sparkles" : mode.symbol
        let color: UIColor
        if isPaused || alertCount > 0 {
            color = .systemOrange
        } else {
            switch mode {
            case .off: color = .label
            case .mentions: color = .systemBlue
            case .follow: color = .systemIndigo
            case .participating: color = .systemGreen
            }
        }
        let label = L("Assistant mode: %@", mode.title)
        assistantButton.configuration?.image = UIImage(systemName: symbol)
        assistantButton.configuration?.title = alertCount > 0 ? "\(alertCount)" : nil
        assistantButton.configuration?.baseForegroundColor = color
        assistantButton.accessibilityLabel = label
        assistantButton.largeContentTitle = label
        assistantButton.largeContentImage = UIImage(systemName: symbol)
        syncCompactWorkspaceControls()
        configureMoreMenu()
    }

    func showAssistantAlert(title: String, reason: String, onTap: @escaping () -> Void) {
        guard isViewLoaded else { return }
        dismissAssistantAlert()
        assistantBannerTapHandler = onTap

        let container = UIView()
        container.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.96)
        container.layer.cornerRadius = 14
        container.layer.borderWidth = 0.5
        container.layer.borderColor = UIColor.separator.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "sparkles"))
        icon.tintColor = accent
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLbl = UILabel()
        titleLbl.text = title
        titleLbl.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLbl.textColor = .secondaryLabel
        titleLbl.numberOfLines = 1

        let bodyLbl = UILabel()
        bodyLbl.text = reason
        bodyLbl.font = .preferredFont(forTextStyle: .subheadline)
        bodyLbl.textColor = .label
        bodyLbl.numberOfLines = 2

        let textStack = UIStackView(arrangedSubviews: [titleLbl, bodyLbl])
        textStack.axis = .vertical
        textStack.spacing = 2

        let closeBtn = UIButton(type: .system)
        closeBtn.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeBtn.tintColor = .tertiaryLabel
        closeBtn.accessibilityLabel = L("Dismiss alert")
        closeBtn.addAction(UIAction { [weak self] _ in self?.dismissAssistantAlert() }, for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [icon, textStack, closeBtn])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(row)
        view.addSubview(container)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleAssistantBannerTap))
        container.addGestureRecognizer(tap)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            closeBtn.widthAnchor.constraint(equalToConstant: 32),
            closeBtn.heightAnchor.constraint(equalToConstant: 32),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 56),
            container.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            container.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12)
        ])
        view.bringSubviewToFront(container)

        assistantBannerView = container
        assistantBannerDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.dismissAssistantAlert()
        }
    }

    private func dismissAssistantAlert() {
        assistantBannerDismissTask?.cancel()
        assistantBannerDismissTask = nil
        assistantBannerView?.removeFromSuperview()
        assistantBannerView = nil
        assistantBannerTapHandler = nil
    }

    @objc private func handleAssistantBannerTap() {
        let handler = assistantBannerTapHandler
        dismissAssistantAlert()
        handler?()
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
        style.baseForegroundColor = .label
        button.configuration = style
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.accessibilityLabel = label
        button.showsLargeContentViewer = true
        button.largeContentTitle = label
        button.largeContentImage = UIImage(systemName: symbol)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        guard scrollView !== streamScroll, let key = scrollView.accessibilityIdentifier else { return nil }
        return videoTiles[key]?.canvas
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        if scrollView !== streamScroll {
            scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > 1.01
            scrollView.accessibilityValue = "\(Int((scrollView.zoomScale * 100).rounded()))%"
            rememberZoom(scrollView)
            if !restoringZoom && scrollView === primaryZoom { updateShareScaleControl() }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === streamScroll {
            onVideoDemandChanged?()
        }
        rememberZoom(scrollView)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if scrollView === streamScroll && !decelerate { settleGalleryPage() }
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
              entry.video.bounds.width > 0, entry.video.bounds.height > 0 else { return }
        let center = zoom.convert(CGPoint(x: zoom.bounds.midX, y: zoom.bounds.midY), to: entry.video)
        zoomStates[key] = (zoom.zoomScale, CGPoint(
            x: center.x / entry.video.bounds.width, y: center.y / entry.video.bounds.height))
    }
    private func restoreZoom(_ zoom: UIScrollView, key: String) {
        guard let state = zoomStates[key], let entry = videoTiles[key] else { return }
        zoom.setZoomScale(state.0, animated: false)
        let center = entry.video.convert(CGPoint(x: state.1.x * entry.video.bounds.width,
            y: state.1.y * entry.video.bounds.height), to: zoom)
        zoom.contentOffset = CGPoint(
            x: min(max(0, center.x - zoom.bounds.width / 2), max(0, zoom.contentSize.width - zoom.bounds.width)),
            y: min(max(0, center.y - zoom.bounds.height / 2), max(0, zoom.contentSize.height - zoom.bounds.height)))
    }
}
