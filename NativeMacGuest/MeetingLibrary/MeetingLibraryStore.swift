import ConferenceCore
import CryptoKit
import Foundation
import SQLite3

/// Text/blob bind destructor that copies the bound value (SQLite's own SQLITE_TRANSIENT
/// macro is not imported by the Swift SQLite3 module).
private let meetingSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum MeetingSQLiteField: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

typealias MeetingSQLiteRow = [MeetingSQLiteField?]

private enum MeetingSQLiteError: LocalizedError {
    case open(String)
    case step(String)
    case bind(String)

    var errorDescription: String? { String(describing: self) }
}

/// Each connection is confined to its owning isolation domain.
final class MeetingSQLiteConnection: @unchecked Sendable {
    private let path: URL
    private var database: OpaquePointer?

    init(path: URL) throws {
        self.path = path
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path.path, &opened, flags, nil)
        guard code == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let opened { sqlite3_close(opened) }
            throw MeetingSQLiteError.open(message)
        }
        database = opened
        sqlite3_busy_timeout(database, 5_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA foreign_keys=ON")
    }

    /// Idempotent close. `sqlite3_close_v2` (unlike `sqlite3_close`) tolerates
    /// unfinalized statements and marks the handle dead immediately, so teardown
    /// never leaves a live file descriptor behind in a directory a fixture is
    /// about to delete ("vnode unlinked while in use").
    func close() {
        if let database { sqlite3_close_v2(database) }
        database = nil
    }

    deinit { close() }

    var errorMessage: String {
        guard let database else { return "database closed" }
        return String(cString: sqlite3_errmsg(database))
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        let code = sqlite3_exec(database, sql, nil, nil, &error)
        if code != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw MeetingSQLiteError.step(message)
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func rows(_ sql: String, bind: (OpaquePointer) throws -> Void = { _ in }) throws -> [MeetingSQLiteRow] {
        var statement: OpaquePointer?
        var code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw MeetingSQLiteError.step(errorMessage)
        }
        defer { sqlite3_finalize(statement) }
        do { try bind(statement) } catch {
            throw MeetingSQLiteError.bind(error.localizedDescription)
        }
        var result: [MeetingSQLiteRow] = []
        let count = Int(sqlite3_column_count(statement))
        while true {
            code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw MeetingSQLiteError.step(errorMessage) }
            var row = MeetingSQLiteRow()
            row.reserveCapacity(count)
            for index in 0..<count {
                switch sqlite3_column_type(statement, Int32(index)) {
                case SQLITE_NULL: row.append(nil)
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, Int32(index))))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, Int32(index))))
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_blob(statement, Int32(index))
                    let length = Int(sqlite3_column_bytes(statement, Int32(index)))
                    row.append(.blob(bytes.map { Data(bytes: $0, count: length) } ?? Data()))
                default: row.append(.text(String(cString: sqlite3_column_text(statement, Int32(index)))))
                }
            }
            result.append(row)
        }
        return result
    }

    func one(_ sql: String, bind: (OpaquePointer) throws -> Void = { _ in }) throws -> MeetingSQLiteRow? {
        try rows(sql, bind: bind).first
    }

    func run(_ sql: String, bind: (OpaquePointer) throws -> Void) throws {
        let row = try rows(sql, bind: bind)
        _ = row
    }

    static func bindText(_ statement: OpaquePointer, _ value: String?, at index: Int32) throws {
        let code: Int32
        if let value { code = sqlite3_bind_text(statement, index, value, -1, meetingSQLiteTransient) }
        else { code = sqlite3_bind_null(statement, index) }
        guard code == SQLITE_OK else { throw MeetingSQLiteError.bind("bind text \(index)") }
    }

    static func bindNull(_ statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
            throw MeetingSQLiteError.bind("bind null \(index)")
        }
    }

    static func bindInt(_ statement: OpaquePointer, _ value: Int64, at index: Int32) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw MeetingSQLiteError.bind("bind integer \(index)")
        }
    }

    static func bindDouble(_ statement: OpaquePointer, _ value: Double, at index: Int32) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw MeetingSQLiteError.bind("bind double \(index)")
        }
    }

    static func bindBlob(_ statement: OpaquePointer, _ value: Data?, at index: Int32) throws {
        let code: Int32
        if let value {
            code = value.withUnsafeBytes { raw in sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(value.count), meetingSQLiteTransient) }
        } else { code = sqlite3_bind_null(statement, index) }
        guard code == SQLITE_OK else { throw MeetingSQLiteError.bind("bind blob \(index)") }
    }
}

extension MeetingSQLiteRow {
    func text(_ index: Int) -> String? {
        guard case .text(let value)? = self[index] else { return nil }
        return value
    }
    func integer(_ index: Int) -> Int64? {
        guard case .integer(let value)? = self[index] else { return nil }
        return value
    }
    func bool(_ index: Int) -> Bool { integer(index) == 1 }
}

/// Thread-safe hand-off between the actor-isolated store and synchronous teardown
/// paths (`closeSync`, owner `deinit`). An unsynchronized `nonisolated(unsafe)`
/// read can miss a connection the actor just installed: the teardown block then
/// sees `nil`, the directory is deleted, and the handle outlives it.
private final class MeetingSQLiteConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: MeetingSQLiteConnection?

    func install(_ connection: MeetingSQLiteConnection) {
        lock.lock(); self.connection = connection; lock.unlock()
    }

    func current() -> MeetingSQLiteConnection? {
        lock.lock(); defer { lock.unlock() }
        return connection
    }

    /// Removes and returns the connection so it is closed exactly once.
    func take() -> MeetingSQLiteConnection? {
        lock.lock(); defer { lock.unlock() }
        let connection = self.connection
        self.connection = nil
        return connection
    }
}

