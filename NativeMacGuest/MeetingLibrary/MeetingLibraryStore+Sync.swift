import ConferenceCore
import Foundation

extension MeetingLibraryStore {
    /// Keep the source summary and historical task citations when an alias replaces a session.
    func preserveRedirectedHistory(from source: UUID, to target: UUID) throws {
        let db = try db()
        try db.transaction {
            try Self.ensureSessionExists(db: db, sessionID: target)
            if let row = try db.one("SELECT outcome_id,revision,updated_at FROM meeting_outcomes WHERE session_id=?", bind: {
                try Self.bindText($0, source.uuidString, at: 1)
            }), let id = row.text(0).flatMap(UUID.init(uuidString:)), let outcome = try Self.storedOutcome(db: db, id: id) {
                try Self.recordOutcomeVersion(db: db, outcome: outcome, sessionID: source,
                    revision: Int(row.integer(1) ?? 1), savedAt: Self.date(row.integer(2)), canonicalOutcomeID: id)
            }
            for table in ["meeting_outcome_versions", "meeting_outcome_task_links"] {
                try db.run("UPDATE \(table) SET session_id=? WHERE session_id=?") {
                    try Self.bindText($0, target.uuidString, at: 1)
                    try Self.bindText($0, source.uuidString, at: 2)
                }
            }
        }
    }

    func noteSyncBase(_ sessionID: UUID) throws -> NoteBaseSnapshot? {
        guard let row = try db().one("SELECT sha256, markdown FROM note_sync_bases WHERE session_id=?", bind: {
            try Self.bindText($0, sessionID.uuidString, at: 1)
        }), let sha = row.text(0), let markdown = row.text(1) else { return nil }
        return NoteBaseSnapshot(sessionID: sessionID, sha256: sha, markdown: markdown)
    }

    func saveNoteSyncBase(_ sessionID: UUID, markdown: String) throws {
        let sha = SyncedMeetingNote.sha256(markdown)
        try db().run("""
            INSERT INTO note_sync_bases(session_id,sha256,markdown) VALUES(?,?,?)
            ON CONFLICT(session_id) DO UPDATE SET sha256=excluded.sha256,markdown=excluded.markdown
            """) {
            try Self.bindText($0, sessionID.uuidString, at: 1)
            try Self.bindText($0, sha, at: 2)
            try Self.bindText($0, markdown, at: 3)
        }
    }

    struct RemoteSessionApplyResult {
        var changed: Bool
        var becameEnded: Bool = false
        var exportRevision: Int = 0
        var newManualSaveAt: Date? = nil
    }

    @discardableResult
    func applyRemoteSession(_ remote: SyncedMeetingSession, deferOutbox: Bool = false) throws -> Bool {
        try applyRemoteSessionDetailed(remote, deferOutbox: deferOutbox).changed
    }

