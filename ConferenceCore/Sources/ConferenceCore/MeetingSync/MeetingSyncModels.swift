import CryptoKit
import Foundation

public enum TranscriptSyncRetention: String, Codable, CaseIterable, Sendable {
    case off
    case days7
    case days14
    case days30
    case days90

    public var days: Int? {
        switch self {
        case .off: return nil
        case .days7: return 7
        case .days14: return 14
        case .days30: return 30
        case .days90: return 90
        }
    }

    public var timeInterval: TimeInterval? {
        days.map { TimeInterval($0) * 86_400 }
    }

    public var titleKey: String {
        switch self {
        case .off: return "Off"
        case .days7: return "7 days"
        case .days14: return "14 days"
        case .days30: return "30 days"
        case .days90: return "90 days"
        }
    }

    public var title: String { L(titleKey) }
}

public protocol SyncZoneRecord: Codable, Equatable, Sendable {
    var syncRecordID: String { get }
    var maximumSyncCounter: Int64 { get }
    func merging(_ other: Self) -> Self
}

public enum SyncedDeviceKind: String, Codable, Equatable, Sendable {
    case mac
    case ios
}

/// One local join and leave, including repeated participation on the same device.
public struct MeetingParticipationInterval: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let joinedAt: Date
    public var leftAt: Date?

    public init(id: UUID = UUID(), joinedAt: Date, leftAt: Date? = nil) {
        self.id = id
        self.joinedAt = joinedAt
        self.leftAt = leftAt
    }
}

public struct MeetingCalendarAssociation: Codable, Equatable, Sendable {
    public static let rejoinGrace: TimeInterval = 30 * 60
    public let occurrenceID: String
    public let roomKey: String
    public let title: String
    public let start: Date
    public let end: Date

    public init(_ meeting: CalendarMeeting, room: MeetingRoomIdentity) {
        let occurrence = meeting.originalOccurrenceStart ?? meeting.start
        self.occurrenceID = (meeting.externalSeriesID ?? meeting.seriesID) + "|" +
            String(Int64(occurrence.timeIntervalSince1970.rounded(.towardZero)))
        self.roomKey = room.workspaceKey
        self.title = meeting.title
        self.start = meeting.start
        self.end = meeting.end
    }

    public func matches(_ other: Self) -> Bool {
        occurrenceID == other.occurrenceID && roomKey == other.roomKey
    }

    public func allowsRejoin(at date: Date, before nextOccurrence: Date? = nil) -> Bool {
        date >= start && date <= end.addingTimeInterval(Self.rejoinGrace) &&
            (nextOccurrence.map { date < $0 } ?? true)
    }
}

public struct DeviceParticipationLeg: Codable, Equatable, Sendable {
    public var deviceID: String
    public var deviceKind: SyncedDeviceKind
    public var joinedAt: Date
    public var leftAt: Date?
    public var hasOutcomeWriter: Bool
    public var transcriptChunkCount: Int
    public var updatedAt: Date
    public var intervals: [UUID: MeetingParticipationInterval]?

    public init(
        deviceID: String,
        deviceKind: SyncedDeviceKind,
        joinedAt: Date,
        leftAt: Date? = nil,
        hasOutcomeWriter: Bool = false,
        transcriptChunkCount: Int = 0,
        updatedAt: Date = Date(),
        intervals: [UUID: MeetingParticipationInterval]? = nil
    ) {
        self.deviceID = deviceID
        self.deviceKind = deviceKind
        self.joinedAt = joinedAt
        self.leftAt = leftAt
        self.hasOutcomeWriter = hasOutcomeWriter
        self.transcriptChunkCount = transcriptChunkCount
        self.updatedAt = updatedAt
        self.intervals = intervals
    }

    public mutating func beginInterval(id: UUID = UUID(), at date: Date) {
        if intervals?[id] != nil { return }
        var history = intervals ?? [:]
        history[id] = MeetingParticipationInterval(id: id, joinedAt: date)
        intervals = history
    }

    public mutating func endInterval(id: UUID? = nil, at date: Date) {
        guard var history = intervals,
              let target = id ?? history.values.filter({ $0.leftAt == nil }).max(by: { $0.joinedAt < $1.joinedAt })?.id,
              let interval = history[target], interval.leftAt == nil else { return }
        history[target]?.leftAt = max(interval.joinedAt, date)
        intervals = history
    }

    public func merging(_ other: Self) -> Self {
        let newer = (updatedAt, leftAt != nil ? 1 : 0, transcriptChunkCount) >=
            (other.updatedAt, other.leftAt != nil ? 1 : 0, other.transcriptChunkCount)
        var winner = newer ? self : other
        winner.joinedAt = min(joinedAt, other.joinedAt)
        winner.transcriptChunkCount = max(transcriptChunkCount, other.transcriptChunkCount)
        winner.hasOutcomeWriter = newer ? hasOutcomeWriter : other.hasOutcomeWriter
        if winner.leftAt == nil, let fallbackLeft = (newer ? other.leftAt : leftAt),
           (newer ? other.updatedAt : updatedAt) >= winner.updatedAt {
            winner.leftAt = fallbackLeft
        }
        if intervals != nil || other.intervals != nil {
            winner.intervals = (intervals ?? [:]).merging(other.intervals ?? [:]) { old, incoming in
                MeetingParticipationInterval(id: old.id, joinedAt: min(old.joinedAt, incoming.joinedAt),
                    leftAt: [old.leftAt, incoming.leftAt].compactMap { $0 }.max())
            }
        }
        winner.updatedAt = max(updatedAt, other.updatedAt)
        return winner
    }
}

