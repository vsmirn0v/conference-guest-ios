import ConferenceCore
import XCTest
@testable import RockNRoll

@MainActor
final class ReactionSubmissionTests: XCTestCase {
    func testRepeatedOwnReactionsFloatOnlyAfterAcceptanceAndNeverDuplicateCompletion() {
        let sender = ReactionSubmission(valid: { true })
        var ids: [String] = [], floated: [MeetingReaction] = [], completions: [(Bool) -> Void] = []
        sender.onAccepted = { _, id in ids.append(id) }
        sender.onTransmitted = { kind, _ in floated.append(kind) }
        for _ in 0..<2 { XCTAssertTrue(sender.send(.heart) { completions.append($0); return true }) }
        XCTAssertEqual(Set(ids).count, 2); XCTAssertTrue(floated.isEmpty)
        completions[1](true); completions[0](true); completions[0](true)
        XCTAssertEqual(floated, [.heart, .heart])
    }
    func testFailedRejectedAndRetiredSendsCannotFloat() {
        var valid = true
        let sender = ReactionSubmission(valid: { valid })
        var failures: [String] = [], completions: [(Bool) -> Void] = [], submitted = 0
        sender.onAccepted = { _, _ in submitted += 1 }
        sender.onFailed = { failures.append($0) }
        sender.onTransmitted = { _, _ in XCTFail("Failed or stale reaction floated") }
        XCTAssertFalse(sender.send(.like) { _ in false })
        XCTAssertTrue(sender.send(.like) { completions.append($0); return true })
        completions[0](false); XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(sender.send(.heart) { completions.append($0); return true })
        valid = false; completions[1](true)
        valid = true
        XCTAssertTrue(sender.send(.like) { completions.append($0); return true })
        sender.stop(); completions[2](true)
        XCTAssertFalse(sender.send(.like) { _ in XCTFail("Stopped send called transport"); return true })
        XCTAssertEqual(submitted, 3); XCTAssertEqual(failures.count, 1)
    }
    func testLegacySynchronousCompletionRecordsHistoryBeforeFeedback() {
        let sender = ReactionSubmission(valid: { true })
        var events: [String] = []
        sender.onAccepted = { _, _ in events.append("history") }
        sender.onTransmitted = { _, _ in events.append("float") }
        XCTAssertTrue(sender.send(.like) { done in done(true); return true })
        XCTAssertEqual(events, ["history", "float"])
    }
}
