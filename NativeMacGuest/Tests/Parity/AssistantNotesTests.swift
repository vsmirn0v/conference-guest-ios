import Foundation
import XCTest
@testable import RockNativeDesktop

/// Assistant read path for notes: registry metadata, full-note tool, coverage flag,
/// separate provenance, and note matches in search.
@MainActor final class AssistantNotesTests: XCTestCase {
    private let meetingID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E5")!

    private func fixture(notes: [AssistantNoteRecord] = []) -> AssistantNativeSnapshot {
        AssistantNativeSnapshot(
            now: Date(timeIntervalSince1970: 1_760_000_000), timeZoneIdentifier: "UTC", language: "en",
            contextMeetingID: nil, profileNames: ["You"], meetings: [], outcomes: [], notes: notes,
            moments: [], memories: [], calendar: [], actionTargets: [], settings: [:])
    }

    private func noteRecord(preview: String = "parking lot") -> AssistantNoteRecord {
        AssistantNoteRecord(id: UUID(), meetingID: meetingID, meetingTitle: "Notes Sync",
                            revision: 3, updatedAt: Date(timeIntervalSince1970: 1_760_000_000),
                            preview: preview)
    }

    private func registry(notes: [AssistantNoteRecord] = [],
                          readNote: @escaping @Sendable (UUID) async -> MeetingNoteRecord? = { _ in nil })
        -> AssistantAgentToolRegistry {
        AssistantNativeToolProvider.registry(snapshot: fixture(notes: notes),
            hooks: .init(executeAction: { _ in "executed" }, readNote: readNote))
    }

    private func call(_ name: String, _ arguments: AssistantJSON = .object([:])) -> AssistantAgentToolCall {
        .init(id: "c1", name: name, arguments: arguments)
    }

    func testGetNotesReturnsFullMarkdownWithPersonalNoteProvenance() async throws {
        let committed = MeetingNoteRecord(id: UUID(), sessionID: meetingID,
                                          markdown: "# Raw\n\npersonal note body", revision: 3,
                                          createdAt: Date(), updatedAt: Date())
        let registry = registry(notes: [noteRecord()]) { id in
            XCTAssertEqual(id, self.meetingID)
            return committed
        }
        let validated = try registry.validate(call("rocknroll_get_notes",
            .object(["meeting_id": .string(meetingID.uuidString)])))
        let result = try await registry.tool(named: "rocknroll_get_notes")!
            .execute(validated, arguments: validated.arguments)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.json["markdown"]?.stringValue, "# Raw\n\npersonal note body")
        XCTAssertEqual(result.json["revision"]?.intValue, 3)
        XCTAssertEqual(result.json["coverage"]?.stringValue, "complete")
        XCTAssertEqual(result.json["provenance"]?.stringValue, "personal_note_user_authored")
        XCTAssertTrue(result.evidence.contains { $0.kind == "note" && $0.title == "Notes Sync" })
    }

    func testGetNotesFlagsPartialCoverageOverTwelveK() async throws {
        let longMarkdown = String(repeating: "x", count: 12_500)
        let committed = MeetingNoteRecord(id: UUID(), sessionID: meetingID, markdown: longMarkdown,
                                          revision: 1, createdAt: Date(), updatedAt: Date())
        let registry = registry(notes: [noteRecord()]) { _ in committed }
        let validated = try registry.validate(call("rocknroll_get_notes",
            .object(["meeting_id": .string(meetingID.uuidString)])))
        let result = try await registry.tool(named: "rocknroll_get_notes")!
            .execute(validated, arguments: validated.arguments)
        XCTAssertEqual(result.json["coverage"]?.stringValue, "partial_first_12k")
        XCTAssertEqual(result.json["markdown"]?.stringValue?.utf8.count, 12_000)
    }

    func testGetNotesFailsClosedForUnknownMeetingAndMissingNote() async throws {
        let registry = registry(notes: [noteRecord()])
        // Meeting without note metadata is unknown.
        let other = UUID(uuidString: "00000000-0000-0000-0000-0000000000EE")!
        // Unknown meetings fail closed at execution time with a typed tool error.
        let unknown = try registry.validate(call("rocknroll_get_notes",
            .object(["meeting_id": .string(other.uuidString)])))
        do {
            _ = try await registry.tool(named: "rocknroll_get_notes")!
                .execute(unknown, arguments: unknown.arguments)
            XCTFail("unknown meeting must fail closed")
        } catch let error as AssistantAgentError {
            XCTAssertEqual(error, .unknownMeeting(other.uuidString))
        }
        // Metadata exists but the repository read fails: explicit unavailability, still not an error crash.
        let validated = try registry.validate(call("rocknroll_get_notes",
            .object(["meeting_id": .string(meetingID.uuidString)])))
        let result = try await registry.tool(named: "rocknroll_get_notes")!
            .execute(validated, arguments: validated.arguments)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.json["available"]?.boolValue, false)
    }

    func testSearchSurfacesNotesWithDistinctKind() async throws {
        let record = noteRecord(preview: "Parking lot: flaky sync tests")
        let registry = registry(notes: [record])
        let validated = try registry.validate(call("rocknroll_search",
            .object(["query": .string("parking lot")])) )
        let result = try await registry.tool(named: "rocknroll_search")!
            .execute(validated, arguments: validated.arguments)
        XCTAssertFalse(result.isError)
        let matches = result.json["matches"]?.arrayValue ?? []
        let noteMatches = matches.filter { $0["kind"]?.stringValue == "note" }
        XCTAssertEqual(noteMatches.count, 1)
        XCTAssertEqual(noteMatches[0]["id"]?.stringValue, "note-\(record.id.uuidString)")
        XCTAssertEqual(noteMatches[0]["meeting"]?.stringValue, "Notes Sync")
    }

    func testStatusToolMentionsNoteCapabilities() async throws {
        let registry = registry()
        let validated = try registry.validate(call("rocknroll_status"))
        let result = try await registry.tool(named: "rocknroll_status")!
            .execute(validated, arguments: validated.arguments)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.json["write_actions_available"]?.boolValue, true)
    }
}
