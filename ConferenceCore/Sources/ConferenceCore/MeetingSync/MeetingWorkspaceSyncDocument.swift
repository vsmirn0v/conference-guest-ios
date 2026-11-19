import CryptoKit
import Foundation

public struct MeetingWorkspaceSyncDocument: Codable, Equatable, Sendable {
    public let device: String
    public private(set) var counter: Int64 = 0
    public private(set) var sessions: [UUID: SyncedMeetingSession] = [:]
    public private(set) var notes: [UUID: SyncedMeetingNote] = [:]
    public private(set) var noteBases: [UUID: NoteBaseSnapshot] = [:]
    public private(set) var outcomes: [UUID: SyncedMeetingOutcome] = [:]
    public private(set) var tasks: [UUID: SyncedMeetingTask] = [:]
    public private(set) var taskLinks: [String: SyncedTaskLink] = [:]
    public private(set) var taskProfiles: [String: SyncedTaskProfile] = [:]
    public private(set) var contextSettings: [String: SyncedMeetingContextSettings] = [:]
    public private(set) var transcriptChunks: [String: SyncedTranscriptChunk] = [:]
    /// Maps CloudKit transcript record ID (`"transcript:<session>:<device>:<chunk>"`) to session start date for retention pruning.
    public private(set) var cloudTranscriptIndex: [String: Date] = [:]

    public init(device: String = UUID().uuidString) {
        self.device = device
    }

    public mutating func nextVersion() -> SyncVersion {
        counter += 1
        return SyncVersion(counter: counter, device: device)
    }

    public static func occurrenceKey(
        calendarSeriesExternalID: String?,
        roomIdentity: String,
        startedAt: Date
    ) -> String {
        if let ext = calendarSeriesExternalID, !ext.isEmpty {
            let minuteBucket = Int64((startedAt.timeIntervalSince1970 / 60).rounded())
            return "cal:\(ext):\(minuteBucket):\(digest(roomIdentity).prefix(12))"
        }
        return "room:\(digest(roomIdentity))"
    }

    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func resolveCanonicalSessionID(for sessionID: UUID) -> UUID {
        var current = sessionID
        var visited: Set<UUID> = [sessionID]
        for _ in 0..<8 {
            guard let target = sessions[current]?.canonicalSessionID?.value,
                  target != current,
                  visited.insert(target).inserted else {
                break
            }
            current = target
        }
        return current
    }

    public mutating func upsertSession(_ incoming: SyncedMeetingSession) {
        counter = max(counter, incoming.maximumCounter)
        let canonical = resolveCanonicalSessionID(for: incoming.id)
        if canonical != incoming.id {
            var redirected = incoming
            redirected.canonicalSessionID = sessions[incoming.id]?.canonicalSessionID
                ?? SyncValue(canonical, version: nextVersion())
            sessions[incoming.id] = sessions[incoming.id]?.merging(redirected) ?? redirected
            var targetLegs: [String: DeviceParticipationLeg] = [:]
            for (k, v) in incoming.legs { targetLegs[k] = v }
            if var existingCanonical = sessions[canonical] {
                for (k, v) in targetLegs {
                    existingCanonical.legs[k] = existingCanonical.legs[k]?.merging(v) ?? v
                }
                existingCanonical.updatedAt = max(existingCanonical.updatedAt, incoming.updatedAt)
                sessions[canonical] = existingCanonical
            }
            return
        }
        sessions[incoming.id] = sessions[incoming.id]?.merging(incoming) ?? incoming
    }

    public mutating func saveNote(sessionID: UUID, noteID: UUID = UUID(), markdown: String, now: Date = Date()) {
        let sid = resolveCanonicalSessionID(for: sessionID)
        let version = nextVersion()
        let existing = notes[sid]
        let parentHash = existing?.sha256
        let resolvedNoteID = existing?.noteID ?? noteID
        notes[sid] = SyncedMeetingNote(
            sessionID: sid,
            noteID: resolvedNoteID,
            markdown: markdown,
            version: version,
            parentSHA256: parentHash,
            updatedAt: now,
            isDeleted: SyncValue(false, version: version)
        )
    }

    public mutating func upsertOutcome(_ outcome: SyncedMeetingOutcome) {
        counter = max(counter, outcome.maximumCounter)
        let sid = resolveCanonicalSessionID(for: outcome.sessionID)
        var adjusted = outcome
        adjusted.sessionID = sid
        outcomes[sid] = outcomes[sid]?.merging(adjusted) ?? adjusted
    }

