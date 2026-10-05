import CallKit
import XCTest
import JazzSDK
@testable import RockNRoll

@MainActor
final class SessionOwnershipTests: XCTestCase {
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
