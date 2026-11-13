import Combine
import Foundation

/// One source buffer and one editing lease for each meeting session.
@MainActor final class MeetingNotesController: ObservableObject {
    struct Draft: Equatable {
        var text: String
        var generation = 0
        var savedText: String?
        var savedGeneration = 0
        var revision: Int?
        var firstDirtyAt: Date?
        var saveError: String?

        var isDirty: Bool { generation != savedGeneration }
    }

    struct EditorState: Equatable {
        var selection: NSRange?
        var scrollPoint: NSPoint?
    }

    struct Editor {
        let relinquish: () -> Bool
        let focus: () -> Void
        var commitComposition: () -> Void = {}
    }

    enum HistoryAction {
        case undo, redo
    }

    private struct Edit {
        let location: Int
        let removed: String
        let inserted: String
        let selectionBefore: NSRange
        let selectionAfter: NSRange
    }

    private struct EditHistory {
        var undo: [Edit] = []
        var redo: [Edit] = []
    }

    static let debounce: TimeInterval = 0.5
    static let maxContinuousInterval: TimeInterval = 1.0

    let library: MeetingLibraryController
    @Published private var drafts: [UUID: Draft] = [:]
    @Published private var leases: [UUID: UUID] = [:]
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var committing: [UUID: Task<Bool, Never>] = [:]
    private var loading: [UUID: Task<Void, Never>] = [:]
    private var editors: [UUID: Editor] = [:]
    private var editorSessions: [UUID: UUID] = [:]
    private var editorStates: [UUID: EditorState] = [:]
    private var editHistory: [UUID: EditHistory] = [:]
    private(set) lazy var windows = MeetingNotesWindows(notes: self)

    init(library: MeetingLibraryController) {
        self.library = library
    }

    func draft(sessionID: UUID) -> Draft? { drafts[sessionID] }
    func participationDraftChanges(sessionID: UUID) -> AnyPublisher<Void, Never> {
        $drafts.map { $0[sessionID]?.text }.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
    }
    func buffer(sessionID: UUID) -> String { drafts[sessionID]?.text ?? "" }
    func editorOwner(sessionID: UUID) -> UUID? { leases[sessionID] }

    func registerEditor(_ id: UUID, sessionID: UUID, editor: Editor) {
        editors[id] = editor
        editorSessions[id] = sessionID
    }

    func hasEditor(sessionID: UUID) -> Bool { editorSessions.values.contains(sessionID) }

    func unregisterEditor(_ id: UUID, sessionID: UUID) {
        editors[id] = nil
        editorSessions[id] = nil
        if leases[sessionID] == id { leases[sessionID] = nil }
    }

    @discardableResult
    func claimEditor(_ id: UUID, sessionID: UUID) -> Bool {
        guard drafts[sessionID]?.savedText != nil else { return false }
        if let owner = leases[sessionID], owner != id,
           editors[owner]?.relinquish() == false { return false }
        if leases[sessionID] != id { leases[sessionID] = id }
        return true
    }

    func focusEditor(sessionID: UUID) {
        if let owner = leases[sessionID] { editors[owner]?.focus() }
    }

    func load(sessionID: UUID) async {
        if drafts[sessionID]?.savedText != nil { return }
        if let task = loading[sessionID] { await task.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { loading[sessionID] = nil }
            do {
                let record = try await library.store.note(sessionID)
                guard !Task.isCancelled, drafts[sessionID]?.isDirty != true else { return }
                hydrate(sessionID: sessionID, text: record?.markdown ?? "", revision: record?.revision ?? 0)
            } catch {
                guard !Task.isCancelled, drafts[sessionID]?.isDirty != true else { return }
                drafts[sessionID] = Draft(text: "", saveError: error.localizedDescription)
            }
        }
        loading[sessionID] = task
        await task.value
    }

    func hydrate(sessionID: UUID, text: String, revision: Int? = nil) {
        guard drafts[sessionID]?.savedText == nil, drafts[sessionID]?.isDirty != true else { return }
        drafts[sessionID] = Draft(text: text, savedText: text, revision: revision)
    }

    /// Applies an AppKit UTF-16 edit only to the generation the editor displayed.
    func replace(sessionID: UUID, editorID: UUID, generation: Int, range: NSRange,
                 with replacement: String, selectionBefore: NSRange? = nil, selectionAfter: NSRange? = nil) -> Int? {
        guard leases[sessionID] == editorID, let draft = drafts[sessionID],
              draft.generation == generation, range.location <= draft.text.utf16.count,
              range.length <= draft.text.utf16.count - range.location else { return nil }
        let source = draft.text as NSString
        let removed = source.substring(with: range)
        guard !removed.utf16.elementsEqual(replacement.utf16) else { return draft.generation }

        let edit = Edit(location: range.location, removed: removed, inserted: replacement,
            selectionBefore: selectionBefore ?? range,
            selectionAfter: selectionAfter ?? NSRange(location: range.location + replacement.utf16.count, length: 0))
        editHistory[sessionID, default: EditHistory()].undo.append(edit)
        editHistory[sessionID]?.redo.removeAll()
        storeDraft(sessionID: sessionID, text: source.replacingCharacters(in: range, with: replacement), at: Date())
        return drafts[sessionID]?.generation
    }

