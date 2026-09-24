import Combine
import Foundation

struct ChatEntry: Equatable, Identifiable {
    let id: String
    let sender: String
    let text: String
    let sentAt: Date
    let isOwn: Bool
    var delivery: ChatDelivery = .sent
}

enum ChatDelivery: Equatable {
    case pending, sent, failed
}

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var items: [ChatEntry] = []
    @Published var canSend = false
    @Published var draft = ""
    @Published private(set) var unreadCount = 0
    var isConversationOpen = false {
        didSet { if isConversationOpen { unreadCount = 0 } }
    }
    var onSend: ((String) -> Void)?
    var onRetry: ((ChatEntry) -> Void)?

    func send(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let onSend, !clean.isEmpty, clean.count <= 2_000 else { return false }
        onSend(clean)
        return true
    }

    func replace(_ messages: [ChatEntry]) {
        if !isConversationOpen {
            let oldIDs = Set(items.map(\.id))
            unreadCount += messages.filter { !$0.isOwn && !oldIDs.contains($0.id) }.count
        }
        items = Array(messages.suffix(200))
    }

    func append(_ message: ChatEntry) {
        guard !items.contains(where: { $0.id == message.id }) else { return }
        if !message.isOwn && !isConversationOpen { unreadCount += 1 }
        items.append(message)
        if items.count > 200 { items.removeFirst(items.count - 200) }
    }

    func setDelivery(_ delivery: ChatDelivery, for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].delivery = delivery
    }

    func retry(_ id: String) {
        guard canSend, let onRetry,
              let entry = items.first(where: { $0.id == id && $0.delivery == .failed }) else { return }
        setDelivery(.pending, for: id)
        onRetry(entry)
    }

    func clear() {
        items = []
        draft = ""
        unreadCount = 0
        canSend = false
        onSend = nil
        onRetry = nil
    }
}
