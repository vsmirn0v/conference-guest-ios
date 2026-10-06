import Combine
import CoreMedia
import JazzSDK
import UIKit

final class CallControls: UIView, UIGestureRecognizerDelegate {
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        CallKeyboardCommands.make(microphone: #selector(keyToggleMicrophone), camera: #selector(keyToggleCamera),
            chat: #selector(keyOpenChat), participants: #selector(keyOpenParticipants), fit: #selector(keyFitScreen), focus: #selector(keyFocus), restore: #selector(keyRestoreControls)) +
            [UIKeyCommand(input: ",", modifierFlags: .command, action: #selector(keyOpenStudio))]
    }
    @objc private func keyToggleMicrophone() { microphone.sendActions(for: .touchUpInside) }
    @objc private func keyToggleCamera() { camera.sendActions(for: .touchUpInside) }
    @objc private func keyOpenStudio() {
        guard let studio else { return }
        StudioPresentation.show(studio, from: moreButton)
    }
    @objc private func keyOpenChat() { catchUpButton.sendActions(for: .touchUpInside) }
    @objc private func keyOpenParticipants() { participantsButton.sendActions(for: .touchUpInside) }
    @objc private func keyFocus() { focus.toggle() }
    @objc private func keyRestoreControls() { focus.show(); focus.interaction() }
    @objc private func keyFitScreen() { fitZoomedContent() }
    private let surface = CallChromeSurface()
    private let focus = CallFocusController()
    private let layoutOwner = UUID()
    private weak var mountedWindow: UIWindow?
    private var toolbar: CallToolbar?
    private var headerView: UIStackView?
    private let compactHeader = CompactCallHeader()
    private let focusButton = UIButton(type: .system)
    private let navigation = UIStackView()
    private let previous = UIButton(type: .system)
    private let nextStream = UIButton(type: .system)
    private let automaticView = UIButton(type: .system)
    private var navigationCount = 0
    private var stagePinned = false
    var onBrowse: ((Int) -> Void)?
    var onAutomaticView: (() -> Void)?
    var onPinStage: (() -> Void)?
    var onPinParticipant: ((GuestStreamViews.PinTarget?) -> Void)?
    private let usesNativeParticipants: Bool
    private weak var participantsPanel: ParticipantPanelViewController?
    private var participantRoster: [GuestStreamViews.Participant] = []
    private var speakingParticipant: String?
    private var pinnedParticipant: GuestStreamViews.PinTarget?
    private var participantPinTargets: [String: GuestStreamViews.PinTarget] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private let localPreview: LocalSharePreview
    private let localShareCard: LocalSharePreviewCard
    private let microphone = AlignedCallButton(frame: .zero)
    private let camera = AlignedCallButton(frame: .zero)
    private let share = AlignedCallButton(frame: .zero)
    private let route = UIView()
    private let catchUpButton = UIButton(type: .system)
    private let missedButton = UIButton(type: .system)
    private let participantsButton = UIButton(type: .system)
    private let moreButton = AlignedCallButton(frame: .zero)
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let routeLabel = UILabel()
    private let callStateLabel = UILabel()
    private let speakerLabel = UILabel()
    private let audioOnlyBackdrop = UIView()
    private let screenSharesBackdrop = UIView()
    private let waitingBackdrop = UIView()
    private let stageView = UIView()
    private let stageVideo = GuestSampleBufferView()
    private let stageStatus = UILabel()
    private let shareOffer = UIButton(type: .system)
    private var stageViewport: StreamViewport?
    private var lastPresentation: GuestStreamViews.Presentation?
    private var stageID: String?
    private var stageName: String?
    private var stageIsShare = false
    private var stageActive = false
    private var stageHasFrame = false
    var onViewShare: (() -> Void)?
    private let notices = TopNoticeView()
    private var displayMode: ConferenceDisplayMode = .all
    private var hasScreenShare = false
    private var hasVideo = false
    private var isWaitingForOthers = false
    private var cameraOn = false
    private var sdkCameraOn = false
    private var sdkCameraAvailable = true
    private var isHeld = false
    private var mediaStatus: String?
    private var missedCount = 0
    private var unreadChatCount = 0
    private let workspace = CallWorkspaceControls()
    private let onFloat: () -> Void
    private let onFloatingPreferenceChanged: () -> Void
    private var floatingVideoAvailable = false
    private var refreshMoreMenu: (() -> Void)?
    private let studio: StudioModel?
    private let activeSpeaker: ActiveSpeakerStore
    #if DEBUG
    var fixtureActions: [UIAction] = [] { didSet { refreshMoreMenu?() } }
    #endif

    var canFloatVideo: Bool {
        floatingVideoAvailable && !isHeld && displayMode != .audioOnly &&
            (displayMode == .screenShares ? hasScreenShare : hasScreenShare || hasVideo)
    }

    init(localPreview: LocalSharePreview, state: JazzActiveConferenceState?, coordinator: JazzActiveConferenceCoordinator?,
         router: JazzActiveConferenceRouter?,
         catchUp: CatchUpStore, chat: ChatStore,
         initialDisplayMode: ConferenceDisplayMode,
         invitationURL: URL?, roomIdentifier: String?,
         onDisplayMode: @escaping (ConferenceDisplayMode) -> Void,
         onFloat: @escaping () -> Void,
         onFloatingPreferenceChanged: @escaping () -> Void,
         onLeave: @escaping () -> Void, onScreenShare: @escaping (Bool) -> Void,
         onMicrophoneState: @escaping (Bool) -> Void,
         onCameraState: @escaping (Bool) -> Void,
         usesNativeParticipants: Bool = ProcessInfo.processInfo.isiOSAppOnMac,
         studio: StudioModel? = nil, activeSpeaker: ActiveSpeakerStore? = nil) {
        self.studio = studio
        self.activeSpeaker = activeSpeaker ?? ActiveSpeakerStore()
        self.usesNativeParticipants = usesNativeParticipants
        self.localPreview = localPreview
        self.localShareCard = LocalSharePreviewCard(model: localPreview)
        self.onFloat = onFloat
        self.onFloatingPreferenceChanged = onFloatingPreferenceChanged
        super.init(frame: .zero)
        localShareCard.onStop = { onScreenShare(false) }
        localShareCard.onLayoutChanged = { [weak self] in self?.surface.setNeedsLayout() }
        refreshMoreMenu = { [weak self] in
            self?.configureMoreMenu(coordinator: coordinator, onChange: onDisplayMode)
        }
        workspace.invitationURL = invitationURL
        workspace.roomIdentifier = roomIdentifier
        displayMode = initialDisplayMode
        backgroundColor = .clear
        surface.tintColor = .white
        audioOnlyBackdrop.backgroundColor = .black
        audioOnlyBackdrop.isHidden = initialDisplayMode != .audioOnly
        audioOnlyBackdrop.isUserInteractionEnabled = false
        audioOnlyBackdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(audioOnlyBackdrop)
        let audioOnlyLabel = UILabel()
        audioOnlyLabel.text = L("Audio only\nJam audio continues")
        audioOnlyLabel.textColor = .lightGray
        audioOnlyLabel.font = .preferredFont(forTextStyle: .title2)
        audioOnlyLabel.numberOfLines = 2
        audioOnlyLabel.textAlignment = .center
        audioOnlyLabel.translatesAutoresizingMaskIntoConstraints = false
        audioOnlyBackdrop.addSubview(audioOnlyLabel)
        let missedWidth = missedButton.widthAnchor.constraint(equalToConstant: 48)
        missedWidth.priority = .defaultHigh
        let missedHeight = missedButton.heightAnchor.constraint(equalToConstant: 48)
        missedHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            audioOnlyBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            audioOnlyBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            audioOnlyBackdrop.topAnchor.constraint(equalTo: topAnchor),
            audioOnlyBackdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            audioOnlyLabel.centerXAnchor.constraint(equalTo: audioOnlyBackdrop.centerXAnchor),
            audioOnlyLabel.centerYAnchor.constraint(equalTo: audioOnlyBackdrop.centerYAnchor),
            audioOnlyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: audioOnlyBackdrop.leadingAnchor, constant: 20),
            audioOnlyLabel.trailingAnchor.constraint(lessThanOrEqualTo: audioOnlyBackdrop.trailingAnchor, constant: -20),
        ])
        // Keep the SDK renderer: it prioritizes a live share, while this coordinator
        // only switches all incoming video together. Cover camera-only output.
        screenSharesBackdrop.backgroundColor = .black
        screenSharesBackdrop.isHidden = initialDisplayMode != .screenShares
        screenSharesBackdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(screenSharesBackdrop)
        let noShareLabel = UILabel()
        noShareLabel.text = L("No screen share is live.\nJam audio continues.")
        noShareLabel.textColor = .lightGray
        noShareLabel.font = .preferredFont(forTextStyle: .title3)
        noShareLabel.adjustsFontForContentSizeCategory = true
        noShareLabel.numberOfLines = 0
        noShareLabel.textAlignment = .center
        noShareLabel.translatesAutoresizingMaskIntoConstraints = false
        screenSharesBackdrop.addSubview(noShareLabel)
        NSLayoutConstraint.activate([
            screenSharesBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            screenSharesBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            screenSharesBackdrop.topAnchor.constraint(equalTo: topAnchor),
            screenSharesBackdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            noShareLabel.centerXAnchor.constraint(equalTo: screenSharesBackdrop.centerXAnchor),
            noShareLabel.centerYAnchor.constraint(equalTo: screenSharesBackdrop.centerYAnchor),
            noShareLabel.leadingAnchor.constraint(greaterThanOrEqualTo: screenSharesBackdrop.leadingAnchor, constant: 20),
            noShareLabel.trailingAnchor.constraint(lessThanOrEqualTo: screenSharesBackdrop.trailingAnchor, constant: -20)
        ])
        waitingBackdrop.backgroundColor = .black
        waitingBackdrop.isHidden = true
        waitingBackdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(waitingBackdrop)
        let waitingLabel = UILabel()
        waitingLabel.text = L("You're connected. Waiting for others.")
        waitingLabel.textColor = .white
        waitingLabel.font = .preferredFont(forTextStyle: .title3)
        waitingLabel.adjustsFontForContentSizeCategory = true
        waitingLabel.textAlignment = .center
        waitingLabel.numberOfLines = 0
        let waitingColumn = UIStackView(arrangedSubviews: [waitingLabel])
        waitingColumn.axis = .vertical
        waitingColumn.alignment = .center
        waitingColumn.spacing = 12
        if invitationURL != nil {
            let invite = UIButton(type: .system)
            invite.configuration = .tinted()
            invite.configuration?.title = L("Invite musicians")
            invite.configuration?.image = UIImage(systemName: "square.and.arrow.up")
            invite.tintColor = UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1)
            invite.addAction(UIAction { [weak self] _ in
                self?.workspace.shareInvitation(from: invite)
            }, for: .touchUpInside)
            let copy = UIButton(type: .system)
            copy.configuration = .plain()
            copy.configuration?.title = L("Copy link")
            copy.tintColor = UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1)
            copy.addAction(UIAction { [weak self] _ in self?.workspace.copyInvitation() },
                           for: .touchUpInside)
            waitingColumn.addArrangedSubview(invite)
            waitingColumn.addArrangedSubview(copy)
        }
        waitingColumn.translatesAutoresizingMaskIntoConstraints = false
        waitingBackdrop.addSubview(waitingColumn)
        NSLayoutConstraint.activate([
            waitingBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            waitingBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            waitingBackdrop.topAnchor.constraint(equalTo: topAnchor),
            waitingBackdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            waitingColumn.centerXAnchor.constraint(equalTo: waitingBackdrop.centerXAnchor),
            waitingColumn.centerYAnchor.constraint(equalTo: waitingBackdrop.centerYAnchor),
            waitingColumn.leadingAnchor.constraint(greaterThanOrEqualTo: waitingBackdrop.leadingAnchor, constant: 20),
            waitingColumn.trailingAnchor.constraint(lessThanOrEqualTo: waitingBackdrop.trailingAnchor, constant: -20),
        ])
        stageView.backgroundColor = .black
        stageView.isHidden = true
        stageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stageView)
        stageStatus.textColor = .white
        stageStatus.textAlignment = .center
        stageStatus.numberOfLines = 0
        stageStatus.translatesAutoresizingMaskIntoConstraints = false
        stageView.addSubview(stageStatus)
        shareOffer.configuration = .tinted()
        shareOffer.configuration?.image = UIImage(systemName: "rectangle.on.rectangle")
        shareOffer.isHidden = true
        shareOffer.addAction(UIAction { [weak self] _ in self?.onViewShare?() }, for: .touchUpInside)
        shareOffer.translatesAutoresizingMaskIntoConstraints = false
        stageView.addSubview(shareOffer)
        NSLayoutConstraint.activate([
            stageStatus.centerXAnchor.constraint(equalTo: stageView.centerXAnchor),
            stageStatus.centerYAnchor.constraint(equalTo: stageView.centerYAnchor),
            stageStatus.leadingAnchor.constraint(greaterThanOrEqualTo: stageView.leadingAnchor, constant: 16),
            stageStatus.trailingAnchor.constraint(lessThanOrEqualTo: stageView.trailingAnchor, constant: -16),
            shareOffer.centerXAnchor.constraint(equalTo: stageView.centerXAnchor),
            shareOffer.topAnchor.constraint(equalTo: stageView.topAnchor, constant: 56),
            shareOffer.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            shareOffer.leadingAnchor.constraint(greaterThanOrEqualTo: stageView.leadingAnchor, constant: 8),
            shareOffer.trailingAnchor.constraint(lessThanOrEqualTo: stageView.trailingAnchor, constant: -8)
        ])

        let leave = Self.button(L("Leave"), symbol: "phone.down.fill")
        catchUpButton.configuration = Self.iconConfiguration("text.bubble")
        catchUpButton.accessibilityLabel = L("Chat")
        missedButton.configuration = Self.iconConfiguration("clock.arrow.circlepath")
        missedButton.accessibilityLabel = L("Catch up")
        missedButton.isHidden = true
        moreButton.configuration = Self.iconConfiguration("ellipsis.circle.fill", title: L("More"))
        moreButton.accessibilityLabel = L("More call options")
        moreButton.showsMenuAsPrimaryAction = true
        participantsButton.configuration = Self.iconConfiguration("person.2.fill")
        participantsButton.accessibilityLabel = L("Musicians")
        configureMoreMenu(coordinator: coordinator, onChange: onDisplayMode)
        microphone.configuration = Self.iconConfiguration("mic.slash.fill", title: L("Mic"))
        camera.configuration = Self.iconConfiguration("video.slash.fill", title: L("Video"))
        microphone.accessibilityLabel = L("Unmute microphone")
        camera.accessibilityLabel = L("Start video")
        share.configuration = Self.iconConfiguration("rectangle.on.rectangle", title: L("Share"))
        share.accessibilityLabel = L("Share screen")
        for button in [microphone, camera, share, catchUpButton, missedButton, moreButton, participantsButton] {
            button.showsLargeContentViewer = true
            button.largeContentTitle = button.accessibilityLabel
            button.largeContentImage = button.configuration?.image
        }
        leave.configuration?.baseForegroundColor = .systemRed

        microphone.addAction(UIAction { [weak self] _ in
            let turnOn = state.map { $0.microphoneState != .on } ?? !(self?.workspace.microphoneOn ?? false)
            onMicrophoneState(turnOn)
            coordinator?.toggleMicrohone(isOn: turnOn)
        }, for: .touchUpInside)
        camera.addAction(UIAction { [weak self, weak studio] _ in
            if let presenter = studio?.presenter, presenter.running {
                presenter.includeCamera.toggle()
                if !presenter.includeCamera { onCameraState(false) }
                return
            }
            let turnOn = state.map { $0.cameraState != .on } ?? !(self?.cameraOn ?? false)
            Task { @MainActor [weak studio] in
                await studio?.releasePrivateCamera()
                guard studio?.active != false, !turnOn || studio?.held != true else { return }
                onCameraState(turnOn)
                coordinator?.toggleCamera(isOn: turnOn)
            }
        }, for: .touchUpInside)
        if let studio {
            studio.enableCamera = { [weak self] in self?.camera.sendActions(for: .touchUpInside) }
            studio.enableMicrophone = { [weak self] in self?.microphone.sendActions(for: .touchUpInside) }
            studio.flipLiveCamera = { coordinator?.switchCamera() }
            StudioShortcut.install(on: microphone, pane: .sound, model: studio)
            StudioShortcut.install(on: camera, pane: .camera, model: studio)
            StudioShortcut.install(on: route, pane: .sound, model: studio)
            StudioShortcut.install(on: share, pane: .presenter, model: studio)
            Publishers.CombineLatest(studio.presenter.$running, studio.presenter.$includeCamera)
                .receive(on: DispatchQueue.main).sink { [weak self] _, _ in self?.renderCameraControl() }
                .store(in: &subscriptions)
        }
        share.addAction(UIAction { _ in
            onScreenShare(state?.screenShareState != .on)
        }, for: .touchUpInside)
        leave.addAction(UIAction { _ in onLeave() }, for: .touchUpInside)
        for button in [microphone, camera, share, participantsButton, catchUpButton, missedButton] {
            button.addAction(UIAction { [weak self] _ in self?.focus.interaction() }, for: .touchUpInside)
        }
        workspace.toggleMicrophone = { [weak self] in self?.microphone.sendActions(for: .touchUpInside) }
        workspace.toggleCamera = { [weak self] in self?.camera.sendActions(for: .touchUpInside) }
        workspace.leave = { leave.sendActions(for: .touchUpInside) }
        catchUpButton.addAction(UIAction { [weak self] _ in
            self?.openConversation(catchUp: catchUp, chat: chat, selected: .chat)
        }, for: .touchUpInside)
        missedButton.addAction(UIAction { [weak self] _ in
            self?.openConversation(catchUp: catchUp, chat: chat, selected: .catchUp)
        }, for: .touchUpInside)
        participantsButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if self.usesNativeParticipants { self.openParticipantsPanel() }
            else { router?.openParticipants() }
        }, for: .touchUpInside)

        route.translatesAutoresizingMaskIntoConstraints = false
        route.accessibilityLabel = L("Audio route")
        let picker: UIView = ProcessInfo.processInfo.isiOSAppOnMac ? MacAudioRouteButton()
            : (coordinator?.audioRoutePickerButton ?? UIButton(type: .system))
        picker.translatesAutoresizingMaskIntoConstraints = false
        route.addSubview(picker)
        let routeAppearance = AlignedCallButton(frame: .zero)
        routeAppearance.configuration = Self.iconConfiguration("speaker.wave.2.fill", title: L("Audio"))
        routeAppearance.isUserInteractionEnabled = false
        routeAppearance.accessibilityElementsHidden = true
        routeAppearance.backgroundColor = UIColor(red: 0.12, green: 0.14, blue: 0.21, alpha: 1)
        routeAppearance.translatesAutoresizingMaskIntoConstraints = false
        route.addSubview(routeAppearance)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: route.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: route.trailingAnchor),
            picker.topAnchor.constraint(equalTo: route.topAnchor),
            picker.bottomAnchor.constraint(equalTo: route.bottomAnchor),
            routeAppearance.leadingAnchor.constraint(equalTo: route.leadingAnchor),
            routeAppearance.trailingAnchor.constraint(equalTo: route.trailingAnchor),
            routeAppearance.topAnchor.constraint(equalTo: route.topAnchor),
            routeAppearance.bottomAnchor.constraint(equalTo: route.bottomAnchor)
        ])

        let bar = CallToolbar(items: [microphone, camera, route, share, moreButton, leave])
        toolbar = bar
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.text = L("Jam")
        countLabel.font = .preferredFont(forTextStyle: .caption1)
        countLabel.textColor = .lightGray
        countLabel.text = L("Connecting…")
        routeLabel.font = .preferredFont(forTextStyle: .caption2)
        routeLabel.textColor = .lightGray
        routeLabel.text = L("Audio output")
        callStateLabel.font = .preferredFont(forTextStyle: .caption2)
        callStateLabel.textColor = .systemOrange
        callStateLabel.isHidden = true
        let identity = UIStackView(arrangedSubviews: [titleLabel, countLabel, routeLabel, callStateLabel])
        identity.axis = .vertical
        identity.spacing = 1
        let header = UIStackView(arrangedSubviews: [identity, participantsButton,
                                                    missedButton, catchUpButton])
        headerView = header
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 4
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)
        header.backgroundColor = UIColor.black.withAlphaComponent(0.64)
        header.layer.cornerRadius = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        notices.translatesAutoresizingMaskIntoConstraints = false
        addSubview(notices)
        speakerLabel.font = .preferredFont(forTextStyle: .subheadline)
        speakerLabel.textColor = .systemGreen
        speakerLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        speakerLabel.layer.cornerRadius = 8
        speakerLabel.clipsToBounds = true
        speakerLabel.isHidden = true
        speakerLabel.isUserInteractionEnabled = false
        speakerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(speakerLabel)
        NSLayoutConstraint.activate([
            participantsButton.widthAnchor.constraint(equalToConstant: 48),
            participantsButton.heightAnchor.constraint(equalToConstant: 48),
            catchUpButton.widthAnchor.constraint(equalToConstant: 48),
            catchUpButton.heightAnchor.constraint(equalToConstant: 48), missedWidth, missedHeight
        ])
        installPresentation()
        self.activeSpeaker.$current.sink { [weak self] speaker in
            guard let self else { return }
            let hidden = self.speakerLabel.isHidden
            self.speakerLabel.text = speaker.map { L("  Speaking: %@  ", $0.title) }
            self.speakerLabel.isHidden = speaker == nil
            self.compactHeader.setSpeaker(speaker)
            self.speakingParticipant = speaker?.id
            self.updateParticipantsPanel()
            if !self.focus.hidden && self.compactHeader.isHidden && hidden != self.speakerLabel.isHidden {
                self.surface.setNeedsLayout()
            }
        }.store(in: &subscriptions)

        catchUp.$timeline.receive(on: DispatchQueue.main).sink { [weak self] timeline in
            guard let self else { return }
            self.missedCount = timeline.unreadCount
            self.updateChatBadge()
        }.store(in: &subscriptions)
        chat.$unreadCount.receive(on: DispatchQueue.main).sink { [weak self] count in
            guard let self else { return }
            self.unreadChatCount = count
            self.updateChatBadge()
        }.store(in: &subscriptions)

        guard let state else { return }
        state.$microphoneState.receive(on: DispatchQueue.main).sink { [weak self] media in
            guard let self else { return }
            #if DEBUG
            print("Microphone state changed: \(media)")
            #endif
            self.microphone.configuration?.image = UIImage(systemName: media == .on ? "mic.fill" : "mic.slash.fill")
            self.microphone.configuration?.title = L("Mic")
            self.microphone.configuration?.baseForegroundColor = media == .on ?
                UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1) : .white
            self.microphone.isEnabled = media != .disabled
            self.microphone.accessibilityLabel = media == .on ? L("Mute microphone") : L("Unmute microphone")
            self.microphone.largeContentTitle = self.microphone.accessibilityLabel
            self.workspace.microphoneOn = media == .on
            self.studio?.microphoneOn = media == .on
        }.store(in: &subscriptions)
        state.$cameraState.receive(on: DispatchQueue.main).sink { [weak self] media in
            guard let self else { return }
            #if DEBUG
            print("Camera state changed: \(media)")
            #endif
            self.sdkCameraOn = media == .on
            self.sdkCameraAvailable = media != .disabled
            self.studio?.cameraOn = media == .on
            self.renderCameraControl()
            self.configureMoreMenu(coordinator: coordinator, onChange: onDisplayMode)
        }.store(in: &subscriptions)
        state.$screenShareState.receive(on: DispatchQueue.main).sink { [weak self] media in
            guard let self else { return }
            let isSharing = media == .on
            if isSharing { self.localPreview.begin() } else { self.localPreview.end() }
            self.share.configuration?.image = UIImage(systemName: isSharing ? "rectangle.slash" : "rectangle.on.rectangle")
            self.share.configuration?.title = L("Share")
            self.share.configuration?.baseForegroundColor = isSharing ?
                UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1) : .white
            self.share.isEnabled = media != .disabled
            self.share.accessibilityLabel = isSharing ? L("Stop sharing screen") : L("Share screen")
            self.share.largeContentTitle = self.share.accessibilityLabel
        }.store(in: &subscriptions)
        Publishers.CombineLatest(state.$localParticipant, state.$remoteParticipants)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] local, remote in
                guard let self else { return }
                let hasShare = local.screenSharing.isOn ||
                    remote.values.contains { $0.screenSharing.isOn }
                let hasVideo = remote.values.contains { $0.camera.isOn }
                let availabilityChanged = self.hasScreenShare != hasShare || self.hasVideo != hasVideo
                self.hasScreenShare = hasShare
                self.hasVideo = hasVideo
                if availabilityChanged {
                    self.configureMoreMenu(coordinator: coordinator, onChange: onDisplayMode)
                }
                self.setWaitingForOthers(remote.isEmpty && !local.camera.isOn &&
                    !local.screenSharing.isOn)
                self.participantsButton.accessibilityLabel = L("Musicians, %ld", remote.count + 1)
                let identifier = self.workspace.roomIdentifier.map { " · \($0)" } ?? ""
                self.countLabel.text = remote.isEmpty ? L("Waiting for others%@", identifier) :
                    L("%ld participants", remote.count + 1) + identifier
                self.participantsButton.accessibilityValue = remote.values.contains { $0.screenSharing.isOn }
                    ? L("A screen is being shared") : nil
                if self.usesNativeParticipants {
                    self.updateParticipantRoster(([local] + Array(remote.values)).map {
                        GuestStreamViews.Participant(id: $0.id, name: $0.userName ?? L("Musician"),
                            isLocal: $0.isLocal, microphoneOn: $0.microphone.isOn,
                            cameraOn: $0.camera.isOn, sharing: $0.screenSharing.isOn)
                    }, speaking: self.activeSpeaker.current?.id)
                }
                self.surface.setNeedsLayout()
            }.store(in: &subscriptions)
        state.$conferenceTitle.receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                self?.titleLabel.text = title.isEmpty ? L("Jam") : title
                self?.surface.setNeedsLayout()
            }
            .store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { nil }

    func setStagePresentation(_ presentation: GuestStreamViews.Presentation,
                              pinnedParticipant: GuestStreamViews.PinTarget? = nil) {
        self.pinnedParticipant = pinnedParticipant
        updateParticipantsPanel()
        guard lastPresentation != presentation else { return }
        lastPresentation = presentation
        let id = presentation.target?.participant, name = presentation.name
        let isShare = presentation.target?.isShare == true
        let active = presentation.active, automatic = presentation.automatic
        let microphoneOn = presentation.microphoneOn
        navigationCount = presentation.count
        automaticView.isHidden = !presentation.browsing
        let changed = stageID != id || stageIsShare != isShare
        if stageActive && !active {
            stageVideo.clear()
            stageHasFrame = false
        }
        if changed { stageHasFrame = false }
        stageID = id
        stageName = name
        stageIsShare = isShare
        stageActive = active
        stagePinned = !automatic
        surface.backgroundColor = .black
        surface.accessibilityIdentifier = "Meeting stage"
        updateDisplayBackdrops()
        stageStatus.text = active ? L("Waiting for %@'s %@…", name ?? L("Musician"), isShare ? L("screen share") : L("video")) :
            L("%@ · %@ unavailable · Pinned", name ?? L("Musician"), isShare ? L("Screen share") : L("Camera"))
        stageStatus.isHidden = !active || stageHasFrame
        if changed {
            stageVideo.clear()
            stageViewport?.removeFromSuperview()
            stageViewport = nil
            if name != nil {
                let viewport = StreamViewport(video: stageVideo, state: StreamViewportState(),
                    zoomable: isShare, name: name ?? L("Musician"), showInfo: true,
                    microphoneOn: microphoneOn, pinned: !automatic, watermark: presentation.watermark)
                viewport.updatePin(name: name ?? L("Musician"), isShare: isShare,
                                   pinned: !automatic, onPin: { [weak self] in self?.onPinStage?() })
                viewport.translatesAutoresizingMaskIntoConstraints = false
                stageView.insertSubview(viewport, at: 0)
                NSLayoutConstraint.activate([
                    viewport.leadingAnchor.constraint(equalTo: stageView.leadingAnchor),
                    viewport.trailingAnchor.constraint(equalTo: stageView.trailingAnchor),
                    viewport.topAnchor.constraint(equalTo: stageView.topAnchor),
                    viewport.bottomAnchor.constraint(equalTo: stageView.bottomAnchor)
                ])
                viewport.onBrowse = { [weak self] step in self?.onBrowse?(step) }
                viewport.onMenuVisibilityChanged = { [weak self] in self?.focus.menuVisible = $0 }
                viewport.onToggleControls = { [weak self] in self?.toggleControls() }
                stageViewport = viewport
            }
        }
        stageViewport?.updatePresentation(name: name ?? L("Musician"), showInfo: true,
            microphoneOn: microphoneOn, pinned: !automatic, watermark: presentation.watermark, zoomable: isShare,
            placeholderText: active ? nil : "\(name ?? L("Musician")) · \(L("Camera off"))")
        stageViewport?.updatePin(name: name ?? L("Musician"), isShare: isShare,
            pinned: !automatic, onPin: { [weak self] in self?.onPinStage?() })
        stageViewport?.setMediaActive(active)
        layoutPresentation()
    }

    func showStageFrame(_ sample: CMSampleBuffer, rotation: Int) {
        guard stageName != nil, stageActive, !stageView.isHidden else { return }
        if stageVideo.enqueue(sample, rotation: rotation) {
            stageHasFrame = true
            stageStatus.isHidden = true
        }
    }

    func setWaitingForOthers(_ waiting: Bool) {
        isWaitingForOthers = waiting
        updateDisplayBackdrops()
        surface.setNeedsLayout()
    }

    func setShareOffer(name: String?) {
        shareOffer.isHidden = name == nil || stageView.isHidden
        shareOffer.configuration?.title = name.map { L("%@ is sharing · View", $0) }
        shareOffer.accessibilityLabel = name.map { L("View %@ screen share", $0) }
    }

    private func openConversation(catchUp: CatchUpStore, chat: ChatStore,
                                  selected: ConversationMode) {
        var responder: UIResponder? = self
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard let presenter = responder as? UIViewController,
              presenter.presentedViewController == nil else { return }
        presenter.present(ConversationPanelViewController(catchUp: catchUp, chat: chat,
                                                           initialMode: selected, call: workspace),
                          animated: true)
    }

    func updateParticipantRoster(_ roster: [GuestStreamViews.Participant], speaking: String?) {
        participantRoster = roster.sorted {
            if $0.isLocal != $1.isLocal { return $0.isLocal }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        speakingParticipant = speaking
        updateParticipantsPanel()
    }

    private func openParticipantsPanel() {
        guard let presenter = presentationContainer, presenter.presentedViewController == nil else { return }
        let panel = ParticipantPanelViewController()
        panel.onPin = { [weak self] key in
            guard let self, self.window != nil else { return }
            self.onPinParticipant?(key.flatMap { self.participantPinTargets[$0] })
        }
        participantsPanel = panel
        updateParticipantsPanel()
        let navigation = UINavigationController(rootViewController: panel)
        // A popover anchors to the visible controls even when the SDK controller's bounds are zero.
        // A sheet uses that controller's viewport and can become invisible in the Mac runtime.
        navigation.modalPresentationStyle = .popover
        navigation.preferredContentSize = CGSize(width: 440, height: 520)
        let anchor = compactHeader.isHidden ? participantsButton : compactHeader.participants
        navigation.popoverPresentationController?.sourceView = anchor
        navigation.popoverPresentationController?.sourceRect = anchor.bounds
        presenter.present(navigation, animated: true)
    }

    private func updateParticipantsPanel() {
        guard let panel = participantsPanel else { return }
        func key(_ target: GuestStreamViews.PinTarget) -> String {
            (target.isShare ? "share:" : "video:") + target.participant
        }
        participantPinTargets.removeAll(keepingCapacity: true)
        let statuses = participantRoster.map { participant in
            let video = GuestStreamViews.PinTarget(participant: participant.id, isShare: false)
            let share = GuestStreamViews.PinTarget(participant: participant.id, isShare: true)
            let videoKey = (participant.cameraOn && displayMode == .all || pinnedParticipant == video) ? key(video) : nil
            let shareKey = (!participant.isLocal && participant.sharing && displayMode != .audioOnly || pinnedParticipant == share) ? key(share) : nil
            if let videoKey { participantPinTargets[videoKey] = video }
            if let shareKey { participantPinTargets[shareKey] = share }
            return ParticipantStatus(id: participant.id, name: participant.name, isLocal: participant.isLocal,
                microphoneOn: participant.microphoneOn, cameraOn: participant.cameraOn,
                screenShareOn: participant.sharing,
                isSpeaking: participant.microphoneOn && speakingParticipant == participant.id,
                videoKey: videoKey, shareKey: shareKey)
        }
        panel.update(statuses, pinnedKey: pinnedParticipant.map(key))
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // The SDK's video renderer sits behind this full-screen controls view.
        // Passing empty space through lets its own screen-share scroll view
        // receive pinch and pan gestures without changing the video renderer.
        if hit === self { return nil }
        return hit
    }

    func showNotices(_ items: [InCallNotice]) {
        notices.show(items)
        if !items.isEmpty { focus.show() }
        layoutPresentation()
    }

    func setHeld(_ held: Bool) {
        studio?.held = held
        isHeld = held
        renderCameraControl()
        if held { focus.show() }
        workspace.onHold = held
        refreshMoreMenu?()
        renderCallStatus()
    }

    private func renderCameraControl() {
        let presenter = studio?.presenter
        let usesPresenter = presenter?.running == true
        let on = sdkCameraOn || (usesPresenter && presenter?.includeCamera == true)
        cameraOn = on; workspace.cameraOn = on
        camera.isEnabled = !isHeld && (sdkCameraAvailable || usesPresenter)
        camera.configuration?.image = UIImage(systemName: on ? "video.fill" : "video.slash.fill")
        camera.configuration?.title = L("Video")
        camera.configuration?.baseForegroundColor = on ? UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1) : .white
        camera.accessibilityLabel = on ? L("Stop video") : L("Start video")
        camera.accessibilityValue = usesPresenter ? L("Camera in Presenter") : nil
        camera.largeContentTitle = camera.accessibilityLabel
    }

    func setFloatingVideoAvailable(_ available: Bool) {
        guard floatingVideoAvailable != available else { return }
        floatingVideoAvailable = available
        moreButton.accessibilityValue = available ? L("Floating video available") : nil
        refreshMoreMenu?()
    }

    func showMediaStatus(_ message: String?) {
        mediaStatus = message
        if message != nil { focus.show() }
        renderCallStatus()
    }

    func setAudioRouteName(_ name: String) {
        routeLabel.text = L("Audio · %@", name)
        workspace.routeName = name
        route.accessibilityValue = name
    }

    private func renderCallStatus() {
        callStateLabel.text = isHeld ? L("On hold · audio resumes after your call") : mediaStatus
        callStateLabel.isHidden = callStateLabel.text == nil
        surface.setNeedsLayout()
    }

    private func updateChatBadge() {
        catchUpButton.configuration?.title = unreadChatCount > 0 ? "\(unreadChatCount)" : nil
        missedButton.isHidden = missedCount == 0
        missedButton.configuration?.title = missedCount > 0 ? "\(missedCount)" : nil
        missedButton.accessibilityLabel = L("Catch up, %ld missed sections", missedCount)
        catchUpButton.accessibilityLabel = unreadChatCount > 0 ?
            L("Chat, %ld unread", unreadChatCount) : L("Chat")
        surface.setNeedsLayout()
    }

    deinit { surface.removeFromSuperview() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            participantsPanel?.dismiss(animated: false)
            participantsPanel = nil
            CallStageLayout.remove(window: mountedWindow, owner: layoutOwner)
            surface.removeFromSuperview()
            mountedWindow = nil
            focus.invalidate()
            return
        }
        guard let window, let host = presentationContainer?.view else { return }
        if surface.superview !== host {
            CallStageLayout.remove(window: mountedWindow, owner: layoutOwner)
            mountedWindow = window
            surface.removeFromSuperview()
            host.addSubview(surface)
            surface.frame = host.convert(window.bounds, from: window)
        }
        layoutPresentation()
        becomeFirstResponder()
        focus.interaction()
    }

    override func layoutSubviews() { super.layoutSubviews(); layoutPresentation() }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); layoutPresentation() }

    private func installPresentation() {
        NSLayoutConstraint.deactivate(constraints)
        for child in subviews {
            NSLayoutConstraint.deactivate(child.constraints.filter { $0.firstItem === child && $0.secondItem == nil })
            child.removeFromSuperview()
            child.translatesAutoresizingMaskIntoConstraints = true
            surface.addSubview(child)
        }
        if let identity = headerView?.arrangedSubviews.first as? UIStackView {
            speakerLabel.removeFromSuperview()
            identity.addArrangedSubview(speakerLabel)
        }
        localShareCard.translatesAutoresizingMaskIntoConstraints = true
        surface.addSubview(localShareCard)
        surface.onLayout = { [weak self] in self?.layoutPresentation() }
        focus.onChange = { [weak self] _ in self?.layoutPresentation() }
        focus.canHide = { [weak self] in
            guard let self else { return false }
            return !self.isHeld && self.mediaStatus == nil && self.notices.subviews.isEmpty &&
                self.presentationContainer?.presentedViewController == nil
        }
        focusButton.configuration = .tinted()
        focusButton.configuration?.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
        focusButton.accessibilityLabel = L("Hide controls")
        focusButton.addAction(UIAction { [weak self] _ in self?.focus.hide() }, for: .touchUpInside)
        for button in [previous, nextStream, automaticView] { button.configuration = .tinted() }
        previous.configuration?.image = UIImage(systemName: "chevron.left")
        previous.accessibilityLabel = L("Previous stream")
        nextStream.configuration?.image = UIImage(systemName: "chevron.right")
        nextStream.accessibilityLabel = L("Next stream")
        automaticView.configuration?.title = L("Auto")
        automaticView.accessibilityLabel = L("Automatic view")
        previous.addAction(UIAction { [weak self] _ in self?.onBrowse?(-1); self?.focus.interaction() }, for: .touchUpInside)
        nextStream.addAction(UIAction { [weak self] _ in self?.onBrowse?(1); self?.focus.interaction() }, for: .touchUpInside)
        automaticView.addAction(UIAction { [weak self] _ in self?.onAutomaticView?(); self?.focus.interaction() }, for: .touchUpInside)
        navigation.axis = .horizontal; navigation.spacing = 4; navigation.distribution = .fillEqually
        [previous, automaticView, nextStream].forEach { navigation.addArrangedSubview($0) }
        [focusButton, navigation, compactHeader].forEach(surface.addSubview)
        focus.installHint(in: surface)
        for backdrop in [audioOnlyBackdrop, screenSharesBackdrop, waitingBackdrop] {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tappedBackdrop))
            tap.delegate = self
            backdrop.addGestureRecognizer(tap)
            backdrop.accessibilityLabel = L("Meeting content")
        }
        for (button, action) in [
            (compactHeader.previous, previous), (compactHeader.nextStream, nextStream),
            (compactHeader.automatic, automaticView), (compactHeader.participants, participantsButton),
            (compactHeader.missed, missedButton),
            (compactHeader.conversation, catchUpButton), (compactHeader.focus, focusButton)
        ] {
            button.addAction(UIAction { [weak action] _ in action?.sendActions(for: .touchUpInside) }, for: .touchUpInside)
        }
        compactHeader.pin.addAction(UIAction { [weak self] _ in self?.onPinStage?(); self?.focus.interaction() }, for: .touchUpInside)
        compactHeader.details.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.workspace.showDetails(from: self.compactHeader.details, presenter: self.presentationContainer,
                title: self.titleLabel.text ?? L("Jam"),
                lines: [self.countLabel.text, self.routeLabel.text,
                        self.callStateLabel.isHidden ? nil : self.callStateLabel.text,
                        self.speakerLabel.isHidden ? nil : self.speakerLabel.text].compactMap { $0 })
        }, for: .touchUpInside)
        moreButton.onMenuVisibilityChanged = { [weak self] in self?.focus.menuVisible = $0 }
    }

    private var presenter: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    private var presentationContainer: UIViewController? {
        guard var controller = presenter else { return nil }
        // The custom SDK overlay can have a zero-sized hosting controller.
        // Its enclosing meeting controller owns the visible viewport and menus.
        while let parent = controller.parent { controller = parent }
        return controller
    }

    private func toggleControls() {
        focus.toggle()
    }
    @objc private func tappedBackdrop() { toggleControls() }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var target = touch.view
        while let current = target {
            if current is UIControl { return false }
            target = current.superview
        }
        return true
    }

    private func layoutPresentation() {
        guard let window = mountedWindow, let toolbar, let header = headerView else { return }
        if let host = surface.superview { surface.frame = host.convert(window.bounds, from: window) }
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        toolbar.arrange(rail: false, largeText: large)
        let headerHeight = max(58, header.systemLayoutSizeFitting(CGSize(width: min(440, window.bounds.width - 16), height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height)
        let geometry = CallPresentationGeometry(bounds: surface.bounds, insets: window.safeAreaInsets,
            headerHeight: headerHeight, toolbarHeight: toolbar.preferredHeight, hidden: focus.hidden, largeText: large)
        toolbar.arrange(rail: geometry.rail, largeText: large)
        automaticView.configuration?.title = large ? nil : L("Auto")
        automaticView.configuration?.image = large ? UIImage(systemName: "arrow.triangle.2.circlepath") : nil
        header.frame = geometry.header; toolbar.frame = geometry.toolbar
        header.isHidden = focus.hidden || geometry.compactHeader; toolbar.isHidden = focus.hidden
        compactHeader.frame = geometry.header
        compactHeader.isHidden = focus.hidden || !geometry.compactHeader
        let showsStage = !stageView.isHidden
        let pinLabel = showsStage ? stageName.map { "\(stagePinned ? L("Unpin") : L("Pin")) \($0) \(stageIsShare ? L("screen share") : L("video"))" } : nil
        let status = callStateLabel.isHidden ? nil : callStateLabel.text
        compactHeader.update(name: status ?? (showsStage ? (stageName ?? titleLabel.text ?? L("Jam")) + (stageIsShare ? L(" · Screen") : "") : titleLabel.text ?? L("Jam")),
            navigation: navigationCount > 1 && displayMode != .audioOnly && !isWaitingForOthers,
            browsing: lastPresentation?.browsing == true, pinned: stagePinned,
            pinLabel: pinLabel,
            participantsLabel: participantsButton.accessibilityLabel,
            chatValue: unreadChatCount > 0 ? catchUpButton.accessibilityLabel : nil,
            chatCount: unreadChatCount, missedCount: missedCount, status: status,
            speaking: activeSpeaker.current, focusAvailable: showsStage)
        navigation.isHidden = focus.hidden || geometry.compactHeader || navigationCount < 2 || stagePinned || displayMode == .audioOnly || isWaitingForOthers
        var stage = geometry.stage
        if !navigation.isHidden {
            let width: CGFloat = automaticView.isHidden ? 100 : 260
            navigation.frame = CGRect(x: stage.midX - width / 2, y: stage.minY, width: width, height: 44)
            stage.origin.y += 48; stage.size.height = max(0, stage.height - 48)
        }
        for backdrop in [audioOnlyBackdrop, screenSharesBackdrop, waitingBackdrop, stageView] { backdrop.frame = stage }
        for backdrop in [audioOnlyBackdrop, screenSharesBackdrop, waitingBackdrop] {
            backdrop.isAccessibilityElement = focus.hidden
            backdrop.accessibilityCustomActions = focus.hidden ? [focus.restoreAccessibilityAction()] : nil
        }
        notices.frame = CGRect(x: geometry.header.minX, y: geometry.header.maxY + 4,
            width: geometry.header.width, height: notices.systemLayoutSizeFitting(CGSize(width: geometry.header.width, height: 0)).height)
        focusButton.isHidden = focus.hidden || stageView.isHidden || geometry.compactHeader
        focusButton.frame = CGRect(x: stage.minX + 8, y: stage.minY + 8, width: 44, height: 44)
        localShareCard.alpha = focus.hidden ? 0 : 1
        localShareCard.refreshLayout()
        let cardWidth = min(216, stage.width - 8)
        let cardHeight = min(max(0, stage.height - 44), localShareCard.systemLayoutSizeFitting(
            CGSize(width: cardWidth, height: 0), withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height)
        localShareCard.frame = CGRect(x: stage.minX + 4, y: stage.maxY - cardHeight - 44,
            width: cardWidth, height: cardHeight)
        stageViewport?.controlsHidden = focus.hidden
        stageViewport?.pinInHeader = geometry.compactHeader
        CallStageLayout.update(window: window, owner: layoutOwner, rect: surface.convert(stage, to: window), hidden: focus.hidden,
            toggle: { [weak self] in self?.toggleControls() })
    }

    private func configureMoreMenu(coordinator: JazzActiveConferenceCoordinator?,
                                   onChange: @escaping (ConferenceDisplayMode) -> Void) {
        let viewMenu = UIMenu(title: L("View"), children: ConferenceDisplayMode.allCases.map { option in
            UIAction(title: option.title, image: UIImage(systemName: option.symbol),
                     state: option == displayMode ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.displayMode = option
                self.updateDisplayBackdrops()
                self.configureMoreMenu(coordinator: coordinator, onChange: onChange)
                onChange(option)
            }
        })
        let flip = UIAction(title: L("Flip camera"), image: UIImage(systemName: "camera.rotate"),
                            attributes: cameraOn && studio?.presenter.running != true ? [] : [.disabled]) { _ in coordinator?.switchCamera() }
        let fit = UIAction(title: L("Fit shared screen"),
                           image: UIImage(systemName: "arrow.down.right.and.arrow.up.left")) { [weak self] _ in
            self?.fitZoomedContent()
        }
        let float = UIAction(title: L("Show floating video"), image: UIImage(systemName: "pip.enter"),
                             attributes: canFloatVideo ? [] : [.disabled]) { [weak self] _ in
            guard self?.canFloatVideo == true else { return }
            self?.onFloat()
        }
        let automatic = UIAction(title: L("Floating video when multitasking"),
                                 image: UIImage(systemName: "pip"),
                                 state: FloatingVideoPreference.enabled ? .on : .off) { [weak self] _ in
            FloatingVideoPreference.enabled.toggle()
            self?.onFloatingPreferenceChanged()
            self?.configureMoreMenu(coordinator: coordinator, onChange: onChange)
        }
        let focusAction = UIAction(title: L("Hide controls"), image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) {
            [weak self] _ in self?.focus.hide()
        }
        let autoHide = UIAction(title: L("Automatically hide controls"), state: focus.automaticallyHides ? .on : .off) {
            [weak self] _ in guard let self else { return }
            self.focus.automaticallyHides.toggle()
            self.refreshMoreMenu?()
        }
        var actions: [UIMenuElement] = [focusAction, autoHide, float, automatic, viewMenu, fit, flip]
        if workspace.invitationURL != nil {
            actions.insert(UIAction(title: L("Invite musicians"), image: UIImage(systemName: "square.and.arrow.up")) {
                [weak self] _ in guard let self else { return }
                self.workspace.shareInvitation(from: self.moreButton)
            }, at: 0)
            actions.insert(UIAction(title: L("Copy link"), image: UIImage(systemName: "doc.on.doc")) {
                [weak self] _ in self?.workspace.copyInvitation()
            }, at: 1)
        }
        if let studio {
            actions.insert(UIAction(title: L("Presenter"), image: UIImage(systemName: "person.crop.rectangle")) { [weak self] _ in
                guard let self else { return }
                StudioPresentation.show(studio, from: self.moreButton, pane: .presenter)
            }, at: 0)
            actions.insert(UIAction(title: L("Camera & sound"), image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
                guard let self else { return }
                StudioPresentation.show(studio, from: self.moreButton)
            }, at: 0)
        }
        #if DEBUG
        actions = fixtureActions + actions
        #endif
        moreButton.menu = UIMenu(children: actions)
    }

    #if DEBUG
    func setFixtureMedia(camera: Bool? = nil, microphone: Bool? = nil) {
        if let camera {
            cameraOn = camera
            studio?.cameraOn = camera
            workspace.cameraOn = camera
            self.camera.accessibilityLabel = camera ? L("Stop video") : L("Start video")
        }
        if let microphone {
            studio?.microphoneOn = microphone
            workspace.microphoneOn = microphone
            self.microphone.accessibilityLabel = microphone ? L("Mute microphone") : L("Unmute microphone")
        }
    }
    #endif

    private func updateDisplayBackdrops() {
        audioOnlyBackdrop.isHidden = displayMode != .audioOnly
        screenSharesBackdrop.isHidden = displayMode != .screenShares || hasScreenShare
        waitingBackdrop.isHidden = displayMode != .all || !isWaitingForOthers
        stageView.isHidden = stageName == nil || displayMode == .audioOnly || isWaitingForOthers ||
            displayMode == .screenShares && !stageIsShare
        shareOffer.isHidden = shareOffer.configuration?.title == nil || stageView.isHidden
    }

    private func fitZoomedContent() {
        guard let root = window else { return }
        var zoomed: [UIScrollView] = []
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            if let scroll = view as? UIScrollView,
               scroll.maximumZoomScale > 1, scroll.zoomScale > 1.01 {
                zoomed.append(scroll)
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        zoomed.max { $0.zoomScale < $1.zoomScale }?.setZoomScale(1, animated: true)
    }

    private static func button(_ title: String, symbol: String) -> UIButton {
        let button = AlignedCallButton(frame: .zero)
        button.configuration = iconConfiguration(symbol, title: title)
        button.accessibilityLabel = title
        button.showsLargeContentViewer = true
        button.largeContentTitle = title
        button.largeContentImage = UIImage(systemName: symbol)
        return button
    }

    private static func iconConfiguration(_ symbol: String, title: String? = nil) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.title = title
        configuration.imagePlacement = .top
        configuration.imagePadding = 2
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 12, weight: .medium)
            return attributes
        }
        configuration.baseForegroundColor = .white
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 19)
        return configuration
    }
}