    public mutating func upsertTask(_ task: SyncedMeetingTask) {
        counter = max(counter, task.maximumCounter)
        let sid = resolveCanonicalSessionID(for: task.sessionID)
        var adjusted = task
        adjusted.sessionID = sid
        tasks[adjusted.id] = tasks[adjusted.id]?.merging(adjusted) ?? adjusted
    }

    public mutating func upsertTaskProfile(_ profile: SyncedTaskProfile) {
        counter = max(counter, profile.maximumCounter)
        taskProfiles[profile.profileID] = taskProfiles[profile.profileID]?.merging(profile) ?? profile
    }

    public var canonicalTaskProfile: SyncedTaskProfile? {
        taskProfiles.values.max { lhs, rhs in
            let lConfigured = !(lhs.assigneeID.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) || !lhs.aliases.value.isEmpty
            let rConfigured = !(rhs.assigneeID.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) || !rhs.aliases.value.isEmpty
            if lConfigured != rConfigured { return !lConfigured && rConfigured }
            if lhs.maximumCounter != rhs.maximumCounter { return lhs.maximumCounter < rhs.maximumCounter }
            let lIsDefault = lhs.profileID.isEmpty || lhs.profileID == "default"
            let rIsDefault = rhs.profileID.isEmpty || rhs.profileID == "default"
            if lIsDefault != rIsDefault { return lIsDefault && !rIsDefault }
            return lhs.profileID > rhs.profileID
        }
    }

    public mutating func upsertContextSettings(_ settings: SyncedMeetingContextSettings) {
        counter = max(counter, settings.maximumCounter)
        contextSettings[settings.scopeKey] = contextSettings[settings.scopeKey]?.merging(settings) ?? settings
    }

    public mutating func upsertTranscriptChunk(_ chunk: SyncedTranscriptChunk) {
        let sid = resolveCanonicalSessionID(for: chunk.sessionID)
        var adjusted = chunk
        adjusted.sessionID = sid
        transcriptChunks[adjusted.id] = transcriptChunks[adjusted.id]?.merging(adjusted) ?? adjusted
    }

    public mutating func markTranscriptUploaded(recordID: String, sessionStartedAt: Date) {
        cloudTranscriptIndex[recordID] = sessionStartedAt
    }

    public mutating func markTranscriptDeleted(recordID: String) {
        cloudTranscriptIndex.removeValue(forKey: recordID)
    }

    /// Deterministically merges overlapping offline sessions that represent the same calendar
    /// occurrence or overlapping call in the same room.
    @discardableResult
    public mutating func coalesceOverlappingSessions(
        respectingTransitionMode: (String?) -> String? = { _ in nil }
    ) -> [(loser: UUID, winner: UUID)] {
        let active = sessions.values.filter { $0.canonicalSessionID == nil && !$0.isDeleted.value }
            .sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
        var redirects: [(loser: UUID, winner: UUID)] = []
        var consumed: Set<UUID> = []

        for i in active.indices {
            let first = active[i]
            if consumed.contains(first.id) { continue }
            for j in active.indices where j > i {
                let second = active[j]
                if consumed.contains(second.id) { continue }
                guard shouldCoalesce(first, second, transitionMode: respectingTransitionMode) else { continue }
                consumed.insert(second.id)
                let version = nextVersion()
                var winner = sessions[first.id] ?? first
                var loser = sessions[second.id] ?? second
                winner = winner.merging(SyncedMeetingSession(
                    id: winner.id,
                    occurrenceKey: winner.occurrenceKey,
                    canonicalSessionID: nil,
                    title: loser.title,
                    hasTitleOverride: loser.hasTitleOverride,
                    invitation: loser.invitation,
                    roomIdentity: loser.roomIdentity,
                    calendarSeriesID: loser.calendarSeriesID,
                    externalSeriesID: loser.externalSeriesID,
                    startedAt: loser.startedAt,
                    endedAt: loser.endedAt,
                    timeZoneID: loser.timeZoneID,
                    state: loser.state,
                    startProvenance: loser.startProvenance,
                    legs: loser.legs,
                    outcomeClaim: loser.outcomeClaim,
                    obsidianReceipt: loser.obsidianReceipt,
                    manualObsidianSaveAt: loser.manualObsidianSaveAt,
                    transcriptDeletedAt: loser.transcriptDeletedAt,
                    isDeleted: loser.isDeleted,
                    createdAt: loser.createdAt,
                    updatedAt: loser.updatedAt
                ))
                loser.canonicalSessionID = SyncValue(winner.id, version: version)
                sessions[winner.id] = winner
                sessions[loser.id] = loser
                reattributeChildren(from: loser.id, to: winner.id, version: version)
                redirects.append((loser.id, winner.id))
            }
        }
        return redirects
    }

