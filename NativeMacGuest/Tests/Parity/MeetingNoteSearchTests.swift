import Foundation
import XCTest
@testable import RockNativeDesktop

/// Note chunking and case-insensitive search over committed notes.
final class MeetingNoteSearchTests: XCTestCase {
    private var temp: URL!

    override func setUp() {
        super.setUp()
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-note-search-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temp)
        super.tearDown()
    }

    func testSearchFindsCaseFoldedMatchesAcrossChunks() async throws {
        let store = MeetingLibraryStore(root: temp)
        try await store.prepare()
        let session = MeetingSessionRecord(title: "Launch Review", startedAt: Date())
        try await store.upsertSession(session)
        _ = try await store.saveNote(sessionID: session.id, markdown:
            "# Launch Review\n\nParking lot: investigate the Flaky Sync tests.\n\n- Vendor demo next week")

        let hits = try await store.searchNotes(query: "FLAKY SYNC")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].meetingTitle, "Launch Review")
        XCTAssertEqual(hits[0].sessionID, session.id)
        XCTAssertTrue(hits[0].chunk.text.contains("Flaky Sync"))
        XCTAssertEqual(hits[0].matchedField, "note")
    }

    func testSearchReturnsNothingForBlankOrMissingQuery() async throws {
        let store = MeetingLibraryStore(root: temp)
        try await store.prepare()
        let session = MeetingSessionRecord(title: "Empty", startedAt: Date())
        try await store.upsertSession(session)
        _ = try await store.saveNote(sessionID: session.id, markdown: "content")
        let blank = try await store.searchNotes(query: "   ")
        let absent = try await store.searchNotes(query: "absent")
        XCTAssertEqual(blank.count, 0)
        XCTAssertEqual(absent.count, 0)
    }

    func testSearchFiltersByTimeRange() async throws {
        let store = MeetingLibraryStore(root: temp)
        try await store.prepare()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = Date(timeIntervalSince1970: 1_760_000_000)
        let oldSession = MeetingSessionRecord(title: "Old", startedAt: old)
        let newSession = MeetingSessionRecord(title: "New", startedAt: recent)
        try await store.upsertSession(oldSession)
        try await store.upsertSession(newSession)
        _ = try await store.saveNote(sessionID: oldSession.id, markdown: "retro keyword apple")
        _ = try await store.saveNote(sessionID: newSession.id, markdown: "standup keyword apple")

        let recentOnly = try await store.searchNotes(query: "apple", from: recent.addingTimeInterval(-60))
        XCTAssertEqual(recentOnly.map(\.sessionID), [newSession.id])
    }

    func testRecommittedNoteReplacesChunks() async throws {
        let store = MeetingLibraryStore(root: temp)
        try await store.prepare()
        let session = MeetingSessionRecord(title: "Rewrite", startedAt: Date())
        try await store.upsertSession(session)
        _ = try await store.saveNote(sessionID: session.id, markdown: "first banana draft")
        _ = try await store.saveNote(sessionID: session.id, markdown: "second cherry draft")

        let chunks = try await store.noteChunks(session.id)
        XCTAssertTrue(chunks.allSatisfy { $0.noteRevision == 2 })
        let banana = try await store.searchNotes(query: "banana")
        let cherry = try await store.searchNotes(query: "cherry")
        XCTAssertFalse(banana.contains { $0.chunk.noteRevision == 1 })
        XCTAssertEqual(cherry.count, 1)
    }
}
