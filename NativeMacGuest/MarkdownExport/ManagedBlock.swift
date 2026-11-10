import Foundation

/// Marker grammar for app-owned blocks inside exported Markdown.
///
///     <!-- rnr:meeting:begin <session-uuid> <nonce> -->
///     ...managed content...
///     <!-- rnr:meeting:end <session-uuid> <nonce> -->
///
/// The nonce is generated per binding, so note text that merely looks like a marker
/// cannot forge ownership of a block.
enum ManagedBlock {
    static let schemaVersion = 1

    static func beginMarker(sessionID: UUID, nonce: String, component: ObsidianExportComponent) -> String {
        "<!-- rnr:\(component.rawValue):begin \(sessionID.uuidString) \(nonce) -->"
    }

    static func endMarker(sessionID: UUID, nonce: String, component: ObsidianExportComponent) -> String {
        "<!-- rnr:\(component.rawValue):end \(sessionID.uuidString) \(nonce) -->"
    }

    static func newNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    struct Markers {
        var sessionID: UUID
        var nonce: String
        var component: ObsidianExportComponent
    }

    /// Parses one marker line exactly. Returns nil for any other line, including
    /// marker-like text that does not match the grammar (that is content, not structure).
    static func parse(_ line: String) -> Markers? {
        guard line.hasPrefix("<!-- rnr:") else { return nil }
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count == 5, parts[0] == "<!--", parts[4] == "-->" else { return nil }
        let fields = parts[1].split(separator: ":").map(String.init)
        guard fields.count == 3, fields[0] == "rnr",
              let component = ObsidianExportComponent(rawValue: fields[1]),
              fields[2] == "begin" || fields[2] == "end",
              let sessionID = UUID(uuidString: parts[2]),
              parts[3].count == 32, parts[3].allSatisfy({ $0.isHexDigit }) else { return nil }
        return Markers(sessionID: sessionID, nonce: parts[3].lowercased(), component: component)
    }

    /// One begin/end pair with exact source ranges, line indices inclusive.
    struct Block {
        var beginLine: Int
        var endLine: Int
        var markers: Markers
        var isBegin: Bool
    }
}
