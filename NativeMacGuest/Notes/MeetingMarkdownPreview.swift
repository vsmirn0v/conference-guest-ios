import AppKit

/// Foundation's CommonMark parser supplies source positions in the original source.
enum MeetingMarkdownPreview {
    struct Line: Equatable {
        var range: NSRange
        var spans: [Span] = []
        var heading: Int?
        var quote = false
        var code = false
        var table = false
        var tableHeader = false
        var tableDelimiter = false
        var tableGroup: Int?
        var tableRow: TableRow?
        var rule = false
        var checklist: NSRange?
    }

    struct TableCell: Equatable {
        var range: NSRange
        var trailingPipe: Int?
    }

    struct TableRow: Equatable {
        var leadingPipe: Int?
        var cells: [TableCell]

        var dividerIndices: [Int] { [leadingPipe].compactMap { $0 } + cells.compactMap(\.trailingPipe) }

        mutating func shift(by delta: Int) {
            leadingPipe = leadingPipe.map { $0 + delta }
            for index in cells.indices {
                cells[index].range.location += delta
                cells[index].trailingPipe = cells[index].trailingPipe.map { $0 + delta }
            }
        }
    }

    struct Span: Equatable {
        var range: NSRange
        var style: Style
    }

    enum Style: Equatable {
        case bold, italic, strike, code, link, syntax, listMarker, checked, unchecked
    }

    /// Markdown source columns are 1-based UTF-8 offsets. Pre-index the document
    /// once so a run near the end is no more expensive to map than the first run.
    struct SourceOffsets {
        private var lines = [0]
        private var units: [Int] = []

        init(_ markdown: String) {
            units.reserveCapacity(markdown.utf8.count + 1)
            var byteIndex = 0
            var utf16Index = 0
            var precedingCR = false
            for scalar in markdown.unicodeScalars {
                let value = scalar.value
                let width = value < 0x80 ? 1 : value < 0x800 ? 2 : value < 0x10000 ? 3 : 4
                for _ in 0..<width { units.append(utf16Index) }
                byteIndex += width
                utf16Index += value < 0x10000 ? 1 : 2
                if value == 13 || value == 10 && !precedingCR {
                    lines.append(byteIndex)
                } else if value == 10 {
                    lines[lines.count - 1] = byteIndex
                }
                precedingCR = value == 13
            }
            units.append(utf16Index)
        }

        func range(_ position: AttributedString.MarkdownSourcePosition) -> NSRange? {
            guard let first = index(line: position.startLine, column: position.startColumn),
                  let last = index(line: position.endLine, column: position.endColumn), first <= last else { return nil }
            var end = last + 1
            while end < units.count && units[end] == units[last] { end += 1 }
            guard end < units.count else { return nil }
            return NSRange(location: units[first], length: units[end] - units[first])
        }

        private func index(line: Int, column: Int) -> Int? {
            guard line > 0, line <= lines.count, column > 0 else { return nil }
            let start = lines[line - 1]
            let end = line < lines.count ? lines[line] : units.count - 1
            guard column <= end - start else { return nil }
            return start + column - 1
        }
    }

