import Foundation

struct MeetingWorkspaceEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case transcript, captureGap, chat, assistantReply, privateGuidance, action
    }

    enum Status: String, Codable {
        case queued, sending, sent, spoken, failed, held, cancelled, interrupted, unknown, accepted, submitted, privateOnly

        var needsRecovery: Bool {
            self == .queued || self == .sending
        }
    }

    struct StatusChange: Codable, Equatable {
        let status: Status
        let at: Date
    }

    struct Revision: Codable, Equatable {
        let text: String
        let author: String?
        let observedAt: Date
    }

    struct SourceSnapshot: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let text: String?
        let revision: String?
        let capturedAt: Date
    }

    let id: String
    let kind: Kind
    let occurredAt: Date
    let source: String?
    private var observedTime: Bool?
    var timeIsObserved: Bool { observedTime == true }
    var isPrivate: Bool
    var linkedChatID: String?
    var author: String?
    var text: String?
    var endedAt: Date?
    var revisions: [Revision]
    var statusHistory: [StatusChange]
    let sourceSnapshots: [SourceSnapshot]
    var isBookmarked = false
    var status: Status? { statusHistory.last?.status }

    init(id: String, kind: Kind, occurredAt: Date, observedAt: Date? = nil, source: String? = nil,
         author: String? = nil, text: String? = nil, status: Status? = nil, isPrivate: Bool = false,
         sourceSnapshots: [SourceSnapshot] = [], linkedChatID: String? = nil, timeIsObserved: Bool = false) {
        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
        self.source = source
        observedTime = timeIsObserved ? true : nil
        self.isPrivate = isPrivate
        self.author = author
        self.text = text
        self.linkedChatID = linkedChatID
        self.sourceSnapshots = sourceSnapshots
        let observedAt = observedAt ?? occurredAt
        revisions = text.map { [.init(text: $0, author: author, observedAt: observedAt)] } ?? []
        statusHistory = status.map { [.init(status: $0, at: observedAt)] } ?? []
    }

    mutating func changeStatus(_ status: Status, at: Date) {
        guard self.status != status else { return }
        statusHistory.append(.init(status: status, at: at))
    }
}