    func canPerformHistory(_ action: HistoryAction, sessionID: UUID, editorID: UUID) -> Bool {
        guard leases[sessionID] == editorID, let history = editHistory[sessionID] else { return false }
        return action == .undo ? !history.undo.isEmpty : !history.redo.isEmpty
    }

    @discardableResult
    func performHistory(_ action: HistoryAction, sessionID: UUID, editorID: UUID) -> NSRange? {
        guard leases[sessionID] == editorID, let draft = drafts[sessionID],
              var history = editHistory[sessionID] else { return nil }
        let undo = action == .undo
        guard let edit = undo ? history.undo.popLast() : history.redo.popLast() else { return nil }
        let expected = undo ? edit.inserted : edit.removed
        let replacement = undo ? edit.removed : edit.inserted
        let selection = undo ? edit.selectionBefore : edit.selectionAfter
        let source = draft.text as NSString
        let range = NSRange(location: edit.location, length: expected.utf16.count)
        guard range.upperBound <= source.length, source.substring(with: range).utf16.elementsEqual(expected.utf16) else {
            editHistory[sessionID] = nil
            return nil
        }

        if undo { history.redo.append(edit) } else { history.undo.append(edit) }
        editHistory[sessionID] = history
        editorStates[sessionID, default: EditorState()].selection = selection
        storeDraft(sessionID: sessionID, text: source.replacingCharacters(in: range, with: replacement), at: Date())
        return selection
    }

    func update(sessionID: UUID, text: String, at now: Date = Date()) {
        guard !buffer(sessionID: sessionID).utf16.elementsEqual(text.utf16) else { return }
        editHistory[sessionID] = nil
        storeDraft(sessionID: sessionID, text: text, at: now)
    }

    private func storeDraft(sessionID: UUID, text: String, at now: Date) {
        var draft = drafts[sessionID] ?? Draft(text: "")
        draft.text = text
        draft.generation += 1
        draft.firstDirtyAt = draft.firstDirtyAt ?? now
        drafts[sessionID] = draft
        scheduleCommit(sessionID: sessionID, now: now)
    }

    private func scheduleCommit(sessionID: UUID, now: Date) {
        pending[sessionID]?.cancel()
        guard let dirtySince = drafts[sessionID]?.firstDirtyAt else { return }
        let deadline = min(now.addingTimeInterval(Self.debounce),
                           dirtySince.addingTimeInterval(Self.maxContinuousInterval))
        pending[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSince(now))))
            guard let self, !Task.isCancelled else { return }
            pending[sessionID] = nil
            _ = await commit(sessionID: sessionID)
        }
    }

    /// Commits through the newest generation, including edits made during an in-flight commit.
    @discardableResult
    func flush(sessionID: UUID) async -> Bool {
        if let owner = leases[sessionID] { editors[owner]?.commitComposition() }
        pending.removeValue(forKey: sessionID)?.cancel()
        while drafts[sessionID]?.isDirty == true || committing[sessionID] != nil {
            guard await commit(sessionID: sessionID) else { return false }
            pending.removeValue(forKey: sessionID)?.cancel()
        }
        return true
    }

    @discardableResult
    func flushAll() async -> [UUID] {
        var failed: [UUID] = []
        for sessionID in Array(drafts.keys) {
            if !(await flush(sessionID: sessionID)) { failed.append(sessionID) }
        }
        return failed
    }

    private func commit(sessionID: UUID) async -> Bool {
        if let task = committing[sessionID] { return await task.value }
        guard var draft = drafts[sessionID], draft.isDirty else { return true }
        draft.firstDirtyAt = nil
        drafts[sessionID] = draft
        let captured = draft
        let task = Task { [weak self] in
            guard let self else { return false }
            defer { committing[sessionID] = nil }
            let result = await library.saveNote(sessionID: sessionID, markdown: captured.text)
            guard var current = drafts[sessionID] else { return false }
            switch result {
            case .success(let commit):
                current.savedGeneration = captured.generation
                current.savedText = captured.text
                current.revision = commit.revision
                current.saveError = nil
            case .failure(let error):
                current.saveError = error.localizedDescription
            }
            drafts[sessionID] = current
            if current.generation != captured.generation, pending[sessionID] == nil {
                scheduleCommit(sessionID: sessionID, now: Date())
            }
            return current.saveError == nil
        }
        committing[sessionID] = task
        return await task.value
    }

    func editorState(sessionID: UUID) -> EditorState { editorStates[sessionID] ?? EditorState() }

    func setEditorState(sessionID: UUID, selection: NSRange?, scrollPoint: NSPoint?) {
        editorStates[sessionID] = EditorState(selection: selection, scrollPoint: scrollPoint)
    }

    func discard(sessionID: UUID) {
        pending.removeValue(forKey: sessionID)?.cancel()
        loading.removeValue(forKey: sessionID)?.cancel()
        drafts[sessionID] = nil
        editorStates[sessionID] = nil
        editHistory[sessionID] = nil
    }
}
