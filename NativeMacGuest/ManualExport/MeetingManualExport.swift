import Darwin
import Foundation

struct MeetingManualExportItem: Identifiable, Sendable {
    var id: UUID { session.id }
    var session: MeetingSessionRecord
    var note: MeetingNoteRecord?
    var outcome: MeetingOutcome?
    var outcomeState: MeetingOutcomePersistenceState
    var isUnsavedDraft: Bool

    var effectiveDate: Date? {
        session.effectiveDate?.date
    }
}

enum MeetingManualExportFormat: String, CaseIterable, Identifiable, Sendable {
    case files, worklog, filesWithIndex
    var id: Self { self }
}

struct MeetingManualExportOptions: Sendable {
    var format: MeetingManualExportFormat = .files
    var sections: MeetingMarkdownSections = .all
    var byMonth = false
    var groupByDay = false
    var newestDaysFirst = false
    var newestMeetingsFirst = false
    var calendar = Calendar.current
}

struct MeetingManualExportFileResult: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let url: URL?
    let error: String?
}

/// Independent local export uses a snapshot plus current drafts. It creates
/// new files only and leaves the automatic export state alone.
enum MeetingManualExport {
    static func render(item: MeetingManualExportItem, sections: MeetingMarkdownSections = .all) -> String {
        let frontmatter = MeetingMarkdownTemplate.frontmatter(
            session: item.session, note: item.note, outcome: item.outcome,
            outcomeState: item.outcomeState, exportRevision: item.session.exportRevision)
        return frontmatter + "\n\n" + renderBody(item, sections: sections, heading: 1) + "\n"
    }

    static func renderWorklog(items: [MeetingManualExportItem], options: MeetingManualExportOptions = .init()) -> String {
        let ordered = items.sorted { left, right in
            let leftDay = left.effectiveDate.map(options.calendar.startOfDay(for:))
            let rightDay = right.effectiveDate.map(options.calendar.startOfDay(for:))
            if options.groupByDay, leftDay != rightDay {
                return orderedBefore(leftDay, rightDay, newestFirst: options.newestDaysFirst)
            }
            if left.effectiveDate != right.effectiveDate {
                return orderedBefore(left.effectiveDate, right.effectiveDate, newestFirst: options.newestMeetingsFirst)
            }
            return left.id.uuidString < right.id.uuidString
        }
        var parts = ["# " + L("Meeting worklog")]
        var lastDay: Date?
        for (index, item) in ordered.enumerated() {
            let day = item.effectiveDate.map(options.calendar.startOfDay(for:))
            if options.groupByDay, index == 0 || day != lastDay {
                parts += ["", "## " + (day.map { $0.formatted(date: .complete, time: .omitted) } ?? L("Date unknown"))]
            }
            if !options.groupByDay {
                parts += ["", item.effectiveDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? L("Date unknown")]
            }
            parts += ["", renderBody(item, sections: options.sections, heading: options.groupByDay ? 3 : 2), "\n---"]
            lastDay = day
        }
        return parts.joined(separator: "\n") + "\n"
    }

