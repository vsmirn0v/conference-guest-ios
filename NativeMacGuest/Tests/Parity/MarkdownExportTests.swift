import Foundation
import XCTest
@testable import RockNativeDesktop

/// Marker grammar, structure scanning, byte-preserving patching and templates.
final class MarkdownExportTests: XCTestCase {
    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!

    // MARK: ManagedBlock + scanner

    func testMarkerRoundTripParsesExactly() {
        let nonce = ManagedBlock.newNonce()
        let begin = ManagedBlock.beginMarker(sessionID: sessionID, nonce: nonce, component: .meeting)
        let parsed = ManagedBlock.parse(begin)
        XCTAssertEqual(parsed?.sessionID, sessionID)
        XCTAssertEqual(parsed?.nonce, nonce)
        XCTAssertEqual(parsed?.component, .meeting)
        XCTAssertNotNil(ManagedBlock.parse(ManagedBlock.endMarker(sessionID: sessionID, nonce: nonce, component: .meeting)))
    }

    func testMarkerLikeTextThatIsNotOwnedIsContent() {
        // Marker-shaped text without a valid 32-hex nonce must never parse as structure.
        let forged = "<!-- rnr:meeting:begin \(sessionID.uuidString) 0123 -->"
        XCTAssertNil(ManagedBlock.parse(forged))
        XCTAssertTrue(MarkdownStructureScanner.markerLikeContentExists(forged))
    }

    func testScannerFlagsUnbalancedMarkersAsAmbiguity() {
        let nonce = ManagedBlock.newNonce()
        let text = ManagedBlock.beginMarker(sessionID: sessionID, nonce: nonce, component: .meeting) + "\ncontent\n"
        let structure = MarkdownStructureScanner.scan(text)
        XCTAssertNotNil(structure.markerAmbiguity)
    }

    // MARK: Patcher

    func testPatchPreservesExternalEditsAndUpdatesBlock() throws {
        let nonce = ManagedBlock.newNonce()
        let created = MarkdownFilePatcher.create(sessionID: sessionID, nonce: nonce,
                                                 frontmatter: "---\ntitle: T\n---", managedContent: "v1")
        // The user appends free content below the managed block.
        var existing = created.text + "\n## My own section\nkeep me\n"
        existing = existing.replacingOccurrences(of: "title: T", with: "title: Renamed by user")

        let patched = try MarkdownFilePatcher.patch(existing: existing, sessionID: sessionID, nonce: nonce,
                                                    component: .meeting, managedContent: "v2",
                                                    expectedBlockSHA256: created.blockSHA256)
        XCTAssertTrue(patched.text.contains("v2"))
        XCTAssertFalse(patched.text.contains("\nv1\n"))
        XCTAssertTrue(patched.text.contains("## My own section\nkeep me"))
        XCTAssertTrue(patched.text.contains("title: Renamed by user"), "user frontmatter edits survive a patch")
    }

    func testPatchConflictsWhenManagedContentChangedExternally() {
        let nonce = ManagedBlock.newNonce()
        let created = MarkdownFilePatcher.create(sessionID: sessionID, nonce: nonce,
                                                 frontmatter: "---\n---", managedContent: "v1")
        // External writer changed the managed content: the old block hash no longer matches.
        let begin = ManagedBlock.beginMarker(sessionID: sessionID, nonce: nonce, component: .meeting)
        let end = ManagedBlock.endMarker(sessionID: sessionID, nonce: nonce, component: .meeting)
        let tampered = created.text.replacingOccurrences(of: "\nv1\n", with: "\ntampered\n")
        XCTAssertTrue(tampered.contains(begin) && tampered.contains(end))
        XCTAssertThrowsError(try MarkdownFilePatcher.patch(existing: tampered, sessionID: sessionID, nonce: nonce,
                                                           component: .meeting, managedContent: "v2",
                                                           expectedBlockSHA256: created.blockSHA256)) { error in
            XCTAssertEqual(error as? ObsidianExportError, .managedBlockConflict)
        }
    }

    func testPatchAppendsOwnedBlockToUnmanagedFile() throws {
        let nonce = ManagedBlock.newNonce()
        let existing = "# Existing note\n\nSome user content.\n"
        let result = try MarkdownFilePatcher.patch(existing: existing, sessionID: sessionID, nonce: nonce,
                                                   component: .meeting, managedContent: "auto",
                                                   expectedBlockSHA256: nil)
        XCTAssertTrue(result.text.hasPrefix(existing))
        XCTAssertTrue(result.text.contains(ManagedBlock.beginMarker(sessionID: sessionID, nonce: nonce, component: .meeting)))
    }

    func testPatchRejectsAmbiguousForeignMarkerPair() {
        let foreignNonce = ManagedBlock.newNonce()
        let foreign = ManagedBlock.beginMarker(sessionID: UUID(), nonce: foreignNonce, component: .meeting) + "\nx\n"
            + ManagedBlock.endMarker(sessionID: UUID(), nonce: foreignNonce, component: .meeting)
        // A different session's meeting block already exists; appending ours would be ambiguous.
        XCTAssertThrowsError(try MarkdownFilePatcher.patch(existing: foreign, sessionID: sessionID,
                                                           nonce: ManagedBlock.newNonce(), component: .meeting,
                                                           managedContent: "mine", expectedBlockSHA256: nil)) { error in
            guard case .markerDamage = error as? ObsidianExportError else {
                return XCTFail("expected markerDamage, got \(error)")
            }
        }
    }

    // MARK: Template

    func testMeetingFileNameSanitizesAndStaysStable() {
        let name = MeetingMarkdownTemplate.meetingFileName(title: "Design / Sync: Weekly!", sessionID: sessionID)
        XCTAssertTrue(name.hasSuffix(".md"))
        XCTAssertTrue(name.contains("Design Sync Weekly"))
        XCTAssertTrue(name.contains(String(sessionID.uuidString.prefix(8))))
        XCTAssertEqual(MeetingMarkdownTemplate.meetingFileName(title: "   ", sessionID: sessionID),
                       "Meeting \(String(sessionID.uuidString.prefix(8))).md")
    }

    func testManagedContentShowsExplicitEmptyAndPendingStates() {
        let session = MeetingSessionRecord(id: sessionID, title: "T", startedAt: Date())
        let empty = MeetingMarkdownTemplate.managedContent(session: session, note: nil, outcome: nil, outcomeState: .notStarted)
        XCTAssertTrue(empty.contains("_No notes for this meeting._"))
        XCTAssertTrue(empty.contains("_The meeting outcome is being prepared…_"))
        let failed = MeetingMarkdownTemplate.managedContent(session: session, note: nil, outcome: nil, outcomeState: .failed)
        XCTAssertTrue(failed.contains("could not be generated"))
    }

    func testYamlValueQuotesUnsafeScalars() {
        XCTAssertEqual(MeetingMarkdownTemplate.yamlValue("plain title-1"), "plain title-1")
        XCTAssertEqual(MeetingMarkdownTemplate.yamlValue(" leading"), "\" leading\"")
        XCTAssertEqual(MeetingMarkdownTemplate.yamlValue("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(MeetingMarkdownTemplate.yamlValue(""), "\"\"")
    }
}
