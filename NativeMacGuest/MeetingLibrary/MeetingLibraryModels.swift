import Foundation

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

    init(id: UUID = UUID(), title: String, invitation: URL? = nil, roomIdentity: String = "",
         calendarSeriesID: String? = nil, continuationID: String? = nil, startedAt: Date,
         endedAt: Date? = nil, timeZoneID: String = TimeZone.current.identifier, state: State = .active,
         exportRevision: Int = 0, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.title = title; self.invitation = invitation; self.roomIdentity = roomIdentity
        self.calendarSeriesID = calendarSeriesID; self.continuationID = continuationID
        self.startedAt = startedAt; self.endedAt = endedAt; self.timeZoneID = timeZoneID
        self.state = state; self.exportRevision = exportRevision; self.createdAt = createdAt; self.updatedAt = updatedAt
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
    var updatedAt: Date
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

/// Export granularity. Mode A (separate meeting files) is the only selectable mode
/// in this stage; worklog/index components exist in the schema for later stages and
/// must not be offered in UI until their convergence tests pass.
enum ObsidianExportMode: String, Codable, CaseIterable, Sendable {
    case separateFiles = "separateFiles"
}

struct ObsidianDestinationRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var enabled: Bool
    var mode: ObsidianExportMode
    /// Vault-relative folder for meeting files; validated to stay inside the vault.
    var meetingFolder: String
    var configRevision: Int
    /// Security-scoped bookmark data for the vault root.
    var vaultBookmark: Data?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), enabled: Bool = false, mode: ObsidianExportMode = .separateFiles,
         meetingFolder: String = "Meetings", configRevision: Int = 0, vaultBookmark: Data? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.enabled = enabled; self.mode = mode; self.meetingFolder = meetingFolder
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
        }
    }

    /// Retryable errors resume automatically; conflicts and marker damage wait for the user.
    var isTransient: Bool {
        switch self {
        case .vaultUnavailable, .backupFailed, .verifyFailed, .destinationChanged, .staleRevision: true
        case .pathEscapesVault, .notARegularFile, .managedBlockConflict, .markerDamage: false
        }
    }
}
