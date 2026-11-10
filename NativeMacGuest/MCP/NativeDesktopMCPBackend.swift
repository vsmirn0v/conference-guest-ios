import AppKit
import ConferenceCore
import Foundation

// MARK: - Native desktop backend

@MainActor final class NativeDesktopMCPBackend: MCPBackend {
    private let workspace: () -> NativeDesktopWorkspace?
    let actions = MCPActionCenter()
    private let defaults: UserDefaults
    private var settingsRevision = UUID().uuidString
    private var favoriteRevision = UUID().uuidString
    private var cursorValues: [String: (kind: String, filters: String, items: [MCPJSON], offset: Int, observedAt: String)] = [:]
    private let cursorSecret = UUID().uuidString

    init(workspace: @escaping () -> NativeDesktopWorkspace? = { nil }, defaults: UserDefaults = .standard, approval: (@escaping (String, MCPJSON) async -> Bool) = { _, _ in false }, attention attentionOverride: (() -> AttentionCoordinator?)? = nil) {
        self.workspace = workspace; self.defaults = defaults; self.attentionOverride = attentionOverride; actions.approval = approval
    }

    private let attentionOverride: (() -> AttentionCoordinator?)?

    private var app: NativeDesktopWorkspace? { workspace() }
    private var library: NativeDesktopLibrary? { app?.library }
    private var attention: AttentionCoordinator? { attentionOverride?() ?? app?.attention }

    private func envelope(_ value: MCPJSON, coverage: String = "complete", warnings: [String] = []) -> MCPJSON {
        var copy = value
        copy["observed_at"] = mcpNow(); copy["coverage"] = coverage; copy["warnings"] = warnings
        return copy
    }

    private func page(kind: String, filters: MCPJSON, args: MCPJSON, items: [MCPJSON]) throws -> MCPJSON {
        let limit = try MCPValue.integer(args["limit"], key: "limit", default: 20, maximum: 100)
        let filterKey = canonical(filters)
        let offset: Int
        let observed: String
        if let cursor = args["cursor"] as? String {
            guard var stored = cursorValues[cursor], stored.kind == kind, stored.filters == filterKey else {
                throw MCPToolFailure("CURSOR_EXPIRED", "The cursor no longer matches this query.", retryable: true)
            }
            offset = stored.offset; observed = stored.observedAt; stored.items = items
            cursorValues[cursor] = stored
        } else {
            offset = 0; observed = mcpNow()
        }
        let slice = Array(items.dropFirst(offset).prefix(limit))
        let next = offset + slice.count
        let nextCursor: String? = next < items.count ? makeCursor(kind: kind, filters: filterKey, items: items, offset: next, observedAt: observed) : nil
        return [
            "items": slice, "next_cursor": nextCursor ?? NSNull(), "observed_at": observed,
            "coverage": "complete", "warnings": [],
        ]
    }

    private func makeCursor(kind: String, filters: String, items: [MCPJSON], offset: Int, observedAt: String) -> String {
        let token = mcpSHA256(cursorSecret + kind + filters + String(offset) + observedAt)
        cursorValues[token] = (kind, filters, items, offset, observedAt)
        if cursorValues.count > 512 { cursorValues.removeAll() }
        return token
    }

