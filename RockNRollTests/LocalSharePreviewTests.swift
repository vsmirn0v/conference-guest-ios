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

    func testMacOnlyPreviewsWhenOwnSceneIsKnownNotCaptured() {
        let preview = LocalSharePreview(isMac: true, observeLifecycle: false)
        preview.begin(source: .window)
        preview.acceptThumbnail(thumbnail)
        let initial = preview.image
        XCTAssertNotNil(initial, "Unknown sources can show one frozen confidence snapshot")
        XCTAssertFalse(preview.live)
        preview.acceptThumbnail(thumbnail)
        XCTAssertTrue(preview.image === initial, "An unknown source must not form a repeating live preview")
        preview.ownSceneIsNotCaptured = { true }
        preview.acceptThumbnail(thumbnail)
        XCTAssertNotNil(preview.image)
        XCTAssertTrue(preview.live)
        preview.ownSceneIsNotCaptured = { false }
        let safe = preview.image
        preview.acceptThumbnail(thumbnail)
        XCTAssertTrue(preview.image === safe)
        XCTAssertFalse(preview.live)
        preview.hidden = true
        preview.ownSceneIsNotCaptured = { true }
        XCTAssertFalse(preview.acceptsFrames)
    }
}