actor MeetingLibraryStore: @unchecked Sendable {
    nonisolated let participationNoteChanges = ParticipationNoteChanges()
    private let root: URL
    private let connectionBox = MeetingSQLiteConnectionBox()
    private(set) var persistenceError: String?

    init(root: URL) {
        self.root = root.appendingPathComponent("MeetingLibrary", isDirectory: true)
    }

    var databaseURL: URL { root.appendingPathComponent("meetings.sqlite3", isDirectory: false) }

    func prepare() async throws {
        if connectionBox.current() != nil { return }
        // Teardown cancellation: the owner cancels its prepare task when a fixture
        // closes the library; a job that starts after cancellation must not open
        // a handle at all (closeSync may already have run and seen an empty box).
        guard !Task.isCancelled else { throw CancellationError() }
        let opened = try MeetingSQLiteConnection(path: databaseURL)
        // Register the handle before running DDL: a synchronous `closeSync()` from
        // owner teardown (a fixture) can then take and close it even mid-prepare.
        connectionBox.install(opened)
        // The handle exists on disk now; if the owner cancelled us between the
        // first guard and registration (teardown running concurrently), close it
        // immediately — but only if it is still ours: a concurrent closeSync may
        // already have taken and closed it, and a second close would corrupt.
        guard !Task.isCancelled else {
            if let taken = connectionBox.take() { taken.close() }
            throw CancellationError()
        }
        do {
            if try opened.one("SELECT 1 FROM sqlite_master WHERE name='schema_migrations'") != nil {
                let previous = try opened.one("SELECT MAX(version) FROM schema_migrations")?.integer(0) ?? 0
                guard previous <= MeetingLibrarySchema.currentVersion else {
                    throw MeetingLibraryError.unavailable("database requires a newer version of Rock’n’Roll")
                }
                if previous > 0, previous < MeetingLibrarySchema.currentVersion {
                    let backup = root.appendingPathComponent("meetings.before-v\(MeetingLibrarySchema.currentVersion).sqlite3")
                    if !FileManager.default.fileExists(atPath: backup.path) {
                        let temporary = root.appendingPathComponent(".migration-backup-\(UUID().uuidString).sqlite3")
                        defer { try? FileManager.default.removeItem(at: temporary) }
                        try opened.run("VACUUM INTO ?") { try Self.bindText($0, temporary.path, at: 1) }
                        try FileManager.default.moveItem(at: temporary, to: backup)
                    }
                }
            }
            try opened.transaction {
                for statement in MeetingLibrarySchema.ddl { try opened.execute(statement) }
                try opened.execute("CREATE TABLE IF NOT EXISTS meeting_library_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                let version = try opened.one("SELECT MAX(version) FROM schema_migrations")?.integer(0) ?? 0
                if version < 3 {
                    try Self.migrateTasks(db: opened)
                }
                if version < 4 {
                    try opened.execute("ALTER TABLE export_outbox ADD COLUMN intent TEXT NOT NULL DEFAULT 'legacy'")
                    try opened.execute("ALTER TABLE export_outbox ADD COLUMN snapshot_json BLOB")
                    try opened.execute("ALTER TABLE export_outbox ADD COLUMN policy_held INTEGER NOT NULL DEFAULT 1")
                }
                if version < 5 {
                    try opened.execute("ALTER TABLE meeting_sessions ADD COLUMN start_provenance TEXT NOT NULL DEFAULT 'unknown'")
                    try opened.execute("ALTER TABLE meeting_sessions ADD COLUMN outcome_end_fallback INTEGER")
                    try Self.migrateMeetingDateProvenance(db: opened)
                }
                if version < 6 {
                    try Self.migrateOutcomeVersions(db: opened)
                }
                if version < MeetingLibrarySchema.currentVersion {
                    try opened.run("INSERT INTO schema_migrations(version, applied_at) VALUES(?, ?)") {
                        try MeetingSQLiteConnection.bindInt($0, Int64(MeetingLibrarySchema.currentVersion), at: 1)
                        try MeetingSQLiteConnection.bindInt($0, Date().ms, at: 2)
                    }
                }
            }
        } catch {
            _ = connectionBox.take()
            throw error
        }
    }

    /// Deterministic teardown: closes the SQLite connection — checkpointing and
    /// removing the WAL sidecar — before a test removes the containing directory.
    /// Idempotent; `prepare()` reopens the database on demand.
    func close() { connectionBox.take()?.close() }

    /// Synchronous close for the drained teardown path only (`AttentionStore.
    /// closeLibrarySyncForTeardown`): the caller must guarantee no statement is
    /// in flight — `sqlite3_close_v2` racing `sqlite3_exec` corrupts the
    /// connection. Idempotent; safe from any thread once drained (FULLMUTEX
    /// handle, pointer consumed exactly once via the box).
    nonisolated func closeSync() { connectionBox.take()?.close() }

    /// Last-resort hygiene when the store is released without `close()`: with
    /// FULLMUTEX handles the close is safe from the deallocating thread.
    deinit { connectionBox.take()?.close() }

    private func db() throws -> MeetingSQLiteConnection {
        guard let connection = connectionBox.current() else {
            throw MeetingLibraryError.unavailable("database is closed")
        }
        return connection
    }

    // MARK: Sessions

    func upsertSession(_ session: MeetingSessionRecord) async throws {
        let db = try db()
        try db.run("""
        INSERT INTO meeting_sessions(session_id,title,title_folded,invitation,room_identity,calendar_series_id,continuation_id,started_at,ended_at,time_zone_id,state,export_revision,created_at,updated_at,start_provenance,outcome_end_fallback)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(session_id) DO UPDATE SET
        title=CASE WHEN EXISTS(SELECT 1 FROM meeting_title_overrides WHERE session_id=excluded.session_id) THEN meeting_sessions.title ELSE excluded.title END,
        title_folded=CASE WHEN EXISTS(SELECT 1 FROM meeting_title_overrides WHERE session_id=excluded.session_id) THEN meeting_sessions.title_folded ELSE excluded.title_folded END,invitation=excluded.invitation,
        room_identity=excluded.room_identity,calendar_series_id=excluded.calendar_series_id,
        continuation_id=excluded.continuation_id,started_at=excluded.started_at,ended_at=excluded.ended_at,
        time_zone_id=excluded.time_zone_id,state=excluded.state,export_revision=MAX(meeting_sessions.export_revision,excluded.export_revision),
        updated_at=excluded.updated_at,start_provenance=excluded.start_provenance,outcome_end_fallback=excluded.outcome_end_fallback
        """) {
            try Self.bindText($0, session.id.uuidString, at: 1)
            try Self.bindText($0, session.title, at: 2)
            try Self.bindText($0, MeetingTextNormalization.folded(session.title), at: 3)
            try Self.bindText($0, session.invitation?.absoluteString, at: 4)
            try Self.bindText($0, session.roomIdentity, at: 5)
            try Self.bindText($0, session.calendarSeriesID, at: 6)
            try Self.bindText($0, session.continuationID, at: 7)
            try Self.bindInt($0, session.startedAt.ms, at: 8)
            try Self.bindOptionalInt($0, session.endedAt?.ms, at: 9)
            try Self.bindText($0, session.timeZoneID, at: 10)
            try Self.bindText($0, session.state.rawValue, at: 11)
            try Self.bindInt($0, Int64(session.exportRevision), at: 12)
            try Self.bindInt($0, session.createdAt.ms, at: 13)
            try Self.bindInt($0, session.updatedAt.ms, at: 14)
            try Self.bindText($0, (session.startProvenance ?? .unknown).rawValue, at: 15)
            try Self.bindOptionalInt($0, session.outcomeEndFallback?.ms, at: 16)
        }
    }

    func updateSession(_ sessionID: UUID, title: String? = nil, endedAt: Date? = nil,
                       state: MeetingSessionRecord.State? = nil) async throws -> MeetingSessionRecord? {
        guard var session = try await session(sessionID) else { return nil }
        var exportRevision = session.exportRevision
        if title != nil, title != session.title {
            session.title = title ?? session.title
            exportRevision += 1
        }
        if let endedAt, endedAt != session.endedAt {
            session.endedAt = endedAt
            exportRevision += 1
        }
        if let state, state != session.state {
            session.state = state
            exportRevision += 1
        }
        session.exportRevision = exportRevision
        session.updatedAt = Date()
        try await upsertSession(session)
        return try await self.session(sessionID)
    }

    func renameSession(_ sessionID: UUID, title: String) throws {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw MeetingLibraryError.persistenceFailed("A meeting title is required.") }
        let db = try db()
        try db.transaction {
            guard let row = try db.one("SELECT export_revision,title FROM meeting_sessions WHERE session_id=?", bind: {
                try Self.bindText($0, sessionID.uuidString, at: 1)
            }) else { throw MeetingLibraryError.invalidSession }
            let revision = Int(row.integer(0) ?? 0) + 1
            try db.run("INSERT INTO meeting_title_overrides(session_id,title,original_title) VALUES(?,?,?) ON CONFLICT(session_id) DO UPDATE SET title=excluded.title") {
                try Self.bindText($0, sessionID.uuidString, at: 1)
                try Self.bindText($0, clean, at: 2)
                try Self.bindText($0, row.text(1) ?? "", at: 3)
            }
            try db.run("UPDATE meeting_sessions SET title=?,title_folded=?,export_revision=?,updated_at=? WHERE session_id=?") {
                try Self.bindText($0, clean, at: 1)
                try Self.bindText($0, MeetingTextNormalization.folded(clean), at: 2)
                try Self.bindInt($0, Int64(revision), at: 3)
                try Self.bindInt($0, Date().ms, at: 4)
                try Self.bindText($0, sessionID.uuidString, at: 5)
            }
            _ = try Self.queueOutbox(db: db, sessionID: sessionID, desiredRevision: revision)
        }
    }

    /// Idempotent final participation event; reconnect paths never call this.
    func endSession(_ id: UUID, at date: Date, awaitingOutcome: Bool) throws {
        let db = try db()
        try db.transaction {
            guard let row = try db.one("SELECT export_revision,state FROM meeting_sessions WHERE session_id=?",
                bind: { try Self.bindText($0, id.uuidString, at: 1) }), row.text(1) != "ended" else { return }
            let revision = Int(row.integer(0) ?? 0) + 1
            try db.run("UPDATE meeting_sessions SET ended_at=?,state='ended',export_revision=?,updated_at=? WHERE session_id=?") {
                try Self.bindInt($0, date.ms, at: 1)
                try Self.bindInt($0, Int64(revision), at: 2)
                try Self.bindInt($0, Date().ms, at: 3)
                try Self.bindText($0, id.uuidString, at: 4)
            }
            _ = try Self.queueOutbox(db: db, sessionID: id, desiredRevision: revision,
                                     finalEnd: true, awaitingOutcome: awaitingOutcome)
        }
    }

    func session(_ sessionID: UUID) async throws -> MeetingSessionRecord? {
        let db = try db()
        guard let row = try db.one("SELECT * FROM meeting_sessions WHERE session_id = ?", bind: { try Self.bindText($0, sessionID.uuidString, at: 1) }) else { return nil }
        return Self.session(from: row)
    }

    func sessions(from: Date? = nil, to: Date? = nil) async throws -> [MeetingSessionRecord] {
        let db = try db()
        var sql = "SELECT * FROM meeting_sessions"
        var filters: [String] = []
        var binders: [(OpaquePointer) throws -> Void] = []
        if let from { filters.append("started_at >= ?"); binders.append { try Self.bindInt($0, from.ms, at: Int32(binders.count + 1)) } }
        if let to { filters.append("started_at < ?"); binders.append { try Self.bindInt($0, to.ms, at: Int32(binders.count + 2)) } }
        if !filters.isEmpty { sql += " WHERE " + filters.joined(separator: " AND ") }
        sql += " ORDER BY started_at DESC, session_id DESC"
        var next = 1
        let rows = try db.rows(sql) { statement in
            for binder in binders {
                let index = Int32(next); next += 1
                try binder(statement)
                _ = index
            }
        }
        return rows.map(Self.session(from:))
    }

    // MARK: Notes

    func note(_ sessionID: UUID) async throws -> MeetingNoteRecord? {
        let db = try db()
        guard let row = try db.one("SELECT * FROM meeting_notes WHERE session_id = ?", bind: { try Self.bindText($0, sessionID.uuidString, at: 1) }) else { return nil }
        return try Self.note(from: row)
    }

    /// Commits the note, its bounded search chunks, the aggregate export revision,
    /// and all active destination outbox rows in one transaction.
    @discardableResult
    func saveNote(sessionID: UUID, markdown: String) async throws -> MeetingLibraryNoteCommit {
        let db = try db()
        guard var session = try await self.session(sessionID) else { throw MeetingLibraryError.invalidSession }
        participationNoteChanges.willChange(sessionID)
        return try db.transaction {
            let existing = try db.one("SELECT note_id,revision,created_at FROM meeting_notes WHERE session_id = ?", bind: {
                try Self.bindText($0, sessionID.uuidString, at: 1)
            })
            let noteID = UUID(uuidString: existing?.text(0) ?? "") ?? UUID()
            let revision = Int((existing?.integer(1) ?? 0) + 1)
            let createdAt = Self.date(existing?.integer(2)) ?? Date()
            let now = Date()
            session.exportRevision += 1
            session.updatedAt = now
            try db.run("""
            INSERT INTO meeting_sessions(session_id,title,title_folded,invitation,room_identity,calendar_series_id,continuation_id,started_at,ended_at,time_zone_id,state,export_revision,created_at,updated_at,start_provenance,outcome_end_fallback)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(session_id) DO UPDATE SET export_revision=excluded.export_revision,updated_at=excluded.updated_at
            """) {
                try Self.bindText($0, session.id.uuidString, at: 1)
                try Self.bindText($0, session.title, at: 2)
                try Self.bindText($0, MeetingTextNormalization.folded(session.title), at: 3)
                try Self.bindText($0, session.invitation?.absoluteString, at: 4)
                try Self.bindText($0, session.roomIdentity, at: 5)
                try Self.bindText($0, session.calendarSeriesID, at: 6)
                try Self.bindText($0, session.continuationID, at: 7)
                try Self.bindInt($0, session.startedAt.ms, at: 8)
                try Self.bindOptionalInt($0, session.endedAt?.ms, at: 9)
                try Self.bindText($0, session.timeZoneID, at: 10)
                try Self.bindText($0, session.state.rawValue, at: 11)
                try Self.bindInt($0, Int64(session.exportRevision), at: 12)
                try Self.bindInt($0, session.createdAt.ms, at: 13)
                try Self.bindInt($0, session.updatedAt.ms, at: 14)
                try Self.bindText($0, (session.startProvenance ?? .unknown).rawValue, at: 15)
                try Self.bindOptionalInt($0, session.outcomeEndFallback?.ms, at: 16)
            }
            if existing == nil {
                try db.run("INSERT INTO meeting_notes(note_id,session_id,markdown,revision,created_at,updated_at) VALUES(?,?,?,?,?,?)") {
                    try Self.bindText($0, noteID.uuidString, at: 1)
                    try Self.bindText($0, sessionID.uuidString, at: 2)
                    try Self.bindText($0, markdown, at: 3)
                    try Self.bindInt($0, Int64(revision), at: 4)
                    try Self.bindInt($0, createdAt.ms, at: 5)
                    try Self.bindInt($0, now.ms, at: 6)
                }
            } else {
                try db.run("UPDATE meeting_notes SET markdown=?,revision=?,updated_at=? WHERE session_id=?") {
                    try Self.bindText($0, markdown, at: 1)
                    try Self.bindInt($0, Int64(revision), at: 2)
                    try Self.bindInt($0, now.ms, at: 3)
                    try Self.bindText($0, sessionID.uuidString, at: 4)
                }
            }
            try db.run("DELETE FROM note_chunks WHERE session_id=?") {
                try Self.bindText($0, sessionID.uuidString, at: 1)
            }
            for chunk in MeetingTextNormalization.chunks(for: markdown, noteID: noteID, sessionID: sessionID, revision: revision) {
                try db.run("INSERT INTO note_chunks(id,session_id,note_id,note_revision,ordinal,start_offset,end_offset,start_line,end_line,text,text_folded) VALUES(?,?,?,?,?,?,?,?,?,?,?)") {
                    try Self.bindText($0, chunk.id, at: 1)
                    try Self.bindText($0, chunk.sessionID.uuidString, at: 2)
                    try Self.bindText($0, chunk.noteID.uuidString, at: 3)
                    try Self.bindInt($0, Int64(chunk.noteRevision), at: 4)
                    try Self.bindInt($0, Int64(chunk.ordinal), at: 5)
                    try Self.bindInt($0, Int64(chunk.startOffset), at: 6)
                    try Self.bindInt($0, Int64(chunk.endOffset), at: 7)
                    try Self.bindInt($0, Int64(chunk.startLine), at: 8)
                    try Self.bindInt($0, Int64(chunk.endLine), at: 9)
                    try Self.bindText($0, chunk.text, at: 10)
                    try Self.bindText($0, MeetingTextNormalization.folded(chunk.text), at: 11)
                }
            }
            let queued = try Self.queueOutbox(db: db, sessionID: sessionID, desiredRevision: session.exportRevision)
            return MeetingLibraryNoteCommit(sessionID: sessionID, noteID: noteID, revision: revision,
                exportRevision: session.exportRevision, updatedAt: now, queuedDestinations: queued)
        }
    }

    func noteChunks(_ sessionID: UUID, noteRevision: Int? = nil) async throws -> [MeetingNoteChunk] {
        let db = try db()
        let rows: [MeetingSQLiteRow]
        if let noteRevision {
            rows = try db.rows("SELECT * FROM note_chunks WHERE session_id=? AND note_revision=? ORDER BY ordinal") {
                try Self.bindText($0, sessionID.uuidString, at: 1)
                try Self.bindInt($0, Int64(noteRevision), at: 2)
            }
        } else {
            rows = try db.rows("SELECT * FROM note_chunks WHERE session_id=? ORDER BY ordinal") {
                try Self.bindText($0, sessionID.uuidString, at: 1)
            }
        }
        return rows.map(Self.chunk(from:))
    }

    func searchNotes(query: String, from: Date? = nil, to: Date? = nil, limit: Int = 20) async throws -> [MeetingNoteSearchResult] {
        let folded = MeetingTextNormalization.folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !folded.isEmpty else { return [] }
        let db = try db()
        let pattern = "%" + MeetingTextNormalization.sqlLikeEscaped(folded) + "%"
        var sql = """
        SELECT c.*, s.title, s.started_at
        FROM note_chunks c JOIN meeting_sessions s ON s.session_id=c.session_id
        WHERE c.text_folded LIKE ? ESCAPE '\\'
        """
        var binders: [(OpaquePointer, Int32) throws -> Void] = [ { statement, _ in try Self.bindText(statement, pattern, at: 1) }]
        if let from {
            sql += " AND s.started_at >= ?"
            binders.append { statement, index in try Self.bindInt(statement, from.ms, at: index) }
        }
        if let to {
            sql += " AND s.started_at < ?"
            binders.append { statement, index in try Self.bindInt(statement, to.ms, at: index) }
        }
        sql += " ORDER BY s.started_at DESC, c.ordinal LIMIT ?"
        binders.append { statement, index in try Self.bindInt(statement, Int64(limit), at: index) }
        var next = 1
        let rows = try db.rows(sql) { statement in
            for binder in binders {
                let index = Int32(next); next += 1
                try binder(statement, index)
                _ = index
            }
        }
        return rows.compactMap { row in
            guard let title = row.text(11), let started = row.integer(12) else { return nil }
            return MeetingNoteSearchResult(chunk: Self.chunk(from: Array(row.prefix(11))),
                                           sessionID: UUID(uuidString: row.text(1) ?? "") ?? UUID(),
                                           meetingTitle: title,
                                           startedAt: Self.date(started) ?? .distantPast,
                                           matchedField: "note")
        }
    }

    // MARK: Outcomes

    var legacyOutcomesMigrated: Bool {
        get async {
            guard let db = try? db(), let row = try? db.one("SELECT value FROM meeting_library_meta WHERE key='legacy_outcomes_migrated'") else { return false }
            return row.text(0) == "1"
        }
    }

    func importLegacyOutcomes(_ outcomes: [MeetingOutcome]) async throws {
        guard !outcomes.isEmpty else {
            try await markLegacyOutcomesMigrated()
            return
        }
        let db = try db()
        try db.transaction {
            for outcome in outcomes {
                let sessionID = outcome.meetingID ?? Self.legacySessionID(for: outcome.id)
                if try db.one("SELECT session_id FROM meeting_sessions WHERE session_id=?", bind: { try Self.bindText($0, sessionID.uuidString, at: 1) }) == nil {
                    let now = Date()
                    try db.run("""
                    INSERT INTO meeting_sessions(session_id,title,title_folded,invitation,room_identity,calendar_series_id,continuation_id,started_at,ended_at,time_zone_id,state,export_revision,created_at,updated_at,start_provenance,outcome_end_fallback)
                    VALUES(?,?,?,?,?,?,NULL,?,?,?,?,0,?,?,'outcomeOnly',NULL)
                    """) {
                        try Self.bindText($0, sessionID.uuidString, at: 1)
                        try Self.bindText($0, outcome.meetingTitle, at: 2)
                        try Self.bindText($0, MeetingTextNormalization.folded(outcome.meetingTitle), at: 3)
                        try Self.bindText($0, outcome.invitation?.absoluteString, at: 4)
                        try Self.bindText($0, outcome.invitation.flatMap { MeetingRoomIdentity($0)?.displayDetails }, at: 5)
                        try Self.bindText($0, outcome.seriesID, at: 6)
                        try Self.bindInt($0, Date.distantPast.ms, at: 7)
                        try Self.bindOptionalInt($0, outcome.knownEndedAt?.ms, at: 8)
                        try Self.bindText($0, TimeZone.current.identifier, at: 9)
                        try Self.bindText($0, MeetingSessionRecord.State.ended.rawValue, at: 10)
                        try Self.bindInt($0, now.ms, at: 11)
                        try Self.bindInt($0, now.ms, at: 12)
                    }
                }
                if let seen = try Self.knownOutcomeSession(db: db, outcomeID: outcome.id) {
                    guard seen == sessionID else {
                        throw MeetingLibraryError.migrationFailed("The same outcome ID refers to different sessions.")
                    }
                    continue
                }
                let current = try db.one("SELECT outcome_id FROM meeting_outcomes WHERE session_id=?", bind: {
                    try Self.bindText($0, sessionID.uuidString, at: 1)
                })?.text(0).flatMap(UUID.init(uuidString:))
                let headID: UUID
                if let current, var head = try Self.storedOutcome(db: db, id: current) {
                    let knownTasks = Set(head.tasks.map(\.id))
                    head.tasks += outcome.tasks.filter { !knownTasks.contains($0.id) }
                    try Self.replaceTasks(db: db, outcome: head)
                    try db.run("UPDATE meeting_outcomes SET payload_json=? WHERE outcome_id=?") {
                        try Self.bindBlob($0, JSONEncoder.attention.encode(head), at: 1)
                        try Self.bindText($0, current.uuidString, at: 2)
                    }
                    headID = current
                } else {
                    let payload = try JSONEncoder.attention.encode(outcome)
                    try db.run("""
                        INSERT INTO meeting_outcomes(outcome_id,session_id,state,payload_json,revision,generation_owner,error_code,created_at,updated_at)
                        VALUES(?,?,?,?,1,NULL,NULL,?,?)
                        """) {
                        try Self.bindText($0, outcome.id.uuidString, at: 1)
                        try Self.bindText($0, sessionID.uuidString, at: 2)
                        try Self.bindText($0, MeetingOutcomePersistenceState.ready.rawValue, at: 3)
                        try Self.bindBlob($0, payload, at: 4)
                        try Self.bindInt($0, outcome.endedAt.ms, at: 5)
                        try Self.bindInt($0, outcome.endedAt.ms, at: 6)
                    }
                    try Self.replaceTasks(db: db, outcome: outcome)
                    headID = outcome.id
                }
                // Legacy storage puts the latest saved outcome first. No version
                // timestamp exists in that format. Keep source order rather than
                // treating the meeting end time as a version creation timestamp.
                try Self.recordOutcomeVersion(db: db, outcome: outcome, sessionID: sessionID, revision: 1,
                    savedAt: nil, canonicalOutcomeID: headID)
            }
            try db.run("INSERT INTO meeting_library_meta(key,value) VALUES('legacy_outcomes_migrated','1') ON CONFLICT(key) DO UPDATE SET value='1'") { _ in }
        }
    }

    func markLegacyOutcomesMigrated() async throws {
        let db = try db()
        try db.run("INSERT INTO meeting_library_meta(key,value) VALUES('legacy_outcomes_migrated','1') ON CONFLICT(key) DO UPDATE SET value='1'") { _ in }
    }

    func outcomes() async throws -> [MeetingOutcome] {
        let db = try db()
        return try db.rows("SELECT outcome_id FROM meeting_outcomes WHERE state='ready' ORDER BY updated_at DESC")
            .compactMap { row in
                guard let id = row.text(0).flatMap(UUID.init(uuidString:)) else { return nil }
                return try Self.storedOutcome(db: db, id: id)
            }
    }

    func outcome(_ outcomeID: UUID) async throws -> MeetingOutcome? {
        let db = try db()
        if let head = try Self.storedOutcome(db: db, id: outcomeID) { return head }
        guard let row = try db.one("""
            SELECT v.payload_json,v.session_id,s.title
            FROM meeting_outcome_versions v JOIN meeting_sessions s ON s.session_id=v.session_id
            WHERE v.outcome_id=? ORDER BY v.revision DESC LIMIT 1
            """, bind: { try Self.bindText($0, outcomeID.uuidString, at: 1) }),
              case .blob(let payload)? = row[0] else { return nil }
        var outcome = try JSONDecoder.attention.decode(MeetingOutcome.self, from: payload)
        outcome.meetingID = row.text(1).flatMap(UUID.init(uuidString:))
        outcome.meetingTitle = row.text(2) ?? outcome.meetingTitle
        let linked = try db.rows("""
            SELECT l.historical_task_id,t.payload_json FROM meeting_outcome_task_links l
            JOIN meeting_tasks t ON t.task_id=l.canonical_task_id WHERE l.outcome_id=?
            """, bind: { try Self.bindText($0, outcomeID.uuidString, at: 1) })
        let current = try Dictionary(uniqueKeysWithValues: linked.compactMap { row -> (UUID, MeetingOutcomeTask)? in
            guard let id = row.text(0).flatMap(UUID.init(uuidString:)), case .blob(let data)? = row[1] else { return nil }
            return (id, try JSONDecoder.attention.decode(MeetingOutcomeTask.self, from: data))
        })
        outcome.tasks = outcome.tasks.map { current[$0.id] ?? $0 }
        return outcome
    }

    func outcomeVersions(sessionID: UUID) throws -> [MeetingOutcomeVersion] {
        let db = try db()
        let head = try db.one("SELECT outcome_id,revision,updated_at FROM meeting_outcomes WHERE session_id=? AND state='ready'", bind: {
            try Self.bindText($0, sessionID.uuidString, at: 1)
        })
        var current: MeetingOutcomeVersion?
        if let head, let id = head.text(0).flatMap(UUID.init(uuidString:)),
           let outcome = try Self.storedOutcome(db: db, id: id) {
            current = MeetingOutcomeVersion(outcome: outcome, revision: Int(head.integer(1) ?? 1),
                savedAt: Self.date(head.integer(2)), isCurrent: true)
        }
        let rows = try db.rows("""
            SELECT payload_json,revision,saved_at FROM meeting_outcome_versions
            WHERE session_id=? ORDER BY saved_at DESC,rowid ASC
            """, bind: { try Self.bindText($0, sessionID.uuidString, at: 1) })
        let history = try rows.compactMap { row -> MeetingOutcomeVersion? in
            guard case .blob(let payload)? = row[0] else { return nil }
            var outcome = try JSONDecoder.attention.decode(MeetingOutcome.self, from: payload)
            outcome.meetingID = sessionID
            let revision = Int(row.integer(1) ?? 1)
            guard current?.outcome.id != outcome.id || current?.revision != revision else { return nil }
            return MeetingOutcomeVersion(outcome: outcome, revision: revision, savedAt: Self.date(row.integer(2)), isCurrent: false)
        }
        return (current.map { [$0] } ?? []) + history
    }

    @discardableResult
    func saveOutcome(_ outcome: MeetingOutcome, state: MeetingOutcomePersistenceState,
                     generationOwner: String? = nil, errorCode: String? = nil) async throws -> MeetingOutcomeCommit {
        try commitOutcome(outcome, state: state, generationOwner: generationOwner, errorCode: errorCode)
    }

    func saveOutcomeEdits(_ edits: [MeetingOutcomeEdit]) throws -> MeetingOutcomeCommit? {
        guard let first = edits.first else { return nil }
        return try commitOutcome(first.edited, state: .ready, edits: edits)
    }

    @discardableResult
    func startOutcome(_ outcome: MeetingOutcome, input: MeetingOutcomeInput, owner: String) throws -> MeetingOutcome {
        var draft = outcome
        if let sessionID = draft.meetingID,
           let row = try db().one("SELECT outcome_id FROM meeting_outcomes WHERE session_id=?", bind: {
               try Self.bindText($0, sessionID.uuidString, at: 1)
           }), let current = row.text(0).flatMap(UUID.init(uuidString:)) {
            draft.id = current
        }
        return try commitOutcome(draft, state: .pending, generationOwner: owner, input: input).outcome
    }

    func outcomeInput(_ id: UUID) throws -> MeetingOutcomeInput? {
        let db = try db()
        guard let row = try db.one("SELECT input_json FROM meeting_outcome_inputs WHERE outcome_id=?", bind: {
            try Self.bindText($0, id.uuidString, at: 1)
        }), case .blob(let payload)? = row[0] ?? nil else { return nil }
        return try JSONDecoder().decode(MeetingOutcomeInput.self, from: payload)
    }

    func claimOutcomeRetry(_ id: UUID, owner: String) throws -> MeetingOutcome? {
        let db = try db()
        return try db.transaction {
            let row = try db.one("""
                UPDATE meeting_outcomes SET state='pending', generation_owner=?, error_code=NULL, updated_at=?
                WHERE outcome_id=? AND state='failed'
                  AND EXISTS(SELECT 1 FROM meeting_outcome_inputs WHERE outcome_id=meeting_outcomes.outcome_id)
                RETURNING payload_json
                """) {
                try Self.bindText($0, owner, at: 1)
                try Self.bindInt($0, Date().ms, at: 2)
                try Self.bindText($0, id.uuidString, at: 3)
            }
            guard case .blob(let payload)? = row?[0] else { return nil }
            return try JSONDecoder.attention.decode(MeetingOutcome.self, from: payload)
        }
    }

    private struct OutcomeClaimLost: Error {}

    func finishOutcome(_ outcome: MeetingOutcome, owner: String, errorCode: String?) throws -> MeetingOutcomeCommit? {
        do {
            return try commitOutcome(outcome, state: errorCode == nil ? .ready : .failed,
                                     errorCode: errorCode, expectedOwner: owner)
        } catch is OutcomeClaimLost { return nil }
    }

    private func commitOutcome(_ outcome: MeetingOutcome, state: MeetingOutcomePersistenceState,
                               generationOwner: String? = nil, errorCode: String? = nil,
                               input: MeetingOutcomeInput? = nil, expectedOwner: String? = nil,
                               edits: [MeetingOutcomeEdit] = []) throws -> MeetingOutcomeCommit {
        let db = try db()
        let sessionID = outcome.meetingID ?? Self.legacySessionID(for: outcome.id)
        var outcome = outcome
        outcome.meetingID = sessionID
        return try db.transaction {
            let previous = try Self.storedOutcome(db: db, id: outcome.id)
            var state = state
            var generationOwner = generationOwner
            var errorCode = errorCode
            if !edits.isEmpty {
                outcome = edits.reduce(previous ?? outcome) { $1.apply(to: $0) }
                outcome.meetingID = sessionID
            }
            if edits.first?.baseline != nil, let previous {
                // Editing a displayed outcome must leave a running or failed generation
                // claim and its retained input available to the generation workflow.
                if let row = try db.one("SELECT state,generation_owner,error_code FROM meeting_outcomes WHERE outcome_id=?", bind: {
                    try Self.bindText($0, previous.id.uuidString, at: 1)
                }), let current = row.text(0).flatMap(MeetingOutcomePersistenceState.init(rawValue:)) {
                    state = current
                    generationOwner = row.text(1)
                    errorCode = row.text(2)
                }
            }
            if input != nil, let previous {
                if let stored = try db.one("SELECT revision,state,updated_at FROM meeting_outcomes WHERE outcome_id=?", bind: {
                    try Self.bindText($0, previous.id.uuidString, at: 1)
                }), stored.text(1) == MeetingOutcomePersistenceState.ready.rawValue {
                    try Self.recordOutcomeVersion(db: db, outcome: previous, sessionID: sessionID,
                        revision: Int(stored.integer(0) ?? 1), savedAt: Self.date(stored.integer(2)), canonicalOutcomeID: previous.id)
                }
                outcome.tasks = previous.tasks
                outcome.taskReviewCandidates = previous.taskReviewCandidates
                outcome.taskReviewMatches = previous.taskReviewMatches
            }
            if let expectedOwner {
                guard try db.one("SELECT outcome_id FROM meeting_outcomes WHERE outcome_id=? AND state='pending' AND generation_owner=?", bind: {
                    try Self.bindText($0, outcome.id.uuidString, at: 1)
                    try Self.bindText($0, expectedOwner, at: 2)
                }) != nil else { throw OutcomeClaimLost() }
                if let previous, !previous.tasks.isEmpty {
                    if state == .ready {
                        // Generated tasks have no authoritative links to existing tasks.
                        // Keep existing tasks and require explicit acceptance of candidates.
                        outcome.taskReviewCandidates = outcome.tasks
                    }
                    outcome.tasks = previous.tasks
                }
            }
            if try db.one("SELECT session_id FROM meeting_sessions WHERE session_id=?", bind: { try Self.bindText($0, sessionID.uuidString, at: 1) }) == nil {
                let now = Date()
                try db.run("""
                INSERT INTO meeting_sessions(session_id,title,title_folded,invitation,room_identity,calendar_series_id,continuation_id,started_at,ended_at,time_zone_id,state,export_revision,created_at,updated_at,start_provenance,outcome_end_fallback)
                VALUES(?,?,?,?,?,?,NULL,?,?,?,?,1,?,?,'outcomeOnly',NULL)
                """) {
                    try Self.bindText($0, sessionID.uuidString, at: 1)
                    try Self.bindText($0, outcome.meetingTitle, at: 2)
                    try Self.bindText($0, MeetingTextNormalization.folded(outcome.meetingTitle), at: 3)
                    try Self.bindText($0, outcome.invitation?.absoluteString, at: 4)
                    try Self.bindText($0, outcome.invitation.flatMap { MeetingRoomIdentity($0)?.displayDetails }, at: 5)
                    try Self.bindText($0, outcome.seriesID, at: 6)
                    try Self.bindInt($0, Date.distantPast.ms, at: 7)
                    try Self.bindOptionalInt($0, outcome.knownEndedAt?.ms, at: 8)
                    try Self.bindText($0, TimeZone.current.identifier, at: 9)
                    try Self.bindText($0, MeetingSessionRecord.State.ended.rawValue, at: 10)
                    try Self.bindInt($0, now.ms, at: 11)
                    try Self.bindInt($0, now.ms, at: 12)
                }
            }
            if let row = try db.one("SELECT title FROM meeting_sessions WHERE session_id=?", bind: {
                try Self.bindText($0, sessionID.uuidString, at: 1)
            }), let title = row.text(0) { outcome.meetingTitle = title }
            let existing = try db.one("SELECT revision FROM meeting_outcomes WHERE outcome_id=?", bind: { try Self.bindText($0, outcome.id.uuidString, at: 1) })
            let revision = Int((existing?.integer(0) ?? 0) + 1)
            let now = Date()
            let payload = try JSONEncoder.attention.encode(outcome)
            try db.run("""
            INSERT INTO meeting_outcomes(outcome_id,session_id,state,payload_json,revision,generation_owner,error_code,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(outcome_id) DO UPDATE SET session_id=excluded.session_id,state=excluded.state,payload_json=excluded.payload_json,revision=excluded.revision,generation_owner=excluded.generation_owner,error_code=excluded.error_code,updated_at=excluded.updated_at
            """) {
                try Self.bindText($0, outcome.id.uuidString, at: 1)
                try Self.bindText($0, sessionID.uuidString, at: 2)
                try Self.bindText($0, state.rawValue, at: 3)
                try Self.bindBlob($0, payload, at: 4)
                try Self.bindInt($0, Int64(revision), at: 5)
                try Self.bindText($0, generationOwner, at: 6)
                try Self.bindText($0, errorCode, at: 7)
                try Self.bindInt($0, outcome.endedAt.ms, at: 8)
                try Self.bindInt($0, now.ms, at: 9)
            }
            try Self.replaceTasks(db: db, outcome: outcome)
            if state == .ready, previous == nil || expectedOwner != nil {
                try Self.recordOutcomeVersion(db: db, outcome: outcome, sessionID: sessionID, revision: revision,
                    savedAt: now, canonicalOutcomeID: outcome.id)
            }
            if let previous {
                let current = Dictionary(uniqueKeysWithValues: outcome.tasks.map { ($0.id, $0) })
                for task in previous.tasks where task.reminderAt != nil {
                    let updated = current[task.id]
                    if updated == nil || updated?.done == true || updated?.owner != task.owner ||
                        updated?.assigneeID != task.assigneeID || updated?.reminderAt == nil {
                        try Self.cancelTaskReminder(db: db, taskID: task.id)
                    }
                }
            }
            if let input {
                let payload = try JSONEncoder().encode(input)
                try db.run("""
                    INSERT INTO meeting_outcome_inputs(outcome_id,input_json) VALUES(?,?)
                    ON CONFLICT(outcome_id) DO UPDATE SET input_json=excluded.input_json
                    """) {
                    try Self.bindText($0, outcome.id.uuidString, at: 1)
                    try Self.bindBlob($0, payload, at: 2)
                }
            } else if state == .ready {
                try db.run("DELETE FROM meeting_outcome_inputs WHERE outcome_id=?") {
                    try Self.bindText($0, outcome.id.uuidString, at: 1)
                }
            }
            let updatedSession = try db.one("SELECT export_revision FROM meeting_sessions WHERE session_id=?", bind: { try Self.bindText($0, sessionID.uuidString, at: 1) })
            let exportRevision = Int((updatedSession?.integer(0) ?? 0) + 1)
            try db.run("UPDATE meeting_sessions SET export_revision=?,updated_at=? WHERE session_id=?") {
                try Self.bindInt($0, Int64(exportRevision), at: 1)
                try Self.bindInt($0, now.ms, at: 2)
                try Self.bindText($0, sessionID.uuidString, at: 3)
            }
            let queued = try Self.queueOutbox(db: db, sessionID: sessionID, desiredRevision: exportRevision,
                                              outcomeReady: state == .ready)
            _ = queued
            return MeetingOutcomeCommit(outcomeID: outcome.id, sessionID: sessionID, state: state, outcome: outcome,
                                        revision: revision, exportRevision: exportRevision, updatedAt: now)
        }
    }

    func removeOutcome(_ outcomeID: UUID) async throws {
        let db = try db()
        try db.transaction {
            let sessionID = try Self.knownOutcomeSession(db: db, outcomeID: outcomeID)
            let isHead = try db.one("SELECT 1 FROM meeting_outcomes WHERE outcome_id=?", bind: {
                try Self.bindText($0, outcomeID.uuidString, at: 1)
            }) != nil
            try db.run("DELETE FROM meeting_outcomes WHERE outcome_id=?") { try Self.bindText($0, outcomeID.uuidString, at: 1) }
            for table in ["meeting_outcome_task_links", "meeting_outcome_versions"] {
                if isHead, let sessionID {
                    try db.run("DELETE FROM \(table) WHERE session_id=?") { try Self.bindText($0, sessionID.uuidString, at: 1) }
                } else {
                    try db.run("DELETE FROM \(table) WHERE outcome_id=?") { try Self.bindText($0, outcomeID.uuidString, at: 1) }
                }
            }
        }
    }

    // MARK: Data clearing

    func deleteAll() async throws {
        participationNoteChanges.willChange()
        let db = try db()
        try db.transaction {
            for table in ["export_outbox", "export_bindings", "export_destinations", "note_chunks", "meeting_notes", "meeting_outcomes", "meeting_sessions"] {
                try db.execute("DELETE FROM \(table)")
            }
        }
    }

    // MARK: Binding helpers

    /// Called from the same transaction as every exportable change.
    private static func queueOutbox(db: MeetingSQLiteConnection, sessionID: UUID, desiredRevision: Int,
                                    outcomeReady: Bool = false, finalEnd: Bool = false,
                                    awaitingOutcome: Bool = false) throws -> Int {
        guard let destination = try activeDestination(db) else { return 0 }
        let linked = try isObsidianLinked(db: db, destination: destination, sessionID: sessionID)
        let stage = try db.one("SELECT stage FROM export_initial_state WHERE destination_id=? AND session_id=?",
            bind: { try bindExportKey($0, destination: destination.id, session: sessionID) })?.text(0)
        let after = destination.enabled && destination.saveAfterMeeting
        let sync = destination.enabled && destination.syncChanges
        let intent: ObsidianExportIntent
        let held: Bool
        var forcedState: MeetingOutcomePersistenceState?
        if finalEnd, after, stage == nil {
            let existingState = try db.one("SELECT state FROM meeting_outcomes WHERE session_id=?",
                bind: { try bindText($0, sessionID.uuidString, at: 1) })?.text(0)
            let wait = existingState != MeetingOutcomePersistenceState.ready.rawValue && awaitingOutcome
            try setInitialStage(wait ? "waiting" : "complete", db: db, destination: destination.id, session: sessionID)
            forcedState = wait && existingState == nil ? .pending : nil
            intent = .initialEnd
            held = false
        } else if outcomeReady, stage == "waiting" || stage == "held" {
            try setInitialStage("complete", db: db, destination: destination.id, session: sessionID)
            intent = after && stage == "waiting" || !sync || !linked ? .initialFirstReady : .linkedUpdate
            held = intent == .initialFirstReady && (!after || stage == "held")
        } else if sync, linked {
            intent = .linkedUpdate
            held = false
        } else {
            return 0
        }
        guard var snapshot = try exportSnapshot(db, sessionID: sessionID),
              snapshot.session.exportRevision == desiredRevision else { return 0 }
        if let forcedState { snapshot.outcomeState = forcedState }
        try putExport(db: db, destination: destination, snapshot: snapshot, intent: intent, held: held)
        return 1
    }

    private static func isObsidianLinked(db: MeetingSQLiteConnection, destination: ObsidianDestinationRecord,
                                        sessionID: UUID) throws -> Bool {
        let key = { try bindExportKey($0, destination: destination.id, session: sessionID) }
        if try db.one("SELECT 1 FROM export_completed_deliveries WHERE destination_id=? AND session_id=?",
                      bind: key) != nil { return true }
        // Older releases only supported individual meeting files and recorded the
        // complete delivery in that component's binding.
        guard destination.mode == .separateFiles else { return false }
        return try db.one("""
            SELECT 1 FROM export_bindings WHERE destination_id=? AND session_id=?
            AND component='meeting' AND last_exported_revision>0
            """, bind: key) != nil
    }

    private static func bindExportKey(_ statement: OpaquePointer, destination: UUID, session: UUID) throws {
        try bindText(statement, destination.uuidString, at: 1)
        try bindText(statement, session.uuidString, at: 2)
    }

    private static func setInitialStage(_ stage: String, db: MeetingSQLiteConnection, destination: UUID, session: UUID) throws {
        try db.run("""
        INSERT INTO export_initial_state(destination_id,session_id,stage) VALUES(?,?,?)
        ON CONFLICT(destination_id,session_id) DO UPDATE SET stage=excluded.stage
        """) {
            try bindExportKey($0, destination: destination, session: session)
            try bindText($0, stage, at: 3)
        }
    }

    private static func exportSnapshot(_ db: MeetingSQLiteConnection, sessionID: UUID) throws -> ObsidianExportSnapshot? {
        guard let row = try db.one("SELECT * FROM meeting_sessions WHERE session_id=?",
            bind: { try bindText($0, sessionID.uuidString, at: 1) }) else { return nil }
        let noteRow = try db.one("SELECT * FROM meeting_notes WHERE session_id=?",
            bind: { try bindText($0, sessionID.uuidString, at: 1) })
        let outcomeRow = try db.one("SELECT outcome_id,state FROM meeting_outcomes WHERE session_id=?",
            bind: { try bindText($0, sessionID.uuidString, at: 1) })
        let outcome = try outcomeRow?.text(0).flatMap(UUID.init(uuidString:)).flatMap { try storedOutcome(db: db, id: $0) }
        return ObsidianExportSnapshot(session: session(from: row), note: try noteRow.map(note(from:)),
            outcome: outcome, outcomeState: outcomeRow?.text(1).flatMap(MeetingOutcomePersistenceState.init(rawValue:)) ?? .notStarted)
    }

    func manualExportSnapshots(sessionIDs: [UUID]) throws -> [ObsidianExportSnapshot] {
        let db = try db()
        return try db.transaction {
            try sessionIDs.compactMap { try Self.exportSnapshot(db, sessionID: $0) }
        }
    }

    private static func putExport(db: MeetingSQLiteConnection, destination: ObsidianDestinationRecord,
                                  snapshot: ObsidianExportSnapshot, intent: ObsidianExportIntent, held: Bool) throws {
        let sessionID = snapshot.session.id
        let existing = try db.one("SELECT intent,policy_held FROM export_outbox WHERE destination_id=? AND session_id=?",
            bind: { try bindExportKey($0, destination: destination.id, session: sessionID) })
        let currentIntent = existing?.text(0).flatMap(ObsidianExportIntent.init(rawValue:))
        if currentIntent == .manualSave && intent != .manualSave ||
            currentIntent != nil && existing?.bool(1) == false && intent == .linkedUpdate && currentIntent != .linkedUpdate {
            try db.run("""
            INSERT INTO export_deferred(destination_id,session_id,intent,revision,snapshot_json,policy_held)
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(destination_id,session_id,intent) DO UPDATE SET
                revision=excluded.revision,snapshot_json=excluded.snapshot_json,policy_held=excluded.policy_held
            WHERE excluded.revision >= revision
            """) {
                try bindExportKey($0, destination: destination.id, session: sessionID)
                try bindText($0, intent.rawValue, at: 3)
                try bindInt($0, Int64(snapshot.session.exportRevision), at: 4)
                try bindBlob($0, JSONEncoder.attention.encode(snapshot), at: 5)
                try bindInt($0, held ? 1 : 0, at: 6)
            }
            return
        }
        try db.run("""
        INSERT INTO export_outbox(destination_id,session_id,desired_revision,desired_config_revision,attempt_count,
            next_attempt_at,paused,last_error_code,updated_at,intent,snapshot_json,policy_held)
        VALUES(?,?,?,?,0,0,0,NULL,?,?,?,?)
        ON CONFLICT(destination_id,session_id) DO UPDATE SET
            desired_revision=excluded.desired_revision,desired_config_revision=excluded.desired_config_revision,
            attempt_count=CASE WHEN paused=1 THEN attempt_count ELSE 0 END,
            next_attempt_at=CASE WHEN paused=1 THEN next_attempt_at ELSE 0 END,
            last_error_code=CASE WHEN paused=1 THEN last_error_code ELSE NULL END,updated_at=excluded.updated_at,
            intent=excluded.intent,snapshot_json=excluded.snapshot_json,policy_held=excluded.policy_held
        WHERE excluded.desired_revision >= desired_revision
        """) {
            try bindExportKey($0, destination: destination.id, session: snapshot.session.id)
            try bindInt($0, Int64(snapshot.session.exportRevision), at: 3)
            try bindInt($0, Int64(destination.configRevision), at: 4)
            try bindInt($0, Date().ms, at: 5)
            try bindText($0, intent.rawValue, at: 6)
            try bindBlob($0, JSONEncoder.attention.encode(snapshot), at: 7)
            try bindInt($0, held ? 1 : 0, at: 8)
        }
    }

    private static func promoteDeferred(db: MeetingSQLiteConnection, destination: ObsidianDestinationRecord,
                                        sessionID: UUID, through revision: Int? = nil) throws {
        if let revision {
            try db.run("DELETE FROM export_deferred WHERE destination_id=? AND session_id=? AND revision<=?") {
                try bindExportKey($0, destination: destination.id, session: sessionID)
                try bindInt($0, Int64(revision), at: 3)
            }
        }
        guard let next = try db.one("""
            SELECT intent,snapshot_json FROM export_deferred
            WHERE destination_id=? AND session_id=? AND policy_held=0 ORDER BY revision LIMIT 1
            """, bind: { try bindExportKey($0, destination: destination.id, session: sessionID) }),
            let intent = next.text(0).flatMap(ObsidianExportIntent.init(rawValue:)),
            intent.permitted(by: destination), case .blob(let data)? = next[1] else { return }
        let snapshot = try JSONDecoder.attention.decode(ObsidianExportSnapshot.self, from: data)
        let head = try db.one("SELECT policy_held,desired_revision FROM export_outbox WHERE destination_id=? AND session_id=?",
            bind: { try bindExportKey($0, destination: destination.id, session: sessionID) })
        guard head == nil || head?.bool(0) == true && (head?.integer(1) ?? 0) <= snapshot.session.exportRevision else { return }
        try putExport(db: db, destination: destination, snapshot: snapshot, intent: intent, held: false)
        try db.run("DELETE FROM export_deferred WHERE destination_id=? AND session_id=? AND intent=?") {
            try bindExportKey($0, destination: destination.id, session: sessionID)
            try bindText($0, intent.rawValue, at: 3)
        }
    }

    private static func legacySessionID(for outcomeID: UUID) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("meeting-session-legacy-outcome-\(outcomeID.uuidString)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }

    private static func migrateMeetingDateProvenance(db: MeetingSQLiteConnection) throws {
        // The outcome-only constructors always created ended rows without a
        // continuation. A local note created while an actual session was still
        // open also proves the session existed before its outcome-only import.
        try db.execute("""
            UPDATE meeting_sessions SET start_provenance='recorded'
            WHERE state IN ('joining','active','reconnecting','failed')
               OR continuation_id IS NOT NULL
               OR EXISTS(SELECT 1 FROM meeting_notes n WHERE n.session_id=meeting_sessions.session_id
                    AND n.created_at>=meeting_sessions.created_at AND n.created_at<meeting_sessions.ended_at)
            """)
        let outcomes = try db.rows("""
            SELECT o.outcome_id,o.session_id,s.ended_at,o.payload_json
            FROM meeting_outcomes o JOIN meeting_sessions s ON s.session_id=o.session_id
            """)
        for row in outcomes {
            guard let outcomeID = row.text(0).flatMap(UUID.init(uuidString:)),
                  let sessionID = row.text(1).flatMap(UUID.init(uuidString:)),
                  sessionID == legacySessionID(for: outcomeID) else { continue }
            let fallback: Int64?
            if row.integer(2) == nil, case .blob(let payload)? = row[3],
               let outcome = try? JSONDecoder.attention.decode(MeetingOutcome.self, from: payload),
               outcome.endedAt != .distantPast {
                fallback = outcome.endedAt.ms
            } else {
                fallback = nil
            }
            try db.run("""
                UPDATE meeting_sessions SET start_provenance='outcomeOnly',outcome_end_fallback=?
                WHERE session_id=?
                """) {
                try bindOptionalInt($0, fallback, at: 1)
                try bindText($0, sessionID.uuidString, at: 2)
            }
        }
    }

    private static func session(from row: MeetingSQLiteRow) -> MeetingSessionRecord {
        MeetingSessionRecord(
            id: UUID(uuidString: row.text(0) ?? UUID().uuidString) ?? UUID(),
            title: row.text(1) ?? "",
            invitation: row.text(3).flatMap(URL.init(string:)),
            roomIdentity: row.text(4) ?? "",
            calendarSeriesID: row.text(5),
            continuationID: row.text(6),
            startedAt: Self.date(row.integer(7)) ?? .distantPast,
            endedAt: Self.date(row.integer(8)),
            timeZoneID: row.text(9) ?? TimeZone.current.identifier,
            state: MeetingSessionRecord.State(rawValue: row.text(10) ?? "") ?? .active,
            exportRevision: Int(row.integer(11) ?? 0),
            createdAt: Self.date(row.integer(12)) ?? .distantPast,
            updatedAt: Self.date(row.integer(13)) ?? .distantPast,
            startProvenance: row.text(14).flatMap(MeetingStartProvenance.init(rawValue:)),
            outcomeEndFallback: Self.date(row.integer(15))
        )
    }

    private static func note(from row: MeetingSQLiteRow) throws -> MeetingNoteRecord {
        guard let id = UUID(uuidString: row.text(0) ?? ""), let sessionID = UUID(uuidString: row.text(1) ?? "") else {
            throw MeetingLibraryError.persistenceFailed("invalid note identity")
        }
        return MeetingNoteRecord(id: id, sessionID: sessionID, markdown: row.text(2) ?? "",
                                 revision: Int(row.integer(3) ?? 0), createdAt: Self.date(row.integer(4)) ?? .distantPast,
                                 updatedAt: Self.date(row.integer(5)) ?? .distantPast)
    }

    private static func chunk(from row: MeetingSQLiteRow) -> MeetingNoteChunk {
        MeetingNoteChunk(
            id: row.text(0) ?? UUID().uuidString,
            sessionID: UUID(uuidString: row.text(1) ?? "") ?? UUID(),
            noteID: UUID(uuidString: row.text(2) ?? "") ?? UUID(),
            noteRevision: Int(row.integer(3) ?? 0),
            ordinal: Int(row.integer(4) ?? 0),
            startOffset: Int(row.integer(5) ?? 0),
            endOffset: Int(row.integer(6) ?? 0),
            startLine: Int(row.integer(7) ?? 0),
            endLine: Int(row.integer(8) ?? 0),
            text: row.text(9) ?? ""
        )
    }

    private static func bindText(_ statement: OpaquePointer, _ value: String?, at index: Int32) throws {
        try MeetingSQLiteConnection.bindText(statement, value, at: index)
    }
    private static func bindInt(_ statement: OpaquePointer, _ value: Int64, at index: Int32) throws {
        try MeetingSQLiteConnection.bindInt(statement, value, at: index)
    }
    private static func bindOptionalInt(_ statement: OpaquePointer, _ value: Int64?, at index: Int32) throws {
        if let value { try MeetingSQLiteConnection.bindInt(statement, value, at: index) }
        else { try MeetingSQLiteConnection.bindNull(statement, at: index) }
    }
    private static func bindBlob(_ statement: OpaquePointer, _ value: Data?, at index: Int32) throws {
        try MeetingSQLiteConnection.bindBlob(statement, value, at: index)
    }
    private static func date(_ value: Int64?) -> Date? {
        value.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }
}

private extension Date {
    var ms: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}

// MARK: - Personal tasks

extension MeetingLibraryStore {
    private static func knownOutcomeSession(db: MeetingSQLiteConnection, outcomeID: UUID) throws -> UUID? {
        try db.one("""
            SELECT session_id FROM meeting_outcomes WHERE outcome_id=?1
            UNION ALL SELECT session_id FROM meeting_outcome_versions WHERE outcome_id=?1 LIMIT 1
            """, bind: { try bindText($0, outcomeID.uuidString, at: 1) })?.text(0).flatMap(UUID.init(uuidString:))
    }

    private static func recordOutcomeVersion(db: MeetingSQLiteConnection, outcome: MeetingOutcome, sessionID: UUID,
                                             revision: Int, savedAt: Date?, canonicalOutcomeID: UUID) throws {
        let payload = try JSONEncoder.attention.encode(outcome)
        try db.run("""
            INSERT OR IGNORE INTO meeting_outcome_versions(outcome_id,revision,session_id,payload_json,saved_at)
            VALUES(?,?,?,?,?)
            """) {
            try bindText($0, outcome.id.uuidString, at: 1)
            try bindInt($0, Int64(revision), at: 2)
            try bindText($0, sessionID.uuidString, at: 3)
            try bindBlob($0, payload, at: 4)
            try bindOptionalInt($0, savedAt?.ms, at: 5)
        }
        for task in outcome.tasks {
            try db.run("""
                INSERT OR IGNORE INTO meeting_outcome_task_links(outcome_id,historical_task_id,session_id,canonical_task_id)
                SELECT ?1,?2,?3,task_id FROM meeting_tasks WHERE task_id=?2 AND outcome_id=?4
                """) {
                try bindText($0, outcome.id.uuidString, at: 1)
                try bindText($0, task.id.uuidString, at: 2)
                try bindText($0, sessionID.uuidString, at: 3)
                try bindText($0, canonicalOutcomeID.uuidString, at: 4)
            }
        }
    }

    private static func migrateOutcomeVersions(db: MeetingSQLiteConnection) throws {
        for row in try db.rows("SELECT outcome_id,session_id,revision,updated_at FROM meeting_outcomes WHERE state='ready'") {
            guard let id = row.text(0).flatMap(UUID.init(uuidString:)),
                  let sessionID = row.text(1).flatMap(UUID.init(uuidString:)),
                  let outcome = try storedOutcome(db: db, id: id) else { continue }
            try recordOutcomeVersion(db: db, outcome: outcome, sessionID: sessionID,
                revision: Int(row.integer(2) ?? 1), savedAt: date(row.integer(3)), canonicalOutcomeID: id)
        }
    }

    private static func storedOutcome(db: MeetingSQLiteConnection, id: UUID) throws -> MeetingOutcome? {
        guard let row = try db.one("""
            SELECT o.payload_json, s.session_id, s.title
            FROM meeting_outcomes o JOIN meeting_sessions s ON s.session_id=o.session_id WHERE o.outcome_id=?
            """, bind: { try bindText($0, id.uuidString, at: 1) }),
              case .blob(let data)? = row[0] else { return nil }
        var outcome = try JSONDecoder.attention.decode(MeetingOutcome.self, from: data)
        outcome.meetingID = row.text(1).flatMap(UUID.init(uuidString:)) ?? outcome.meetingID
        outcome.meetingTitle = row.text(2) ?? outcome.meetingTitle
        outcome.tasks = try db.rows("SELECT payload_json FROM meeting_tasks WHERE outcome_id=? ORDER BY ordinal", bind: {
            try bindText($0, id.uuidString, at: 1)
        }).map { row in
            guard case .blob(let data)? = row[0] else { throw MeetingLibraryError.persistenceFailed("missing task payload") }
            return try JSONDecoder.attention.decode(MeetingOutcomeTask.self, from: data)
        }
        return outcome
    }

    private static func migrateTasks(db: MeetingSQLiteConnection) throws {
        for row in try db.rows("SELECT outcome_id, payload_json FROM meeting_outcomes") {
            guard let id = row.text(0), case .blob(let data)? = row[1] else {
                throw MeetingLibraryError.persistenceFailed("missing outcome payload during migration")
            }
            let outcome = try JSONDecoder.attention.decode(MeetingOutcome.self, from: data)
            guard outcome.id.uuidString == id else {
                throw MeetingLibraryError.persistenceFailed("outcome identity differs from its saved payload")
            }
            try replaceTasks(db: db, outcome: outcome)
            // Materialize IDs once for older payloads that did not carry task IDs.
            let payload = try JSONEncoder.attention.encode(outcome)
            try db.run("UPDATE meeting_outcomes SET payload_json=? WHERE outcome_id=?") {
                try bindBlob($0, payload, at: 1)
                try bindText($0, id, at: 2)
            }
        }
    }

    private static func replaceTasks(db: MeetingSQLiteConnection, outcome: MeetingOutcome) throws {
        let desired = Set(outcome.tasks.map { $0.id.uuidString })
        guard desired.count == outcome.tasks.count else {
            throw MeetingLibraryError.persistenceFailed("duplicate task identifier")
        }
        let existing = try db.rows("SELECT task_id FROM meeting_tasks WHERE outcome_id=?", bind: {
            try bindText($0, outcome.id.uuidString, at: 1)
        }).compactMap { $0.text(0) }
        for id in existing where !desired.contains(id) {
            try db.run("DELETE FROM meeting_tasks WHERE task_id=?") { try bindText($0, id, at: 1) }
        }
        for (ordinal, task) in outcome.tasks.enumerated() {
            let payload = try JSONEncoder.attention.encode(task)
            let saved = try db.one("""
                INSERT INTO meeting_tasks(task_id,outcome_id,ordinal,payload_json) VALUES(?,?,?,?)
                ON CONFLICT(task_id) DO UPDATE SET ordinal=excluded.ordinal,payload_json=excluded.payload_json
                WHERE meeting_tasks.outcome_id=excluded.outcome_id RETURNING task_id
                """) {
                try bindText($0, task.id.uuidString, at: 1)
                try bindText($0, outcome.id.uuidString, at: 2)
                try bindInt($0, Int64(ordinal), at: 3)
                try bindBlob($0, payload, at: 4)
            }
            guard saved != nil else { throw MeetingLibraryError.persistenceFailed("duplicate task identifier") }
        }
    }

    func taskProfile() throws -> PersonalTaskProfile {
        let db = try db()
        if let row = try db.one("SELECT value FROM meeting_library_meta WHERE key='personal_task_profile'"),
           let json = row.text(0) {
            return try JSONDecoder().decode(PersonalTaskProfile.self, from: Data(json.utf8))
        }
        let profile = PersonalTaskProfile(id: UUID().uuidString)
        try saveTaskProfile(profile)
        return profile
    }

    func saveTaskProfile(_ profile: PersonalTaskProfile) throws {
        let db = try db()
        let json = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        try db.transaction {
            try db.run("""
                INSERT INTO meeting_library_meta(key,value) VALUES('personal_task_profile',?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """) { try Self.bindText($0, json, at: 1) }
            for row in try db.rows("SELECT payload_json FROM meeting_tasks") {
                guard case .blob(let data)? = row[0] else { continue }
                let task = try JSONDecoder.attention.decode(MeetingOutcomeTask.self, from: data)
                if task.reminderAt != nil && !profile.owns(task) {
                    try Self.cancelTaskReminder(db: db, taskID: task.id)
                }
            }
        }
    }

    func taskArchiveDates(profileID: String) throws -> [UUID: Date] {
        let rows = try db().rows("SELECT task_id, archived_at FROM personal_task_archive WHERE profile_id=?", bind: {
            try Self.bindText($0, profileID, at: 1)
        })
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let id = row.text(0).flatMap(UUID.init(uuidString:)),
                  let date = Self.date(row.integer(1)) else { return nil }
            return (id, date)
        })
    }

    func taskHistory(profile: PersonalTaskProfile) throws -> [PersonalTaskRow] {
        let archive = try taskArchiveDates(profileID: profile.id)
        return try db().rows("""
            SELECT t.payload_json, o.outcome_id, s.session_id, s.title, s.started_at, s.ended_at, s.start_provenance, s.outcome_end_fallback
            FROM meeting_tasks t JOIN meeting_outcomes o ON t.outcome_id=o.outcome_id
            JOIN meeting_sessions s ON o.session_id=s.session_id
            """).compactMap { row in
            guard case .blob(let data)? = row[0],
                  let outcomeID = row.text(1).flatMap(UUID.init(uuidString:)),
                  let sessionID = row.text(2).flatMap(UUID.init(uuidString:)) else { return nil }
            let task = try JSONDecoder.attention.decode(MeetingOutcomeTask.self, from: data)
            guard profile.owns(task) else { return nil }
            let start = row.text(6) == MeetingStartProvenance.recorded.rawValue ? Self.date(row.integer(4)) : nil
            let end = Self.date(row.integer(5)) ?? Self.date(row.integer(7))
            let meetingDate = MeetingEffectiveDate.resolve(start: start, end: end)?.date
            return PersonalTaskRow(outcomeID: outcomeID, sessionID: sessionID, title: row.text(3) ?? "",
                                   meetingDate: meetingDate, task: task, archivedAt: archive[task.id])
        }
    }

    @discardableResult
    func changeTask(outcomeID: UUID, taskID: UUID,
                    change: @Sendable (inout MeetingOutcomeTask) -> Void) throws -> MeetingOutcomeCommit? {
        let db = try db()
        guard let link = try db.one("""
            SELECT outcome_id,task_id FROM meeting_tasks WHERE outcome_id=?1 AND task_id=?2
            UNION ALL SELECT t.outcome_id,t.task_id FROM meeting_outcome_task_links l
            JOIN meeting_tasks t ON t.task_id=l.canonical_task_id
            WHERE l.outcome_id=?1 AND l.historical_task_id=?2 LIMIT 1
            """, bind: {
                try Self.bindText($0, outcomeID.uuidString, at: 1)
                try Self.bindText($0, taskID.uuidString, at: 2)
            }),
              let canonical = link.text(0).flatMap(UUID.init(uuidString:)),
              let canonicalTaskID = link.text(1).flatMap(UUID.init(uuidString:)),
              var outcome = try Self.storedOutcome(db: db, id: canonical),
              let metadata = try db.one("SELECT state,generation_owner,error_code FROM meeting_outcomes WHERE outcome_id=?", bind: {
                  try Self.bindText($0, canonical.uuidString, at: 1)
              }),
              let state = metadata.text(0).flatMap(MeetingOutcomePersistenceState.init(rawValue:)),
              let index = outcome.tasks.firstIndex(where: { $0.id == canonicalTaskID }) else { return nil }
        change(&outcome.tasks[index])
        return try commitOutcome(outcome, state: state, generationOwner: metadata.text(1), errorCode: metadata.text(2))
    }

    func setTaskArchived(taskID: UUID, profile: PersonalTaskProfile, archived: Bool) throws -> Date? {
        let db = try db()
        let currentProfile = try taskProfile()
        return try db.transaction {
            guard currentProfile.id == profile.id,
                  let row = try db.one("SELECT payload_json FROM meeting_tasks WHERE task_id=?", bind: {
                try Self.bindText($0, taskID.uuidString, at: 1)
            }), case .blob(let data)? = row[0],
                  currentProfile.owns(try JSONDecoder.attention.decode(MeetingOutcomeTask.self, from: data)) else {
                throw MeetingLibraryError.unavailable("task is no longer assigned to this profile")
            }
            if archived {
                let date = Date()
                try db.run("""
                    INSERT INTO personal_task_archive(profile_id,task_id,archived_at) VALUES(?,?,?)
                    ON CONFLICT(profile_id,task_id) DO UPDATE SET archived_at=excluded.archived_at
                    """) {
                    try Self.bindText($0, profile.id, at: 1)
                    try Self.bindText($0, taskID.uuidString, at: 2)
                    try Self.bindInt($0, date.ms, at: 3)
                }
                try Self.cancelTaskReminder(db: db, taskID: taskID)
                return date
            }
            try db.run("DELETE FROM personal_task_archive WHERE profile_id=? AND task_id=?") {
                try Self.bindText($0, profile.id, at: 1)
                try Self.bindText($0, taskID.uuidString, at: 2)
            }
            return nil
        }
    }

    private static func cancelTaskReminder(db: MeetingSQLiteConnection, taskID: UUID) throws {
        try db.run("INSERT OR IGNORE INTO task_reminder_cancellations(task_id) VALUES(?)") {
            try bindText($0, taskID.uuidString, at: 1)
        }
    }

    func taskReminderCancellations() throws -> [UUID] {
        try db().rows("SELECT task_id FROM task_reminder_cancellations").compactMap {
            $0.text(0).flatMap(UUID.init(uuidString:))
        }
    }

    func taskReminderAllowed(_ id: UUID, profile: PersonalTaskProfile) throws -> Bool {
        let currentProfile = try taskProfile()
        guard currentProfile.id == profile.id else { return false }
        let db = try db()
        guard let row = try db.one("""
            SELECT t.payload_json FROM meeting_tasks t WHERE t.task_id=?
            AND NOT EXISTS (SELECT 1 FROM personal_task_archive a WHERE a.task_id=t.task_id AND a.profile_id=?)
            AND NOT EXISTS (SELECT 1 FROM task_reminder_cancellations c WHERE c.task_id=t.task_id)
            """, bind: {
                try Self.bindText($0, id.uuidString, at: 1)
                try Self.bindText($0, profile.id, at: 2)
            }), case .blob(let data)? = row[0] else { return false }
        let task = try JSONDecoder.attention.decode(MeetingOutcomeTask.self, from: data)
        return !task.done && currentProfile.owns(task)
    }

    func recordTaskReminder(outcomeID: UUID, taskID: UUID, profile: PersonalTaskProfile,
                            at: Date) throws -> MeetingOutcomeCommit? {
        guard try taskReminderAllowed(taskID, profile: profile) else { return nil }
        return try changeTask(outcomeID: outcomeID, taskID: taskID) { $0.reminderAt = at }
    }

    func acknowledgeTaskReminderCancellation(_ id: UUID) throws {
        try db().run("DELETE FROM task_reminder_cancellations WHERE task_id=?") {
            try Self.bindText($0, id.uuidString, at: 1)
        }
    }
}