public struct OutcomeGenerationClaim: Codable, Equatable, Sendable {
    public var ownerDeviceID: String
    public var deviceKind: SyncedDeviceKind
    public var claimedAt: Date
    public var leaseExpiresAt: Date
    public var state: String

    public init(
        ownerDeviceID: String,
        deviceKind: SyncedDeviceKind,
        claimedAt: Date,
        leaseExpiresAt: Date,
        state: String
    ) {
        self.ownerDeviceID = ownerDeviceID
        self.deviceKind = deviceKind
        self.claimedAt = claimedAt
        self.leaseExpiresAt = leaseExpiresAt
        self.state = state
    }
}

public struct ObsidianSyncReceipt: Codable, Equatable, Sendable {
    public var exporterDeviceID: String
    public var state: String
    public var relativePath: String?
    public var exportedRevision: Int
    public var updatedAt: Date
    public var errorMessage: String?
    public var transcriptIncluded: Bool?

    public init(
        exporterDeviceID: String,
        state: String,
        relativePath: String? = nil,
        exportedRevision: Int = 0,
        updatedAt: Date = Date(),
        errorMessage: String? = nil,
        transcriptIncluded: Bool? = nil
    ) {
        self.exporterDeviceID = exporterDeviceID
        self.state = state
        self.relativePath = relativePath
        self.exportedRevision = exportedRevision
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
        self.transcriptIncluded = transcriptIncluded
    }
}

