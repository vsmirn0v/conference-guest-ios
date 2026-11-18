import Foundation

public struct MeetingWorkspaceEvent: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable {
        case transcript, captureGap, chat, assistantReply, privateGuidance, action
    }

    public enum Status: String, Codable {
        case queued, sending, sent, spoken, failed, held, cancelled, interrupted, unknown, accepted, submitted, privateOnly

        public var needsRecovery: Bool {
            self == .queued || self == .sending
        }
    }

    public struct StatusChange: Codable, Equatable {
        public let status: Status
        public let at: Date
        public init(status: Status, at: Date) { self.status = status; self.at = at }
    }

    public struct Revision: Codable, Equatable {
        public let text: String
        public let author: String?
        public let observedAt: Date
        public init(text: String, author: String?, observedAt: Date) { self.text = text; self.author = author; self.observedAt = observedAt }
    }

    public struct SourceSnapshot: Codable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let text: String?
        public let revision: String?
        public let capturedAt: Date
        public init(id: String, title: String, text: String?, revision: String?, capturedAt: Date) {
            self.id = id; self.title = title; self.text = text; self.revision = revision; self.capturedAt = capturedAt
        }
    }

    public let id: String
    public let kind: Kind
    public let occurredAt: Date
    public let source: String?
    private var observedTime: Bool?
    public var timeIsObserved: Bool { observedTime == true }
    public var isPrivate: Bool
    public var linkedChatID: String?
    public var author: String?
    public var text: String?
    public var endedAt: Date?
    public var revisions: [Revision]
    public var statusHistory: [StatusChange]
    public let sourceSnapshots: [SourceSnapshot]
    public var isBookmarked = false
    public var status: Status? { statusHistory.last?.status }

    public init(id: String, kind: Kind, occurredAt: Date, observedAt: Date? = nil, source: String? = nil,
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

    public mutating func changeStatus(_ status: Status, at: Date) {
        guard self.status != status else { return }
        statusHistory.append(.init(status: status, at: at))
    }
}
