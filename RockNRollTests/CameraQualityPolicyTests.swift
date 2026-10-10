import CoreMedia
import XCTest
@testable import RockNRoll

final class CameraQualityPolicyTests: XCTestCase {
    func testInitialQualityUsesExplicitPowerAndNetworkEvidence() {
        for power in [CameraQualityPolicy.Power.battery, .unknown] {
            for network in [CameraQualityPolicy.Network.unknown, .ordinary] {
                var policy = CameraQualityPolicy()
                let profile = policy.update(power: power, network: network, pressure: .normal, constrainedPath: false, at: 0)
                XCTAssertEqual(profile, .init(tier: .balance, fps: 20))
            }
        }
        var powered = CameraQualityPolicy(), excellent = CameraQualityPolicy()
        XCTAssertEqual(powered.update(power: .connected, network: .unknown, pressure: .normal, constrainedPath: false, at: 0),
                       .init(tier: .high, fps: 24))
        XCTAssertEqual(excellent.update(power: .battery, network: .excellent, pressure: .normal, constrainedPath: false, at: 0),
                       .init(tier: .high, fps: 24))
    }

    func testPoorNetworkAndRestrictedPathsOverrideExternalPower() {
        var poor = CameraQualityPolicy(), restricted = CameraQualityPolicy()
        XCTAssertEqual(poor.update(power: .connected, network: .poor, pressure: .normal, constrainedPath: false, at: 0),
                       .init(tier: .constrained, fps: 15))
        XCTAssertEqual(restricted.update(power: .connected, network: .excellent, pressure: .normal, constrainedPath: true, at: 0),
                       .init(tier: .constrained, fps: 15))
    }

    func testUpgradeRequiresThirtyContinuousHealthySeconds() {
        var policy = CameraQualityPolicy()
        _ = policy.update(power: .battery, network: .ordinary, pressure: .normal, constrainedPath: false, at: 0)
        for time in [2.0, 12, 31.9] {
            XCTAssertEqual(policy.update(power: .battery, network: .excellent, pressure: .normal, constrainedPath: false, at: time).tier, .balance)
        }
        XCTAssertEqual(policy.update(power: .battery, network: .excellent, pressure: .normal, constrainedPath: false, at: 32).tier, .high)
    }

    func testLostEvidenceRestartsUpgradeQualification() {
        var policy = CameraQualityPolicy()
        _ = policy.update(power: .battery, network: .unknown, pressure: .normal, constrainedPath: false, at: 0)
        _ = policy.update(power: .battery, network: .excellent, pressure: .normal, constrainedPath: false, at: 2)
        _ = policy.update(power: .battery, network: .unknown, pressure: .normal, constrainedPath: false, at: 20)
        for time in [22.0, 32, 51.9] {
            XCTAssertEqual(policy.update(power: .battery, network: .excellent, pressure: .normal, constrainedPath: false, at: time).tier, .balance)
        }
        XCTAssertEqual(policy.update(power: .battery, network: .excellent, pressure: .normal, constrainedPath: false, at: 52).tier, .high)
    }

    func testOrdinaryTransitionsHaveTenSecondDwell() {
        var policy = CameraQualityPolicy()
        _ = policy.update(power: .connected, network: .ordinary, pressure: .normal, constrainedPath: false, at: 0)
        XCTAssertEqual(policy.update(power: .battery, network: .ordinary, pressure: .normal, constrainedPath: false, at: 2).tier, .high)
        XCTAssertEqual(policy.update(power: .battery, network: .ordinary, pressure: .normal, constrainedPath: false, at: 10).tier, .balance)
        XCTAssertEqual(policy.update(power: .battery, network: .poor, pressure: .normal, constrainedPath: false, at: 12).tier, .balance)
        XCTAssertEqual(policy.update(power: .battery, network: .poor, pressure: .normal, constrainedPath: false, at: 20).tier, .constrained)
    }

    func testPressureAndDataRestrictionApplyImmediatelyButRecoverSlowly() {
        var policy = CameraQualityPolicy()
        _ = policy.update(power: .connected, network: .excellent, pressure: .normal, constrainedPath: false, at: 0)
        XCTAssertEqual(policy.update(power: .connected, network: .excellent, pressure: .constrained, constrainedPath: false, at: 1),
                       .init(tier: .constrained, fps: 15))
        XCTAssertEqual(policy.update(power: .connected, network: .excellent, pressure: .severe, constrainedPath: false, at: 2),
                       .init(tier: .constrained, fps: 10))
        for time in [3.0, 32.9] {
            XCTAssertEqual(policy.update(power: .connected, network: .excellent, pressure: .normal, constrainedPath: false, at: time),
                           .init(tier: .constrained, fps: 10))
        }
        XCTAssertEqual(policy.update(power: .connected, network: .excellent, pressure: .normal, constrainedPath: false, at: 33).tier, .high)
        XCTAssertEqual(policy.update(power: .connected, network: .excellent, pressure: .normal, constrainedPath: true, at: 34).tier, .constrained)
    }

