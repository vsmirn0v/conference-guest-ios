import Combine
import ConferenceCore
import XCTest
@testable import RockNRoll

@MainActor
final class ReactionHistoryStoreTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private func time(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }
    private func store(maximumEvents: Int = 2_000, maximumIdentityCount: Int = 8_000,
                       maximumGaps: Int = 128) -> ReactionHistoryStore {
        let store = ReactionHistoryStore(maximumEvents: maximumEvents,
            maximumIdentityCount: maximumIdentityCount, maximumGaps: maximumGaps,
            clock: { self.origin })
        store.beginMeeting()
        return store
    }
    @discardableResult
    private func receive(_ store: ReactionHistoryStore, _ seconds: Double = 0,
                         kind: MeetingReaction = .like, participant: String = "ani",
                         name: String? = "Ani", providerID: String? = nil) -> MeetingReactionEvent? {
        store.receive(kind: kind, participantID: participant, displayName: name,
                      providerEventID: providerID, receivedAt: time(seconds))
    }

    func testMeetingLifetimePreservesSameSessionAndRevokesOldCallbacks() throws {
        let store = ReactionHistoryStore()
        XCTAssertNil(receive(store))
        let meeting = UUID()
        store.beginMeeting(id: meeting)
        let first = try XCTUnwrap(receive(store))
        store.isReadingLatest = true
        store.beginMeeting(id: meeting)
        XCTAssertEqual(store.events, [first])
        XCTAssertTrue(store.isReadingLatest)
        store.beginGap(at: time(1))
        store.beginMeeting(id: UUID())
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(store.gaps.isEmpty)
        XCTAssertFalse(store.isReadingLatest)
        XCTAssertFalse(store.hasUnseenReactions)
        XCTAssertNil(store.receive(kind: .heart, participantID: "ani", displayName: "Ani",
                                   expectedMeetingID: meeting))
        store.endMeeting()
        XCTAssertNil(receive(store))
        XCTAssertNil(store.recordLocalSubmission(kind: .like, participantID: "me", displayName: "Me"))
        XCTAssertNil(store.meetingID)
    }

    func testExactIDsDeduplicateButSameKindSameTimeRepeatsRemainDistinct() throws {
        let store = store()
        let first = try XCTUnwrap(receive(store, providerID: "event-1"))
        XCTAssertNil(receive(store, 20, providerID: "event-1"))
        let second = try XCTUnwrap(receive(store, providerID: "event-2"))
        let third = try XCTUnwrap(receive(store))
        let fourth = try XCTUnwrap(receive(store))
        XCTAssertEqual(Set([first.id, second.id, third.id, fourth.id]).count, 4)
        XCTAssertEqual(store.events.map(\.sequence), [0, 1, 2, 3])
        XCTAssertEqual(store.projection().first?.reactionCounts[.like], 4)
        // Provider IDs are interpreted within their exact participant identity.
        XCTAssertNotNil(receive(store, participant: "max", name: "Max", providerID: "event-1"))
    }

    func testLocalSubmissionEchoReconciliationRequiresExactIdentityAndSubmission() throws {
        let store = store()
        let local = try XCTUnwrap(store.recordLocalSubmission(kind: .like, participantID: "me",
            displayName: "Me", submissionID: "submission-1", at: time(0)))
        XCTAssertTrue(local.isSeen)
        XCTAssertEqual(local.delivery, .submitted)
        XCTAssertFalse(store.hasUnseenReactions)
        XCTAssertNil(store.recordLocalSubmission(kind: .heart, participantID: "me", displayName: "Me",
                                                  submissionID: "submission-1"))
        XCTAssertNil(store.receive(kind: .like, participantID: "me", displayName: "Me", isOwn: true))
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.events[0].delivery, .submitted)
        XCTAssertNil(store.receive(kind: .heart, participantID: "me", displayName: "Me", isOwn: true,
                                   matchingLocalSubmissionID: "submission-1"))
        XCTAssertNil(store.receive(kind: .like, participantID: "different", displayName: "Me", isOwn: true,
                                   matchingLocalSubmissionID: "submission-1"))
        XCTAssertEqual(store.events[0].delivery, .submitted)
        XCTAssertNil(store.receive(kind: .like, participantID: "me", displayName: "Me", isOwn: true,
                                   providerEventID: "echo-1", providerTimestamp: time(2),
                                   matchingLocalSubmissionID: "submission-1"))
        XCTAssertEqual(store.events[0].delivery, .acknowledged)
        XCTAssertEqual(store.events[0].providerEventID, "echo-1")
        XCTAssertEqual(store.events[0].timestamp, local.timestamp)
        store.setLocalDelivery(.failed, submissionID: "submission-1")
        XCTAssertEqual(store.events[0].delivery, .acknowledged)
        XCTAssertEqual(store.events.count, 1)
    }

    func testFailedLocalSubmissionDoesNotQueueRetryOrBecomeUnread() throws {
        let store = store()
        let local = try XCTUnwrap(store.recordLocalSubmission(kind: .wave, participantID: "me",
            displayName: "Me", submissionID: "submission", at: time(0)))
        store.setLocalDelivery(.failed, submissionID: "submission")
        store.setLocalDelivery(.submitted, submissionID: "submission")
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.events[0].id, local.id)
        XCTAssertEqual(store.events[0].delivery, .failed)
        XCTAssertFalse(store.hasUnseenReactions)
        store.beginGap(at: time(1)); store.endGap(at: time(3))
        XCTAssertEqual(store.events[0].delivery, .failed)
    }

    func testSeenStateTracksVisibleEventsAndNewAdditionToSameGroup() throws {
        let store = store()
        let first = try XCTUnwrap(receive(store))
        let second = try XCTUnwrap(receive(store, 1))
        let groupID = try XCTUnwrap(store.projection().first?.id)
        store.isReadingLatest = true
        XCTAssertTrue(store.hasUnseenReactions, "Opening the latest view cannot acknowledge invisible rows")
        store.markSeen(ids: [first.id, "unknown"])
        XCTAssertTrue(store.hasUnseenReactions)
        XCTAssertEqual(store.projection().first?.unseenCount, 1)
        store.markSeen(ids: [second.id])
        XCTAssertFalse(store.hasUnseenReactions)
        let third = try XCTUnwrap(receive(store, 2))
        XCTAssertTrue(store.hasUnseenReactions)
        XCTAssertEqual(store.projection().first?.id, groupID)
        XCTAssertEqual(store.projection().first?.events.map(\.isSeen), [true, true, false])
        store.markSeen(ids: [third.id])
        XCTAssertFalse(store.hasUnseenReactions)
    }

    func testCapturedNamesSurviveRenamesAndUnknownNamesResolveOnlyOnceByID() throws {
        let store = store()
        receive(store)
        receive(store, 1, participant: "max", name: nil)
        receive(store, 2, participant: "other-max", name: nil)
        store.resolveUnknownParticipant(id: "ani", name: "Renamed Ani")
        store.resolveUnknownParticipant(id: "max", name: "Max")
        store.resolveUnknownParticipant(id: "max", name: "Renamed Max")
        XCTAssertEqual(store.events.map(\.displayName), ["Ani", "Max", nil])
        receive(store, 3, name: "Renamed Ani")
        XCTAssertEqual(store.events.first?.displayName, "Ani")
        XCTAssertEqual(store.events.last?.displayName, "Renamed Ani")
        XCTAssertEqual(store.projection().first?.participantCount, 3)
    }

    func testGroupingCapsBurstSpanAndSplitsOnChatMessages() {
        let store = store()
        for seconds in [0.0, 4, 8, 12, 18] { receive(store, seconds) }
        XCTAssertEqual(store.projection().map { $0.events.map(\.sequence) }, [[0, 1, 2], [3], [4]])
        XCTAssertEqual(store.projection(chatBoundaries: [time(6)]).map { $0.events.map(\.sequence) },
                       [[0, 1], [2, 3], [4]])
        XCTAssertEqual(store.projection(chatBoundaries: [time(4)]).map { $0.events.map(\.sequence) },
                       [[0], [1], [2, 3], [4]])
    }

    func testGroupingCountsEventsAndPeopleSeparatelyWithoutMutatingHistory() {
        let store = store()
        receive(store, kind: .like)
        receive(store, 1, kind: .like)
        receive(store, 2, kind: .heart, participant: "max", name: "Max")
        let original = store.events
        let group = store.projection()[0]
        XCTAssertEqual(group.reactionCounts, [.like: 2, .heart: 1])
        XCTAssertEqual(group.participantCount, 2)
        XCTAssertEqual(group.unseenCount, 3)
        _ = store.projection(chatBoundaries: [time(1.5)])
        XCTAssertEqual(store.events, original)
    }

    func testGapsSplitByReceiptSequenceDespiteProviderClockDifferences() throws {
        let store = store()
        store.receive(kind: .like, participantID: "ani", displayName: "Ani",
                      providerTimestamp: time(-60), receivedAt: time(0))
        store.beginGap(at: time(1)); store.beginGap(at: time(1.5))
        let gap = try XCTUnwrap(store.gaps.first)
        receive(store, 2)
        store.endGap(at: time(3)); store.endGap(at: time(4))
        receive(store, 4)
        XCTAssertEqual(store.gaps.count, 1)
        XCTAssertEqual(store.gaps[0].id, gap.id)
        XCTAssertEqual(store.gaps[0].start, time(1))
        XCTAssertEqual(store.gaps[0].end, time(3))
        XCTAssertEqual(store.projection().map { $0.events.count }, [1, 1, 1])
    }

    func testProviderTimestampUsedWhenKnownAndClockRollbackCannotMakeAnEndlessGroup() {
        let store = store()
        let timed = store.receive(kind: .like, participantID: "ani", displayName: "Ani",
            providerTimestamp: time(-60), receivedAt: time(0))
        XCTAssertEqual(timed?.timestamp, time(-60))
        receive(store, 1)
        receive(store, -1)
        XCTAssertEqual(store.projection().map { $0.events.count }, [1, 1, 1])
        let fallback = store.receive(kind: .heart, participantID: "ani", displayName: "Ani",
            providerTimestamp: Date(timeIntervalSince1970: .infinity), receivedAt: time(2))
        XCTAssertEqual(fallback?.timestamp, time(2))
    }

    func testEvictingOldGapDetailsCannotMergeEventsAcrossThatGap() {
        let store = store(maximumGaps: 1)
        receive(store)
        store.beginGap(at: time(1)); store.endGap(at: time(2))
        receive(store, 3)
        store.beginGap(at: time(4)); store.endGap(at: time(5))
        XCTAssertEqual(store.gaps.count, 1)
        XCTAssertTrue(store.hasTruncatedHistory)
        XCTAssertEqual(store.projection().map { $0.events.count }, [1, 1])
    }

    func testBoundedRetentionShowsTruncationAndDeduplicatesRecentEvictedEvents() {
        let store = store(maximumEvents: 2, maximumIdentityCount: 4, maximumGaps: 2)
        for index in 0..<3 { receive(store, Double(index), providerID: "event-\(index)") }
        XCTAssertEqual(store.events.map(\.sequence), [1, 2])
        XCTAssertTrue(store.hasTruncatedHistory)
        XCTAssertNil(receive(store, 3, providerID: "event-0"))
        store.markSeen(ids: store.events.map(\.id))
        XCTAssertFalse(store.hasUnseenReactions)
        for index in 3..<20 { receive(store, Double(index), providerID: "event-\(index)") }
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.retainedIdentityCount, 4)
        for index in 0..<10 { store.beginGap(at: time(Double(index))); store.endGap(at: time(Double(index + 1))) }
        XCTAssertEqual(store.gaps.count, 2)
        store.endMeeting()
        XCTAssertEqual(store.retainedIdentityCount, 0)
        XCTAssertTrue(store.gaps.isEmpty)
        XCTAssertFalse(store.hasTruncatedHistory)
    }

    func testInvalidInputCannotPoisonIdentityDedupOrRetainUnboundedNames() {
        let store = store()
        XCTAssertNil(store.receive(kind: .like, participantID: "ani", displayName: "Ani",
            providerEventID: "event", receivedAt: Date(timeIntervalSince1970: .nan)))
        XCTAssertNotNil(receive(store, providerID: "event"))
        XCTAssertNil(receive(store, participant: ""))
        XCTAssertNil(receive(store, providerID: ""))
        XCTAssertNil(receive(store, participant: String(repeating: "p", count: 1_025)))
        XCTAssertNotNil(receive(store, name: String(repeating: "n", count: 1_025)))
        XCTAssertNil(store.events.last?.displayName)
    }

    func testRepeatedVisibilityAndUnknownNameUpdatesDoNotRepublishHistory() throws {
        let store = store()
        let event = try XCTUnwrap(receive(store))
        store.markSeen(ids: [event.id])
        var publications = 0
        let subscription = store.$events.dropFirst().sink { _ in publications += 1 }
        store.markSeen(ids: [event.id])
        store.resolveUnknownParticipant(id: "ani", name: "Someone else")
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(subscription) {}
    }
}