public struct SyncedMeetingSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var occurrenceKey: String
    public var calendarAssociation: SyncValue<MeetingCalendarAssociation?>?
    /// User-visible grouping. Keep the original child records and their content independently addressable.
    public var historyGroupParent: SyncValue<UUID?>?
    public var canonicalSessionID: SyncValue<UUID>?
    public var title: SyncValue<String>
    public var hasTitleOverride: SyncValue<Bool>
    public var invitation: SyncValue<URL?>
    public var roomIdentity: String
    public var calendarSeriesID: String?
    public var externalSeriesID: String?
    public var startedAt: Date
    public var endedAt: SyncValue<Date?>
    public var timeZoneID: String
    public var state: SyncValue<String>
    public var startProvenance: String?
    public var legs: [String: DeviceParticipationLeg]
    public var outcomeClaim: SyncValue<OutcomeGenerationClaim?>?
    public var obsidianReceipt: SyncValue<ObsidianSyncReceipt?>?
    public var manualObsidianSaveAt: SyncValue<Date?>?
    public var transcriptDeletedAt: SyncValue<Date?>?
    public var isDeleted: SyncValue<Bool>
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        occurrenceKey: String,
        canonicalSessionID: SyncValue<UUID>? = nil,
        calendarAssociation: SyncValue<MeetingCalendarAssociation?>? = nil,
        historyGroupParent: SyncValue<UUID?>? = nil,
        title: SyncValue<String>,
        hasTitleOverride: SyncValue<Bool>,
        invitation: SyncValue<URL?>,
        roomIdentity: String,
        calendarSeriesID: String? = nil,
        externalSeriesID: String? = nil,
        startedAt: Date,
        endedAt: SyncValue<Date?>,
        timeZoneID: String,
        state: SyncValue<String>,
        startProvenance: String? = "recorded",
        legs: [String: DeviceParticipationLeg] = [:],
        outcomeClaim: SyncValue<OutcomeGenerationClaim?>? = nil,
        obsidianReceipt: SyncValue<ObsidianSyncReceipt?>? = nil,
        manualObsidianSaveAt: SyncValue<Date?>? = nil,
        transcriptDeletedAt: SyncValue<Date?>? = nil,
        isDeleted: SyncValue<Bool>,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.occurrenceKey = occurrenceKey
        self.calendarAssociation = calendarAssociation
        self.historyGroupParent = historyGroupParent
        self.canonicalSessionID = canonicalSessionID
        self.title = title
        self.hasTitleOverride = hasTitleOverride
        self.invitation = invitation
        self.roomIdentity = roomIdentity
        self.calendarSeriesID = calendarSeriesID
        self.externalSeriesID = externalSeriesID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.timeZoneID = timeZoneID
        self.state = state
        self.startProvenance = startProvenance
        self.legs = legs
        self.outcomeClaim = outcomeClaim
        self.obsidianReceipt = obsidianReceipt
        self.manualObsidianSaveAt = manualObsidianSaveAt
        self.transcriptDeletedAt = transcriptDeletedAt
        self.isDeleted = isDeleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var maximumCounter: Int64 {
        var versions: [SyncVersion] = [
            title.version,
            hasTitleOverride.version,
            invitation.version,
            endedAt.version,
            state.version,
            isDeleted.version
        ]
        if let calendarAssociation { versions.append(calendarAssociation.version) }
        if let historyGroupParent { versions.append(historyGroupParent.version) }
        if let canonicalSessionID { versions.append(canonicalSessionID.version) }
        if let outcomeClaim { versions.append(outcomeClaim.version) }
        if let obsidianReceipt { versions.append(obsidianReceipt.version) }
        if let manualObsidianSaveAt { versions.append(manualObsidianSaveAt.version) }
        if let transcriptDeletedAt { versions.append(transcriptDeletedAt.version) }
        return versions.map(\.counter).max() ?? 0
    }

    public func merging(_ other: Self) -> Self {
        guard id == other.id else { return self }
        var result = self
        result.occurrenceKey = Self.pickNonEmpty(occurrenceKey, other.occurrenceKey)
        result.canonicalSessionID = Self.mergeOptional(canonicalSessionID, other.canonicalSessionID)
        result.calendarAssociation = Self.mergeOptional(calendarAssociation, other.calendarAssociation)
        result.historyGroupParent = Self.mergeOptional(historyGroupParent, other.historyGroupParent)
        if hasTitleOverride.value != other.hasTitleOverride.value {
            result.title = hasTitleOverride.value ? title : other.title
        } else {
            result.title = title.merging(other.title)
        }
        result.hasTitleOverride = hasTitleOverride.merging(other.hasTitleOverride)
        result.invitation = invitation.merging(other.invitation)
        result.roomIdentity = Self.pickNonEmpty(roomIdentity, other.roomIdentity)
        result.calendarSeriesID = Self.pickOptional(calendarSeriesID, other.calendarSeriesID)
        result.externalSeriesID = Self.pickOptional(externalSeriesID, other.externalSeriesID)
        result.startedAt = Self.earliestRecordedStart(startedAt, other.startedAt)
        result.endedAt = endedAt.merging(other.endedAt)
        result.timeZoneID = title.version < other.title.version ? other.timeZoneID : timeZoneID
        result.state = state.merging(other.state)
        result.startProvenance = Self.pickProvenance(startProvenance, other.startProvenance)

        var mergedLegs = legs
        for (device, leg) in other.legs {
            mergedLegs[device] = mergedLegs[device]?.merging(leg) ?? leg
        }
        result.legs = mergedLegs

        result.outcomeClaim = Self.mergeOptional(outcomeClaim, other.outcomeClaim)
        result.obsidianReceipt = Self.mergeOptional(obsidianReceipt, other.obsidianReceipt)
        result.manualObsidianSaveAt = Self.mergeOptional(manualObsidianSaveAt, other.manualObsidianSaveAt)
        result.transcriptDeletedAt = Self.mergeOptional(transcriptDeletedAt, other.transcriptDeletedAt)
        result.isDeleted = isDeleted.merging(other.isDeleted)
        result.createdAt = min(createdAt, other.createdAt)
        result.updatedAt = max(updatedAt, other.updatedAt)
        return result
    }

    private static func mergeOptional<V>(_ lhs: SyncValue<V>?, _ rhs: SyncValue<V>?) -> SyncValue<V>? {
        switch (lhs, rhs) {
        case (.some(let a), .some(let b)): return a.merging(b)
        case (.some(let a), .none): return a
        case (.none, .some(let b)): return b
        case (.none, .none): return nil
        }
    }

    private static func pickNonEmpty(_ lhs: String, _ rhs: String) -> String {
        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }
        return lhs < rhs ? lhs : rhs
    }

    private static func pickOptional(_ lhs: String?, _ rhs: String?) -> String? {
        switch (lhs, rhs) {
        case (.some(let a), .some(let b)) where !a.isEmpty && !b.isEmpty:
            return a < b ? a : b
        case (.some(let a), _) where !a.isEmpty:
            return a
        default:
            return rhs
        }
    }

    private static func earliestRecordedStart(_ lhs: Date, _ rhs: Date) -> Date {
        if lhs == .distantPast { return rhs }
        if rhs == .distantPast { return lhs }
        return min(lhs, rhs)
    }

    private static func pickProvenance(_ lhs: String?, _ rhs: String?) -> String? {
        func rank(_ value: String?) -> Int {
            switch value {
            case "recorded": return 3
            case "outcomeOnly": return 2
            case "unknown": return 1
            default: return 0
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }
}

public struct SyncedMeetingNote: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var noteID: UUID
    public var markdown: String
    public var version: SyncVersion
    public var parentSHA256: String?
    public var updatedAt: Date
    public var isDeleted: SyncValue<Bool>

    public init(
        sessionID: UUID,
        noteID: UUID,
        markdown: String,
        version: SyncVersion,
        parentSHA256: String? = nil,
        updatedAt: Date = Date(),
        isDeleted: SyncValue<Bool>
    ) {
        self.sessionID = sessionID
        self.noteID = noteID
        self.markdown = markdown
        self.version = version
        self.parentSHA256 = parentSHA256
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }

    public var sha256: String { Self.sha256(markdown) }

    public var maximumCounter: Int64 {
        max(version.counter, isDeleted.version.counter)
    }

    public static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct NoteBaseSnapshot: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var sha256: String
    public var markdown: String

    public init(sessionID: UUID, sha256: String, markdown: String) {
        self.sessionID = sessionID
        self.sha256 = sha256
        self.markdown = markdown
    }

    public init(sessionID: UUID, markdown: String) {
        self.sessionID = sessionID
        self.sha256 = SyncedMeetingNote.sha256(markdown)
        self.markdown = markdown
    }
}

public struct SyncedOutcomeVersionSnapshot: Codable, Equatable, Sendable {
    public var revision: Int
    public var summary: String
    public var decisions: [String]
    public var openQuestions: [String]
    public var savedAt: Date
    public var deviceID: String

    public init(
        revision: Int,
        summary: String,
        decisions: [String],
        openQuestions: [String],
        savedAt: Date,
        deviceID: String
    ) {
        self.revision = revision
        self.summary = summary
        self.decisions = decisions
        self.openQuestions = openQuestions
        self.savedAt = savedAt
        self.deviceID = deviceID
    }
}

