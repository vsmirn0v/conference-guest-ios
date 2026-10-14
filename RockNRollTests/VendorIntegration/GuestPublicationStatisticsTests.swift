import Foundation
import XCTest
@testable import RockNRoll

final class GuestPublicationStatisticsTests: XCTestCase {
    func testStartupNeedsStableRepeatedActiveEvidenceAndResetsForPauseOrReplacement() {
        var startup = VideoPublicationStartup()
        let zero = VideoPublicationStartup.Sample(stream: "sender/layer", encoded: 0)
        XCTAssertEqual(startup.observe(zero, at: 8), .waiting)
        XCTAssertEqual(startup.observe(zero, at: 11.9), .waiting)
        startup.reset() // Paused/unknown evidence cannot count toward failure.
        XCTAssertEqual(startup.observe(zero, at: 12), .waiting)
        XCTAssertEqual(startup.observe(.init(stream: "sender/new-layer", encoded: 0), at: 16), .waiting)
        XCTAssertEqual(startup.observe(.init(stream: "sender/new-layer", encoded: 1), at: 20), .working)
        XCTAssertEqual(startup.observe(zero, at: 24), .waiting)
        XCTAssertEqual(startup.observe(zero, at: 28), .stalled)
        XCTAssertEqual(startup.observe(zero, at: 1), .waiting, "Clock regression starts new evidence")
        XCTAssertEqual(startup.observe(zero, at: .nan), .waiting)
        XCTAssertEqual(startup.observe(.init(stream: zero.stream, encoded: 0, bandwidthLimited: true), at: 32), .waiting)
        XCTAssertEqual(startup.observe(zero, at: 36), .waiting, "Network limitation retires zero-frame evidence")
    }

    private func record(_ id: String = "layer", mid: String = "camera", active: Bool? = true,
                        frames: Int64? = 0, kind: String = "video") -> CameraUplinkStatistics.Record {
        var values: [String: NSObject] = ["mid": mid as NSString, "kind": kind as NSString]
        if let active { values["active"] = NSNumber(value: active) }
        if let frames { values["framesEncoded"] = NSNumber(value: frames) }
        return .init(id: id, type: "outbound-rtp", timestamp: 1, values: values)
    }

    func testPausedMissingAndOtherSourcesCannotBecomePublicationFailure() {
        for records in [[], [record(active: false)], [record(active: nil)],
                        [record(mid: "sharing")], [record(kind: "audio")]] {
            XCTAssertNil(GuestPublicationStatistics.activeVideo(records, mid: "camera"))
        }
    }

    func testOnlyActiveCameraLayersContributeWhileSVCHasOneEncoding() throws {
        let records = [record("inactive", active: false, frames: 500), record("low", frames: 4),
                       record("high", frames: 8), record("share", mid: "sharing", frames: 100)]
        let active = try XCTUnwrap(GuestPublicationStatistics.activeVideo(records, mid: "camera"))
        XCTAssertEqual(active.map(\.id), ["low", "high"])
        XCTAssertEqual(GuestPublicationStatistics.encodedFrames(active), 12)
        XCTAssertEqual(GuestPublicationStatistics.encodedFrames([record("svc", frames: 9)]), 9)
    }

    func testStartupZeroRequiresExplicitActiveAndCompleteNonnegativeCounters() throws {
        let active = try XCTUnwrap(GuestPublicationStatistics.activeVideo([record()], mid: "camera"))
        XCTAssertEqual(GuestPublicationStatistics.encodedFrames(active), 0)
        XCTAssertNil(GuestPublicationStatistics.encodedFrames([record(frames: nil)]))
        XCTAssertNil(GuestPublicationStatistics.encodedFrames([record(frames: -1)]))
        XCTAssertNil(GuestPublicationStatistics.encodedFrames([]))
        XCTAssertNil(GuestPublicationStatistics.encodedFrames([record(frames: .max), record(frames: 1)]))
    }
}
