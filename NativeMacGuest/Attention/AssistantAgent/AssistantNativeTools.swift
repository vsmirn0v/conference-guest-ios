import ConferenceCore
import Foundation

struct AssistantTextLine: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var speaker: String
    var text: String
    var at: Date?
}

struct AssistantMeetingRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var active: Bool
    var roomIdentity: String
    var invitationSummary: String
    var seriesID: String?
    var displayName: String
    var participants: [String]
    var transcript: [AssistantTextLine]
    var chat: [AssistantTextLine]
    var transcriptCoverage: String
    var canSendChat: Bool
    var canReact: Bool
    var supportsVoiceReply: Bool
    var microphoneOn: Bool
    var soundOn: Bool
    var outcomeID: UUID?
}

struct AssistantTaskRecord: Codable, Equatable, Sendable {
    var text: String
    var owner: String
    var dueAt: Date?
    var done: Bool
}

struct AssistantOutcomeRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var meetingID: UUID?
    var title: String
    var roomIdentity: String
    var seriesID: String?
    var endedAt: Date
    var summary: String
    var decisions: [String]
    var tasks: [AssistantTaskRecord]
    var openQuestions: [String]
}

/// Note metadata for one meeting. The full note is read only through the
/// `rocknroll_get_notes` tool so long notes never bloat every turn.
struct AssistantNoteRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var meetingID: UUID
    var meetingTitle: String
    var revision: Int
    var updatedAt: Date
    /// Bounded excerpt; the tool returns the complete raw Markdown.
    var preview: String
}

struct AssistantMomentRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var meetingID: UUID?
    var title: String
    var reason: String
    var createdAt: Date
    var state: String
}

struct AssistantCalendarOccurrence: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var seriesID: String
    var calendarID: String
    var calendarTitle: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var roomIdentity: String
}

struct AssistantMemoryRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: String
    var text: String
    var updatedAt: Date
}

struct AssistantActionTarget: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var invitation: URL?
    var active: Bool
    var meetingID: UUID?
}

/// A serializable, per-turn snapshot of native authority. Tools never receive live domain
/// objects or credentials, and stale typed IDs fail closed during validation.
struct AssistantNativeSnapshot: Codable, Equatable, Sendable {
    var now: Date
    var timeZoneIdentifier: String
    var language: String
    var contextMeetingID: UUID?
    var profileNames: [String]
    var meetings: [AssistantMeetingRecord]
    var outcomes: [AssistantOutcomeRecord]
    var notes: [AssistantNoteRecord]
    var moments: [AssistantMomentRecord]
    var memories: [AssistantMemoryRecord]
    var calendar: [AssistantCalendarOccurrence]
    var actionTargets: [AssistantActionTarget]
    var settings: [String: String]
}

/// Resolves only the explicitly selected active meeting. Other titles and ambiguous targets
/// remain invalid; no title-based guessing is allowed for outward actions.
private func assistantResolvedMeetingArguments(_ arguments: AssistantJSON,
                                               snapshot: AssistantNativeSnapshot,
                                               defaultWhenMissing: Bool) -> AssistantJSON {
    guard case .object(var object) = arguments else { return arguments }
    // Only an absent/empty string or the exact selected title is canonicalizable. A wrong
    // JSON type must still reach the generic validator and produce a useful correction result.
    if let supplied = object["meeting_id"], supplied.stringValue == nil { return arguments }
    let raw = object["meeting_id"]?.stringValue?.trimmed
    guard raw == nil || raw?.isEmpty == true || UUID(uuidString: raw ?? "") == nil,
          let selectedID = snapshot.contextMeetingID,
          let selected = snapshot.meetings.first(where: { $0.id == selectedID && $0.active }) else {
        return arguments
    }
    let normalized = { (value: String) in
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmed
    }
    if (defaultWhenMissing && (raw == nil || raw?.isEmpty == true)) ||
        (raw.map { normalized($0) == normalized(selected.title) } == true) {
        object["meeting_id"] = .string(selectedID.uuidString)
        return .object(object)
    }
    return arguments
}

private struct AssistantClosureTool: AssistantAgentTool {
    let descriptor: AssistantAgentToolDescriptor
    let validator: @Sendable (AssistantJSON) throws -> AssistantJSON
    let body: @Sendable (AssistantAgentToolCall, AssistantJSON) async throws -> AssistantAgentToolResult

    func validate(_ arguments: AssistantJSON) throws -> AssistantJSON { try validator(arguments) }

    func execute(_ call: AssistantAgentToolCall, arguments: AssistantJSON) async throws -> AssistantAgentToolResult {
        try await body(call, arguments)
    }
}

private struct AssistantNativeActionTool: AssistantAgentActionTool {
    let descriptor: AssistantAgentToolDescriptor
    let snapshot: AssistantNativeSnapshot
    let executor: @Sendable (AssistantCanonicalAction) async throws -> String