    private func applyRemoteSessionDetailed(_ remote: SyncedMeetingSession, deferOutbox: Bool) throws -> RemoteSessionApplyResult {
        let db = try db()
        if remote.isDeleted.value {
            let existed = try db.one("SELECT 1 FROM meeting_sessions WHERE session_id=?", bind: {
                try Self.bindText($0, remote.id.uuidString, at: 1)
            }) != nil
            if existed {
                try db.transaction {
                    for table in ["export_outbox", "export_bindings", "note_chunks", "note_sync_bases", "meeting_sessions"] {
                        try db.run("DELETE FROM \(table) WHERE session_id=?") {
                            try Self.bindText($0, remote.id.uuidString, at: 1)
                        }
                    }
                }
            }
            return RemoteSessionApplyResult(changed: existed)
        }
        if let canonical = remote.canonicalSessionID?.value, canonical != remote.id {
            let exists = try db.one("SELECT 1 FROM meeting_sessions WHERE session_id=?", bind: {
                try Self.bindText($0, remote.id.uuidString, at: 1)
            }) != nil
            if exists {
                try db.run("DELETE FROM meeting_sessions WHERE session_id=?") {
                    try Self.bindText($0, remote.id.uuidString, at: 1)
                }
            }
            return RemoteSessionApplyResult(changed: exists)
        }

        return try db.transaction {
            let existingRow = try db.one("SELECT * FROM meeting_sessions WHERE session_id=?", bind: {
                try Self.bindText($0, remote.id.uuidString, at: 1)
            })
            let existing = existingRow.map(Self.session(from:))
            let newState = MeetingSessionRecord.State(rawValue: remote.state.value) ?? .ended
            let newTitle = remote.title.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (existing?.title ?? L("Meeting"))
                : remote.title.value
            let newEndedAt = remote.endedAt.value ?? existing?.endedAt
            let newInvitation = remote.invitation.value ?? existing?.invitation
            let newRoom = remote.roomIdentity.isEmpty ? (existing?.roomIdentity ?? "") : remote.roomIdentity
            let newSeries = remote.calendarSeriesID ?? existing?.calendarSeriesID

            let exportedChanged = existing == nil ||
                existing?.title != newTitle ||
                existing?.endedAt != newEndedAt ||
                existing?.state != newState

            var exportRevision = existing?.exportRevision ?? 0
            if exportedChanged { exportRevision += 1 }
            let now = Date()

            if let existing {
                try db.run("""
                    UPDATE meeting_sessions SET
                        title=?, title_folded=?, invitation=?, room_identity=?, calendar_series_id=?,
                        started_at=?, ended_at=?, time_zone_id=?, state=?, export_revision=?,
                        updated_at=?, start_provenance=?
                    WHERE session_id=?
                    """) {
                    try Self.bindText($0, newTitle, at: 1)
                    try Self.bindText($0, MeetingTextNormalization.folded(newTitle), at: 2)
                    try Self.bindText($0, newInvitation?.absoluteString, at: 3)
                    try Self.bindText($0, newRoom, at: 4)
                    try Self.bindText($0, newSeries, at: 5)
                    try Self.bindInt($0, (remote.startedAt != .distantPast ? remote.startedAt : existing.startedAt).syncMilliseconds, at: 6)
                    try Self.bindOptionalInt($0, newEndedAt?.syncMilliseconds, at: 7)
                    try Self.bindText($0, remote.timeZoneID.isEmpty ? existing.timeZoneID : remote.timeZoneID, at: 8)
                    try Self.bindText($0, newState.rawValue, at: 9)
                    try Self.bindInt($0, Int64(exportRevision), at: 10)
                    try Self.bindInt($0, now.syncMilliseconds, at: 11)
                    try Self.bindText($0, remote.startProvenance ?? existing.startProvenance?.rawValue ?? "recorded", at: 12)
                    try Self.bindText($0, remote.id.uuidString, at: 13)
                }
            } else {
                try db.run("""
                    INSERT INTO meeting_sessions(
                        session_id,title,title_folded,invitation,room_identity,calendar_series_id,
                        continuation_id,started_at,ended_at,time_zone_id,state,export_revision,
                        created_at,updated_at,start_provenance,outcome_end_fallback
                    ) VALUES(?,?,?,?,?,?,NULL,?,?,?,?,?,?,?,?,NULL)
                    """) {
                    try Self.bindText($0, remote.id.uuidString, at: 1)
                    try Self.bindText($0, newTitle, at: 2)
                    try Self.bindText($0, MeetingTextNormalization.folded(newTitle), at: 3)
                    try Self.bindText($0, newInvitation?.absoluteString, at: 4)
                    try Self.bindText($0, newRoom, at: 5)
                    try Self.bindText($0, newSeries, at: 6)
                    try Self.bindInt($0, remote.startedAt.syncMilliseconds, at: 7)
                    try Self.bindOptionalInt($0, newEndedAt?.syncMilliseconds, at: 8)
                    try Self.bindText($0, remote.timeZoneID, at: 9)
                    try Self.bindText($0, newState.rawValue, at: 10)
                    try Self.bindInt($0, Int64(exportRevision), at: 11)
                    try Self.bindInt($0, remote.createdAt.syncMilliseconds, at: 12)
                    try Self.bindInt($0, now.syncMilliseconds, at: 13)
                    try Self.bindText($0, remote.startProvenance ?? "recorded", at: 14)
                }
            }

            if remote.hasTitleOverride.value {
                try db.run("""
                    INSERT INTO meeting_title_overrides(session_id,title,original_title) VALUES(?,?,?)
                    ON CONFLICT(session_id) DO UPDATE SET title=excluded.title
                    """) {
                    try Self.bindText($0, remote.id.uuidString, at: 1)
                    try Self.bindText($0, newTitle, at: 2)
                    try Self.bindText($0, existing?.title ?? newTitle, at: 3)
                }
            }

            let becameEnded = existing?.state != .ended && newState == .ended
            if !deferOutbox {
                if becameEnded {
                    let awaiting = remote.outcomeClaim?.value?.state == "pending"
                    _ = try Self.queueOutbox(
                        db: db,
                        sessionID: remote.id,
                        desiredRevision: exportRevision,
                        finalEnd: true,
                        awaitingOutcome: awaiting
                    )
                } else if exportedChanged {
                    _ = try Self.queueOutbox(db: db, sessionID: remote.id, desiredRevision: exportRevision)
                }
            }

            var newManualAt: Date?
            if let manualAt = remote.manualObsidianSaveAt?.value {
                let metaKey = "remote_manual_obsidian_" + remote.id.uuidString
                let lastRaw = try db.one("SELECT value FROM meeting_library_meta WHERE key=?", bind: {
                    try Self.bindText($0, metaKey, at: 1)
                })?.text(0)
                let lastMs = lastRaw.flatMap(Int64.init) ?? 0
                if manualAt.syncMilliseconds > lastMs {
                    newManualAt = manualAt
                    if !deferOutbox {
                        try db.run("""
                            INSERT INTO meeting_library_meta(key,value) VALUES(?,?)
                            ON CONFLICT(key) DO UPDATE SET value=excluded.value
                            """) {
                            try Self.bindText($0, metaKey, at: 1)
                            try Self.bindText($0, String(manualAt.syncMilliseconds), at: 2)
                        }
                        if let destination = try Self.activeDestination(db),
                           destination.vaultBookmark != nil,
                           let snapshot = try Self.exportSnapshot(db, sessionID: remote.id) {
                            try Self.putExport(db: db, destination: destination, snapshot: snapshot, intent: .manualSave, held: false)
                        }
                    }
                }
            }

            return RemoteSessionApplyResult(
                changed: exportedChanged || newManualAt != nil,
                becameEnded: becameEnded,
                exportRevision: exportRevision,
                newManualSaveAt: newManualAt
            )
        }
    }

