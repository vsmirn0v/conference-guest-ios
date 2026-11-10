import AppKit
import Foundation

/// MainActor manual-export flow: flush → snapshot → pick destination → write with
/// visible per-file results. Cancellation stops between files; failures are reported
/// and only failed items can be retried. No Obsidian state changes.
@MainActor final class MeetingManualExportController: ObservableObject {
    @Published private(set) var exporting = false
    @Published private(set) var lastResult: MeetingManualExportResult?

    private let library: MeetingLibraryController
    private let notes: MeetingNotesController

    init(library: MeetingLibraryController, notes: MeetingNotesController) {
        self.library = library
        self.notes = notes
    }

    /// Flushes drafts and builds the export items for the given sessions.
    func makeItems(sessionIDs: [UUID]) async -> [MeetingManualExportItem] {
        await notes.flushAll()
        var items: [MeetingManualExportItem] = []
        for id in sessionIDs {
            guard let session = try? await library.store.session(id) else { continue }
            let note = await library.note(sessionID: id)
            let outcome = await library.outcome(sessionID: id)
            var outcomeState: MeetingOutcomePersistenceState = .notStarted
            if let outcome {
                outcomeState = (try? await library.store.outcomeState(outcome.id)) ?? .ready
            }
            let draft = notes.draft(sessionID: id)
            let unsaved = draft?.saveError != nil || (draft != nil && draft?.savedText != draft?.text)
            items.append(MeetingManualExportItem(
                session: session, note: note, outcome: outcome,
                outcomeState: outcomeState,
                isUnsavedDraft: unsaved))
        }
        return items
    }

    /// Single-meeting save panel export.
    func exportSingle(item: MeetingManualExportItem) async -> MeetingManualExportResult {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MeetingMarkdownTemplate.meetingFileName(
            title: item.session.title, sessionID: item.session.id)
        panel.allowedContentTypes = [.init(filenameExtension: "md")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else {
            return MeetingManualExportResult(saved: [], failed: [], cancelled: true)
        }
        return write(items: [item], to: [item.session.id: url])
    }

    /// Batch export into one folder, one file per meeting, with the visible unique-name rule.
    func exportBatch(items: [MeetingManualExportItem]) async -> MeetingManualExportResult {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Export")
        guard panel.runModal() == .OK, let directory = panel.url else {
            return MeetingManualExportResult(saved: [], failed: [], cancelled: true)
        }
        var targets: [UUID: URL] = [:]
        for item in items {
            let name = MeetingMarkdownTemplate.meetingFileName(title: item.session.title, sessionID: item.session.id)
            targets[item.session.id] = MeetingManualExport.uniqueURL(directory: directory, fileName: name)
        }
        return write(items: items, to: targets)
    }

    private func write(items: [MeetingManualExportItem], to targets: [UUID: URL]) -> MeetingManualExportResult {
        exporting = true
        defer { exporting = false }
        var saved: [UUID] = []
        var failed: [(id: UUID, error: String)] = []
        for item in items {
            guard let url = targets[item.session.id] else { continue }
            do {
                let text = MeetingManualExport.render(item: item)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url, options: .atomic)
                saved.append(item.session.id)
            } catch {
                failed.append((item.session.id, error.localizedDescription))
            }
        }
        let result = MeetingManualExportResult(saved: saved, failed: failed, cancelled: false)
        lastResult = result
        return result
    }
}
