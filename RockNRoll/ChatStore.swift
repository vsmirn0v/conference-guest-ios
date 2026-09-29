import Combine
import ConferenceCore
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
    private var seenMessageIDs = Set<String>()
    private var seenOrder: [String] = []
    private var snapshotTail: [String] = []
    private var hasSnapshot = false
    private var newestTimestamp: Date?
    @Published private(set) var unreadCoverageIsLimited = false
    var retainedIdentityCount: Int { seenMessageIDs.count }

    private func remember(_ id: String) -> Bool {
        guard seenMessageIDs.insert(id).inserted else { return false }
        seenOrder.append(id)
        if seenOrder.count >= 4_096 {
            let dropped = seenOrder.count - 2_048
            seenOrder.prefix(dropped).forEach { seenMessageIDs.remove($0) }
            seenOrder.removeFirst(dropped)
        }
        return true
    }
    var isConversationOpen = false {
        didSet { if isConversationOpen { unreadCount = 0 } }
    }
    var onSend: ((String) -> Void)?
    var onRetry: ((ChatEntry) -> Void)?

    func send(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let onSend, RoomChatPacket.accepts(text: clean) else { return false }
        onSend(clean)
        return true
    }

    /// Provider snapshots are ordered. An anchor establishes the new suffix;
    /// after reordering/truncation, only provably newer timestamps count as unread.
    func replace(_ messages: [ChatEntry]) {
        replaceSnapshot(messages, id: { $0.id }, timestamp: { $0.sentAt }, isOwn: { $0.isOwn }, entry: { $0 })
    }

    func replaceSnapshot<Message>(_ messages: [Message], id: (Message) -> String,
                                  timestamp: (Message) -> Date?, isOwn: (Message) -> Bool,
                                  entry: (Message) -> ChatEntry) {
        // Empty initial/reconnect snapshots establish no cursor. Keep the last
        // nonempty anchor so reconnect replay cannot be counted as fresh chat.
        guard !messages.isEmpty else {
            if !items.isEmpty { items = [] }
            return
        }
        let anchor = snapshotTail.last
        var start = 0
        var verified = !hasSnapshot
        if let anchor, let index = messages.lastIndex(where: { id($0) == anchor }) {
            let preceding = messages.prefix(index + 1).suffix(snapshotTail.count).map(id)
            if preceding == snapshotTail { start = index + 1; verified = true }
        }
        if hasSnapshot && !verified { unreadCoverageIsLimited = true }
        var added = 0
        for message in messages.dropFirst(start) {
            let knownNew = verified || timestamp(message).map { $0 > (newestTimestamp ?? .distantPast) } == true
            guard knownNew else { continue }
            if remember(id(message)), !isOwn(message), !isConversationOpen { added += 1 }
        }
        if added > 0 { unreadCount += added }
        newestTimestamp = max(newestTimestamp ?? .distantPast,
                              messages.reduce(Date.distantPast) { max($0, timestamp($1) ?? .distantPast) })
        snapshotTail = messages.suffix(2_048).map(id)
        hasSnapshot = true
        let visible = messages.suffix(200).map(entry)
        if items != visible { items = visible }
    }

    func append(_ message: ChatEntry) {
        guard !hasSnapshot || message.sentAt > (newestTimestamp ?? .distantPast) || seenMessageIDs.contains(message.id) else { return }
        guard remember(message.id) else { return }
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
        seenMessageIDs.removeAll()
        seenOrder.removeAll()
        snapshotTail.removeAll()
        hasSnapshot = false
        newestTimestamp = nil
        unreadCoverageIsLimited = false
        items = []
        draft = ""
        unreadCount = 0
        canSend = false
        onSend = nil
        onRetry = nil
    }
}
