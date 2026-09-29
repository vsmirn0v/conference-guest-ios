import Combine
import LiveKit
import XCTest
@testable import RockNRoll

@MainActor
final class LocalShareTrackPreviewTests: XCTestCase {
    func testExistingLocalTrackFeedsPreviewAndDetachClearsIt() async throws {
        let preview = LocalSharePreview(isMac: false, observeLifecycle: false)
        let renderer = LocalShareTrackPreview(preview: preview)
        let track = await LocalVideoTrack.createBufferTrack()
        let capturer = try XCTUnwrap(track.capturer as? BufferCapturer)
        renderer.setTrack(track)
        preview.setForeground(false)
        try await track.start()
        let received = expectation(description: "Existing track supplies preview pixels")
        let observation = preview.$image.compactMap { $0 }.prefix(1).sink { image in
            XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 640)
            received.fulfill()
        }
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        capturer.capture(pixels)
        await fulfillment(of: [received], timeout: 5)
        renderer.setTrack(nil)
        XCTAssertNil(preview.image)
        capturer.capture(pixels)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(preview.image, "Detached tracks must not repopulate another share's preview")
        try await track.stop()
        observation.cancel()
    }
}
