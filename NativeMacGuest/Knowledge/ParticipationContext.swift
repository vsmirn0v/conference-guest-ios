import Combine
import ConferenceCore
import CryptoKit
import Foundation

/// The selected vault can change while a reply is being generated or queued.
/// The workspace marks a change before persisting the replacement bookmark.
final class ParticipationVaultConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var changing = false
    private var callbacks: [UUID: @Sendable () -> Void] = [:]

    func beginChange() -> UInt64 {
        lock.lock()
        generation &+= 1
        changing = true
        let change = generation
        let pending = callbacks.values
        callbacks.removeAll()
        lock.unlock()
        for cancel in pending { cancel() }
        return change
    }

    func endChange(_ change: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if generation == change { changing = false }
    }

    func currentGeneration() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return changing ? nil : generation
    }

    func cancelOnChange(generation expected: UInt64, _ cancel: @escaping @Sendable () -> Void) -> AnyCancellable {
        let id = UUID()
        lock.lock()
        let current = !changing && generation == expected
        if current { callbacks[id] = cancel }
        lock.unlock()
        if !current { cancel() }
        return AnyCancellable { [weak self] in self?.removeCallback(id) }
    }

    private func removeCallback(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        callbacks[id] = nil
    }
}

/// Persistent notes can also be edited outside the meeting note window.
final class ParticipationNoteChanges: @unchecked Sendable {
    struct Version: Equatable, Sendable {
        fileprivate let library: UInt64
        fileprivate let note: UInt64
    }

    private let lock = NSLock()
    private var libraryVersion: UInt64 = 0
    private var noteVersions: [UUID: UInt64] = [:]
    private var callbacks: [UUID: (session: UUID, cancel: @Sendable () -> Void)] = [:]

    func willChange(_ sessionID: UUID? = nil) {
        lock.lock()
        if let sessionID { noteVersions[sessionID, default: 0] &+= 1 }
        else { libraryVersion &+= 1; noteVersions.removeAll() }
        let pending = callbacks.filter { sessionID == nil || $0.value.session == sessionID }
        for id in pending.keys { callbacks[id] = nil }
        lock.unlock()
        for callback in pending.values { callback.cancel() }
    }

    func version(_ sessionID: UUID) -> Version {
        lock.lock(); defer { lock.unlock() }
        return currentVersion(sessionID)
    }

    func observe(_ sessionID: UUID, version: Version, _ cancel: @escaping @Sendable () -> Void) -> AnyCancellable {
        let id = UUID()
        lock.lock()
        let current = version == currentVersion(sessionID)
        if current { callbacks[id] = (sessionID, cancel) }
        lock.unlock()
        if !current { cancel() }
        return AnyCancellable { [weak self] in self?.removeCallback(id) }
    }

    private func currentVersion(_ sessionID: UUID) -> Version {
        .init(library: libraryVersion, note: noteVersions[sessionID, default: 0])
    }

    private func removeCallback(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        callbacks[id] = nil
    }
}

enum ParticipationContext {
    /// These fields come from the current user's profile, meeting preset, and
    /// the note they can edit for this session. Vault documents are separate.
    struct Instructions: Encodable, Equatable, Sendable {
        var meetingAbout: String?
        var meetingPriorities: String?
        var meetingAvoid: String?
        var meetingNote: String?
        var userRole: String?
        var replyStyle: String?
        var workspaceLiveGuidance: [String]?
        var workspaceReviewGuidance: [String]?
    }

    struct Snapshot: Sendable {
        let instructions: Instructions
        let sources: [ParticipationSource]
        let canSearchVault: Bool
        fileprivate let live: LiveFields
        fileprivate let session: SessionFields
        fileprivate let note: NoteVersion?
        fileprivate let noteChanges: ParticipationNoteChanges
        fileprivate let persistedNoteVersion: ParticipationNoteChanges.Version
        fileprivate let readSavedNote: Bool
        fileprivate let vault: VaultEvidence?

        var hasVaultSources: Bool { vault != nil }

        @MainActor
        func validates(model: NativeDesktopMeetingModel, store: AttentionStore) -> Bool {
            guard live == LiveFields(model: model, store: store), vault?.isCurrent != false,
                  note?.isDraft == true || readSavedNote,
                  note?.isDraft == true || noteChanges.version(live.sessionID) == persistedNoteVersion
            else { return false }
            if let draft = store.notes.draft(sessionID: live.sessionID), draft.savedText != nil || draft.isDirty {
                return draft.text == (note?.markdown ?? "")
            }
            return note?.isDraft != true
        }

