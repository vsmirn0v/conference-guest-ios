import ConferenceCore
import Foundation
import SQLite3

private let transientSQLiteDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct IOSMeetingSessionItem: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var occurrenceKey: String
    var title: String
    var hasTitleOverride: Bool
    var invitation: URL?
    var roomIdentity: String
    var calendarSeriesID: String?
    var externalSeriesID: String?
    var startedAt: Date
    var endedAt: Date?
    var timeZoneID: String
    var state: String
    var legs: [String: DeviceParticipationLeg]
    var outcomeClaim: OutcomeGenerationClaim?
    var obsidianReceipt: ObsidianSyncReceipt?
    var manualObsidianSaveAt: Date?
    var createdAt: Date
    var updatedAt: Date
}

struct IOSMeetingNoteItem: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { sessionID }
    var sessionID: UUID
    var noteID: UUID
    var markdown: String
    var revision: Int
    var updatedAt: Date

    var isEmpty: Bool { markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasConflictMarkers: Bool {
        markdown.contains("<<<<<<<") && markdown.contains("=======") && markdown.contains(">>>>>>>")
    }
}

struct IOSMeetingOutcomeItem: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { outcomeID }
    var outcomeID: UUID
    var sessionID: UUID
    var state: String
    var summary: String
    var decisions: [String]
    var openQuestions: [String]
    var summaryEdited: Bool
    var decisionsEdited: Bool
    var questionsEdited: Bool
    var coverageSeconds: Double
    var writerTier: Int
    var versions: [SyncedOutcomeVersionSnapshot]
    var reviewCandidates: [SyncedTaskSnapshot]
    var updatedAt: Date
}

struct IOSMeetingTaskItem: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var sessionID: UUID
    var outcomeID: UUID
    var ordinal: Int
    var text: String
    var owner: String
    var assigneeID: String?
    var dueDay: String?
    var dueAt: Date?
    var reminderAt: Date?
    var done: Bool
    var completedAt: Date?
    var updatedAt: Date
}

struct IOSTaskProfile: Codable, Equatable, Sendable {
    var profileID: String
    var assigneeID: String?
    var aliases: [String]

    init(profileID: String = "default", assigneeID: String? = nil, aliases: [String] = []) {
        self.profileID = profileID
        self.assigneeID = assigneeID
        self.aliases = aliases
    }

    static func cleanedAlias(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func normalized(_ name: String) -> String {
        cleanedAlias(name).folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func confirmedAliases(_ raw: String) -> [String] {
        var seen: Set<String> = []
        let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: ","))
        return raw.components(separatedBy: separators)
            .map(cleanedAlias)
            .filter { !$0.isEmpty && seen.insert(normalized($0)).inserted }
    }

    @discardableResult
    mutating func appendAliasIfMissing(_ name: String) -> Bool {
        let cleaned = Self.cleanedAlias(name)
        guard !cleaned.isEmpty else { return false }
        let key = Self.normalized(cleaned)
        guard !aliases.contains(where: { Self.normalized($0) == key }) else { return false }
        aliases.append(cleaned)
        return true
    }

    var isConfigured: Bool {
        let hasAssignee = !(assigneeID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return hasAssignee || aliases.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func owns(_ task: IOSMeetingTaskItem) -> Bool {
        if let assignment = task.assigneeID, !assignment.isEmpty {
            return assignment == assigneeID
        }
        let owner = Self.normalized(task.owner)
        return !owner.isEmpty && aliases.contains { Self.normalized($0) == owner }
    }
}

struct IOSWorkspaceSearchHit: Equatable, Identifiable, Sendable {
    var id: UUID { sessionID }
    var sessionID: UUID
    var title: String
    var startedAt: Date
    var snippet: String
}

enum IOSWorkspaceStoreError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return msg
        case .prepareFailed(let msg): return msg
        case .stepFailed(let msg): return msg
        }
    }
}

