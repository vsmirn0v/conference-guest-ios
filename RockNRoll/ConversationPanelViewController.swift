import Combine
import ConferenceCore
import UIKit

@MainActor
final class ConversationPanelViewController: UIViewController, UITextViewDelegate {
    private static var preferredTab: Int {
        let saved = UserDefaults.standard.integer(forKey: "conversationPreferredTab")
        return (0...2).contains(saved) ? saved : 0
    }
    private let catchUp: CatchUpStore
    private let chat: ChatStore
    private var subscriptions = Set<AnyCancellable>()
    private let mode = UISegmentedControl(items: ["Chat", "Live text", "Catch up"])
    private let messages = UITextView()
    private let transcript = UITextView()
    private let composer = UITextView()
    private let sendButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let newMessagesButton = UIButton(type: .system)
    private let chatFooter = UIStackView()
    private let reviewed = UIButton(type: .system)
    private var timeline = CatchUpTimeline()
    private var canViewTranscript: Bool?
    private var transcriptionEnabled = false

    init(catchUp: CatchUpStore, chat: ChatStore, showTranscript: Bool = false) {
        self.catchUp = catchUp
        self.chat = chat
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        let remembered = Self.preferredTab
        mode.selectedSegmentIndex = showTranscript ? 2 :
            (remembered == 2 && catchUp.timeline.unreadCount == 0 ? 0 : remembered)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if mode.selectedSegmentIndex == 0 { chat.isConversationOpen = true }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        chat.isConversationOpen = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.07, green: 0.09, blue: 0.15, alpha: 1)
        let title = UILabel()
        title.text = "Conversation"
        title.textColor = .white
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        close.accessibilityLabel = "Close conversation"
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [title, close])
        header.axis = .horizontal
        header.spacing = 12
        close.widthAnchor.constraint(equalToConstant: 44).isActive = true

        mode.accessibilityLabel = "Conversation mode"
        mode.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            UserDefaults.standard.set(self.mode.selectedSegmentIndex, forKey: "conversationPreferredTab")
            self.renderMode()
        }, for: .valueChanged)
        for textView in [messages, transcript] {
            textView.isEditable = false
            textView.isSelectable = true
            textView.backgroundColor = UIColor(red: 0.11, green: 0.13, blue: 0.20, alpha: 1)
            textView.textColor = .white
            textView.layer.cornerRadius = 14
            textView.font = .preferredFont(forTextStyle: .body)
            textView.adjustsFontForContentSizeCategory = true
            textView.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)
        }
        messages.accessibilityLabel = "Jam chat messages"
        transcript.accessibilityLabel = "Jam transcript"

        composer.backgroundColor = .secondarySystemBackground
        composer.textColor = .label
        composer.font = .preferredFont(forTextStyle: .body)
        composer.adjustsFontForContentSizeCategory = true
        composer.layer.cornerRadius = 12
        composer.delegate = self
        composer.text = chat.draft
        composer.accessibilityLabel = "Chat message"
        composer.accessibilityHint = "Write a message, then tap Send"
        composer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sendButton.configuration = .filled()
        sendButton.configuration?.image = UIImage(systemName: "arrow.up")
        sendButton.accessibilityLabel = "Send chat message"
        sendButton.addAction(UIAction { [weak self] _ in self?.sendMessage() }, for: .touchUpInside)
        sendButton.widthAnchor.constraint(equalToConstant: 48).isActive = true
        sendButton.heightAnchor.constraint(equalToConstant: 48).isActive = true
        chatFooter.axis = .horizontal
        chatFooter.alignment = .bottom
        chatFooter.spacing = 8
        chatFooter.addArrangedSubview(composer)
        chatFooter.addArrangedSubview(sendButton)
        composer.heightAnchor.constraint(equalToConstant: 72).isActive = true

        retryButton.configuration = .tinted()
        retryButton.configuration?.title = "Retry failed message"
        retryButton.addAction(UIAction { [weak self] _ in
            guard let self, let entry = self.chat.items.last(where: { $0.delivery == .failed }) else { return }
            self.chat.retry(entry.id)
        }, for: .touchUpInside)
        reviewed.configuration = .tinted()
        reviewed.configuration?.title = "Mark reviewed"
        reviewed.addAction(UIAction { [weak self] _ in self?.catchUp.markReviewed() }, for: .touchUpInside)
        newMessagesButton.configuration = .tinted()
        newMessagesButton.configuration?.title = "New messages ↓"
        newMessagesButton.addAction(UIAction { [weak self] _ in self?.scrollChatToBottom() }, for: .touchUpInside)
        newMessagesButton.isHidden = true
        let footer = UIStackView(arrangedSubviews: [newMessagesButton, retryButton, chatFooter, reviewed])
        footer.axis = .vertical
        footer.spacing = 6

        for item in [header, mode, messages, transcript, footer] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            mode.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            mode.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            mode.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            mode.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            messages.topAnchor.constraint(equalTo: mode.bottomAnchor, constant: 10),
            messages.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            messages.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            messages.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            transcript.topAnchor.constraint(equalTo: messages.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: messages.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: messages.trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: messages.bottomAnchor),
        ])
        Publishers.CombineLatest3(catchUp.$timeline, catchUp.$canViewTranscript,
                                  catchUp.$transcriptionEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] timeline, canView, enabled in
                guard let self else { return }
                self.timeline = timeline
                self.canViewTranscript = canView
                self.transcriptionEnabled = enabled
                self.renderTranscript()
                self.reviewed.isHidden = self.mode.selectedSegmentIndex != 2 || timeline.unreadCount == 0
            }
            .store(in: &subscriptions)
        chat.$items.receive(on: DispatchQueue.main)
            .sink { [weak self] items in self?.renderMessages(items) }
            .store(in: &subscriptions)
        chat.$canSend.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateComposer() }
            .store(in: &subscriptions)
        renderMode()
        updateComposer()
    }

    private func renderMode() {
        let isChat = mode.selectedSegmentIndex == 0
        chat.isConversationOpen = isChat && view.window != nil
        messages.isHidden = !isChat
        transcript.isHidden = isChat
        chatFooter.isHidden = !isChat
        retryButton.isHidden = !isChat || !chat.items.contains { $0.delivery == .failed }
        newMessagesButton.isHidden = !isChat || newMessagesButton.isHidden
        reviewed.isHidden = mode.selectedSegmentIndex != 2 || timeline.unreadCount == 0
        if !isChat { composer.resignFirstResponder() }
        renderTranscript()
    }

    private func renderTranscript() {
        if mode.selectedSegmentIndex == 1 {
            if canViewTranscript == true && transcriptionEnabled && !timeline.segments.isEmpty {
                transcript.attributedText = liveTranscript()
            } else {
                transcript.text = CatchUpText.live(timeline: timeline, canView: canViewTranscript,
                                                   enabled: transcriptionEnabled)
            }
        } else if mode.selectedSegmentIndex == 2 {
            transcript.text = CatchUpText.make(timeline: timeline, canView: canViewTranscript,
                                               enabled: transcriptionEnabled,
                                               warning: catchUp.persistenceWarning)
        }
    }

    private func liveTranscript() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = UIFont.preferredFont(forTextStyle: .body)
        let caption = UIFont.preferredFont(forTextStyle: .caption1)
        let speakerFont = UIFont.systemFont(ofSize: body.pointSize, weight: .semibold)
        let ordered = timeline.segments.sorted {
            ($0.spokenAt ?? .distantFuture) < ($1.spokenAt ?? .distantFuture)
        }
        result.append(NSAttributedString(string: "Text received by this phone may be incomplete.\n\n",
                                         attributes: [.font: caption, .foregroundColor: UIColor.lightGray]))
        for (index, segment) in ordered.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n\n")) }
            if let spokenAt = segment.spokenAt {
                let time = DateFormatter.localizedString(from: spokenAt,
                                                         dateStyle: .none, timeStyle: .short)
                result.append(NSAttributedString(string: "\(time)  ", attributes: [
                    .font: caption, .foregroundColor: UIColor.lightGray
                ]))
            }
            result.append(NSAttributedString(string: segment.speaker ?? "Participant", attributes: [
                .font: speakerFont, .foregroundColor: UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1)
            ]))
            result.append(NSAttributedString(string: "\n\(segment.text)", attributes: [
                .font: body, .foregroundColor: UIColor.white
            ]))
        }
        if timeline.isTruncated {
            result.append(NSAttributedString(string: "\n\nOlder lines have left this phone’s memory.", attributes: [
                .font: caption, .foregroundColor: UIColor.lightGray
            ]))
        }
        return result
    }

    private func renderMessages(_ items: [ChatEntry]) {
        let nearBottom = messages.contentSize.height - messages.contentOffset.y - messages.bounds.height < 80
        let oldOffset = messages.contentOffset
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        messages.text = items.isEmpty ? "No messages yet. Say hello to the group." : items.map { entry in
            let delivery = entry.delivery == .pending ? " · Sending…" :
                (entry.delivery == .failed ? " · Not sent" : "")
            return "\(entry.sender) · \(formatter.string(from: entry.sentAt))\(delivery)\n\(entry.text)"
        }.joined(separator: "\n\n")
        retryButton.isHidden = mode.selectedSegmentIndex != 0 || !items.contains { $0.delivery == .failed }
        if nearBottom { scrollChatToBottom() }
        else {
            messages.setContentOffset(oldOffset, animated: false)
            newMessagesButton.isHidden = mode.selectedSegmentIndex != 0
        }
    }

    private func scrollChatToBottom() {
        messages.layoutIfNeeded()
        let bottom = max(0, messages.contentSize.height - messages.bounds.height)
        messages.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        newMessagesButton.isHidden = true
    }

    func textViewDidChange(_ textView: UITextView) {
        chat.draft = textView.text
        updateComposer()
    }

    private func updateComposer() {
        let count = composer.text.trimmingCharacters(in: .whitespacesAndNewlines).count
        sendButton.isEnabled = chat.canSend && count > 0 && count <= 2_000
        retryButton.isEnabled = chat.canSend
        composer.isEditable = chat.canSend
    }

    private func sendMessage() {
        if chat.send(composer.text) {
            composer.text = ""
            chat.draft = ""
            updateComposer()
            scrollChatToBottom()
        }
    }
}
