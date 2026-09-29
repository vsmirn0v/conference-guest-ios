import CoreVideo
import XCTest
@testable import RockNRoll

final class LocalSharePreviewTransportTests: XCTestCase {
    func testLegacyBroadcastThumbnailCrossesLoopbackWithoutImageFiles() async throws {
        let receiver = LocalSharePreviewReceiver()
        let received = expectation(description: "Thumbnail received")
        let ready = expectation(description: "Current thumbnail channel is ready")
        receiver.onReady = { ready.fulfill() }
        receiver.start { image in
            XCTAssertEqual(image.size.width, 32)
            XCTAssertEqual(image.size.height, 24)
            received.fulfill()
        }
        receiver.setWanted(true)
        defer { receiver.stop() }
        let endpointURL = try XCTUnwrap(LocalSharePreviewEndpoint.url)
        await fulfillment(of: [ready], timeout: 5)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 32, 24, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 127, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let sender = LocalSharePreviewSender()
        sender.send(pixels)
        await fulfillment(of: [received], timeout: 5)
        withExtendedLifetime(sender) {}
        let metadata = try Data(contentsOf: endpointURL)
        XCTAssertLessThan(metadata.count, 256, "The app group holds connection metadata, never image data")
    }
}