actor IOSWorkspaceStore {
    let root: URL
    private var handle: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.root = appSupport.appendingPathComponent("RockWorkspace", isDirectory: true)
        }
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    func close() {
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    func prepare() throws {
        guard handle == nil else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dbURL = root.appendingPathComponent("workspace.sqlite3")
        var raw: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbURL.path, &raw, flags, nil) == SQLITE_OK, let raw else {
            let message = raw.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open error"
            if let raw { sqlite3_close_v2(raw) }
            throw IOSWorkspaceStoreError.openFailed(message)
        }
        handle = raw
        try exec("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;")
        try exec("""
            CREATE TABLE IF NOT EXISTS sessions (
                session_id TEXT PRIMARY KEY,
                occurrence_key TEXT NOT NULL,
                title TEXT NOT NULL,
                title_folded TEXT NOT NULL,
                has_title_override INTEGER NOT NULL DEFAULT 0,
                invitation TEXT,
                room_identity TEXT NOT NULL,
                calendar_series_id TEXT,
                external_series_id TEXT,
                started_at INTEGER NOT NULL,
                ended_at INTEGER,
                time_zone_id TEXT NOT NULL,
                state TEXT NOT NULL,
                legs_json BLOB NOT NULL,
                outcome_claim_json BLOB,
                obsidian_receipt_json BLOB,
                manual_obsidian_save_at INTEGER,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_sessions_started ON sessions(started_at DESC);

            CREATE TABLE IF NOT EXISTS notes (
                session_id TEXT PRIMARY KEY REFERENCES sessions(session_id) ON DELETE CASCADE,
                note_id TEXT NOT NULL,
                markdown TEXT NOT NULL,
                markdown_folded TEXT NOT NULL,
                revision INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS note_sync_bases (
                session_id TEXT PRIMARY KEY REFERENCES sessions(session_id) ON DELETE CASCADE,
                sha256 TEXT NOT NULL,
                markdown TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS outcomes (
                session_id TEXT PRIMARY KEY REFERENCES sessions(session_id) ON DELETE CASCADE,
                outcome_id TEXT NOT NULL,
                state TEXT NOT NULL,
                summary TEXT NOT NULL,
                summary_folded TEXT NOT NULL,
                decisions_json BLOB NOT NULL,
                open_questions_json BLOB NOT NULL,
                summary_edited INTEGER NOT NULL DEFAULT 0,
                decisions_edited INTEGER NOT NULL DEFAULT 0,
                questions_edited INTEGER NOT NULL DEFAULT 0,
                coverage_seconds REAL NOT NULL DEFAULT 0,
                writer_tier INTEGER NOT NULL DEFAULT 0,
                versions_json BLOB NOT NULL,
                review_candidates_json BLOB NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS tasks (
                task_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
                outcome_id TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                text TEXT NOT NULL,
                text_folded TEXT NOT NULL,
                owner TEXT NOT NULL,
                assignee_id TEXT,
                due_day TEXT,
                due_at INTEGER,
                reminder_at INTEGER,
                done INTEGER NOT NULL DEFAULT 0,
                completed_at INTEGER,
                updated_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_tasks_session ON tasks(session_id, ordinal);

            CREATE TABLE IF NOT EXISTS task_links (
                session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
                historical_task_id TEXT NOT NULL,
                canonical_task_id TEXT NOT NULL,
                PRIMARY KEY(session_id, historical_task_id)
            );

            CREATE TABLE IF NOT EXISTS task_archive (
                profile_id TEXT NOT NULL,
                task_id TEXT NOT NULL,
                archived_at INTEGER NOT NULL,
                PRIMARY KEY(profile_id, task_id)
            );

            CREATE TABLE IF NOT EXISTS task_profile (
                profile_id TEXT PRIMARY KEY,
                assignee_id TEXT,
                aliases_json BLOB NOT NULL
            );

            CREATE TABLE IF NOT EXISTS local_transcript_events (
                session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
                event_id TEXT NOT NULL,
                payload_json BLOB NOT NULL,
                occurred_at INTEGER NOT NULL,
                PRIMARY KEY(session_id, event_id)
            );
            CREATE INDEX IF NOT EXISTS idx_transcript_session_time ON local_transcript_events(session_id, occurred_at);

            CREATE TABLE IF NOT EXISTS context_settings (
                scope_key TEXT PRIMARY KEY,
                payload_json BLOB NOT NULL
            );
            """)
    }

    // MARK: - Sessions

    func allSessions() throws -> [IOSMeetingSessionItem] {
        try prepare()
        return try query("SELECT session_id,occurrence_key,title,has_title_override,invitation,room_identity,calendar_series_id,external_series_id,started_at,ended_at,time_zone_id,state,legs_json,outcome_claim_json,obsidian_receipt_json,manual_obsidian_save_at,created_at,updated_at FROM sessions ORDER BY started_at DESC") { stmt in
            decodeSessionRow(stmt)
        }
    }

    func session(_ id: UUID) throws -> IOSMeetingSessionItem? {
        try prepare()
        return try query("SELECT session_id,occurrence_key,title,has_title_override,invitation,room_identity,calendar_series_id,external_series_id,started_at,ended_at,time_zone_id,state,legs_json,outcome_claim_json,obsidian_receipt_json,manual_obsidian_save_at,created_at,updated_at FROM sessions WHERE session_id=?", bind: {
            bindText($0, id.uuidString, at: 1)
        }) { stmt in
            decodeSessionRow(stmt)
        }.first
    }

    func upsertSession(_ session: IOSMeetingSessionItem) throws {
        try prepare()
        let legsData = try encoder.encode(session.legs)
        let claimData = try session.outcomeClaim.map { try encoder.encode($0) }
        let receiptData = try session.obsidianReceipt.map { try encoder.encode($0) }
        try run("""
            INSERT INTO sessions(
                session_id,occurrence_key,title,title_folded,has_title_override,invitation,room_identity,
                calendar_series_id,external_series_id,started_at,ended_at,time_zone_id,state,legs_json,
                outcome_claim_json,obsidian_receipt_json,manual_obsidian_save_at,created_at,updated_at
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(session_id) DO UPDATE SET
                occurrence_key=excluded.occurrence_key,
                title=excluded.title,
                title_folded=excluded.title_folded,
                has_title_override=excluded.has_title_override,
                invitation=excluded.invitation,
                room_identity=excluded.room_identity,
                calendar_series_id=excluded.calendar_series_id,
                external_series_id=excluded.external_series_id,
                started_at=excluded.started_at,
                ended_at=excluded.ended_at,
                time_zone_id=excluded.time_zone_id,
                state=excluded.state,
                legs_json=excluded.legs_json,
                outcome_claim_json=excluded.outcome_claim_json,
                obsidian_receipt_json=excluded.obsidian_receipt_json,
                manual_obsidian_save_at=excluded.manual_obsidian_save_at,
                updated_at=excluded.updated_at
            """) { stmt in
            bindText(stmt, session.id.uuidString, at: 1)
            bindText(stmt, session.occurrenceKey, at: 2)
            bindText(stmt, session.title, at: 3)
            bindText(stmt, session.title.workspaceFolded, at: 4)
            bindInt(stmt, session.hasTitleOverride ? 1 : 0, at: 5)
            bindText(stmt, session.invitation?.absoluteString, at: 6)
            bindText(stmt, session.roomIdentity, at: 7)
            bindText(stmt, session.calendarSeriesID, at: 8)
            bindText(stmt, session.externalSeriesID, at: 9)
            bindInt(stmt, session.startedAt.syncMilliseconds, at: 10)
            bindOptionalInt(stmt, session.endedAt?.syncMilliseconds, at: 11)
            bindText(stmt, session.timeZoneID, at: 12)
            bindText(stmt, session.state, at: 13)
            bindBlob(stmt, legsData, at: 14)
            bindBlob(stmt, claimData, at: 15)
            bindBlob(stmt, receiptData, at: 16)
            bindOptionalInt(stmt, session.manualObsidianSaveAt?.syncMilliseconds, at: 17)
            bindInt(stmt, session.createdAt.syncMilliseconds, at: 18)
            bindInt(stmt, session.updatedAt.syncMilliseconds, at: 19)
        }
    }

    func deleteSession(_ id: UUID) throws {
        try prepare()
        try run("DELETE FROM sessions WHERE session_id=?") { bindText($0, id.uuidString, at: 1) }
    }

    func applyRemoteSession(_ remote: SyncedMeetingSession) throws -> Bool {
        try prepare()
        if remote.isDeleted.value || (remote.canonicalSessionID?.value != nil && remote.canonicalSessionID?.value != remote.id) {
            let existed = try session(remote.id) != nil
            if existed { try deleteSession(remote.id) }
            return existed
        }
        let existing = try session(remote.id)
        let title = remote.title.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (existing?.title ?? L("Meeting"))
            : remote.title.value
        let item = IOSMeetingSessionItem(
            id: remote.id,
            occurrenceKey: remote.occurrenceKey,
            title: title,
            hasTitleOverride: remote.hasTitleOverride.value,
            invitation: remote.invitation.value ?? existing?.invitation,
            roomIdentity: remote.roomIdentity.isEmpty ? (existing?.roomIdentity ?? "") : remote.roomIdentity,
            calendarSeriesID: remote.calendarSeriesID ?? existing?.calendarSeriesID,
            externalSeriesID: remote.externalSeriesID ?? existing?.externalSeriesID,
            startedAt: remote.startedAt == .distantPast ? (existing?.startedAt ?? Date()) : remote.startedAt,
            endedAt: remote.endedAt.value ?? existing?.endedAt,
            timeZoneID: remote.timeZoneID.isEmpty ? (existing?.timeZoneID ?? TimeZone.current.identifier) : remote.timeZoneID,
            state: remote.state.value,
            legs: remote.legs,
            outcomeClaim: remote.outcomeClaim?.value ?? existing?.outcomeClaim,
            obsidianReceipt: remote.obsidianReceipt?.value ?? existing?.obsidianReceipt,
            manualObsidianSaveAt: remote.manualObsidianSaveAt?.value ?? existing?.manualObsidianSaveAt,
            createdAt: min(existing?.createdAt ?? remote.createdAt, remote.createdAt),
            updatedAt: max(existing?.updatedAt ?? remote.updatedAt, remote.updatedAt)
        )
        if existing == item { return false }
        try upsertSession(item)
        return true
    }

    // MARK: - Notes

    func allNotes() throws -> [UUID: IOSMeetingNoteItem] {
        try prepare()
        let items = try query("SELECT session_id,note_id,markdown,revision,updated_at FROM notes") { stmt in
            decodeNoteRow(stmt)
        }
        return Dictionary(uniqueKeysWithValues: items.compactMap { $0 }.map { ($0.sessionID, $0) })
    }

    func note(_ sessionID: UUID) throws -> IOSMeetingNoteItem? {
        try prepare()
        return try query("SELECT session_id,note_id,markdown,revision,updated_at FROM notes WHERE session_id=?", bind: {
            bindText($0, sessionID.uuidString, at: 1)
        }) { stmt in
            decodeNoteRow(stmt)
        }.first
    }

    func noteSyncBase(_ sessionID: UUID) throws -> NoteBaseSnapshot? {
        try prepare()
        return try query("SELECT sha256,markdown FROM note_sync_bases WHERE session_id=?", bind: {
            bindText($0, sessionID.uuidString, at: 1)
        }) { stmt in
            guard let sha = colText(stmt, 0), let md = colText(stmt, 1) else { return nil }
            return NoteBaseSnapshot(sessionID: sessionID, sha256: sha, markdown: md)
        }.first
    }

    func saveNoteSyncBase(_ sessionID: UUID, markdown: String) throws {
        try prepare()
        try ensureSessionExists(sessionID)
        try run("""
            INSERT INTO note_sync_bases(session_id,sha256,markdown) VALUES(?,?,?)
            ON CONFLICT(session_id) DO UPDATE SET sha256=excluded.sha256,markdown=excluded.markdown
            """) { stmt in
            bindText(stmt, sessionID.uuidString, at: 1)
            bindText(stmt, SyncedMeetingNote.sha256(markdown), at: 2)
            bindText(stmt, markdown, at: 3)
        }
    }

    @discardableResult
    func saveNote(sessionID: UUID, noteID: UUID = UUID(), markdown: String, updatedAt: Date = Date()) throws -> IOSMeetingNoteItem {
        try prepare()
        try ensureSessionExists(sessionID)
        let existing = try note(sessionID)
        let resolvedNoteID = existing?.noteID ?? noteID
        let nextRevision = (existing?.revision ?? 0) + 1
        let item = IOSMeetingNoteItem(
            sessionID: sessionID,
            noteID: resolvedNoteID,
            markdown: markdown,
            revision: nextRevision,
            updatedAt: updatedAt
        )
        try writeNote(item)
        return item
    }

    func applyRemoteNote(_ remote: SyncedMeetingNote, localDeviceID: String) throws -> (markdown: String, changed: Bool) {
        try prepare()
        if remote.isDeleted.value {
            try run("DELETE FROM notes WHERE session_id=?") { bindText($0, remote.sessionID.uuidString, at: 1) }
            try run("DELETE FROM note_sync_bases WHERE session_id=?") { bindText($0, remote.sessionID.uuidString, at: 1) }
            return ("", true)
        }
        try ensureSessionExists(remote.sessionID)
        let existing = try note(remote.sessionID)
        let base = try noteSyncBase(remote.sessionID)?.markdown

        let finalMarkdown: String
        let changed: Bool
        if let existing {
            if existing.markdown == remote.markdown {
                finalMarkdown = existing.markdown
                changed = false
            } else {
                let localVersion = SyncVersion(counter: Int64(max(1, existing.revision)), device: localDeviceID)
                let merge = NoteThreeWayMerger.merge(
                    base: base,
                    local: existing.markdown,
                    localVersion: localVersion,
                    remote: remote.markdown,
                    remoteVersion: remote.version
                )
                finalMarkdown = merge.markdown
                changed = finalMarkdown != existing.markdown
            }
        } else {
            finalMarkdown = remote.markdown
            changed = true
        }

        try saveNoteSyncBase(remote.sessionID, markdown: remote.markdown)
        guard changed else { return (finalMarkdown, false) }

        let updated = IOSMeetingNoteItem(
            sessionID: remote.sessionID,
            noteID: existing?.noteID ?? remote.noteID,
            markdown: finalMarkdown,
            revision: (existing?.revision ?? 0) + 1,
            updatedAt: max(existing?.updatedAt ?? remote.updatedAt, remote.updatedAt)
        )
        try writeNote(updated)
        return (finalMarkdown, true)
    }

    // MARK: - Outcomes & Tasks

    func allOutcomes() throws -> [UUID: IOSMeetingOutcomeItem] {
        try prepare()
        let items = try query("SELECT outcome_id,session_id,state,summary,decisions_json,open_questions_json,summary_edited,decisions_edited,questions_edited,coverage_seconds,writer_tier,versions_json,review_candidates_json,updated_at FROM outcomes") { stmt in
            decodeOutcomeRow(stmt)
        }
        return Dictionary(uniqueKeysWithValues: items.compactMap { $0 }.map { ($0.sessionID, $0) })
    }

    func saveOutcome(_ item: IOSMeetingOutcomeItem) throws {
        try prepare()
        try ensureSessionExists(item.sessionID)
        let decisionsData = try encoder.encode(item.decisions)
        let questionsData = try encoder.encode(item.openQuestions)
        let versionsData = try encoder.encode(item.versions)
        let reviewData = try encoder.encode(item.reviewCandidates)
        try run("""
            INSERT INTO outcomes(
                session_id,outcome_id,state,summary,summary_folded,decisions_json,open_questions_json,
                summary_edited,decisions_edited,questions_edited,coverage_seconds,writer_tier,
                versions_json,review_candidates_json,updated_at
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(session_id) DO UPDATE SET
                outcome_id=excluded.outcome_id,
                state=excluded.state,
                summary=excluded.summary,
                summary_folded=excluded.summary_folded,
                decisions_json=excluded.decisions_json,
                open_questions_json=excluded.open_questions_json,
                summary_edited=excluded.summary_edited,
                decisions_edited=excluded.decisions_edited,
                questions_edited=excluded.questions_edited,
                coverage_seconds=excluded.coverage_seconds,
                writer_tier=excluded.writer_tier,
                versions_json=excluded.versions_json,
                review_candidates_json=excluded.review_candidates_json,
                updated_at=excluded.updated_at
            """) { stmt in
            bindText(stmt, item.sessionID.uuidString, at: 1)
            bindText(stmt, item.outcomeID.uuidString, at: 2)
            bindText(stmt, item.state, at: 3)
            bindText(stmt, item.summary, at: 4)
            bindText(stmt, item.summary.workspaceFolded, at: 5)
            bindBlob(stmt, decisionsData, at: 6)
            bindBlob(stmt, questionsData, at: 7)
            bindInt(stmt, item.summaryEdited ? 1 : 0, at: 8)
            bindInt(stmt, item.decisionsEdited ? 1 : 0, at: 9)
            bindInt(stmt, item.questionsEdited ? 1 : 0, at: 10)
            bindDouble(stmt, item.coverageSeconds, at: 11)
            bindInt(stmt, Int64(item.writerTier), at: 12)
            bindBlob(stmt, versionsData, at: 13)
            bindBlob(stmt, reviewData, at: 14)
            bindInt(stmt, item.updatedAt.syncMilliseconds, at: 15)
        }
    }

    func allTasks() throws -> [IOSMeetingTaskItem] {
        try prepare()
        return try query("SELECT task_id,session_id,outcome_id,ordinal,text,owner,assignee_id,due_day,due_at,reminder_at,done,completed_at,updated_at FROM tasks ORDER BY updated_at DESC, ordinal ASC") { stmt in
            decodeTaskRow(stmt)
        }
    }

    func replaceTasks(for sessionID: UUID, tasks: [IOSMeetingTaskItem]) throws {
        try prepare()
        try ensureSessionExists(sessionID)
        try run("DELETE FROM tasks WHERE session_id=?") { bindText($0, sessionID.uuidString, at: 1) }
        for task in tasks {
            try upsertTask(task)
        }
    }

    func upsertTask(_ task: IOSMeetingTaskItem) throws {
        try prepare()
        try ensureSessionExists(task.sessionID)
        try run("""
            INSERT INTO tasks(
                task_id,session_id,outcome_id,ordinal,text,text_folded,owner,assignee_id,
                due_day,due_at,reminder_at,done,completed_at,updated_at
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(task_id) DO UPDATE SET
                ordinal=excluded.ordinal,
                text=excluded.text,
                text_folded=excluded.text_folded,
                owner=excluded.owner,
                assignee_id=excluded.assignee_id,
                due_day=excluded.due_day,
                due_at=excluded.due_at,
                reminder_at=excluded.reminder_at,
                done=excluded.done,
                completed_at=excluded.completed_at,
                updated_at=excluded.updated_at
            """) { stmt in
            bindText(stmt, task.id.uuidString, at: 1)
            bindText(stmt, task.sessionID.uuidString, at: 2)
            bindText(stmt, task.outcomeID.uuidString, at: 3)
            bindInt(stmt, Int64(task.ordinal), at: 4)
            bindText(stmt, task.text, at: 5)
            bindText(stmt, task.text.workspaceFolded, at: 6)
            bindText(stmt, task.owner, at: 7)
            bindText(stmt, task.assigneeID, at: 8)
            bindText(stmt, task.dueDay, at: 9)
            bindOptionalInt(stmt, task.dueAt?.syncMilliseconds, at: 10)
            bindOptionalInt(stmt, task.reminderAt?.syncMilliseconds, at: 11)
            bindInt(stmt, task.done ? 1 : 0, at: 12)
            bindOptionalInt(stmt, task.completedAt?.syncMilliseconds, at: 13)
            bindInt(stmt, task.updatedAt.syncMilliseconds, at: 14)
        }
    }

    func deleteTask(_ taskID: UUID) throws {
        try prepare()
        try run("DELETE FROM tasks WHERE task_id=?") { bindText($0, taskID.uuidString, at: 1) }
        try run("DELETE FROM task_archive WHERE task_id=?") { bindText($0, taskID.uuidString, at: 1) }
    }

    func applyRemoteOutcomeAndTasks(
        sessionID: UUID,
        outcome: SyncedMeetingOutcome?,
        tasks: [SyncedMeetingTask],
        links: [SyncedTaskLink]
    ) throws {
        try prepare()
        try ensureSessionExists(sessionID)

        if let outcome {
            if outcome.isDeleted.value {
                try run("DELETE FROM outcomes WHERE session_id=?") { bindText($0, sessionID.uuidString, at: 1) }
            } else {
                let item = IOSMeetingOutcomeItem(
                    outcomeID: outcome.outcomeID,
                    sessionID: sessionID,
                    state: outcome.state.value,
                    summary: outcome.summary.value,
                    decisions: outcome.decisions.value,
                    openQuestions: outcome.openQuestions.value,
                    summaryEdited: outcome.summaryEdited,
                    decisionsEdited: outcome.decisionsEdited,
                    questionsEdited: outcome.questionsEdited,
                    coverageSeconds: outcome.coverageSeconds,
                    writerTier: outcome.writerTier,
                    versions: outcome.versions,
                    reviewCandidates: outcome.reviewCandidates.value,
                    updatedAt: outcome.updatedAt
                )
                try saveOutcome(item)
            }
        }

        let active = tasks
            .filter { !$0.isDeleted.value }
            .sorted { ($0.ordinal.value, $0.id.uuidString) < ($1.ordinal.value, $1.id.uuidString) }
            .map { task in
                IOSMeetingTaskItem(
                    id: task.id,
                    sessionID: sessionID,
                    outcomeID: task.outcomeID,
                    ordinal: task.ordinal.value,
                    text: task.text.value,
                    owner: task.owner.value,
                    assigneeID: task.assigneeID.value,
                    dueDay: task.dueDay.value,
                    dueAt: task.dueAt.value,
                    reminderAt: task.done.value ? nil : task.reminderAt.value,
                    done: task.done.value,
                    completedAt: task.completedAt.value,
                    updatedAt: task.updatedAt
                )
            }
        try replaceTasks(for: sessionID, tasks: active)

        for link in links {
            try run("INSERT OR IGNORE INTO task_links(session_id,historical_task_id,canonical_task_id) VALUES(?,?,?)") { stmt in
                bindText(stmt, sessionID.uuidString, at: 1)
                bindText(stmt, link.historicalTaskID.uuidString, at: 2)
                bindText(stmt, link.canonicalTaskID.uuidString, at: 3)
            }
        }

        for task in tasks {
            for (profileID, archived) in task.archivedByProfile {
                if let archivedAt = archived.value {
                    try run("""
                        INSERT INTO task_archive(profile_id,task_id,archived_at) VALUES(?,?,?)
                        ON CONFLICT(profile_id,task_id) DO UPDATE SET archived_at=excluded.archived_at
                        """) { stmt in
                        bindText(stmt, profileID, at: 1)
                        bindText(stmt, task.id.uuidString, at: 2)
                        bindInt(stmt, archivedAt.syncMilliseconds, at: 3)
                    }
                } else {
                    try run("DELETE FROM task_archive WHERE profile_id=? AND task_id=?") { stmt in
                        bindText(stmt, profileID, at: 1)
                        bindText(stmt, task.id.uuidString, at: 2)
                    }
                }
            }
        }
    }

    func allTaskLinks() throws -> [SyncedTaskLink] {
        try prepare()
        return try query("SELECT session_id,historical_task_id,canonical_task_id FROM task_links") { stmt in
            guard let sid = colText(stmt, 0).flatMap(UUID.init(uuidString:)),
                  let hist = colText(stmt, 1).flatMap(UUID.init(uuidString:)),
                  let canon = colText(stmt, 2).flatMap(UUID.init(uuidString:)) else { return nil }
            return SyncedTaskLink(sessionID: sid, historicalTaskID: hist, canonicalTaskID: canon)
        }
    }

    func taskArchiveDates(profileID: String) throws -> [UUID: Date] {
        try prepare()
        let key = profileID.isEmpty ? "default" : profileID
        let rows = try query("SELECT task_id,archived_at FROM task_archive WHERE profile_id=?", bind: {
            bindText($0, key, at: 1)
        }) { stmt -> (UUID, Date)? in
            guard let tid = colText(stmt, 0).flatMap(UUID.init(uuidString:)),
                  let ms = colInt(stmt, 1) else { return nil }
            return (tid, Date.fromSyncMilliseconds(ms))
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    func setTaskArchived(taskID: UUID, profileID: String, archived: Bool, now: Date = Date()) throws -> Date? {
        try prepare()
        let key = profileID.isEmpty ? "default" : profileID
        if archived {
            try run("""
                INSERT INTO task_archive(profile_id,task_id,archived_at) VALUES(?,?,?)
                ON CONFLICT(profile_id,task_id) DO UPDATE SET archived_at=excluded.archived_at
                """) { stmt in
                bindText(stmt, key, at: 1)
                bindText(stmt, taskID.uuidString, at: 2)
                bindInt(stmt, now.syncMilliseconds, at: 3)
            }
            return now
        } else {
            try run("DELETE FROM task_archive WHERE profile_id=? AND task_id=?") { stmt in
                bindText(stmt, key, at: 1)
                bindText(stmt, taskID.uuidString, at: 2)
            }
            return nil
        }
    }

    func taskProfile() throws -> IOSTaskProfile {
        try prepare()
        return try query("SELECT profile_id,assignee_id,aliases_json FROM task_profile LIMIT 1") { stmt -> IOSTaskProfile? in
            let id = colText(stmt, 0) ?? "default"
            let assignee = colText(stmt, 1)
            let aliases = colBlob(stmt, 2).flatMap { try? decoder.decode([String].self, from: $0) } ?? []
            return IOSTaskProfile(profileID: id, assigneeID: assignee, aliases: aliases)
        }.first ?? IOSTaskProfile()
    }

    func saveTaskProfile(_ profile: IOSTaskProfile) throws {
        try prepare()
        let key = profile.profileID.isEmpty ? "default" : profile.profileID
        let data = try encoder.encode(profile.aliases)
        try exec("BEGIN IMMEDIATE TRANSACTION")
        do {
            try run("DELETE FROM task_profile WHERE profile_id != ?") { stmt in
                bindText(stmt, key, at: 1)
            }
            try run("""
                INSERT INTO task_profile(profile_id,assignee_id,aliases_json) VALUES(?,?,?)
                ON CONFLICT(profile_id) DO UPDATE SET assignee_id=excluded.assignee_id,aliases_json=excluded.aliases_json
                """) { stmt in
                bindText(stmt, key, at: 1)
                bindText(stmt, profile.assigneeID, at: 2)
                bindBlob(stmt, data, at: 3)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Context Settings

    func allContextSettings() throws -> [String: SyncedMeetingContextSettings] {
        try prepare()
        let rows = try query("SELECT scope_key,payload_json FROM context_settings") { stmt -> (String, SyncedMeetingContextSettings)? in
            guard let key = colText(stmt, 0),
                  let blob = colBlob(stmt, 1),
                  let decoded = try? decoder.decode(SyncedMeetingContextSettings.self, from: blob) else { return nil }
            return (key, decoded)
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    func saveContextSettings(_ settings: SyncedMeetingContextSettings) throws {
        try prepare()
        let data = try encoder.encode(settings)
        try run("""
            INSERT INTO context_settings(scope_key,payload_json) VALUES(?,?)
            ON CONFLICT(scope_key) DO UPDATE SET payload_json=excluded.payload_json
            """) { stmt in
            bindText(stmt, settings.scopeKey, at: 1)
            bindBlob(stmt, data, at: 2)
        }
    }

    // MARK: - Unexpiring Local Transcript Events

    func appendTranscriptEvents(sessionID: UUID, events: [SyncedTranscriptEvent]) throws {
        try prepare()
        guard !events.isEmpty else { return }
        try exec("BEGIN IMMEDIATE TRANSACTION")
        do {
            try ensureSessionExists(sessionID)
            for event in events {
                let data = try encoder.encode(event)
                try run("""
                    INSERT INTO local_transcript_events(session_id,event_id,payload_json,occurred_at) VALUES(?,?,?,?)
                    ON CONFLICT(session_id,event_id) DO UPDATE SET payload_json=excluded.payload_json,occurred_at=excluded.occurred_at
                    """) { stmt in
                    bindText(stmt, sessionID.uuidString, at: 1)
                    bindText(stmt, event.id, at: 2)
                    bindBlob(stmt, data, at: 3)
                    bindInt(stmt, event.occurredAt.syncMilliseconds, at: 4)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func loadTranscriptEvents(sessionID: UUID) throws -> [SyncedTranscriptEvent] {
        try prepare()
        return try query("SELECT payload_json FROM local_transcript_events WHERE session_id=? ORDER BY occurred_at ASC, event_id ASC", bind: {
            bindText($0, sessionID.uuidString, at: 1)
        }) { stmt in
            guard let data = colBlob(stmt, 0) else { return nil }
            return try? decoder.decode(SyncedTranscriptEvent.self, from: data)
        }
    }

    // MARK: - Search

    func search(query text: String, limit: Int = 30) throws -> [IOSWorkspaceSearchHit] {
        try prepare()
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).workspaceFolded
        guard !needle.isEmpty else { return [] }
        let pattern = "%" + needle + "%"
        let sql = """
            SELECT s.session_id, s.title, s.started_at,
                   COALESCE(NULLIF(o.summary,''), COALESCE(n.markdown,'')) AS snippet
            FROM sessions s
            LEFT JOIN outcomes o ON o.session_id = s.session_id
            LEFT JOIN notes n ON n.session_id = s.session_id
            WHERE s.title_folded LIKE ?
               OR COALESCE(n.markdown_folded,'') LIKE ?
               OR COALESCE(o.summary_folded,'') LIKE ?
               OR EXISTS (
                   SELECT 1 FROM tasks t
                   WHERE t.session_id = s.session_id AND t.text_folded LIKE ?
               )
            ORDER BY s.started_at DESC
            LIMIT ?
            """
        return try query(sql, bind: { stmt in
            bindText(stmt, pattern, at: 1)
            bindText(stmt, pattern, at: 2)
            bindText(stmt, pattern, at: 3)
            bindText(stmt, pattern, at: 4)
            bindInt(stmt, Int64(limit), at: 5)
        }) { stmt -> IOSWorkspaceSearchHit? in
            guard let sid = colText(stmt, 0).flatMap(UUID.init(uuidString:)),
                  let title = colText(stmt, 1),
                  let ms = colInt(stmt, 2) else { return nil }
            let rawSnippet = (colText(stmt, 3) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return IOSWorkspaceSearchHit(
                sessionID: sid,
                title: title,
                startedAt: Date.fromSyncMilliseconds(ms),
                snippet: String(rawSnippet.prefix(160))
            )
        }
    }

    // MARK: - Private SQLite Helpers

    private func writeNote(_ item: IOSMeetingNoteItem) throws {
        try run("""
            INSERT INTO notes(session_id,note_id,markdown,markdown_folded,revision,updated_at) VALUES(?,?,?,?,?,?)
            ON CONFLICT(session_id) DO UPDATE SET
                note_id=excluded.note_id,
                markdown=excluded.markdown,
                markdown_folded=excluded.markdown_folded,
                revision=excluded.revision,
                updated_at=excluded.updated_at
            """) { stmt in
            bindText(stmt, item.sessionID.uuidString, at: 1)
            bindText(stmt, item.noteID.uuidString, at: 2)
            bindText(stmt, item.markdown, at: 3)
            bindText(stmt, item.markdown.workspaceFolded, at: 4)
            bindInt(stmt, Int64(item.revision), at: 5)
            bindInt(stmt, item.updatedAt.syncMilliseconds, at: 6)
        }
    }

    private func ensureSessionExists(_ sessionID: UUID) throws {
        let existing = try query("SELECT 1 FROM sessions WHERE session_id=?", bind: {
            bindText($0, sessionID.uuidString, at: 1)
        }) { _ in true }
        guard existing.isEmpty else { return }
        let now = Date()
        let placeholder = L("Meeting")
        try upsertSession(
            IOSMeetingSessionItem(
                id: sessionID,
                occurrenceKey: "room:" + sessionID.uuidString,
                title: placeholder,
                hasTitleOverride: false,
                invitation: nil,
                roomIdentity: "",
                calendarSeriesID: nil,
                externalSeriesID: nil,
                startedAt: now,
                endedAt: nil,
                timeZoneID: TimeZone.current.identifier,
                state: "ended",
                legs: [:],
                createdAt: now,
                updatedAt: now
            )
        )
    }

    private func decodeSessionRow(_ stmt: OpaquePointer) -> IOSMeetingSessionItem? {
        guard let sid = colText(stmt, 0).flatMap(UUID.init(uuidString:)),
              let occKey = colText(stmt, 1),
              let title = colText(stmt, 2),
              let startedMs = colInt(stmt, 8),
              let createdMs = colInt(stmt, 16),
              let updatedMs = colInt(stmt, 17) else { return nil }
        let legs = colBlob(stmt, 12).flatMap { try? decoder.decode([String: DeviceParticipationLeg].self, from: $0) } ?? [:]
        let claim = colBlob(stmt, 13).flatMap { try? decoder.decode(OutcomeGenerationClaim.self, from: $0) }
        let receipt = colBlob(stmt, 14).flatMap { try? decoder.decode(ObsidianSyncReceipt.self, from: $0) }
        return IOSMeetingSessionItem(
            id: sid,
            occurrenceKey: occKey,
            title: title,
            hasTitleOverride: (colInt(stmt, 3) ?? 0) == 1,
            invitation: colText(stmt, 4).flatMap(URL.init(string:)),
            roomIdentity: colText(stmt, 5) ?? "",
            calendarSeriesID: colText(stmt, 6),
            externalSeriesID: colText(stmt, 7),
            startedAt: Date.fromSyncMilliseconds(startedMs),
            endedAt: colInt(stmt, 9).map(Date.fromSyncMilliseconds),
            timeZoneID: colText(stmt, 10) ?? TimeZone.current.identifier,
            state: colText(stmt, 11) ?? "ended",
            legs: legs,
            outcomeClaim: claim,
            obsidianReceipt: receipt,
            manualObsidianSaveAt: colInt(stmt, 15).map(Date.fromSyncMilliseconds),
            createdAt: Date.fromSyncMilliseconds(createdMs),
            updatedAt: Date.fromSyncMilliseconds(updatedMs)
        )
    }

    private func decodeNoteRow(_ stmt: OpaquePointer) -> IOSMeetingNoteItem? {
        guard let sid = colText(stmt, 0).flatMap(UUID.init(uuidString:)),
              let nid = colText(stmt, 1).flatMap(UUID.init(uuidString:)),
              let markdown = colText(stmt, 2),
              let revision = colInt(stmt, 3),
              let updatedMs = colInt(stmt, 4) else { return nil }
        return IOSMeetingNoteItem(
            sessionID: sid,
            noteID: nid,
            markdown: markdown,
            revision: Int(revision),
            updatedAt: Date.fromSyncMilliseconds(updatedMs)
        )
    }

    private func decodeOutcomeRow(_ stmt: OpaquePointer) -> IOSMeetingOutcomeItem? {
        guard let oid = colText(stmt, 0).flatMap(UUID.init(uuidString:)),
              let sid = colText(stmt, 1).flatMap(UUID.init(uuidString:)),
              let state = colText(stmt, 2),
              let summary = colText(stmt, 3),
              let updatedMs = colInt(stmt, 13) else { return nil }
        let decisions = colBlob(stmt, 4).flatMap { try? decoder.decode([String].self, from: $0) } ?? []
        let questions = colBlob(stmt, 5).flatMap { try? decoder.decode([String].self, from: $0) } ?? []
        let versions = colBlob(stmt, 11).flatMap { try? decoder.decode([SyncedOutcomeVersionSnapshot].self, from: $0) } ?? []
        let candidates = colBlob(stmt, 12).flatMap { try? decoder.decode([SyncedTaskSnapshot].self, from: $0) } ?? []
        return IOSMeetingOutcomeItem(
            outcomeID: oid,
            sessionID: sid,
            state: state,
            summary: summary,
            decisions: decisions,
            openQuestions: questions,
            summaryEdited: (colInt(stmt, 6) ?? 0) == 1,
            decisionsEdited: (colInt(stmt, 7) ?? 0) == 1,
            questionsEdited: (colInt(stmt, 8) ?? 0) == 1,
            coverageSeconds: colDouble(stmt, 9),
            writerTier: Int(colInt(stmt, 10) ?? 0),
            versions: versions,
            reviewCandidates: candidates,
            updatedAt: Date.fromSyncMilliseconds(updatedMs)
        )
    }

    private func decodeTaskRow(_ stmt: OpaquePointer) -> IOSMeetingTaskItem? {
        guard let tid = colText(stmt, 0).flatMap(UUID.init(uuidString:)),
              let sid = colText(stmt, 1).flatMap(UUID.init(uuidString:)),
              let oid = colText(stmt, 2).flatMap(UUID.init(uuidString:)),
              let text = colText(stmt, 4),
              let updatedMs = colInt(stmt, 12) else { return nil }
        return IOSMeetingTaskItem(
            id: tid,
            sessionID: sid,
            outcomeID: oid,
            ordinal: Int(colInt(stmt, 3) ?? 0),
            text: text,
            owner: colText(stmt, 5) ?? "",
            assigneeID: colText(stmt, 6),
            dueDay: colText(stmt, 7),
            dueAt: colInt(stmt, 8).map(Date.fromSyncMilliseconds),
            reminderAt: colInt(stmt, 9).map(Date.fromSyncMilliseconds),
            done: (colInt(stmt, 10) ?? 0) == 1,
            completedAt: colInt(stmt, 11).map(Date.fromSyncMilliseconds),
            updatedAt: Date.fromSyncMilliseconds(updatedMs)
        )
    }

    private func exec(_ sql: String) throws {
        guard let handle else { throw IOSWorkspaceStoreError.openFailed("Database not open") }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errMsg)
            throw IOSWorkspaceStoreError.prepareFailed(msg)
        }
    }

    private func run(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }) throws {
        guard let handle else { throw IOSWorkspaceStoreError.openFailed("Database not open") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw IOSWorkspaceStoreError.prepareFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw IOSWorkspaceStoreError.stepFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func query<T>(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }, decode: (OpaquePointer) -> T?) throws -> [T] {
        guard let handle else { throw IOSWorkspaceStoreError.openFailed("Database not open") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw IOSWorkspaceStoreError.prepareFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let value = decode(stmt) { out.append(value) }
        }
        return out
    }

    private func bindText(_ stmt: OpaquePointer, _ value: String?, at index: Int32) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, transientSQLiteDestructor)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindInt(_ stmt: OpaquePointer, _ value: Int64, at index: Int32) {
        sqlite3_bind_int64(stmt, index, value)
    }

    private func bindOptionalInt(_ stmt: OpaquePointer, _ value: Int64?, at index: Int32) {
        if let value { sqlite3_bind_int64(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }

    private func bindDouble(_ stmt: OpaquePointer, _ value: Double, at index: Int32) {
        sqlite3_bind_double(stmt, index, value)
    }

    private func bindBlob(_ stmt: OpaquePointer, _ data: Data?, at index: Int32) {
        guard let data else {
            sqlite3_bind_null(stmt, index)
            return
        }
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, index, bytes.baseAddress, Int32(data.count), transientSQLiteDestructor)
        }
    }

    private func colText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private func colInt(_ stmt: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(stmt, index)
    }

    private func colDouble(_ stmt: OpaquePointer, _ index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }

    private func colBlob(_ stmt: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let ptr = sqlite3_column_blob(stmt, index) else { return nil }
        let len = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: ptr, count: len)
    }
}