// MARK: - Cards

extension MeetingLibraryStore {
    /// One row per session that has notes or an outcome (or is still active). A failed
    /// join that produced neither is invisible history.
    func cards() async throws -> [MeetingLibraryCard] {
        let db = try db()
        let rows = try db.rows("""
        SELECT s.session_id, s.title, s.started_at, s.ended_at, s.state, s.updated_at,
               n.note_id, n.revision, substr(n.markdown, 1, 240),
               o.outcome_id, o.state, o.error_code,
               EXISTS(SELECT 1 FROM meeting_outcome_inputs i WHERE i.outcome_id=o.outcome_id),
               s.start_provenance, s.outcome_end_fallback
        FROM meeting_sessions s
        LEFT JOIN meeting_notes n ON n.session_id = s.session_id
        LEFT JOIN meeting_outcomes o ON o.session_id = s.session_id
        ORDER BY s.started_at DESC, s.session_id DESC
        """)
        return rows.compactMap { row in
            let hasNote = row.text(6) != nil
            let hasOutcome = row.text(9) != nil
            let state = MeetingSessionRecord.State(rawValue: row.text(4) ?? "") ?? .active
            guard hasNote || hasOutcome || state == .active || state == .reconnecting else { return nil }
            return MeetingLibraryCard(
                sessionID: UUID(uuidString: row.text(0) ?? "") ?? UUID(),
                title: row.text(1) ?? "",
                startedAt: Self.date(row.integer(2)) ?? .distantPast,
                endedAt: Self.date(row.integer(3)),
                state: state,
                hasNotes: hasNote,
                noteID: row.text(6).flatMap(UUID.init(uuidString:)),
                noteRevision: Int(row.integer(7) ?? 0),
                notePreview: row.text(8),
                outcomeID: row.text(9).flatMap(UUID.init(uuidString:)),
                outcomeState: MeetingOutcomePersistenceState(rawValue: row.text(10) ?? "") ?? .notStarted,
                outcomeErrorCode: row.text(11),
                hasOutcomeInput: row.bool(12),
                updatedAt: Self.date(row.integer(5)) ?? .distantPast,
                startProvenance: row.text(13).flatMap(MeetingStartProvenance.init(rawValue:)),
                outcomeEndFallback: Self.date(row.integer(14)))
        }
    }

