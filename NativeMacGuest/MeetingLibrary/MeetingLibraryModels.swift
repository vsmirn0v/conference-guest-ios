import Foundation

enum MeetingStartProvenance: String, Codable, Equatable, Sendable {
    case recorded, outcomeOnly, unknown
}

struct MeetingEffectiveDate: Equatable, Sendable {
    var date: Date
    var fromEnd: Bool

    static func resolve(start: Date?, end: Date?) -> Self? {
        if let start, start != .distantPast { return Self(date: start, fromEnd: false) }
        if let end, end != .distantPast { return Self(date: end, fromEnd: true) }
        return nil
    }
}

/// Durable identity for one occurrence of a meeting. A room may host many sessions;
/// a title change never changes the session ID or an existing export binding.
struct MeetingSessionRecord: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, CaseIterable, Sendable {
        case joining, active, reconnecting, ended, failed
    }

    var id: UUID
    var title: String
    var invitation: URL?
    var roomIdentity: String
    var calendarSeriesID: String?
    var continuationID: String?
    var startedAt: Date
    var endedAt: Date?
    var timeZoneID: String
    var state: State
    var exportRevision: Int
    var createdAt: Date
    var updatedAt: Date
    var startProvenance: MeetingStartProvenance?
    var outcomeEndFallback: Date?

    var recordedStart: Date? { startProvenance == .recorded && startedAt != .distantPast ? startedAt : nil }
    var knownEnd: Date? { [endedAt, outcomeEndFallback].compactMap { $0 }.first { $0 != .distantPast } }
    var effectiveDate: MeetingEffectiveDate? { .resolve(start: recordedStart, end: knownEnd) }

    init(id: UUID = UUID(), title: String, invitation: URL? = nil, roomIdentity: String = "",
         calendarSeriesID: String? = nil, continuationID: String? = nil, startedAt: Date,
         endedAt: Date? = nil, timeZoneID: String = TimeZone.current.identifier, state: State = .active,
         exportRevision: Int = 0, createdAt: Date = Date(), updatedAt: Date = Date(),
         startProvenance: MeetingStartProvenance? = .recorded, outcomeEndFallback: Date? = nil) {
        self.id = id; self.title = title; self.invitation = invitation; self.roomIdentity = roomIdentity
        self.calendarSeriesID = calendarSeriesID; self.continuationID = continuationID
        self.startedAt = startedAt; self.endedAt = endedAt; self.timeZoneID = timeZoneID
        self.state = state; self.exportRevision = exportRevision; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.startProvenance = startProvenance; self.outcomeEndFallback = outcomeEndFallback
    }
}

struct MeetingNoteRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var sessionID: UUID
    var markdown: String
    var revision: Int
    var createdAt: Date
    var updatedAt: Date

    var isEmpty: Bool { markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum MeetingOutcomePersistenceState: String, Codable, CaseIterable, Sendable {
    case notStarted, pending, draft, ready, failed
}

struct MeetingOutcomeCommit: Codable, Equatable, Sendable {
    var outcomeID: UUID
    var sessionID: UUID
    var state: MeetingOutcomePersistenceState
    var outcome: MeetingOutcome
    var revision: Int
    var exportRevision: Int
    var updatedAt: Date
}

struct MeetingOutcomeVersion: Identifiable, Equatable, Sendable {
    var id: String { "\(outcome.id.uuidString)/\(revision)" }
    var outcome: MeetingOutcome
    var revision: Int
    var savedAt: Date?
    var isCurrent: Bool
}

struct MeetingLibrarySnapshot: Codable, Equatable, Sendable {
    var sessions: [MeetingSessionRecord]
    var notes: [MeetingNoteRecord]
    var outcomes: [MeetingOutcome]
}

struct MeetingLibraryNoteCommit: Codable, Equatable, Sendable {
    var sessionID: UUID
    var noteID: UUID
    var revision: Int
    var exportRevision: Int
    var updatedAt: Date
    var queuedDestinations: Int
}

/// One addressable meeting in Assistant/history. Outcomes remain optional so a
/// notes-only meeting has a first-class card instead of being hidden until a model
/// completes.
struct MeetingLibraryCard: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { sessionID }
    var sessionID: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var state: MeetingSessionRecord.State
    var hasNotes: Bool
    var noteID: UUID?
    var noteRevision: Int
    /// Bounded preview of the committed note for Assistant context; never the whole note.
    var notePreview: String?
    var outcomeID: UUID?
    var outcomeState: MeetingOutcomePersistenceState
    var outcomeErrorCode: String? = nil
    var hasOutcomeInput: Bool = false
    var updatedAt: Date
    var startProvenance: MeetingStartProvenance?
    var outcomeEndFallback: Date?

    var effectiveDate: MeetingEffectiveDate? {
        .resolve(start: startProvenance == .recorded ? startedAt : nil, end: endedAt ?? outcomeEndFallback)
    }
}

