import Foundation

enum ObsidianOwnedMetadata {
    private static let keys: Set<String> = [
        "schema_version", "meeting_id", "title", "started_at", "ended_at", "time_zone",
        "export_revision", "note_revision", "outcome_state",
    ]

    private struct Fields {
        var values: [String: MarkdownStructureScanner.Line]
        let closing: MarkdownStructureScanner.Line

        var preview: String { values.keys.sorted().compactMap { values[$0]?.text }.joined(separator: "\n") }
        var hash: String { MarkdownFilePatcher.sha256(preview) }
    }

    static func hash(in text: String) throws -> String? { try read(text)?.hash }

    static func preview(in text: String) throws -> String? { try read(text)?.preview }

    static func ownsLegacyFrontmatter(_ text: String, sessionID: UUID) throws -> Bool {
        guard let fields = try read(text) else { return false }
        return fields.values["meeting_id"]?.text == "meeting_id: \"\(sessionID.uuidString)\"" &&
            fields.values["schema_version"]?.text == "schema_version: \(MeetingMarkdownTemplate.schemaVersion)"
    }

    static func replacing(in text: String, generated: String, expected: String) throws -> (String, String) {
        guard let previous = try read(text), previous.hash == expected,
              let next = try read(generated) else { throw ObsidianExportError.managedBlockConflict }
        var bytes = Data(text.utf8)
        let oldRanges = previous.values.map { key, line in (key, line.byteStart, line.byteEnd) }
            .sorted { $0.1 > $1.1 }
        let additions = next.values.keys.sorted().filter { previous.values[$0] == nil }.compactMap { next.values[$0]?.text }
        if !additions.isEmpty {
            let newline = previous.closing.byteStart >= 2 && bytes[previous.closing.byteStart - 2] == 13 ? "\r\n" : "\n"
            bytes.insert(contentsOf: (additions.joined(separator: newline) + newline).utf8, at: previous.closing.byteStart)
        }
        for (key, start, end) in oldRanges {
            if let field = next.values[key] {
                let contentEnd = end > start && bytes[end - 1] == 13 ? end - 1 : end
                bytes.replaceSubrange(start..<contentEnd, with: field.text.utf8)
            } else {
                bytes.removeSubrange(start..<(end + 1))
            }
        }
        guard let updated = String(data: bytes, encoding: .utf8) else {
            throw ObsidianExportError.markerDamage("The updated metadata is not valid UTF-8.")
        }
        return (updated, next.hash)
    }

    private static func read(_ text: String) throws -> Fields? {
        let bytes = text.utf8
        var offset = 0
        var cursor = bytes.startIndex
        var fields: [String: MarkdownStructureScanner.Line] = [:]
        while cursor < bytes.endIndex {
            let end = bytes[cursor...].firstIndex(of: 10) ?? bytes.endIndex
            let count = bytes.distance(from: cursor, to: end)
            var value = String(decoding: bytes[cursor..<end], as: UTF8.self)
            if value.hasSuffix("\r") { value.removeLast() }
            let line = MarkdownStructureScanner.Line(text: value, byteStart: offset, byteEnd: offset + count)
            if offset == 0 {
                guard value == "---" else { return nil }
            } else if value == "---" || value == "..." {
                return Fields(values: fields, closing: line)
            } else if let colon = value.firstIndex(of: ":") {
                let key = String(value[..<colon])
                if keys.contains(key) {
                    guard fields[key] == nil else {
                        throw ObsidianExportError.markerDamage("An owned metadata field is duplicated.")
                    }
                    fields[key] = line
                }
            }
            offset += count + 1
            guard end < bytes.endIndex else { break }
            cursor = bytes.index(after: end)
        }
        return nil
    }
}
