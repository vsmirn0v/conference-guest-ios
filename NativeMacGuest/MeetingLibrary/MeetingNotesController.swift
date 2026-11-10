import Foundation

/// Per-session note draft with debounced, generation-fenced commits.
/// 500 ms after typing stops the draft commits; while typing continues without a
/// pause, a commit runs at least once per second. A completion for generation N can
/// never mark generation N+1 saved.
@MainActor final class MeetingNotesController: ObservableObject {
    struct Draft: Equatable {
        var text: String
        var generation: Int
        var lastChangeAt: Date
        var lastCommitAttemptAt: Date?
        var savedText: String?
        var saveError: String?
    }

    struct EditorState: Equatable {
        var selection: NSRange?
        var scrollPoint: NSPoint?
    }

    static let debounce: TimeInterval = 0.5
    static let maxContinuousInterval: TimeInterval = 1.0

    let library: MeetingLibraryController
    private var drafts: [UUID: Draft] = [:]
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var editorStates: [UUID: EditorState] = [:]

    init(library: MeetingLibraryController) {
        self.library = library
    }

    func draft(sessionID: UUID) -> Draft? { drafts[sessionID] }

    func buffer(sessionID: UUID) -> String {
        drafts[sessionID]?.text ?? ""
    }

    /// Adopts an already-committed note (e.g. loaded from the repository) without
    /// marking the session dirty.
    func hydrate(sessionID: UUID, text: String) {
        guard drafts[sessionID] == nil else { return }
        drafts[sessionID] = Draft(text: text, generation: 0, lastChangeAt: .distantPast,
            lastCommitAttemptAt: nil, savedText: text, saveError: nil)
    }

    /// Records an editor change and schedules the next commit.
    func update(sessionID: UUID, text: String, at now: Date = Date()) {
        var draft = drafts[sessionID] ?? Draft(text: "", generation: 0, lastChangeAt: now,
            lastCommitAttemptAt: nil, savedText: nil, saveError: nil)
        draft.text = text
        draft.generation += 1
        draft.lastChangeAt = now
        drafts[sessionID] = draft
        scheduleCommit(sessionID: sessionID, generation: draft.generation, now: now)
    }

    private func scheduleCommit(sessionID: UUID, generation: Int, now: Date) {
        pending[sessionID]?.cancel()
        let continuousOverdue: Bool
        if let last = drafts[sessionID]?.lastCommitAttemptAt {
            continuousOverdue = now.timeIntervalSince(last) >= Self.maxContinuousInterval
        } else {
            continuousOverdue = false
        }
        let delay = continuousOverdue ? 0.0 : Self.debounce
        pending[sessionID] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
            guard let self, !Task.isCancelled else { return }
            await self.commit(sessionID: sessionID, generation: generation)
        }
    }

    /// Commits the draft at invocation time, bypassing the debounce.
    @discardableResult
    func flush(sessionID: UUID) async -> Bool {
        pending[sessionID]?.cancel()
        let generation = drafts[sessionID]?.generation ?? 0
        return await commit(sessionID: sessionID, generation: generation)
    }

    /// Flushes every dirty draft. Called on Quit before termination may finish.
    func flushAll() async {
        pending.values.forEach { $0.cancel() }
        for sessionID in drafts.keys where drafts[sessionID]?.saveError == nil || drafts[sessionID]?.text != drafts[sessionID]?.savedText {
            _ = await commit(sessionID: sessionID, generation: drafts[sessionID]?.generation ?? 0)
        }
    }

    @discardableResult
    private func commit(sessionID: UUID, generation: Int) async -> Bool {
        guard var draft = drafts[sessionID], draft.generation == generation else { return false }
        draft.lastCommitAttemptAt = Date()
        drafts[sessionID] = draft
        let text = draft.text
        let result = await library.saveNote(sessionID: sessionID, markdown: text)
        switch result {
        case .success:
            guard var current = drafts[sessionID], current.generation == generation else { return false }
            current.savedText = text
            current.saveError = nil
            drafts[sessionID] = current
            return true
        case .failure(let error):
            guard var current = drafts[sessionID], current.generation == generation else { return false }
            current.saveError = error.localizedDescription
            drafts[sessionID] = current
            return false
        }
    }

    func editorState(sessionID: UUID) -> EditorState { editorStates[sessionID] ?? EditorState() }

    func setEditorState(sessionID: UUID, selection: NSRange?, scrollPoint: NSPoint?) {
        editorStates[sessionID] = EditorState(selection: selection, scrollPoint: scrollPoint)
    }

    func discard(sessionID: UUID) {
        pending[sessionID]?.cancel()
        pending[sessionID] = nil
        drafts[sessionID] = nil
        editorStates[sessionID] = nil
    }
}
