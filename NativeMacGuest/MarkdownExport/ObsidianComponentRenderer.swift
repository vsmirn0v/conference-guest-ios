import Foundation

enum ObsidianComponentRenderer {
    static func relativePath(for component: ObsidianExportComponent, destination: ObsidianDestinationRecord,
                             snapshot: ObsidianExportSnapshot) -> String {
        if component == .meeting {
            let name = MeetingMarkdownTemplate.meetingFileName(title: snapshot.session.title, sessionID: snapshot.session.id)
            return destination.meetingFolder.isEmpty ? name : destination.meetingFolder + "/" + name
        }
        let path = destination.layout.documentPath
        guard destination.layout.monthly else { return path }
        let date = dayKey(for: snapshot.session, timeZoneID: destination.layout.timeZoneID)
        let suffix = date == "unknown" ? "unknown-date" : String(date.prefix(7))
        let base = (path as NSString).deletingPathExtension
        return base + " " + suffix + ".md"
    }

    static func patch(existing: String, binding: ObsidianExportBindingRecord, destination: ObsidianDestinationRecord,
                      snapshot: ObsidianExportSnapshot, meetingRelativePath: String?,
                      fileExists: Bool = false) throws -> MarkdownFilePatcher.PatchResult {
        guard let nonce = binding.markerID else { throw ObsidianExportError.markerDamage("The export binding has no marker identity.") }
        let layout = destination.layout
        let session = snapshot.session
        let content: String
        switch binding.component {
        case .meeting, .worklog:
            let shared = binding.component == .worklog
            let heading = shared ? (layout.groupByDay ? 4 : 3) : 1
            content = MeetingMarkdownTemplate.managedContent(session: session, note: snapshot.note, outcome: snapshot.outcome,
                outcomeState: snapshot.outcomeState, sections: layout.sections, headingLevel: heading,
                boldTitle: shared && layout.runtimeStyle)
        case .index:
            guard let meetingRelativePath else {
                throw ObsidianExportError.placementConflict("The index requires a delivered meeting file.")
            }
            content = indexEntry(snapshot, meetingPath: meetingRelativePath, indexPath: binding.relativePath, sections: layout.sections)
        }
        if existing.isEmpty, binding.lastExportedRevision > 0 {
            throw ObsidianExportError.markerDamage("The previously exported file is missing or empty.")
        }
        let metadata = binding.component == .meeting ? MeetingMarkdownTemplate.frontmatter(session: session,
            note: snapshot.note, outcome: snapshot.outcome, outcomeState: snapshot.outcomeState,
            exportRevision: session.exportRevision) : nil
        if existing.isEmpty, !fileExists, let metadata {
            var result = MarkdownFilePatcher.create(sessionID: session.id, nonce: nonce, frontmatter: metadata, managedContent: content)
            result.metadataSHA256 = try ObsidianOwnedMetadata.hash(in: metadata)
            return result
        }
        let structure = MarkdownStructureScanner.scan(existing)
        let existingBlock = structure.managedBlocks.contains {
            $0.markers.sessionID == session.id && $0.markers.component == binding.component
        }
        let placement: ObsidianWorklogPlacement.Insertion?
        if existingBlock || binding.component == .meeting {
            placement = nil
        } else {
            placement = try ObsidianWorklogPlacement.insertion(in: existing, structure: structure,
                component: binding.component, dateKey: dayKey(for: session, timeZoneID: layout.timeZoneID), layout: layout,
                relativePath: binding.relativePath)
        }
        let expected = binding.lastBlockSHA256 ?? (existingBlock ? MarkdownFilePatcher.sha256(content) : nil)
        var result = try MarkdownFilePatcher.patch(existing: existing, sessionID: session.id, nonce: nonce,
            component: binding.component, managedContent: content, expectedBlockSHA256: expected,
            insertionByteOffset: placement?.offset, insertionHeader: placement?.heading)
        if let metadata {
            var previous = binding.lastMetadataSHA256
            if previous == nil, binding.metadataOwnershipEvaluated != true, let fileHash = binding.lastFileSHA256,
               fileHash == MarkdownFilePatcher.sha256(existing),
               try ObsidianOwnedMetadata.ownsLegacyFrontmatter(existing, sessionID: session.id) {
                previous = try ObsidianOwnedMetadata.hash(in: existing)
            }
            if let previous {
                let (updated, metadataHash) = try ObsidianOwnedMetadata.replacing(in: result.text, generated: metadata, expected: previous)
                result.text = updated
                result.fileSHA256 = MarkdownFilePatcher.sha256(updated)
                result.metadataSHA256 = metadataHash
            }
        }
        return result
    }

