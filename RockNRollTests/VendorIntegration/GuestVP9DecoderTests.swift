import CoreVideo
import LiveKitWebRTC
import WebRTC
import XCTest
@testable import RockNRoll

final class GuestVP9DecoderTests: XCTestCase {
    private func fixtures() throws -> [VP9Fixture] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "vp9-lossless", withExtension: "json"))
        return try JSONDecoder().decode([VP9Fixture].self, from: Data(contentsOf: url))
    }
    private func image(_ frame: VP9Fixture.Frame, timestamp: UInt32) -> RTCEncodedImage {
        let image = RTCEncodedImage(); image.buffer = frame.data
        image.frameType = frame.key ? .videoFrameKey : .videoFrameDelta
        image.timeStamp = timestamp; image.captureTimeMs = 1000; image.rotation = ._90
        return image
    }
    func testBoundsAndReleaseDoNotDeliverRetiredFrames() {
        var delivered = 0, failures = 0
        let decoder = GuestVP9HardwareDecoder { failures += 1 }
        decoder.setCallback { _ in delivered += 1 }
        let empty = RTCEncodedImage(); empty.buffer = Data()
        XCTAssertEqual(decoder.decode(empty, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -1)
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 1), 0)
        XCTAssertEqual(decoder.decode(empty, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -1)
        empty.buffer = Data(repeating: 255, count: 32); empty.frameType = .videoFrameKey
        XCTAssertEqual(decoder.decode(empty, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -1)
        XCTAssertEqual(failures, 0); XCTAssertEqual(delivered, 0)
        XCTAssertEqual(decoder.release(), 0)
        XCTAssertEqual(decoder.decode(empty, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -1)
        XCTAssertEqual(delivered, 0)
    }
    func testUnavailableHardwareFailsOnceAndCanRestart() throws {
        guard !VideoToolboxVP9Session.available else { throw XCTSkip("Software-device fallback check") }
        var failures = 0
        let decoder = GuestVP9HardwareDecoder { failures += 1 }
        let input = image(try XCTUnwrap(fixtures().first?.frames.first), timestamp: 90_000)
        _ = decoder.startDecode(withNumberOfCores: 1)
        XCTAssertEqual(decoder.decode(input, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -1)
        XCTAssertEqual(decoder.decode(input, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -1)
        XCTAssertEqual(failures, 1)
        _ = decoder.release(); _ = decoder.startDecode(withNumberOfCores: 1)
        XCTAssertEqual(decoder.decode(input, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -1)
        XCTAssertEqual(failures, 2)
    }
    func testHardwareGuestFramesMatchIndependentReferenceAndRTPWrap() throws {
        guard VideoToolboxVP9Session.available else { throw XCTSkip("Hardware VP9 required") }
        var count = 0, failures = 0, expected = "", timestamp = UInt32.max - 3000
        let decoder = GuestVP9HardwareDecoder { failures += 1 }
        _ = decoder.startDecode(withNumberOfCores: 1)
        decoder.setCallback { frame in
            guard let pixels = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else { XCTFail("Native pixel buffer required"); return }
            let native = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._90, timeStampNs: frame.timeStampNs)
            XCTAssertEqual(VP9Fixture.digest(native), expected)
            XCTAssertEqual(frame.rotation, ._90); XCTAssertEqual(frame.timeStamp, Int32(bitPattern: timestamp))
            count += 1
        }
        for fixture in try fixtures() {
            for frame in fixture.frames {
                expected = frame.sha256
                XCTAssertEqual(decoder.decode(image(frame, timestamp: timestamp), missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), 0)
                timestamp &+= 6000
            }
        }
        XCTAssertEqual(count, 16); XCTAssertEqual(failures, 0)
        XCTAssertEqual(decoder.evidenceForTesting["verifiedHardwareSession"] as? Bool, true)
        _ = decoder.release()
    }
}