    func outcomeState(_ outcomeID: UUID) async throws -> MeetingOutcomePersistenceState? {
        let db = try db()
        guard let row = try db.one("SELECT state FROM meeting_outcomes WHERE outcome_id=?", bind: {
            try Self.bindText($0, outcomeID.uuidString, at: 1)
        }) else { return nil }
        return row.text(0).flatMap(MeetingOutcomePersistenceState.init(rawValue:))
    }

    func outcomeBySession(_ sessionID: UUID) async throws -> MeetingOutcome? {
        let db = try db()
        guard let row = try db.one("SELECT outcome_id FROM meeting_outcomes WHERE session_id=?", bind: {
            try Self.bindText($0, sessionID.uuidString, at: 1)
        }), let id = row.text(0).flatMap(UUID.init(uuidString:)) else { return nil }
        return try Self.storedOutcome(db: db, id: id)
    }
}

// MARK: - Obsidian destination, bindings and outbox

extension MeetingLibraryStore {
    func saveDestination(_ destination: ObsidianDestinationRecord) async throws {
        let db = try db()
        var destination = destination
        destination.updatedAt = Date()
        try db.transaction {
            let previous = try Self.activeDestination(db)
            try db.run("""
            INSERT INTO export_destinations(destination_id,enabled,mode,config_json,config_revision,vault_bookmark,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(destination_id) DO UPDATE SET enabled=excluded.enabled,mode=excluded.mode,
            config_json=excluded.config_json,config_revision=excluded.config_revision,
            vault_bookmark=excluded.vault_bookmark,updated_at=excluded.updated_at
            """) {
                try Self.bindText($0, destination.id.uuidString, at: 1)
                try Self.bindInt($0, destination.enabled ? 1 : 0, at: 2)
                try Self.bindText($0, destination.mode.rawValue, at: 3)
                let config = try JSONEncoder.attention.encode(ExportConfiguration(meetingFolder: destination.meetingFolder,
                    saveAfterMeeting: destination.saveAfterMeeting, syncChanges: destination.syncChanges, layout: destination.layout))
                try Self.bindBlob($0, config, at: 4)
                try Self.bindInt($0, Int64(destination.configRevision), at: 5)
                try Self.bindBlob($0, destination.vaultBookmark, at: 6)
                try Self.bindInt($0, destination.createdAt.ms, at: 7)
                try Self.bindInt($0, destination.updatedAt.ms, at: 8)
            }
            if !destination.enabled || !destination.saveAfterMeeting {
                try db.run("UPDATE export_initial_state SET stage='held' WHERE destination_id=? AND stage='waiting'") {
                    try Self.bindText($0, destination.id.uuidString, at: 1)
                }
                try db.run("UPDATE export_deferred SET policy_held=1 WHERE destination_id=? AND intent IN ('initialEnd','initialFirstReady')") {
                    try Self.bindText($0, destination.id.uuidString, at: 1)
                }
                try db.run("UPDATE export_outbox SET policy_held=1 WHERE destination_id=? AND intent IN ('initialEnd','initialFirstReady')") {
                    try Self.bindText($0, destination.id.uuidString, at: 1)
                }
            }
            if !destination.enabled || !destination.syncChanges {
                try db.run("UPDATE export_deferred SET policy_held=1 WHERE destination_id=? AND intent='linkedUpdate'") {
                    try Self.bindText($0, destination.id.uuidString, at: 1)
                }
                try db.run("UPDATE export_outbox SET policy_held=1 WHERE destination_id=? AND intent='linkedUpdate'") {
                    try Self.bindText($0, destination.id.uuidString, at: 1)
                }
            }
            // Changing authorization refreshes configuration for pending retries without
            // reopening work that was held by a policy decision.
            try db.run("UPDATE export_outbox SET desired_config_revision=? WHERE destination_id=?") {
                try Self.bindInt($0, Int64(destination.configRevision), at: 1)
                try Self.bindText($0, destination.id.uuidString, at: 2)
            }
            if let previous, previous.id == destination.id, previous.layout != destination.layout {
                try db.run("""
                    UPDATE export_outbox SET paused=0,attempt_count=0,next_attempt_at=0,last_error_code=NULL
                    WHERE destination_id=? AND policy_held=0 AND last_error_code LIKE 'placementConflict(%'
                    """) { try Self.bindText($0, destination.id.uuidString, at: 1) }
            }
            let candidates = try db.rows("SELECT DISTINCT session_id FROM export_deferred WHERE destination_id=? AND policy_held=0") {
                try Self.bindText($0, destination.id.uuidString, at: 1)
            }
            for row in candidates {
                if let id = row.text(0).flatMap(UUID.init(uuidString:)) {
                    try Self.promoteDeferred(db: db, destination: destination, sessionID: id)
                }
            }
        }
    }