    static func dayKey(for session: MeetingSessionRecord, timeZoneID: String) -> String {
        let date = session.effectiveDate?.date
        guard let date else { return "unknown" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)!
        let pieces = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", pieces.year ?? 0, pieces.month ?? 0, pieces.day ?? 0)
    }

    private static func indexEntry(_ snapshot: ObsidianExportSnapshot, meetingPath: String,
                                   indexPath: String, sections: MeetingMarkdownSections) -> String {
        let title = snapshot.session.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let path = relativeLink(from: indexPath, to: meetingPath)
        let open = snapshot.outcome?.tasks.filter { !$0.done }.count ?? 0
        let label = "- [\(title)](\(path)) · " + L("Open tasks: %ld", open)
        guard sections.contains(.summary) else { return label }
        let summary: String
        switch snapshot.outcomeState {
        case .pending: summary = L("Preparing outcome…")
        case .failed: summary = L("The outcome could not be generated.")
        case .notStarted: summary = L("No outcome for this meeting.")
        case .ready, .draft: summary = snapshot.outcome?.summary ?? ""
        }
        let brief = summary.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(240)
        return brief.isEmpty ? label : label + "\n  " + brief
    }

    private static func relativeLink(from indexPath: String, to meetingPath: String) -> String {
        let indexParent = indexPath.split(separator: "/").dropLast()
        let meeting = meetingPath.split(separator: "/")
        let common = zip(indexParent, meeting).prefix { $0 == $1 }.count
        let link = (Array(repeating: "..", count: indexParent.count - common) + meeting.dropFirst(common).map(String.init))
            .joined(separator: "/")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        return link.addingPercentEncoding(withAllowedCharacters: allowed) ?? link
    }
}

enum ObsidianWorklogPlacement {
    struct Insertion {
        let offset: Int
        var heading: String?
    }

    struct LegacyRuntimeDay: Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let lineNumber: Int
        let context: String?
        let day: Int
        let month: Int