public struct SyncedTaskSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var owner: String
    public var assigneeID: String?
    public var dueDay: String?
    public var dueAt: Date?
    public var reminderAt: Date?
    public var done: Bool
    public var completedAt: Date?

    public init(
        id: UUID,
        text: String,
        owner: String = "",
        assigneeID: String? = nil,
        dueDay: String? = nil,
        dueAt: Date? = nil,
        reminderAt: Date? = nil,
        done: Bool = false,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.owner = owner
        self.assigneeID = assigneeID
        self.dueDay = dueDay
        self.dueAt = dueAt
        self.reminderAt = reminderAt
        self.done = done
        self.completedAt = completedAt
    }
}

public struct SyncedMeetingOutcome: Codable, Equatable, Sendable {
    public var outcomeID: UUID
    public var sessionID: UUID
    public var state: SyncValue<String>
    public var summary: SyncValue<String>
    public var decisions: SyncValue<[String]>
    public var openQuestions: SyncValue<[String]>
    public var summaryEdited: Bool
    public var decisionsEdited: Bool
    public var questionsEdited: Bool
    public var coverageSeconds: Double
    public var writerTier: Int
    public var versions: [SyncedOutcomeVersionSnapshot]
    public var reviewCandidates: SyncValue<[SyncedTaskSnapshot]>
    public var updatedAt: Date
    public var isDeleted: SyncValue<Bool>

    public init(
        outcomeID: UUID,
        sessionID: UUID,
        state: SyncValue<String>,
        summary: SyncValue<String>,
        decisions: SyncValue<[String]>,
        openQuestions: SyncValue<[String]>,
        summaryEdited: Bool = false,
        decisionsEdited: Bool = false,
        questionsEdited: Bool = false,
        coverageSeconds: Double = 0,
        writerTier: Int = 0,
        versions: [SyncedOutcomeVersionSnapshot] = [],
        reviewCandidates: SyncValue<[SyncedTaskSnapshot]>,
        updatedAt: Date = Date(),
        isDeleted: SyncValue<Bool>
    ) {
        self.outcomeID = outcomeID
        self.sessionID = sessionID
        self.state = state
        self.summary = summary
        self.decisions = decisions
        self.openQuestions = openQuestions
        self.summaryEdited = summaryEdited
        self.decisionsEdited = decisionsEdited
        self.questionsEdited = questionsEdited
        self.coverageSeconds = coverageSeconds
        self.writerTier = writerTier
        self.versions = versions
        self.reviewCandidates = reviewCandidates
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }

    public var maximumCounter: Int64 {
        [
            state.version.counter,
            summary.version.counter,
            decisions.version.counter,
            openQuestions.version.counter,
            reviewCandidates.version.counter,
            isDeleted.version.counter
        ].max() ?? 0
    }

    public func merging(_ other: Self) -> Self {
        OutcomeAndTaskMergeEngine.mergeOutcomes(local: self, remote: other)
    }
}

public struct SyncedMeetingTask: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var outcomeID: UUID
    public var ordinal: SyncValue<Int>
    public var text: SyncValue<String>
    public var owner: SyncValue<String>
    public var assigneeID: SyncValue<String?>
    public var dueDay: SyncValue<String?>
    public var dueAt: SyncValue<Date?>
    public var reminderAt: SyncValue<Date?>
    public var done: SyncValue<Bool>
    public var completedAt: SyncValue<Date?>
    public var archivedByProfile: [String: SyncValue<Date?>]
    public var isDeleted: SyncValue<Bool>
    public var updatedAt: Date

    public init(
        id: UUID,
        sessionID: UUID,
        outcomeID: UUID,
        ordinal: SyncValue<Int>,
        text: SyncValue<String>,
        owner: SyncValue<String>,
        assigneeID: SyncValue<String?>,
        dueDay: SyncValue<String?>,
        dueAt: SyncValue<Date?>,
        reminderAt: SyncValue<Date?>,
        done: SyncValue<Bool>,
        completedAt: SyncValue<Date?>,
        archivedByProfile: [String: SyncValue<Date?>] = [:],
        isDeleted: SyncValue<Bool>,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.outcomeID = outcomeID
        self.ordinal = ordinal
        self.text = text
        self.owner = owner
        self.assigneeID = assigneeID
        self.dueDay = dueDay
        self.dueAt = dueAt
        self.reminderAt = reminderAt
        self.done = done
        self.completedAt = completedAt
        self.archivedByProfile = archivedByProfile
        self.isDeleted = isDeleted
        self.updatedAt = updatedAt
    }

    public var maximumCounter: Int64 {
        let base: [Int64] = [
            ordinal.version.counter,
            text.version.counter,
            owner.version.counter,
            assigneeID.version.counter,
            dueDay.version.counter,
            dueAt.version.counter,
            reminderAt.version.counter,
            done.version.counter,
            completedAt.version.counter,
            isDeleted.version.counter
        ]
        let archiveMax = archivedByProfile.values.map(\.version.counter).max() ?? 0
        return max(base.max() ?? 0, archiveMax)
    }

    public func merging(_ other: Self) -> Self {
        guard id == other.id else { return self }
        var result = self
        result.ordinal = ordinal.merging(other.ordinal)
        result.text = text.merging(other.text)
        result.owner = owner.merging(other.owner)
        result.assigneeID = assigneeID.merging(other.assigneeID)
        result.dueDay = dueDay.merging(other.dueDay)
        result.dueAt = dueAt.merging(other.dueAt)
        result.reminderAt = reminderAt.merging(other.reminderAt)
        result.done = done.merging(other.done)
        result.completedAt = completedAt.merging(other.completedAt)
        if result.done.value {
            result.reminderAt.value = nil
        }
        var mergedArchive = archivedByProfile
        for (profileID, archived) in other.archivedByProfile {
            mergedArchive[profileID] = mergedArchive[profileID]?.merging(archived) ?? archived
        }
        result.archivedByProfile = mergedArchive
        result.isDeleted = isDeleted.merging(other.isDeleted)
        result.updatedAt = max(updatedAt, other.updatedAt)
        return result
    }
}

