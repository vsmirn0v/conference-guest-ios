import CallKit
import XCTest
import JazzSDK
@testable import RockNRoll

@MainActor
final class SessionOwnershipTests: XCTestCase {
    // Record acknowledgments at the delegate boundary: these local actions
    // are not attached to a system transaction.
    private final class StartAction: CXStartCallAction {
        var fulfilled = false
        override func fulfill() { fulfilled = true }
    }
    private final class HoldAction: CXSetHeldCallAction {
        var fulfilled = false
        override func fulfill() { fulfilled = true }
    }

    func testMeetingAdvertisesHoldSupportAtStartAndConnection() throws {
        var transactions: [CXTransaction] = []
        var updates: [(UUID, CXCallUpdate)] = []
        let calls = SystemCallCoordinator(transactionRequester: { transaction, completion in
            transactions.append(transaction); completion(nil)
        }, callUpdateReporter: { updates.append(($0, $1)) })
        let configuration = SystemCallCoordinator.providerConfiguration()
        XCTAssertEqual(configuration.maximumCallGroups, 2)
        XCTAssertEqual(configuration.maximumCallsPerCallGroup, 1)
        let provider = CXProvider(configuration: configuration)
        calls.start()
        let requested = try XCTUnwrap(transactions.first?.actions.first as? CXStartCallAction)
        let start = StartAction(call: requested.callUUID, handle: requested.handle)
        calls.provider(provider, perform: start)
        XCTAssertTrue(start.fulfilled)
        XCTAssertEqual(updates.count, 1)
        calls.markConnected()
        XCTAssertEqual(updates.count, 2)
        for (id, update) in updates {
            XCTAssertEqual(id, calls.callID)
            XCTAssertTrue(update.supportsHolding)
            XCTAssertFalse(update.supportsGrouping)
            XCTAssertFalse(update.supportsUngrouping)
            XCTAssertFalse(update.supportsDTMF)
        }
        let count = transactions.count
        calls.start()
        XCTAssertEqual(transactions.count, count, "Two system groups must not start a second meeting")
        calls.markEnded(reason: .remoteEnded)
    }

    func testSystemHoldAndResumeKeepMeetingIdentityAndMuteIntent() throws {
        let calls = SystemCallCoordinator(transactionRequester: { _, completion in completion(nil) })
        var holds: [Bool] = []
        var muteChanges = 0, ends = 0
        calls.onHoldChanged = { holds.append($0) }
        calls.onMuteChanged = { _ in muteChanges += 1 }
        calls.onEnded = { _ in ends += 1 }
        calls.start()
        let id = try XCTUnwrap(calls.callID)
        let provider = CXProvider(configuration: SystemCallCoordinator.providerConfiguration())
        for held in [true, false] {
            let action = HoldAction(call: id, onHold: held)
            calls.provider(provider, perform: action)
            XCTAssertTrue(action.fulfilled)
            XCTAssertEqual(calls.callID, id)
        }
        XCTAssertEqual(holds, [true, false])
        XCTAssertEqual(muteChanges, 0)
        XCTAssertEqual(ends, 0)
        calls.markEnded(reason: .remoteEnded)
    }

    func testTimedOutHoldCallbacksCannotCompleteNewResume() async throws {
        var transactions: [CXTransaction] = []
        var completions: [(Error?) -> Void] = []
        let calls = SystemCallCoordinator(transactionRequester: { transaction, callback in
            transactions.append(transaction); completions.append(callback)
        })
        calls.start()
        let hold = Task { try? await calls.setTransferHeld(true) }
        while transactions.count < 2 { await Task.yield() }
        let oldHold = try XCTUnwrap(transactions[1].actions.first as? CXSetHeldCallAction)
        let oldError = completions[1]
        await hold.value // Exercise the real eight-second deadline.
        var finished = false
        var resumeError: Error?
        let resume = Task {
            do { try await calls.setTransferHeld(false) } catch { resumeError = error }
            finished = true
        }
        while transactions.count < 3 { await Task.yield() }
        let resumeAction = try XCTUnwrap(transactions[2].actions.first as? CXSetHeldCallAction)
        let provider = CXProvider(configuration: CXProviderConfiguration())
        oldError(NSError(domain: "OldHold", code: 1))
        calls.provider(provider, perform: oldHold)
        await withCheckedContinuation { result in DispatchQueue.main.async { result.resume() } }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(finished, "Neither the old error nor its late action acknowledges the new resume")
        calls.provider(provider, perform: resumeAction)
        await resume.value
        XCTAssertNil(resumeError)
        calls.markEnded(reason: .remoteEnded)
    }

    func testDelayedEndFailureCannotEndNewCall() async {
        var completions: [(Error?) -> Void] = []
        let calls = SystemCallCoordinator(transactionRequester: { _, callback in completions.append(callback) })
        var ended = 0
        calls.onEnded = { _ in ended += 1 }
        calls.start()
        let first = calls.callID
        calls.end()
        let endOfA = completions.last!
        calls.markEnded(reason: .remoteEnded)
        calls.start()
        let second = calls.callID
        XCTAssertNotEqual(first, second)
        endOfA(NSError(domain: "delayed-end", code: 1))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(calls.callID, second)
        XCTAssertEqual(ended, 0)
        calls.markEnded(reason: .remoteEnded)
    }

    func testRoomIdentityDoesNotRequireSDKLinkBuilder() {
        let expected = JazzRoom(id: "room", decodedPassword: "secret", host: "meeting.example.test")
        XCTAssertTrue(EventRelay.matches(expected, expected))
        XCTAssertFalse(EventRelay.matches(JazzRoom(id: "other", decodedPassword: "secret", host: expected.host), expected))
        XCTAssertFalse(EventRelay.matches(JazzRoom(id: expected.id, decodedPassword: "secret", host: "other.example.test"), expected))
    }

    func testQueuedRelayEventRetainsOriginalRecipient() async {
        let relay = EventRelay()
        var a = 0
        var b = 0
        relay.onEvent = { _, _ in a += 1 }
        relay.deliver(.left)
        relay.onEvent = { _, _ in b += 1 }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(a, 1)
        XCTAssertEqual(b, 0)
    }

    func testQueuedMediaReadinessCannotCompleteReplacementAttempt() async {
        let relay = EventRelay()
        var old = 0, replacement = 0
        relay.onMediaConnected = { old += 1 }
        relay.onMediaConnectionEstablished(timeInterval: 0.1)
        relay.onMediaConnected = { replacement += 1 }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(old, 1)
        XCTAssertEqual(replacement, 0)
        relay.onMediaConnectionEstablished(timeInterval: 0.2)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(replacement, 1)
    }
}