struct MeetingNoteChunk: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var sessionID: UUID
    var noteID: UUID
    var noteRevision: Int
    var ordinal: Int
    var startOffset: Int
    var endOffset: Int
    var startLine: Int
    var endLine: Int
    var text: String
}

struct MeetingNoteSearchResult: Codable, Equatable, Identifiable, Sendable {
    var id: String { chunk.id }
    var chunk: MeetingNoteChunk
    var sessionID: UUID
    var meetingTitle: String
    var startedAt: Date
    var matchedField: String
}

enum MeetingLibraryError: LocalizedError, Equatable {
    case unavailable(String)
    case invalidSession
    case persistenceFailed(String)
    case migrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail): L("Meeting library is unavailable: %@", detail)
        case .invalidSession: L("The meeting is unavailable.")
        case .persistenceFailed(let detail): L("Meeting data could not be saved. %@", detail)
        case .migrationFailed(let detail): L("Existing Assistant data could not be migrated. %@", detail)
        }
    }
}

// MARK: - Obsidian export (Stage 4+)

enum ObsidianExportMode: String, Codable, CaseIterable, Sendable {
    case separateFiles, worklog, filesAndIndex

    var requiredComponents: [ObsidianExportComponent] {
        switch self {
        case .separateFiles: [.meeting]
        case .worklog: [.worklog]
        case .filesAndIndex: [.meeting, .index]
        }
    }
}

struct ObsidianExportLayout: Codable, Equatable, Sendable {
    var documentPath = "Meeting worklog.md"
    var monthly = false
    var sections: MeetingMarkdownSections = .all
    var groupByDay = false
    var newestDaysFirst = true
    var insertAtBeginning = false
    var withinDayAtBeginning = false
    var timeZoneID = TimeZone.current.identifier
    var runtimeStyle = false
    /// Path-scoped confirmations from the placement preview, keyed by the original section.
    var legacyRuntimeYears: [String: [String: Int]]?
    var startAfter: String?
    var endBefore: String?

    mutating func applyRuntimePreset() {
        monthly = false
        groupByDay = true
        newestDaysFirst = true
        withinDayAtBeginning = false
        runtimeStyle = true
    }
}

struct ObsidianDestinationRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var enabled: Bool
    var saveAfterMeeting: Bool
    var syncChanges: Bool
    var mode: ObsidianExportMode
    /// Vault-relative folder for meeting files; validated to stay inside the vault.
    var meetingFolder: String
    var layout: ObsidianExportLayout
    var configRevision: Int
    /// Security-scoped bookmark data for the vault root.
    var vaultBookmark: Data?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), enabled: Bool = false, saveAfterMeeting: Bool = false,
         syncChanges: Bool = false, mode: ObsidianExportMode = .separateFiles,
         meetingFolder: String = "Meetings", layout: ObsidianExportLayout = .init(),
         configRevision: Int = 0, vaultBookmark: Data? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.enabled = enabled; self.saveAfterMeeting = saveAfterMeeting; self.syncChanges = syncChanges
        self.mode = mode; self.meetingFolder = meetingFolder; self.layout = layout
        self.configRevision = configRevision; self.vaultBookmark = vaultBookmark
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