        func dateKey(year: Int) -> String? {
            guard (1...9999).contains(year) else { return nil }
            let key = String(format: "%04d-%02d-%02d", year, month, day)
            return ObsidianWorklogPlacement.validDay(key) ? key : nil
        }
    }

    private struct DayHeading {
        let line: Int
        let contentLine: Int
        let fullDate: String?
        var shortDate: (day: Int, month: Int)?
    }

    private struct Workspace {
        let bodyStart: Int
        let bodyEnd: Int
        let eligible: [Int]
        let managedLines: Set<Int>
    }

    static func insertion(in source: String, structure: MarkdownStructureScanner.Structure,
                          component: ObsidianExportComponent, dateKey: String,
                          layout: ObsidianExportLayout, relativePath: String? = nil) throws -> Insertion {
        let work = try workspace(structure, layout: layout)
        let start = work.bodyStart
        let end = work.bodyEnd
        let lines = structure.lines
        func offset(_ line: Int) -> Int { line < lines.count ? lines[line].byteStart : source.utf8.count }
        guard layout.groupByDay else {
            let managed = structure.managedBlocks.first {
                $0.markers.component == component && $0.beginLine >= start && $0.endLine < end
            }
            if layout.insertAtBeginning, layout.startAfter == nil, managed == nil,
               work.eligible.contains(where: { (start..<end).contains($0) && !lines[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                throw ObsidianExportError.placementConflict("Choose the beginning of the work area in the format preview.")
            }
            let first = layout.startAfter != nil ? start : managed?.beginLine ?? end
            return Insertion(offset: offset(layout.insertAtBeginning ? first : end))
        }

        let headings = try dayHeadings(in: work, lines: lines, runtimeStyle: layout.runtimeStyle)
        let legacy = legacyDays(from: headings, in: work, lines: lines)
        let years = layout.legacyRuntimeYears?[relativePath ?? layout.documentPath] ?? [:]
        var dateKeys: [String] = []
        for heading in headings {
            if let date = heading.fullDate {
                dateKeys.append(date)
                continue
            }
            guard let section = legacy[heading.line], let year = years[section.id] else {
                throw ObsidianExportError.placementConflict("Confirm each existing day’s year in the format preview.")
            }
            guard let date = section.dateKey(year: year) else {
                throw ObsidianExportError.placementConflict("An existing day is invalid in its confirmed year.")
            }
            dateKeys.append(date)
        }
        guard Set(dateKeys).count == dateKeys.count else {
            throw ObsidianExportError.placementConflict("More than one section has the same full date.")
        }
        if let index = dateKeys.firstIndex(of: dateKey) {
            let boundary = index + 1 < headings.count ? headings[index + 1].line : end
            return Insertion(offset: offset(layout.withinDayAtBeginning ? headings[index].contentLine : boundary))
        }
        let next = dateKeys.firstIndex { isBefore(dateKey, $0, newestFirst: layout.newestDaysFirst) }
            .map { headings[$0].line } ?? end
        let headingText = "### " + heading(for: dateKey, runtime: layout.runtimeStyle) + "\n<!-- rnr:day \(dateKey) -->"
        return Insertion(offset: offset(next), heading: headingText)
    }

    static func legacyRuntimeDays(in structure: MarkdownStructureScanner.Structure,
                                  layout: ObsidianExportLayout) throws -> [LegacyRuntimeDay] {
        guard layout.groupByDay, layout.runtimeStyle else { return [] }
        let work = try workspace(structure, layout: layout)
        let headings = try dayHeadings(in: work, lines: structure.lines, runtimeStyle: true)
        return legacyDays(from: headings, in: work, lines: structure.lines).values.sorted {
            $0.lineNumber < $1.lineNumber
        }
    }

    private static func workspace(_ structure: MarkdownStructureScanner.Structure,
                                  layout: ObsidianExportLayout) throws -> Workspace {
        if let error = structure.markerAmbiguity { throw ObsidianExportError.markerDamage(error) }
        let lines = structure.lines
        var managedLines: Set<Int> = []
        for block in structure.managedBlocks { managedLines.formUnion(block.beginLine...block.endLine) }
        var hidden = managedLines
        for range in structure.codeRanges { hidden.formUnion(range) }
        let firstBodyLine = structure.hasFrontmatter
            ? ((lines.indices.dropFirst().first { ["---", "..."].contains(lines[$0].text) } ?? 0) + 1)
            : 0
        let eligible = lines.indices.filter { $0 >= firstBodyLine && !hidden.contains($0) }

        func anchor(_ line: String?) throws -> Int? {
            guard let line, !line.isEmpty else { return nil }
            let matches = eligible.filter { lines[$0].text == line }
            guard matches.count == 1 else {
                throw ObsidianExportError.placementConflict("A configured workspace boundary is missing or duplicated.")
            }
            return matches.first
        }

        let start = try anchor(layout.startAfter).map { $0 + 1 } ?? firstBodyLine
        let end = try anchor(layout.endBefore) ?? lines.count
        guard start <= end else { throw ObsidianExportError.placementConflict("The workspace boundaries are reversed.") }
        return Workspace(bodyStart: start, bodyEnd: end, eligible: eligible, managedLines: managedLines)
    }

    private static func dayHeadings(in work: Workspace, lines: [MarkdownStructureScanner.Line],
                                    runtimeStyle: Bool) throws -> [DayHeading] {
        let eligibleSet = Set(work.eligible)
        return try work.eligible.filter { (work.bodyStart..<work.bodyEnd).contains($0) }.compactMap { line in
            guard lines[line].text.hasPrefix("### ") else { return nil }
            let title = String(lines[line].text.dropFirst(4))
            let following = line + 1
            if following < work.bodyEnd, eligibleSet.contains(following),
               let key = markedDay(lines[following].text) {
                guard heading(for: key, runtime: true) == title || title == key ||
                        (key == "unknown" && !title.isEmpty) else {
                    throw ObsidianExportError.placementConflict("A date marker disagrees with its heading.")
                }
                return DayHeading(line: line, contentLine: following + 1, fullDate: key)
            }
            if validDay(title) { return DayHeading(line: line, contentLine: following, fullDate: title) }
            guard runtimeStyle, let (day, month) = shortDay(title) else { return nil }
            return DayHeading(line: line, contentLine: following, fullDate: nil, shortDate: (day, month))
        }
    }

    private static func legacyDays(from headings: [DayHeading], in work: Workspace,
                                   lines: [MarkdownStructureScanner.Line]) -> [Int: LegacyRuntimeDay] {
        let originals = headings.enumerated().compactMap { index, heading -> (DayHeading, String, String?)? in
            guard heading.shortDate != nil else { return nil }
            let end = index + 1 < headings.count ? headings[index + 1].line : work.bodyEnd
            let manual = (heading.contentLine..<end).compactMap { line -> String? in
                let content = lines[line].text
                guard !work.managedLines.contains(line),
                      !content.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return content
            }
            let signature = MarkdownFilePatcher.sha256(([lines[heading.line].text] + manual).joined(separator: "\n"))
            return (heading, signature, manual.first.map { String($0.prefix(140)) })
        }
        var counts: [String: Int] = [:]
        for (_, signature, _) in originals { counts[signature, default: 0] += 1 }
        var occurrences: [String: Int] = [:]
        var result: [Int: LegacyRuntimeDay] = [:]
        for (heading, signature, context) in originals {
            guard let date = heading.shortDate else { continue }
            occurrences[signature, default: 0] += 1
            // Identical source sections are distinguishable only within the same
            // duplicate set. A change to that set invalidates every old confirmation.
            let id = "\(signature)/\(counts[signature, default: 0])/\(occurrences[signature, default: 0])"
            result[heading.line] = LegacyRuntimeDay(id: id, title: String(lines[heading.line].text.dropFirst(4)),
                lineNumber: heading.line + 1, context: context, day: date.day, month: date.month)
        }
        return result
    }

    private static func isBefore(_ left: String, _ right: String, newestFirst: Bool) -> Bool {
        if left == "unknown" { return false }
        if right == "unknown" { return true }
        return newestFirst ? left > right : left < right
    }

    private static func heading(for key: String, runtime: Bool) -> String {
        guard key != "unknown" else { return L("Date unknown") }
        guard runtime, let components = MeetingOutcomeTask.dayComponents(key),
              let day = components.day, let month = components.month else { return key }
        return "\(day).\(String(format: "%02d", month))"
    }

    private static func markedDay(_ line: String) -> String? {
        let prefix = "<!-- rnr:day "
        guard line.hasPrefix(prefix), line.hasSuffix(" -->") else { return nil }
        let key = String(line.dropFirst(prefix.count).dropLast(4))
        return validDay(key) || key == "unknown" ? key : nil
    }

    private static func validDay(_ date: String) -> Bool {
        MeetingOutcomeTask.dayComponents(date) != nil
    }

    private static func shortDay(_ label: String) -> (Int, Int)? {
        let fields = label.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 2, (1...2).contains(fields[0].count), (1...2).contains(fields[1].count),
              let day = Int(fields[0]), let month = Int(fields[1]), (1...31).contains(day), (1...12).contains(month) else { return nil }
        return (day, month)
    }
}
