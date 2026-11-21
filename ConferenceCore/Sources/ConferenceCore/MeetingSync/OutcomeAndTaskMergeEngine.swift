import Foundation

public enum OutcomeCoordinatorPolicy {
    public static let activeLegStaleSeconds: TimeInterval = 120
    public static let macPreferenceGraceSeconds: TimeInterval = 30

    public static func shouldWaitForActiveLegs(session: SyncedMeetingSession, now: Date = Date()) -> Bool {
        session.legs.values.contains { leg in
            leg.leftAt == nil && now.timeIntervalSince(leg.updatedAt) < activeLegStaleSeconds
        }
    }

    /// Returns a wait deadline if iOS should wait for an online Mac leg (or an active
    /// remote claim) before generating an outcome locally; returns nil if local generation
    /// may proceed or is already satisfied by a ready claim.
    public static func deferToMacDeadline(
        session: SyncedMeetingSession,
        localDeviceID: String,
        localIsMac: Bool,
        isOnline: Bool,
        now: Date = Date()
    ) -> Date? {
        if let claim = session.outcomeClaim?.value {
            if claim.state == "ready" { return nil }
            if claim.ownerDeviceID != localDeviceID && claim.state == "pending" && claim.leaseExpiresAt > now {
                return claim.leaseExpiresAt
            }
        }
        guard !localIsMac, isOnline else { return nil }
        var latestDeadline: Date?
        for leg in session.legs.values where leg.deviceID != localDeviceID && leg.deviceKind == .mac && leg.hasOutcomeWriter {
            let reference = leg.leftAt ?? leg.updatedAt
            let deadline: Date
            if leg.leftAt == nil && now.timeIntervalSince(leg.updatedAt) < activeLegStaleSeconds {
                deadline = now.addingTimeInterval(macPreferenceGraceSeconds)
            } else {
                deadline = reference.addingTimeInterval(macPreferenceGraceSeconds)
            }
            if deadline > now {
                latestDeadline = max(latestDeadline ?? deadline, deadline)
            }
        }
        return latestDeadline
    }

    public static func canClaimGeneration(
        session: SyncedMeetingSession,
        localDeviceID: String,
        now: Date = Date()
    ) -> Bool {
        guard let claim = session.outcomeClaim?.value else { return true }
        if claim.state == "ready" { return false }
        if claim.ownerDeviceID == localDeviceID { return true }
        return claim.leaseExpiresAt <= now
    }
}

public enum OutcomeAndTaskMergeEngine {
    public static func mergeOutcomes(
        local: SyncedMeetingOutcome,
        remote: SyncedMeetingOutcome
    ) -> SyncedMeetingOutcome {
        guard local.sessionID == remote.sessionID else { return local }

        let preferRemoteGenerated = generatedPrecedes(local, remote)
        let primaryGen = preferRemoteGenerated ? remote : local
        let secondaryGen = preferRemoteGenerated ? local : remote

        var result = primaryGen

        // State resolution: ready beats non-ready unless explicitly tombstoned later; otherwise logical version.
        if local.state.value == "ready" && remote.state.value != "ready" {
            result.state = local.state
        } else if remote.state.value == "ready" && local.state.value != "ready" {
            result.state = remote.state
        } else {
            result.state = local.state.merging(remote.state)
        }

        // Summary: human-edited beats unedited generated.
        if local.summaryEdited != remote.summaryEdited {
            let editedSide = local.summaryEdited ? local : remote
            result.summary = editedSide.summary
            result.summaryEdited = true
        } else if local.summaryEdited && remote.summaryEdited {
            result.summary = local.summary.merging(remote.summary)
            result.summaryEdited = true
        } else {
            result.summary = primaryGen.summary
            result.summaryEdited = false
        }

        // Decisions: human-edited beats unedited; dual unedited outcomes union deduplicated items.
        if local.decisionsEdited != remote.decisionsEdited {
            let editedSide = local.decisionsEdited ? local : remote
            result.decisions = editedSide.decisions
            result.decisionsEdited = true
        } else if local.decisionsEdited && remote.decisionsEdited {
            result.decisions = local.decisions.merging(remote.decisions)
            result.decisionsEdited = true
        } else {
            result.decisions = SyncValue(
                unionStrings(primaryGen.decisions.value, secondaryGen.decisions.value),
                version: max(primaryGen.decisions.version, secondaryGen.decisions.version)
            )
            result.decisionsEdited = false
        }

        // Open questions: same rule as decisions.
        if local.questionsEdited != remote.questionsEdited {
            let editedSide = local.questionsEdited ? local : remote
            result.openQuestions = editedSide.openQuestions
            result.questionsEdited = true
        } else if local.questionsEdited && remote.questionsEdited {
            result.openQuestions = local.openQuestions.merging(remote.openQuestions)
            result.questionsEdited = true
        } else {
            result.openQuestions = SyncValue(
                unionStrings(primaryGen.openQuestions.value, secondaryGen.openQuestions.value),
                version: max(primaryGen.openQuestions.version, secondaryGen.openQuestions.version)
            )
            result.questionsEdited = false
        }

        result.coverageSeconds = max(local.coverageSeconds, remote.coverageSeconds)
        result.writerTier = max(local.writerTier, remote.writerTier)
        result.reviewCandidates = local.reviewCandidates.merging(remote.reviewCandidates)
        result.isDeleted = local.isDeleted.merging(remote.isDeleted)
        result.updatedAt = max(local.updatedAt, remote.updatedAt)

        // Retain runner-up generated summary in bounded version history (max 2 snapshots).
        var mergedVersions = local.versions + remote.versions
        if !secondaryGen.summary.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           secondaryGen.summary.value != result.summary.value {
            mergedVersions.append(
                SyncedOutcomeVersionSnapshot(
                    revision: Int(max(1, secondaryGen.summary.version.counter)),
                    summary: secondaryGen.summary.value,
                    decisions: secondaryGen.decisions.value,
                    openQuestions: secondaryGen.openQuestions.value,
                    savedAt: secondaryGen.updatedAt,
                    deviceID: secondaryGen.summary.version.device
                )
            )
        }
        var seenVersions: Set<String> = []
        result.versions = mergedVersions
            .sorted { ($0.savedAt, $0.revision, $0.deviceID) > ($1.savedAt, $1.revision, $1.deviceID) }
            .filter {
                $0.summary != result.summary.value &&
                    seenVersions.insert("\($0.revision)|\($0.deviceID)|\($0.summary)").inserted
            }
            .prefix(2)
            .map { $0 }

        return result
    }

