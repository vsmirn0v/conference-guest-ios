import ConferenceCore
import XCTest
@testable import RockNativeDesktop

@MainActor final class AttentionMomentsTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)
    private let verdict = AttentionVerdict(level: .now, probability: 0.9, reason: "Anna needs an answer.", evidence: ["a"], action: .chat)
    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func store(_ root: URL? = nil) -> AttentionStore {
        let defaults = UserDefaults(suiteName: "moments-\(UUID())")!
        let keys = AttentionKeychain(service: "moments-tests-\(UUID())")
        addTeardownBlock { keys.deleteAll() }
        return AttentionStore(root: root ?? folder(), defaults: defaults, keychain: keys)
    }
    private func record(_ outcome: AttentionDecisionRecord.Outcome, id: UUID = UUID(), decision: UUID? = nil,
                        meeting: UUID? = UUID(), title: String = "Infra") -> AttentionDecisionRecord {
        .init(id: id, at: at, meetingTitle: title, meetingID: meeting, invitation: URL(string: "https://example.test/infra"),
              presetID: nil, window: nil, verdict: [.shown, .crowdedOut].contains(outcome) ? verdict : nil,
              provider: "local", model: "m", outcome: outcome, decisionID: decision)
    }

    func testReducerTracksStatesDraftsResponsesAndUnread() {
        var history = AttentionMomentHistory()
        let id = UUID()
        history.apply(record(.shown, id: id))
        XCTAssertEqual(history.moment(id)?.state, .live); XCTAssertEqual(history.unreadCount, 1)
        history.apply(record(.seen, decision: id))
        XCTAssertEqual(history.moment(id)?.state, .live); XCTAssertEqual(history.unreadCount, 0)
        history.apply(record(.missed, decision: id))
        XCTAssertEqual(history.moment(id)?.state, .missed)
        history.apply(record(.drafted, decision: id))
        history.apply(record(.replied, decision: id))
        XCTAssertEqual(history.moment(id)?.state, .answered); XCTAssertTrue(history.moment(id)?.seen == true)
        history.apply(record(.reminded, decision: id))
        XCTAssertEqual(history.moment(id)?.reminderAt, at.addingTimeInterval(600))
        XCTAssertEqual(history.moments(filter: .answered).count, 1)
        XCTAssertEqual(history.moments(filter: nil).count, 1)
    }

    func testSeenDoesNotChangeRecencyOrdering() throws {
        var history = AttentionMomentHistory()
        let id = UUID(), seenAt = at.addingTimeInterval(300)
        history.apply(record(.shown, id: id))
        let originalUpdate = try XCTUnwrap(history.moment(id)?.updatedAt)
        let records = history.markSeen([id], at: seenAt)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.at, seenAt)
        XCTAssertEqual(history.moment(id)?.updatedAt, originalUpdate)
        history.apply(try XCTUnwrap(records.first))
        XCTAssertEqual(history.moment(id)?.updatedAt, originalUpdate, "Journal replay must also preserve recency")
    }

    func testCrowdedOutDismissDeclineAndQuietAggregation() {
        var history = AttentionMomentHistory()
        let crowded = UUID(), dismissed = UUID(), declined = UUID(), meeting = UUID()
        history.apply(record(.crowdedOut, id: crowded, meeting: meeting))
        history.apply(record(.shown, id: dismissed, meeting: meeting)); history.apply(record(.dismissed, decision: dismissed, meeting: meeting))
        history.apply(record(.shown, id: declined, meeting: meeting)); history.apply(record(.declined, decision: declined, meeting: meeting))
        history.apply(record(.belowThreshold, meeting: meeting)); history.apply(record(.belowThreshold, meeting: meeting))
        history.apply(record(.failed, meeting: meeting)); history.apply(record(.draftFailed, meeting: meeting))
        XCTAssertEqual(history.moment(crowded)?.state, .missed); XCTAssertEqual(history.unreadCount, 1)
        XCTAssertEqual(history.moment(dismissed)?.state, .dismissed)
        XCTAssertEqual(history.moment(declined)?.state, .notForMe)
        XCTAssertEqual(history.quietChecks.count, 1); XCTAssertEqual(history.quietChecks[0].count, 2)
        XCTAssertEqual(history.moments.count, 3, "Diagnostics never create Moments")
    }

    func testHistoricalLiveBecomesMissedAndLookupFindsTheRightMoment() {
        let records = (0..<10_000).map { index in record(index % 3 == 0 ? .shown : .belowThreshold) }
        let history = AttentionDecisionJournal.reduce(records)
        let shown = records.filter { $0.outcome == .shown }
        XCTAssertEqual(history.moments.count, shown.count)
        XCTAssertTrue(history.moments.allSatisfy { $0.state == .missed })
        XCTAssertEqual(history.moment(records[3].id)?.meetingTitle, "Infra")
        XCTAssertNil(history.moment(UUID()))
        XCTAssertEqual(history.quietChecks.reduce(0) { $0 + $1.count }, records.filter { $0.outcome == .belowThreshold }.count)
    }

    func testFileOrderKeepsASameSecondFollowUpFromErasingTheMoment() {
        let id = UUID()
        var shown = record(.shown, id: id)
        shown.at = at.addingTimeInterval(2)
        var replied = record(.replied, decision: id)
        replied.at = at.addingTimeInterval(2)
        var again = record(.shown, id: UUID(), decision: id)
        again.at = at.addingTimeInterval(2)
        var draft = record(.drafted, decision: id)
        draft.at = at
        draft.draft = .init(chat: "Yes", reaction: nil)
        let history = AttentionDecisionJournal.reduce([shown, replied, again, draft])
        XCTAssertEqual(history.moment(id)?.state, .answered, "A later shown record in the same second must not reopen an answer")
        XCTAssertEqual(history.moment(id)?.draft?.chat, "Yes", "A draft written after the card, even with an earlier timestamp, is kept")
    }

    func testLegacyRecordDecodesWithoutMeetingIdentity() throws {
        let old = record(.shown)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.attention.encode(old)) as? [String: Any])
        object.removeValue(forKey: "meetingID"); object.removeValue(forKey: "invitation"); object.removeValue(forKey: "seriesID")
        let decoded = try JSONDecoder.attention.decode(AttentionDecisionRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.meetingID); XCTAssertEqual(decoded.outcome, .shown)
        var history = AttentionMomentHistory(); history.apply(decoded); history.settleHistoricalLive()
        XCTAssertEqual(history.moment(old.id)?.state, .missed)
    }

    func testStoreRestoresAndBuffersEventsWrittenDuringLaunchLoad() async throws {
        let root = folder(), first = store(root), id = UUID(), meetingID = UUID()
        first.log(record(.shown, id: id, meeting: meetingID))
        await first.waitForMoments()
        let second = store(root)
        second.log(record(.replied, decision: id, meeting: meetingID))
        second.log(record(.belowThreshold, meeting: meetingID))
        await second.waitForMoments()
        XCTAssertEqual(second.momentHistory.moment(id)?.state, .answered)
        XCTAssertEqual(second.momentHistory.quietChecks.first?.count, 1, "Buffered quiet checks must not be counted twice when merged with disk")
        let third = store(root); await third.waitForMoments()
        XCTAssertEqual(third.momentHistory.moment(id)?.state, .answered)
        XCTAssertEqual(third.momentHistory.quietChecks.first?.count, 1)
        XCTAssertEqual(third.decisionFiles().count, 1, "Restoration does not rewrite history")
    }

    func testSinceThenWindowIsExclusiveAndBounded() {
        let after = at
        let transcript = (0..<80).map { index in
            GuestMeetingMessage(id: "t\(index)", participantID: "a", participantName: "Anna", text: "Line \(index)",
                                sentAt: after.addingTimeInterval(Double(index)), isOwn: false)
        }
        let window = AttentionWindowBuilder.build(.init(title: "Infra", transcript: transcript, chat: [], reactions: [],
            participantCount: 2, yourNames: [], microphoneOn: false, soundOn: false, now: after.addingTimeInterval(100), after: after))
        XCTAssertEqual(window.lines.count, 60); XCTAssertEqual(window.lines.first?.id, "t20")
        XCTAssertFalse(window.lines.contains { $0.id == "t0" }, "The Moment's own instant is not later content")
    }

    func testReminderIsScheduledOnceAndJournaled() async throws {
        let store = store(), coordinator = AttentionCoordinator(store: store), id = UUID()
        store.log(record(.crowdedOut, id: id))
        var scheduled: Date?
        coordinator.now = { self.at }
        coordinator.scheduleReminder = { _, at in scheduled = at }
        let moment = try XCTUnwrap(store.momentHistory.moment(id))
        coordinator.remind(moment)
        for _ in 0..<100 where scheduled == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(scheduled, at.addingTimeInterval(600))
        XCTAssertEqual(store.momentHistory.moment(id)?.reminderAt, at.addingTimeInterval(600))
    }

    func testSummaryParsingAndBounds() throws {
        XCTAssertEqual(try MomentSummaryPrompt.parse("{\"summary\":\" Anna answered. \"}"), "Anna answered.")
        XCTAssertThrowsError(try MomentSummaryPrompt.parse("{}"))
    }
}