public struct SyncedTaskLink: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var historicalTaskID: UUID
    public var canonicalTaskID: UUID
    public var updatedAt: Date

    public init(sessionID: UUID, historicalTaskID: UUID, canonicalTaskID: UUID, updatedAt: Date = Date()) {
        self.sessionID = sessionID
        self.historicalTaskID = historicalTaskID
        self.canonicalTaskID = canonicalTaskID
        self.updatedAt = updatedAt
    }

    public var syncID: String {
        sessionID.uuidString + "/" + historicalTaskID.uuidString
    }
}

public struct SyncedTaskProfile: Codable, Equatable, Sendable {
    public var profileID: String
    public var assigneeID: SyncValue<String?>
    public var aliases: SyncValue<[String]>

    public init(
        profileID: String,
        assigneeID: SyncValue<String?>,
        aliases: SyncValue<[String]>
    ) {
        self.profileID = profileID
        self.assigneeID = assigneeID
        self.aliases = aliases
    }

    public var maximumCounter: Int64 {
        max(assigneeID.version.counter, aliases.version.counter)
    }

    public func merging(_ other: Self) -> Self {
        guard profileID == other.profileID else { return self }
        return SyncedTaskProfile(
            profileID: profileID,
            assigneeID: assigneeID.merging(other.assigneeID),
            aliases: aliases.merging(other.aliases)
        )
    }
}

public struct SyncedTranscriptRevision: Codable, Equatable, Sendable {
    public var text: String
    public var author: String?
    public var observedAt: Date

    public init(text: String, author: String? = nil, observedAt: Date) {
        self.text = text
        self.author = author
        self.observedAt = observedAt
    }
}

public struct SyncedTranscriptEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var providerMessageID: String?
    public var kind: String
    public var sourceTier: Int
    public var occurredAt: Date
    public var endedAt: Date?
    public var speaker: String?
    public var isOwn: Bool
    public var text: String
    public var revisions: [SyncedTranscriptRevision]
    public var isBookmarked: Bool
    public var deviceID: String

    public init(
        id: String,
        providerMessageID: String? = nil,
        kind: String,
        sourceTier: Int = 1,
        occurredAt: Date,
        endedAt: Date? = nil,
        speaker: String? = nil,
        isOwn: Bool = false,
        text: String,
        revisions: [SyncedTranscriptRevision] = [],
        isBookmarked: Bool = false,
        deviceID: String
    ) {
        self.id = id
        self.providerMessageID = providerMessageID
        self.kind = kind
        self.sourceTier = sourceTier
        self.occurredAt = occurredAt
        self.endedAt = endedAt
        self.speaker = speaker
        self.isOwn = isOwn
        self.text = text
        self.revisions = revisions
        self.isBookmarked = isBookmarked
        self.deviceID = deviceID
    }
}

public struct SyncedTranscriptChunk: Codable, Equatable, Identifiable, Sendable {
    public var sessionID: UUID
    public var deviceID: String
    public var chunkIndex: Int
    public var sessionStartedAt: Date
    public var sessionEndedAt: Date?
    public var micActiveIntervals: [DateInterval]
    public var events: [SyncedTranscriptEvent]
    public var isDeleted: Bool
    public var updatedAt: Date

    public var id: String { "\(sessionID.uuidString):\(deviceID):\(chunkIndex)" }

    public init(
        sessionID: UUID,
        deviceID: String,
        chunkIndex: Int,
        sessionStartedAt: Date,
        sessionEndedAt: Date? = nil,
        micActiveIntervals: [DateInterval] = [],
        events: [SyncedTranscriptEvent] = [],
        isDeleted: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.chunkIndex = chunkIndex
        self.sessionStartedAt = sessionStartedAt
        self.sessionEndedAt = sessionEndedAt
        self.micActiveIntervals = micActiveIntervals
        self.events = events
        self.isDeleted = isDeleted
        self.updatedAt = updatedAt
    }

    public func merging(_ other: Self) -> Self {
        guard id == other.id else { return self }
        let preferOther = (other.updatedAt, other.events.count, other.isDeleted ? 1 : 0) >
            (updatedAt, events.count, isDeleted ? 1 : 0)
        var result = preferOther ? other : self
        result.sessionStartedAt = min(sessionStartedAt, other.sessionStartedAt)
        result.sessionEndedAt = [sessionEndedAt, other.sessionEndedAt].compactMap { $0 }.max()
        result.updatedAt = max(updatedAt, other.updatedAt)
        if !result.isDeleted {
            var byID: [String: SyncedTranscriptEvent] = [:]
            for event in events + other.events {
                if let existing = byID[event.id] {
                    let newer = event.revisions.count >= existing.revisions.count ? event : existing
                    var combined = newer
                    combined.isBookmarked = existing.isBookmarked || event.isBookmarked
                    byID[event.id] = combined
                } else {
                    byID[event.id] = event
                }
            }
            result.events = byID.values.sorted {
                $0.occurredAt == $1.occurredAt ? $0.id < $1.id : $0.occurredAt < $1.occurredAt
            }
            let intervals = Set(micActiveIntervals + other.micActiveIntervals)
            result.micActiveIntervals = intervals.sorted { $0.start < $1.start }
        }
        return result
    }
}

