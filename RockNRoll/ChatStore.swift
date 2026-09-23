import Combine
import Foundation

struct ChatEntry: Equatable, Identifiable {
    let id: String
    let sender: String
    let text: String
    let sentAt: Date
    let isOwn: Bool
}

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var items: [ChatEntry] = []
    @Published var canSend = false
    var onSend: ((String) -> Void)?

    func send(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !clean.isEmpty, clean.count <= 2_000 else { return false }
        onSend?(clean)
        return true
    }

    func replace(_ messages: [ChatEntry]) {
        items = Array(messages.suffix(200))
    }

    func append(_ message: ChatEntry) {
        guard !items.contains(where: { $0.id == message.id }) else { return }
        items.append(message)
        if items.count > 200 { items.removeFirst(items.count - 200) }
    }

    func clear() {
        items = []
        canSend = false
        onSend = nil
    }
}