    func validate(_ arguments: AssistantJSON) throws -> AssistantJSON {
        guard descriptor.arguments.contains(where: { $0.name == "meeting_id" }) else { return arguments }
        return assistantResolvedMeetingArguments(arguments, snapshot: snapshot, defaultWhenMissing: true)
    }

    func execute(_ call: AssistantAgentToolCall, arguments: AssistantJSON) async throws -> AssistantAgentToolResult {
        let action = try canonicalAction(for: call, arguments: arguments)
        let summary = try await executor(action)
        return .init(callID: call.id, toolName: call.name, json: .object(["applied": .bool(true)]),
                     summary: summary)
    }

    func canonicalAction(for call: AssistantAgentToolCall, arguments: AssistantJSON) throws -> AssistantCanonicalAction {
        let kind = AssistantCanonicalActionKind(rawValue: String(descriptor.name.dropFirst("rocknroll_".count))) ?? .sendChat
        let targetID = arguments["meeting_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let target = targetID.flatMap { id in snapshot.actionTargets.first { $0.id == id } }
        let meetingID = target.flatMap { $0.active ? $0.id : nil }
        switch kind {
        case .setAttention:
            guard let mode = AttentionMode(rawValue: arguments["mode"]?.stringValue ?? "") else {
                throw AssistantAgentError.missingArgument(descriptor.name, "mode")
            }
            return .init(kind: kind, meetingID: meetingID, mode: mode,
                         scope: AssistantCommandScope(rawValue: arguments["scope"]?.stringValue ?? "") ?? .untilLeave)
        case .join:
            guard let target else { throw AssistantAgentError.unknownMeeting(targetID?.uuidString ?? "none") }
            return .init(kind: kind, meetingID: target.id)
        case .leave, .mute:
            guard let target, target.active == true else { throw AssistantAgentError.unknownMeeting(targetID?.uuidString ?? "none") }
            return .init(kind: kind, meetingID: target.id)
        case .sendChat, .say:
            guard let target, target.active == true else {
                throw AssistantAgentError.unknownMeeting(arguments["meeting_id"]?.stringValue ?? "missing")
            }
            guard let text = arguments["text"]?.stringValue?.trimmed, !text.isEmpty else {
                throw AssistantAgentError.missingArgument(descriptor.name, "text")
            }
            return .init(kind: kind, meetingID: target.id, text: String(text.prefix(1000)))
        case .react:
            guard let target, target.active == true else {
                throw AssistantAgentError.unknownMeeting(arguments["meeting_id"]?.stringValue ?? "missing")
            }
            guard let reaction = MeetingReaction(rawValue: arguments["reaction"]?.stringValue ?? "") else {
                throw AssistantAgentError.missingArgument(descriptor.name, "reaction")
            }
            return .init(kind: kind, meetingID: target.id, reaction: reaction)
        case .remind:
            guard let momentID = arguments["moment_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  snapshot.moments.contains(where: { $0.id == momentID }),
                  let at = arguments["at"]?.stringValue.flatMap(AssistantTime.parse) else {
                throw AssistantAgentError.missingArgument(descriptor.name, "moment_id or at")
            }
            guard at > snapshot.now else { throw AssistantCommandError.pastReminder }
            return .init(kind: kind, momentID: momentID, at: at)
        case .remember:
            guard let text = arguments["text"]?.stringValue?.trimmed, !text.isEmpty else {
                throw AssistantAgentError.missingArgument(descriptor.name, "text")
            }
            return .init(kind: kind, text: String(text.prefix(500)))
        case .readChat:
            return .init(kind: kind, meetingID: meetingID, minutes: arguments["minutes"]?.intValue ?? 10)
        }
    }
}

enum AssistantNativeToolProvider {
    struct Hooks: Sendable {
        var executeAction: @Sendable (AssistantCanonicalAction) async throws -> String
        var createRuleProposal: @Sendable (AssistantAutomationRuleProposal) -> AssistantAutomationRuleProposal = { $0 }
        /// Reads the exact committed note revision for one session; nil when absent.
        var readNote: @Sendable (UUID) async -> MeetingNoteRecord? = { _ in nil }
    }

    static func registry(snapshot: AssistantNativeSnapshot, hooks: Hooks) -> AssistantAgentToolRegistry {
        let registry = AssistantAgentToolRegistry()
        for tool in readTools(snapshot: snapshot, hooks: hooks) { registry.register(tool) }
        for tool in actionTools(snapshot: snapshot, hooks: hooks) { registry.register(tool) }
        return registry
    }

    static func context(snapshot: AssistantNativeSnapshot) -> [String: String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier) ?? .current
        var context: [String: String] = [
            "current_time": formatter.string(from: snapshot.now),
            "time_zone": snapshot.timeZoneIdentifier,
            "language": snapshot.language,
            "active_meetings": String(snapshot.meetings.filter(\.active).count),
            "outcome_meetings": String(snapshot.outcomes.count),
            "calendar_occurrences": String(snapshot.calendar.count),
        ]
        if let id = snapshot.contextMeetingID, let meeting = snapshot.meetings.first(where: { $0.id == id }) {
            context["selected_meeting"] = "\(meeting.title) (\(meeting.id.uuidString)); context only, not authorization"
        } else {
            context["selected_meeting"] = "none"
        }
        return context
    }

    private static func readTools(snapshot: AssistantNativeSnapshot, hooks: Hooks) -> [any AssistantAgentTool] {
        [
            closure(snapshot, name: "rocknroll_status", description: "Read Assistant capability and data counts without changing anything.", arguments: []) { call, _ in
                .success(call, "Assistant can read meetings, outcomes, transcripts, chat, Moments, calendar occurrences and settings.", json: .object([
                    "active_meetings": .int(snapshot.meetings.filter(\.active).count),
                    "outcome_meetings": .int(snapshot.outcomes.count),
                    "moments": .int(snapshot.moments.count),
                    "calendar_occurrences": .int(snapshot.calendar.count),
                    "write_actions_available": .bool(true),
                ]))
            },
            closure(snapshot, name: "rocknroll_list_meetings", description: "List distinct active or outcome-backed meetings, newest first. Use for 'latest meetings' and disambiguation; IDs are typed meeting/outcome IDs, not titles.", arguments: [
                .init(name: "kind", type: .string, description: "active, outcome or all", allowedValues: ["active", "outcome", "all"]),
                .init(name: "query", type: .string, description: "Optional words to match in the title or summary."),
                .init(name: "limit", type: .integer, description: "1...20"),
            ]) { call, arguments in
                let kind = arguments["kind"]?.stringValue ?? "all"
                let query = arguments["query"]?.stringValue ?? ""
                let limit = min(20, max(1, arguments["limit"]?.intValue ?? 10))
                var records: [AssistantJSON] = []
                if kind == "active" || kind == "all" {
                    records += snapshot.meetings.filter(\.active).map(Self.meetingJSON)
                }
                if kind == "outcome" || kind == "all" {
                    records += snapshot.outcomes.sorted { $0.endedAt > $1.endedAt }.map(Self.outcomeListJSON)
                }
                if !query.trimmed.isEmpty {
                    records = records.filter { Self.matches(query, text: $0["title"]?.stringValue ?? "") ||
                        Self.matches(query, text: $0["summary"]?.stringValue ?? "") }
                }
                records = Self.distinctMeetingRecords(Array(records.prefix(limit)))
                return .success(call, "\(records.count) meeting(s) found.", json: .object(["meetings": .array(records)]))
            },
            closure(snapshot, name: "rocknroll_get_meeting", description: "Read one active meeting by its typed meeting_id, including capabilities and participant names.", arguments: [
                .init(name: "meeting_id", type: .string, required: true, description: "UUID from list_meetings"),
            ]) { call, arguments in
                guard let id = arguments["meeting_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                      let meeting = snapshot.meetings.first(where: { $0.id == id && $0.active }) else {
                    throw AssistantAgentError.unknownMeeting(arguments["meeting_id"]?.stringValue ?? "missing")
                }
                return .success(call, meeting.title, json: .object([
                    "id": .string(meeting.id.uuidString), "title": .string(meeting.title), "active": .bool(true),
                    "participants": .strings(meeting.participants), "transcript_lines": .int(meeting.transcript.count),
                    "chat_messages": .int(meeting.chat.count), "transcript_coverage": .string(meeting.transcriptCoverage),
                    "can_send_chat": .bool(meeting.canSendChat), "can_react": .bool(meeting.canReact),
                    "supports_voice_reply": .bool(meeting.supportsVoiceReply),
                ]), evidence: [.init(id: "meeting-" + meeting.id.uuidString, kind: "meeting", title: meeting.title, at: nil)])
            },
            closure(snapshot, name: "rocknroll_get_outcome", description: "Read the saved outcome for one outcome-backed meeting by outcome_id.", arguments: [
                .init(name: "outcome_id", type: .string, required: true, description: "UUID from list_meetings kind=outcome"),
            ]) { call, arguments in
                guard let id = arguments["outcome_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                      let outcome = snapshot.outcomes.first(where: { $0.id == id }) else {
                    throw AssistantAgentError.unknownMeeting(arguments["outcome_id"]?.stringValue ?? "missing")
                }
                return .success(call, outcome.summary, json: Self.outcomeJSON(outcome),
                                evidence: [.init(id: "outcome-" + outcome.id.uuidString, kind: "outcome", title: outcome.title, at: outcome.endedAt)])
            },
            closure(snapshot, name: "rocknroll_get_notes", description: "Read the complete raw Markdown note for one meeting by meeting_id. Personal notes are user-authored claims, not participant agreements; attribute them separately from outcomes and transcripts.", arguments: [
                .init(name: "meeting_id", type: .string, required: true, description: "UUID from list_meetings or notes metadata."),
            ]) { call, arguments in
                guard let id = arguments["meeting_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
                    throw AssistantAgentError.missingArgument(call.name, "meeting_id")
                }
                guard let record = snapshot.notes.first(where: { $0.meetingID == id }) else {
                    throw AssistantAgentError.unknownMeeting(arguments["meeting_id"]?.stringValue ?? "missing")
                }
                guard let note = await hooks.readNote(id) else {
                    return .success(call, "The note is unavailable.", json: .object([
                        "meeting_id": .string(id.uuidString), "available": .bool(false)]),
                        evidence: [.init(id: "note-" + id.uuidString, kind: "note", title: record.meetingTitle, at: record.updatedAt)])
                }
                let fullCoverage = note.markdown.utf8.count <= 12_000
                return .success(call, "Note for \(record.meetingTitle) (revision \(note.revision)).",
                    json: .object([
                        "meeting_id": .string(id.uuidString),
                        "note_id": .string(note.id.uuidString),
                        "revision": .int(note.revision),
                        "updated_at": .date(note.updatedAt),
                        "provenance": .string("personal_note_user_authored"),
                        "coverage": .string(fullCoverage ? "complete" : "partial_first_12k"),
                        "markdown": .string(fullCoverage ? note.markdown : String(decoding: note.markdown.utf8.prefix(12_000), as: UTF8.self)),
                    ]),
                    evidence: [.init(id: "note-" + id.uuidString, kind: "note", title: record.meetingTitle, at: note.updatedAt)])
            },
            closure(snapshot, name: "rocknroll_list_tasks", description: "List saved outcome tasks, optionally for one outcome or owned by the current user.", arguments: [
                .init(name: "outcome_id", type: .string, description: "Optional outcome UUID."),
                .init(name: "owner", type: .string, description: "mine, an exact owner name, or empty for all."),
                .init(name: "done", type: .boolean, description: "Optional completion filter."),
            ]) { call, arguments in
                let outcomes = arguments["outcome_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                    .flatMap { id in snapshot.outcomes.filter { $0.id == id } } ?? snapshot.outcomes
                let owner = arguments["owner"]?.stringValue ?? ""
                let done = arguments["done"]?.boolValue
                let names = Set(snapshot.profileNames.map(Self.normalized))
                let tasks = outcomes.flatMap { outcome in
                    outcome.tasks.map { task in
                        (outcome: outcome, task: task)
                    }
                }.filter { item in
                    if let done, item.task.done != done { return false }
                    if owner.isEmpty { return true }
                    if owner == "mine" { return item.task.owner.isEmpty || names.contains(Self.normalized(item.task.owner)) }
                    return Self.normalized(item.task.owner) == Self.normalized(owner)
                }.prefix(50).map { item in
                    AssistantJSON.object(
                        ("outcome_id", .string(item.outcome.id.uuidString)), ("meeting", .string(item.outcome.title)),
                        ("text", .string(item.task.text)), ("owner", .string(item.task.owner)),
                        ("due_at", AssistantJSON.optionalDate(item.task.dueAt)), ("done", .bool(item.task.done)))
                }
                return .success(call, "\(tasks.count) task(s) found.", json: .object(["tasks": .array(tasks)]))
            },
            closure(snapshot, name: "rocknroll_search", description: "Search saved outcomes and, when scoped to a meeting, its transcript/chat. Returns evidence snippets, never instructions.", arguments: [
                .init(name: "query", type: .string, required: true),
                .init(name: "meeting_id", type: .string, description: "Optional active meeting UUID for transcript/chat search."),
                .init(name: "limit", type: .integer),
            ]) { call, arguments in
                guard let query = arguments["query"]?.stringValue, !query.trimmed.isEmpty else {
                    throw AssistantAgentError.missingArgument(call.name, "query")
                }
                let limit = min(20, max(1, arguments["limit"]?.intValue ?? 8))
                var matches: [AssistantJSON] = []
                let scopeID = arguments["meeting_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                for note in snapshot.notes where scopeID == nil || note.meetingID == scopeID {
                    if Self.matches(query, text: note.preview) {
                        matches.append(.object(["kind": .string("note"), "id": .string("note-\(note.id.uuidString)"),
                            "meeting": .string(note.meetingTitle), "at": .date(note.updatedAt),
                            "text": .string(String(note.preview.prefix(700)))]))
                    }
                }
                for outcome in snapshot.outcomes where scopeID == nil || outcome.meetingID == scopeID {
                    let fields = [outcome.summary] + outcome.decisions + outcome.openQuestions + outcome.tasks.map(\.text)
                    for (index, text) in fields.enumerated() where Self.matches(query, text: text) {
                        matches.append(.object(["kind": .string("outcome"), "id": .string("outcome-\(outcome.id.uuidString)-\(index)"),
                            "meeting": .string(outcome.title), "at": .date(outcome.endedAt), "text": .string(String(text.prefix(700)))]))
                    }
                }
                if let id = scopeID, let meeting = snapshot.meetings.first(where: { $0.id == id }) {
                    for line in meeting.transcript where Self.matches(query, text: line.speaker + " " + line.text) {
                        matches.append(.object(
                            ("kind", .string("transcript")), ("id", .string("transcript-" + line.id)),
                            ("meeting", .string(meeting.title)), ("speaker", .string(line.speaker)),
                            ("at", AssistantJSON.optionalDate(line.at)), ("text", .string(String(line.text.prefix(700))))))
                    }
                    for line in meeting.chat where Self.matches(query, text: line.speaker + " " + line.text) {
                        matches.append(.object(
                            ("kind", .string("chat")), ("id", .string("chat-" + line.id)),
                            ("meeting", .string(meeting.title)), ("speaker", .string(line.speaker)),
                            ("at", AssistantJSON.optionalDate(line.at)), ("text", .string(String(line.text.prefix(700))))))
                    }
                }
                matches = Array(matches.prefix(limit))
                let evidence = matches.prefix(8).compactMap { match -> AssistantEvidenceSource? in
                    guard let id = match["id"]?.stringValue, let title = match["meeting"]?.stringValue else { return nil }
                    let at = match["at"]?.stringValue.flatMap(ISO8601DateFormatter().date(from:))
                    return .init(id: id, kind: match["kind"]?.stringValue ?? "source", title: title, at: at)
                }
                return .success(call, matches.isEmpty ? "No matching evidence was found." : "\(matches.count) matching evidence item(s).",
                                json: .object(["matches": .array(matches)]), evidence: evidence)
            },
            closure(snapshot, name: "rocknroll_get_transcript", description: "Read bounded transcript lines for one active meeting. The result states its actual coverage.", arguments: [
                .init(name: "meeting_id", type: .string, required: true),
                .init(name: "after", type: .string, description: "Optional ISO 8601 lower bound."),
                .init(name: "limit", type: .integer, description: "1...200"),
            ]) { call, arguments in
                guard let id = arguments["meeting_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                      let meeting = snapshot.meetings.first(where: { $0.id == id && $0.active }) else {
                    throw AssistantAgentError.unknownMeeting(arguments["meeting_id"]?.stringValue ?? "missing")
                }
                let after = arguments["after"]?.stringValue.flatMap(AssistantTime.parse) ?? .distantPast
                let limit = min(200, max(1, arguments["limit"]?.intValue ?? 100))
                let lines = meeting.transcript.filter { ($0.at ?? .distantPast) >= after }.suffix(limit).map(Self.lineJSON)
                return .success(call, "\(lines.count) transcript line(s), coverage: \(meeting.transcriptCoverage).",
                    json: .object(["meeting_id": .string(id.uuidString), "coverage": .string(meeting.transcriptCoverage),
                                   "lines": .array(lines)]),
                    evidence: [.init(id: "transcript-" + id.uuidString, kind: "transcript", title: meeting.title, at: nil)])
            },
            closure(snapshot, name: "rocknroll_read_chat", description: "Read bounded chat messages for one active meeting.", arguments: [
                .init(name: "meeting_id", type: .string, required: true),
                .init(name: "limit", type: .integer, description: "1...100"),
            ]) { call, arguments in
                guard let id = arguments["meeting_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                      let meeting = snapshot.meetings.first(where: { $0.id == id && $0.active }) else {
                    throw AssistantAgentError.unknownMeeting(arguments["meeting_id"]?.stringValue ?? "missing")
                }
                let limit = min(100, max(1, arguments["limit"]?.intValue ?? 30))
                let lines = meeting.chat.suffix(limit).map(Self.lineJSON)
                return .success(call, "\(lines.count) chat message(s).", json: .object(["lines": .array(lines)]),
                                evidence: [.init(id: "chat-" + id.uuidString, kind: "chat", title: meeting.title, at: nil)])
            },
            closure(snapshot, name: "rocknroll_list_moments", description: "Read recent Assistant Moments with meeting and reason.", arguments: [
                .init(name: "limit", type: .integer, description: "1...20"),
            ]) { call, arguments in
                let limit = min(20, max(1, arguments["limit"]?.intValue ?? 10))
                let moments = snapshot.moments.sorted { $0.createdAt > $1.createdAt }.prefix(limit).map { moment in
                    AssistantJSON.object(["id": .string(moment.id.uuidString), "meeting": .string(moment.title),
                                          "reason": .string(moment.reason), "state": .string(moment.state),
                                          "at": .date(moment.createdAt)])
                }
                return .success(call, "\(moments.count) Moment(s).", json: .object(["moments": .array(moments)]))
            },
            closure(snapshot, name: "rocknroll_search_memory", description: "Read bounded explicit long-term memory excerpts. Use only when personal memory is relevant; never use this tool to answer a historical-meeting question.", arguments: [
                .init(name: "query", type: .string, required: true),
                .init(name: "limit", type: .integer),
            ]) { call, arguments in
                guard let query = arguments["query"]?.stringValue else { throw AssistantAgentError.missingArgument(call.name, "query") }
                let limit = min(10, max(1, arguments["limit"]?.intValue ?? 5))
                let words = Self.tokens(query)
                let matches = snapshot.memories.filter { item in
                    !words.isDisjoint(with: Self.tokens(item.text)) || Self.matches(query, text: item.text)
                }.prefix(limit).map { item in
                    AssistantJSON.object(["id": .string("memory-" + item.id.uuidString), "kind": .string(item.kind),
                                          "text": .string(String(item.text.prefix(500))), "updated_at": .date(item.updatedAt)])
                }
                return .success(call, "\(matches.count) memory excerpt(s).", json: .object(["matches": .array(matches)]))
            },
            closure(snapshot, name: "rocknroll_list_calendar_occurrences", description: "Query future native calendar occurrences. Returns occurrence/series/calendar IDs and provenance; never join or edit an event.", arguments: [
                .init(name: "after", type: .string, required: true, description: "ISO 8601 instant; normally the supplied current time."),
                .init(name: "before", type: .string, description: "Optional ISO 8601 upper bound."),
                .init(name: "query", type: .string, description: "Optional series or title words such as daily."),
                .init(name: "limit", type: .integer, description: "1...20"),
            ]) { call, arguments in
                guard let afterText = arguments["after"]?.stringValue,
                      let after = AssistantTime.parse(afterText) else { throw AssistantAgentError.missingArgument(call.name, "after") }
                let before = arguments["before"]?.stringValue.flatMap(AssistantTime.parse) ?? after.addingTimeInterval(45 * 86400)
                let query = arguments["query"]?.stringValue ?? ""
                let limit = min(20, max(1, arguments["limit"]?.intValue ?? 10))
                let matches = snapshot.calendar.filter { occurrence in
                    occurrence.start >= after && occurrence.start <= before &&
                    (query.trimmed.isEmpty || Self.matches(query, text: occurrence.title))
                }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }.prefix(limit).map(Self.calendarJSON)
                let next = matches.first?["start"]?.stringValue ?? "none"
                return .success(call, "\(matches.count) future occurrence(s); next starts \(next).",
                                json: .object(["occurrences": .array(matches)]))
            },
            closure(snapshot, name: "rocknroll_get_settings", description: "Read allowlisted effective Assistant settings when a question requires them. Keys and values only; no credentials.", arguments: [
                .init(name: "keys", type: .array, required: true, description: "Allowlisted keys."),
            ]) { call, arguments in
                let allowed = Set(["voice_engine", "talk_back", "provider_host", "outcomes_enabled", "push_to_talk"])
                guard let keys = arguments["keys"]?.arrayValue else { throw AssistantAgentError.missingArgument(call.name, "keys") }
                var object: [String: AssistantJSON] = [:]
                for key in keys {
                    guard let name = key.stringValue, allowed.contains(name) else {
                        return .error(call, AssistantAgentError.invalidArguments(call.name, "unsupported setting key").localizedDescription ?? "unsupported setting key")
                    }
                    object[name] = .string(snapshot.settings[name] ?? "unavailable")
                }
                return .success(call, "Settings read.", json: .object(object))
            },
            closure(snapshot, name: "rocknroll_propose_automation_rule", description: "Convert a persistent standing instruction into a reviewable native rule proposal. This tool only proposes; enabling never happens here and creates no voice or chat action.", arguments: [
                .init(name: "trigger", type: .string, required: true, allowedValues: ["mentionOfCurrentUser"]),
                .init(name: "scope", type: .string, required: true, allowedValues: ["allEligibleCurrentAndFutureMeetings"]),
                .init(name: "action", type: .string, required: true, allowedValues: ["voiceReply"]),
                .init(name: "text", type: .string, required: true, description: "Exact outward reply text."),
                .init(name: "voice_id", type: .string, required: true),
                .init(name: "cooldown_seconds", type: .integer, required: true, description: "30...3600"),
            ]) { call, arguments in
                guard let trigger = AssistantAutomationRuleProposal.Trigger(rawValue: arguments["trigger"]?.stringValue ?? ""),
                      let scope = AssistantAutomationRuleProposal.Scope(rawValue: arguments["scope"]?.stringValue ?? ""),
                      let action = AssistantAutomationRuleProposal.Action(rawValue: arguments["action"]?.stringValue ?? ""),
                      let text = arguments["text"]?.stringValue?.trimmed, !text.isEmpty,
                      let voiceID = arguments["voice_id"]?.stringValue?.trimmed, !voiceID.isEmpty else {
                    throw AssistantAgentError.missingArgument(call.name, "valid rule fields")
                }
                let cooldown = TimeInterval(arguments["cooldown_seconds"]?.intValue ?? 300)
                guard (30...3600).contains(cooldown) else { throw AssistantAgentError.invalidArguments(call.name, "cooldown_seconds") }
                var proposal = AssistantAutomationRuleProposal(trigger: trigger, scope: scope, action: action,
                                                               text: text, voiceID: voiceID, cooldownSeconds: cooldown,
                                                               execution: .askEachTime)
                proposal = hooks.createRuleProposal(proposal)
                return .init(callID: call.id, toolName: call.name,
                             json: .object(["proposal_id": .string(proposal.id.uuidString), "revision": .int(proposal.revision),
                                            "execution": .string(proposal.execution.rawValue)]),
                             summary: L("Review the automation rule before it can run."), ruleProposal: proposal)
            },
        ]
    }

    private static func actionTools(snapshot: AssistantNativeSnapshot, hooks: Hooks) -> [any AssistantAgentTool] {
        let targetArgument = AssistantArgumentSpec(name: "meeting_id", type: .string, required: true,
                                                   description: "Typed active meeting ID; join may use a listed historical target ID.")
        // Direct sends to the selected meeting are action-first: meeting_id may be omitted
        // and the app binds the exact selected active meeting. Everything else stays strict.
        let selectedSendArgument = AssistantArgumentSpec(name: "meeting_id", type: .string, required: false,
                                                         description: "Optional typed active meeting ID; omit for the selected meeting.")
        let textArgument = AssistantArgumentSpec(name: "text", type: .string, required: true, description: "Exact outward text.")
        func descriptor(_ name: String, _ description: String, arguments: [AssistantArgumentSpec] = []) -> AssistantAgentToolDescriptor {
            .init(name: "rocknroll_" + name, description: description, arguments: arguments, requiresApproval: true)
        }
        return [
            AssistantNativeActionTool(descriptor: descriptor("setAttention", "Set this meeting's attention mode after approval.",
                arguments: [targetArgument, .init(name: "mode", type: .string, required: true, allowedValues: AttentionMode.allCases.map(\.rawValue)),
                            .init(name: "scope", type: .string, allowedValues: ["untilLeave", "minutes30", "series"])]),
                snapshot: snapshot, executor: hooks.executeAction),
            AssistantNativeActionTool(descriptor: descriptor("join", "Join or open the exact target meeting after approval.",
                arguments: [targetArgument]), snapshot: snapshot, executor: hooks.executeAction),
            AssistantNativeActionTool(descriptor: descriptor("leave", "Leave the exact active meeting after approval.",
                arguments: [targetArgument]), snapshot: snapshot, executor: hooks.executeAction),
            AssistantNativeActionTool(descriptor: descriptor("mute", "Mute the microphone in the exact active meeting after approval.",
                arguments: [targetArgument]), snapshot: snapshot, executor: hooks.executeAction),
            AssistantNativeActionTool(descriptor: descriptor("sendChat",
                "Send the exact text to the selected meeting's chat. Omit meeting_id to use the selected active meeting; no preliminary read is needed.",
                arguments: [selectedSendArgument, textArgument]), snapshot: snapshot, executor: hooks.executeAction),
            AssistantNativeActionTool(descriptor: descriptor("say",
                "Speak the exact text into the selected meeting. Omit meeting_id to use the selected active meeting; no preliminary read is needed.",
                arguments: [selectedSendArgument, textArgument]), snapshot: snapshot, executor: hooks.executeAction),
            AssistantNativeActionTool(descriptor: descriptor("react",
                "Send the exact reaction in the selected meeting. Omit meeting_id to use the selected active meeting; no preliminary read is needed.",
                arguments: [selectedSendArgument, .init(name: "reaction", type: .string, required: true,
                                                allowedValues: MeetingReaction.allCases.map(\.rawValue))]),
                snapshot: snapshot, executor: hooks.executeAction),
            AssistantNativeActionTool(descriptor: descriptor("remind", "Set a reminder for the exact Moment after approval.",
                arguments: [.init(name: "moment_id", type: .string, required: true),
                            .init(name: "at", type: .string, required: true, description: "Future ISO 8601 instant")]),
                snapshot: snapshot, executor: hooks.executeAction),
            AssistantNativeActionTool(descriptor: descriptor("remember", "Store an explicit personal memory. Use only when the user asks to remember.",
                arguments: [textArgument]), snapshot: snapshot, executor: hooks.executeAction),
        ]
    }

    private static func closure(_ snapshot: AssistantNativeSnapshot, name: String, description: String,
                                arguments: [AssistantArgumentSpec],
                                body: @escaping @Sendable (AssistantAgentToolCall, AssistantJSON) async throws -> AssistantAgentToolResult)
        -> any AssistantAgentTool {
        let requiredMeetingID = arguments.contains { $0.name == "meeting_id" && $0.required }
        return AssistantClosureTool(
            descriptor: .init(name: name, description: description, arguments: arguments),
            validator: { input in
                assistantResolvedMeetingArguments(input, snapshot: snapshot, defaultWhenMissing: requiredMeetingID)
            },
            body: body)
    }
}

private extension AssistantAgentToolResult {
    static func success(_ call: AssistantAgentToolCall, _ summary: String, json: AssistantJSON,
                        evidence: [AssistantEvidenceSource] = []) -> AssistantAgentToolResult {
        .init(callID: call.id, toolName: call.name, json: json, summary: summary, evidence: evidence)
    }
}

private extension AssistantNativeToolProvider {
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmed
    }

