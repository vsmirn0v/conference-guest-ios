import Foundation

/// App-owned, byte-oriented Markdown structure scanner for export patching.
/// Recognizes frontmatter (file start only), fenced code, indented code, block quotes,
/// comments and exact managed markers. Anything ambiguous fails closed — the caller
/// reports a typed conflict instead of guessing a patch. The document never round-trips
/// through a preview AST.
enum MarkdownStructureScanner {
    struct Line {
        var text: String
        var byteStart: Int
        var byteEnd: Int
    }

    struct Structure {
        var lines: [Line]
        var hasFrontmatter: Bool
        /// Line ranges (inclusive) inside fenced or indented code where markers are not structural.
        var codeRanges: [ClosedRange<Int>]
        var unterminatedFence: String?
        /// Recognized managed-marker lines paired by begin/end.
        var managedBlocks: [ManagedBlock.Block]
        /// Marker grammar appeared somewhere it cannot be trusted (nested, duplicated
        /// or mismatched); the caller must refuse to patch.
        var markerAmbiguity: String?
    }

    static func scan(_ text: String) -> Structure {
        var lines: [Line] = []
        var byteOffset = 0
        for raw in text.components(separatedBy: "\n") {
            var line = raw
            while line.hasSuffix("\r") { line.removeLast() }
            let bytes = raw.utf8.count
            lines.append(Line(text: line, byteStart: byteOffset, byteEnd: byteOffset + bytes))
            byteOffset += bytes + 1
        }
        if text.isEmpty { lines = [] }

        // Frontmatter is recognized only at the very start of the file.
        var hasFrontmatter = false
        if lines.first?.text == "---", lines.count > 1 {
            let close = lines.indices.first { index in
                index > 0 && (lines[index].text == "---" || lines[index].text == "...")
            }
            if let close, close > 1 { hasFrontmatter = true }
        }

        // Fenced code: toggle on ```/~~~ fences (at least three, allowing the rest of the line).
        var codeRanges: [ClosedRange<Int>] = []
        var fenceStart: Int? = nil
        var fenceCharacter: Character?
        var fenceLength = 0
        for (index, line) in lines.enumerated() {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            let first = trimmed.first
            let isFenceCharacter = first == "`" || first == "~"
            let run = isFenceCharacter ? trimmed.prefix(while: { $0 == first }).count : 0
            let isFence = run >= 3
            if fenceStart == nil {
                if isFence, hasFrontmatter ? index > 0 : true {
                    fenceCharacter = first
                    fenceLength = run
                    fenceStart = index
                } else if !trimmed.isEmpty && !trimmed.hasPrefix(">") && !trimmed.hasPrefix("#") &&
                            !trimmed.hasPrefix("-") && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("|") {
                    // Indented code block: 4+ spaces and not a list/quote/heading/table continuation.
                    let leading = line.text.prefix(while: { $0 == " " }).count
                    if leading >= 4 { codeRanges.append(index...index) }
                }
            } else {
                if first == fenceCharacter && run >= fenceLength && trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty {
                    codeRanges.append(fenceStart!...index)
                    fenceStart = nil
                }
            }
        }
        let unterminatedFence: String?
        if let open = fenceStart, let fenceCharacter {
            codeRanges.append(open...(lines.count - 1))
            unterminatedFence = String(repeating: String(fenceCharacter), count: fenceLength)
        } else {
            unterminatedFence = nil
        }

        // Managed markers outside code only; anything else is content.
        var markerLines: [(line: Int, markers: ManagedBlock.Markers, isBegin: Bool)] = []
        var codeIndex = 0
        for (index, line) in lines.enumerated() {
            while codeIndex < codeRanges.count, codeRanges[codeIndex].upperBound < index { codeIndex += 1 }
            if codeIndex < codeRanges.count, codeRanges[codeIndex].contains(index) { continue }
            if let markers = ManagedBlock.parse(line.text) {
                markerLines.append((index, markers, line.text.contains(":begin ")))
            }
        }
        var managedBlocks: [ManagedBlock.Block] = []
        var ambiguity: String? = nil
        var open: (line: Int, markers: ManagedBlock.Markers)? = nil
        for entry in markerLines {
            if entry.isBegin {
                if open != nil { ambiguity = "nested begin marker"; break }
                open = (entry.line, entry.markers)
            } else {
                guard let current = open else { ambiguity = "end marker without begin"; break }
                guard current.markers.sessionID == entry.markers.sessionID,
                      current.markers.nonce == entry.markers.nonce,
                      current.markers.component == entry.markers.component else {
                    ambiguity = "mismatched marker pair"; break
                }
                managedBlocks.append(.init(beginLine: current.line, endLine: entry.line,
                    markers: current.markers, isBegin: true))
                open = nil
            }
        }
        if ambiguity == nil, open != nil { ambiguity = "unclosed begin marker" }

        return Structure(lines: lines, hasFrontmatter: hasFrontmatter, codeRanges: codeRanges,
            unterminatedFence: unterminatedFence, managedBlocks: managedBlocks, markerAmbiguity: ambiguity)
    }

    /// The exported Markdown can be followed by app-owned sections or markers.
    /// Close a trailing source fence outside the original bytes so those lines
    /// remain structural while a literal marker inside the fence stays literal.
    static func closingTrailingFence(in markdown: String) -> String {
        guard markdown.contains("```") || markdown.contains("~~~"),
              let fence = scan(markdown).unterminatedFence else { return markdown }
        return markdown + (markdown.hasSuffix("\n") ? "" : "\n") + fence
    }

    /// True when the marker text appears on a line the scanner treats as content
    /// (inside code, or not parseable as an exact marker). Used to regenerate a nonce
    /// on creation when a collision would otherwise be ambiguous.
    static func markerLikeContentExists(_ text: String) -> Bool {
        let structure = scan(text)
        for line in structure.lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("<!-- rnr:") else { continue }
            if ManagedBlock.parse(line.text) == nil { return true }
        }
        return false
    }
}
