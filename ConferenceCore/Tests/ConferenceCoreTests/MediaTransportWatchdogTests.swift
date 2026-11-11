import XCTest
@testable import ConferenceCore

final class MediaTransportWatchdogTests: XCTestCase {
    private let primaryPeer = UUID()

    private func sample(_ inbound: Int64, _ ice: MediaTransportWatchdog.ICE = .connected,
                        peer: UUID? = nil, pair: String = "selected") -> [MediaTransportWatchdog.Sample] {
        [.init(peer: peer ?? primaryPeer, ice: ice, selectedPairs: [pair: inbound])]
    }

    func testReconnectRequiresSustainedConnectedTransportAndCounterProgress() {
        let pair = MediaTransportRecoveryConfirmation.Pair(peer: UUID(), pair: "pair")
        var confirmation = MediaTransportRecoveryConfirmation()
        XCTAssertFalse(confirmation.observe([pair: 4], at: 2))
        XCTAssertFalse(confirmation.observe([pair: 4], at: 6))
        XCTAssertFalse(confirmation.observe([pair: 7], at: 20))
        XCTAssertFalse(confirmation.observe([:], at: 22))
        XCTAssertFalse(confirmation.observe([pair: 10], at: 24))
        XCTAssertFalse(confirmation.observe([pair: 12], at: 26))
        XCTAssertTrue(confirmation.observe([pair: 13], at: 28))
    }

    func testReconnectRequiresProgressOnEachPeerAndRebaselinesAfterPairChanges() {
        let sender = MediaTransportRecoveryConfirmation.Pair(peer: UUID(), pair: "sender")
        let receiver = MediaTransportRecoveryConfirmation.Pair(peer: UUID(), pair: "receiver")
        let replacement = MediaTransportRecoveryConfirmation.Pair(peer: receiver.peer, pair: "replacement")
        var confirmation = MediaTransportRecoveryConfirmation()
        XCTAssertFalse(confirmation.observe([sender: 1, receiver: 1], at: 0))
        XCTAssertFalse(confirmation.observe([sender: 100, receiver: 1], at: 4))
        XCTAssertFalse(confirmation.observe([sender: 101, replacement: 500], at: 6))
        XCTAssertFalse(confirmation.observe([sender: 102, replacement: 501], at: 8))
        XCTAssertFalse(confirmation.observe([sender: 103, replacement: 5], at: 10))
        XCTAssertTrue(confirmation.observe([sender: 105, replacement: 7], at: 14))
    }

    func testReconnectRebaselinesWhenAnOpenPeerJoinsTheObservation() {
        let sender = MediaTransportRecoveryConfirmation.Pair(peer: UUID(), pair: "selected")
        let receiver = MediaTransportRecoveryConfirmation.Pair(peer: UUID(), pair: "selected")
        var confirmation = MediaTransportRecoveryConfirmation()
        XCTAssertFalse(confirmation.observe([sender: 1], at: 0))
        XCTAssertFalse(confirmation.observe([sender: 2, receiver: 8], at: 4))
        XCTAssertFalse(confirmation.observe([sender: 3, receiver: 8], at: 8))
        XCTAssertTrue(confirmation.observe([sender: 4, receiver: 9], at: 10))
    }

    func testAdvancingTransportStaysHealthy() {
        var watchdog = MediaTransportWatchdog()
        for step in 0..<30 { XCTAssertNil(watchdog.observe(sample(Int64(step * 100)), at: Double(step * 2))) }
    }

    func testFrozenInboundReportsOnceAfterSilenceLimit() {
        var watchdog = MediaTransportWatchdog()
        XCTAssertNil(watchdog.observe(sample(500), at: 0))
        XCTAssertNil(watchdog.observe(sample(600), at: 2))
        XCTAssertNil(watchdog.observe(sample(600), at: 4))
        XCTAssertNil(watchdog.observe(sample(600), at: 10))
        XCTAssertEqual(watchdog.observe(sample(600), at: 12), .noInbound)
        XCTAssertNil(watchdog.observe(sample(600), at: 14))
        watchdog.reset()
        XCTAssertNil(watchdog.observe(sample(600), at: 16))
        XCTAssertNil(watchdog.observe(sample(600), at: 18))
    }