public struct SyncedCalendarOccurrence: Codable, Equatable, Identifiable, Sendable {
    public var occurrenceKey: String
    public var seriesKey: String
    public var title: String
    public var calendarTitle: String
    public var start: Date
    public var end: Date
    public var originalOccurrenceStart: Date?
    public var allDay: Bool
    public var tentative: Bool
    public var links: [URL]
    public var invitation: URL?
    public var engine: MeetingEngineKind?
    public var endpoint: String?
    public var requiresChoice: Bool
    public var sourceDevices: [String: Date]
    public var boundInvitation: SyncValue<URL?>?
    public var reminderOverride: SyncValue<ReminderOverride?>?
    public var skipped: SyncValue<Bool>?
    public var snoozeUntil: SyncValue<Date?>?
    public var snoozeScope: SyncValue<ReminderDeliveryScope?>?
    public var attendedDevices: Set<String>
    public var linkedSessionID: SyncValue<UUID?>?
    public var isDeleted: SyncValue<Bool>
    public var updatedAt: Date

    public var id: String { occurrenceKey }

    public init(
        occurrenceKey: String,
        seriesKey: String,
        title: String,
        calendarTitle: String,
        start: Date,
        end: Date,
        originalOccurrenceStart: Date? = nil,
        allDay: Bool = false,
        tentative: Bool = false,
        links: [URL] = [],
        invitation: URL? = nil,
        engine: MeetingEngineKind? = nil,
        endpoint: String? = nil,
        requiresChoice: Bool = false,
        sourceDevices: [String: Date] = [:],
        boundInvitation: SyncValue<URL?>? = nil,
        reminderOverride: SyncValue<ReminderOverride?>? = nil,
        skipped: SyncValue<Bool>? = nil,
        snoozeUntil: SyncValue<Date?>? = nil,
        snoozeScope: SyncValue<ReminderDeliveryScope?>? = nil,
        attendedDevices: Set<String> = [],
        linkedSessionID: SyncValue<UUID?>? = nil,
        isDeleted: SyncValue<Bool>,
        updatedAt: Date = Date()
    ) {
        self.occurrenceKey = occurrenceKey
        self.seriesKey = seriesKey
        self.title = title
        self.calendarTitle = calendarTitle
        self.start = start
        self.end = end
        self.originalOccurrenceStart = originalOccurrenceStart
        self.allDay = allDay
        self.tentative = tentative
        self.links = links
        self.invitation = invitation
        self.engine = engine
        self.endpoint = endpoint
        self.requiresChoice = requiresChoice
        self.sourceDevices = sourceDevices
        self.boundInvitation = boundInvitation
        self.reminderOverride = reminderOverride
        self.skipped = skipped
        self.snoozeUntil = snoozeUntil
        self.snoozeScope = snoozeScope
        self.attendedDevices = attendedDevices
        self.linkedSessionID = linkedSessionID
        self.isDeleted = isDeleted
        self.updatedAt = updatedAt
    }

    public var maximumCounter: Int64 {
        [
            boundInvitation?.version.counter,
            reminderOverride?.version.counter,
            skipped?.version.counter,
            snoozeUntil?.version.counter,
            snoozeScope?.version.counter,
            linkedSessionID?.version.counter,
            isDeleted.version.counter
        ].compactMap { $0 }.max() ?? 0
    }

    public var semanticFingerprint: CalendarOccurrenceSemanticFingerprint {
        CalendarOccurrenceSemanticFingerprint(
            title: title,
            start: start,
            end: end,
            allDay: allDay,
            links: links,
            invitation: boundInvitation?.value ?? invitation
        )
    }

    public func merging(_ other: Self) -> Self {
        guard occurrenceKey == other.occurrenceKey else { return self }
        let selfFresh = sourceDevices.values.max() ?? updatedAt
        let otherFresh = other.sourceDevices.values.max() ?? other.updatedAt
        let preferOtherMeta = (otherFresh, other.invitation != nil ? 1 : 0) >
            (selfFresh, invitation != nil ? 1 : 0)
        var result = preferOtherMeta ? other : self
        result.originalOccurrenceStart = result.originalOccurrenceStart ?? (preferOtherMeta ? originalOccurrenceStart : other.originalOccurrenceStart)
        let mergedDeleted = isDeleted.merging(other.isDeleted)
        result.isDeleted = mergedDeleted
        if mergedDeleted.value {
            if isDeleted.value && other.isDeleted.value {
                var intersection: [String: Date] = [:]
                for (device, seen) in sourceDevices {
                    if let otherSeen = other.sourceDevices[device] {
                        intersection[device] = max(seen, otherSeen)
                    }
                }
                result.sourceDevices = intersection
            } else {
                result.sourceDevices = isDeleted.value ? sourceDevices : other.sourceDevices
            }
        } else {
            var sources = isDeleted.value ? [:] : sourceDevices
            if !other.isDeleted.value {
                for (device, seen) in other.sourceDevices {
                    sources[device] = max(sources[device] ?? seen, seen)
                }
            }
            result.sourceDevices = sources
        }
        result.boundInvitation = mergeOptional(boundInvitation, other.boundInvitation)
        result.reminderOverride = mergeOptional(reminderOverride, other.reminderOverride)
        result.skipped = mergeOptional(skipped, other.skipped)
        result.snoozeUntil = mergeOptional(snoozeUntil, other.snoozeUntil)
        result.snoozeScope = mergeOptional(snoozeScope, other.snoozeScope)
        result.attendedDevices = attendedDevices.union(other.attendedDevices)
        result.linkedSessionID = mergeOptional(linkedSessionID, other.linkedSessionID)
        result.updatedAt = max(updatedAt, other.updatedAt)
        return result
    }