    /// Foundation can assign later runs to the wrong source line after a
    /// backslash hard break. Parse a same-length shadow with those breaks
    /// converted to soft breaks; neither the displayed nor saved source changes.
    /// Escaped backslashes are left alone. ASCII substitution preserves both
    /// UTF-8 columns and UTF-16 offsets, including for surrounding Unicode.
    static func previewSource(_ markdown: String) -> String {
        guard markdown.utf8.contains(92) else { return markdown }
        var bytes = Array(markdown.utf8)
        var slashCount = 0
        for index in bytes.indices {
            if bytes[index] == 92 {
                slashCount += 1
                continue
            }
            if (bytes[index] == 10 || bytes[index] == 13), !slashCount.isMultiple(of: 2) {
                bytes[index - 1] = 32
            }
            slashCount = 0
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Only use shadow positions when it parses to the same presentation.
    /// Backslashes in code or link definitions are not necessarily hard breaks.
    private static func equivalentPresentation(_ original: AttributedString, _ shadow: AttributedString) -> Bool {
        let first = Array(original.runs), second = Array(shadow.runs)
        guard first.count == second.count else { return false }
        let breaks: InlinePresentationIntent = [.lineBreak, .softBreak]
        return first.indices.allSatisfy { index in
            let lhs = first[index], rhs = second[index]
            let leftIntent = lhs.inlinePresentationIntent ?? []
            let rightIntent = rhs.inlinePresentationIntent ?? []
            guard leftIntent.subtracting(breaks) == rightIntent.subtracting(breaks),
                  lhs.presentationIntent == rhs.presentationIntent, lhs.link == rhs.link else { return false }
            let left = String(original[lhs.range].characters)
            let right = String(shadow[rhs.range].characters)
            if !leftIntent.intersection(breaks).isEmpty && !rightIntent.intersection(breaks).isEmpty {
                return true
            }
            let codeBlock = lhs.presentationIntent?.components.contains {
                if case .codeBlock = $0.kind { return true }; return false
            } == true
            if leftIntent.contains(.code) || codeBlock {
                let originalScalars = Array(left.unicodeScalars), shadowScalars = Array(right.unicodeScalars)
                return originalScalars.count == shadowScalars.count && zip(originalScalars, shadowScalars).allSatisfy { first, second in
                    first == second || (first.value == 92 && second.value == 32)
                }
            }
            if index + 1 < first.count,
               !(first[index + 1].inlinePresentationIntent ?? []).intersection(breaks).isEmpty,
               !(second[index + 1].inlinePresentationIntent ?? []).intersection(breaks).isEmpty {
                return left.reversed().drop(while: { $0 == " " || $0 == "\t" })
                    .elementsEqual(right.reversed().drop(while: { $0 == " " || $0 == "\t" }))
            }
            return left == right
        }
    }

    static func lines(in input: String) -> [Line] {
        // NSTextView supplies an NSString-backed Swift value. Foundation resolves
        // each parser position against UTF-8, so repeated offset lookup needs native
        // contiguous storage instead of traversing the bridged text for each run.
        var markdown = input
        markdown.makeContiguousUTF8()
        let source = markdown as NSString
        guard source.length > 0 else { return [] }
        let options = AttributedString.MarkdownParsingOptions(appliesSourcePositionAttributes: true)
        guard let original = try? AttributedString(markdown: markdown, options: options) else { return [] }
        var shadowSource = previewSource(markdown)
        var parsed = original
        if !shadowSource.utf8.elementsEqual(markdown.utf8) {
            if let shadow = try? AttributedString(markdown: shadowSource, options: options),
               equivalentPresentation(original, shadow) {
                parsed = shadow
            } else {
                // A literal backslash in a code span or reference definition can
                // change parsing semantics. Keep safe substitutions elsewhere,
                // splitting rejected groups with a bounded amount of extra work.
                let bytes = Array(markdown.utf8), proposed = Array(shadowSource.utf8)
                let changes = bytes.indices.filter { bytes[$0] != proposed[$0] }
                var accepted = bytes
                var budget = bytes.count > 100_000 ? 4 : 12
                func consider(_ group: ArraySlice<Int>) {
                    guard !group.isEmpty, budget > 0, !Task.isCancelled else { return }
                    budget -= 1
                    var candidate = accepted
                    for index in group { candidate[index] = proposed[index] }
                    let text = String(decoding: candidate, as: UTF8.self)
                    if let result = try? AttributedString(markdown: text, options: options),
                       equivalentPresentation(original, result) {
                        accepted = candidate
                        parsed = result
                    } else if group.count > 1 {
                        let middle = group.index(group.startIndex, offsetBy: group.count / 2)
                        consider(group[..<middle])
                        consider(group[middle...])
                    }
                }
                if changes.count > 1 {
                    let middle = changes.count / 2
                    consider(changes[..<middle])
                    consider(changes[middle...])
                }
                shadowSource = String(decoding: accepted, as: UTF8.self)
            }
        }
        let usingShadow = !shadowSource.utf8.elementsEqual(markdown.utf8)
        let shadow = shadowSource as NSString
        let offsets = SourceOffsets(markdown)
        var lines: [Int: Line] = [:]
        var tableRows: [Int: Set<Int>] = [:]
        var ruleCount = 0
        var lastSourceEnd = 0
        for run in parsed.runs {
            if Task.isCancelled { return [] }
            let components = run.presentationIntent?.components ?? []
            // Foundation can report positions outside the source for intermediate
            // edits. Its Range initializer may trap on those positions, so only
            // use the bounds-checked mapping and leave invalid runs unstyled.
            guard let position = run.markdownSourcePosition,
                  let range = offsets.range(position),
                  range.location <= source.length, range.length <= source.length - range.location else {
                if components.contains(where: { if case .thematicBreak = $0.kind { return true }; return false }) {
                    ruleCount += 1
                }
                continue
            }
            if ruleCount > 0 {
                addRules(source, from: lastSourceEnd, to: range.location, count: ruleCount, into: &lines)
                ruleCount = 0
            }
            lastSourceEnd = max(lastSourceEnd, NSMaxRange(range))
            let codeBlock = components.contains { if case .codeBlock = $0.kind { return true }; return false }
            var location = range.location
            repeat {
                let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
                guard lineRange.length > 0 else { break }
                var line = lines[lineRange.location] ?? Line(range: lineRange)
                let firstRun = lines[lineRange.location] == nil
                if codeBlock {
                    line.code = true
                } else {
                    for component in components {
                        switch component.kind {
                        case .header(let level): line.heading = level
                        case .blockQuote: line.quote = true
                        case .table:
                            line.table = true
                            line.tableGroup = component.identity
                            tableRows[component.identity, default: []].insert(lineRange.location)
                        case .tableHeaderRow: line.tableHeader = true
                        default: break
                        }
                    }
                    if firstRun {
                        let prefix = NSRange(location: lineRange.location, length: max(0, range.location - lineRange.location))
                        let marker = source.substring(with: prefix)
                        if line.heading != nil, let markup = marker.range(of: #"^[ \t]*#{1,6}[ \t]+"#, options: .regularExpression) {
                            let syntax = NSRange(markup, in: marker)
                            line.spans.append(Span(range: NSRange(location: prefix.location, length: syntax.length), style: .syntax))
                        } else if line.quote {
                            line.spans.append(Span(range: prefix, style: .listMarker))
                        }
                        let listItem = components.contains { if case .listItem = $0.kind { return true }; return false }
                        if listItem {
                            styleList(source, prefix: prefix, content: range, into: &line, marker: marker)
                        }
                    }
                    var content = NSIntersectionRange(range, lineRange)
                    let inline = run.inlinePresentationIntent ?? []
                    // The shadow's replacement space may be included in an
                    // otherwise styled run. The original backslash is syntax.
                    if usingShadow, !inline.contains(.code), content.length > 0,
                       content.upperBound < source.length,
                       [10, 13].contains(source.character(at: content.upperBound)),
                       source.character(at: content.upperBound - 1) == 92,
                       shadow.character(at: content.upperBound - 1) == 32 {
                        content.length -= 1
                    }
                    if inline.contains(.code) {
                        line.spans.append(Span(range: content, style: .code))
                        hideDelimiters(in: source, around: content, on: lineRange, marker: "`", into: &line)
                    } else {
                        for (intent, style, marker): (InlinePresentationIntent, Style, String) in [
                            (.stronglyEmphasized, .bold, "**"), (.emphasized, .italic, "*"),
                            (.strikethrough, .strike, "~~")
                        ] where inline.contains(intent) {
                            line.spans.append(Span(range: content, style: style))
                            hideDelimiters(in: source, around: content, on: lineRange, marker: marker, into: &line)
                            if marker.first == "*" {
                                hideDelimiters(in: source, around: content, on: lineRange,
                                               marker: marker.replacingOccurrences(of: "*", with: "_"), into: &line)
                            }
                        }
                        if run.link != nil {
                            line.spans.append(Span(range: content, style: .link))
                            hideLink(in: source, around: content, on: lineRange, into: &line)
                        }
                    }
                }
                if line.code || line.table || line.quote || line.heading != nil || !line.spans.isEmpty {
                    lines[lineRange.location] = line
                }
                location = NSMaxRange(lineRange)
            } while location < NSMaxRange(range)
        }
        if ruleCount > 0 { addRules(source, from: lastSourceEnd, to: source.length, count: ruleCount, into: &lines) }
        for (group, rows) in tableRows { identifyTableRows(in: source, group: group, rows: rows, lines: &lines) }
        return lines.values.sorted { $0.range.location < $1.range.location }
    }

    /// Locate source cells; TextKit measures their actual styled glyph advances on the main actor.
    private static func identifyTableRows(in source: NSString, group: Int, rows: Set<Int>, lines: inout [Int: Line]) {
        for location in rows.sorted() {
            guard var row = lines[location] else { continue }
            var contentEnd = NSMaxRange(row.range)
            source.getLineStart(nil, end: nil, contentsEnd: &contentEnd, for: NSRange(location: location, length: 0))
            var pipes: [Int] = []
            var escapeCount = 0
            for index in location..<contentEnd {
                let unit = source.character(at: index)
                if unit == 92 { escapeCount += 1; continue }
                defer { escapeCount = 0 }
                guard unit == 124 else { continue }
                if escapeCount.isMultiple(of: 2) {
                    pipes.append(index)
                } else {
                    row.spans.append(Span(range: NSRange(location: index - 1, length: 1), style: .syntax))
                }
            }

            func onlyWhitespace(from first: Int, to last: Int) -> Bool {
                (first..<last).allSatisfy { [9, 32].contains(source.character(at: $0)) }
            }

            var leadingPipe: Int?
            if let first = pipes.first, onlyWhitespace(from: location, to: first) {
                leadingPipe = pipes.removeFirst()
            }
            let trailingPipe = pipes.last.map { onlyWhitespace(from: $0 + 1, to: contentEnd) } ?? false
            var start = leadingPipe.map { $0 + 1 } ?? location
            var cells = pipes.map { pipe in
                defer { start = pipe + 1 }
                return TableCell(range: NSRange(location: start, length: pipe - start), trailingPipe: pipe)
            }
            if !trailingPipe {
                cells.append(TableCell(range: NSRange(location: start, length: contentEnd - start), trailingPipe: nil))
            }
            row.tableRow = TableRow(leadingPipe: leadingPipe, cells: cells)
            lines[location] = row

            let next = NSMaxRange(row.range)
            if row.tableHeader, next < source.length, lines[next] == nil {
                let separator = source.lineRange(for: NSRange(location: next, length: 0))
                lines[next] = Line(range: separator, tableDelimiter: true, tableGroup: group)
            }
        }
    }

    private static func styleList(_ source: NSString, prefix: NSRange, content: NSRange,
                                  into line: inout Line, marker: String) {
        guard marker.range(of: #"^[ \t>]*([-+*]|[0-9]{1,9}[.)])[ \t]+$"#, options: .regularExpression) != nil else { return }
        line.spans.append(Span(range: prefix, style: .listMarker))
        guard NSMaxRange(content) - content.location >= 3 else { return }
        let checkbox = NSRange(location: content.location, length: 3)
        let mark = source.substring(with: checkbox).lowercased()
        guard mark == "[ ]" || mark == "[x]" else { return }
        let next = NSMaxRange(checkbox)
        guard next == source.length || [9, 10, 13, 32].contains(source.character(at: next)) else { return }
        line.checklist = NSRange(location: checkbox.location + 1, length: 1)
        line.spans.append(Span(range: checkbox, style: mark == "[x]" ? .checked : .unchecked))
    }

    private static func hideDelimiters(in source: NSString, around content: NSRange, on lineRange: NSRange,
                                       marker: String, into line: inout Line) {
        let count = marker.utf16.count
        let after = NSRange(location: NSMaxRange(content), length: count)
        if content.location - count >= lineRange.location {
            let before = NSRange(location: content.location - count, length: count)
            if source.substring(with: before) == marker {
                line.spans.append(Span(range: before, style: .syntax))
            }
        }
        if NSMaxRange(after) <= NSMaxRange(lineRange), source.substring(with: after) == marker {
            line.spans.append(Span(range: after, style: .syntax))
        }
    }

    private static func hideLink(in source: NSString, around content: NSRange, on lineRange: NSRange, into line: inout Line) {
        guard content.location > lineRange.location, source.character(at: content.location - 1) == 91 else { return }
        let end = NSMaxRange(content)
        guard end + 2 < NSMaxRange(lineRange), source.substring(with: NSRange(location: end, length: 2)) == "](" else { return }
        let tail = NSRange(location: end + 2, length: NSMaxRange(lineRange) - end - 2)
        // Retain source for destinations with nested delimiters.
        let destination = source.range(of: #"^[^()\r\n]*\)"#, options: .regularExpression, range: tail)
        guard destination.location != NSNotFound else { return }
        line.spans.append(Span(range: NSRange(location: content.location - 1, length: 1), style: .syntax))
        line.spans.append(Span(range: NSRange(location: end, length: destination.length + 2), style: .syntax))
    }

    private static func addRules(_ source: NSString, from start: Int, to end: Int, count: Int, into lines: inout [Int: Line]) {
        var cursor = start
        var remaining = count
        while cursor < end, remaining > 0 {
            let line = source.lineRange(for: NSRange(location: cursor, length: 0))
            let text = source.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.range(of: #"^(?:\*[ \t]*){3,}$|^(?:-[ \t]*){3,}$|^(?:_[ \t]*){3,}$"#, options: .regularExpression) != nil,
               lines[line.location] == nil {
                lines[line.location] = Line(range: line, rule: true)
                remaining -= 1
            }
            cursor = NSMaxRange(line)
        }
    }
}