    func testHealthyPublisherCannotHideFrozenSubscriberSelectedPair() {
        let receiver = UUID()
        var watchdog = MediaTransportWatchdog()
        for step in 0..<5 {
            let peers = sample(Int64(step), peer: primaryPeer) + sample(10, peer: receiver)
            XCTAssertNil(watchdog.observe(peers, at: Double(step * 2)))
        }
        XCTAssertEqual(watchdog.observe(sample(5) + sample(10, peer: receiver), at: 10), .noInbound)
    }

    func testPairChangeAndPeerReplacementDiscardTheOldStallInterval() {
        var watchdog = MediaTransportWatchdog()
        XCTAssertNil(watchdog.observe(sample(8), at: 0))
        XCTAssertNil(watchdog.observe(sample(8), at: 6))
        XCTAssertNil(watchdog.observe(sample(8, pair: "new"), at: 10))
        XCTAssertNil(watchdog.observe(sample(8, pair: "new"), at: 16))
        XCTAssertNil(watchdog.observe(sample(8, peer: UUID(), pair: "new"), at: 20))
    }

    func testFailedICEReportsImmediately() {
        var watchdog = MediaTransportWatchdog()
        XCTAssertNil(watchdog.observe(sample(1), at: 0))
        XCTAssertEqual(watchdog.observe(sample(2, .failed), at: 2), .iceFailed)
    }

    func testDisconnectedICEGetsGraceAndRecoveryClearsIt() {
        var watchdog = MediaTransportWatchdog()
        XCTAssertNil(watchdog.observe(sample(1, .disconnected), at: 0))
        XCTAssertNil(watchdog.observe(sample(2, .disconnected), at: 4))
        XCTAssertNil(watchdog.observe(sample(3, .connected), at: 6))
        XCTAssertNil(watchdog.observe(sample(4, .disconnected), at: 8))
        XCTAssertNil(watchdog.observe(sample(5, .disconnected), at: 14))
        XCTAssertEqual(watchdog.observe(sample(6, .disconnected), at: 16), .iceDisconnected)
    }

    func testSuspendedProcessGapStartsOver() {
        var watchdog = MediaTransportWatchdog()
        XCTAssertNil(watchdog.observe(sample(7), at: 0))
        XCTAssertNil(watchdog.observe(sample(7), at: 60))
        XCTAssertNil(watchdog.observe(sample(7), at: 62))
    }

    func testNoTransportsAndReplacedCountersAreNotStalls() {
        var watchdog = MediaTransportWatchdog()
        XCTAssertNil(watchdog.observe(sample(900), at: 0))
        XCTAssertNil(watchdog.observe([], at: 2))
        XCTAssertNil(watchdog.observe(sample(10), at: 4))
        XCTAssertNil(watchdog.observe(sample(5), at: 6))
        XCTAssertNil(watchdog.observe(sample(5), at: 10))
        XCTAssertNil(watchdog.observe(sample(5), at: 14))
        XCTAssertEqual(watchdog.observe(sample(5), at: 16), .noInbound)
    }

    func testStallTriggersImmediateRebuildOnlyForConnectedMeeting() {
        var fresh = CallNetworkRecovery()
        fresh.mediaStalled(at: 5)
        XCTAssertFalse(fresh.requiresRecovery)

        var recovery = CallNetworkRecovery()
        recovery.pathChanged(available: true, at: 0)
        recovery.connected()
        recovery.mediaStalled(at: 5)
        XCTAssertTrue(recovery.requiresRecovery)
        XCTAssertNil(recovery.nextAction(at: 5, blocked: true))
        XCTAssertEqual(recovery.nextAction(at: 5, blocked: false), .restart)
        recovery.attemptFinished(succeeded: true, at: 7)
        XCTAssertFalse(recovery.requiresRecovery)
    }
}
