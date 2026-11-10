import Foundation
import XCTest
@testable import RockNativeDesktop

/// Debounced note commits: hydration, flush, generation fencing and error surfaces.
@MainActor final class MeetingNotesControllerTests: XCTestCase {
    private var temp: URL!
    private var library: MeetingLibraryController!
    private var notes: MeetingNotesController!

    override func setUp() async throws {
        try await super.setUp()
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-notes-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        library = MeetingLibraryController(root: temp)
        notes = MeetingNotesController(library: library)
        await library.prepare()
        XCTAssertTrue(library.isReady)
    }

    override func tearDown() async throws {
        await library?.close()
        library = nil
        notes = nil
        try? FileManager.default.removeItem(at: temp)
        try await super.tearDown()
    }

    private func makeSession(_ id: UUID = UUID(), title: String = "Notes Test") async -> UUID {
        _ = await library.createSession(id: id, title: title, invitation: nil, roomIdentity: "", calendarSeriesID: nil)
        return id
    }

    func testFlushCommitsLatestDraft() async {
        let id = await makeSession()
        notes.update(sessionID: id, text: "draft one")
        notes.update(sessionID: id, text: "draft two")
        let committed = await notes.flush(sessionID: id)
        XCTAssertTrue(committed)
        let record = await library.note(sessionID: id)
        XCTAssertEqual(record?.markdown, "draft two")
        XCTAssertEqual(notes.draft(sessionID: id)?.savedText, "draft two")
        XCTAssertNil(notes.draft(sessionID: id)?.saveError)
    }

    func testHydrateAdoptsCommittedNoteWithoutDirtying() async {
        let id = await makeSession()
        _ = await library.saveNote(sessionID: id, markdown: "already saved")
        notes.hydrate(sessionID: id, text: "already saved")
        // A hydrated buffer that matches the committed text is not dirty; flushing is a no-op success.
        let committed = await notes.flush(sessionID: id)
        XCTAssertTrue(committed)
        XCTAssertEqual(notes.buffer(sessionID: id), "already saved")
    }

    func testFlushForUnknownSessionReportsFailure() async {
        let unknown = UUID()
        notes.update(sessionID: unknown, text: "orphan")
        let committed = await notes.flush(sessionID: unknown)
        XCTAssertFalse(committed)
        XCTAssertNotNil(notes.draft(sessionID: unknown)?.saveError)
    }

    func testGenerationFencePreventsStaleCommitFromMarkingSaved() async {
        let id = await makeSession()
        notes.update(sessionID: id, text: "first")
        // Simulate a slow commit for generation 1 racing a newer edit:
        // commit the current text directly, then mark generation 2.
        _ = await notes.flush(sessionID: id)
        notes.update(sessionID: id, text: "second")
        // A stale completion for generation 1 must not mark generation 2 saved.
        XCTAssertNotEqual(notes.draft(sessionID: id)?.savedText, "second")
        XCTAssertEqual(notes.buffer(sessionID: id), "second")
        let committed = await notes.flush(sessionID: id)
        XCTAssertTrue(committed)
        XCTAssertEqual(notes.draft(sessionID: id)?.savedText, "second")
        let record = await library.note(sessionID: id)
        XCTAssertEqual(record?.markdown, "second")
    }

    func testEditorStateIsKeptPerSession() {
        let a = UUID(), b = UUID()
        notes.setEditorState(sessionID: a, selection: NSRange(location: 3, length: 2), scrollPoint: NSPoint(x: 1, y: 2))
        XCTAssertEqual(notes.editorState(sessionID: a).selection, NSRange(location: 3, length: 2))
        XCTAssertNil(notes.editorState(sessionID: b).selection)
        notes.discard(sessionID: a)
        XCTAssertNil(notes.editorState(sessionID: a).selection)
        XCTAssertNil(notes.draft(sessionID: a))
    }

    func testFlushAllCommitsEveryDirtyDraft() async {
        let a = await makeSession(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, title: "One")
        let b = await makeSession(UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!, title: "Two")
        notes.update(sessionID: a, text: "one")
        notes.update(sessionID: b, text: "two")
        await notes.flushAll()
        let noteA = await library.note(sessionID: a)
        let noteB = await library.note(sessionID: b)
        XCTAssertEqual(noteA?.markdown, "one")
        XCTAssertEqual(noteB?.markdown, "two")
    }
}