    public func coalescingSemanticDuplicate(_ other: Self) -> Self {
        let selfResolved = (!isDeleted.value && (boundInvitation?.value ?? invitation) != nil && engine != nil && !requiresChoice) ? 1 : 0
        let otherResolved = (!other.isDeleted.value && (other.boundInvitation?.value ?? other.invitation) != nil && other.engine != nil && !other.requiresChoice) ? 1 : 0
        let selfAny = ((boundInvitation?.value ?? invitation) != nil || !links.isEmpty) ? 1 : 0
        let otherAny = ((other.boundInvitation?.value ?? other.invitation) != nil || !other.links.isEmpty) ? 1 : 0
        let selfFresh = sourceDevices.values.max() ?? updatedAt
        let otherFresh = other.sourceDevices.values.max() ?? other.updatedAt

        let selfRank = (isDeleted.value ? 0 : 1, selfResolved, selfAny, selfFresh)
        let otherRank = (other.isDeleted.value ? 0 : 1, otherResolved, otherAny, otherFresh)
        let preferOther = otherRank > selfRank || (otherRank == selfRank && other.occurrenceKey < occurrenceKey)

        let base = preferOther ? other : self
        let secondary = preferOther ? self : other
        var result = base
        result.originalOccurrenceStart = result.originalOccurrenceStart ?? secondary.originalOccurrenceStart

        var sources = base.sourceDevices
        for (device, seen) in secondary.sourceDevices {
            sources[device] = max(sources[device] ?? seen, seen)
        }
        result.sourceDevices = sources

        var mergedLinks = base.links
        var seenLinks = Set(base.links)
        for link in secondary.links where seenLinks.insert(link).inserted {
            mergedLinks.append(link)
        }
        result.links = mergedLinks
        result.invitation = base.invitation ?? secondary.invitation
        result.engine = base.engine ?? secondary.engine
        result.endpoint = base.endpoint ?? secondary.endpoint
        result.boundInvitation = mergeOptional(base.boundInvitation, secondary.boundInvitation)
        result.reminderOverride = mergeOptional(base.reminderOverride, secondary.reminderOverride)
        result.skipped = mergeOptional(base.skipped, secondary.skipped)
        result.snoozeUntil = mergeOptional(base.snoozeUntil, secondary.snoozeUntil)
        result.snoozeScope = mergeOptional(base.snoozeScope, secondary.snoozeScope)
        result.attendedDevices = base.attendedDevices.union(secondary.attendedDevices)
        result.linkedSessionID = mergeOptional(base.linkedSessionID, secondary.linkedSessionID)
        result.isDeleted = base.isDeleted
        result.updatedAt = max(base.updatedAt, secondary.updatedAt)
        return result
    }

    private func mergeOptional<V>(_ lhs: SyncValue<V>?, _ rhs: SyncValue<V>?) -> SyncValue<V>? {
        switch (lhs, rhs) {
        case (.some(let a), .some(let b)): return a.merging(b)
        case (.some(let a), .none): return a
        case (.none, .some(let b)): return b
        case (.none, .none): return nil
        }
    }
}

public struct SyncedGuidanceRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var deleted: Bool

    public init(id: UUID = UUID(), text: String, deleted: Bool = false) {
        self.id = id
        self.text = text
        self.deleted = deleted
    }
}

public struct SyncedMeetingContextSettings: Codable, Equatable, Identifiable, Sendable {
    public enum ScopeKind: String, Codable, Equatable, Sendable {
        case allMeetings
        case room
        case calendarSeries
    }

    public var id: String { scopeKey }
    public var scopeKey: String
    public var scopeKind: ScopeKind
    public var title: SyncValue<String>
    public var sameRoomTransition: SyncValue<String?>?
    public var attentionMode: SyncValue<String?>?
    public var urgency: SyncValue<String>?
    public var suggestReplies: SyncValue<Bool?>?
    public var about: SyncValue<String>?
    public var matters: SyncValue<String>?
    public var never: SyncValue<String>?
    public var people: SyncValue<[String]>?
    public var defaultReminderOverride: SyncValue<ReminderOverride?>?
    public var guidanceRules: [UUID: SyncValue<SyncedGuidanceRule>]

    public init(
        scopeKey: String,
        scopeKind: ScopeKind,
        title: SyncValue<String>,
        sameRoomTransition: SyncValue<String?>? = nil,
        attentionMode: SyncValue<String?>? = nil,
        urgency: SyncValue<String>? = nil,
        suggestReplies: SyncValue<Bool?>? = nil,
        about: SyncValue<String>? = nil,
        matters: SyncValue<String>? = nil,
        never: SyncValue<String>? = nil,
        people: SyncValue<[String]>? = nil,
        defaultReminderOverride: SyncValue<ReminderOverride?>? = nil,
        guidanceRules: [UUID: SyncValue<SyncedGuidanceRule>] = [:]
    ) {
        self.scopeKey = scopeKey
        self.scopeKind = scopeKind
        self.title = title
        self.sameRoomTransition = sameRoomTransition
        self.attentionMode = attentionMode
        self.urgency = urgency
        self.suggestReplies = suggestReplies
        self.about = about
        self.matters = matters
        self.never = never
        self.people = people
        self.defaultReminderOverride = defaultReminderOverride
        self.guidanceRules = guidanceRules
    }