    private func canonical(_ value: MCPJSON) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "\(value)"
    }

    private func timeFilter(_ args: MCPJSON) throws -> (Date?, Date?) {
        // NOTE: keep this a single-expression tuple of throwing calls. Expanding
        // it into multiple `let` bindings + a comparison + early throw miscompiles
        // under Swift 6.3/6.4 (swiftlang/swift#87481) and aborts the host process
        // with "freed pointer was not the last allocation" at runtime.
        (try MCPValue.date(args["from"], key: "from"), try MCPValue.date(args["to"], key: "to"))
    }

    /// from/to ordering lives outside `timeFilter` so the parser keeps its
    /// single-expression shape (see the note there).
    private func assertOrdered(_ from: Date?, _ to: Date?) throws {
        if let from, let to, from >= to {
            throw MCPToolFailure("INVALID_ARGUMENT", "from must be earlier than to.", details: ["field": "from", "reason": "range"])
        }
    }

    private func inRange(_ date: Date?, from: Date?, to: Date?) -> Bool {
        if let from, (date == nil || date! < from) { return false }
        if let to, (date == nil || date! >= to) { return false }
        return true
    }

    // MARK: Status and meeting cards

    func status() async throws -> MCPJSON {
        [
            "backend": "native",
            "server": ["name": "rocknroll-native", "version": "0.3.0"],
            "app": [
                "running": true,
                "bundle_id": Bundle.main.bundleIdentifier ?? "dev.vsmirn0v.conferenceguest.nativeguest",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "active_meetings": app?.meetings.count ?? 0,
            ],
            "capabilities": [
                "kinds": ["active", "favorite", "recent", "calendar", "outcome"],
                "search_types": ["meeting", "outcome", "task", "transcript", "note"],
                "controls": ["join", "leave", "microphone", "camera"],
                "mutations": ["favorite", "task", "settings"],
                "assistant": true, "settings": true,
            ],
            "limitations": [
                "Assistant commands that need native confirmation are returned as approval-required and are not executed by MCP.",
                "Transcript completeness remains partial unless the meeting service proves a complete stream.",
            ],
            "observed_at": mcpNow(),
        ]
    }

    private func activeCard(_ model: NativeDesktopMeetingModel) -> MCPJSON {
        [
            "id": mcpSessionID(model.sessionID), "kind": "active", "title": model.title,
            "engine": model.kind.rawValue, "connected": model.connected,
            "microphone_on": model.snapshot.microphoneOn, "camera_on": model.snapshot.cameraOn,
            "playout_on": model.snapshot.playoutOn, "owns_microphone": model.ownsMicrophone,
            "participant_count": model.participants.count,
            "related": ["room": mcpRoomID(model.invitation, engine: model.kind)],
            "supported_controls": ["leave", "microphone", "camera"],
            "coverage": "complete", "provenance": ["type": "active_session", "record_id": model.sessionID.uuidString],
        ]
    }

    private func roomCard(_ room: RecentRoom, kind: String) -> MCPJSON {
        [
            "id": mcpRoomID(room.invitationURL, engine: room.engine), "kind": kind,
            "title": room.displayTitle, "favorite": room.isStarred,
            "last_joined_at": mcpDate(room.lastVisit), "engine": room.engine?.rawValue ?? NSNull(),
            "related": [:], "coverage": "complete",
            "provenance": ["type": "room_history", "record_id": room.identifier],
        ]
    }

    private func calendarCard(_ meeting: CalendarMeeting) -> MCPJSON {
        [
            "id": mcpOccurrenceID(meeting.id), "kind": "calendar", "title": meeting.title,
            "start": mcpDate(meeting.start) ?? "", "end": mcpDate(meeting.end) ?? "",
            "all_day": meeting.allDay, "tentative": meeting.tentative,
            "resolved": meeting.hasResolvedInvitation,
            "related": meeting.roomIdentity.map { ["room": mcpOpaqueID("room", $0.origin + "|" + $0.room + "|" + $0.engine.rawValue)] } ?? [:],
            "coverage": "complete", "provenance": ["type": "calendar", "record_id": meeting.id],
        ]
    }

    private func outcomeCard(_ outcome: MeetingOutcome) -> MCPJSON {
        [
            "id": mcpOutcomeID(outcome.id), "kind": "outcome", "title": outcome.meetingTitle,
            "summary": outcome.summary, "ended_at": mcpDate(outcome.endedAt) ?? "",
            "related": [:], "coverage": "complete",
            "provenance": ["type": "outcome", "record_id": outcome.id.uuidString],
        ]
    }

    private func allMeetingItems() -> [MCPJSON] {
        guard let app, let library else { return [] }
        var items: [MCPJSON] = app.meetings.map(activeCard)
        items += library.favorites.map { roomCard($0, kind: "favorite") }
        items += library.recent.map { roomCard($0, kind: "recent") }
        items += library.calendarMeetings.map(calendarCard)
        let outcomes = attention?.store.assistant.outcomes ?? []
        items += outcomes.map(outcomeCard)
        return items
    }

    func listMeetings(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        let (from, to) = try timeFilter(args)
        try assertOrdered(from, to)
        // The query filter is trimmed; a whitespace-only value is ignored.
        let trimmed = try MCPValue.optionalString(args["query"], key: "query").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let query = (trimmed?.isEmpty == true ? nil : trimmed)?.lowercased()
        let kind = try MCPValue.optionalString(args["kind"], key: "kind")
        if let kind, !["active", "favorite", "recent", "calendar", "outcome"].contains(kind) {
            throw MCPToolFailure("CAPABILITY_UNAVAILABLE", "Unknown meeting kind: \(kind)")
        }
        let items = allMeetingItems().filter { item in
            if let kind, item["kind"] as? String != kind { return false }
            let date = Self.cardDate(item)
            guard inRange(date, from: from, to: to) else { return false }
            if let query {
                let title = item["title"] as? String ?? ""
                let summary = item["summary"] as? String ?? ""
                guard (title + " " + summary).lowercased().contains(query) else { return false }
            }
            return true
        }.sorted { lhs, rhs in
            let left = Self.cardDate(lhs) ?? .distantPast, right = Self.cardDate(rhs) ?? .distantPast
            if left != right { return left < right }
            return (lhs["id"] as? String ?? "") < (rhs["id"] as? String ?? "")
        }
        // Dates are stringified for the cursor key: a boxed Date/Optional<Date> in
        // this dictionary trips the Swift 6.3/6.4 miscompile (swiftlang/swift#87481)
        // and aborts the host, and JSONSerialization cannot encode Date anyway.
        return try page(kind: "meetings", filters: ["from": mcpDate(from) as Any, "to": mcpDate(to) as Any, "query": query as Any, "kind": kind as Any], args: args, items: items)
    }

    static func cardDate(_ item: MCPJSON) -> Date? {
        let formatter = ISO8601DateFormatter()
        for key in ["start", "ended_at", "last_joined_at"] {
            if let value = item[key] as? String, let date = formatter.date(from: value) { return date }
        }
        return item["kind"] as? String == "active" ? Date() : nil
    }

    private func activeMeeting(_ id: String) throws -> NativeDesktopMeetingModel {
        guard let model = app?.meetings.first(where: { mcpSessionID($0.sessionID) == id }) else {
            throw MCPToolFailure("MEETING_NOT_FOUND", "The requested active meeting is unavailable.")
        }
        return model
    }

    private func room(_ id: String) throws -> RecentRoom {
        guard let room = library?.history.rooms.first(where: { mcpRoomID($0.invitationURL, engine: $0.engine) == id }) else {
            throw MCPToolFailure("MEETING_NOT_FOUND", "The requested room is unavailable.")
        }
        return room
    }

    private func calendarMeeting(_ id: String) throws -> CalendarMeeting {
        guard let meeting = library?.calendarMeetings.first(where: { mcpOccurrenceID($0.id) == id }) else {
            throw MCPToolFailure("MEETING_NOT_FOUND", "The requested calendar meeting is unavailable.")
        }
        return meeting
    }

    private func outcome(_ id: String) throws -> MeetingOutcome {
        guard let outcome = attention?.store.assistant.outcomes.first(where: { mcpOutcomeID($0.id) == id }) else {
            throw MCPToolFailure("OUTCOME_NOT_FOUND", "The requested outcome is unavailable.")
        }
        return outcome
    }

    func getMeeting(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        let id = try MCPValue.string(args["meeting_id"], key: "meeting_id")
        if id.hasPrefix("session:") {
            return envelope(activeCard(try activeMeeting(id)))
        }
        if id.hasPrefix("room:") {
            let value = try room(id); let starred = value.isStarred
            return envelope(roomCard(value, kind: starred ? "favorite" : "recent"), warnings: ["Room identity is stable; repeated sessions are not merged."])
        }
        if id.hasPrefix("occurrence:") {
            let meeting = try calendarMeeting(id)
            var card = calendarCard(meeting)
            card["calendar_title"] = meeting.calendarTitle
            card["series_id"] = meeting.seriesID
            return envelope(card)
        }
        if id.hasPrefix("outcome:") {
            let value = try outcome(id)
            var card = outcomeCard(value)
            card["decisions"] = value.decisions; card["open_questions"] = value.openQuestions
            card["task_ids"] = value.tasks.map { mcpTaskID(value.id, $0) }
            return envelope(card)
        }
        throw MCPToolFailure("INVALID_ARGUMENT", "meeting_id has an unsupported entity type.")
    }

    func getTranscript(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        let id = try MCPValue.string(args["meeting_id"], key: "meeting_id")
        guard id.hasPrefix("session:") else { throw MCPToolFailure("TRANSCRIPT_UNAVAILABLE", "Only an active session has an authoritative native transcript.") }
        let model = try activeMeeting(id)
        let (from, to) = try timeFilter(args)
        try assertOrdered(from, to)
        let service = model.transcript.map { message in
            [
                "id": "utterance:native:\(message.id)", "speaker": message.participantName,
                "text": message.text, "at": mcpDate(Self.spokenDate(message)) ?? "", "is_you": message.isOwn,
                "mentions_you": false, "provenance": ["type": "service_transcript", "record_id": message.id],
            ] as MCPJSON
        }
        let local = model.localTranscript.map { message in
            [
                "id": "utterance:native:local:\(message.id)", "speaker": message.participantName,
                "text": message.text, "at": mcpDate(Self.spokenDate(message)) ?? "", "is_you": message.isOwn,
                "mentions_you": false, "provenance": ["type": "local_transcription", "record_id": message.id],
            ] as MCPJSON
        }
        var seen = Set<String>()
        let items = (service + local).filter { item in
            guard let text = item["id"] as? String, seen.insert(text).inserted else { return false }
            let formatter = ISO8601DateFormatter()
            let date = (item["at"] as? String).flatMap { formatter.date(from: $0) }
            return inRange(date, from: from, to: to)
        }.sorted { (($0["at"] as? String) ?? "") < (($1["at"] as? String) ?? "") }
        var result = try page(kind: "transcript", filters: ["meeting_id": id, "from": mcpDate(from) as Any, "to": mcpDate(to) as Any], args: args, items: items)
        result["coverage"] = model.guestFeatures.transcriptionStatus == .active ? "unknown" : "partial"
        return result
    }

    static func spokenDate(_ message: GuestMeetingMessage) -> Date? {
        NativeDesktopMeetingModel.spokenAt(message)
    }

    func getOutcome(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        let id = try MCPValue.string(args["outcome_id"], key: "outcome_id")
        let value = try outcome(id)
        return [
            "id": id, "meeting_title": value.meetingTitle, "ended_at": mcpDate(value.endedAt) ?? "",
            "summary": value.summary, "decisions": value.decisions, "open_questions": value.openQuestions,
            "tasks": value.tasks.map { task in
                [
                    "id": mcpTaskID(value.id, task), "text": task.text, "owner": task.owner, "done": task.done,
                    "due_at": mcpDate(task.dueAt) ?? NSNull(), "reminder_at": mcpDate(task.reminderAt) ?? NSNull(),
                    "meeting_id": id,
                ] as MCPJSON
            },
            "observed_at": mcpNow(), "coverage": "complete", "warnings": [],
        ]
    }

    /// Resolves a persisted or active session to its (sessionUUID, title) pair.
    private func noteSession(_ id: String) async throws -> (UUID, String) {
        if id.hasPrefix("session:"), let model = app?.meetings.first(where: { mcpSessionID($0.sessionID) == id }) {
            return (model.sessionID, model.title)
        }
        let raw = id.split(separator: ":").last.map(String.init) ?? id
        guard let uuid = UUID(uuidString: raw) else {
            throw MCPToolFailure("INVALID_ARGUMENT", "meeting_id is not a recognized session identifier.")
        }
        // Historical sessions no longer require an open meeting; the persisted
        // record's title answers when the meeting is not active.
        guard let store = attention?.store.meetingLibrary.store,
              let session = try await store.session(uuid) else {
            throw MCPToolFailure("MEETING_NOT_FOUND", "The requested meeting is unavailable.")
        }
        return (uuid, session.title)
    }

    func getNotes(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        let id = try MCPValue.string(args["meeting_id"], key: "meeting_id")
        let (sessionID, title) = try await noteSession(id)
        guard let library = attention?.store.meetingLibrary else {
            throw MCPToolFailure("APP_NOT_RUNNING", "The native workspace is unavailable.")
        }
        guard let note = await library.note(sessionID: sessionID) else {
            return [
                "meeting_id": mcpSessionID(sessionID), "note": NSNull(), "has_notes": false,
                "meeting_title": title,
                "coverage": "complete", "warnings": ["This meeting has no saved note."],
                "observed_at": mcpNow(),
            ]
        }
        return [
            "meeting_id": mcpSessionID(sessionID), "note_id": mcpNoteID(sessionID, note.id),
            "has_notes": true, "revision": note.revision, "updated_at": mcpDate(note.updatedAt) ?? "",
            "provenance": ["type": "personal_note", "record_id": note.id.uuidString],
            "coverage": "complete", "warnings": [],
            "markdown": note.markdown,
            "meeting_title": title,
            "observed_at": mcpNow(),
        ]
    }

    func listTasks(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        let meetingID = try MCPValue.optionalString(args["meeting_id"], key: "meeting_id")
        let done = try MCPValue.optionalBool(args["done"], key: "done")
        let owner = try MCPValue.optionalString(args["owner"], key: "owner")?.lowercased()
        let outcomes = attention?.store.assistant.outcomes ?? []
        var tasks: [MCPJSON] = []
        for value in outcomes {
            let oid = mcpOutcomeID(value.id)
            if let meetingID, meetingID != oid { continue }
            for task in value.tasks where (done == nil || task.done == done) && (owner == nil || task.owner.lowercased().contains(owner!)) {
                tasks.append([
                    "id": mcpTaskID(value.id, task), "text": task.text, "owner": task.owner, "done": task.done,
                    "due_at": mcpDate(task.dueAt) ?? NSNull(), "reminder_at": mcpDate(task.reminderAt) ?? NSNull(),
                    "meeting_id": oid,
                ])
            }
        }
        return try page(kind: "tasks", filters: ["meeting_id": meetingID as Any, "done": done as Any, "owner": owner as Any], args: args, items: tasks)
    }

    func search(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        let rawQuery = try MCPValue.string(args["query"], key: "query")
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw MCPToolFailure("INVALID_ARGUMENT", "query must not be empty.", details: ["field": "query", "reason": "empty"])
        }
        let needle = query.lowercased()
        let types = args["types"] as? [String] ?? ["meeting", "outcome", "task", "transcript", "note"]
        var results: [MCPJSON] = []
        if types.contains("meeting") {
            for item in allMeetingItems() {
                let text = ((item["title"] as? String) ?? "").lowercased()
                if text.contains(needle) { results.append(["type": "meeting", "meeting": item, "matched_field": "title"]) }
            }
        }
        if types.contains("outcome") {
            for value in attention?.store.assistant.outcomes ?? [] {
                let item = outcomeCard(value)
                let haystack = ((item["title"] as? String) ?? "") + " " + value.summary
                if haystack.lowercased().contains(needle) { results.append(["type": "outcome", "meeting": item, "matched_field": "title_or_summary"]) }
            }
        }
        if types.contains("task") {
            for value in attention?.store.assistant.outcomes ?? [] {
                for task in value.tasks where task.text.lowercased().contains(needle) {
                    results.append(["type": "task", "task": ["id": mcpTaskID(value.id, task), "text": task.text, "owner": task.owner, "done": task.done, "meeting_id": mcpOutcomeID(value.id)], "matched_field": "text"])
                }
            }
        }
        if types.contains("note"), let library = attention?.store.meetingLibrary {
            for hit in await library.searchNotes(query: query, limit: 20) {
                results.append(["type": "note",
                    "meeting": ["id": mcpSessionID(hit.sessionID), "title": hit.meetingTitle,
                                "has_notes": true, "provenance": ["type": "meeting_library", "record_id": hit.sessionID.uuidString]],
                    "note": ["id": mcpNoteID(hit.sessionID, hit.chunk.noteID), "revision": hit.chunk.noteRevision,
                             "excerpt": hit.chunk.text.prefix(400).description],
                    "matched_field": "note"])
            }
        }
        if types.contains("transcript") {
            for model in app?.meetings ?? [] {
                for message in model.transcript + model.localTranscript where message.text.lowercased().contains(needle) {
                    results.append(["type": "transcript", "meeting": activeCard(model), "utterance": ["speaker": message.participantName, "text": message.text, "at": mcpDate(Self.spokenDate(message)) ?? ""], "matched_field": "text"])
                }
            }
        }
        return try page(kind: "search", filters: ["query": query, "types": types], args: args, items: results)
    }

    // MARK: Settings and attention

    private func providerInfo(_ provider: AttentionProvider, store: AttentionStore) -> MCPJSON {
        ["kind": provider.kind.rawValue, "model": provider.model, "base_url": provider.baseURL, "on_this_mac": provider.onThisMac, "configured": store.writerConfigured, "has_key": store.hasKey(for: provider)]
    }

    func getSettings(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        guard let store = attention?.store else { throw MCPToolFailure("APP_NOT_RUNNING", "The native workspace is unavailable.") }
        let requested = args["sections"] as? [String] ?? ["app", "attention", "meeting"]
        var sections: MCPJSON = [:]
        if requested.contains("app") {
            sections["app"] = [
                "display_name": library?.displayName ?? "", "multiple_meetings": defaults.object(forKey: "nativeDesktop.multipleMeetings") as? Bool ?? true,
                "calendar_enabled": library?.calendar.enabled ?? false, "calendar_access": String(describing: library?.calendar.access ?? .notDetermined),
                // Published so rocknroll_set_favorite callers can supply expected_revision.
                "favorite_revision": favoriteRevision,
            ]
        }
        if requested.contains("attention") {
            // Sub-expressions are hoisted into lets: nesting the provider/writer
            // calls and mapValues directly inside the dictionary literal miscompiles
            // under Swift 6.3/6.4 (swiftlang/swift#87481) and aborts the host
            // process with "freed pointer was not the last allocation".
            let provider = providerInfo(store.provider, store: store)
            let writer = providerInfo(store.effectiveWriter, store: store)
            // String-keyed: the raw store dictionary is keyed by the
            // AttentionSituation enum, which JSONSerialization cannot encode
            // (and whose bridging trips the Swift 6.3/6.4 arena miscompile,
            // swiftlang/swift#87481, aborting the host mid-serialization).
            let modes = Dictionary(uniqueKeysWithValues: store.situationModes.map { ($0.key.rawValue, $0.value.rawValue) })
            sections["attention"] = [
                "judge_enabled": store.enabled, "pause_on_battery": store.pauseOnBattery,
                "draft_replies": store.draftReplies, "local_drafts": store.localDrafts,
                "push_to_talk": store.pushToTalk, "talk_back": store.talkBack,
                "generate_outcomes": store.generateOutcomes, "remote_outcomes": store.remoteOutcomes,
                "provider": provider, "writer": writer,
                "situation_modes": modes,
            ]
        }
        if requested.contains("meeting") {
            var meeting: MCPJSON = [:]
            if let id = try MCPValue.optionalString(args["meeting_id"], key: "meeting_id"), id.hasPrefix("session:") {
                let model = try activeMeeting(id)
                let preset = store.preset(room: model.invitation, latest: nil, series: model.calendarSeriesID)
                let situation: AttentionSituation = workspace().map { $0.isOnScreen(model) ? .onScreen : (model.snapshot.playoutOn ? .background : .silenced) } ?? .silenced
                // Hoisted out of the literal for the same swiftlang/swift#87481 reason
                // as the attention branch above.
                let configuredMode: Any = preset?.mode?.rawValue ?? NSNull()
                let effectiveMode = (preset?.mode ?? store.mode(for: situation)).rawValue
                let inheritedFrom: Any = preset.map { _ in ["meeting_preset"] } ?? ["situation_default"]
                let presetID: Any = preset?.id.uuidString ?? NSNull()
                meeting = [
                    "configured_mode": configuredMode, "effective_mode": effectiveMode,
                    "inherited_from": inheritedFrom, "preset_id": presetID,
                ]
            }
            sections["meeting"] = meeting
        }
        return ["sections": sections, "revision": settingsRevision, "observed_at": mcpNow(), "coverage": "complete", "warnings": []]
    }

    // MARK: Actions

    private func beginAction(_ args: MCPJSON, client: MCPClientIdentity) throws -> (id: String, replay: MCPJSON?) {
        let id = try MCPValue.string(args["action_id"], key: "action_id")
        let payload = args.filter { $0.key != "action_id" }
        // The center returns nil for an exact replay and throws ACTION_ID_REUSED
        // when the same action_id arrives with a different payload.
        let record = try actions.begin(client: client, actionID: id, payload: payload)
        return (id, record == nil ? actions.recordedActions[id]?.result : nil)
    }

    private func expectRevision(_ expected: Any?, actual: String) throws {
        guard let expected = expected as? String, !expected.isEmpty else {
            throw MCPToolFailure("INVALID_ARGUMENT", "expected_revision is required.", details: ["field": "expected_revision", "reason": "required"])
        }
        guard expected == actual else { throw MCPToolFailure("REVISION_CONFLICT", "The target changed before the action was applied.", retryable: true) }
    }

    func controlMeeting(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        let (id, replay) = try beginAction(args, client: client); if let replay { return replay }
        let meetingID = try MCPValue.string(args["meeting_id"], key: "meeting_id")
        let desired = args["desired_state"] as? MCPJSON ?? [:]
        let title: String
        do {
            if meetingID.hasPrefix("session:") { title = try activeMeeting(meetingID).title }
            else if meetingID.hasPrefix("room:") { title = try room(meetingID).displayTitle }
            else if meetingID.hasPrefix("occurrence:") { title = try calendarMeeting(meetingID).title }
            else { throw MCPToolFailure("INVALID_ARGUMENT", "meeting_id must identify a session, room or occurrence.") }
        }
        guard await actions.approval("Meeting control", ["meeting_id": meetingID, "desired_state": desired]) else {
            return actions.finish(id, client: client, type: "meeting_control", target: meetingID, status: "rejected", failure: "APPROVAL_DENIED")
        }
        if meetingID.hasPrefix("session:") {
            let model = try activeMeeting(meetingID)
            if desired["leave"] as? Bool == true {
                _ = await app?.leave(model)
            }
            if let microphone = desired["microphone"] as? Bool, microphone != model.snapshot.microphoneOn { model.toggleMicrophone() }
            if let camera = desired["camera"] as? Bool, camera != model.snapshot.cameraOn { model.toggleCamera() }
            return actions.finish(id, client: client, type: "meeting_control", target: meetingID, status: "applied", result: ["action_id": id, "status": "applied", "observed_at": mcpNow(), "entity_id": meetingID, "revision": model.sessionID.uuidString, "warnings": []])
        }
        guard let library, let app else { throw MCPToolFailure("APP_NOT_RUNNING", "The native workspace is unavailable.") }
        let url: URL; let engine: MeetingEngineKind?; let titleValue: String?; let eventID: String?
        if meetingID.hasPrefix("room:") {
            let value = try room(meetingID); url = library.calendar.preferredInvitation(for: value); engine = library.calendar.preferredEngine(for: value); titleValue = value.displayTitle; eventID = nil
        } else {
            let meeting = try calendarMeeting(meetingID)
            guard let invitation = meeting.invitation, meeting.hasResolvedInvitation else { throw MCPToolFailure("CAPABILITY_UNAVAILABLE", "This calendar meeting has no resolved room.") }
            url = invitation; engine = meeting.engine; titleValue = meeting.title; eventID = meeting.id
        }
        app.join(url, engine: engine, title: titleValue, eventID: eventID, quiet: desired["microphone"] as? Bool == false)
        return actions.finish(id, client: client, type: "meeting_control", target: meetingID, status: "applied", result: ["action_id": id, "status": "applied", "observed_at": mcpNow(), "entity_id": meetingID, "revision": UUID().uuidString, "warnings": []])
    }

    func setFavorite(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        let roomID = try MCPValue.string(args["room_id"], key: "room_id")
        let favorite = try MCPValue.bool(args["favorite"], key: "favorite")
        let actionID = try MCPValue.string(args["action_id"], key: "action_id")
        // Validate before recording so a refused action leaves no pending record;
        // an exact replay is returned by beginAction without re-checking the revision.
        if actions.recordedActions[actionID] == nil { try expectRevision(args["expected_revision"], actual: favoriteRevision) }
        let (id, replay) = try beginAction(args, client: client); if let replay { return replay }
        let value = try room(roomID)
        if value.isStarred != favorite { library?.toggleFavorite(value) }
        favoriteRevision = UUID().uuidString
        return actions.finish(id, client: client, type: "favorite", target: roomID, status: "applied", result: ["action_id": id, "status": "applied", "observed_at": mcpNow(), "entity_id": roomID, "revision": favoriteRevision, "warnings": []])
    }

    func updateTask(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        guard let store = attention?.store else { throw MCPToolFailure("APP_NOT_RUNNING", "The native workspace is unavailable.") }
        let taskID = try MCPValue.string(args["task_id"], key: "task_id")
        guard let parsed = taskID.split(separator: ":").last, let taskUUID = UUID(uuidString: String(parsed)) else { throw MCPToolFailure("TASK_NOT_FOUND", "The requested task is unavailable.") }
        var found: (outcome: MeetingOutcome, task: MeetingOutcomeTask)? = nil
        for outcome in store.assistant.outcomes {
            if let task = outcome.tasks.first(where: { $0.id == taskUUID }) { found = (outcome, task); break }
        }
        guard let target = found else { throw MCPToolFailure("TASK_NOT_FOUND", "The requested task is unavailable.") }
        // Validation precedes the action record; replays skip the revision check.
        let actionID = try MCPValue.string(args["action_id"], key: "action_id")
        if actions.recordedActions[actionID] == nil { try expectRevision(args["expected_revision"], actual: target.outcome.id.uuidString) }
        let (id, replay) = try beginAction(args, client: client); if let replay { return replay }
        var task = target.task
        if let text = try MCPValue.optionalString(args["text"], key: "text") { task.text = text }
        if let owner = try MCPValue.optionalString(args["owner"], key: "owner") { task.owner = owner }
        if let done = try MCPValue.optionalBool(args["done"], key: "done") { task.done = done }
        var outcome = target.outcome
        if let index = outcome.tasks.firstIndex(where: { $0.id == task.id }) { outcome.tasks[index] = task }
        store.assistant.updateOutcome(outcome)
        return actions.finish(id, client: client, type: "task", target: taskID, status: "applied", result: ["action_id": id, "status": "applied", "observed_at": mcpNow(), "entity_id": taskID, "revision": outcome.id.uuidString, "warnings": []])
    }

    func updateSettings(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        guard let store = attention?.store else { throw MCPToolFailure("APP_NOT_RUNNING", "The native workspace is unavailable.") }
        let sections = args["sections"] as? MCPJSON ?? [:]
        let attentionPatch = sections["attention"] as? MCPJSON ?? [:]
        let allowed: [String: (AttentionStore) -> Bool] = [
            "judge_enabled": { $0.enabled }, "pause_on_battery": { $0.pauseOnBattery }, "draft_replies": { $0.draftReplies },
            "local_drafts": { $0.localDrafts }, "push_to_talk": { $0.pushToTalk }, "talk_back": { $0.talkBack },
            "generate_outcomes": { $0.generateOutcomes }, "remote_outcomes": { $0.remoteOutcomes },
        ]
        var updates: [String: Bool] = [:]
        for key in attentionPatch.keys {
            guard allowed[key] != nil else { throw MCPToolFailure("INVALID_ARGUMENT", "Unsupported attention setting: \(key)") }
            updates[key] = try MCPValue.bool(attentionPatch[key], key: key)
        }
        if let appPatch = sections["app"] as? MCPJSON, appPatch.keys.contains("multiple_meetings"), !(appPatch["multiple_meetings"] is Bool) {
            throw MCPToolFailure("INVALID_ARGUMENT", "multiple_meetings must be a boolean.")
        }
        // Validate before recording so a refused action leaves no pending record;
        // replays skip the revision check and return the stored result.
        let actionID = try MCPValue.string(args["action_id"], key: "action_id")
        if actions.recordedActions[actionID] == nil { try expectRevision(args["expected_revision"], actual: settingsRevision) }
        let (id, replay) = try beginAction(args, client: client); if let replay { return replay }
        guard await actions.approval("Settings update", ["sections": Array(sections.keys).sorted()]) else {
            return actions.finish(id, client: client, type: "settings", target: "settings", status: "rejected", failure: "APPROVAL_DENIED")
        }
        for (key, value) in updates {
            switch key {
            case "judge_enabled": store.enabled = value
            case "pause_on_battery": store.pauseOnBattery = value
            case "draft_replies": store.draftReplies = value
            case "local_drafts": store.localDrafts = value
            case "push_to_talk": store.pushToTalk = value
            case "talk_back": store.talkBack = value
            case "generate_outcomes": store.generateOutcomes = value
            case "remote_outcomes": store.remoteOutcomes = value
            default: break
            }
        }
        if let appPatch = sections["app"] as? MCPJSON, let multiple = appPatch["multiple_meetings"] as? Bool {
            defaults.set(multiple, forKey: "nativeDesktop.multipleMeetings")
        }
        settingsRevision = UUID().uuidString
        return actions.finish(id, client: client, type: "settings", target: "settings", status: "applied", result: ["action_id": id, "status": "applied", "observed_at": mcpNow(), "entity_id": "settings", "revision": settingsRevision, "warnings": []])
    }

    func runAssistant(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        let (id, replay) = try beginAction(args, client: client); if let replay { return replay }
        // Reject the unsupported field before any workspace lookup so clients
        // reliably get CAPABILITY_UNAVAILABLE rather than APP_NOT_RUNNING.
        if args["conversation_id"] != nil { throw MCPToolFailure("CAPABILITY_UNAVAILABLE", "This assistant does not expose external conversation IDs.") }
        let rawPrompt = try MCPValue.string(args["prompt"], key: "prompt")
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw MCPToolFailure("INVALID_ARGUMENT", "prompt must not be empty.", details: ["field": "prompt", "reason": "empty"])
        }
        guard let app, let talk = attention?.talk else { throw MCPToolFailure("APP_NOT_RUNNING", "The native assistant is unavailable.") }
        if let meetingID = try MCPValue.optionalString(args["meeting_id"], key: "meeting_id") {
            guard meetingID.hasPrefix("session:") else { throw MCPToolFailure("INVALID_ARGUMENT", "meeting_id must identify an active session.") }
            let model = try activeMeeting(meetingID)
            talk.targetMeetingID = model.sessionID
        }
        let response = await talk.runExternal(prompt)
        if response.needsNativeConfirmation {
            return actions.finish(id, client: client, type: "assistant", target: "assistant", status: "rejected", failure: "APPROVAL_REQUIRED")
        }
        let result: MCPJSON = [
            "action_id": id, "status": "applied", "observed_at": mcpNow(), "entity_id": "assistant",
            "response": response.answer ?? "", "provenance": ["type": "in_app_assistant"], "warnings": [],
        ]
        return actions.finish(id, client: client, type: "assistant", target: "assistant", status: "applied", result: result)
    }
}