    private struct ExportConfiguration: Codable {
        let meetingFolder: String
        let saveAfterMeeting: Bool?
        let syncChanges: Bool?
        let layout: ObsidianExportLayout?
    }

    private static func activeDestination(_ db: MeetingSQLiteConnection) throws -> ObsidianDestinationRecord? {
        guard let row = try db.one("SELECT * FROM export_destinations ORDER BY updated_at DESC, rowid DESC LIMIT 1"),
              let id = UUID(uuidString: row.text(0) ?? "") else { return nil }
        var config: ExportConfiguration?
        if case .blob(let data)? = row[3] ?? nil {
            config = try? JSONDecoder.attention.decode(ExportConfiguration.self, from: data)
        }
        return ObsidianDestinationRecord(
            id: id, enabled: row.bool(1), saveAfterMeeting: config?.saveAfterMeeting ?? false,
            syncChanges: config?.syncChanges ?? false,
            mode: ObsidianExportMode(rawValue: row.text(2) ?? "") ?? .separateFiles,
            meetingFolder: config?.meetingFolder ?? "Meetings", layout: config?.layout ?? .init(),
            configRevision: Int(row.integer(4) ?? 0),
            vaultBookmark: { if case .blob(let data)? = row[5] ?? nil { return data }; return nil }(),
            createdAt: Self.date(row.integer(6)) ?? .distantPast,
            updatedAt: Self.date(row.integer(7)) ?? .distantPast)
    }

