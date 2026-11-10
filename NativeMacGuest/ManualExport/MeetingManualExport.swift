import Foundation

enum MeetingManualExportError: LocalizedError {
    case cancelled

    var errorDescription: String? { L("The export was cancelled.") }
}

struct MeetingManualExportItem: Identifiable {
    var id: UUID { session.id }
    var session: MeetingSessionRecord
    var note: MeetingNoteRecord?
    var outcome: MeetingOutcome?
    var outcomeState: MeetingOutcomePersistenceState
    /// True when the local note commit failed and this is an unsaved in-memory draft.
    var isUnsavedDraft: Bool
}

struct MeetingManualExportResult {
    var saved: [UUID]
    var failed: [(id: UUID, error: String)]
    var cancelled: Bool
}

/// Offline single/batch Markdown export. Renders from a flushed local snapshot and
/// writes files the user picked; it never touches the automatic outbox or bindings.
enum MeetingManualExport {
    /// Renders one meeting file with the same template Obsidian uses, without markers.
    static func render(item: MeetingManualExportItem) -> String {
        let frontmatter = MeetingMarkdownTemplate.frontmatter(
            session: item.session, note: item.note, outcome: item.outcome,
            outcomeState: item.outcomeState, exportRevision: item.session.exportRevision)
        let body = MeetingMarkdownTemplate.managedContent(
            session: item.session, note: item.note, outcome: item.outcome, outcomeState: item.outcomeState)
        var text = frontmatter + "\n\n" + body + "\n"
        if item.isUnsavedDraft {
            text += "\n> " + L("Unsaved draft: the local note had not finished saving when this file was written.") + "\n"
        }
        return text
    }

    /// Combined in-memory worklog over several meetings, chronological with a
    /// session-ID tie break. Batch files are plain Markdown; no managed markers.
    static func renderWorklog(items: [MeetingManualExportItem]) -> String {
        let ordered = items.sorted { lhs, rhs in
            if lhs.session.startedAt != rhs.session.startedAt { return lhs.session.startedAt < rhs.session.startedAt }
            return lhs.session.id.uuidString < rhs.session.id.uuidString
        }
        var parts = ["# " + L("Meeting worklog"),
            "",
            ISO8601DateFormatter().string(from: Date()),
            ""]
        for item in ordered {
            parts.append(render(item: item))
            parts.append("\n---\n")
        }
        return parts.joined(separator: "\n")
    }

    /// Unique-ifies a file name inside `directory`, preferring "Name 2.md", "Name 3.md"…
    static func uniqueURL(directory: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(index).\(ext)")
            index += 1
        }
        return candidate
    }
}