struct InCallNotice {
    let title: String
    let actionTitle: String?
    let action: (() -> Void)?
}

final class TopNoticeView: UIStackView {
    init() {
        super.init(frame: .zero)
        axis = .vertical
        spacing = 8
        isHidden = true
        accessibilityIdentifier = "Top meeting notices"
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ items: [InCallNotice]) {
        arrangedSubviews.forEach { view in
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for item in items.suffix(2) {
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 10
            row.isLayoutMarginsRelativeArrangement = true
            row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 14,
                                                                   bottom: 10, trailing: 14)
            row.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.97)
            row.layer.cornerRadius = 14
            row.layer.masksToBounds = true
            let label = UILabel()
            label.text = item.title
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = .label
            label.numberOfLines = 3
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(label)
            if let title = item.actionTitle, let action = item.action {
                let button = UIButton(type: .system)
                button.setTitle(title, for: .normal)
                button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
                button.addAction(UIAction { _ in action() }, for: .touchUpInside)
                row.addArrangedSubview(button)
            }
            addArrangedSubview(row)
        }
        isHidden = arrangedSubviews.isEmpty
    }
}

#if DEBUG
final class NoticeLayoutFixtureViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let notice = TopNoticeView()
        notice.show([InCallNotice(title: L("Meeting transcript is on"), actionTitle: nil, action: nil)])
        notice.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(notice)
        let controls = UIButton(type: .system)
        controls.setTitle("Fixture controls", for: .normal)
        controls.backgroundColor = .secondarySystemBackground
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        NSLayoutConstraint.activate([
            notice.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            notice.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            notice.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            notice.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            notice.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            controls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 6),
            controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -6),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            controls.heightAnchor.constraint(equalToConstant: 54),
        ])
    }
}
#endif