    func destination() async throws -> ObsidianDestinationRecord? { try Self.activeDestination(db()) }

    func saveInObsidian(_ id: UUID) throws {
        let db = try db()
        try db.transaction {
            guard let destination = try Self.activeDestination(db), destination.vaultBookmark != nil else {
                throw ObsidianExportError.vaultUnavailable(L("Select an Obsidian vault in Settings."))
            }
            guard let snapshot = try Self.exportSnapshot(db, sessionID: id) else { throw MeetingLibraryError.invalidSession }
            try Self.putExport(db: db, destination: destination, snapshot: snapshot, intent: .manualSave, held: false)
        }
    }

    func binding(destinationID: UUID, sessionID: UUID, component: ObsidianExportComponent) async throws -> ObsidianExportBindingRecord? {
        let db = try db()
        guard let row = try db.one("SELECT * FROM export_bindings WHERE destination_id=? AND session_id=? AND component=?", bind: {
            try Self.bindText($0, destinationID.uuidString, at: 1)
            try Self.bindText($0, sessionID.uuidString, at: 2)
            try Self.bindText($0, component.rawValue, at: 3)
        }) else { return nil }
        return Self.binding(from: row, destinationID: destinationID)
    }

    func saveBinding(_ binding: ObsidianExportBindingRecord) async throws {
        try Self.writeBinding(binding, db: db())
    }

