import CryptoKit
import Foundation

/// Byte-preserving splice for exported Markdown. Only owned ranges (the managed
/// block between exact markers, or the frontmatter on a separate meeting file) are
/// replaced; every other byte — including third-party edits outside the block — is
/// preserved exactly. Ambiguity fails closed with a typed conflict.
enum MarkdownFilePatcher {
    struct PatchResult {
        var text: String
        /// SHA-256 of the managed block's managed content (between the markers).
        var blockSHA256: String
        /// SHA-256 of the whole resulting file.
        var fileSHA256: String
        var metadataSHA256: String?
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Replaces the managed block owned by (sessionID, nonce) in `existing` with
    /// `managedContent` (the inner content between markers; markers are re-emitted).
    /// - A missing block: appends the markers + content at the end (creation).
    /// - External edits outside the block: preserved byte-for-byte.
    /// - The previous managed content differing from `expectedBlockSHA256`: conflict.
    static func patch(existing: String, sessionID: UUID, nonce: String,
                      component: ObsidianExportComponent, managedContent: String,
                      expectedBlockSHA256: String?, insertionByteOffset: Int? = nil,
                      insertionHeader: String? = nil) throws -> PatchResult {
        let structure = MarkdownStructureScanner.scan(existing)
        if let ambiguity = structure.markerAmbiguity {
            throw ObsidianExportError.markerDamage(ambiguity)
        }
        let begin = ManagedBlock.beginMarker(sessionID: sessionID, nonce: nonce, component: component)
        let end = ManagedBlock.endMarker(sessionID: sessionID, nonce: nonce, component: component)
        let blockText = begin + "\n" + managedContent + "\n" + end

        let matches = structure.managedBlocks.filter {
            $0.markers.sessionID == sessionID && $0.markers.component == component
        }
        if matches.count > 1 { throw ObsidianExportError.markerDamage("The same meeting appears more than once.") }
        if let owned = matches.first {
            guard owned.markers.nonce == nonce else {
                throw ObsidianExportError.markerDamage("The managed block has an unexpected identity.")
            }
            // Managed content = lines strictly between the markers.
            let innerStart = structure.lines[owned.beginLine].byteEnd + 1
            let innerEnd = structure.lines[owned.endLine].byteStart
            guard innerStart <= innerEnd, let inner = substring(of: existing, bytes: innerStart..<innerEnd) else {
                throw ObsidianExportError.markerDamage("block byte range is invalid")
            }
            let normalizedInner = inner.hasPrefix("\n") ? String(inner.dropFirst()) : inner
            let canonicalInner = normalizedInner.hasSuffix("\n") ? String(normalizedInner.dropLast()) : normalizedInner
            if let expectedBlockSHA256, sha256(canonicalInner) != expectedBlockSHA256 {
                throw ObsidianExportError.managedBlockConflict
            }
            let bytes = Data(existing.utf8)
            let updated = bytes.prefix(innerStart) + Data((managedContent + "\n").utf8) + bytes.suffix(bytes.count - innerEnd)
            guard let text = String(data: updated, encoding: .utf8) else {
                throw ObsidianExportError.markerDamage("patched file is not valid UTF-8")
            }
            return PatchResult(text: text, blockSHA256: sha256(managedContent), fileSHA256: sha256(text))
        }

        // No owned block: refuse to create one next to an unclaimed marker pair that
        // would be ambiguous, then append at the end.
        if expectedBlockSHA256 != nil {
            throw ObsidianExportError.markerDamage("The previously exported managed block is missing.")
        }
        if component == .meeting, structure.managedBlocks.contains(where: { $0.markers.component == component }) {
            throw ObsidianExportError.markerDamage("another unmanaged \(component.rawValue) marker pair exists")
        }
        let bytes = Data(existing.utf8)
        let offset = insertionByteOffset ?? bytes.count
        guard (0...bytes.count).contains(offset),
              let prefix = String(data: bytes.prefix(offset), encoding: .utf8),
              let suffix = String(data: bytes.suffix(from: offset), encoding: .utf8) else {
            throw ObsidianExportError.markerDamage("the insertion offset is invalid")
        }
        let separator = prefix.isEmpty ? "" : prefix.hasSuffix("\n") ? "\n" : "\n\n"
        let text = prefix + separator + (insertionHeader.map { $0 + "\n\n" } ?? "") + blockText + "\n" +
            (suffix.isEmpty ? "" : "\n" + suffix)
        return PatchResult(text: text, blockSHA256: sha256(managedContent), fileSHA256: sha256(text))
    }

    static func managedBlockHash(in text: String, sessionID: UUID, nonce: String,
                                 component: ObsidianExportComponent) -> String? {
        managedBlockContent(in: text, sessionID: sessionID, nonce: nonce, component: component).map(sha256)
    }

    static func managedBlockContent(in text: String, sessionID: UUID, nonce: String,
                                    component: ObsidianExportComponent) -> String? {
        let structure = MarkdownStructureScanner.scan(text)
        guard structure.markerAmbiguity == nil else { return nil }
        let matching = structure.managedBlocks.filter {
            $0.markers.sessionID == sessionID && $0.markers.component == component
        }
        guard matching.count == 1, let block = matching.first, block.markers.nonce == nonce else { return nil }
        let start = structure.lines[block.beginLine].byteEnd + 1
        let end = structure.lines[block.endLine].byteStart
        guard start <= end, let inner = substring(of: text, bytes: start..<end) else { return nil }
        return inner.hasSuffix("\n") ? String(inner.dropLast()) : inner
    }

    /// Full-file creation for a separate meeting file: frontmatter + managed block.
    static func create(sessionID: UUID, nonce: String, frontmatter: String, managedContent: String) -> PatchResult {
        let begin = ManagedBlock.beginMarker(sessionID: sessionID, nonce: nonce, component: .meeting)
        let end = ManagedBlock.endMarker(sessionID: sessionID, nonce: nonce, component: .meeting)
        let text = frontmatter + "\n" + begin + "\n" + managedContent + "\n" + end + "\n"
        return PatchResult(text: text, blockSHA256: sha256(managedContent), fileSHA256: sha256(text))
    }

    private static func substring(of text: String, bytes range: Range<Int>) -> String? {
        let data = Data(text.utf8)
        guard range.lowerBound >= 0, range.upperBound <= data.count else { return nil }
        return String(data: data.subdata(in: range), encoding: .utf8)
    }
}