    @discardableResult
    func applyRemoteNote(
        _ remote: SyncedMeetingNote,
        localDeviceID: String,
        deferOutbox: Bool = false
    ) throws -> (markdown: String, changed: Bool) {
        let db = try db()
        if remote.isDeleted.value {
            try db.transaction {
                try db.run("DELETE FROM meeting_notes WHERE session_id=?", bind: { try Self.bindText($0, remote.sessionID.uuidString, at: 1) })
                try db.run("DELETE FROM note_chunks WHERE session_id=?", bind: { try Self.bindText($0, remote.sessionID.uuidString, at: 1) })
                try db.run("DELETE FROM note_sync_bases WHERE session_id=?", bind: { try Self.bindText($0, remote.sessionID.uuidString, at: 1) })
            }
            participationNoteChanges.willChange(remote.sessionID)
            return ("", true)
        }

        participationNoteChanges.willChange(remote.sessionID)
        return try db.transaction {
            try Self.ensureSessionExists(db: db, sessionID: remote.sessionID)
            let existingNoteRow = try db.one("SELECT * FROM meeting_notes WHERE session_id=?", bind: {
                try Self.bindText($0, remote.sessionID.uuidString, at: 1)
            })
            let existingNote = try existingNoteRow.map(Self.note(from:))
            let baseRow = try db.one("SELECT markdown FROM note_sync_bases WHERE session_id=?", bind: {
                try Self.bindText($0, remote.sessionID.uuidString, at: 1)
            })?.text(0)

            let finalMarkdown: String
            let noteChanged: Bool
            if let existingNote {
                if existingNote.markdown == remote.markdown {
                    finalMarkdown = existingNote.markdown
                    noteChanged = false
                } else {
                    let localVersion = SyncVersion(counter: Int64(max(1, existingNote.revision)), device: localDeviceID)
                    let merge = NoteThreeWayMerger.merge(
                        base: baseRow,
                        local: existingNote.markdown,
                        localVersion: localVersion,
                        remote: remote.markdown,
                        remoteVersion: remote.version
                    )
                    finalMarkdown = merge.markdown
                    noteChanged = finalMarkdown != existingNote.markdown
                }
            } else {
                finalMarkdown = remote.markdown
                noteChanged = true
            }

            let baseMarkdown = remote.markdown
            try db.run("""
                INSERT INTO note_sync_bases(session_id,sha256,markdown) VALUES(?,?,?)
                ON CONFLICT(session_id) DO UPDATE SET sha256=excluded.sha256,markdown=excluded.markdown
                """) {
                try Self.bindText($0, remote.sessionID.uuidString, at: 1)
                try Self.bindText($0, SyncedMeetingNote.sha256(baseMarkdown), at: 2)
                try Self.bindText($0, baseMarkdown, at: 3)
            }

            guard noteChanged else {
                return (finalMarkdown, false)
            }

            let noteID = existingNote?.id ?? remote.noteID
            let revision = (existingNote?.revision ?? 0) + 1
            let now = Date()

            let sessionRow = try db.one("SELECT export_revision FROM meeting_sessions WHERE session_id=?", bind: {
                try Self.bindText($0, remote.sessionID.uuidString, at: 1)
            })
            let exportRevision = Int((sessionRow?.integer(0) ?? 0) + 1)
            try db.run("UPDATE meeting_sessions SET export_revision=?,updated_at=? WHERE session_id=?") {
                try Self.bindInt($0, Int64(exportRevision), at: 1)
                try Self.bindInt($0, now.syncMilliseconds, at: 2)
                try Self.bindText($0, remote.sessionID.uuidString, at: 3)
            }

            if existingNote == nil {
                try db.run("INSERT INTO meeting_notes(note_id,session_id,markdown,revision,created_at,updated_at) VALUES(?,?,?,?,?,?)") {
                    try Self.bindText($0, noteID.uuidString, at: 1)
                    try Self.bindText($0, remote.sessionID.uuidString, at: 2)
                    try Self.bindText($0, finalMarkdown, at: 3)
                    try Self.bindInt($0, Int64(revision), at: 4)
                    try Self.bindInt($0, now.syncMilliseconds, at: 5)
                    try Self.bindInt($0, now.syncMilliseconds, at: 6)
                }
            } else {
                try db.run("UPDATE meeting_notes SET markdown=?,revision=?,updated_at=? WHERE session_id=?") {
                    try Self.bindText($0, finalMarkdown, at: 1)
                    try Self.bindInt($0, Int64(revision), at: 2)
                    try Self.bindInt($0, now.syncMilliseconds, at: 3)
                    try Self.bindText($0, remote.sessionID.uuidString, at: 4)
                }
            }

            try db.run("DELETE FROM note_chunks WHERE session_id=?") {
                try Self.bindText($0, remote.sessionID.uuidString, at: 1)
            }
            for chunk in MeetingTextNormalization.chunks(for: finalMarkdown, noteID: noteID, sessionID: remote.sessionID, revision: revision) {
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

            if !deferOutbox {
                _ = try Self.queueOutbox(db: db, sessionID: remote.sessionID, desiredRevision: exportRevision)
            }
            return (finalMarkdown, true)
        }
    }

    @discardableResult
    func applyRemoteOutcomeAndTasks(
        sessionID: UUID,
        outcome: SyncedMeetingOutcome?,
        tasks: [SyncedMeetingTask],
        links: [SyncedTaskLink],
        deferOutbox: Bool = false
    ) throws -> Bool {
        let db = try db()
        if outcome?.isDeleted.value == true {
            try db.run("DELETE FROM meeting_outcomes WHERE session_id=?") {
                try Self.bindText($0, sessionID.uuidString, at: 1)
            }
            return true
        }
        // Tasks are independent CloudKit records: a phone can create one before
        // generating a summary, or its outcome can arrive in a later batch.
        let existingRow = try db.one("SELECT outcome_id,state,revision FROM meeting_outcomes WHERE session_id=?", bind: {
            try Self.bindText($0, sessionID.uuidString, at: 1)
        })
        let firstTask = tasks.filter { !$0.isDeleted.value }.min { $0.id.uuidString < $1.id.uuidString }
        guard let canonicalOutcomeID = existingRow?.text(0).flatMap(UUID.init(uuidString:))
            ?? outcome?.outcomeID ?? firstTask?.outcomeID else { return false }
        let existingOutcome = try Self.storedOutcome(db: db, id: canonicalOutcomeID)
        let targetState = outcome.flatMap { MeetingOutcomePersistenceState(rawValue: $0.state.value) }
            ?? existingRow?.text(1).flatMap(MeetingOutcomePersistenceState.init(rawValue:)) ?? .notStarted

        return try db.transaction {
            try Self.ensureSessionExists(db: db, sessionID: sessionID, provisional: outcome == nil)
            let sessionRow = try db.one("SELECT title,invitation,calendar_series_id,ended_at,export_revision FROM meeting_sessions WHERE session_id=?", bind: {
                try Self.bindText($0, sessionID.uuidString, at: 1)
            })
            let title = sessionRow?.text(0) ?? L("Meeting")
            let invitation = sessionRow?.text(1).flatMap(URL.init(string:))
            let seriesID = sessionRow?.text(2)
            let endedAt = Self.date(sessionRow?.integer(3)) ?? outcome?.updatedAt ?? firstTask?.updatedAt ?? existingOutcome?.endedAt ?? Date()

            let activeTasks = tasks
                .filter { !$0.isDeleted.value }
                .sorted { ($0.ordinal.value, $0.id.uuidString) < ($1.ordinal.value, $1.id.uuidString) }
                .map { task in
                    MeetingOutcomeTask(
                        id: task.id,
                        text: task.text.value,
                        owner: task.owner.value,
                        assigneeID: task.assigneeID.value,
                        dueAt: task.dueAt.value,
                        dueDay: task.dueDay.value,
                        reminderAt: task.reminderAt.value,
                        done: task.done.value,
                        completedAt: task.completedAt.value
                    )
                }

            let reviewCandidates = outcome?.reviewCandidates.value.map { snap in
                MeetingOutcomeTask(
                    id: snap.id,
                    text: snap.text,
                    owner: snap.owner,
                    assigneeID: snap.assigneeID,
                    dueAt: snap.dueAt,
                    dueDay: snap.dueDay,
                    reminderAt: snap.reminderAt,
                    done: snap.done,
                    completedAt: snap.completedAt
                )
            }

            var mapped = MeetingOutcome(
                id: canonicalOutcomeID,
                meetingID: sessionID,
                meetingTitle: title,
                invitation: invitation,
                seriesID: seriesID,
                endedAt: endedAt,
                summary: outcome?.summary.value ?? existingOutcome?.summary ?? "",
                decisions: outcome?.decisions.value ?? existingOutcome?.decisions ?? [],
                tasks: activeTasks,
                openQuestions: outcome?.openQuestions.value ?? existingOutcome?.openQuestions ?? []
            )
            mapped.taskReviewCandidates = reviewCandidates ?? existingOutcome?.taskReviewCandidates ?? []
            mapped.taskReviewMatches = existingOutcome?.taskReviewMatches ?? [:]
            if let existingOutcome {
                if existingOutcome.summary == mapped.summary, existingOutcome.decisions == mapped.decisions,
                   existingOutcome.openQuestions == mapped.openQuestions {
                    mapped.transcriptFingerprint = existingOutcome.transcriptFingerprint
                }
                if existingOutcome.decisions == mapped.decisions {
                    mapped.decisionEvidence = existingOutcome.decisionEvidence
                }
            }

            let existingState = existingRow?.text(1).flatMap(MeetingOutcomePersistenceState.init(rawValue:))
            let outcomeChanged = existingOutcome != mapped || existingState != targetState
            let now = Date()
            if outcomeChanged {
                let revision = Int((existingRow?.integer(2) ?? 0) + 1)
                let payload = try JSONEncoder.attention.encode(mapped)
                try db.run("""
                    INSERT INTO meeting_outcomes(outcome_id,session_id,state,payload_json,revision,generation_owner,error_code,created_at,updated_at)
                    VALUES(?,?,?,?,?,NULL,NULL,?,?)
                    ON CONFLICT(outcome_id) DO UPDATE SET
                        state=excluded.state,payload_json=excluded.payload_json,revision=excluded.revision,updated_at=excluded.updated_at
                    """) {
                    try Self.bindText($0, canonicalOutcomeID.uuidString, at: 1)
                    try Self.bindText($0, sessionID.uuidString, at: 2)
                    try Self.bindText($0, targetState.rawValue, at: 3)
                    try Self.bindBlob($0, payload, at: 4)
                    try Self.bindInt($0, Int64(revision), at: 5)
                    try Self.bindInt($0, endedAt.syncMilliseconds, at: 6)
                    try Self.bindInt($0, now.syncMilliseconds, at: 7)
                }
                try Self.replaceTasks(db: db, outcome: mapped)
            }

            for version in outcome?.versions ?? [] {
                var snapOutcome = mapped
                snapOutcome.summary = version.summary
                snapOutcome.decisions = version.decisions
                snapOutcome.openQuestions = version.openQuestions
                try Self.recordOutcomeVersion(
                    db: db,
                    outcome: snapOutcome,
                    sessionID: sessionID,
                    revision: version.revision,
                    savedAt: version.savedAt,
                    canonicalOutcomeID: canonicalOutcomeID
                )
            }

            for link in links {
                try db.run("""
                    INSERT OR IGNORE INTO meeting_outcome_task_links(outcome_id,historical_task_id,session_id,canonical_task_id)
                    VALUES(?,?,?,?)
                    """) {
                    try Self.bindText($0, canonicalOutcomeID.uuidString, at: 1)
                    try Self.bindText($0, link.historicalTaskID.uuidString, at: 2)
                    try Self.bindText($0, sessionID.uuidString, at: 3)
                    try Self.bindText($0, link.canonicalTaskID.uuidString, at: 4)
                }
            }

            for task in tasks {
                for (profileID, archived) in task.archivedByProfile {
                    if let archivedAt = archived.value {
                        try db.run("""
                            INSERT INTO personal_task_archive(profile_id,task_id,archived_at) VALUES(?,?,?)
                            ON CONFLICT(profile_id,task_id) DO UPDATE SET archived_at=excluded.archived_at
                            """) {
                            try Self.bindText($0, profileID, at: 1)
                            try Self.bindText($0, task.id.uuidString, at: 2)
                            try Self.bindInt($0, archivedAt.syncMilliseconds, at: 3)
                        }
                        try Self.cancelTaskReminder(db: db, taskID: task.id)
                    } else {
                        try db.run("DELETE FROM personal_task_archive WHERE profile_id=? AND task_id=?") {
                            try Self.bindText($0, profileID, at: 1)
                            try Self.bindText($0, task.id.uuidString, at: 2)
                        }
                    }
                }
                if task.done.value || task.reminderAt.value == nil {
                    try Self.cancelTaskReminder(db: db, taskID: task.id)
                }
            }

            if outcomeChanged {
                let latestRevRow = try db.one("SELECT export_revision FROM meeting_sessions WHERE session_id=?", bind: {
                    try Self.bindText($0, sessionID.uuidString, at: 1)
                })
                let exportRevision = Int((latestRevRow?.integer(0) ?? sessionRow?.integer(4) ?? 0) + 1)
                try db.run("UPDATE meeting_sessions SET export_revision=?,updated_at=? WHERE session_id=?") {
                    try Self.bindInt($0, Int64(exportRevision), at: 1)
                    try Self.bindInt($0, now.syncMilliseconds, at: 2)
                    try Self.bindText($0, sessionID.uuidString, at: 3)
                }
                if !deferOutbox {
                    _ = try Self.queueOutbox(
                        db: db,
                        sessionID: sessionID,
                        desiredRevision: exportRevision,
                        outcomeReady: targetState == .ready
                    )
                }
            }
            return outcomeChanged
        }
    }

    /// Applies a complete synced session bundle (session + note + outcome + tasks + links) before
    /// queueing Obsidian export so initial-end snapshots always include notes and outcomes.
    func applyRemoteSessionBundle(
        sessionID: UUID,
        session: SyncedMeetingSession?,
        note: SyncedMeetingNote?,
        outcome: SyncedMeetingOutcome?,
        tasks: [SyncedMeetingTask],
        links: [SyncedTaskLink],
        localDeviceID: String
    ) throws -> (finalMarkdown: String?, sessionBecameActiveLocal: Bool) {
        var sessionResult = RemoteSessionApplyResult(changed: false)
        if let session {
            sessionResult = try applyRemoteSessionDetailed(session, deferOutbox: true)
            if session.isDeleted.value || (session.canonicalSessionID?.value != nil && session.canonicalSessionID?.value != session.id) {
                return (nil, false)
            }
        }

        var noteMarkdown: String?
        var noteChanged = false
        if let note {
            let applied = try applyRemoteNote(note, localDeviceID: localDeviceID, deferOutbox: true)
            noteMarkdown = applied.markdown
            noteChanged = applied.changed
        }

        var outcomeChanged = false
        if outcome != nil || !tasks.isEmpty || !links.isEmpty {
            outcomeChanged = try applyRemoteOutcomeAndTasks(
                sessionID: sessionID,
                outcome: outcome,
                tasks: tasks,
                links: links,
                deferOutbox: true
            )
        }

        let db = try db()
        let latestRevision = Int(
            try db.one("SELECT export_revision FROM meeting_sessions WHERE session_id=?", bind: {
                try Self.bindText($0, sessionID.uuidString, at: 1)
            })?.integer(0) ?? Int64(sessionResult.exportRevision)
        )

        if let manualAt = sessionResult.newManualSaveAt {
            let metaKey = "remote_manual_obsidian_" + sessionID.uuidString
            try db.run("""
                INSERT INTO meeting_library_meta(key,value) VALUES(?,?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """) {
                try Self.bindText($0, metaKey, at: 1)
                try Self.bindText($0, String(manualAt.syncMilliseconds), at: 2)
            }
            if let destination = try Self.activeDestination(db),
               destination.vaultBookmark != nil,
               let snapshot = try Self.exportSnapshot(db, sessionID: sessionID) {
                try Self.putExport(db: db, destination: destination, snapshot: snapshot, intent: .manualSave, held: false)
            }
        } else if sessionResult.becameEnded {
            let awaiting = (outcome?.state.value != "ready") && (session?.outcomeClaim?.value?.state == "pending")
            _ = try Self.queueOutbox(
                db: db,
                sessionID: sessionID,
                desiredRevision: latestRevision,
                outcomeReady: outcome?.state.value == "ready",
                finalEnd: true,
                awaitingOutcome: awaiting
            )
        } else if sessionResult.changed || noteChanged || outcomeChanged {
            _ = try Self.queueOutbox(
                db: db,
                sessionID: sessionID,
                desiredRevision: latestRevision,
                outcomeReady: outcome?.state.value == "ready"
            )
        }

        return (noteMarkdown, session != nil && !session!.isDeleted.value && session!.canonicalSessionID == nil)
    }

    @discardableResult
    func applyRemoteTaskProfile(_ remote: SyncedTaskProfile) throws -> Bool {
        let current = try taskProfile()
        let updated = PersonalTaskProfile(
            id: remote.profileID.isEmpty ? current.id : remote.profileID,
            assigneeID: remote.assigneeID.value,
            aliases: remote.aliases.value
        )
        guard updated != current else { return false }
        try saveTaskProfile(updated)
        return true
    }

    func obsidianSyncReceipt(for sessionID: UUID, exporterDeviceID: String) throws -> ObsidianSyncReceipt? {
        let db = try db()
        guard let destination = try Self.activeDestination(db) else { return nil }
        if let outbox = try db.one("""
            SELECT paused, last_error_code, policy_held, desired_revision, updated_at
            FROM export_outbox WHERE destination_id=? AND session_id=?
            """, bind: {
                try Self.bindText($0, destination.id.uuidString, at: 1)
                try Self.bindText($0, sessionID.uuidString, at: 2)
            }) {
            let paused = outbox.bool(0)
            let held = outbox.bool(2)
            let state = paused ? "conflict" : (held ? "held" : "queued")
            return ObsidianSyncReceipt(
                exporterDeviceID: exporterDeviceID,
                state: state,
                relativePath: nil,
                exportedRevision: Int(outbox.integer(3) ?? 0),
                updatedAt: Self.date(outbox.integer(4)) ?? Date(),
                errorMessage: outbox.text(1)
            )
        }
        let component: ObsidianExportComponent = destination.mode == .worklog ? .worklog : .meeting
        if let row = try db.one("""
            SELECT * FROM export_bindings WHERE destination_id=? AND session_id=? AND component=?
            """, bind: {
                try Self.bindText($0, destination.id.uuidString, at: 1)
                try Self.bindText($0, sessionID.uuidString, at: 2)
                try Self.bindText($0, component.rawValue, at: 3)
            }), let binding = Self.binding(from: row, destinationID: destination.id) {
            return ObsidianSyncReceipt(
                exporterDeviceID: exporterDeviceID,
                state: binding.state.rawValue,
                relativePath: binding.relativePath,
                exportedRevision: binding.lastExportedRevision,
                updatedAt: binding.updatedAt,
                errorMessage: binding.errorCode,
                transcriptIncluded: binding.transcriptSignature.map { !$0.isEmpty }
            )
        }
        return nil
    }

    func allTaskArchiveEntries() throws -> [UUID: [(profileID: String, archivedAt: Date)]] {
        let rows = try db().rows("SELECT task_id, profile_id, archived_at FROM personal_task_archive")
        var result: [UUID: [(profileID: String, archivedAt: Date)]] = [:]
        for row in rows {
            guard let taskID = row.text(0).flatMap(UUID.init(uuidString:)),
                  let profileID = row.text(1),
                  let date = Self.date(row.integer(2)) else { continue }
            result[taskID, default: []].append((profileID, date))
        }
        return result
    }

    private static func ensureSessionExists(db: MeetingSQLiteConnection, sessionID: UUID, provisional: Bool = false) throws {
        guard try db.one("SELECT 1 FROM meeting_sessions WHERE session_id=?", bind: {
            try bindText($0, sessionID.uuidString, at: 1)
        }) == nil else { return }
        let now = Date()
        try db.run("""
            INSERT INTO meeting_sessions(
                session_id,title,title_folded,invitation,room_identity,calendar_series_id,
                continuation_id,started_at,ended_at,time_zone_id,state,export_revision,
                created_at,updated_at,start_provenance,outcome_end_fallback
            ) VALUES(?,?,?,NULL,'',NULL,NULL,?,NULL,?,'ended',0,?,?,?,NULL)
            """) {
            try bindText($0, sessionID.uuidString, at: 1)
            let placeholder = L("Meeting")
            try bindText($0, placeholder, at: 2)
            try bindText($0, MeetingTextNormalization.folded(placeholder), at: 3)
            try bindInt($0, (provisional ? Date.distantPast : now).syncMilliseconds, at: 4)
            try bindText($0, TimeZone.current.identifier, at: 5)
            try bindInt($0, now.syncMilliseconds, at: 6)
            try bindInt($0, now.syncMilliseconds, at: 7)
            try bindText($0, provisional ? "unknown" : "recorded", at: 8)
        }
    }

    struct LocalOutcomeSyncEntry {
        var outcome: MeetingOutcome
        var state: MeetingOutcomePersistenceState
        var revision: Int
        var updatedAt: Date
        var versions: [SyncedOutcomeVersionSnapshot]
    }

    struct LocalLibrarySyncSnapshot {
        var sessions: [MeetingSessionRecord]
        var titleOverrides: Set<UUID>
        var notes: [UUID: MeetingNoteRecord]
        var noteBases: [UUID: NoteBaseSnapshot]
        var outcomesBySession: [UUID: LocalOutcomeSyncEntry]
        var taskLinks: [SyncedTaskLink]
        var taskArchive: [UUID: [(profileID: String, archivedAt: Date)]]
        var taskProfile: PersonalTaskProfile
        var obsidianReceipts: [UUID: ObsidianSyncReceipt]
    }

    func localSyncSnapshot(exporterDeviceID: String) throws -> LocalLibrarySyncSnapshot {
        let db = try db()
        let sessions = try db.rows("SELECT * FROM meeting_sessions ORDER BY started_at DESC").map(Self.session(from:))
        let titleOverrideIDs = Set(
            try db.rows("SELECT session_id FROM meeting_title_overrides")
                .compactMap { $0.text(0).flatMap(UUID.init(uuidString:)) }
        )

        var notes: [UUID: MeetingNoteRecord] = [:]
        for row in try db.rows("SELECT * FROM meeting_notes") {
            let note = try Self.note(from: row)
            notes[note.sessionID] = note
        }

        var noteBases: [UUID: NoteBaseSnapshot] = [:]
        for row in try db.rows("SELECT session_id,sha256,markdown FROM note_sync_bases") {
            guard let sid = row.text(0).flatMap(UUID.init(uuidString:)),
                  let sha = row.text(1),
                  let md = row.text(2) else { continue }
            noteBases[sid] = NoteBaseSnapshot(sessionID: sid, sha256: sha, markdown: md)
        }

        var outcomesBySession: [UUID: LocalOutcomeSyncEntry] = [:]
        let outcomeRows = try db.rows("SELECT outcome_id,session_id,state,revision,updated_at FROM meeting_outcomes")
        for row in outcomeRows {
            guard let oid = row.text(0).flatMap(UUID.init(uuidString:)),
                  let sid = row.text(1).flatMap(UUID.init(uuidString:)),
                  let stored = try Self.storedOutcome(db: db, id: oid) else { continue }
            let state = row.text(2).flatMap(MeetingOutcomePersistenceState.init(rawValue:)) ?? .ready
            let revision = Int(row.integer(3) ?? 1)
            let updatedAt = Self.date(row.integer(4)) ?? stored.endedAt
            let versionRows = try outcomeVersions(sessionID: sid)
            let snapshots = versionRows.map { ver in
                SyncedOutcomeVersionSnapshot(
                    revision: ver.revision,
                    summary: ver.outcome.summary,
                    decisions: ver.outcome.decisions,
                    openQuestions: ver.outcome.openQuestions,
                    savedAt: ver.savedAt ?? updatedAt,
                    deviceID: exporterDeviceID
                )
            }
            outcomesBySession[sid] = LocalOutcomeSyncEntry(
                outcome: stored,
                state: state,
                revision: revision,
                updatedAt: updatedAt,
                versions: snapshots
            )
        }

        var taskLinks: [SyncedTaskLink] = []
        for row in try db.rows("SELECT session_id,historical_task_id,canonical_task_id FROM meeting_outcome_task_links") {
            guard let sid = row.text(0).flatMap(UUID.init(uuidString:)),
                  let historical = row.text(1).flatMap(UUID.init(uuidString:)),
                  let canonical = row.text(2).flatMap(UUID.init(uuidString:)) else { continue }
            taskLinks.append(SyncedTaskLink(sessionID: sid, historicalTaskID: historical, canonicalTaskID: canonical))
        }

        let taskArchive = try allTaskArchiveEntries()
        let taskProfile = try taskProfile()

        var obsidianReceipts: [UUID: ObsidianSyncReceipt] = [:]
        for session in sessions {
            if let receipt = try obsidianSyncReceipt(for: session.id, exporterDeviceID: exporterDeviceID) {
                obsidianReceipts[session.id] = receipt
            }
        }

        return LocalLibrarySyncSnapshot(
            sessions: sessions,
            titleOverrides: titleOverrideIDs,
            notes: notes,
            noteBases: noteBases,
            outcomesBySession: outcomesBySession,
            taskLinks: taskLinks,
            taskArchive: taskArchive,
            taskProfile: taskProfile,
            obsidianReceipts: obsidianReceipts
        )
    }
}