    private struct BindingLayoutReceipt: Codable {
        let metadataSHA256: String?
        let metadataOwnershipEvaluated: Bool?
    }

    private static func writeBinding(_ binding: ObsidianExportBindingRecord, db: MeetingSQLiteConnection) throws {
        var binding = binding
        binding.updatedAt = Date()
        try db.run("""
        INSERT INTO export_bindings(destination_id,session_id,component,relative_path,marker_id,day_key,month_key,layout_map_json,
            last_exported_revision,last_block_sha256,last_file_sha256,last_file_identity,state,error_code,conflict_json,last_success_at,updated_at)
        VALUES(?,?,?,?,?,NULL,NULL,?,?,?,?,NULL,?,?,NULL,?,?)
        ON CONFLICT(destination_id,session_id,component) DO UPDATE SET relative_path=excluded.relative_path,
        marker_id=excluded.marker_id,layout_map_json=excluded.layout_map_json,last_exported_revision=excluded.last_exported_revision,
        last_block_sha256=excluded.last_block_sha256,last_file_sha256=excluded.last_file_sha256,
        state=excluded.state,error_code=excluded.error_code,last_success_at=COALESCE(excluded.last_success_at,last_success_at),updated_at=excluded.updated_at
        """) {
            try Self.bindText($0, binding.destinationID.uuidString, at: 1)
            try Self.bindText($0, binding.sessionID.uuidString, at: 2)
            try Self.bindText($0, binding.component.rawValue, at: 3)
            try Self.bindText($0, binding.relativePath, at: 4)
            try Self.bindText($0, binding.markerID, at: 5)
            let layout: Data?
            if binding.lastMetadataSHA256 != nil || binding.metadataOwnershipEvaluated != nil {
                layout = try JSONEncoder().encode(BindingLayoutReceipt(metadataSHA256: binding.lastMetadataSHA256,
                    metadataOwnershipEvaluated: binding.metadataOwnershipEvaluated))
            } else {
                layout = nil
            }
            try Self.bindBlob($0, layout, at: 6)
            try Self.bindInt($0, Int64(binding.lastExportedRevision), at: 7)
            try Self.bindText($0, binding.lastBlockSHA256, at: 8)
            try Self.bindText($0, binding.lastFileSHA256, at: 9)
            try Self.bindText($0, binding.state.rawValue, at: 10)
            try Self.bindText($0, binding.errorCode, at: 11)
            try Self.bindOptionalInt($0, binding.state == .exported ? Date().ms : nil, at: 12)
            try Self.bindInt($0, binding.updatedAt.ms, at: 13)
        }
    }

    /// Persists the exact intended write in the same transaction as the final authorization check.
    func prepareExportWrite(row: ObsidianOutboxRecord, binding: ObsidianExportBindingRecord) throws -> Bool {
        let db = try db()
        return try db.transaction {
            guard try isAuthorizedForWrite(row) else { return false }
            try db.run("""
                INSERT INTO export_prepared_writes(destination_id,session_id,component,receipt_json) VALUES(?,?,?,?)
                ON CONFLICT(destination_id,session_id,component) DO UPDATE SET receipt_json=excluded.receipt_json
                """) {
                try Self.bindExportKey($0, destination: binding.destinationID, session: binding.sessionID)
                try Self.bindText($0, binding.component.rawValue, at: 3)
                try Self.bindBlob($0, JSONEncoder.attention.encode(binding), at: 4)
            }
            return true
        }
    }

    struct ExportConflictApproval: Codable, Sendable {
        let revision: Int
        let blockHash: String
        let metadataHash: String?
    }

    func approvedObsidianConflict(row: ObsidianOutboxRecord, component: ObsidianExportComponent) throws -> ExportConflictApproval? {
        let match = try db().one("SELECT conflict_json FROM export_bindings WHERE destination_id=? AND session_id=? AND component=?") {
            try Self.bindExportKey($0, destination: row.destinationID, session: row.sessionID)
            try Self.bindText($0, component.rawValue, at: 3)
        }
        guard case .blob(let data)? = match?[0],
              let approval = try? JSONDecoder.attention.decode(ExportConflictApproval.self, from: data),
              approval.revision == row.desiredRevision else { return nil }
        return approval
    }

    func approveObsidianConflictReplacement(row: ObsidianOutboxRecord, component: ObsidianExportComponent,
                                            observedBlockHash: String, observedMetadataHash: String?) throws {
        let db = try db()
        try db.transaction {
            guard let destination = try Self.activeDestination(db), destination.id == row.destinationID,
                  destination.configRevision == row.desiredConfigRevision,
                  let current = try outboxRows(destinationID: row.destinationID).first(where: { $0.sessionID == row.sessionID }),
                  current.paused, current.desiredRevision == row.desiredRevision,
                  try db.one("SELECT 1 FROM export_bindings WHERE destination_id=? AND session_id=? AND component=? AND state='conflict' AND last_exported_revision>0", bind: {
                    try Self.bindExportKey($0, destination: row.destinationID, session: row.sessionID)
                    try Self.bindText($0, component.rawValue, at: 3)
                  }) != nil else { throw ObsidianExportError.destinationChanged }
            let approval = ExportConflictApproval(revision: row.desiredRevision,
                blockHash: observedBlockHash, metadataHash: observedMetadataHash)
            try db.run("UPDATE export_bindings SET conflict_json=? WHERE destination_id=? AND session_id=? AND component=?") {
                try Self.bindBlob($0, JSONEncoder.attention.encode(approval), at: 1)
                try Self.bindText($0, row.destinationID.uuidString, at: 2)
                try Self.bindText($0, row.sessionID.uuidString, at: 3)
                try Self.bindText($0, component.rawValue, at: 4)
            }
            try db.run("""
                UPDATE export_outbox SET intent='manualSave',paused=0,policy_held=0,attempt_count=0,next_attempt_at=0,last_error_code=NULL
                WHERE destination_id=? AND session_id=?
                """) { try Self.bindExportKey($0, destination: row.destinationID, session: row.sessionID) }
        }
    }

    func preparedExportWrite(destinationID: UUID, sessionID: UUID,
                             component: ObsidianExportComponent) throws -> ObsidianExportBindingRecord? {
        let row = try db().one("SELECT receipt_json FROM export_prepared_writes WHERE destination_id=? AND session_id=? AND component=?") {
            try Self.bindExportKey($0, destination: destinationID, session: sessionID)
            try Self.bindText($0, component.rawValue, at: 3)
        }
        guard case .blob(let data)? = row?[0] else { return nil }
        return try JSONDecoder.attention.decode(ObsidianExportBindingRecord.self, from: data)
    }

    func commitExportWrite(_ binding: ObsidianExportBindingRecord) throws {
        let db = try db()
        try db.transaction {
            guard let prepared = try preparedExportWrite(destinationID: binding.destinationID,
                sessionID: binding.sessionID, component: binding.component),
                prepared.lastExportedRevision == binding.lastExportedRevision,
                prepared.lastBlockSHA256 == binding.lastBlockSHA256 else { return }
            try Self.writeBinding(binding, db: db)
            try db.run("UPDATE export_bindings SET conflict_json=NULL WHERE destination_id=? AND session_id=? AND component=?") {
                try Self.bindExportKey($0, destination: binding.destinationID, session: binding.sessionID)
                try Self.bindText($0, binding.component.rawValue, at: 3)
            }
            try db.run("DELETE FROM export_prepared_writes WHERE destination_id=? AND session_id=? AND component=?") {
                try Self.bindExportKey($0, destination: binding.destinationID, session: binding.sessionID)
                try Self.bindText($0, binding.component.rawValue, at: 3)
            }
        }
    }

    func dueOutbox(now: Date = Date()) async throws -> [ObsidianOutboxRecord] {
        let db = try db()
        let rows = try db.rows("""
        SELECT o.*, d.enabled FROM export_outbox o
        JOIN export_destinations d ON d.destination_id = o.destination_id
        WHERE o.paused=0 AND o.policy_held=0 AND (d.enabled=1 OR o.intent='manualSave') AND o.next_attempt_at <= ?
        ORDER BY o.next_attempt_at
        """) { try Self.bindInt($0, now.ms, at: 1) }
        return rows.compactMap(Self.outboxRecord(from:))
    }

    func isAuthorizedForWrite(_ row: ObsidianOutboxRecord) throws -> Bool {
        let db = try db()
        guard let destination = try Self.activeDestination(db), destination.id == row.destinationID,
              destination.configRevision == row.desiredConfigRevision, row.intent.permitted(by: destination) else { return false }
        return try db.one("""
            SELECT 1 FROM export_outbox WHERE destination_id=? AND session_id=? AND desired_revision=?
              AND desired_config_revision=? AND intent=? AND paused=0 AND policy_held=0
            """) {
            try Self.bindExportKey($0, destination: row.destinationID, session: row.sessionID)
            try Self.bindInt($0, Int64(row.desiredRevision), at: 3)
            try Self.bindInt($0, Int64(row.desiredConfigRevision), at: 4)
            try Self.bindText($0, row.intent.rawValue, at: 5)
        } != nil
    }

    func outboxRows(destinationID: UUID) throws -> [ObsidianOutboxRecord] {
        try db().rows("SELECT * FROM export_outbox WHERE destination_id=?") {
            try Self.bindText($0, destinationID.uuidString, at: 1)
        }.compactMap(Self.outboxRecord(from:))
    }

    func latestObsidianDelivery(destinationID: UUID) throws -> (revision: Int, date: Date)? {
        guard let row = try db().one("""
            SELECT revision, completed_at FROM (
                SELECT revision,completed_at FROM export_completed_deliveries WHERE destination_id=?1
                UNION ALL
                SELECT b.last_exported_revision,b.last_success_at FROM export_bindings b
                JOIN export_destinations d ON d.destination_id=b.destination_id
                WHERE b.destination_id=?1 AND d.mode='separateFiles' AND b.component='meeting'
                AND b.last_success_at IS NOT NULL
                AND NOT EXISTS (SELECT 1 FROM export_completed_deliveries c
                    WHERE c.destination_id=b.destination_id AND c.session_id=b.session_id)
            ) ORDER BY completed_at DESC LIMIT 1
            """, bind: { try Self.bindText($0, destinationID.uuidString, at: 1) }),
            let date = Self.date(row.integer(1)) else { return nil }
        return (Int(row.integer(0) ?? 0), date)
    }

    func partialObsidianDeliveryCount(destinationID: UUID) throws -> Int {
        let row = try db().one("""
            SELECT COUNT(*) FROM export_outbox o WHERE o.destination_id=?
            AND EXISTS (SELECT 1 FROM export_bindings b WHERE b.destination_id=o.destination_id
                AND b.session_id=o.session_id AND b.last_exported_revision>=o.desired_revision)
            AND NOT EXISTS (SELECT 1 FROM export_completed_deliveries c WHERE c.destination_id=o.destination_id
                AND c.session_id=o.session_id AND c.revision>=o.desired_revision)
            """, bind: { try Self.bindText($0, destinationID.uuidString, at: 1) })
        return Int(row?.integer(0) ?? 0)
    }

