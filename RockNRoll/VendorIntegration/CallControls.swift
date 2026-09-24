import Combine
import JazzSDK
import UIKit

final class CallControls: UIView {
    private var subscriptions = Set<AnyCancellable>()
    private let microphone = UIButton(type: .system)
    private let camera = UIButton(type: .system)
    private let route = UIView()
    private let catchUpButton = UIButton(type: .system)
    private let missedButton = UIButton(type: .system)
    private let displayButton = UIButton(type: .system)
    private let participantsButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let routeLabel = UILabel()
    private let callStateLabel = UILabel()
    private let speakerLabel = UILabel()
    private let audioOnlyBackdrop = UIView()
    private let screenSharesBackdrop = UIView()
    private let waitingBackdrop = UIView()
    private let notices = TopNoticeView()
    private var barBottomConstraint: NSLayoutConstraint?
    private var barLeadingConstraint: NSLayoutConstraint?
    private var barTrailingConstraint: NSLayoutConstraint?
    private var noticeTopConstraint: NSLayoutConstraint?
    private var headerTopConstraint: NSLayoutConstraint?
    private var headerCenterConstraint: NSLayoutConstraint?
    private var orientationObserver: NSObjectProtocol?
    private var displayMode: ConferenceDisplayMode = .all
    private var hasScreenShare = false
    private var isWaitingForOthers = false
    private var cameraOn = false
    private var isHeld = false
    private var mediaStatus: String?
    private var missedCount = 0
    private var unreadChatCount = 0
    private let workspace = CallWorkspaceControls()

    init(state: JazzActiveConferenceState, coordinator: JazzActiveConferenceCoordinator,
         router: JazzActiveConferenceRouter,
         catchUp: CatchUpStore, chat: ChatStore,
         initialDisplayMode: ConferenceDisplayMode,
         invitationURL: URL?, roomIdentifier: String?,
         onDisplayMode: @escaping (ConferenceDisplayMode) -> Void,
         onLeave: @escaping () -> Void, onMicrophoneState: @escaping (Bool) -> Void,
         onCameraState: @escaping (Bool) -> Void) {
        super.init(frame: .zero)
        workspace.invitationURL = invitationURL
        workspace.roomIdentifier = roomIdentifier
        displayMode = initialDisplayMode
        backgroundColor = .clear
        audioOnlyBackdrop.backgroundColor = .black
        audioOnlyBackdrop.isHidden = initialDisplayMode != .audioOnly
        audioOnlyBackdrop.isUserInteractionEnabled = false
        audioOnlyBackdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(audioOnlyBackdrop)
        let audioOnlyLabel = UILabel()
        audioOnlyLabel.text = "Audio only\nJam audio continues"
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
        noShareLabel.text = "No screen share is live.\nJam audio continues."
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
        waitingLabel.text = "You're connected. Waiting for others."
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
            invite.configuration?.title = "Invite musicians"
            invite.configuration?.image = UIImage(systemName: "square.and.arrow.up")
            invite.tintColor = UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1)
            invite.addAction(UIAction { [weak self] _ in
                self?.workspace.shareInvitation(from: invite)
            }, for: .touchUpInside)
            let copy = UIButton(type: .system)
            copy.configuration = .plain()
            copy.configuration?.title = "Copy link"
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

        let leave = Self.button("Leave", symbol: "phone.down.fill")
        catchUpButton.configuration = Self.iconConfiguration("text.bubble")
        catchUpButton.accessibilityLabel = "Chat"
        missedButton.configuration = Self.iconConfiguration("clock.arrow.circlepath")
        missedButton.accessibilityLabel = "Catch up"
        missedButton.isHidden = true
        displayButton.configuration = Self.iconConfiguration(displayMode.symbol)
        displayButton.accessibilityLabel = "Display: \(displayMode.title)"
        moreButton.configuration = Self.iconConfiguration("ellipsis.circle.fill", title: "More")
        moreButton.accessibilityLabel = "More call options"
        moreButton.showsMenuAsPrimaryAction = true
        participantsButton.configuration = Self.iconConfiguration("person.2.fill")
        participantsButton.accessibilityLabel = "Musicians"
        configureMoreMenu(coordinator: coordinator, onChange: onDisplayMode)
        microphone.configuration = Self.iconConfiguration("mic.slash.fill", title: "Mic off")
        camera.configuration = Self.iconConfiguration("video.slash.fill", title: "Cam off")
        for button in [microphone, camera, catchUpButton, missedButton, moreButton, participantsButton] {
            button.showsLargeContentViewer = true
            button.largeContentTitle = button.accessibilityLabel
            button.largeContentImage = button.configuration?.image
        }
        leave.configuration?.baseForegroundColor = .systemRed

