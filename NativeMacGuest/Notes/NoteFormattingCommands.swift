import SwiftUI

/// Pure Markdown formatting transforms on the raw note string. Each command maps
/// (text, selection) to (text, selection) so it is unit-testable without an editor.
enum NoteFormattingCommand: String, CaseIterable {
    case heading, bold, italic, strikethrough, unorderedList, checklist, quote, code, link, divider

    var title: String {
        switch self {
        case .heading: L("Heading")
        case .bold: L("Bold")
        case .italic: L("Italic")
        case .strikethrough: L("Strikethrough")
        case .unorderedList: L("List")
        case .checklist: L("Checklist")
        case .quote: L("Quote")
        case .code: L("Code")
        case .link: L("Link")
        case .divider: L("Divider")
        }
    }
    var symbol: String {
        switch self {
        case .heading: "textformat.size.larger"
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .unorderedList: "list.bullet"
        case .checklist: "checklist"
        case .quote: "text.quote"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .divider: "minus"
        }
    }

    func apply(to text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let range = Self.clamped(selection, in: text)
        let selected = range.length > 0 ? (text as NSString).substring(with: range) : ""
        switch self {
        case .heading:
            return Self.prefixLines(text, range: range, prefix: "# ")
        case .quote:
            return Self.prefixLines(text, range: range, prefix: "> ")
        case .unorderedList:
            return Self.prefixLines(text, range: range, prefix: "- ")
        case .checklist:
            return Self.prefixLines(text, range: range, prefix: "- [ ] ")
        case .bold:
            return Self.wrap(text, range: range, selected: selected, marker: "**", emptyPlaceholder: L("bold text"))
        case .italic:
            return Self.wrap(text, range: range, selected: selected, marker: "*", emptyPlaceholder: L("italic text"))
        case .strikethrough:
            return Self.wrap(text, range: range, selected: selected, marker: "~~", emptyPlaceholder: L("struck text"))
        case .code:
            if selected.contains("\n") { return Self.fence(text, range: range, selected: selected) }
            return Self.wrap(text, range: range, selected: selected, marker: "`", emptyPlaceholder: L("code"))
        case .link:
            let target = selected.isEmpty ? L("link text") : selected
            let replacement = "[\(target)](\(L("url")))"
            return Self.replace(text, range: range, with: replacement, selectLength: target.utf16.count + 2)
        case .divider:
            let line = "\n\n---\n\n"
            return Self.replace(text, range: range, with: line, selectLength: 0)
        }
    }

    private static func clamped(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(range.location, length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    private static func wrap(_ text: String, range: NSRange, selected: String, marker: String, emptyPlaceholder: String)
        -> (text: String, selection: NSRange) {
        let inner = selected.isEmpty ? emptyPlaceholder : selected
        let replacement = marker + inner + marker
        return replace(text, range: range, with: replacement, selectLength: inner.utf16.count)
    }

    private static func fence(_ text: String, range: NSRange, selected: String) -> (text: String, selection: NSRange) {
        let replacement = "```\n" + selected + "\n```"
        return replace(text, range: range, with: replacement, selectLength: selected.utf16.count)
    }

    private static func prefixLines(_ text: String, range: NSRange, prefix: String) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: range)
        let block = ns.substring(with: lineRange)
        let alreadyPrefixed = block.components(separatedBy: "\n").allSatisfy { $0.isEmpty || $0.hasPrefix(prefix) }
        let newBlock = block.components(separatedBy: "\n").map { line -> String in
            if line.isEmpty { return line }
            return alreadyPrefixed ? String(line.dropFirst(prefix.count)) : prefix + line
        }.joined(separator: "\n")
        return replace(text, range: lineRange, with: newBlock, selectLength: newBlock.utf16.count)
    }

    private static func replace(_ text: String, range: NSRange, with replacement: String, selectLength: Int)
        -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let updated = ns.replacingCharacters(in: range, with: replacement)
        let cursor = range.location + min(selectLength, (replacement as NSString).length)
        return (updated, NSRange(location: cursor, length: 0))
    }
}
