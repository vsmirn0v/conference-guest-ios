import XCTest
@testable import RockNRoll

@MainActor
final class LocalSharePreviewTests: XCTestCase {
    private var thumbnail: UIImage { UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9)).image { _ in } }
    func testPhoneFreezesLastExternalFrameAndDiscardsOnStop() {
        let preview = LocalSharePreview(isMac: false, observeLifecycle: false)
        preview.begin()
        preview.acceptThumbnail(thumbnail)
        XCTAssertNil(preview.image, "Never preview the phone's own foreground scene recursively")
        preview.setForeground(false)
        preview.acceptThumbnail(thumbnail)
        let external = preview.image
        XCTAssertNotNil(external)
        preview.setForeground(true)
        preview.acceptThumbnail(thumbnail)
        XCTAssertTrue(preview.image === external)
        XCTAssertFalse(preview.live)
        preview.end()
        XCTAssertNil(preview.image)
        preview.begin()
        XCTAssertNil(preview.image, "A new share cannot show the previous room's pixels")
    }
    func testThumbnailIsBoundedAndExtraFramesAreDropped() async throws {
        let preview = LocalSharePreview(isMac: false, observeLifecycle: false)
        preview.begin()
        preview.setForeground(false)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        await accept(preview, pixels, time: 10)
        let first = try XCTUnwrap(preview.image)
        XCTAssertLessThanOrEqual(max(first.size.width, first.size.height), 640)
        await accept(preview, pixels, time: 10.2)
        XCTAssertTrue(first === preview.image)
        await accept(preview, pixels, time: 15.2)
        XCTAssertFalse(first === preview.image)
    }

    func testMacThumbnailConversionCostStaysBounded() async throws {
        let preview = LocalSharePreview(isMac: true, observeLifecycle: false)
        preview.begin()
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        await accept(preview, pixels, time: 1)
        let start = Date()
        for index in 0..<100 { await accept(preview, pixels, time: Double(index) * 0.6 + 2) }
        print("PERF 1080p→640px preview average ms: \(Date().timeIntervalSince(start) * 10)")
        XCTAssertLessThanOrEqual(max(preview.image!.size.width, preview.image!.size.height), 640)
    }

    func testMacConversionHandlesCameraAndCaptureFormatsAndRotation() async throws {
        for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                       kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] {
            for rotation in [0, 90, 180, 270] {
                let preview = LocalSharePreview(isMac: true, observeLifecycle: false)
                preview.begin()
                var buffer: CVPixelBuffer?
                XCTAssertEqual(CVPixelBufferCreate(nil, 1280, 720, format,
                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
                let pixels = try XCTUnwrap(buffer)
                await accept(preview, pixels, rotation: rotation, time: 1)
                let image = try XCTUnwrap(preview.image)
                XCTAssertEqual(image.size, rotation == 90 || rotation == 270
                    ? CGSize(width: 360, height: 640) : CGSize(width: 640, height: 360))
                preview.end()
                XCTAssertNil(preview.image)
            }
        }
    }

    func testMacRotatedPixelsMatchExistingRendererAndAreIndependentOfCaptureBuffer() async throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 8, 4, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<4 {
            for x in 0..<8 {
                let offset = y * stride + x * 4
                base[offset] = x < 4 ? 0 : 255
                base[offset + 1] = y < 2 ? 0 : 255
                base[offset + 2] = x < 4 ? 255 : 0
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for rotation in [0, 90, 180, 270] {
            let reference = LocalSharePreview(isMac: false, observeLifecycle: false)
            reference.begin(); reference.setForeground(false)
            await accept(reference, pixels, rotation: rotation, time: 1)
            let mac = LocalSharePreview(isMac: true, observeLifecycle: false)
            mac.begin(); await accept(mac, pixels, rotation: rotation, time: 1)
            let expected = try rgba(try XCTUnwrap(reference.image?.cgImage))
            let actual = try rgba(try XCTUnwrap(mac.image?.cgImage))
            XCTAssertEqual(actual.count, expected.count)
            for (a, b) in zip(actual, expected) { XCTAssertLessThanOrEqual(abs(Int(a) - Int(b)), 2) }
        }
        let mac = LocalSharePreview(isMac: true, observeLifecycle: false)
        mac.begin(); await accept(mac, pixels, time: 1)
        let before = try rgba(try XCTUnwrap(mac.image?.cgImage))
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(base, 0, stride * 4)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        XCTAssertEqual(try rgba(try XCTUnwrap(mac.image?.cgImage)), before)
    }

    private func accept(_ preview: LocalSharePreview, _ pixels: CVPixelBuffer, rotation: Int = 0, time: TimeInterval) async {
        let previous = preview.image
        preview.accept(pixels, rotation: rotation, time: time)
        // A throttled call intentionally keeps the same image.
        if time == 10.2 { return }
        for _ in 0..<100 {
            if preview.image !== previous { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Preview worker did not publish a frame")
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4))
    }

    func testMacThumbnailIsLiveButCapturedEnlargementPauses() {
        let preview = LocalSharePreview(isMac: true, observeLifecycle: false)
        var policies: [Bool] = []
        preview.onCapturePolicyChanged = { policies.append($0) }
        preview.begin(source: .window)
        preview.acceptThumbnail(thumbnail)
        let initial = preview.image
        XCTAssertTrue(preview.live)
        preview.acceptThumbnail(thumbnail)
        XCTAssertFalse(preview.image === initial)
        XCTAssertEqual(policies, [true], "Unchanged frames must not write preview policy metadata")
        preview.setEnlarged(true)
        let paused = preview.image
        preview.acceptThumbnail(thumbnail)
        XCTAssertTrue(preview.image === paused)
        XCTAssertFalse(preview.live)
        preview.refreshFrame()
        preview.acceptThumbnail(thumbnail)
        XCTAssertFalse(preview.image === paused)
        XCTAssertFalse(preview.acceptsFrames, "Refresh accepts exactly one frame")
        preview.setEnlarged(false)
        XCTAssertTrue(preview.live)
        preview.togglePaused()
        XCTAssertFalse(preview.acceptsFrames)
        preview.togglePaused()
        XCTAssertTrue(preview.live)
        preview.setEnlarged(true)
        preview.ownSceneIsNotCaptured = { true }
        preview.refreshPolicy()
        XCTAssertTrue(preview.live, "An external window can remain live while enlarged")
        preview.hidden = true
        preview.refreshPolicy()
        XCTAssertFalse(preview.acceptsFrames)
        preview.end()
        preview.begin()
        XCTAssertTrue(preview.acceptsFrames)
    }
}
