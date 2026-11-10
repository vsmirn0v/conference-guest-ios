import Foundation
import XCTest
@testable import RockNativeDesktop

/// Manual (user-initiated) Markdown export: rendering, file naming, worklog order.
final class MeetingManualExportTests: XCTestCase {
    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D4")!
    private var temp: URL!

    override func setUp() {
        super.setUp()
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-export-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temp)
        super.tearDown()
    }

    private func item(title: String = "Sync", markdown: String? = "note body",
                      outcome: MeetingOutcome? = nil, unsaved: Bool = false,
                      startedAt: Date = Date()) -> MeetingManualExportItem {
        let session = MeetingSessionRecord(id: sessionID, title: title, startedAt: startedAt)
        let note = markdown.map {
            MeetingNoteRecord(id: UUID(), sessionID: sessionID, markdown: $0, revision: 1,
                              createdAt: startedAt, updatedAt: startedAt)
        }
        return MeetingManualExportItem(session: session, note: note, outcome: outcome,
                                       outcomeState: outcome == nil ? .notStarted : .ready,
                                       isUnsavedDraft: unsaved)
    }

    func testRenderContainsNoteAndExplicitOutcomeStateWithoutMarkers() {
        let outcome = MeetingOutcome(meetingTitle: "Sync", endedAt: Date(), summary: "Ship it",
                                     decisions: ["Go"], tasks: [.init(text: "Follow up", owner: "Ana", done: false)],
                                     openQuestions: ["Owner?"])
        let text = MeetingManualExport.render(item: item(markdown: "raw **markdown** body", outcome: outcome))
        XCTAssertTrue(text.contains("raw **markdown** body"), "raw note is never normalized")
        XCTAssertTrue(text.contains("Ship it"))
        XCTAssertTrue(text.contains("- Go"))
        XCTAssertTrue(text.contains("- [ ] Follow up — Ana"))
        XCTAssertTrue(text.contains("- Owner?"))
        XCTAssertFalse(text.contains("rnr:meeting:begin"), "manual export carries no managed markers")
        XCTAssertTrue(text.hasPrefix("---\n"), "frontmatter leads the file")
    }

    func testRenderMarksUnsavedDraft() {
        let text = MeetingManualExport.render(item: item(markdown: "draft", unsaved: true))
        XCTAssertTrue(text.contains("Unsaved draft"))
    }

    func testUniqueURLAppendsIncreasingSuffixes() {
        let first = MeetingManualExport.uniqueURL(directory: temp, fileName: "Sync.md")
        try? Data().write(to: first)
        let second = MeetingManualExport.uniqueURL(directory: temp, fileName: "Sync.md")
        XCTAssertEqual(second.lastPathComponent, "Sync 2.md")
        try? Data().write(to: second)
        XCTAssertEqual(MeetingManualExport.uniqueURL(directory: temp, fileName: "Sync.md").lastPathComponent, "Sync 3.md")
    }

    func testWorklogOrdersByStartTimeWithSessionTieBreak() {
        let later = item(title: "Later", startedAt: Date(timeIntervalSince1970: 2_000))
        let earlier = item(title: "Earlier", startedAt: Date(timeIntervalSince1970: 1_000))
        // Same start time, earlier than both: session UUID breaks the tie deterministically.
        let tieTime = Date(timeIntervalSince1970: 500)
        let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let highID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let makeTie: (UUID, String) -> MeetingManualExportItem = { id, title in
            let session = MeetingSessionRecord(id: id, title: title, startedAt: tieTime)
            return MeetingManualExportItem(session: session, note: nil, outcome: nil,
                                           outcomeState: .notStarted, isUnsavedDraft: false)
        }
        let tieA = makeTie(lowID, "TieA"), tieB = makeTie(highID, "TieB")
        let text = MeetingManualExport.renderWorklog(items: [later, tieB, earlier, tieA])
        // Chronological with a session-ID tie break: TieA(500) < TieB(500) < Earlier(1000) < Later(2000).
        let order = [text.range(of: "# TieA"), text.range(of: "# TieB"),
                     text.range(of: "# Earlier"), text.range(of: "# Later")].compactMap { $0 }
        XCTAssertEqual(order.count, 4)
        XCTAssertTrue(order[0].lowerBound < order[1].lowerBound)
        XCTAssertTrue(order[1].lowerBound < order[2].lowerBound)
        XCTAssertTrue(order[2].lowerBound < order[3].lowerBound)
        XCTAssertTrue(text.hasPrefix("# "))
        XCTAssertTrue(text.contains("\n---\n"), "entries are separated")
    }
}