    private func resolvedTransitionMode(
        for first: SyncedMeetingSession,
        second: SyncedMeetingSession,
        fallback: (String?) -> String?
    ) -> String? {
        for series in [
            first.calendarSeriesID,
            second.calendarSeriesID,
            first.externalSeriesID,
            second.externalSeriesID
        ].compactMap({ $0 }) where !series.isEmpty {
            if let mode = contextSettings["series:" + series]?.sameRoomTransition?.value {
                return mode
            }
        }
        if !first.roomIdentity.isEmpty,
           let mode = contextSettings["room:" + first.roomIdentity]?.sameRoomTransition?.value {
            return mode
        }
        if let inv = first.invitation.value?.absoluteString,
           let mode = contextSettings["room:" + inv]?.sameRoomTransition?.value {
            return mode
        }
        if let fallbackMode = fallback(first.roomIdentity) {
            return fallbackMode
        }
        return contextSettings["all"]?.sameRoomTransition?.value
    }

    private func shouldCoalesce(
        _ first: SyncedMeetingSession,
        _ second: SyncedMeetingSession,
        transitionMode: (String?) -> String?
    ) -> Bool {
        if !first.legs.isEmpty,
           !second.legs.isEmpty,
           first.legs.count == 1,
           Set(first.legs.keys) == Set(second.legs.keys) {
            return false
        }
        if first.occurrenceKey.hasPrefix("cal:"), first.occurrenceKey == second.occurrenceKey {
            if resolvedTransitionMode(for: first, second: second, fallback: transitionMode) == "separateSessions" {
                if let endFirst = first.endedAt.value, endFirst <= second.startedAt { return false }
                if let endSecond = second.endedAt.value, endSecond <= first.startedAt { return false }
            }
            return true
        }
        guard !first.roomIdentity.isEmpty, first.roomIdentity == second.roomIdentity else { return false }
        let delta = abs(first.startedAt.timeIntervalSince(second.startedAt))
        guard delta <= 900 else { return false }
        let endFirst = first.endedAt.value ?? Date.distantFuture
        let endSecond = second.endedAt.value ?? Date.distantFuture
        guard endFirst > second.startedAt && endSecond > first.startedAt else { return false }
        if resolvedTransitionMode(for: first, second: second, fallback: transitionMode) == "separateSessions" {
            if let fEnd = first.endedAt.value, fEnd <= second.startedAt { return false }
            if let sEnd = second.endedAt.value, sEnd <= first.startedAt { return false }
        }
        return true
    }

    private mutating func reattributeChildren(from loserID: UUID, to winnerID: UUID, version: SyncVersion) {
        if var loserNote = notes.removeValue(forKey: loserID) {
            loserNote.sessionID = winnerID
            if let winnerNote = notes[winnerID] {
                let merged = NoteThreeWayMerger.merge(
                    base: noteBases[winnerID]?.markdown,
                    local: winnerNote.markdown,
                    localVersion: winnerNote.version,
                    remote: loserNote.markdown,
                    remoteVersion: loserNote.version
                )
                notes[winnerID] = SyncedMeetingNote(
                    sessionID: winnerID,
                    noteID: winnerNote.noteID,
                    markdown: merged.markdown,
                    version: version,
                    parentSHA256: winnerNote.sha256,
                    updatedAt: max(winnerNote.updatedAt, loserNote.updatedAt),
                    isDeleted: winnerNote.isDeleted
                )
            } else {
                notes[winnerID] = loserNote
            }
        }

        if var loserOutcome = outcomes.removeValue(forKey: loserID) {
            loserOutcome.sessionID = winnerID
            if let winnerOutcome = outcomes[winnerID] {
                outcomes[winnerID] = winnerOutcome.merging(loserOutcome)
            } else {
                outcomes[winnerID] = loserOutcome
            }
        }

        for (taskID, var task) in tasks where task.sessionID == loserID {
            task.sessionID = winnerID
            if let canonicalOutcome = outcomes[winnerID]?.outcomeID {
                task.outcomeID = canonicalOutcome
            }
            tasks[taskID] = task
        }

        for (chunkID, var chunk) in transcriptChunks where chunk.sessionID == loserID {
            transcriptChunks.removeValue(forKey: chunkID)
            chunk.sessionID = winnerID
            transcriptChunks[chunk.id] = transcriptChunks[chunk.id]?.merging(chunk) ?? chunk
        }
    }

