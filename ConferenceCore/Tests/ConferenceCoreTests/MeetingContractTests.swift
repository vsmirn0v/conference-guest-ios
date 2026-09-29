import XCTest
@testable import ConferenceCore

final class MeetingContractTests: XCTestCase {
    func testNamePoliciesCountScalarsAndRejectControls() {
        let community = MeetingInputPolicy(maximumNameScalars: 60)
        let guest = MeetingInputPolicy(maximumNameScalars: 80)
        XCTAssertTrue(community.accepts(name: String(repeating: "a", count: 60)))
        XCTAssertFalse(community.accepts(name: String(repeating: "a", count: 61)))
        XCTAssertTrue(guest.accepts(name: String(repeating: "a", count: 80)))
        XCTAssertFalse(guest.accepts(name: String(repeating: "a", count: 81)))
        XCTAssertFalse(community.accepts(name: "Ani\u{0000}"))
        XCTAssertTrue(community.accepts(name: " Ani "))
        XCTAssertFalse(community.accepts(name: String(repeating: "e\u{301}", count: 31)))
    }

    func testChatUnicodeWireContractAndEscaping() throws {
        for text in [String(repeating: "a", count: 2000), String(repeating: "字", count: 2000),
                     String(repeating: "🎸", count: 2000), String(repeating: "\"\\\n", count: 666),
                     String(repeating: "e\u{301}", count: 1000)] {
            let packet = RoomChatPacket(id: "12345678-1234-1234-1234-123456789abc", text: text)
            let bytes = try packet.encoded()
            XCTAssertLessThanOrEqual(bytes.count, RoomChatPacket.maximumBytes)
            XCTAssertEqual(try RoomChatPacket.decode(bytes).text, text)
        }
        XCTAssertThrowsError(try RoomChatPacket(id: String(repeating: "a", count: 65), text: "a").encoded())
        XCTAssertThrowsError(try RoomChatPacket(id: "id", text: String(repeating: "🎸", count: 2001)).encoded())
        XCTAssertThrowsError(try RoomChatPacket.decode(Data(repeating: 32, count: 16385)))
    }

    func testLargeTranscriptReplayRetainsEditsAndIgnoresDiscardedHistory() {
        var timeline = CatchUpTimeline()
        let messages = (0..<50_000).map { index in
            TranscriptSegment(id: String(format: "%05d", index), speaker: "Ani", text: "Line \(index)",
                spokenAt: Date(timeIntervalSince1970: Double(1_700_000_000 + index)))
        }
        timeline.upsert(messages)
        XCTAssertEqual(timeline.segments.count, 5000)
        let start = Date()
        for _ in 0..<10 { timeline.upsert(messages) }
        print("PERF transcript 50k replay average ms: \(Date().timeIntervalSince(start) * 100)")
        XCTAssertEqual(timeline.segments.count, 5000)
        let edited = TranscriptSegment(id: "49000", speaker: "Ani", text: "Correction",
                                      spokenAt: messages[49000].spokenAt)
        timeline.upsert([edited])
        XCTAssertEqual(timeline.segments.first { $0.id == edited.id }?.text, "Correction")
        XCTAssertTrue(timeline.isTruncated)
        XCTAssertFalse(timeline.shouldRetain(id: "00000", spokenAt: messages[0].spokenAt))
    }
}
