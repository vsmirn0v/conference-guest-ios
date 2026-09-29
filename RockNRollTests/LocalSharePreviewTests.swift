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
    func testThumbnailIsBoundedAndExtraFramesAreDropped() throws {
        let preview = LocalSharePreview(isMac: false, observeLifecycle: false)
        preview.begin()
        preview.setForeground(false)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        preview.accept(pixels, time: 10)
        let first = try XCTUnwrap(preview.image)
        XCTAssertLessThanOrEqual(max(first.size.width, first.size.height), 640)
        preview.accept(pixels, time: 10.2)
        XCTAssertTrue(first === preview.image)
        preview.accept(pixels, time: 11.2)
        XCTAssertFalse(first === preview.image)
    }

    func testMacThumbnailConversionCostStaysBounded() throws {
        let preview = LocalSharePreview(isMac: true, observeLifecycle: false)
        preview.begin()
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        preview.accept(pixels, time: 1)
        let start = Date()
        for index in 0..<100 { preview.accept(pixels, time: Double(index) * 0.6 + 2) }
        print("PERF 1080p→640px preview average ms: \(Date().timeIntervalSince(start) * 10)")
        XCTAssertLessThanOrEqual(max(preview.image!.size.width, preview.image!.size.height), 640)
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