    public struct LibraryMergeOutcome: Equatable, Sendable {
        public var changedSessions: Set<UUID> = []
        public var noteMergeResults: [UUID: NoteThreeWayMerger.MergeResult] = [:]
        public var changedTaskIDs: Set<UUID> = []
        public var changedProfileIDs: Set<String> = []
        public var changedSettingsKeys: Set<String> = []
    }

    @discardableResult
    public mutating func mergeLibraryRecords(_ records: [MeetingLibrarySyncRecord]) -> LibraryMergeOutcome {
        var report = LibraryMergeOutcome()
        for record in records {
            counter = max(counter, record.maximumSyncCounter)
            switch record {
            case .session(let incoming):
                let sid = incoming.id
                let merged = sessions[sid]?.merging(incoming) ?? incoming
                if sessions[sid] != merged {
                    sessions[sid] = merged
                    report.changedSessions.insert(sid)
                }

            case .note(let incoming):
                let sid = resolveCanonicalSessionID(for: incoming.sessionID)
                var normalized = incoming
                normalized.sessionID = sid
                guard let existing = notes[sid] else {
                    notes[sid] = normalized
                    noteBases[sid] = NoteBaseSnapshot(sessionID: sid, markdown: normalized.markdown)
                    report.changedSessions.insert(sid)
                    report.noteMergeResults[sid] = .init(markdown: normalized.markdown, hadConflict: false)
                    continue
                }
                if existing.version == normalized.version && existing.markdown == normalized.markdown {
                    noteBases[sid] = NoteBaseSnapshot(sessionID: sid, markdown: normalized.markdown)
                    continue
                }
                if normalized.parentSHA256 == existing.sha256 {
                    notes[sid] = normalized
                    noteBases[sid] = NoteBaseSnapshot(sessionID: sid, markdown: normalized.markdown)
                    report.changedSessions.insert(sid)
                    report.noteMergeResults[sid] = .init(markdown: normalized.markdown, hadConflict: false)
                    continue
                }
                if existing.parentSHA256 == normalized.sha256 {
                    noteBases[sid] = NoteBaseSnapshot(sessionID: sid, markdown: normalized.markdown)
                    continue
                }
                let base = noteBases[sid]?.markdown
                let merge = NoteThreeWayMerger.merge(
                    base: base,
                    local: existing.markdown,
                    localVersion: existing.version,
                    remote: normalized.markdown,
                    remoteVersion: normalized.version
                )
                if merge.markdown == normalized.markdown {
                    notes[sid] = normalized
                    noteBases[sid] = NoteBaseSnapshot(sessionID: sid, markdown: normalized.markdown)
                    report.changedSessions.insert(sid)
                } else if merge.markdown == existing.markdown {
                    noteBases[sid] = NoteBaseSnapshot(sessionID: sid, markdown: normalized.markdown)
                } else {
                    let version = nextVersion()
                    notes[sid] = SyncedMeetingNote(
                        sessionID: sid,
                        noteID: existing.noteID,
                        markdown: merge.markdown,
                        version: version,
                        parentSHA256: normalized.sha256,
                        updatedAt: max(existing.updatedAt, normalized.updatedAt),
                        isDeleted: existing.isDeleted.merging(normalized.isDeleted)
                    )
                    noteBases[sid] = NoteBaseSnapshot(sessionID: sid, markdown: normalized.markdown)
                    report.changedSessions.insert(sid)
                }
                report.noteMergeResults[sid] = merge

            case .outcome(let incoming):
                let sid = resolveCanonicalSessionID(for: incoming.sessionID)
                var normalized = incoming
                normalized.sessionID = sid
                let merged = outcomes[sid]?.merging(normalized) ?? normalized
                if outcomes[sid] != merged {
                    outcomes[sid] = merged
                    report.changedSessions.insert(sid)
                }

            case .task(let incoming):
                let sid = resolveCanonicalSessionID(for: incoming.sessionID)
                var normalized = incoming
                normalized.sessionID = sid
                let merged = tasks[normalized.id]?.merging(normalized) ?? normalized
                if tasks[normalized.id] != merged {
                    tasks[normalized.id] = merged
                    report.changedTaskIDs.insert(normalized.id)
                    report.changedSessions.insert(sid)
                }

            case .taskLink(let incoming):
                let existing = taskLinks[incoming.syncID]
                if existing.map({ incoming.updatedAt > $0.updatedAt }) ?? true {
                    taskLinks[incoming.syncID] = incoming
                    report.changedSessions.insert(resolveCanonicalSessionID(for: incoming.sessionID))
                }

            case .taskProfile(let incoming):
                let merged = taskProfiles[incoming.profileID]?.merging(incoming) ?? incoming
                if taskProfiles[incoming.profileID] != merged {
                    taskProfiles[incoming.profileID] = merged
                    report.changedProfileIDs.insert(incoming.profileID)
                }

            case .contextSettings(let incoming):
                let merged = contextSettings[incoming.scopeKey]?.merging(incoming) ?? incoming
                if contextSettings[incoming.scopeKey] != merged {
                    contextSettings[incoming.scopeKey] = merged
                    report.changedSettingsKeys.insert(incoming.scopeKey)
                }
            }
        }
        return report
    }

