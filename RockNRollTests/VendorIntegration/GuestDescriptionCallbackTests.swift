import Foundation
import WebRTC
import XCTest
@testable import RockNRoll

final class GuestDescriptionCallbackTests: XCTestCase {
    func testClosingPeerInsideDescriptionCallbackDoesNotDeliverItTwice() async throws {
        guard GuestConferencePlayoutReservation.isSupported else {
            throw XCTSkip("Requires the rebuilt guest WebRTC")
        }
        for _ in 0..<10 {
            let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                                  decoderFactory: RTCDefaultVideoDecoderFactory())
            let configuration = RTCConfiguration()
            configuration.sdpSemantics = .unifiedPlan
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            let peer = try XCTUnwrap(factory.peerConnection(with: configuration, constraints: constraints, delegate: nil))
            _ = peer.dataChannel(forLabel: "reentrant-close", configuration: RTCDataChannelConfiguration())
            let callbacks = expectation(description: "Both pending offers complete once")
            callbacks.expectedFulfillmentCount = 2
            callbacks.assertForOverFulfill = true
            let owner = ReentrantPeerOwner(peer: peer)
            for _ in 0..<2 {
                peer.offer(for: constraints) { description, error in
                    if let selected = owner.take() {
                        XCTAssertNotNil(description, "The first offer must succeed: \(String(describing: error))")
                        // Same signaling thread: exercises destruction of the
                        // description factory while its notification is running.
                        selected.close()
                    }
                    callbacks.fulfill()
                }
            }
            await fulfillment(of: [callbacks], timeout: 5)
            XCTAssertNil(owner.take())
        }
    }
}

private final class ReentrantPeerOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var peer: RTCPeerConnection?
    init(peer: RTCPeerConnection) { self.peer = peer }
    func take() -> RTCPeerConnection? {
        lock.lock(); defer { lock.unlock() }
        let selected = peer; peer = nil
        return selected
    }
}
