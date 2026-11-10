import Foundation

enum MeetingLibrarySchema {
    static let currentVersion = 1

    static let ddl: [String] = [
        """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS meeting_sessions (
            session_id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            title_folded TEXT NOT NULL,
            invitation TEXT,
            room_identity TEXT,
            calendar_series_id TEXT,
            continuation_id TEXT,
            started_at INTEGER NOT NULL,
            ended_at INTEGER,
            time_zone_id TEXT NOT NULL,
            state TEXT NOT NULL,
            export_revision INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_meeting_sessions_started ON meeting_sessions(started_at, session_id)",
        "CREATE INDEX IF NOT EXISTS idx_meeting_sessions_series ON meeting_sessions(calendar_series_id)",
        "CREATE INDEX IF NOT EXISTS idx_meeting_sessions_room ON meeting_sessions(room_identity)",
        """
        CREATE TABLE IF NOT EXISTS meeting_notes (
            note_id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL UNIQUE REFERENCES meeting_sessions(session_id) ON DELETE CASCADE,
            markdown TEXT NOT NULL,
            revision INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_meeting_notes_updated ON meeting_notes(updated_at)",
        """
        CREATE TABLE IF NOT EXISTS meeting_outcomes (
            outcome_id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL UNIQUE REFERENCES meeting_sessions(session_id) ON DELETE CASCADE,
            state TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            revision INTEGER NOT NULL,
            generation_owner TEXT,
            error_code TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_meeting_outcomes_updated ON meeting_outcomes(updated_at)",
        """
        CREATE TABLE IF NOT EXISTS export_destinations (
            destination_id TEXT PRIMARY KEY,
            enabled INTEGER NOT NULL,
            mode TEXT NOT NULL,
            config_json TEXT NOT NULL,
            config_revision INTEGER NOT NULL,
            vault_bookmark BLOB,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS export_bindings (
            destination_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            component TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            marker_id TEXT,
            day_key TEXT,
            month_key TEXT,
            layout_map_json TEXT,
            last_exported_revision INTEGER NOT NULL DEFAULT 0,
            last_block_sha256 TEXT,
            last_file_sha256 TEXT,
            last_file_identity TEXT,
            state TEXT NOT NULL,
            error_code TEXT,
            conflict_json TEXT,
            last_success_at INTEGER,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY(destination_id, session_id, component)
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_export_bindings_path ON export_bindings(relative_path, component)",
        """
        CREATE TABLE IF NOT EXISTS export_outbox (
            destination_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            desired_revision INTEGER NOT NULL,
            desired_config_revision INTEGER NOT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            next_attempt_at INTEGER NOT NULL DEFAULT 0,
            paused INTEGER NOT NULL DEFAULT 0,
            last_error_code TEXT,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY(destination_id, session_id)
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_export_outbox_due ON export_outbox(next_attempt_at, destination_id)",
        """
        CREATE TABLE IF NOT EXISTS note_chunks (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            note_id TEXT NOT NULL,
            note_revision INTEGER NOT NULL,
            ordinal INTEGER NOT NULL,
            start_offset INTEGER NOT NULL,
            end_offset INTEGER NOT NULL,
            start_line INTEGER NOT NULL,
            end_line INTEGER NOT NULL,
            text TEXT NOT NULL,
            text_folded TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_note_chunks_session ON note_chunks(session_id, note_revision)",
        "CREATE INDEX IF NOT EXISTS idx_note_chunks_text ON note_chunks(text_folded)",
    ]
}

enum MeetingTextNormalization {
    /// SQLite's NOCASE is ASCII-only. Store and query a Unicode-folded form so
    /// Cyrillic and accent-insensitive note search works without a provider call.
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func sqlLikeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    static func chunks(for markdown: String, noteID: UUID, sessionID: UUID, revision: Int) -> [MeetingNoteChunk] {
        var chunks: [MeetingNoteChunk] = []
        var block = ""
        var blockBytes = 0
        var newlines = 0
        var byteOffset = 0
        var blockStartOffset = 0
        var line = 1
        var blockStartLine = 1
        var ordinal = 0

        func emit(endOffset: Int, endLine: Int) {
            let clean = block.trimmingCharacters(in: .whitespacesAndNewlines)
            block = ""; blockBytes = 0; newlines = 0
            guard !clean.isEmpty else { return }
            chunks.append(.init(
                id: "\(noteID.uuidString)-\(revision)-\(ordinal)",
                sessionID: sessionID,
                noteID: noteID,
                noteRevision: revision,
                ordinal: ordinal,
                startOffset: blockStartOffset,
                endOffset: endOffset,
                startLine: blockStartLine,
                endLine: endLine,
                text: String(clean.prefix(4000))
            ))
            ordinal += 1
        }

        for character in markdown {
            let bytes = character.utf8.count
            if block.isEmpty { blockStartOffset = byteOffset; blockStartLine = line }
            block.append(character)
            blockBytes += bytes
            if character == "\n" { newlines += 1; line += 1 }
            byteOffset += bytes
            if blockBytes >= 4000 || newlines >= 40 {
                emit(endOffset: byteOffset, endLine: line)
            }
        }
        emit(endOffset: byteOffset, endLine: line)
        return chunks
    }
}
