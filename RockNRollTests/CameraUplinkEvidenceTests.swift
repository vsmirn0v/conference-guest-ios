import XCTest
@testable import RockNRoll

final class CameraUplinkEvidenceTests: XCTestCase {
    private func sample(_ time: Double, _ network: CameraQualityPolicy.Network = .poor,
                        identity: String = "camera-a/transport-a") -> CameraUplinkSample {
        .init(identity: identity, timestamp: time, network: network)
    }

    func testTwoDistinctPoorSamplesAreRequired() {
        var evidence = CameraUplinkEvidence()
        let first = evidence.consume(sample(10))
        XCTAssertEqual(first.network, .ordinary); XCTAssertTrue(first.changed)
        let second = evidence.consume(sample(20))
        XCTAssertEqual(second.network, .poor); XCTAssertFalse(second.changed)
        XCTAssertEqual(evidence.consume(sample(30)).network, .poor)
    }

    func testDuplicateAndOlderSamplesBreakQualificationWithoutAdvancingTime() {
        var evidence = CameraUplinkEvidence()
        _ = evidence.consume(sample(20))
        let duplicate = evidence.consume(sample(20))
        XCTAssertEqual(duplicate.network, .unknown); XCTAssertFalse(duplicate.changed)
        XCTAssertEqual(evidence.consume(sample(30)).network, .ordinary)
        XCTAssertEqual(evidence.consume(sample(25)).network, .unknown)
        XCTAssertEqual(evidence.consume(sample(30)).network, .unknown)
        XCTAssertEqual(evidence.consume(sample(40)).network, .ordinary)
        XCTAssertEqual(evidence.consume(sample(50)).network, .poor)
    }

    func testMissingSamplesBreakContinuityAndStillRejectReplay() {
        var evidence = CameraUplinkEvidence()
        _ = evidence.consume(sample(10))
        let missing = evidence.consume(nil)
        XCTAssertEqual(missing.network, .unknown); XCTAssertFalse(missing.changed)
        XCTAssertEqual(evidence.consume(sample(10)).network, .unknown)
        XCTAssertEqual(evidence.consume(sample(20)).network, .ordinary)
        XCTAssertEqual(evidence.consume(sample(30)).network, .poor)
        XCTAssertEqual(evidence.consume(nil).network, .unknown)
        XCTAssertEqual(evidence.consume(sample(40)).network, .ordinary)
    }

    func testNonfiniteTimestampsNeverQualifyNetworkHealth() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            var evidence = CameraUplinkEvidence()
            _ = evidence.consume(sample(10))
            let result = evidence.consume(sample(invalid, .excellent))
            XCTAssertEqual(result.network, .unknown); XCTAssertFalse(result.changed)
            XCTAssertEqual(evidence.consume(sample(10, .excellent)).network, .unknown)
            XCTAssertEqual(evidence.consume(sample(20)).network, .ordinary)
            XCTAssertEqual(evidence.consume(sample(30)).network, .poor)
        }
    }

    func testReplacementTransportCannotInheritPreviousPoorCountOrTimestamp() {
        var evidence = CameraUplinkEvidence()
        _ = evidence.consume(sample(100))
        _ = evidence.consume(sample(200))
        let replacement = evidence.consume(sample(1, identity: "camera-a/transport-b"))
        XCTAssertEqual(replacement.network, .ordinary); XCTAssertTrue(replacement.changed)
        let next = evidence.consume(sample(2, identity: "camera-a/transport-b"))
        XCTAssertEqual(next.network, .poor); XCTAssertFalse(next.changed)
    }

    func testInvalidFirstSampleStillIdentifiesReplacement() {
        var evidence = CameraUplinkEvidence()
        XCTAssertFalse(evidence.consume(nil).changed)
        let first = evidence.consume(sample(.nan, .excellent))
        XCTAssertEqual(first.network, .unknown); XCTAssertTrue(first.changed)
        let valid = evidence.consume(sample(1, .excellent))
        XCTAssertEqual(valid.network, .excellent); XCTAssertFalse(valid.changed)
        let replacement = evidence.consume(sample(.infinity, .excellent, identity: "camera-b/transport-a"))
        XCTAssertEqual(replacement.network, .unknown); XCTAssertTrue(replacement.changed)
    }

    func testHealthyAndUnknownSamplesInterruptPoorRuns() {
        for network in [CameraQualityPolicy.Network.ordinary, .excellent, .unknown] {
            var evidence = CameraUplinkEvidence()
            _ = evidence.consume(sample(10))
            let interruption = evidence.consume(sample(20, network))
            XCTAssertEqual(interruption.network, network); XCTAssertFalse(interruption.changed)
            XCTAssertEqual(evidence.consume(sample(30)).network, .ordinary)
            XCTAssertEqual(evidence.consume(sample(40)).network, .poor)
        }
    }

    func testMissingOrReplayedHealthyEvidenceReturnsUnknown() {
        var evidence = CameraUplinkEvidence()
        XCTAssertEqual(evidence.consume(sample(10, .excellent)).network, .excellent)
        XCTAssertEqual(evidence.consume(sample(10, .excellent)).network, .unknown)
        XCTAssertEqual(evidence.consume(sample(11, .excellent)).network, .excellent)
        XCTAssertEqual(evidence.consume(nil).network, .unknown)
        XCTAssertEqual(evidence.consume(sample(11, .excellent)).network, .unknown)
    }

    func testResetStartsFreshQualificationEvenForTheSameIdentity() {
        var evidence = CameraUplinkEvidence()
        _ = evidence.consume(sample(100))
        _ = evidence.consume(sample(200))
        evidence.reset()
        XCTAssertFalse(evidence.consume(nil).changed)
        let first = evidence.consume(sample(1))
        XCTAssertEqual(first.network, .ordinary); XCTAssertTrue(first.changed)
        XCTAssertEqual(evidence.consume(sample(2)).network, .poor)
    }
}
