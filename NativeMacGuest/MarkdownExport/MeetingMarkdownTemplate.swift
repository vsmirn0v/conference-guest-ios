import Foundation

struct MeetingMarkdownSections: OptionSet, Codable, Sendable {
    let rawValue: Int

    static let notes = Self(rawValue: 1 << 0)
    static let summary = Self(rawValue: 1 << 1)
    static let decisions = Self(rawValue: 1 << 2)
    static let tasks = Self(rawValue: 1 << 3)
    static let questions = Self(rawValue: 1 << 4)
    static let all: Self = [.notes, .summary, .decisions, .tasks, .questions]
}

/// Fixed Markdown templates. Raw local notes are never normalized: the template wraps
/// them but cannot drop or rewrite unsupported syntax. Explicit states for empty and
/// pending outcomes; schema version and revisions travel with every export.
enum MeetingMarkdownTemplate {
    static let schemaVersion = 1

    /// Flat YAML encoding without a dependency; strings use JSON-compatible quoting.
    static func yamlValue(_ value: String) -> String {
        // JSON strings are valid YAML double-quoted scalars. Always quote to
        // preserve text such as booleans, dates and titles containing colons.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let bytes = try? encoder.encode(value), let encoded = String(data: bytes, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }

    static func frontmatter(session: MeetingSessionRecord, note: MeetingNoteRecord?,
                            outcome: MeetingOutcome?, outcomeState: MeetingOutcomePersistenceState,
                            exportRevision: Int) -> String {
        var lines = ["---",
            "schema_version: \(schemaVersion)",
            "meeting_id: \"\(session.id.uuidString)\"",
            "title: \(yamlValue(session.title))",
            "time_zone: \(yamlValue(session.timeZoneID))",
            "export_revision: \(exportRevision)",
            "note_revision: \(note?.revision ?? 0)",
            "outcome_state: \(outcomeState.rawValue)"]
        if let start = session.recordedStart {
            lines.append("started_at: \(ISO8601DateFormatter().string(from: start))")
        }
        if let ended = session.knownEnd {
            lines.append("ended_at: \(ISO8601DateFormatter().string(from: ended))")
        }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// The managed body: raw note verbatim, then outcome sections with explicit
    /// empty/pending states. Section headings are stable for both locales.
    static func managedContent(session: MeetingSessionRecord, note: MeetingNoteRecord?,
                               outcome: MeetingOutcome?, outcomeState: MeetingOutcomePersistenceState,
                               sections: MeetingMarkdownSections = .all, headingLevel: Int = 1,
                               boldTitle: Bool = false) -> String {
        let heading = String(repeating: "#", count: headingLevel)
        var parts = [boldTitle ? "**" + session.title + "**" : heading + " " + session.title]
        if sections.contains(.notes) {
            parts += ["", heading + "# Notes"]
            if let note, !note.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(MarkdownStructureScanner.closingTrailingFence(in: note.markdown))
            } else {
                parts.append("_No notes for this meeting._")
            }
        }
        if !sections.subtracting(.notes).isEmpty {
            parts += ["", heading + "# Outcome"]
            switch outcomeState {
            case .notStarted:
                parts.append("_No outcome for this meeting._")
            case .pending:
                parts.append("_The meeting outcome is being prepared…_")
            case .failed:
                parts.append("_The meeting outcome could not be generated. Retry it in Rock’N’Roll for Mac._")
            case .draft, .ready:
                if let outcome {
                    if sections.contains(.summary) {
                        parts.append(outcome.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "_No summary._" : MarkdownStructureScanner.closingTrailingFence(in: outcome.summary))
                    }
                    if sections.contains(.decisions), !outcome.decisions.isEmpty {
                        parts += ["", heading + "## Decisions", outcome.decisions.map { "- " + $0 }.joined(separator: "\n")]
                    }
                    if sections.contains(.tasks), !outcome.tasks.isEmpty {
                        parts += ["", heading + "## Tasks", outcome.tasks.map { task in
                            "- [" + (task.done ? "x" : " ") + "] " + task.text +
                                (task.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " — " + task.owner)
                        }.joined(separator: "\n")]
                    }
                    if sections.contains(.questions), !outcome.openQuestions.isEmpty {
                        parts += ["", heading + "## Open questions", outcome.openQuestions.map { "- " + $0 }.joined(separator: "\n")]
                    }
                } else {
                    parts.append("_No outcome for this meeting._")
                }
            }
        }
        return MarkdownStructureScanner.closingTrailingFence(in: parts.joined(separator: "\n"))
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
