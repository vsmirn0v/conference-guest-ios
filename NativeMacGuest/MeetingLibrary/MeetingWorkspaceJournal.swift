import Combine
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

struct MeetingWorkspaceSession: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    let startedAt: Date
    let calendarSeriesID: String?
    let roomIdentity: String?
    var roomRuleKey: String? = nil
    var endedAt: Date?
    var interrupted = false
    var events: [MeetingWorkspaceEvent] = []

    private enum CodingKeys: String, CodingKey {
        case id, title, startedAt, endedAt, calendarSeriesID, roomIdentity, roomRuleKey, interrupted
    }
}

/// The journal commits captured content before publishing it. A dispatch reserves
/// its exact text separately from the transport's at-most-once fence. Opening the
/// archive after a process exit repairs incomplete events without replaying them.
@MainActor final class MeetingWorkspaceJournal: ObservableObject {
    @Published private(set) var sessions: [MeetingWorkspaceSession] = []
    @Published private(set) var persistenceError: String?
    private var failedObservations: [UUID: [MeetingWorkspaceEvent]] = [:]
    private let directory: URL
    private var connection: MeetingSQLiteConnection?
    private var eventsBySession: [UUID: [String: MeetingWorkspaceEvent]] = [:]

    init(root: URL) {
        directory = root.appendingPathComponent("MeetingWorkspace", isDirectory: true)
    }

    func prepare(at: Date = .now) {
        guard connection == nil, write({ _ in }) else { return }
        for entry in sessions {
            var changes = entry.events.filter { $0.status?.needsRecovery == true }
            for index in changes.indices {
                let status: MeetingWorkspaceEvent.Status = changes[index].status == .sending ? .unknown : .interrupted
                changes[index].changeStatus(status, at: at)
            }
            var session = entry
            if session.endedAt == nil {
                let lastEvent = entry.events.reduce(entry.startedAt) { max($0, $1.occurredAt, $1.statusHistory.last?.at ?? $1.occurredAt) }
                session.endedAt = lastEvent
                session.interrupted = true
                changes += entry.events.filter { $0.kind == .captureGap && $0.endedAt == nil }.map { event in
                    var event = event
                    event.endedAt = max(event.occurredAt, lastEvent)
                    return event
                }
            }
            if session.endedAt != entry.endedAt || !changes.isEmpty { commit(session: session, events: changes) }
        }
    }

    func close() { connection?.close(); connection = nil }

    func session(id: UUID) -> MeetingWorkspaceSession? { sessions.first { $0.id == id } }

    func begin(sessionID: UUID, title: String, calendarSeriesID: String?, roomIdentity: String?,
               roomRuleKey: String? = nil, at: Date = .now) {
        if connection == nil { prepare(at: at) }
        guard session(id: sessionID) == nil else { return }
        let session = MeetingWorkspaceSession(id: sessionID, title: title, startedAt: at,
            calendarSeriesID: calendarSeriesID, roomIdentity: roomIdentity, roomRuleKey: roomRuleKey, endedAt: nil)
        commit(session: session, events: [])
    }

    func rename(sessionID: UUID, title: String) {
        guard var session = session(id: sessionID), session.title != title else { return }
        session.title = title
        commit(session: session, events: [])
    }

    func end(sessionID: UUID, at: Date = .now) {
        if failedObservations[sessionID] != nil { observe(sessionID: sessionID, events: []) }
        guard var session = session(id: sessionID), session.endedAt == nil else { return }
        session.endedAt = at
        let closedGaps = session.events.filter { $0.kind == .captureGap && $0.endedAt == nil }.map { event in
            var event = event
            event.endedAt = max(event.occurredAt, at)
            return event
        }
        commit(session: session, events: closedGaps)
    }

