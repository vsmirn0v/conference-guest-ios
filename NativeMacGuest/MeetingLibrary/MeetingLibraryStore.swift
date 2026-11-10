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

/// One connection is confined to `MeetingLibraryStore`. The application does not
/// share a SQLite handle across actors and never claims success before `COMMIT`.
private final class MeetingSQLiteConnection: @unchecked Sendable {
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

private extension MeetingSQLiteRow {
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
            try opened.transaction {
                for statement in MeetingLibrarySchema.ddl { try opened.execute(statement) }
                try opened.execute("CREATE TABLE IF NOT EXISTS meeting_library_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                let version = try opened.one("SELECT version FROM schema_migrations WHERE version = ?") {
                    try MeetingSQLiteConnection.bindInt($0, Int64(MeetingLibrarySchema.currentVersion), at: 1)
                }
                if version == nil {
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
        INSERT INTO meeting_sessions(session_id,title,title_folded,invitation,room_identity,calendar_series_id,continuation_id,started_at,ended_at,time_zone_id,state,export_revision,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(session_id) DO UPDATE SET
        title=excluded.title,title_folded=excluded.title_folded,invitation=excluded.invitation,
        room_identity=excluded.room_identity,calendar_series_id=excluded.calendar_series_id,
        continuation_id=excluded.continuation_id,started_at=excluded.started_at,ended_at=excluded.ended_at,
        time_zone_id=excluded.time_zone_id,state=excluded.state,export_revision=excluded.export_revision,
        updated_at=excluded.updated_at
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
        return session
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
            INSERT INTO meeting_sessions(session_id,title,title_folded,invitation,room_identity,calendar_series_id,continuation_id,started_at,ended_at,time_zone_id,state,export_revision,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
                    INSERT INTO meeting_sessions(session_id,title,title_folded,invitation,room_identity,calendar_series_id,continuation_id,started_at,ended_at,time_zone_id,state,export_revision,created_at,updated_at)
                    VALUES(?,?,?,?,?,?,NULL,?,?,?,?,0,?,?)
                    """) {
                        try Self.bindText($0, sessionID.uuidString, at: 1)
                        try Self.bindText($0, outcome.meetingTitle, at: 2)
                        try Self.bindText($0, MeetingTextNormalization.folded(outcome.meetingTitle), at: 3)
                        try Self.bindText($0, outcome.invitation?.absoluteString, at: 4)
                        try Self.bindText($0, outcome.invitation.flatMap { MeetingRoomIdentity($0)?.displayDetails }, at: 5)
                        try Self.bindText($0, outcome.seriesID, at: 6)
                        try Self.bindInt($0, outcome.endedAt.ms, at: 7)
                        try Self.bindInt($0, outcome.endedAt.ms, at: 8)
                        try Self.bindText($0, TimeZone.current.identifier, at: 9)
                        try Self.bindText($0, MeetingSessionRecord.State.ended.rawValue, at: 10)
                        try Self.bindInt($0, now.ms, at: 11)
                        try Self.bindInt($0, now.ms, at: 12)
                    }
                }
                let payload = try JSONEncoder.attention.encode(outcome)
                try db.run("""
                INSERT INTO meeting_outcomes(outcome_id,session_id,state,payload_json,revision,generation_owner,error_code,created_at,updated_at)
                VALUES(?,?,?,?,1,NULL,NULL,?,?)
                ON CONFLICT(outcome_id) DO NOTHING
                """) {
                    try Self.bindText($0, outcome.id.uuidString, at: 1)
                    try Self.bindText($0, sessionID.uuidString, at: 2)
                    try Self.bindText($0, MeetingOutcomePersistenceState.ready.rawValue, at: 3)
                    try Self.bindBlob($0, payload, at: 4)
                    try Self.bindInt($0, outcome.endedAt.ms, at: 5)
                    try Self.bindInt($0, outcome.endedAt.ms, at: 6)
                }
            }
        }
        try await markLegacyOutcomesMigrated()
    }

    func markLegacyOutcomesMigrated() async throws {
        let db = try db()
        try db.run("INSERT INTO meeting_library_meta(key,value) VALUES('legacy_outcomes_migrated','1') ON CONFLICT(key) DO UPDATE SET value='1'") { _ in }
    }

    func outcomes() async throws -> [MeetingOutcome] {
        let db = try db()
        return try db.rows("SELECT payload_json FROM meeting_outcomes ORDER BY updated_at DESC").compactMap { row in
            guard case .blob(let data)? = row[0] ?? nil else { return nil }
            return try? JSONDecoder.attention.decode(MeetingOutcome.self, from: data)
        }
    }

    func outcome(_ outcomeID: UUID) async throws -> MeetingOutcome? {
        let db = try db()
        guard let row = try db.one("SELECT payload_json FROM meeting_outcomes WHERE outcome_id=?", bind: { try Self.bindText($0, outcomeID.uuidString, at: 1) }),
              case .blob(let data)? = row[0] ?? nil else { return nil }
        return try JSONDecoder.attention.decode(MeetingOutcome.self, from: data)
    }

    @discardableResult
    func saveOutcome(_ outcome: MeetingOutcome, state: MeetingOutcomePersistenceState,
                     generationOwner: String? = nil, errorCode: String? = nil) async throws -> MeetingOutcomeCommit {
        let db = try db()
        let sessionID = outcome.meetingID ?? Self.legacySessionID(for: outcome.id)
        var outcome = outcome
        outcome.meetingID = sessionID
        return try db.transaction {
            if try db.one("SELECT session_id FROM meeting_sessions WHERE session_id=?", bind: { try Self.bindText($0, sessionID.uuidString, at: 1) }) == nil {
                let now = Date()
                try db.run("""
                INSERT INTO meeting_sessions(session_id,title,title_folded,invitation,room_identity,calendar_series_id,continuation_id,started_at,ended_at,time_zone_id,state,export_revision,created_at,updated_at)
                VALUES(?,?,?,?,?,?,NULL,?,?,?,?,1,?,?)
                """) {
                    try Self.bindText($0, sessionID.uuidString, at: 1)
                    try Self.bindText($0, outcome.meetingTitle, at: 2)
                    try Self.bindText($0, MeetingTextNormalization.folded(outcome.meetingTitle), at: 3)
                    try Self.bindText($0, outcome.invitation?.absoluteString, at: 4)
                    try Self.bindText($0, outcome.invitation.flatMap { MeetingRoomIdentity($0)?.displayDetails }, at: 5)
                    try Self.bindText($0, outcome.seriesID, at: 6)
                    try Self.bindInt($0, outcome.endedAt.ms, at: 7)
                    try Self.bindOptionalInt($0, nil, at: 8)
                    try Self.bindText($0, TimeZone.current.identifier, at: 9)
                    try Self.bindText($0, MeetingSessionRecord.State.ended.rawValue, at: 10)
                    try Self.bindInt($0, now.ms, at: 11)
                    try Self.bindInt($0, now.ms, at: 12)
                }
            }
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
            let updatedSession = try db.one("SELECT export_revision FROM meeting_sessions WHERE session_id=?", bind: { try Self.bindText($0, sessionID.uuidString, at: 1) })
            let exportRevision = Int((updatedSession?.integer(0) ?? 0) + 1)
            try db.run("UPDATE meeting_sessions SET export_revision=?,updated_at=? WHERE session_id=?") {
                try Self.bindInt($0, Int64(exportRevision), at: 1)
                try Self.bindInt($0, now.ms, at: 2)
                try Self.bindText($0, sessionID.uuidString, at: 3)
            }
            let queued = try Self.queueOutbox(db: db, sessionID: sessionID, desiredRevision: exportRevision)
            _ = queued
            return MeetingOutcomeCommit(outcomeID: outcome.id, sessionID: sessionID, state: state, outcome: outcome,
                                        revision: revision, exportRevision: exportRevision, updatedAt: now)
        }
    }

    func removeOutcome(_ outcomeID: UUID) async throws {
        let db = try db()
        try db.run("DELETE FROM meeting_outcomes WHERE outcome_id=?") { try Self.bindText($0, outcomeID.uuidString, at: 1) }
    }

    // MARK: Data clearing

    func deleteAll() async throws {
        let db = try db()
        try db.transaction {
            for table in ["export_outbox", "export_bindings", "export_destinations", "note_chunks", "meeting_notes", "meeting_outcomes", "meeting_sessions"] {
                try db.execute("DELETE FROM \(table)")
            }
        }
    }

    // MARK: Binding helpers

    private static func queueOutbox(db: MeetingSQLiteConnection, sessionID: UUID, desiredRevision: Int) throws -> Int {
        try db.run("""
        INSERT INTO export_outbox(destination_id,session_id,desired_revision,desired_config_revision,attempt_count,next_attempt_at,paused,last_error_code,updated_at)
        SELECT destination_id,?, ?, config_revision, 0, 0, 0, NULL, ?
        FROM export_destinations WHERE enabled=1
        ON CONFLICT(destination_id,session_id) DO UPDATE SET
        desired_revision=excluded.desired_revision,desired_config_revision=excluded.desired_config_revision,
        attempt_count=0,next_attempt_at=0,last_error_code=NULL,updated_at=excluded.updated_at
        """) {
            try Self.bindText($0, sessionID.uuidString, at: 1)
            try Self.bindInt($0, Int64(desiredRevision), at: 2)
            try Self.bindInt($0, Date().ms, at: 3)
        }
        let row = try db.one("SELECT COUNT(*) FROM export_destinations WHERE enabled=1")
        return Int(row?.integer(0) ?? 0)
    }

    private static func legacySessionID(for outcomeID: UUID) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("meeting-session-legacy-outcome-\(outcomeID.uuidString)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
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
            updatedAt: Self.date(row.integer(13)) ?? .distantPast
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

// MARK: - Cards

extension MeetingLibraryStore {
    /// One row per session that has notes or an outcome (or is still active). A failed
    /// join that produced neither is invisible history.
    func cards() async throws -> [MeetingLibraryCard] {
        let db = try db()
        let rows = try db.rows("""
        SELECT s.session_id, s.title, s.started_at, s.ended_at, s.state, s.updated_at,
               n.note_id, n.revision, substr(n.markdown, 1, 240),
               o.outcome_id, o.state
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
                updatedAt: Self.date(row.integer(5)) ?? .distantPast)
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
        guard let row = try db.one("SELECT payload_json FROM meeting_outcomes WHERE session_id=?", bind: {
            try Self.bindText($0, sessionID.uuidString, at: 1)
        }), case .blob(let data)? = row[0] ?? nil else { return nil }
        return try JSONDecoder.attention.decode(MeetingOutcome.self, from: data)
    }
}

// MARK: - Obsidian destination, bindings and outbox

extension MeetingLibraryStore {
    func saveDestination(_ destination: ObsidianDestinationRecord) async throws {
        let db = try db()
        var destination = destination
        destination.updatedAt = Date()
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
            let config = try JSONEncoder.attention.encode(["meetingFolder": destination.meetingFolder])
            try Self.bindBlob($0, config, at: 4)
            try Self.bindInt($0, Int64(destination.configRevision), at: 5)
            try Self.bindBlob($0, destination.vaultBookmark, at: 6)
            try Self.bindInt($0, destination.createdAt.ms, at: 7)
            try Self.bindInt($0, destination.updatedAt.ms, at: 8)
        }
    }

    /// The active destination: the most recently updated row. Mode A ships with one.
    func destination() async throws -> ObsidianDestinationRecord? {
        let db = try db()
        guard let row = try db.one("SELECT * FROM export_destinations ORDER BY updated_at DESC LIMIT 1") else { return nil }
        guard let id = UUID(uuidString: row.text(0) ?? "") else { return nil }
        var folder = "Meetings"
        if case .blob(let data)? = row[3] ?? nil, let config = try? JSONDecoder.attention.decode([String: String].self, from: data) {
            folder = config["meetingFolder"] ?? folder
        }
        return ObsidianDestinationRecord(
            id: id, enabled: row.bool(1),
            mode: ObsidianExportMode(rawValue: row.text(2) ?? "") ?? .separateFiles,
            meetingFolder: folder,
            configRevision: Int(row.integer(4) ?? 0),
            vaultBookmark: { if case .blob(let data)? = row[5] ?? nil { return data }; return nil }(),
            createdAt: Self.date(row.integer(6)) ?? .distantPast,
            updatedAt: Self.date(row.integer(7)) ?? .distantPast)
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
        let db = try db()
        var binding = binding
        binding.updatedAt = Date()
        try db.run("""
        INSERT INTO export_bindings(destination_id,session_id,component,relative_path,marker_id,day_key,month_key,layout_map_json,
            last_exported_revision,last_block_sha256,last_file_sha256,last_file_identity,state,error_code,conflict_json,last_success_at,updated_at)
        VALUES(?,?,?,?,?,NULL,NULL,NULL,?,?,?,NULL,?,?,NULL,?,?)
        ON CONFLICT(destination_id,session_id,component) DO UPDATE SET relative_path=excluded.relative_path,
        marker_id=excluded.marker_id,last_exported_revision=excluded.last_exported_revision,
        last_block_sha256=excluded.last_block_sha256,last_file_sha256=excluded.last_file_sha256,
        state=excluded.state,error_code=excluded.error_code,last_success_at=excluded.last_success_at,updated_at=excluded.updated_at
        """) {
            try Self.bindText($0, binding.destinationID.uuidString, at: 1)
            try Self.bindText($0, binding.sessionID.uuidString, at: 2)
            try Self.bindText($0, binding.component.rawValue, at: 3)
            try Self.bindText($0, binding.relativePath, at: 4)
            try Self.bindText($0, binding.markerID, at: 5)
            try Self.bindInt($0, Int64(binding.lastExportedRevision), at: 6)
            try Self.bindText($0, binding.lastBlockSHA256, at: 7)
            try Self.bindText($0, binding.lastFileSHA256, at: 8)
            try Self.bindText($0, binding.state.rawValue, at: 9)
            try Self.bindText($0, binding.errorCode, at: 10)
            try Self.bindInt($0, Date().ms, at: 11)
            try Self.bindInt($0, binding.updatedAt.ms, at: 12)
        }
    }

    func dueOutbox(now: Date = Date()) async throws -> [ObsidianOutboxRecord] {
        let db = try db()
        let rows = try db.rows("""
        SELECT o.*, d.enabled FROM export_outbox o
        JOIN export_destinations d ON d.destination_id = o.destination_id
        WHERE o.paused = 0 AND d.enabled = 1 AND o.next_attempt_at <= ?
        ORDER BY o.next_attempt_at
        """) { try Self.bindInt($0, now.ms, at: 1) }
        return rows.compactMap(Self.outboxRecord(from:))
    }

    func completeOutbox(destinationID: UUID, sessionID: UUID) async throws {
        let db = try db()
        try db.run("DELETE FROM export_outbox WHERE destination_id=? AND session_id=?") {
            try Self.bindText($0, destinationID.uuidString, at: 1)
            try Self.bindText($0, sessionID.uuidString, at: 2)
        }
    }

    /// Records a failed attempt. Transient errors schedule an exponential backoff capped
    /// at 60 seconds; non-transient errors pause the row until the user acts.
    func failOutbox(destinationID: UUID, sessionID: UUID, errorCode: String, transient: Bool, now: Date = Date()) async throws {
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
        WHERE destination_id=? AND session_id=?
        """) {
            try Self.bindInt($0, Int64(attempts), at: 1)
            try Self.bindInt($0, Int64(nextAttemptMs), at: 2)
            try Self.bindInt($0, transient ? 0 : 1, at: 3)
            try Self.bindText($0, errorCode, at: 4)
            try Self.bindInt($0, now.ms, at: 5)
            try Self.bindText($0, destinationID.uuidString, at: 6)
            try Self.bindText($0, sessionID.uuidString, at: 7)
        }
    }

    func outboxCount() async throws -> Int {
        let db = try db()
        return Int(try db.one("SELECT COUNT(*) FROM export_outbox")?.integer(0) ?? 0)
    }

    private static func binding(from row: MeetingSQLiteRow, destinationID: UUID) -> ObsidianExportBindingRecord? {
        guard let sessionID = UUID(uuidString: row.text(1) ?? "") else { return nil }
        return ObsidianExportBindingRecord(
            destinationID: destinationID, sessionID: sessionID,
            component: ObsidianExportComponent(rawValue: row.text(2) ?? "") ?? .meeting,
            relativePath: row.text(3) ?? "", markerID: row.text(4),
            lastExportedRevision: Int(row.integer(8) ?? 0),
            lastBlockSHA256: row.text(9), lastFileSHA256: row.text(10),
            state: ObsidianBindingState(rawValue: row.text(12) ?? "") ?? .idle,
            errorCode: row.text(13),
            updatedAt: Self.date(row.integer(16)) ?? .distantPast)
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
            updatedAt: Self.date(row.integer(8)) ?? .distantPast)
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
        try db.run("UPDATE meeting_outcomes SET state='failed', error_code='interrupted', updated_at=? WHERE state IN ('pending','draft')") {
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
        try db.run("UPDATE export_outbox SET paused=0, attempt_count=0, next_attempt_at=0, last_error_code=NULL, updated_at=?") {
            try Self.bindInt($0, Date().ms, at: 1)
        }
    }
}