        @MainActor
        func revalidate(model: NativeDesktopMeetingModel, store: AttentionStore) async -> Bool {
            guard validates(model: model, store: store) else { return false }
            let library = store.meetingLibrary.store
            do {
                if session.recordedStart != nil || session.timeZone != nil {
                    let current = try await library.session(live.sessionID)
                    guard session == SessionFields(current) else { return false }
                }
                if note?.isDraft != true, readSavedNote {
                    let savedNote = try await library.note(live.sessionID)
                    guard savedNote?.revision == note?.savedRevision else { return false }
                }
                if let vault {
                    let destination = try await library.destination()
                    guard destination?.vaultBookmark == vault.bookmark else { return false }
                }
            } catch {
                return false
            }
            return !Task.isCancelled && validates(model: model, store: store)
        }

        /// Called at the outbound boundary using only the selected bookmark and
        /// the exact files that supplied excerpts.
        func validateVaultSources() -> Bool {
            vault?.validate() ?? true
        }

        func cancelOnVaultChange(_ cancel: @escaping @Sendable () -> Void) -> AnyCancellable? {
            guard let vault else { return nil }
            return vault.connection.cancelOnChange(generation: vault.generation, cancel)
        }

        func cancelOnPersistedNoteChange(_ cancel: @escaping @Sendable () -> Void) -> AnyCancellable? {
            guard note?.isDraft != true else { return nil }
            return noteChanges.observe(live.sessionID, version: persistedNoteVersion, cancel)
        }
    }

    fileprivate struct LiveFields: Equatable, Sendable {
        let sessionID: UUID
        let title: String
        let calendar: CalendarMeeting?
        let participantNames: [String]
        let instructions: Instructions

        @MainActor
        init(model: NativeDesktopMeetingModel, store: AttentionStore) {
            sessionID = model.sessionID
            title = model.title
            calendar = model.participationCalendar
            participantNames = model.participants.map(\.name).sorted()
            let preset = store.preset(room: model.invitation, series: model.calendarSeriesID)
            let liveGuidance = model.participation.workspaceGuidance
            let reviewGuidance = store.workspaceGuidance.instructions(for: model)
            instructions = .init(meetingAbout: bounded(preset?.about, 900),
                meetingPriorities: bounded(preset?.matters, 900), meetingAvoid: bounded(preset?.never, 600),
                userRole: bounded(store.profile.role, 400), replyStyle: bounded(store.profile.replyStyle, 900),
                workspaceLiveGuidance: liveGuidance.isEmpty ? nil : liveGuidance,
                workspaceReviewGuidance: reviewGuidance.isEmpty ? nil : reviewGuidance)
        }
    }

    fileprivate struct SessionFields: Equatable, Sendable {
        let recordedStart: Date?
        let timeZone: String?

        init(_ session: MeetingSessionRecord?) {
            recordedStart = session?.recordedStart
            timeZone = session?.timeZoneID
        }
    }

    fileprivate struct NoteVersion: Sendable {
        let markdown: String
        let isDraft: Bool
        let savedRevision: Int?
    }

    fileprivate struct VaultEvidence: Sendable {
        let bookmark: Data
        let generation: UInt64
        let connection: ParticipationVaultConnection
        let matches: [ParticipationVaultSearch.Match]

        var isCurrent: Bool { connection.currentGeneration() == generation }

        func validate() -> Bool {
            guard isCurrent, case .granted(let root) = ObsidianVaultAccess.resolve(bookmark) else { return false }
            defer { root.stopAccessingSecurityScopedResource() }
            return ParticipationVaultSearch.validate(matches, root: root) && isCurrent
        }
    }

