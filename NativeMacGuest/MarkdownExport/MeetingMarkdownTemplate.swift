import Foundation

/// Fixed Markdown templates. Raw local notes are never normalized: the template wraps
/// them but cannot drop or rewrite unsupported syntax. Explicit states for empty and
/// pending outcomes; schema version and revisions travel with every export.
enum MeetingMarkdownTemplate {
    static let schemaVersion = 1

    /// Flat YAML encoding without a dependency: strings are quoted or plain-scalar
    /// only when safe; everything else is double-quoted with escapes.
    static func yamlValue(_ value: String) -> String {
        let safe = value.allSatisfy { character in
            character.isLetter || character.isNumber || [" ", "-", "_", ".", ":", "+", "@", "(", ")"].contains(character)
        } && !value.hasPrefix(" ") && !value.hasSuffix(" ") && !value.isEmpty
        if safe, let first = value.first, !"!&*?{}[],#|>@`\"'%".contains(first) { return value }
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    static func frontmatter(session: MeetingSessionRecord, note: MeetingNoteRecord?,
                            outcome: MeetingOutcome?, outcomeState: MeetingOutcomePersistenceState,
                            exportRevision: Int) -> String {
        var lines = ["---",
            "schema_version: \(schemaVersion)",
            "meeting_id: \"\(session.id.uuidString)\"",
            "title: \(yamlValue(session.title))",
            "started_at: \(ISO8601DateFormatter().string(from: session.startedAt))",
            "time_zone: \(yamlValue(session.timeZoneID))",
            "export_revision: \(exportRevision)",
            "note_revision: \(note?.revision ?? 0)",
            "outcome_state: \(outcomeState.rawValue)"]
        if let ended = session.endedAt {
            lines.append("ended_at: \(ISO8601DateFormatter().string(from: ended))")
        }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// The managed body: raw note verbatim, then outcome sections with explicit
    /// empty/pending states. Section headings are stable for both locales.
    static func managedContent(session: MeetingSessionRecord, note: MeetingNoteRecord?,
                               outcome: MeetingOutcome?, outcomeState: MeetingOutcomePersistenceState) -> String {
        var parts: [String] = []
        parts.append("# " + session.title)
        parts.append("")
        parts.append("## Notes")
        if let note, !note.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(note.markdown)
        } else {
            parts.append("_No notes for this meeting._")
        }
        parts.append("")
        parts.append("## Outcome")
        switch outcomeState {
        case .pending, .notStarted:
            parts.append("_The meeting outcome is being prepared…_")
        case .failed:
            parts.append("_The meeting outcome could not be generated. Retry it in Rock’N’Roll for Mac._")
        case .draft, .ready:
            if let outcome {
                parts.append(outcome.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "_No summary._" : outcome.summary)
                if !outcome.decisions.isEmpty {
                    parts.append("")
                    parts.append("### Decisions")
                    parts.append(outcome.decisions.map { "- " + $0 }.joined(separator: "\n"))
                }
                if !outcome.tasks.isEmpty {
                    parts.append("")
                    parts.append("### Tasks")
                    parts.append(outcome.tasks.map { task in
                        "- [" + (task.done ? "x" : " ") + "] " + task.text +
                            (task.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " — " + task.owner)
                    }.joined(separator: "\n"))
                }
                if !outcome.openQuestions.isEmpty {
                    parts.append("")
                    parts.append("### Open questions")
                    parts.append(outcome.openQuestions.map { "- " + $0 }.joined(separator: "\n"))
                }
            } else {
                parts.append("_No outcome for this meeting._")
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Sanitized, collision-resistant file name for a meeting. The name derives from
    /// the title plus a stable session prefix; title changes never move the file once
    /// a binding exists.
    static func meetingFileName(title: String, sessionID: UUID) -> String {
        let cleaned = title.components(separatedBy: CharacterSet.alphanumerics.inverted.union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }.joined(separator: " ")
        let base = cleaned.isEmpty ? "Meeting" : String(cleaned.prefix(60))
        return "\(base) \(String(sessionID.uuidString.prefix(8))).md"
    }
}