enum ObsidianExportComponent: String, Codable, Sendable {
    case meeting, worklog, index
}

enum ObsidianBindingState: String, Codable, Sendable {
    case idle, exporting, exported, conflict, failed, paused
}

struct ObsidianExportBindingRecord: Codable, Equatable, Sendable {
    var destinationID: UUID
    var sessionID: UUID
    var component: ObsidianExportComponent
    var relativePath: String
    var markerID: String?
    var lastExportedRevision: Int
    var lastBlockSHA256: String?
    var lastFileSHA256: String?
    var state: ObsidianBindingState
    var errorCode: String?
    var updatedAt: Date
    var lastMetadataSHA256: String?
    var metadataOwnershipEvaluated: Bool?
}

enum ObsidianExportIntent: String, Codable, Sendable {
    case initialEnd, initialFirstReady, linkedUpdate, manualSave, legacy

    func permitted(by destination: ObsidianDestinationRecord) -> Bool {
        switch self {
        case .manualSave: return true
        case .initialEnd, .initialFirstReady: return destination.enabled && destination.saveAfterMeeting
        case .linkedUpdate: return destination.enabled && destination.syncChanges
        case .legacy: return false
        }
    }
}

struct ObsidianExportSnapshot: Codable, Equatable, Sendable {
    var session: MeetingSessionRecord
    var note: MeetingNoteRecord?
    var outcome: MeetingOutcome?
    var outcomeState: MeetingOutcomePersistenceState
}

struct ObsidianOutboxRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String { destinationID.uuidString + "/" + sessionID.uuidString }
    var destinationID: UUID
    var sessionID: UUID
    var desiredRevision: Int
    var desiredConfigRevision: Int
    var attemptCount: Int
    var nextAttemptAt: Date
    var paused: Bool
    var lastErrorCode: String?
    var updatedAt: Date
    var intent: ObsidianExportIntent = .legacy
    var snapshot: ObsidianExportSnapshot?
    var policyHeld = false
}

enum ObsidianExportError: LocalizedError, Equatable {
    case vaultUnavailable(String)
    case pathEscapesVault(String)
    case notARegularFile(String)
    case managedBlockConflict
    case markerDamage(String)
    case backupFailed(String)
    case verifyFailed(String)
    case destinationChanged
    case staleRevision
    case placementConflict(String)

    var errorDescription: String? {
        switch self {
        case .vaultUnavailable(let detail): L("The Obsidian vault is unavailable: %@", detail)
        case .pathEscapesVault(let path): L("“%@” is outside the selected vault.", path)
        case .notARegularFile(let path): L("“%@” is not a regular file.", path)
        case .managedBlockConflict: L("The exported section was changed outside Rock’N’Roll. Choose how to resolve the conflict.")
        case .markerDamage(let detail): L("The managed markers in the export file are damaged: %@", detail)
        case .backupFailed(let detail): L("A safety backup could not be written: %@", detail)
        case .verifyFailed(let detail): L("The exported file could not be verified: %@", detail)
        case .destinationChanged: L("The export destination changed while writing.")
        case .staleRevision: L("A newer local revision exists; the export will be retried.")
        case .placementConflict(let detail): L("The worklog placement is ambiguous. %@", detail)
        }
    }

    /// Retryable errors resume automatically; conflicts and marker damage wait for the user.
    var isTransient: Bool {
        switch self {
        case .vaultUnavailable, .backupFailed, .verifyFailed, .destinationChanged, .staleRevision: true
        case .pathEscapesVault, .notARegularFile, .managedBlockConflict, .markerDamage, .placementConflict: false
        }
    }
}