    @MainActor
    static func read(model: NativeDesktopMeetingModel, store: AttentionStore, query: String,
                     includeVault: Bool = true) async -> Snapshot {
        let live = LiveFields(model: model, store: store)
        let controller = store.meetingLibrary
        let library = controller.store
        let connection = controller.participationVaultConnection
        let generation = connection.currentGeneration()
        let session = SessionFields(try? await library.session(live.sessionID))
        let noteChanges = library.participationNoteChanges
        let persistedNoteVersion = noteChanges.version(live.sessionID)
        let savedNote: MeetingNoteRecord?
        let readSavedNote: Bool
        do {
            savedNote = try await library.note(live.sessionID)
            readSavedNote = true
        } catch {
            savedNote = nil
            readSavedNote = false
        }
        let draft = store.notes.draft(sessionID: live.sessionID)
        let note: NoteVersion?
        if let draft, draft.savedText != nil || draft.isDirty {
            note = .init(markdown: draft.text, isDraft: true, savedRevision: draft.revision)
        } else {
            note = savedNote.map { .init(markdown: $0.markdown, isDraft: false, savedRevision: $0.revision) }
        }

        let terms = ParticipationVaultSearch.queryWords(query)
        let keywords = terms.joined(separator: " ")
        var instructions = live.instructions
        var sources = metadata(live, session).map { [$0] } ?? []
        if let info = meetingInfoSource(instructions.meetingAbout) { sources.append(info) }
        if let markdown = note?.markdown, !markdown.trimmed.isEmpty {
            let excerpt = ParticipationSourceBinding.relevantExcerpt(in: markdown, matching: keywords)
            instructions.meetingNote = noteGuidance(markdown, excerpt: excerpt)
            if let excerpt = excerpt ?? bounded(markdown, 1_200) {
                sources.append(.init(id: "meeting-note", title: "Current meeting notes", text: excerpt,
                                     revision: digest(markdown)))
            }
        }

        let destination = try? await library.destination()
        let bookmark = destination?.vaultBookmark
        let canSearchVault = generation != nil && bookmark != nil && connection.currentGeneration() == generation
        var vault: VaultEvidence?
        if includeVault, let generation, !terms.isEmpty, !Task.isCancelled, let bookmark,
           connection.currentGeneration() == generation {
            let result: [ParticipationVaultSearch.Match]? = await ParticipationSourceBinding.withReadDeadline(.milliseconds(1_200)) {
                guard connection.currentGeneration() == generation,
                      case .granted(let root) = ObsidianVaultAccess.resolve(bookmark) else { return nil }
                defer { root.stopAccessingSecurityScopedResource() }
                return ParticipationVaultSearch.search(root: root, query: terms, meetingTitle: live.title)
            }
            if let matches = result, !matches.isEmpty, connection.currentGeneration() == generation {
                vault = VaultEvidence(bookmark: bookmark, generation: generation, connection: connection, matches: matches)
                sources.append(contentsOf: matches.map(\.source))
            }
        }
        return .init(instructions: instructions, sources: sources, canSearchVault: canSearchVault,
                     live: live, session: session, note: note, noteChanges: noteChanges,
                     persistedNoteVersion: persistedNoteVersion, readSavedNote: readSavedNote, vault: vault)
    }

    private static func metadata(_ live: LiveFields, _ session: SessionFields) -> ParticipationSource? {
        var fields: [String] = []
        if let title = bounded(live.title, 200) { fields.append("Meeting title: " + title) }
        let iso = ISO8601DateFormatter()
        if let calendar = live.calendar, !calendar.allDay {
            fields.append("Scheduled start: " + iso.string(from: calendar.start))
            fields.append("Scheduled end: " + iso.string(from: calendar.end))
        }
        if let start = session.recordedStart {
            fields.append("Local session started: " + iso.string(from: start))
            if let zone = session.timeZone { fields.append("Local session time zone: " + zone) }
        }
        if !live.participantNames.isEmpty {
            let names = live.participantNames.prefix(16).map { String($0.prefix(64)) }
            fields.append("Present participants: " + names.joined(separator: ", "))
        }
        guard !fields.isEmpty else { return nil }
        let text = fields.joined(separator: "\n")
        return .init(id: ParticipationSource.meetingMetadataID, title: "Current meeting details", text: text, revision: digest(text))
    }

    static func noteGuidance(_ markdown: String, excerpt: String?) -> String? {
        guard let head = bounded(markdown, 4_000) else { return nil }
        guard markdown.count > 4_000 else { return head }
        var sections = [head]
        if let excerpt, !head.contains(excerpt.trimmed) { sections.append(excerpt.trimmed) }
        let tail = String(markdown.suffix(1_000)).trimmed
        if !tail.isEmpty, !sections.contains(where: { $0.contains(tail) }) { sections.append(tail) }
        return sections.joined(separator: "\n\n")
    }

    /// The preset's About field can also supply literal evidence for a fact.
    static func meetingInfoSource(_ about: String?) -> ParticipationSource? {
        guard let text = bounded(about, 900) else { return nil }
        return .init(id: "meeting-info", title: "Meeting info", text: text, revision: digest(text))
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func bounded(_ value: String?, _ count: Int) -> String? {
        guard let text = value?.trimmed, !text.isEmpty else { return nil }
        return String(text.prefix(count))
    }
}