        microphone.addAction(UIAction { _ in
            let turnOn = state.microphoneState != .on
            onMicrophoneState(turnOn)
            coordinator.toggleMicrohone(isOn: turnOn)
        }, for: .touchUpInside)
        camera.addAction(UIAction { _ in
            let turnOn = state.cameraState != .on
            onCameraState(turnOn)
            coordinator.toggleCamera(isOn: turnOn)
        }, for: .touchUpInside)
        leave.addAction(UIAction { _ in onLeave() }, for: .touchUpInside)
        workspace.toggleMicrophone = { [weak self] in self?.microphone.sendActions(for: .touchUpInside) }
        workspace.toggleCamera = { [weak self] in self?.camera.sendActions(for: .touchUpInside) }
        workspace.leave = { leave.sendActions(for: .touchUpInside) }
        catchUpButton.addAction(UIAction { [weak self] _ in
            self?.openConversation(catchUp: catchUp, chat: chat, selected: .chat)
        }, for: .touchUpInside)
        missedButton.addAction(UIAction { [weak self] _ in
            self?.openConversation(catchUp: catchUp, chat: chat, selected: .catchUp)
        }, for: .touchUpInside)
        participantsButton.addAction(UIAction { _ in router.openParticipants() }, for: .touchUpInside)

        route.translatesAutoresizingMaskIntoConstraints = false
        route.accessibilityLabel = "Audio route"
        let picker = coordinator.audioRoutePickerButton
        picker.translatesAutoresizingMaskIntoConstraints = false
        route.addSubview(picker)
        let routeIcon = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill"))
        routeIcon.tintColor = UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1)
        routeIcon.isUserInteractionEnabled = false
        routeIcon.translatesAutoresizingMaskIntoConstraints = false
        route.addSubview(routeIcon)
        let routeTitle = UILabel()
        routeTitle.text = "Audio"
        routeTitle.textColor = .white
        routeTitle.font = .preferredFont(forTextStyle: .caption2)
        routeTitle.isUserInteractionEnabled = false
        routeTitle.translatesAutoresizingMaskIntoConstraints = false
        route.addSubview(routeTitle)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: route.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: route.trailingAnchor),
            picker.topAnchor.constraint(equalTo: route.topAnchor),
            picker.bottomAnchor.constraint(equalTo: route.bottomAnchor),
            routeIcon.centerXAnchor.constraint(equalTo: route.centerXAnchor),
            routeIcon.centerYAnchor.constraint(equalTo: route.centerYAnchor, constant: -7),
            routeIcon.widthAnchor.constraint(equalToConstant: 25),
            routeIcon.heightAnchor.constraint(equalToConstant: 25),
            routeTitle.centerXAnchor.constraint(equalTo: route.centerXAnchor),
            routeTitle.bottomAnchor.constraint(equalTo: route.bottomAnchor, constant: -4),
        ])

        let bar = UIStackView(arrangedSubviews: [microphone, camera, route, moreButton, leave])
        bar.axis = .horizontal
        bar.distribution = .fillEqually
        bar.alignment = .fill
        bar.spacing = 4
        bar.backgroundColor = UIColor(red: 0.12, green: 0.14, blue: 0.21, alpha: 0.96)
        bar.layer.cornerRadius = 16
        bar.isLayoutMarginsRelativeArrangement = true
        bar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.text = "Jam"
        countLabel.font = .preferredFont(forTextStyle: .caption1)
        countLabel.textColor = .lightGray
        countLabel.text = "Connecting…"
        routeLabel.font = .preferredFont(forTextStyle: .caption2)
        routeLabel.textColor = .lightGray
        routeLabel.text = "Audio output"
        callStateLabel.font = .preferredFont(forTextStyle: .caption2)
        callStateLabel.textColor = .systemOrange
        callStateLabel.isHidden = true
        let identity = UIStackView(arrangedSubviews: [titleLabel, countLabel, routeLabel, callStateLabel])
        identity.axis = .vertical
        identity.spacing = 1
        let header = UIStackView(arrangedSubviews: [identity, participantsButton,
                                                    missedButton, catchUpButton])
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
        let bottom = bar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -4)
        let leading = bar.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 6)
        let trailing = bar.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -6)
        barBottomConstraint = bottom
        barLeadingConstraint = leading
        barTrailingConstraint = trailing
        let noticeTop = notices.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6)
        noticeTopConstraint = noticeTop
        let headerTop = header.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 4)
        let headerCenter = header.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor)
        headerTopConstraint = headerTop
        headerCenterConstraint = headerCenter
        NSLayoutConstraint.activate([
            leading, trailing,
            bottom,
            bar.heightAnchor.constraint(equalToConstant: 62),
            bar.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            bar.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            microphone.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            camera.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            route.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            moreButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            leave.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            headerTop,
            header.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            headerCenter,
            header.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            participantsButton.widthAnchor.constraint(equalToConstant: 48),
            participantsButton.heightAnchor.constraint(equalToConstant: 48),
            catchUpButton.widthAnchor.constraint(equalToConstant: 48),
            catchUpButton.heightAnchor.constraint(equalToConstant: 48),
            missedWidth, missedHeight,
            noticeTop,
            notices.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            notices.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            notices.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            notices.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            speakerLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            speakerLabel.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -7),
            speakerLabel.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -8),
        ])
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.alignBarWithVisibleWindow() }
        }

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

        state.$microphoneState.receive(on: DispatchQueue.main).sink { [weak self] media in
            guard let self else { return }
            #if DEBUG
            print("Microphone state changed: \(media)")
            #endif
            self.microphone.configuration?.image = UIImage(systemName: media == .on ? "mic.fill" : "mic.slash.fill")
            self.microphone.configuration?.title = media == .on ? "Mic on" : "Mic off"
            self.microphone.configuration?.baseForegroundColor = media == .on ?
                UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1) : .white
            self.microphone.isEnabled = media != .disabled
            self.microphone.accessibilityLabel = media == .on ? "Mute microphone" : "Unmute microphone"
            self.microphone.largeContentTitle = self.microphone.accessibilityLabel
            self.workspace.microphoneOn = media == .on
        }.store(in: &subscriptions)
        state.$cameraState.receive(on: DispatchQueue.main).sink { [weak self] media in
            guard let self else { return }
            #if DEBUG
            print("Camera state changed: \(media)")
            #endif
            self.camera.configuration?.image = UIImage(systemName: media == .on ? "video.fill" : "video.slash.fill")
            self.camera.configuration?.title = media == .on ? "Cam on" : "Cam off"
            self.camera.configuration?.baseForegroundColor = media == .on ?
                UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1) : .white
            self.camera.isEnabled = media != .disabled
            self.cameraOn = media == .on
            self.configureMoreMenu(coordinator: coordinator, onChange: onDisplayMode)
            self.camera.accessibilityLabel = media == .on ? "Stop video" : "Start video"
            self.camera.largeContentTitle = self.camera.accessibilityLabel
            self.workspace.cameraOn = media == .on
        }.store(in: &subscriptions)
        Publishers.CombineLatest3(state.$localParticipant, state.$remoteParticipants,
                                  state.$dominantSpeaker)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] local, remote, speaker in
                guard let self else { return }
                self.hasScreenShare = local.screenSharing.isOn ||
                    remote.values.contains { $0.screenSharing.isOn }
                self.isWaitingForOthers = remote.isEmpty && !local.camera.isOn &&
                    !local.screenSharing.isOn
                self.updateDisplayBackdrops()
                self.participantsButton.accessibilityLabel = "Musicians, \(remote.count + 1)"
                let identifier = self.workspace.roomIdentifier.map { " · \($0)" } ?? ""
                self.countLabel.text = remote.isEmpty ? "Waiting for others\(identifier)" :
                    "\(remote.count + 1) participants\(identifier)"
                self.participantsButton.accessibilityValue = remote.values.contains { $0.screenSharing.isOn }
                    ? "A screen is being shared" : nil
                if let speaker, speaker.microphone.isOn {
                    self.speakerLabel.text = "  Speaking: \(speaker.isLocal ? "You" : (speaker.userName ?? "Musician"))  "
                    self.speakerLabel.isHidden = false
                } else {
                    self.speakerLabel.isHidden = true
                }
            }.store(in: &subscriptions)
        state.$conferenceTitle.receive(on: DispatchQueue.main)
            .sink { [weak self] title in self?.titleLabel.text = title.isEmpty ? "Jam" : title }
            .store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { nil }

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
    }

    func setHeld(_ held: Bool) {
        isHeld = held
        workspace.onHold = held
        renderCallStatus()
    }

    func showMediaStatus(_ message: String?) {
        mediaStatus = message
        renderCallStatus()
    }

    func setAudioRouteName(_ name: String) {
        routeLabel.text = "Audio · \(name)"
        workspace.routeName = name
        route.accessibilityValue = name
    }

    private func renderCallStatus() {
        callStateLabel.text = isHeld ? "On hold · audio resumes after your call" : mediaStatus
        callStateLabel.isHidden = callStateLabel.text == nil
    }

    private func updateChatBadge() {
        catchUpButton.configuration?.title = unreadChatCount > 0 ? "\(unreadChatCount)" : nil
        missedButton.isHidden = missedCount == 0
        missedButton.configuration?.title = missedCount > 0 ? "\(missedCount)" : nil
        missedButton.accessibilityLabel = "Catch up, \(missedCount) missed " +
            (missedCount == 1 ? "section" : "sections")
        let unread = unreadChatCount > 0 ? ", \(unreadChatCount) unread" : ""
        catchUpButton.accessibilityLabel = "Chat\(unread)"
    }

    deinit {
        if let orientationObserver { NotificationCenter.default.removeObserver(orientationObserver) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        alignBarWithVisibleWindow()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        alignBarWithVisibleWindow()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        alignBarWithVisibleWindow()
    }

    private func alignBarWithVisibleWindow() {
        guard let window, let barBottomConstraint,
              let barLeadingConstraint, let barTrailingConstraint else { return }
        let visibleLeft = convert(CGPoint(x: window.safeAreaInsets.left, y: 0), from: window).x
        let visibleRight = convert(CGPoint(x: window.bounds.maxX - window.safeAreaInsets.right, y: 0), from: window).x
        let ownSafeLeft = safeAreaInsets.left
        let ownSafeRight = bounds.maxX - safeAreaInsets.right
        let leading = max(6, visibleLeft - ownSafeLeft + 6)
        let trailing = min(-6, visibleRight - ownSafeRight - 6)
        if abs(barLeadingConstraint.constant - leading) > 0.5 { barLeadingConstraint.constant = leading }
        if abs(barTrailingConstraint.constant - trailing) > 0.5 { barTrailingConstraint.constant = trailing }
        let visibleBottom = convert(
            CGPoint(x: 0, y: window.bounds.maxY - window.safeAreaInsets.bottom), from: window
        ).y
        let ownSafeBottom = bounds.maxY - safeAreaInsets.bottom
        let constant = min(-4, visibleBottom - ownSafeBottom - 4)
        if abs(barBottomConstraint.constant - constant) > 0.5 {
            barBottomConstraint.constant = constant
        }
        if let noticeTopConstraint {
            let visibleTop = convert(CGPoint(x: 0, y: window.safeAreaInsets.top), from: window).y
            if let headerTopConstraint {
                let constant = max(4, visibleTop - safeAreaInsets.top + 4)
                if abs(headerTopConstraint.constant - constant) > 0.5 {
                    headerTopConstraint.constant = constant
                }
            }
            if let headerCenterConstraint {
                let windowMidX = (window.bounds.minX + window.bounds.maxX) / 2
                let visibleMidX = convert(CGPoint(x: windowMidX, y: 0), from: window).x
                let ownMidX = (safeAreaLayoutGuide.layoutFrame.minX + safeAreaLayoutGuide.layoutFrame.maxX) / 2
                let constant = visibleMidX - ownMidX
                if abs(headerCenterConstraint.constant - constant) > 0.5 {
                    headerCenterConstraint.constant = constant
                }
            }
            if noticeTopConstraint.constant != 6 { noticeTopConstraint.constant = 6 }
        }
    }

    private func configureMoreMenu(coordinator: JazzActiveConferenceCoordinator,
                                   onChange: @escaping (ConferenceDisplayMode) -> Void) {
        let viewMenu = UIMenu(title: "View", children: ConferenceDisplayMode.allCases.map { option in
            UIAction(title: option.title, image: UIImage(systemName: option.symbol),
                     state: option == displayMode ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.displayMode = option
                self.updateDisplayBackdrops()
                self.configureMoreMenu(coordinator: coordinator, onChange: onChange)
                onChange(option)
            }
        })
        let flip = UIAction(title: "Flip camera", image: UIImage(systemName: "camera.rotate"),
                            attributes: cameraOn ? [] : [.disabled]) { _ in coordinator.switchCamera() }
        let fit = UIAction(title: "Fit shared screen",
                           image: UIImage(systemName: "arrow.down.right.and.arrow.up.left")) { [weak self] _ in
            self?.fitZoomedContent()
        }
        var actions: [UIMenuElement] = [viewMenu, fit, flip]
        if workspace.invitationURL != nil {
            actions.insert(UIAction(title: "Invite musicians", image: UIImage(systemName: "square.and.arrow.up")) {
                [weak self] _ in guard let self else { return }
                self.workspace.shareInvitation(from: self.moreButton)
            }, at: 0)
            actions.insert(UIAction(title: "Copy link", image: UIImage(systemName: "doc.on.doc")) {
                [weak self] _ in self?.workspace.copyInvitation()
            }, at: 1)
        }
        moreButton.menu = UIMenu(children: actions)
    }

    private func updateDisplayBackdrops() {
        audioOnlyBackdrop.isHidden = displayMode != .audioOnly
        screenSharesBackdrop.isHidden = displayMode != .screenShares || hasScreenShare
        waitingBackdrop.isHidden = displayMode != .all || !isWaitingForOthers
    }

    private func fitZoomedContent() {
        guard let root = window?.rootViewController?.view else { return }
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
        let button = UIButton(type: .system)
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
        configuration.baseForegroundColor = UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1)
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
        notice.show([InCallNotice(title: "Meeting transcript is on", actionTitle: nil, action: nil)])
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