    public static func reconcileDualGeneratedTasks(
        primary: [SyncedMeetingTask],
        secondary: [SyncedMeetingTask],
        sessionID: UUID,
        version: SyncVersion
    ) -> (merged: [SyncedMeetingTask], links: [SyncedTaskLink], reviewCandidates: [SyncedTaskSnapshot]) {
        var merged = primary
        var links: [SyncedTaskLink] = []
        var reviewCandidates: [SyncedTaskSnapshot] = []

        for candidate in secondary where !candidate.isDeleted.value {
            if let index = merged.firstIndex(where: { !$0.isDeleted.value && isEquivalentTask($0, candidate) }) {
                var target = merged[index]
                if candidate.done.version > target.done.version {
                    target.done = candidate.done
                    target.completedAt = candidate.completedAt
                }
                if candidate.dueDay.version > target.dueDay.version {
                    target.dueDay = candidate.dueDay
                }
                if candidate.dueAt.version > target.dueAt.version {
                    target.dueAt = candidate.dueAt
                }
                if candidate.reminderAt.version > target.reminderAt.version {
                    target.reminderAt = candidate.reminderAt
                }
                switch (target.extended, candidate.extended) {
                case (.some(let a), .some(let b)):
                    let preferB = a.version < b.version
                    target.extended = SyncValue(
                        a.value.merging(b.value, preferOtherScalars: preferB),
                        version: preferB ? b.version : a.version
                    )
                case (.none, .some(let b)):
                    target.extended = b
                default:
                    break
                }
                merged[index] = target
                links.append(
                    SyncedTaskLink(
                        sessionID: sessionID,
                        historicalTaskID: candidate.id,
                        canonicalTaskID: target.id,
                        updatedAt: max(target.updatedAt, candidate.updatedAt)
                    )
                )
            } else {
                reviewCandidates.append(
                    SyncedTaskSnapshot(
                        id: candidate.id,
                        text: candidate.text.value,
                        owner: candidate.owner.value,
                        assigneeID: candidate.assigneeID.value,
                        dueDay: candidate.dueDay.value,
                        dueAt: candidate.dueAt.value,
                        reminderAt: candidate.reminderAt.value,
                        done: candidate.done.value,
                        completedAt: candidate.completedAt.value,
                        extended: candidate.extended?.value ?? .init()
                    )
                )
            }
        }
        return (merged, links, reviewCandidates)
    }

    public static func isEquivalentTask(_ lhs: SyncedMeetingTask, _ rhs: SyncedMeetingTask) -> Bool {
        if lhs.id == rhs.id { return true }
        let ownerA = normalizedOwner(lhs.owner.value)
        let ownerB = normalizedOwner(rhs.owner.value)
        if !ownerA.isEmpty && !ownerB.isEmpty && ownerA != ownerB {
            return false
        }
        return diceSimilarity(lhs.text.value, rhs.text.value) >= 0.70
    }

    public static func diceSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Set(tokens(lhs))
        let b = Set(tokens(rhs))
        guard !a.isEmpty && !b.isEmpty else { return 0 }
        let overlap = a.intersection(b).count
        return Double(2 * overlap) / Double(a.count + b.count)
    }

    private static func generatedPrecedes(_ lhs: SyncedMeetingOutcome, _ rhs: SyncedMeetingOutcome) -> Bool {
        let lhsKey = (lhs.state.value == "ready" ? 1 : 0, lhs.coverageSeconds, lhs.writerTier)
        let rhsKey = (rhs.state.value == "ready" ? 1 : 0, rhs.coverageSeconds, rhs.writerTier)
        if lhsKey != rhsKey {
            return lhsKey < rhsKey
        }
        return lhs.summary.version < rhs.summary.version
    }

    private static func unionStrings(_ primary: [String], _ secondary: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for item in primary + secondary {
            let clean = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            if seen.insert(clean.workspaceFolded).inserted {
                out.append(clean)
            }
        }
        return Array(out.prefix(20))
    }

    private static func normalizedOwner(_ owner: String) -> String {
        owner.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .workspaceFolded
    }

    private static func tokens(_ text: String) -> [String] {
        text.workspaceFolded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
