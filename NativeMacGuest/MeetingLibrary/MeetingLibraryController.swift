import Foundation

enum MeetingNoteSaveStatus: Equatable {
    case saved(Date)
    case saving
    case failed(String)
}

/// MainActor catalog of persisted meetings: cards, notes status, outcome states.
/// All repository calls cross to the actor-owned store; the UI never touches SQLite.
@MainActor final class MeetingLibraryController: ObservableObject {
    let store: MeetingLibraryStore
    let workspaceJournal: MeetingWorkspaceJournal
    let participationVaultConnection = ParticipationVaultConnection()
    @Published private(set) var cards: [MeetingLibraryCard] = []
    @Published private(set) var noteStatus: [UUID: MeetingNoteSaveStatus] = [:]
    @Published private(set) var persistenceError: String?
    private var refreshTask: Task<Void, Never>?

    init(root: URL) {
        store = MeetingLibraryStore(root: root)
        workspaceJournal = MeetingWorkspaceJournal(root: root)
        workspaceJournal.prepare()
    }

    /// Opens (and creates if needed) the database, then loads the first snapshot.
    func prepare() async {
        do {
            try await store.prepare()
            let interrupted = try await store.failInterruptedGenerations()
            if interrupted > 0 { probeLog("meeting-library-interrupted-generations", ["count": interrupted]) }
            await refresh()
        } catch {
            persistenceError = MeetingLibraryError.persistenceFailed(error.localizedDescription).localizedDescription
        }
    }

    var isReady: Bool { persistenceError == nil }

    /// Deterministic teardown for tests and app shutdown; the underlying store
    /// reopens on the next `prepare()` if the controller is used again.
    func close() async { await store.close(); workspaceJournal.close() }

    /// Sessions visible to Assistant/history. Failed joins with no content are excluded
    /// by the store's card query.
    func refresh() async {
        do { cards = try await store.cards() }
        catch { persistenceError = error.localizedDescription }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            await self.refresh()
        }
    }

    // MARK: Sessions

    @discardableResult
    func createSession(id: UUID, title: String, invitation: URL?, roomIdentity: String,
                       calendarSeriesID: String?, startedAt: Date = Date()) async -> MeetingSessionRecord? {
        let record = MeetingSessionRecord(id: id, title: title, invitation: invitation,
            roomIdentity: roomIdentity, calendarSeriesID: calendarSeriesID, startedAt: startedAt, state: .joining)
        do {
            try await store.upsertSession(record)
            scheduleRefresh()
            return record
        } catch {
            persistenceError = error.localizedDescription
            return nil
        }
    }

    func markSessionConnected(_ id: UUID) {
        Task { [store] in _ = try? await store.updateSession(id, state: .active); await refresh() }
    }

    func markSessionFailed(_ id: UUID) {
        Task { [store] in _ = try? await store.updateSession(id, state: .failed); await refresh() }
    }

    func endSession(_ id: UUID, endedAt: Date = Date(), awaitingOutcome: Bool) async {
        do {
            try await store.endSession(id, at: endedAt, awaitingOutcome: awaitingOutcome)
            await refresh()
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    func saveInObsidian(_ id: UUID) async throws {
        try await store.saveInObsidian(id)
    }

    func renameSession(_ id: UUID, title: String) async throws {
        try await store.renameSession(id, title: title)
        workspaceJournal.rename(sessionID: id, title: title.trimmingCharacters(in: .whitespacesAndNewlines))
        await refresh()
    }

    // MARK: Notes

    /// Commits a note revision. The store raises the aggregate export revision and
    /// enqueues outbox rows in the same transaction.
    @discardableResult
    func saveNote(sessionID: UUID, markdown: String) async -> Result<MeetingLibraryNoteCommit, Error> {
        noteStatus[sessionID] = .saving
        do {
            let commit = try await store.saveNote(sessionID: sessionID, markdown: markdown)
            noteStatus[sessionID] = .saved(commit.updatedAt)
            persistenceError = nil
            scheduleRefresh()
            return .success(commit)
        } catch {
            noteStatus[sessionID] = .failed(error.localizedDescription)
            persistenceError = error.localizedDescription
            return .failure(error)
        }
    }

    func note(sessionID: UUID) async -> MeetingNoteRecord? {
        try? await store.note(sessionID)
    }

    func searchNotes(query: String, from: Date? = nil, to: Date? = nil, limit: Int = 20) async -> [MeetingNoteSearchResult] {
        (try? await store.searchNotes(query: query, from: from, to: to, limit: limit)) ?? []
    }

    // MARK: Outcomes

    func addOutcome(_ outcome: MeetingOutcome, state: MeetingOutcomePersistenceState = .ready) async {
        do {
            _ = try await store.saveOutcome(outcome, state: state)
            persistenceError = nil
            scheduleRefresh()
        } catch { persistenceError = error.localizedDescription }
    }

    func setOutcomeState(_ outcomeID: UUID, state: MeetingOutcomePersistenceState,
                         generationOwner: String? = nil, errorCode: String? = nil) {
        Task { [store] in
            guard var outcome = try? await store.outcome(outcomeID) else { return }
            do {
                _ = try await store.saveOutcome(outcome, state: state, generationOwner: generationOwner, errorCode: errorCode)
                outcome = outcome
            } catch { }
            await refresh()
        }
    }

    /// Awaitable (no inner fire-and-forget task): AttentionStore tracks and drains
    /// the calling task before closing the store at teardown.
    func removeOutcome(_ outcomeID: UUID) async {
        try? await store.removeOutcome(outcomeID)
        await refresh()
    }

    func outcomeState(_ outcomeID: UUID) async -> MeetingOutcomePersistenceState? {
        try? await store.outcomeState(outcomeID)
    }

    func outcome(sessionID: UUID) async -> MeetingOutcome? {
        try? await store.outcomeBySession(sessionID)
    }

    func deleteAll() async {
        do {
            try await store.deleteAll()
            noteStatus.removeAll()
            await refresh()
        } catch { persistenceError = error.localizedDescription }
    }
}
