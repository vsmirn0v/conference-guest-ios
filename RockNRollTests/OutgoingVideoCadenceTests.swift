import CoreMedia
import CoreVideo
import XCTest
@testable import RockNRoll

final class OutgoingVideoCadenceTests: XCTestCase {
    private func sample(width: Int = 160, height: Int = 90, time: Double) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        return try XCTUnwrap(PresenterCompositor.sample(try XCTUnwrap(pixels), time: CMTime(seconds: time, preferredTimescale: 60_000)))
    }
    func testCapsSixtyFPSInputWithoutDriftAndRecoversImmediately() throws {
        var cadence = OutgoingVideoCadence()
        var delivered = 0
        for frame in 0..<60 { if cadence.accept(try sample(time: Double(frame) / 60), fps: 15) { delivered += 1 } }
        XCTAssertEqual(delivered, 15)
        XCTAssertTrue(cadence.accept(try sample(time: 1), fps: 5))
        XCTAssertFalse(cadence.accept(try sample(time: 1.01), fps: 5))
        XCTAssertTrue(cadence.accept(try sample(time: 1.02), fps: 15))
        XCTAssertTrue(cadence.accept(try sample(time: 10), fps: 15))
        XCTAssertFalse(cadence.accept(try sample(time: 10.001), fps: 15), "No catch-up burst after a gap")
    }
    func testRotationFormatAndTimestampResetAreImmediate() throws {
        var cadence = OutgoingVideoCadence()
        XCTAssertTrue(cadence.accept(try sample(time: 5), fps: 10))
        XCTAssertTrue(cadence.accept(try sample(width: 90, height: 160, time: 5.01), fps: 10))
        XCTAssertTrue(cadence.accept(try sample(width: 90, height: 160, time: 0), fps: 10))
        XCTAssertFalse(cadence.accept(try sample(width: 90, height: 160, time: 0.01), fps: 10))
    }
}