    func heldDeferredObsidianCount(destinationID: UUID) throws -> Int {
        let row = try db().one("SELECT COUNT(*) FROM export_deferred WHERE destination_id=? AND policy_held=1") {
            try Self.bindText($0, destinationID.uuidString, at: 1)
        }
        return Int(row?.integer(0) ?? 0)
    }

    func heldObsidianMeetings(destinationID: UUID) throws -> [(id: UUID, title: String, date: MeetingEffectiveDate?, snapshots: [ObsidianExportSnapshot])] {
        try db().rows("""
            SELECT s.session_id,s.title FROM meeting_sessions s
            WHERE EXISTS (SELECT 1 FROM export_outbox o WHERE o.destination_id=?1 AND o.session_id=s.session_id AND o.policy_held=1)
               OR EXISTS (SELECT 1 FROM export_deferred d WHERE d.destination_id=?1 AND d.session_id=s.session_id AND d.policy_held=1)
            ORDER BY s.started_at DESC,s.session_id
            """, bind: { try Self.bindText($0, destinationID.uuidString, at: 1) }).compactMap { row in
                guard let id = row.text(0).flatMap(UUID.init(uuidString:)) else { return nil }
                let snapshots = try heldObsidianSnapshots(destinationID: destinationID, sessionID: id)
                return (id: id, title: row.text(1) ?? "", date: snapshots.first?.session.effectiveDate, snapshots: snapshots)
            }
    }

    private func heldObsidianSnapshots(destinationID: UUID, sessionID: UUID) throws -> [ObsidianExportSnapshot] {
        let db = try db()
        var snapshots: [ObsidianExportSnapshot] = []
        let headRow = try db.one("SELECT * FROM export_outbox WHERE destination_id=? AND session_id=? AND policy_held=1", bind: {
            try Self.bindExportKey($0, destination: destinationID, session: sessionID)
        })
        if let head = headRow.flatMap(Self.outboxRecord(from:)),
           let snapshot = try head.snapshot ?? Self.exportSnapshot(db, sessionID: sessionID) {
            snapshots.append(snapshot)
        }
        let rows = try db.rows("SELECT snapshot_json FROM export_deferred WHERE destination_id=? AND session_id=? AND policy_held=1 ORDER BY revision") {
            try Self.bindText($0, destinationID.uuidString, at: 1)
            try Self.bindText($0, sessionID.uuidString, at: 2)
        }
        for row in rows {
            guard case .blob(let data)? = row[0] else { continue }
            snapshots.append(try JSONDecoder.attention.decode(ObsidianExportSnapshot.self, from: data))
        }
        return snapshots
    }

    func sendHeldObsidianRows(sessionIDs: Set<UUID>? = nil, expectedDestination: UUID? = nil,
                              expectedConfigRevision: Int? = nil,
                              expectedSnapshots: [UUID: [ObsidianExportSnapshot]]? = nil) throws {
        let db = try db()
        try db.transaction {
            guard let destination = try Self.activeDestination(db), destination.vaultBookmark != nil else {
                throw ObsidianExportError.vaultUnavailable(L("Select an Obsidian vault in Settings."))
            }
            guard (expectedDestination == nil || destination.id == expectedDestination),
                  (expectedConfigRevision == nil || destination.configRevision == expectedConfigRevision) else {
                throw ObsidianExportError.destinationChanged
            }
            if let expectedSnapshots {
                guard let sessionIDs, Set(expectedSnapshots.keys) == sessionIDs else {
                    throw ObsidianExportError.staleRevision
                }
                for (sessionID, snapshots) in expectedSnapshots {
                    guard try heldObsidianSnapshots(destinationID: destination.id, sessionID: sessionID) == snapshots else {
                        throw ObsidianExportError.staleRevision
                    }
                }
            }
            let held = try outboxRows(destinationID: destination.id).filter { $0.policyHeld && (sessionIDs == nil || sessionIDs!.contains($0.sessionID)) }
            for row in held {
                guard let snapshot = try row.snapshot ?? Self.exportSnapshot(db, sessionID: row.sessionID) else { continue }
                try Self.putExport(db: db, destination: destination, snapshot: snapshot, intent: .manualSave, held: false)
            }
            let deferred = try db.rows("SELECT snapshot_json,session_id FROM export_deferred WHERE destination_id=? AND policy_held=1 ORDER BY revision") {
                try Self.bindText($0, destination.id.uuidString, at: 1)
            }
            let selectedDeferred = deferred.filter { row in
                guard let session = row.text(1).flatMap(UUID.init(uuidString:)) else { return false }
                return sessionIDs == nil || sessionIDs!.contains(session)
            }
            for session in Set(selectedDeferred.compactMap { $0.text(1).flatMap(UUID.init(uuidString:)) }) {
                try db.run("DELETE FROM export_deferred WHERE destination_id=? AND session_id=? AND policy_held=1") {
                    try Self.bindText($0, destination.id.uuidString, at: 1)
                    try Self.bindText($0, session.uuidString, at: 2)
                }
            }
            for row in selectedDeferred {
                guard case .blob(let data)? = row[0] else { continue }
                let snapshot = try JSONDecoder.attention.decode(ObsidianExportSnapshot.self, from: data)
                try Self.putExport(db: db, destination: destination, snapshot: snapshot, intent: .manualSave, held: false)
            }
        }
    }

    func completeOutbox(destinationID: UUID, sessionID: UUID, throughRevision: Int? = nil,
                        configRevision: Int? = nil) async throws {
        let db = try db()
        try db.transaction {
            if let throughRevision {
                let modeRow = try db.one("SELECT mode FROM export_destinations WHERE destination_id=?", bind: {
                    try Self.bindText($0, destinationID.uuidString, at: 1)
                })
                guard let mode = modeRow?.text(0).flatMap(ObsidianExportMode.init(rawValue:)) else { return }
                let delivered = try db.rows("""
                    SELECT component FROM export_bindings
                    WHERE destination_id=? AND session_id=? AND last_exported_revision>=?
                    """) {
                    try Self.bindExportKey($0, destination: destinationID, session: sessionID)
                    try Self.bindInt($0, Int64(throughRevision), at: 3)
                }
                let components = Set(delivered.compactMap { $0.text(0) })
                guard mode.requiredComponents.allSatisfy({ components.contains($0.rawValue) }) else { return }
                try db.run("""
                    INSERT INTO export_completed_deliveries(destination_id,session_id,revision,completed_at)
                    VALUES(?,?,?,?) ON CONFLICT(destination_id,session_id)
                    DO UPDATE SET revision=excluded.revision,completed_at=excluded.completed_at
                    WHERE excluded.revision>export_completed_deliveries.revision
                    """) {
                    try Self.bindExportKey($0, destination: destinationID, session: sessionID)
                    try Self.bindInt($0, Int64(throughRevision), at: 3)
                    try Self.bindInt($0, Date().ms, at: 4)
                }
            }
            try db.run("DELETE FROM export_outbox WHERE destination_id=? AND session_id=? AND (? IS NULL OR desired_revision<=?) AND (? IS NULL OR desired_config_revision=?)") {
                try Self.bindText($0, destinationID.uuidString, at: 1)
                try Self.bindText($0, sessionID.uuidString, at: 2)
                try Self.bindOptionalInt($0, throughRevision.map(Int64.init), at: 3)
                try Self.bindOptionalInt($0, throughRevision.map(Int64.init), at: 4)
                try Self.bindOptionalInt($0, configRevision.map(Int64.init), at: 5)
                try Self.bindOptionalInt($0, configRevision.map(Int64.init), at: 6)
            }
            if let destination = try Self.activeDestination(db), destination.id == destinationID {
                try Self.promoteDeferred(db: db, destination: destination, sessionID: sessionID, through: throughRevision)
            }
        }
    }

    /// Records a failed attempt. Transient errors schedule an exponential backoff capped
    /// at 60 seconds; non-transient errors pause the row until the user acts.
    func failOutbox(destinationID: UUID, sessionID: UUID, errorCode: String, transient: Bool,
                    now: Date = Date(), expectedRevision: Int? = nil, configRevision: Int? = nil) async throws {
        let db = try db()
        let row = try db.one("SELECT attempt_count FROM export_outbox WHERE destination_id=? AND session_id=?") {
            try Self.bindText($0, destinationID.uuidString, at: 1)
            try Self.bindText($0, sessionID.uuidString, at: 2)
        }
        let attempts = Int(row?.integer(0) ?? 0) + 1
        let delay = transient ? min(60.0, pow(2.0, Double(min(attempts, 6)))) : TimeInterval.greatestFiniteMagnitude
        // Clamp far-future retries to a finite, safely-representable millisecond value;
        // +inf or a rounded-to-2^63 double would trap on Int64 conversion.
        let nextAttemptMs = min((now.timeIntervalSince1970 + delay) * 1000.0, 9.0e18)
        try db.run("""
        UPDATE export_outbox SET attempt_count=?, next_attempt_at=?, paused=?, last_error_code=?, updated_at=?
        WHERE destination_id=? AND session_id=? AND (? IS NULL OR desired_revision=?)
          AND (? IS NULL OR desired_config_revision=?)
        """) {
            try Self.bindInt($0, Int64(attempts), at: 1)
            try Self.bindInt($0, Int64(nextAttemptMs), at: 2)
            try Self.bindInt($0, transient ? 0 : 1, at: 3)
            try Self.bindText($0, errorCode, at: 4)
            try Self.bindInt($0, now.ms, at: 5)
            try Self.bindText($0, destinationID.uuidString, at: 6)
            try Self.bindText($0, sessionID.uuidString, at: 7)
            try Self.bindOptionalInt($0, expectedRevision.map(Int64.init), at: 8)
            try Self.bindOptionalInt($0, expectedRevision.map(Int64.init), at: 9)
            try Self.bindOptionalInt($0, configRevision.map(Int64.init), at: 10)
            try Self.bindOptionalInt($0, configRevision.map(Int64.init), at: 11)
        }
    }

    func outboxCount() async throws -> Int {
        let db = try db()
        return Int(try db.one("SELECT COUNT(*) FROM export_outbox")?.integer(0) ?? 0)
    }

    private static func binding(from row: MeetingSQLiteRow, destinationID: UUID) -> ObsidianExportBindingRecord? {
        guard let sessionID = UUID(uuidString: row.text(1) ?? "") else { return nil }
        let layout: BindingLayoutReceipt?
        if case .blob(let bytes)? = row[7] { layout = try? JSONDecoder().decode(BindingLayoutReceipt.self, from: bytes) }
        else { layout = nil }
        return ObsidianExportBindingRecord(
            destinationID: destinationID, sessionID: sessionID,
            component: ObsidianExportComponent(rawValue: row.text(2) ?? "") ?? .meeting,
            relativePath: row.text(3) ?? "", markerID: row.text(4),
            lastExportedRevision: Int(row.integer(8) ?? 0),
            lastBlockSHA256: row.text(9), lastFileSHA256: row.text(10),
            state: ObsidianBindingState(rawValue: row.text(12) ?? "") ?? .idle,
            errorCode: row.text(13),
            updatedAt: Self.date(row.integer(16)) ?? .distantPast,
            lastMetadataSHA256: layout?.metadataSHA256, metadataOwnershipEvaluated: layout?.metadataOwnershipEvaluated)
    }

    private static func outboxRecord(from row: MeetingSQLiteRow) -> ObsidianOutboxRecord? {
        guard let destinationID = UUID(uuidString: row.text(0) ?? ""),
              let sessionID = UUID(uuidString: row.text(1) ?? "") else { return nil }
        return ObsidianOutboxRecord(
            destinationID: destinationID, sessionID: sessionID,
            desiredRevision: Int(row.integer(2) ?? 0),
            desiredConfigRevision: Int(row.integer(3) ?? 0),
            attemptCount: Int(row.integer(4) ?? 0),
            nextAttemptAt: Self.date(row.integer(5)) ?? .distantPast,
            paused: (row.integer(6) ?? 0) == 1,
            lastErrorCode: row.text(7),
            updatedAt: Self.date(row.integer(8)) ?? .distantPast,
            intent: row.text(9).flatMap(ObsidianExportIntent.init(rawValue:)) ?? .legacy,
            snapshot: { if case .blob(let data)? = row[10] {
                return try? JSONDecoder.attention.decode(ObsidianExportSnapshot.self, from: data)
            }; return nil }(),
            policyHeld: row.bool(11))
    }
}

private extension TimeInterval {
    var ms: Int64 { Int64((self * 1000).rounded()) }
}

extension MeetingLibraryStore {
    /// A pending/draft generation orphaned by a process exit becomes failed; a live
    /// task owns its generation only after launch, and prepare() runs before any.
    func failInterruptedGenerations() async throws -> Int {
        let db = try db()
        let before = try db.one("SELECT COUNT(*) FROM meeting_outcomes WHERE state IN ('pending','draft')")
        try db.run("UPDATE meeting_outcomes SET state='failed', error_code='interrupted', generation_owner=NULL, updated_at=? WHERE state IN ('pending','draft')") {
            try Self.bindInt($0, Date().ms, at: 1)
        }
        return Int(before?.integer(0) ?? 0)
    }
}

extension MeetingLibraryStore {
    /// The library root: <root>/MeetingLibrary. Used for export backups beside the database.
    nonisolated var storeRoot: URL { root }

    /// User-initiated retry: every paused or delayed row becomes due immediately.
    func retryAllOutbox() async throws {
        let db = try db()
        try db.run("UPDATE export_outbox SET attempt_count=0,next_attempt_at=0,last_error_code=NULL,updated_at=? WHERE paused=0 AND policy_held=0") {
            try Self.bindInt($0, Date().ms, at: 1)
        }
    }
}
