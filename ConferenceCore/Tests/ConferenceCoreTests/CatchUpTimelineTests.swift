import XCTest
@testable import ConferenceCore

final class CatchUpTimelineTests: XCTestCase {
    func testOverlappingHoldAndConnectionFormOneGapUntilBothEnd() {
        var timeline = CatchUpTimeline()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        timeline.begin(.anotherCall, at: start)
        timeline.begin(.connection, at: start.addingTimeInterval(10))
        timeline.end(.anotherCall, at: start.addingTimeInterval(20))

        XCTAssertEqual(timeline.intervals.count, 1)
        XCTAssertTrue(timeline.intervals[0].isOngoing)
        XCTAssertEqual(timeline.intervals[0].reasons, [.anotherCall, .connection])

        timeline.end(.connection, at: start.addingTimeInterval(30))
        XCTAssertEqual(timeline.intervals[0].end, start.addingTimeInterval(30))
        XCTAssertEqual(timeline.unreadCount, 1)
        timeline.markReviewed()
        XCTAssertEqual(timeline.unreadCount, 0)
    }

    func testDelayedTranscriptCanBePlacedInEarlierGapWithoutClaimingCompleteness() {
        var timeline = CatchUpTimeline()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        timeline.begin(.anotherCall, at: start)
        timeline.end(.anotherCall, at: start.addingTimeInterval(60))

        let first = TranscriptSegment(id: "one", speaker: "Alex", text: "First draft",
                                      spokenAt: start.addingTimeInterval(20))
        let outside = TranscriptSegment(id: "two", speaker: "Sam", text: "After the call",
                                        spokenAt: start.addingTimeInterval(90))
        timeline.upsert([first, outside])
        timeline.upsert([TranscriptSegment(id: "one", speaker: "Alex", text: "Final wording",
                                           spokenAt: first.spokenAt)])

        XCTAssertEqual(timeline.segments.count, 2)
        XCTAssertEqual(timeline.transcript(during: timeline.intervals[0]).map(\.text), ["Final wording"])
    }

    func testUnknownProviderClockIsNotAssignedToMissedSpeech() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(CatchUpTimeline.providerDate(now.timeIntervalSince1970 * 1_000, now: now), now)
        XCTAssertNil(CatchUpTimeline.providerDate(42, now: now))

        var timeline = CatchUpTimeline()
        timeline.begin(.connection, at: now)
        timeline.end(.connection, at: now.addingTimeInterval(30))
        timeline.upsert([TranscriptSegment(id: "unknown", speaker: nil, text: "Words",
                                           spokenAt: nil)])
        XCTAssertTrue(timeline.transcript(during: timeline.intervals[0]).isEmpty)
    }

    func testRestoredHoldBecomesConnectionGapUntilConferenceReturns() throws {
        var timeline = CatchUpTimeline()
        let start = Date().addingTimeInterval(-120)
        timeline.begin(.anotherCall, at: start)
        timeline.upsert([TranscriptSegment(id: "line", speaker: "Alex", text: "Decision",
                                           spokenAt: start.addingTimeInterval(15))])

        let data = try JSONEncoder().encode(timeline)
        var restored = try JSONDecoder().decode(CatchUpTimeline.self, from: data)
        restored.resumeAfterRestart(at: start.addingTimeInterval(60))
        restored.end(.connection, at: start.addingTimeInterval(90))

        XCTAssertEqual(restored.intervals.count, 1)
        XCTAssertEqual(restored.intervals[0].reasons, [.anotherCall, .connection])
        XCTAssertEqual(restored.intervals[0].end, start.addingTimeInterval(90))
        XCTAssertEqual(restored.transcript(during: restored.intervals[0]).map(\.text), ["Decision"])
    }
}