    static func periodIncludes(_ date: Date?, from: Date, through: Date, calendar: Calendar) -> Bool {
        let start = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: through)
        guard let date, last >= start, let end = calendar.date(byAdding: .day, value: 1, to: last) else { return false }
        return date >= start && date < end
    }

    static func write(items: [MeetingManualExportItem], directory: URL,
                      options: MeetingManualExportOptions) -> [MeetingManualExportFileResult] {
        var results: [MeetingManualExportFileResult] = []
        var written: [UUID: URL] = [:]
        if options.format != .worklog {
            for item in items {
                let name = MeetingMarkdownTemplate.meetingFileName(title: item.session.title, sessionID: item.id)
                let result = save(render(item: item, sections: options.sections), name: name, directory: directory)
                results.append(result)
                written[item.id] = result.url
            }
        }
        if options.format != .files {
            let groups = Dictionary(grouping: items) { item in
                options.byMonth ? monthKey(item.effectiveDate, calendar: options.calendar) : ""
            }
            for (month, meetings) in groups.sorted(by: { $0.key < $1.key }) {
                let suffix = month.isEmpty ? "" : " " + month
                switch options.format {
                case .files:
                    break
                case .worklog:
                    results.append(save(renderWorklog(items: meetings, options: options),
                                        name: "Meeting worklog" + suffix + ".md", directory: directory))
                case .filesWithIndex:
                    let rows = meetings.compactMap { meeting in written[meeting.id].map { (meeting, $0) } }
                    guard !rows.isEmpty else { continue }
                    results.append(save(renderIndex(rows, sections: options.sections),
                                        name: "Meeting index" + suffix + ".md", directory: directory))
                }
            }
        }
        return results
    }

    static func renderIndex(_ rows: [(MeetingManualExportItem, URL)], sections: MeetingMarkdownSections) -> String {
        var lines = ["# " + L("Meeting index"), ""]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        for (item, url) in rows {
            let title = item.session.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            let path = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: allowed) ?? url.lastPathComponent
            let count = item.outcome?.tasks.filter { !$0.done }.count ?? 0
            lines.append("- [\(title)](\(path)) · " + L("Open tasks: %ld", count))
            if (item.outcomeState == .ready || item.outcomeState == .draft),
               sections.contains(.summary), let summary = item.outcome?.summary, !summary.isEmpty {
                lines.append("  " + String(summary.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(240)))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func uniqueURL(directory: URL, fileName: String) -> URL {
        var index = 1
        var url = candidate(directory: directory, fileName: fileName, index: index)
        while FileManager.default.fileExists(atPath: url.path) {
            index += 1
            url = candidate(directory: directory, fileName: fileName, index: index)
        }
        return url
    }

    /// The exclusive rename is the authoritative collision check, including files
    /// and dangling symlinks created by another process after rendering.
    static func writeUnique(_ text: String, name: String, directory: URL) throws -> URL {
        let stage = directory.appendingPathComponent(".rocknroll-export-\(UUID().uuidString)")
        try Data(text.utf8).write(to: stage, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: stage) }
        var index = 1
        while true {
            let target = candidate(directory: directory, fileName: name, index: index)
            if renamex_np(stage.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            let failure = errno
            guard failure == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure), userInfo: [NSFilePathErrorKey: target.path])
            }
            index += 1
        }
    }

    private static func renderBody(_ item: MeetingManualExportItem, sections: MeetingMarkdownSections, heading: Int) -> String {
        let body = MeetingMarkdownTemplate.managedContent(session: item.session, note: item.note, outcome: item.outcome,
            outcomeState: item.outcomeState, sections: sections, headingLevel: heading)
        guard item.isUnsavedDraft, sections.contains(.notes) else { return body }
        return body + "\n\n> " + L("Unsaved draft: the local note had not finished saving when this file was written.")
    }

    private static func orderedBefore(_ left: Date?, _ right: Date?, newestFirst: Bool) -> Bool {
        guard let left else { return false }
        guard let right else { return true }
        return newestFirst ? left > right : left < right
    }

    private static func monthKey(_ date: Date?, calendar: Calendar) -> String {
        guard let date else { return "unknown-date" }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let components = gregorian.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    private static func candidate(directory: URL, fileName: String, index: Int) -> URL {
        guard index > 1 else { return directory.appendingPathComponent(fileName) }
        let base = (fileName as NSString).deletingPathExtension
        return directory.appendingPathComponent("\(base) \(index).md")
    }

    private static func save(_ text: String, name: String, directory: URL) -> MeetingManualExportFileResult {
        do {
            let url = try writeUnique(text, name: name, directory: directory)
            return .init(name: url.lastPathComponent, url: url, error: nil)
        } catch {
            return .init(name: name, url: nil, error: error.localizedDescription)
        }
    }
}
