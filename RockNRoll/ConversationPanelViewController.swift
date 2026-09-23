import Combine
import ConferenceCore
import UIKit

/// A full-screen, rotation-safe conversation view. Audio stays with the meeting engine.
@MainActor
final class ConversationPanelViewController: UIViewController {
    private let catchUp: CatchUpStore
    private let chat: ChatStore
    private var subscriptions = Set<AnyCancellable>()
    private let mode = UISegmentedControl(items: ["Chat", "Transcript"])
    private let messages = UITextView()
    private let transcript = UITextView()
    private let messageField = UITextField()
    private let sendButton = UIButton(type: .system)
    private let chatFooter = UIStackView()
    private let reviewed = UIButton(type: .system)

    init(catchUp: CatchUpStore, chat: ChatStore, showTranscript: Bool = true) {
        self.catchUp = catchUp
        self.chat = chat
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        mode.selectedSegmentIndex = showTranscript ? 1 : 0
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "Jam conversation"
        title.font = .systemFont(ofSize: 25, weight: .bold)
        title.adjustsFontSizeToFitWidth = true
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        close.accessibilityLabel = "Close catch up"
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [title, close])
        header.axis = .horizontal
        header.spacing = 12
        close.widthAnchor.constraint(equalToConstant: 44).isActive = true

        mode.accessibilityLabel = "Conversation mode"
        mode.addAction(UIAction { [weak self] _ in self?.renderMode() }, for: .valueChanged)
        for textView in [messages, transcript] {
            textView.isEditable = false
            textView.isSelectable = true
            textView.backgroundColor = .secondarySystemBackground
            textView.layer.cornerRadius = 14
            textView.font = .preferredFont(forTextStyle: .body)
            textView.adjustsFontForContentSizeCategory = true
            textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        }
        messages.accessibilityLabel = "Jam chat messages"
        transcript.accessibilityLabel = "Missed jam transcript"

        messageField.placeholder = "Message the jam"
        messageField.borderStyle = .roundedRect
        messageField.returnKeyType = .send
        messageField.delegate = self
        messageField.accessibilityLabel = "Chat message"
        sendButton.configuration = .tinted()
        sendButton.configuration?.title = "Send"
        sendButton.addAction(UIAction { [weak self] _ in self?.sendMessage() }, for: .touchUpInside)
        sendButton.accessibilityLabel = "Send chat message"
        chatFooter.axis = .horizontal
        chatFooter.spacing = 8
        chatFooter.addArrangedSubview(messageField)
        chatFooter.addArrangedSubview(sendButton)
        sendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        reviewed.configuration = .tinted()
        reviewed.configuration?.title = "Mark reviewed"
        reviewed.addAction(UIAction { [weak self] _ in self?.catchUp.markReviewed() }, for: .touchUpInside)
        let footer = UIStackView(arrangedSubviews: [chatFooter, reviewed])
        footer.axis = .vertical
        footer.spacing = 0

        for item in [header, mode, messages, transcript, footer] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            header.heightAnchor.constraint(equalToConstant: 44),
            mode.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            mode.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            mode.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            mode.heightAnchor.constraint(equalToConstant: 34),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 40)
        ])
        for content in [messages, transcript] {
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: mode.bottomAnchor, constant: 10),
                content.leadingAnchor.constraint(equalTo: header.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: header.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10)
            ])
        }

        Publishers.CombineLatest4(catchUp.$timeline, catchUp.$canViewTranscript,
                                  catchUp.$transcriptionEnabled, catchUp.$persistenceWarning)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] timeline, canView, enabled, warning in
                self?.transcript.text = CatchUpText.make(timeline: timeline, canView: canView,
                                                         enabled: enabled, warning: warning)
                self?.reviewed.isEnabled = timeline.unreadCount > 0
            }
            .store(in: &subscriptions)
        chat.$items.receive(on: DispatchQueue.main)
            .sink { [weak self] items in self?.renderMessages(items) }
            .store(in: &subscriptions)
        chat.$canSend.receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.messageField.isEnabled = enabled
                self?.sendButton.isEnabled = enabled
            }
            .store(in: &subscriptions)
        renderMode()
    }

    private func renderMode() {
        let showTranscript = mode.selectedSegmentIndex == 1
        transcript.isHidden = !showTranscript
        messages.isHidden = showTranscript
        reviewed.isHidden = !showTranscript
        chatFooter.isHidden = showTranscript
        if showTranscript { messageField.resignFirstResponder() }
    }

    private func renderMessages(_ items: [ChatEntry]) {
        if items.isEmpty {
            messages.text = "No chat messages yet."
        } else {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            messages.text = items.map { entry in
                "\(entry.sender) · \(formatter.string(from: entry.sentAt))\n\(entry.text)"
            }.joined(separator: "\n\n")
        }
        let bottom = max(0, messages.contentSize.height - messages.bounds.height)
        messages.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
    }

    private func sendMessage() {
        if chat.send(messageField.text ?? "") { messageField.text = nil }
    }
}

extension ConversationPanelViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendMessage()
        return true
    }
}
