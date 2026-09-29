import CallKit
import XCTest
import JazzSDK
@testable import RockNRoll

@MainActor
final class SessionOwnershipTests: XCTestCase {
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
}