    func testResetDiscardsPreviousTransportEvidence() {
        var policy = CameraQualityPolicy()
        _ = policy.update(power: .battery, network: .ordinary, pressure: .normal, constrainedPath: false, at: 0)
        _ = policy.update(power: .battery, network: .excellent, pressure: .normal, constrainedPath: false, at: 1)
        policy.reset()
        XCTAssertEqual(policy.update(power: .unknown, network: .unknown, pressure: .normal, constrainedPath: false, at: 40).tier, .balance)
        XCTAssertEqual(policy.update(power: .battery, network: .excellent, pressure: .normal, constrainedPath: false, at: 41).tier, .balance)
        XCTAssertEqual(policy.update(power: .battery, network: .excellent, pressure: .normal, constrainedPath: false, at: 71).tier, .high)
    }

    func testInvalidAndBackwardClocksCannotCompleteAnUpgrade() {
        var policy = CameraQualityPolicy()
        _ = policy.update(power: .battery, network: .ordinary, pressure: .normal, constrainedPath: false, at: 100)
        _ = policy.update(power: .battery, network: .excellent, pressure: .normal, constrainedPath: false, at: 101)
        for time in [Double.nan, .infinity, -.infinity, 2, 31.9] {
            XCTAssertEqual(policy.update(power: .battery, network: .excellent, pressure: .normal, constrainedPath: false, at: time).tier, .balance)
        }
        XCTAssertEqual(policy.update(power: .battery, network: .excellent, pressure: .normal, constrainedPath: false, at: 32).tier, .high)
        XCTAssertEqual(policy.update(power: .battery, network: .excellent, pressure: .severe, constrainedPath: false, at: .nan),
                       .init(tier: .constrained, fps: 10))
    }

    func testCommonCameraDimensionsPreserveAspectOrientationAndDoNotUpscale() {
        let maximum = CMVideoDimensions(width: 1280, height: 720)
        for (width, height, expectedWidth, expectedHeight) in [(1920,1080,1280,720), (1080,1920,720,1280),
                                                             (1552,1164,960,720), (1760,1328,880,664),
                                                             (640,480,640,480), (480,640,480,640)] {
            let result = CameraQualityPolicy.bounded(.init(width: Int32(width), height: Int32(height)), maximum: maximum)
            XCTAssertEqual(result.width, Int32(expectedWidth)); XCTAssertEqual(result.height, Int32(expectedHeight))
            XCTAssertEqual(Int64(result.width) * Int64(height), Int64(result.height) * Int64(width))
        }
    }

    func testOddAndUnusualCameraFormatsNeverEscapeAnyTierCap() {
        for tier in [CameraQualityPolicy.Tier.constrained, .balance, .high] {
            let maximum = CameraQualityPolicy.Profile(tier: tier, fps: 15).maximum
            for (width, height) in [(1401,1001), (1001,1401), (1921,1081), (1081,1921), (641,479), (479,641)] {
                let result = CameraQualityPolicy.bounded(.init(width: Int32(width), height: Int32(height)), maximum: maximum)
                XCTAssertLessThanOrEqual(max(result.width, result.height), max(maximum.width, maximum.height))
                XCTAssertLessThanOrEqual(min(result.width, result.height), min(maximum.width, maximum.height))
                XCTAssertLessThanOrEqual(result.width, Int32(width)); XCTAssertLessThanOrEqual(result.height, Int32(height))
                XCTAssertEqual(result.width % 2, 0); XCTAssertEqual(result.height % 2, 0)
                XCTAssertGreaterThan(result.width, 0); XCTAssertGreaterThan(result.height, 0)
                XCTAssertLessThanOrEqual(abs(Double(result.width) - Double(result.height) * Double(width) / Double(height)), 2)
            }
        }
    }

    func testInvalidBoundsProduceNoUsableOutput() {
        for input in [CMVideoDimensions(width: 0, height: 1080), .init(width: -1, height: 720), .init(width: 1, height: 1)] {
            let result = CameraQualityPolicy.bounded(input, maximum: .init(width: 1280, height: 720))
            XCTAssertEqual(result.width, 0); XCTAssertEqual(result.height, 0)
        }
        let result = CameraQualityPolicy.bounded(.init(width: 1920, height: 1080), maximum: .init(width: 0, height: 720))
        XCTAssertEqual(result.width, 0); XCTAssertEqual(result.height, 0)
    }
}
