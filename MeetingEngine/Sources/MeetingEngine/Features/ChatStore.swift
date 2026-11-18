import Combine
import ConferenceCore
import Foundation

public struct ChatEntry: Equatable, Identifiable {
    public let id: String
    public let sender: String
    public let text: String
    public let sentAt: Date
    public let isOwn: Bool
    public var delivery: ChatDelivery = .sent

    public init(id: String, sender: String, text: String, sentAt: Date, isOwn: Bool, delivery: ChatDelivery = .sent) {
        self.id = id
        self.sender = sender
        self.text = text
        self.sentAt = sentAt
        self.isOwn = isOwn
        self.delivery = delivery
    }
}

public enum ChatDelivery: Equatable {
    case pending, sent, failed
}

@MainActor
public final class ChatStore: ObservableObject {
    public let reactionHistory = ReactionHistoryStore()
    @Published public var reactionHistoryAvailable = false
    @Published public private(set) var items: [ChatEntry] = []
    @Published public var canSend = false
    @Published public var unavailableReason: String?
    public var isReadOnly = false
    @Published public var draft = ""
    @Published public private(set) var unreadCount = 0
    private var seenMessageIDs = Set<String>()
    private var seenOrder: [String] = []
    private var snapshotTail: [String] = []
    private var hasSnapshot = false
    private var newestTimestamp: Date?
    @Published public private(set) var unreadCoverageIsLimited = false
    #if DEBUG
    public var retainedIdentityCount: Int { seenMessageIDs.count }
    #endif

    public init() {}

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
    public var isConversationOpen = false {
        didSet { if isConversationOpen { unreadCount = 0 } }
    }
    public var onSend: ((String) -> Void)?
    public var onRetry: ((ChatEntry) -> Void)?
    /// Optional capture before the visible chat window trims or replaces rows.
    public var onCapture: (([ChatEntry]) -> Void)?

    public func send(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let onSend, RoomChatPacket.accepts(text: clean) else { return false }
        onSend(clean)
        return true
    }

    /// Provider snapshots are ordered. An anchor establishes the new suffix;
    /// after reordering/truncation, only provably newer timestamps count as unread.
    public func replace(_ messages: [ChatEntry]) {
        replaceSnapshot(messages, id: { $0.id }, timestamp: { $0.sentAt }, isOwn: { $0.isOwn }, entry: { $0 })
    }

    public func replaceSnapshot<Message>(_ messages: [Message], id: (Message) -> String,
                                  timestamp: (Message) -> Date?, isOwn: (Message) -> Bool,
                                  entry: (Message) -> ChatEntry) {
        // Empty initial/reconnect snapshots establish no cursor. Keep the last
        // nonempty anchor so reconnect replay cannot be counted as fresh chat.
        guard !messages.isEmpty else {
            if !items.isEmpty { items = [] }
            return
        }
        if let onCapture { onCapture(messages.map(entry)) }
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

    public func append(_ message: ChatEntry) {
        onCapture?([message])
        guard !hasSnapshot || message.sentAt > (newestTimestamp ?? .distantPast) || seenMessageIDs.contains(message.id) else { return }
        guard remember(message.id) else { return }
        if !message.isOwn && !isConversationOpen { unreadCount += 1 }
        items.append(message)
        if items.count > 200 { items.removeFirst(items.count - 200) }
    }

    public func setDelivery(_ delivery: ChatDelivery, for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].delivery = delivery
        onCapture?([items[index]])
    }

    public func retry(_ id: String) {
        guard canSend, let onRetry,
              let entry = items.first(where: { $0.id == id && $0.delivery == .failed }) else { return }
        setDelivery(.pending, for: id)
        onRetry(entry)
    }

    public func clear() {
        reactionHistory.endMeeting(); reactionHistoryAvailable = false
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
        unavailableReason = nil
        isReadOnly = false
        onSend = nil
        onRetry = nil
    }
}