    func delete(sessionID: UUID) throws {
        guard let session = session(id: sessionID), session.endedAt != nil else { throw JournalError.activeSession }
        let db = try database()
        try db.run("DELETE FROM workspace_sessions WHERE id=?") { try MeetingSQLiteConnection.bindText($0, sessionID.uuidString, at: 1) }
        eventsBySession[sessionID] = nil
        failedObservations[sessionID] = nil
        sessions.removeAll { $0.id == sessionID }
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    func toggleBookmark(sessionID: UUID, eventID: String) {
        guard var event = eventsBySession[sessionID]?[eventID] else { return }
        event.isBookmarked.toggle()
        store(sessionID: sessionID, events: [event])
    }

    @discardableResult func recordAction(sessionID: UUID, text: String, occurredAt: Date = .now, source: String? = nil,
        id: String = UUID().uuidString, status: MeetingWorkspaceEvent.Status? = nil, isPrivate: Bool = true,
        sourceSnapshots: [MeetingWorkspaceEvent.SourceSnapshot] = []) -> Bool {
        let key = "action:" + id
        guard eventsBySession[sessionID]?[key] == nil else { return false }
        return store(sessionID: sessionID, events: [.init(id: key, kind: .action, occurredAt: occurredAt,
            source: source, text: text, status: status, isPrivate: isPrivate, sourceSnapshots: sourceSnapshots)])
    }

    func recordGuidance(sessionID: UUID, text: String, source: String? = nil, at: Date = .now,
                        sourceSnapshots: [MeetingWorkspaceEvent.SourceSnapshot] = []) {
        store(sessionID: sessionID, events: [.init(id: "guidance:" + UUID().uuidString, kind: .privateGuidance,
            occurredAt: at, source: source, text: text, isPrivate: true, sourceSnapshots: sourceSnapshots)])
    }

    /// The source ID identifies the same caption across corrections and replays.
    /// Retain both the original and latest text, including revisions after leave.
    func observe(sessionID: UUID, events: [MeetingWorkspaceEvent]) {
        guard let current = eventsBySession[sessionID] else { return }
        let observations = (failedObservations[sessionID] ?? []) + events
        var changes: [String: MeetingWorkspaceEvent] = [:]
        for observation in observations {
            guard var previous = changes[observation.id] ?? current[observation.id] else {
                changes[observation.id] = observation
                continue
            }
            guard previous.kind == observation.kind else { continue }
            let original = previous
            if let revision = observation.revisions.last, previous.text != revision.text || previous.author != revision.author {
                previous.text = revision.text
                previous.author = revision.author
                previous.revisions.append(revision)
            }
            if let status = observation.statusHistory.last,
               previous.status != .sent || status.status == .sent {
                previous.changeStatus(status.status, at: status.at)
            }
            if previous != original { changes[observation.id] = previous }
        }
        guard !changes.isEmpty else { return }
        if store(sessionID: sessionID, events: Array(changes.values)) {
            failedObservations[sessionID] = nil
            if failedObservations.isEmpty { persistenceError = nil }
        } else {
            failedObservations[sessionID] = observations
        }
    }

    func recordGap(sessionID: UUID, id: String = UUID().uuidString, reason: String, from start: Date, until end: Date? = nil) {
        let key = "gap:" + id
        var gap = eventsBySession[sessionID]?[key] ?? .init(id: key, kind: .captureGap, occurredAt: start, source: reason)
        if let end { gap.endedAt = max(start, end) }
        store(sessionID: sessionID, events: [gap])
    }

    /// Must succeed before a public transport starts. Existing reply IDs are
    /// immutable. Repeated calls never reset a resolved attempt to queued.
    @discardableResult func recordAssistantReply(sessionID: UUID, id: String, text: String, source: String,
        status: MeetingWorkspaceEvent.Status, at: Date = .now, isPrivate: Bool = false,
        sourceSnapshots: [MeetingWorkspaceEvent.SourceSnapshot] = [], linkedChatID: String? = nil) -> Bool {
        let key = "assistant:" + id
        if var existing = eventsBySession[sessionID]?[key] {
            guard existing.text == text, existing.status == .queued,
                  status != .queued, isPrivate || status == .sending else { return false }
            if status == .sending {
                existing.isPrivate = isPrivate
                existing.linkedChatID = linkedChatID
            }
            existing.changeStatus(status, at: at)
            return store(sessionID: sessionID, events: [existing])
        }
        return store(sessionID: sessionID, events: [.init(id: key, kind: .assistantReply,
            occurredAt: at, source: source, text: text, status: status, isPrivate: isPrivate,
            sourceSnapshots: sourceSnapshots, linkedChatID: linkedChatID)])
    }

    @discardableResult func reviseHeldReply(sessionID: UUID, id: String, text: String) -> Bool {
        guard var event = eventsBySession[sessionID]?["assistant:" + id], event.status == .held,
              event.isPrivate else { return false }
        guard event.text != text else { return true }
        event.text = text
        event.revisions.append(.init(text: text, author: event.author, observedAt: .now))
        return store(sessionID: sessionID, events: [event])
    }

    @discardableResult func updateReplyStatus(sessionID: UUID, id: String, status: MeetingWorkspaceEvent.Status,
                                              at: Date = .now, isPrivate: Bool? = nil) -> Bool {
        guard var event = eventsBySession[sessionID]?["assistant:" + id] else { return false }
        guard event.status != status || (isPrivate != nil && isPrivate != event.isPrivate) else { return true }
        guard event.status != .sent, event.status != .spoken else { return false }
        event.changeStatus(status, at: at)
        if let isPrivate { event.isPrivate = isPrivate }
        return store(sessionID: sessionID, events: [event])
    }

    func observeApprovedChat(sessionID: UUID, chatID: String, status: MeetingWorkspaceEvent.Status) {
        guard let event = eventsBySession[sessionID]?.values.first(where: {
            $0.kind == .assistantReply && $0.source == "approvedChat" && $0.linkedChatID == chatID
        }) else { return }
        updateReplyStatus(sessionID: sessionID, id: String(event.id.dropFirst("assistant:".count)), status: status,
                          isPrivate: status == .cancelled ? true : nil)
    }

    @discardableResult func updateActionStatus(sessionID: UUID, id: String, status: MeetingWorkspaceEvent.Status) -> Bool {
        guard var event = eventsBySession[sessionID]?["action:" + id] else { return false }
        if event.status == status { return true }
        event.changeStatus(status, at: .now)
        return store(sessionID: sessionID, events: [event])
    }

    private func database() throws -> MeetingSQLiteConnection {
        if let connection { return connection }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let db = try MeetingSQLiteConnection(path: directory.appendingPathComponent("journal.sqlite3"))
        try db.execute("""
        PRAGMA secure_delete=ON;
        CREATE TABLE IF NOT EXISTS workspace_sessions(id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS workspace_events(
            session_id TEXT NOT NULL REFERENCES workspace_sessions(id) ON DELETE CASCADE,
            id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(session_id,id)
        );
        """)
        let decoder = JSONDecoder()
        let captured = try db.rows("SELECT session_id,payload FROM workspace_events").map {
            guard let key = $0.text(0), let id = UUID(uuidString: key),
                  case .blob(let payload)? = $0[1] else { throw JournalError.invalidData }
            return (id, try decoder.decode(MeetingWorkspaceEvent.self, from: payload))
        }
        let grouped = Dictionary(grouping: captured, by: { $0.0 })
        let loaded = try db.rows("SELECT payload FROM workspace_sessions").map {
            guard case .blob(let payload)? = $0[0] else { throw JournalError.invalidData }
            var session = try decoder.decode(MeetingWorkspaceSession.self, from: payload)
            session.events = (grouped[session.id] ?? []).map { $0.1 }.sorted(by: Self.eventOrder)
            return session
        }
        eventsBySession = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, Dictionary(uniqueKeysWithValues: $0.events.map { ($0.id, $0) })) })
        connection = db
        sessions = loaded.sorted(by: Self.sessionOrder)
        return db
    }

    private static func eventOrder(_ lhs: MeetingWorkspaceEvent, _ rhs: MeetingWorkspaceEvent) -> Bool {
        lhs.occurredAt == rhs.occurredAt ? lhs.id < rhs.id : lhs.occurredAt < rhs.occurredAt
    }

    private static func sessionOrder(_ lhs: MeetingWorkspaceSession, _ rhs: MeetingWorkspaceSession) -> Bool {
        lhs.startedAt == rhs.startedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.startedAt > rhs.startedAt
    }

    @discardableResult private func store(sessionID: UUID, events: [MeetingWorkspaceEvent]) -> Bool {
        guard !events.isEmpty, let session = session(id: sessionID) else { return false }
        return commit(session: session, events: events)
    }

    @discardableResult private func commit(session: MeetingWorkspaceSession, events: [MeetingWorkspaceEvent]) -> Bool {
        let encoder = JSONEncoder()
        let saved = write { db in
            try db.transaction {
                try db.run("INSERT INTO workspace_sessions(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload") {
                    try MeetingSQLiteConnection.bindText($0, session.id.uuidString, at: 1)
                    try MeetingSQLiteConnection.bindBlob($0, encoder.encode(session), at: 2)
                }
                for event in events {
                    try db.run("""
                    INSERT INTO workspace_events(session_id,id,payload) VALUES(?,?,?)
                    ON CONFLICT(session_id,id) DO UPDATE SET payload=excluded.payload
                    """) {
                        try MeetingSQLiteConnection.bindText($0, session.id.uuidString, at: 1)
                        try MeetingSQLiteConnection.bindText($0, event.id, at: 2)
                        try MeetingSQLiteConnection.bindBlob($0, encoder.encode(event), at: 3)
                    }
                }
            }
        }
        guard saved else { return false }
        if eventsBySession[session.id] == nil { eventsBySession[session.id] = [:] }
        for event in events { eventsBySession[session.id]?[event.id] = event }
        var session = session
        for event in events.sorted(by: Self.eventOrder) {
            var low = 0, high = session.events.count
            while low < high {
                let middle = low + (high - low) / 2
                if Self.eventOrder(session.events[middle], event) { low = middle + 1 }
                else { high = middle }
            }
            if low < session.events.count, session.events[low].id == event.id { session.events[low] = event }
            else { session.events.insert(event, at: low) }
        }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session }
        else { sessions = (sessions + [session]).sorted(by: Self.sessionOrder) }
        return true
    }

    private func write(_ operation: (MeetingSQLiteConnection) throws -> Void) -> Bool {
        do {
            try operation(database())
            if failedObservations.isEmpty { persistenceError = nil }
            return true
        } catch {
            persistenceError = error.localizedDescription
            return false
        }
    }

    enum JournalError: LocalizedError {
        case activeSession, invalidData
        var errorDescription: String? {
            switch self {
            case .activeSession: L("The meeting must end before its conversation can be deleted.")
            case .invalidData: L("The meeting conversation could not be read.")
            }
        }
    }
}
