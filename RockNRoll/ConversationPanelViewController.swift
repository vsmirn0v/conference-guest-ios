import AVKit
import Combine
import ConferenceCore
import SwiftUI
import UIKit

enum ConversationMode: Int {
    case chat, liveText, catchUp
}

enum ConversationActivityFilter: CaseIterable {
    case all, messages, reactions
    var title: String {
        switch self { case .all: L("All activity"); case .messages: L("Messages"); case .reactions: L("Reactions") }
    }
}

@MainActor
final class ConversationPanelViewController: UIViewController, UITextViewDelegate {
    private let catchUp: CatchUpStore
    private let chat: ChatStore
    private let activityFilterButton = UIButton(type: .system)
    private var activityFilter: ConversationActivityFilter
    private var reactionViews: [String: ReactionHistoryRowView] = [:]
    private var renderedReactionIDs = [String]()
    private var renderingMessages = false
    private var panelVisible = false
    private let call: CallWorkspaceControls?
    private var subscriptions = Set<AnyCancellable>()

    private let dark = UIColor(red: 0.07, green: 0.09, blue: 0.15, alpha: 1)
    private let card = UIColor(red: 0.11, green: 0.13, blue: 0.20, alpha: 1)
    private let accent = UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1)
    private let panel = UIView()
    private var panelLeading: NSLayoutConstraint!
    private var panelSideWidth: NSLayoutConstraint!
    private var isSidePanel = false
    private let header = UIStackView()
    private let mode = UISegmentedControl(items: [L("Chat"), L("Live text"), L("Catch up")])
    private let messageList = UIScrollView()
    private let messageRows = UIStackView()
    private let transcript = UITextView()
    private let content = UIView()
    private let composer = UITextView()
    private let placeholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private let hint = UILabel()
    private let footer = UIStackView()
    private let composerRow = UIStackView()
    private let callStrip = UIStackView()
    private let micButton = UIButton(type: .system)
    private let cameraButton = UIButton(type: .system)
    private let speakerButton = UIButton(type: .system)
    private let leaveButton = UIButton(type: .system)
    private let newMessagesButton = UIButton(type: .system)
    private let followButton = UIButton(type: .system)
    private var composerHeight: NSLayoutConstraint!
    private var catchUpHost: UIHostingController<CatchUpCardsView>!
    private var timeline = CatchUpTimeline()
    private var renderedTranscriptSegments: [TranscriptSegment]?
    private var canViewTranscript: Bool?
    private var transcriptionEnabled = false
    private var lastMessageIDs = [String]()
    private var messageViews: [String: (entry: ChatEntry, view: UIView)] = [:]
    private var retryButtons: [String: UIButton] = [:]
    private var hasNewMessages = false
    private var isRenderingTranscript = false
    private var isCompactForKeyboard = false
    private var keyboardPresented = false
    private let docked: Bool
    var onClose: (() -> Void)?

    init(catchUp: CatchUpStore, chat: ChatStore,
         initialMode: ConversationMode = .chat, call: CallWorkspaceControls? = nil,
         docked: Bool = false, chatAvailable: Bool = true, initialFilter: ConversationActivityFilter = .all) {
        self.catchUp = catchUp
        self.chat = chat
        self.activityFilter = initialFilter
        self.call = call
        self.docked = docked
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        let canViewChat = chatAvailable || chat.reactionHistoryAvailable
        mode.setEnabled(canViewChat, forSegmentAt: ConversationMode.chat.rawValue)
        mode.selectedSegmentIndex = (!canViewChat && initialMode == .chat ? ConversationMode.catchUp : initialMode).rawValue
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        if docked {
            view = UIView()
            return
        }
        let overlay = ConversationOverlayView()
        overlay.panel = panel
        view = overlay
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .clear
        view.tintColor = accent
        panel.backgroundColor = dark
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        panelLeading = panel.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        panelSideWidth = panel.widthAnchor.constraint(equalToConstant: 380)
        NSLayoutConstraint.activate([
            panelLeading,
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        buildHeader()
        buildContent()
        buildFooter()
        buildCallStrip()

        let column = UIStackView(arrangedSubviews: [header, mode, activityFilterButton, content, footer, callStrip])
        column.axis = .vertical
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: panel.safeAreaLayoutGuide.topAnchor, constant: 5),
            column.leadingAnchor.constraint(equalTo: panel.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: panel.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            column.bottomAnchor.constraint(equalTo: panel.keyboardLayoutGuide.topAnchor, constant: -5),
            header.heightAnchor.constraint(equalToConstant: 44),
            mode.heightAnchor.constraint(equalToConstant: 38),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).withPriority(.defaultHigh),
            callStrip.heightAnchor.constraint(equalToConstant: 50)
        ])

        activityFilterButton.configuration = .plain()
        activityFilterButton.contentHorizontalAlignment = .leading
        activityFilterButton.accessibilityIdentifier = "chat.activity-filter"
        activityFilterButton.showsMenuAsPrimaryAction = true
        activityFilterButton.heightAnchor.constraint(equalToConstant: 44).withPriority(.defaultHigh).isActive = true
        updateActivityFilter()
        messageList.delegate = self

        mode.accessibilityLabel = L("Conversation mode")
        mode.accessibilityIdentifier = "Conversation mode"
        mode.apportionsSegmentWidthsByContent = true
        mode.addAction(UIAction { [weak self] _ in self?.renderMode() }, for: .valueChanged)
        callStrip.isHidden = call == nil || docked
        Publishers.CombineLatest3(catchUp.$timeline, catchUp.$canViewTranscript,
                                  catchUp.$transcriptionEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] timeline, canView, enabled in
                guard let self else { return }
                self.timeline = timeline
                self.canViewTranscript = canView
                self.transcriptionEnabled = enabled
                self.renderTranscript()
            }
            .store(in: &subscriptions)
        chat.$items.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.renderMessages($0) }
            .store(in: &subscriptions)
        Publishers.CombineLatest(chat.$canSend, chat.$unavailableReason).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateComposer() }
            .store(in: &subscriptions)
        chat.$unreadCoverageIsLimited.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateComposer() }
            .store(in: &subscriptions)
        chat.reactionHistory.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] in
                DispatchQueue.main.async { [weak self] in self?.renderMessages(self?.chat.items ?? []) }
            }.store(in: &subscriptions)
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.markVisibleReactions() }
            }.store(in: &subscriptions)
        }
        if let call {
            Publishers.CombineLatest4(call.$microphoneOn, call.$cameraOn,
                                      call.$speakerOn, call.$onHold)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] mic, camera, speaker, held in
                    self?.renderCallState(microphone: mic, camera: camera,
                                          speaker: speaker, held: held)
                }
                .store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.keyboardPresented = true
                self?.view.setNeedsLayout()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.keyboardPresented = false
                self?.view.setNeedsLayout()
            }.store(in: &subscriptions)
        renderMode()
        updateComposer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        panelVisible = true
        renderMode(); markVisibleReactions()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        panelVisible = false
        chat.isConversationOpen = false
        chat.reactionHistory.isReadingLatest = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let sidePanel = !docked && view.bounds.width >= 700
        if sidePanel != isSidePanel {
            isSidePanel = sidePanel
            panelLeading.isActive = !sidePanel
            panelSideWidth.isActive = sidePanel
            panel.layer.cornerRadius = sidePanel ? 16 : 0
            panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        }
        if docked {
            panel.layer.cornerRadius = 0
            panelLeading.isActive = true
            panelSideWidth.isActive = false
        } else if sidePanel {
            // Keep the reading width after the landscape cutout/home-indicator inset.
            let safeWidth = view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right
            panelSideWidth.constant = min(420, max(320, safeWidth * 0.34)) + view.safeAreaInsets.right
        }
        let keyboardVisible = keyboardPresented || panel.keyboardLayoutGuide.layoutFrame.minY <
            panel.bounds.height - panel.safeAreaInsets.bottom - 20
        let usableHeight = panel.keyboardLayoutGuide.layoutFrame.minY - panel.safeAreaInsets.top
        let compact = call != nil && keyboardVisible &&
            (sidePanel || usableHeight < 320 || panel.bounds.height < 450)
        if compact != isCompactForKeyboard {
            isCompactForKeyboard = compact
            header.isHidden = compact
            mode.isHidden = compact
            hint.isHidden = compact
            callStrip.viewWithTag(29)?.isHidden = !compact
            if let call {
                renderCallState(microphone: call.microphoneOn, camera: call.cameraOn,
                                speaker: call.speakerOn, held: call.onHold)
            }
            view.layoutIfNeeded()
        }
        updateComposerHeight()
        markVisibleReactions()
    }

    override func viewWillTransition(to size: CGSize,
                                     with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        let nearBottom = messageList.contentSize.height - messageList.contentOffset.y -
            messageList.bounds.height < 60
        let oldOffset = messageList.contentOffset.y
        let rows = messageRows.arrangedSubviews
        let anchor = rows.firstIndex { $0.frame.maxY > oldOffset }
        let intraRowOffset = anchor.map { oldOffset - rows[$0].frame.minY } ?? 0
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard let self else { return }
                self.messageList.layoutIfNeeded()
                if nearBottom {
                    self.scrollMessagesToBottom()
                } else if let anchor, self.messageRows.arrangedSubviews.indices.contains(anchor) {
                    let row = self.messageRows.arrangedSubviews[anchor]
                    let target = max(0, min(row.frame.minY + intraRowOffset,
                                            self.messageList.contentSize.height - self.messageList.bounds.height))
                    self.messageList.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                }
            }
        }
    }

    private func buildHeader() {
        let title = UILabel()
        title.text = L("Conversation")
        title.textColor = .white
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        close.accessibilityLabel = L("Close conversation")
        close.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if let onClose = self.onClose { onClose() }
            else { self.dismiss(animated: true) }
        }, for: .touchUpInside)
        close.widthAnchor.constraint(equalToConstant: 44).isActive = true
        header.axis = .horizontal
        header.alignment = .center
        header.addArrangedSubview(title)
        header.addArrangedSubview(close)
    }

    private func buildContent() {
        for child in [messageList, transcript] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: content.topAnchor),
                child.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                child.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }
        messageList.backgroundColor = card
        messageList.layer.cornerRadius = 14
        messageList.keyboardDismissMode = .interactive
        messageList.accessibilityLabel = L("Jam chat messages")
        messageRows.axis = .vertical
        messageRows.spacing = 12
        messageRows.isLayoutMarginsRelativeArrangement = true
        messageRows.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 12,
                                                                       bottom: 14, trailing: 12)
        messageRows.translatesAutoresizingMaskIntoConstraints = false
        messageList.addSubview(messageRows)
        NSLayoutConstraint.activate([
            messageRows.topAnchor.constraint(equalTo: messageList.contentLayoutGuide.topAnchor),
            messageRows.bottomAnchor.constraint(equalTo: messageList.contentLayoutGuide.bottomAnchor),
            messageRows.leadingAnchor.constraint(equalTo: messageList.contentLayoutGuide.leadingAnchor),
            messageRows.trailingAnchor.constraint(equalTo: messageList.contentLayoutGuide.trailingAnchor),
            messageRows.widthAnchor.constraint(equalTo: messageList.frameLayoutGuide.widthAnchor)
        ])

        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.backgroundColor = card
        transcript.textColor = .white
        transcript.layer.cornerRadius = 14
        transcript.font = .preferredFont(forTextStyle: .body)
        transcript.adjustsFontForContentSizeCategory = true
        transcript.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)
        transcript.accessibilityLabel = L("Jam transcript")
        transcript.delegate = self
        transcript.keyboardDismissMode = .interactive

        catchUpHost = UIHostingController(rootView: CatchUpCardsView(store: catchUp))
        catchUpHost.overrideUserInterfaceStyle = .dark
        addChild(catchUpHost)
        let catchUpView = catchUpHost.view!
        catchUpView.backgroundColor = card
        catchUpView.layer.cornerRadius = 14
        catchUpView.clipsToBounds = true
        catchUpView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(catchUpView)
        NSLayoutConstraint.activate([
            catchUpView.topAnchor.constraint(equalTo: content.topAnchor),
            catchUpView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            catchUpView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            catchUpView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        catchUpHost.didMove(toParent: self)

        newMessagesButton.configuration = .tinted()
        newMessagesButton.configuration?.title = L("New messages ↓")
        newMessagesButton.addAction(UIAction { [weak self] _ in self?.scrollMessagesToBottom() }, for: .touchUpInside)
        followButton.configuration = .tinted()
        followButton.configuration?.title = L("Jump to latest ↓")
        followButton.addAction(UIAction { [weak self] _ in self?.scrollTranscriptToBottom() }, for: .touchUpInside)
        for button in [newMessagesButton, followButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                button.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
            ])
            button.isHidden = true
        }
    }

    private func buildFooter() {
        composer.backgroundColor = UIColor(red: 0.16, green: 0.18, blue: 0.25, alpha: 1)
        composer.textColor = .white
        composer.font = .preferredFont(forTextStyle: .body)
        composer.adjustsFontForContentSizeCategory = true
        composer.layer.cornerRadius = 12
        composer.delegate = self
        composer.text = chat.draft
        composer.accessibilityLabel = L("Chat message")
        composer.accessibilityHint = L("Write a message, then tap Send")
        composerHeight = composer.heightAnchor.constraint(equalToConstant: 48)
        composerHeight.isActive = true
        placeholder.text = L("Message the group…")
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.textColor = .lightGray
        placeholder.isUserInteractionEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        composer.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: composer.topAnchor, constant: 8),
            placeholder.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 6),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: composer.trailingAnchor, constant: -6)
        ])
        sendButton.configuration = .filled()
        sendButton.configuration?.image = UIImage(systemName: "arrow.up")
        sendButton.accessibilityLabel = L("Send chat message")
        sendButton.addAction(UIAction { [weak self] _ in self?.sendMessage() }, for: .touchUpInside)
        sendButton.widthAnchor.constraint(equalToConstant: 48).isActive = true
        sendButton.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let row = composerRow
        row.addArrangedSubview(composer); row.addArrangedSubview(sendButton)
        row.axis = .horizontal
        row.alignment = .bottom
        row.spacing = 8
        // Give the reading area spare height, not a bottom-aligned composer row.
        row.heightAnchor.constraint(equalTo: composer.heightAnchor).withPriority(.defaultHigh).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualTo: sendButton.heightAnchor).withPriority(.defaultHigh).isActive = true
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .lightGray
        hint.numberOfLines = 0
        footer.axis = .vertical
        footer.spacing = 4
        footer.addArrangedSubview(hint)
        footer.addArrangedSubview(row)
    }

    private func buildCallStrip() {
        guard let call else { return }
        callStrip.axis = .horizontal
        callStrip.alignment = .fill
        callStrip.distribution = .fillEqually
        callStrip.spacing = 4
        callStrip.isLayoutMarginsRelativeArrangement = true
        callStrip.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 2, leading: 4,
                                                                     bottom: 2, trailing: 4)
        callStrip.backgroundColor = card
        callStrip.layer.cornerRadius = 12
        callStrip.accessibilityIdentifier = "Conversation call controls"
        for button in [micButton, cameraButton, speakerButton, leaveButton] {
            button.configuration = .tinted()
            button.configuration?.imagePlacement = .top
            button.configuration?.imagePadding = 2
            button.configuration?.contentInsets = .init(top: 2, leading: 2, bottom: 2, trailing: 2)
            callStrip.addArrangedSubview(button)
        }
        micButton.addAction(UIAction { _ in call.toggleMicrophone?() }, for: .touchUpInside)
        cameraButton.addAction(UIAction { _ in call.toggleCamera?() }, for: .touchUpInside)
        speakerButton.addAction(UIAction { _ in call.toggleSpeaker?() }, for: .touchUpInside)
        speakerButton.isHidden = call.toggleSpeaker == nil
        let picker = AVRoutePickerView()
        picker.tintColor = accent
        picker.activeTintColor = accent
        picker.accessibilityLabel = L("Audio route")
        let routeControl = UIView()
        let routeTitle = UILabel()
        routeTitle.text = L("Audio")
        routeTitle.textColor = .white
        routeTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        routeTitle.isUserInteractionEnabled = false
        picker.translatesAutoresizingMaskIntoConstraints = false
        routeTitle.translatesAutoresizingMaskIntoConstraints = false
        routeControl.addSubview(picker)
        routeControl.addSubview(routeTitle)
        NSLayoutConstraint.activate([
            picker.centerXAnchor.constraint(equalTo: routeControl.centerXAnchor),
            picker.centerYAnchor.constraint(equalTo: routeControl.centerYAnchor, constant: -6),
            picker.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            picker.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            routeTitle.centerXAnchor.constraint(equalTo: routeControl.centerXAnchor),
            routeTitle.bottomAnchor.constraint(equalTo: routeControl.bottomAnchor, constant: -2)
        ])
        call.$routeName.receive(on: DispatchQueue.main)
            .sink { picker.accessibilityValue = $0 }
            .store(in: &subscriptions)
        callStrip.insertArrangedSubview(routeControl, at: 2)
        leaveButton.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: false)
            call.leave?()
        }, for: .touchUpInside)
        let compactClose = UIButton(type: .system)
        compactClose.configuration = .plain()
        compactClose.configuration?.image = UIImage(systemName: "xmark")
        compactClose.accessibilityLabel = L("Close conversation")
        compactClose.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        compactClose.isHidden = true
        callStrip.addArrangedSubview(compactClose)
        compactClose.tag = 29
    }

    private func renderCallState(microphone: Bool, camera: Bool, speaker: Bool, held: Bool) {
        style(micButton, title: held ? L("On hold") : L("Mic"),
              symbol: microphone ? "mic.fill" : "mic.slash.fill", active: microphone)
        micButton.isEnabled = !held
        micButton.accessibilityLabel = microphone ? L("Mute microphone") : L("Unmute microphone")
        micButton.accessibilityValue = held ? L("On hold") : (microphone ? L("Microphone on") : L("Microphone off"))
        micButton.largeContentTitle = micButton.accessibilityValue
        style(cameraButton, title: L("Cam"),
              symbol: camera ? "video.fill" : "video.slash.fill", active: camera)
        cameraButton.accessibilityLabel = camera ? L("Stop video") : L("Start video")
        cameraButton.accessibilityValue = camera ? L("Camera on") : L("Camera off")
        cameraButton.largeContentTitle = cameraButton.accessibilityValue
        style(speakerButton, title: speaker ? L("Speaker") : "iPhone",
              symbol: speaker ? "speaker.wave.2" : "iphone", active: speaker)
        speakerButton.accessibilityLabel = speaker ? L("Use iPhone receiver") : L("Use iPhone speaker")
        style(leaveButton, title: L("Leave"), symbol: "phone.down.fill", active: false)
        leaveButton.configuration?.baseForegroundColor = .systemRed
        leaveButton.accessibilityLabel = L("Leave")
    }

    private func style(_ button: UIButton, title: String, symbol: String, active: Bool) {
        button.configuration?.title = isCompactForKeyboard ? nil : title
        button.configuration?.titleLineBreakMode = .byTruncatingTail
        button.configuration?.image = UIImage(systemName: symbol)
        button.showsLargeContentViewer = true
        button.largeContentTitle = title
        button.largeContentImage = UIImage(systemName: symbol)
        button.configuration?.baseForegroundColor = active ? accent : .white
        button.configuration?.baseBackgroundColor = active ? accent.withAlphaComponent(0.22) : card
        button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = .systemFont(ofSize: 11, weight: .semibold)
            return result
        }
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.8
    }

    private func renderMode() {
        let selected = ConversationMode(rawValue: mode.selectedSegmentIndex) ?? .chat
        chat.isConversationOpen = selected == .chat && activityFilter != .reactions && panelVisible && UIApplication.shared.applicationState == .active
        activityFilterButton.isHidden = selected != .chat || !chat.reactionHistoryAvailable
        messageList.isHidden = selected != .chat
        transcript.isHidden = selected != .liveText
        catchUpHost.view.isHidden = selected != .catchUp
        footer.isHidden = selected != .chat || activityFilter == .reactions
        if selected != .chat { composer.resignFirstResponder() }
        newMessagesButton.isHidden = selected != .chat || !hasNewMessages
        if selected != .liveText { followButton.isHidden = true }
        renderTranscript()
        updateComposer()
        markVisibleReactions()
    }

    private func updateActivityFilter() {
        activityFilterButton.configuration?.title = activityFilter.title
        activityFilterButton.configuration?.image = UIImage(systemName: "line.3.horizontal.decrease.circle")
        activityFilterButton.configuration?.imagePadding = 8
        var actions: [UIMenuElement] = ConversationActivityFilter.allCases.map { filter in
            UIAction(title: filter.title, state: activityFilter == filter ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.activityFilter = filter; self.updateActivityFilter()
                self.hasNewMessages = false
                self.messageList.setContentOffset(.zero, animated: false)
                self.renderMessages(self.chat.items); self.renderMode()
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_UI_FIXTURE"]?.hasPrefix("reactions") == true {
            actions.append(UIAction(title: "Receive test reaction") { [weak self] _ in
                self?.chat.reactionHistory.receive(kind: .wave, participantID: "late", displayName: "Narek", isOwn: false)
            })
        }
        #endif
        activityFilterButton.menu = UIMenu(children: actions)
    }

    private func renderMessages(_ items: [ChatEntry]) {
        guard isViewLoaded, !renderingMessages else { return }
        renderingMessages = true
        defer { renderingMessages = false }
        let oldIDs = lastMessageIDs, oldReactionIDs = renderedReactionIDs
        let nearBottom = messageList.contentSize.height - messageList.contentOffset.y - messageList.bounds.height < 60
        let oldOffset = messageList.contentOffset
        let oldAnchor = messageRows.arrangedSubviews.first { $0.frame.maxY > oldOffset.y }
        let anchorID = oldAnchor?.accessibilityIdentifier
        let anchorOffset = oldAnchor.map { oldOffset.y - $0.frame.minY } ?? 0
        lastMessageIDs = items.map(\.id)
        renderedReactionIDs = chat.reactionHistory.events.map(\.id)
        let visibleIDs = Set(items.map(\.id))
        messageViews = messageViews.filter { visibleIDs.contains($0.key) }
        retryButtons = retryButtons.filter { visibleIDs.contains($0.key) }
        var timeline: [(Date, String, UIView)] = []
        if activityFilter != .reactions {
            for entry in items {
                let row: UIView
                if let cached = messageViews[entry.id], cached.entry == entry { row = cached.view }
                else {
                    retryButtons.removeValue(forKey: entry.id)
                    row = messageRow(entry)
                    row.accessibilityIdentifier = "chat.message." + entry.id
                    messageViews[entry.id] = (entry, row)
                }
                timeline.append((entry.sentAt, "m:" + entry.id, row))
            }
        }
        if activityFilter != .messages && chat.reactionHistoryAvailable {
            let groups = chat.reactionHistory.projection(chatBoundaries: items.map(\.sentAt))
            let groupIDs = Set(groups.map(\.id))
            reactionViews = reactionViews.filter { groupIDs.contains($0.key) }
            for group in groups {
                let row: ReactionHistoryRowView
                if let cached = reactionViews[group.id] { row = cached; if !cached.matchesContent(group) { cached.update(group) } }
                else {
                    row = ReactionHistoryRowView(group: group)
                    row.onExpansionChanged = { [weak self] in self?.messageList.layoutIfNeeded(); self?.markVisibleReactions() }
                    reactionViews[group.id] = row
                }
                timeline.append((group.start, "r:" + group.id, row))
            }
            for gap in chat.reactionHistory.gaps {
                let time = gap.start.formatted(date: .omitted, time: .shortened) + (gap.end.map { "–" + $0.formatted(date: .omitted, time: .shortened) } ?? "…")
                let row = activityNote(time + " · " + L("Some reactions may be missing while disconnected or backgrounded."))
                row.accessibilityIdentifier = "reaction.gap." + gap.id
                timeline.append((gap.start, "g:" + gap.id, row))
            }
        }
        timeline.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var desiredViews = timeline.map { $0.2 }
        if desiredViews.isEmpty {
            desiredViews = [activityNote(activityFilter == .reactions ? L("No reactions yet.") : L("No messages yet. Say hello to the group."))]
        }
        if activityFilter != .messages && chat.reactionHistoryAvailable {
            let scope = activityNote(L("Reactions received on this device during this meeting."))
            scope.accessibilityIdentifier = "reaction.history-scope"
            desiredViews.insert(scope, at: 0)
            if chat.reactionHistory.hasTruncatedHistory { desiredViews.insert(activityNote(L("Showing recent reactions")), at: 1) }
        }
        let desiredIdentities = Set(desiredViews.map(ObjectIdentifier.init))
        for row in messageRows.arrangedSubviews where !desiredIdentities.contains(ObjectIdentifier(row)) { row.removeFromSuperview() }
        for (index, row) in desiredViews.enumerated() {
            if messageRows.arrangedSubviews.count <= index || messageRows.arrangedSubviews[index] !== row { messageRows.insertArrangedSubview(row, at: index) }
        }
        messageList.layoutIfNeeded()
        if nearBottom { scrollMessagesToBottom() }
        else {
            if let anchorID, let row = messageRows.arrangedSubviews.first(where: { $0.accessibilityIdentifier == anchorID }) {
                messageList.setContentOffset(CGPoint(x: 0, y: max(0, row.frame.minY + anchorOffset)), animated: false)
            } else { messageList.setContentOffset(oldOffset, animated: false) }
            if (activityFilter != .reactions && oldIDs != lastMessageIDs) || (activityFilter != .messages && oldReactionIDs != renderedReactionIDs) { hasNewMessages = true }
            newMessagesButton.configuration?.title = L("New activity ↓")
            newMessagesButton.isHidden = !hasNewMessages || mode.selectedSegmentIndex != 0
        }
        DispatchQueue.main.async { [weak self] in self?.markVisibleReactions() }
    }

    private func activityNote(_ text: String) -> UILabel {
        let label = UILabel(); label.text = text; label.numberOfLines = 0
        label.textColor = .lightGray; label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func markVisibleReactions() {
        chat.isConversationOpen = panelVisible && UIApplication.shared.applicationState == .active &&
            mode.selectedSegmentIndex == ConversationMode.chat.rawValue && activityFilter != .reactions
        let reading = panelVisible && UIApplication.shared.applicationState == .active &&
            mode.selectedSegmentIndex == ConversationMode.chat.rawValue && activityFilter != .messages &&
            viewIfLoaded?.window != nil && presentedViewController == nil
        let nearBottom = messageList.contentSize.height - messageList.contentOffset.y - messageList.bounds.height < 60
        chat.reactionHistory.isReadingLatest = reading && nearBottom
        guard reading, !renderingMessages else { return }
        let ids = messageRows.arrangedSubviews.flatMap { row -> [String] in
            (row as? ReactionHistoryRowView)?.visibleEventIDs(in: messageList) ?? []
        }
        chat.reactionHistory.markSeen(ids: ids)
    }

    private func messageRow(_ entry: ChatEntry) -> UIView {
        let row = UIStackView()
        row.axis = .vertical
        row.spacing = 5
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 12,
                                                                bottom: 10, trailing: 12)
        row.backgroundColor = entry.isOwn ? UIColor(red: 0.17, green: 0.24, blue: 0.32, alpha: 1) :
            UIColor(red: 0.16, green: 0.18, blue: 0.25, alpha: 1)
        row.layer.cornerRadius = 12
        let sender = UILabel()
        sender.text = "\(entry.isOwn ? L("You") : entry.sender) · \(entry.sentAt.formatted(date: .omitted, time: .shortened))"
        sender.font = .preferredFont(forTextStyle: .caption1)
        sender.adjustsFontForContentSizeCategory = true
        sender.textColor = entry.isOwn ? accent : .lightGray
        sender.numberOfLines = 0
        row.addArrangedSubview(sender)
        let body = UITextView()
        body.text = entry.text
        body.font = .preferredFont(forTextStyle: .body)
        body.adjustsFontForContentSizeCategory = true
        body.textColor = .white
        body.backgroundColor = .clear
        body.isEditable = false
        body.isScrollEnabled = false
        body.isSelectable = true
        body.dataDetectorTypes = [.link]
        body.linkTextAttributes = [.foregroundColor: accent]
        body.textContainerInset = .zero
        body.textContainer.lineFragmentPadding = 0
        body.accessibilityLabel = "\(entry.isOwn ? L("You") : entry.sender): \(entry.text)"
        row.addArrangedSubview(body)
        switch entry.delivery {
        case .pending:
            let state = UILabel()
            state.text = L("Sending…")
            state.textColor = .lightGray
            state.font = .preferredFont(forTextStyle: .caption1)
            row.addArrangedSubview(state)
        case .failed:
            let retry = UIButton(type: .system)
            retry.configuration = .tinted()
            retry.configuration?.title = L("Not sent · Retry")
            retry.accessibilityLabel = L("Retry message from %@", sender.text ?? L("You"))
            retry.isEnabled = chat.canSend
            retryButtons[entry.id] = retry
            retry.addAction(UIAction { [weak self] _ in self?.chat.retry(entry.id) }, for: .touchUpInside)
            row.addArrangedSubview(retry)
        case .sent: break
        }
        return row
    }

    private func renderTranscript() {
        guard isViewLoaded, mode.selectedSegmentIndex == ConversationMode.liveText.rawValue else { return }
        let nearBottom = transcript.contentSize.height - transcript.contentOffset.y - transcript.bounds.height < 60
        let offset = transcript.contentOffset
        isRenderingTranscript = true
        if canViewTranscript == true && transcriptionEnabled && !timeline.segments.isEmpty {
            let segments = timeline.segments
            if let previous = renderedTranscriptSegments,
               segments.count >= previous.count, segments.starts(with: previous) {
                if segments.count > previous.count {
                    transcript.textStorage.append(transcriptLines(segments.dropFirst(previous.count),
                                                                  precedingLines: previous.count))
                }
            } else {
                transcript.attributedText = liveTranscript()
            }
            renderedTranscriptSegments = segments
        } else {
            renderedTranscriptSegments = nil
            let message = catchUp.transcriptUnavailableReason ?? CatchUpText.live(timeline: timeline, canView: canViewTranscript,
                                           enabled: transcriptionEnabled)
            if transcript.text != message { transcript.text = message }
        }
        transcript.layoutIfNeeded()
        if nearBottom { scrollTranscriptToBottom() }
        else {
            transcript.setContentOffset(offset, animated: false)
            followButton.isHidden = false
        }
        isRenderingTranscript = false
    }

    private func liveTranscript() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let caption = UIFont.preferredFont(forTextStyle: .caption1)
        result.append(NSAttributedString(string: L("Text received by this phone may be incomplete.\n\n"),
                                         attributes: [.font: caption, .foregroundColor: UIColor.lightGray]))
        result.append(transcriptLines(timeline.segments[...], precedingLines: 0))
        return result
    }

    private func transcriptLines(_ lines: ArraySlice<TranscriptSegment>,
                                 precedingLines: Int) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = UIFont.preferredFont(forTextStyle: .body)
        let caption = UIFont.preferredFont(forTextStyle: .caption1)
        for (index, line) in lines.enumerated() {
            if precedingLines + index > 0 { result.append(NSAttributedString(string: "\n\n")) }
            if let time = line.spokenAt {
                result.append(NSAttributedString(string: "\(time.formatted(date: .omitted, time: .shortened))  ",
                    attributes: [.font: caption, .foregroundColor: UIColor.lightGray]))
            }
            result.append(NSAttributedString(string: line.speaker ?? L("Participant"),
                attributes: [.font: UIFont.systemFont(ofSize: body.pointSize, weight: .semibold),
                             .foregroundColor: accent]))
            result.append(NSAttributedString(string: "\n\(line.text)",
                attributes: [.font: body, .foregroundColor: UIColor.white]))
        }
        return result
    }

    private func scrollMessagesToBottom() {
        messageList.layoutIfNeeded()
        messageList.setContentOffset(CGPoint(x: 0, y: max(0, messageList.contentSize.height -
                                                         messageList.bounds.height)), animated: false)
        newMessagesButton.isHidden = true
        hasNewMessages = false
        markVisibleReactions()
    }

    private func scrollTranscriptToBottom() {
        transcript.layoutIfNeeded()
        transcript.setContentOffset(CGPoint(x: 0, y: max(0, transcript.contentSize.height -
                                                        transcript.bounds.height)), animated: false)
        followButton.isHidden = true
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === messageList {
            markVisibleReactions()
            if messageList.contentSize.height - messageList.contentOffset.y - messageList.bounds.height < 60 {
                hasNewMessages = false; newMessagesButton.isHidden = true
            }
            return
        }
        guard scrollView === transcript, !isRenderingTranscript,
              mode.selectedSegmentIndex == ConversationMode.liveText.rawValue else { return }
        let remaining = transcript.contentSize.height - transcript.contentOffset.y - transcript.bounds.height
        followButton.isHidden = remaining < 60
    }

    func textViewDidChange(_ textView: UITextView) {
        guard textView === composer else { return }
        chat.draft = textView.text
        updateComposer()
    }

    private func updateComposer() {
        guard isViewLoaded else { return }
        let clean = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = clean.unicodeScalars.count
        placeholder.isHidden = !composer.text.isEmpty || !chat.canSend
        sendButton.isEnabled = chat.canSend && RoomChatPacket.accepts(text: clean)
        retryButtons.values.forEach { $0.isEnabled = chat.canSend }
        composer.isEditable = chat.canSend
        composerRow.isHidden = chat.isReadOnly || activityFilter == .reactions
        if activityFilter == .reactions { hint.text = nil }
        else if !chat.canSend { hint.text = chat.unavailableReason ?? L("Chat isn't available right now.") }
        else if count > 2_000 { hint.text = L("%ld characters over the limit", count - 2_000) }
        else if count > 0 && !RoomChatPacket.accepts(text: clean) { hint.text = L("This message is too large to send.") }
        else if count >= 1_800 { hint.text = L("%ld/2,000 characters", count) }
        else if chat.unreadCoverageIsLimited { hint.text = L("Earlier unread messages may be incomplete after history changed.") }
        else { hint.text = nil }
        hint.isHidden = hint.text == nil
        updateComposerHeight()
    }

    private func updateComposerHeight() {
        guard composerHeight != nil else { return }
        let landscape = view.bounds.width > view.bounds.height
        let target = landscape ? 48 :
            min(100, max(48, composer.sizeThatFits(CGSize(width: max(150, composer.bounds.width),
                                                           height: .greatestFiniteMagnitude)).height))
        if abs(composerHeight.constant - target) > 0.5 { composerHeight.constant = target }
    }

    private func sendMessage() {
        guard chat.send(composer.text) else { return }
        composer.text = ""
        chat.draft = ""
        updateComposer()
        scrollMessagesToBottom()
    }
}

private final class ConversationOverlayView: UIView {
    weak var panel: UIView?

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let panel else { return false }
        return panel.frame.contains(point)
    }
}