    public var maximumCounter: Int64 {
        let scalars: [Int64?] = [
            title.version.counter,
            sameRoomTransition?.version.counter,
            attentionMode?.version.counter,
            urgency?.version.counter,
            suggestReplies?.version.counter,
            about?.version.counter,
            matters?.version.counter,
            never?.version.counter,
            people?.version.counter,
            defaultReminderOverride?.version.counter
        ]
        let ruleMax = guidanceRules.values.map(\.version.counter).max() ?? 0
        return max(scalars.compactMap { $0 }.max() ?? 0, ruleMax)
    }

    public func merging(_ other: Self) -> Self {
        guard scopeKey == other.scopeKey else { return self }
        var result = self
        result.title = title.merging(other.title)
        result.sameRoomTransition = mergeOptional(sameRoomTransition, other.sameRoomTransition)
        result.attentionMode = mergeOptional(attentionMode, other.attentionMode)
        result.urgency = mergeOptional(urgency, other.urgency)
        result.suggestReplies = mergeOptional(suggestReplies, other.suggestReplies)
        result.about = mergeOptional(about, other.about)
        result.matters = mergeOptional(matters, other.matters)
        result.never = mergeOptional(never, other.never)
        result.people = mergeOptional(people, other.people)
        result.defaultReminderOverride = mergeOptional(defaultReminderOverride, other.defaultReminderOverride)
        var rules = guidanceRules
        for (ruleID, value) in other.guidanceRules {
            rules[ruleID] = rules[ruleID]?.merging(value) ?? value
        }
        result.guidanceRules = rules
        return result
    }

    private func mergeOptional<V>(_ lhs: SyncValue<V>?, _ rhs: SyncValue<V>?) -> SyncValue<V>? {
        switch (lhs, rhs) {
        case (.some(let a), .some(let b)): return a.merging(b)
        case (.some(let a), .none): return a
        case (.none, .some(let b)): return b
        case (.none, .none): return nil
        }
    }
}

public enum MeetingLibrarySyncRecord: SyncZoneRecord {
    case session(SyncedMeetingSession)
    case note(SyncedMeetingNote)
    case outcome(SyncedMeetingOutcome)
    case task(SyncedMeetingTask)
    case taskLink(SyncedTaskLink)
    case taskProfile(SyncedTaskProfile)
    case contextSettings(SyncedMeetingContextSettings)

    public var syncRecordID: String {
        switch self {
        case .session(let value): return "session:" + value.id.uuidString
        case .note(let value): return "note:" + value.sessionID.uuidString
        case .outcome(let value): return "outcome:" + value.sessionID.uuidString
        case .task(let value): return "task:" + value.id.uuidString
        case .taskLink(let value): return "tasklink:" + value.syncID
        case .taskProfile(let value): return "taskprofile:" + value.profileID
        case .contextSettings(let value): return "settings:" + value.scopeKey
        }
    }

    public var maximumSyncCounter: Int64 {
        switch self {
        case .session(let value): return value.maximumCounter
        case .note(let value): return value.maximumCounter
        case .outcome(let value): return value.maximumCounter
        case .task(let value): return value.maximumCounter
        case .taskLink: return 0
        case .taskProfile(let value): return value.maximumCounter
        case .contextSettings(let value): return value.maximumCounter
        }
    }

    public func merging(_ other: Self) -> Self {
        switch (self, other) {
        case (.session(let a), .session(let b)): return .session(a.merging(b))
        case (.note(let a), .note(let b)):
            return a.version < b.version ? .note(b) : .note(a)
        case (.outcome(let a), .outcome(let b)): return .outcome(a.merging(b))
        case (.task(let a), .task(let b)): return .task(a.merging(b))
        case (.taskLink(let a), .taskLink(let b)):
            return a.updatedAt >= b.updatedAt ? .taskLink(a) : .taskLink(b)
        case (.taskProfile(let a), .taskProfile(let b)): return .taskProfile(a.merging(b))
        case (.contextSettings(let a), .contextSettings(let b)): return .contextSettings(a.merging(b))
        default: return self
        }
    }
}

public enum MeetingTranscriptSyncRecord: SyncZoneRecord {
    case chunk(SyncedTranscriptChunk)

    public var syncRecordID: String {
        switch self {
        case .chunk(let value): return "transcript:" + value.id
        }
    }

    public var maximumSyncCounter: Int64 { 0 }

    public func merging(_ other: Self) -> Self {
        switch (self, other) {
        case (.chunk(let a), .chunk(let b)): return .chunk(a.merging(b))
        }
    }
}

public enum MeetingScheduleSyncRecord: SyncZoneRecord {
    case occurrence(SyncedCalendarOccurrence)

    public var syncRecordID: String {
        switch self {
        case .occurrence(let value): return "cal:" + value.occurrenceKey
        }
    }

    public var maximumSyncCounter: Int64 {
        switch self {
        case .occurrence(let value): return value.maximumCounter
        }
    }

    public func merging(_ other: Self) -> Self {
        switch (self, other) {
        case (.occurrence(let a), .occurrence(let b)): return .occurrence(a.merging(b))
        }
    }
}

public extension Date {
    var syncMilliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
    static func fromSyncMilliseconds(_ value: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(value) / 1000)
    }
}

public extension String {
    var workspaceFolded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