    static func tokens(_ text: String) -> Set<String> {
        Set(normalized(text).split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { $0.count > 1 })
    }

    static func matches(_ query: String, text: String) -> Bool {
        let words = tokens(query)
        guard !words.isEmpty else { return false }
        let haystack = normalized(text)
        return words.allSatisfy { word in
            haystack.range(of: word) != nil || text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static func lineJSON(_ line: AssistantTextLine) -> AssistantJSON {
        .object(("id", .string(line.id)), ("speaker", .string(line.speaker)), ("text", .string(line.text)),
                ("at", AssistantJSON.optionalDate(line.at)))
    }

    static func meetingJSON(_ meeting: AssistantMeetingRecord) -> AssistantJSON {
        .object(("id", .string(meeting.id.uuidString)), ("title", .string(meeting.title)), ("active", .bool(true)),
                ("participants", .strings(meeting.participants)), ("transcript_coverage", .string(meeting.transcriptCoverage)),
                ("can_send_chat", .bool(meeting.canSendChat)), ("can_react", .bool(meeting.canReact)),
                ("supports_voice_reply", .bool(meeting.supportsVoiceReply)), ("source", .string("active meeting")))
    }

    static func outcomeListJSON(_ outcome: AssistantOutcomeRecord) -> AssistantJSON {
        .object(("id", .string(outcome.id.uuidString)), ("meeting_id", AssistantJSON.optionalString(outcome.meetingID?.uuidString)),
                ("title", .string(outcome.title)), ("active", .bool(false)), ("ended_at", .date(outcome.endedAt)),
                ("summary", .string(String(outcome.summary.prefix(500)))), ("source", .string("meeting outcome")))
    }

    static func outcomeJSON(_ outcome: AssistantOutcomeRecord) -> AssistantJSON {
        .object(("id", .string(outcome.id.uuidString)), ("meeting_id", AssistantJSON.optionalString(outcome.meetingID?.uuidString)),
                ("title", .string(outcome.title)), ("ended_at", .date(outcome.endedAt)), ("summary", .string(outcome.summary)),
                ("decisions", .strings(outcome.decisions)), ("open_questions", .strings(outcome.openQuestions)),
                ("tasks", .array(outcome.tasks.map { task in
                    .object(("text", .string(task.text)), ("owner", .string(task.owner)),
                            ("due_at", AssistantJSON.optionalDate(task.dueAt)), ("done", .bool(task.done)))
                })))
    }

    static func calendarJSON(_ occurrence: AssistantCalendarOccurrence) -> AssistantJSON {
        .object(["occurrence_id": .string(occurrence.id), "series_id": .string(occurrence.seriesID),
                 "calendar_id": .string(occurrence.calendarID), "calendar": .string(occurrence.calendarTitle),
                 "title": .string(occurrence.title), "start": .date(occurrence.start), "end": .date(occurrence.end),
                 "all_day": .bool(occurrence.allDay), "room": .string(occurrence.roomIdentity)])
    }

    /// Remove duplicate projections while retaining separate occurrences of one series.
    static func distinctMeetingRecords(_ records: [AssistantJSON]) -> [AssistantJSON] {
        var seen: Set<String> = []
        return records.filter { record in
            let key = (record["title"]?.stringValue ?? "") + "|" + (record["ended_at"]?.stringValue ?? "")
            return seen.insert(key).inserted
        }
    }
}