    @discardableResult
    public mutating func mergeTranscriptRecords(_ records: [MeetingTranscriptSyncRecord]) -> Set<UUID> {
        var changed: Set<UUID> = []
        for record in records {
            switch record {
            case .chunk(let incoming):
                let sid = resolveCanonicalSessionID(for: incoming.sessionID)
                var normalized = incoming
                normalized.sessionID = sid
                cloudTranscriptIndex[record.syncRecordID] = normalized.sessionStartedAt
                let merged = transcriptChunks[normalized.id]?.merging(normalized) ?? normalized
                if transcriptChunks[normalized.id] != merged {
                    transcriptChunks[normalized.id] = merged
                    changed.insert(sid)
                }
            }
        }
        return changed
    }

    public func mergedTranscript(for sessionID: UUID) -> [SyncedTranscriptEvent] {
        let sid = resolveCanonicalSessionID(for: sessionID)
        let chunks = transcriptChunks.values.filter { resolveCanonicalSessionID(for: $0.sessionID) == sid }
        return TranscriptMergeEngine.merge(chunks: Array(chunks))
    }

    public var allLibraryRecords: [MeetingLibrarySyncRecord] {
        var records: [MeetingLibrarySyncRecord] = []
        records.append(contentsOf: sessions.values.map { .session($0) })
        records.append(contentsOf: notes.values.map { .note($0) })
        records.append(contentsOf: outcomes.values.map { .outcome($0) })
        records.append(contentsOf: tasks.values.map { .task($0) })
        records.append(contentsOf: taskLinks.values.map { .taskLink($0) })
        records.append(contentsOf: taskProfiles.values.map { .taskProfile($0) })
        records.append(contentsOf: contextSettings.values.map { .contextSettings($0) })
        return records
    }

    public func pendingLibraryRecords(
        acknowledged: [String: MeetingLibrarySyncRecord]
    ) -> [MeetingLibrarySyncRecord] {
        allLibraryRecords.filter { acknowledged[$0.syncRecordID] != $0 }
    }

    /// Returns transcript records eligible for CloudKit upload under the configured retention window.
    public func transcriptRecordsForCloud(
        retention: TranscriptSyncRetention,
        now: Date = Date()
    ) -> [MeetingTranscriptSyncRecord] {
        guard let window = retention.timeInterval else { return [] }
        let cutoff = now.addingTimeInterval(-window)
        return transcriptChunks.values.filter { chunk in
            !chunk.isDeleted &&
                chunk.sessionStartedAt >= cutoff &&
                sessions[resolveCanonicalSessionID(for: chunk.sessionID)]?.isDeleted.value != true
        }.map { .chunk($0) }
    }

    /// Returns CloudKit transcript record IDs that have aged past the configured retention window
    /// and can be deleted from iCloud without affecting local device storage or archive backups.
    public func expiredCloudTranscriptRecordIDs(
        retention: TranscriptSyncRetention,
        now: Date = Date()
    ) -> [String] {
        guard let window = retention.timeInterval else {
            return Array(cloudTranscriptIndex.keys)
        }
        let cutoff = now.addingTimeInterval(-window)
        return cloudTranscriptIndex.compactMap { recordID, startedAt in
            startedAt < cutoff ? recordID : nil
        }
    }
}
