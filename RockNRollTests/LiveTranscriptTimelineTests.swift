import ConferenceCore
import Foundation
import XCTest
@testable import RockNRoll

@MainActor
final class LiveTranscriptTimelineTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testChronologicalMergeExcludesReactionsBeforeFirstDatedSegment() throws {
        let rows = LiveTranscriptTimeline.rows(
            segments: [
                segment("one", at: base.addingTimeInterval(10)),
                segment("two", at: base.addingTimeInterval(30))
            ],
            reactions: [
                try event(.wave, at: base.addingTimeInterval(5)),
                try event(.heart, at: base.addingTimeInterval(20)),
                try event(.like, at: base.addingTimeInterval(40))
            ])

        XCTAssertEqual(labels(rows), ["one", "heart", "two", "like"])
    }

    func testEmptyTranscriptIncludesAllReactions() throws {
        let rows = LiveTranscriptTimeline.rows(
            segments: [],
            reactions: [try event(.heart, at: base), try event(.like, at: base.addingTimeInterval(1))])

        XCTAssertEqual(labels(rows), ["heart", "like"])
    }

    func testEqualTimestampKeepsTranscriptLineBeforeReaction() throws {
        let rows = LiveTranscriptTimeline.rows(
            segments: [segment("line", at: base)],
            reactions: [try event(.heart, at: base)])

        XCTAssertEqual(labels(rows), ["line", "heart"])
    }

    func testTrailingUndatedLineKeepsItsPlaceWithoutGainingATimestamp() throws {
        let undated = segment("unknown", at: nil)
        let rows = LiveTranscriptTimeline.rows(
            segments: [
                segment("one", at: base),
                segment("two", at: base.addingTimeInterval(20)),
                undated
            ],
            reactions: [try event(.heart, at: base.addingTimeInterval(10))])

        XCTAssertEqual(labels(rows), ["one", "heart", "two", "unknown"])
        guard case .line(let stored)? = rows.last else { return XCTFail("Last row must remain a transcript line") }
        XCTAssertNil(stored.spokenAt)
        XCTAssertEqual(stored.id, undated.id)
    }

    func testEntirelyUndatedTranscriptKeepsOriginalNilTimestamps() throws {
        let rows = LiveTranscriptTimeline.rows(
            segments: [segment("one", at: nil), segment("two", at: nil)],
            reactions: [try event(.heart, at: base)])

        XCTAssertEqual(labels(rows), ["one", "two", "heart"])
        for row in rows.prefix(2) {
            guard case .line(let segment) = row else { return XCTFail("Expected transcript lines") }
            XCTAssertNil(segment.spokenAt)
        }
    }

    private func segment(_ text: String, at date: Date?) -> TranscriptSegment {
        TranscriptSegment(id: text, speaker: "Musician", text: text, spokenAt: date)
    }

    private func event(_ kind: MeetingReaction, at date: Date,
                       displayName: String? = "Ani") throws -> MeetingReactionEvent {
        let store = ReactionHistoryStore()
        store.beginMeeting(id: UUID())
        return try XCTUnwrap(store.receive(kind: kind, participantID: "participant", displayName: displayName,
                                           providerTimestamp: date, receivedAt: date))
    }

    private func labels(_ rows: [LiveTranscriptRow]) -> [String] {
        rows.map { row in
            switch row {
            case .line(let segment): return segment.text
            case .reaction(let event): return event.kind.rawValue
            }
        }
    }
}
