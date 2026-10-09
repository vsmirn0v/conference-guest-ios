import ConferenceCore
import AVFoundation
import ImageIO
import VideoToolbox
import XCTest
@testable import RockNRoll

final class PresenterCompositorTests: XCTestCase {
    private func pixels(_ sample: CMSampleBuffer) throws -> [UInt8] {
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let pointer = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer, count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)))
    }
    private func solid(_ value: UInt8, width: Int = 160, height: Int = 90) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        memset(CVPixelBufferGetBaseAddress(result), Int32(value), CVPixelBufferGetDataSize(result))
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }
    func testColorAndTimestampStayStableAcrossIdenticalFrames() throws {
        let compositor = PresenterCompositor(size: CGSize(width: 160, height: 90))
        let first = try XCTUnwrap(compositor.render(scene: PresenterScene(), camera: nil, time: CMTime(value: 100, timescale: 100)))
        let snapshot = try pixels(first)
        let second = try XCTUnwrap(compositor.render(scene: PresenterScene(), camera: nil, time: CMTime(value: 200, timescale: 100)))
        XCTAssertEqual(try pixels(second), snapshot)
        XCTAssertEqual(try pixels(first), snapshot, "A retained encoder buffer must not be overwritten")
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(second), CMTime(value: 200, timescale: 100))
    }
    func testCutoutFailureDoesNotRevealRawCamera() throws {
        let compositor = PresenterCompositor(size: CGSize(width: 160, height: 90), personMask: { _, _ in nil })
        var scene = PresenterScene(); scene.layout = .cutout
        let plain = try XCTUnwrap(compositor.render(scene: scene, camera: nil, time: .zero))
        let protected = try XCTUnwrap(compositor.render(scene: scene, camera: solid(220), time: .zero))
        XCTAssertEqual(try pixels(plain), try pixels(protected))
    }
    func testCameraCardDisappearsAndAnnotationsReachTheOutput() throws {
        let compositor = PresenterCompositor(size: CGSize(width: 160, height: 90))
        var scene = PresenterScene()
        let live = try XCTUnwrap(compositor.render(scene: scene, camera: solid(230), time: .zero))
        let off = try XCTUnwrap(compositor.render(scene: scene, camera: nil, time: .zero))
        XCTAssertNotEqual(try pixels(live), try pixels(off))
        scene.strokes = [[CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.6, y: 0.5)]]
        let marked = try XCTUnwrap(compositor.render(scene: scene, camera: nil, time: .zero))
        XCTAssertNotEqual(try pixels(marked), try pixels(off))
        XCTAssertNil(compositor.render(scene: scene, camera: nil, time: .zero), "Keep at most three encoder/preview buffers")
    }
    func testInstrumentCropStaysInsideSourceAtEveryEdge() {
        let extent = CGRect(x: 10, y: 20, width: 640, height: 480)
        for x in [-1.0, 0, 0.5, 1, 2] {
            for y in [-1.0, 0, 0.5, 1, 2] {
                let crop = PresenterCompositor.instrumentCrop(extent: extent, zoom: 3, focus: CGPoint(x: x, y: y))
                XCTAssertTrue(extent.contains(crop)); XCTAssertEqual(crop.width, 640 / 3, accuracy: 0.001)
            }
        }
        XCTAssertEqual(PresenterCompositor.instrumentCrop(extent: extent, zoom: .nan, focus: CGPoint(x: CGFloat.nan, y: CGFloat.nan)), extent)
    }
    func testManualCameraRotationUsesTheSamePixelAndMaskOrientation() throws {
        let compositor = PresenterCompositor(size: CGSize(width: 160, height: 90))
        let camera = try solid(180)
        var scene = PresenterScene(); scene.cameraRotation = 90
        let manual = try XCTUnwrap(compositor.render(scene: scene, camera: camera, time: .zero))
        let device = try XCTUnwrap(compositor.render(scene: PresenterScene(), camera: camera, rotation: 90, time: .zero))
        XCTAssertEqual(try pixels(manual), try pixels(device))
        var maskOrientation: CGImagePropertyOrientation?
        let masked = PresenterCompositor(size: CGSize(width: 160, height: 90), personMask: { _, orientation in
            maskOrientation = orientation; return nil
        })
        scene.layout = .cutout
        _ = masked.render(scene: scene, camera: camera, time: .zero)
        XCTAssertEqual(maskOrientation, .right)
    }
    func testCameraPlacementAndLiveDrawingReachOutgoingPixels() throws {
        let compositor = PresenterCompositor(size: CGSize(width: 160, height: 90))
        var scene = PresenterScene()
        let camera = try solid(230)
        var left: [UInt8] = [], right: [UInt8] = []
        scene.placement.x = 0.03
        left = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: camera, time: .zero)))
        scene.placement.x = 0.72
        right = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: camera, time: .zero)))
        XCTAssertNotEqual(left, right)
        scene.draftStroke = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.7, y: 0.3)]
        let drawing = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: camera, time: .zero)))
        XCTAssertNotEqual(right, drawing, "Pen movement is shared before the finger lifts")
    }
    func testLiveScreenAndSideBySidePreserveContent() throws {
        let compositor = PresenterCompositor(size: CGSize(width: 160, height: 90))
        let screen = try solid(180)
        var scene = PresenterScene()
        let plain = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: nil, screen: screen, time: .zero)))
        let blank = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: nil, time: .zero)))
        XCTAssertNotEqual(plain, blank)
        scene.layout = .beside
        let beside = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: solid(240), screen: screen, time: .zero)))
        XCTAssertNotEqual(beside, plain)
    }
    func testGeometryClampsInvalidPlacementAndPreservesResizeCenter() {
        var place = PresenterPlacement(x: .nan, y: 2, width: .infinity, height: -2)
        place.clamp()
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(place.rect))
        place = PresenterPlacement(x: 0.3, y: 0.3, width: 0.2, height: 0.3)
        let center = CGPoint(x: place.rect.midX, y: place.rect.midY)
        place.resize(1.5)
        XCTAssertEqual(place.rect.midX, center.x, accuracy: 0.0001)
        XCTAssertEqual(place.rect.midY, center.y, accuracy: 0.0001)
        XCTAssertEqual(place.pixels(in: CGSize(width: 160, height: 90)).maxY, (1 - place.y) * 90, accuracy: 0.001)
    }
    func testSpeakingGlowDoesNotRecolorAnImportedSlide() throws {
        let compositor = PresenterCompositor(size: CGSize(width: 160, height: 90))
        let canvas = try XCTUnwrap(compositor.render(scene: PresenterScene(), camera: nil, time: .zero))
        var image: CGImage?
        XCTAssertEqual(VTCreateCGImageFromCVPixelBuffer(try XCTUnwrap(CMSampleBufferGetImageBuffer(canvas)), options: nil, imageOut: &image), noErr)
        var scene = PresenterScene(); scene.backdrop = .stage; scene.image = try XCTUnwrap(image)
        let idle = try XCTUnwrap(compositor.render(scene: scene, camera: nil, time: .zero))
        scene.speaking = true
        let speaking = try XCTUnwrap(compositor.render(scene: scene, camera: nil, time: .zero))
        XCTAssertEqual(try pixels(idle), try pixels(speaking))
    }
    func testSquareBackgroundFillsCanvasWhileSlidePreservesWholeImage() throws {
        var image: CGImage?
        XCTAssertEqual(VTCreateCGImageFromCVPixelBuffer(try solid(220, width: 90, height: 90), options: nil, imageOut: &image), noErr)
        let compositor = PresenterCompositor(size: CGSize(width: 160, height: 90))
        var scene = PresenterScene(); scene.image = try XCTUnwrap(image)
        let fit = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: nil, time: .zero)))
        scene.imageFraming = .fill
        let fill = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: nil, time: .zero)))
        XCTAssertLessThan(fit[0], 30, "A fitted square slide retains margins")
        XCTAssertGreaterThan(fill[0], 200, "Generated backgrounds cover the canvas edge")
        XCTAssertEqual(compositor.backgroundBuilds, 2, "Framing changes must invalidate the cached background")
        scene.layout = .beside
        let beside = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: solid(40), time: .zero)))
        XCTAssertGreaterThan(beside[159 * 4], 200, "A generated background also fills the camera side of the canvas")
    }
    func testHeartbeatRetimesWithoutCopyingOrMutatingPixels() throws {
        let buffer = try solid(100)
        let first = try XCTUnwrap(PresenterCompositor.sample(buffer, time: CMTime(value: 1, timescale: 1)))
        let next = try XCTUnwrap(PresenterCompositor.retimed(first, time: CMTime(value: 2, timescale: 1)))
        XCTAssertTrue(CMSampleBufferGetImageBuffer(next) === buffer)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(first), CMTime(value: 1, timescale: 1))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(next), CMTime(value: 2, timescale: 1))
        XCTAssertEqual(try pixels(first), try pixels(next))
    }
    func testMaskReuseRequiresSameCaptureRevisionBufferAndOrientation() throws {
        var calls = 0
        let compositor = PresenterCompositor(size: CGSize(width: 160, height: 90), personMask: { _, _ in calls += 1; return nil })
        let camera = try solid(220)
        var scene = PresenterScene(); scene.layout = .cutout
        let blank = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: nil, time: .zero)))
        func render(_ revision: UInt64, rotation: Int = 0) throws {
            XCTAssertEqual(try pixels(XCTUnwrap(compositor.render(scene: scene, camera: camera,
                cameraRevision: revision, rotation: rotation, time: .zero))), blank, "A failed mask must remain concealed")
        }
        try render(1); scene.placement.x = 0.1; try render(1)
        XCTAssertEqual(calls, 1, "A scene edit must not rerun Vision on identical camera pixels")
        try render(2); XCTAssertEqual(calls, 2, "A recycled buffer contains a new frame")
        try render(2, rotation: 90); XCTAssertEqual(calls, 3)
        _ = compositor.render(scene: scene, camera: nil, time: .zero)
        try render(2, rotation: 90); XCTAssertEqual(calls, 4, "Camera retirement clears the cached mask")
        _ = compositor.render(scene: scene, camera: try solid(230), cameraRevision: 2, rotation: 90, time: .zero)
        XCTAssertEqual(calls, 5, "A revision alone must not match a different buffer")
    }
    func testSuccessfulMaskCannotBeReusedOnNewFrameAfterFailure() throws {
        var mask: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 9, kCVPixelFormatType_OneComponent8,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &mask), kCVReturnSuccess)
        let white = try XCTUnwrap(mask)
        CVPixelBufferLockBaseAddress(white, [])
        memset(CVPixelBufferGetBaseAddress(white), 255, CVPixelBufferGetDataSize(white))
        CVPixelBufferUnlockBaseAddress(white, [])
        var calls = 0
        let compositor = PresenterCompositor(size: CGSize(width: 160, height: 90), personMask: { _, _ in
            calls += 1; return calls == 1 ? white : nil
        })
        let camera = try solid(220)
        var scene = PresenterScene(); scene.layout = .cutout
        let plain = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: nil, time: .zero)))
        let visible = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: camera, cameraRevision: 1, time: .zero)))
        XCTAssertNotEqual(visible, plain)
        let repeated = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: camera, cameraRevision: 1, time: .zero)))
        XCTAssertEqual(visible, repeated); XCTAssertEqual(calls, 1)
        let concealed = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: camera, cameraRevision: 2, time: .zero)))
        XCTAssertEqual(concealed, plain); XCTAssertEqual(calls, 2)
    }
    func testCroppedDraftMatchesCommittedStrokePixelsAtCanvasEdges() throws {
        let compositor = PresenterCompositor(size: CGSize(width: 160, height: 90))
        for points in [
            [CGPoint(x: 0.01, y: 0.99), CGPoint(x: 0.99, y: 0.01)],
            [CGPoint(x: 0.2, y: 0.4), CGPoint(x: 0.7, y: 0.4)],
            [CGPoint(x: 0, y: 0.8), CGPoint(x: 0.4, y: 0.6), CGPoint(x: 0.3, y: 1)]
        ] {
            var scene = PresenterScene(); scene.backdrop = .stage; scene.draftStroke = points
            let draft = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: nil, time: .zero)))
            scene.draftStroke = []; scene.strokes = [points]
            let committed = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: nil, time: .zero)))
            XCTAssertEqual(draft, committed, "Crop origin must preserve drawing geometry and antialiasing")
        }
    }
    func testBackgroundAndCommittedDrawingSurviveDraftUpdates() throws {
        let compositor = PresenterCompositor(size: CGSize(width: 160, height: 90))
        var scene = PresenterScene(); scene.backdrop = .stage
        scene.strokes = [[CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.8, y: 0.1)]]
        _ = compositor.render(scene: scene, camera: nil, time: .zero)
        XCTAssertEqual(compositor.backgroundBuilds, 1); XCTAssertEqual(compositor.annotationRasterizations, 1)
        for index in 1...5 {
            scene.draftStroke = [CGPoint(x: 0.1, y: 0.2), CGPoint(x: CGFloat(index) / 10, y: 0.4)]
            _ = compositor.render(scene: scene, camera: nil, time: .zero)
        }
        XCTAssertEqual(compositor.backgroundBuilds, 1)
        XCTAssertEqual(compositor.annotationRasterizations, 6, "Only the live stroke changes")
        scene.speaking = true
        _ = compositor.render(scene: scene, camera: nil, time: .zero)
        XCTAssertEqual(compositor.backgroundBuilds, 2)
        scene.strokes = []; scene.draftStroke = []
        _ = compositor.render(scene: scene, camera: nil, time: .zero)
        XCTAssertEqual(compositor.annotationRasterizations, 6)
    }

}

@MainActor
final class PresenterModelTests: XCTestCase {
    private final class Capture: PrivateCameraPreviewing {
        let view = UIView()
        var started = false, stopped = false
        var waiting: CheckedContinuation<Void, Never>?
        var delay = false
        var onFrames: ((@escaping (CVPixelBuffer, Int) -> Void) -> Void)?
        func start() async throws {}
        func startFrames(_ frames: @escaping @MainActor (CVPixelBuffer, Int) -> Void) async throws {
            if delay { await withCheckedContinuation { waiting = $0 } }
            onFrames?(frames); started = true
        }
        func stop() async { stopped = true; started = false }
    }
    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 { if predicate() { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Presenter did not settle")
    }
    func testSetupDoesNotSendUntilExplicitShareAndHoldStopsSharing() async {
        let model = PresenterModel(observeLifecycle: false)
        var starts = 0, sends = 0, stops = 0
        model.startSharing = { _ in starts += 1 }
        model.sendSample = { _ in sends += 1 }; model.stopSharing = { stops += 1 }
        model.selectCanvas(); model.open(); await waitUntil { model.hasPreview }
        XCTAssertEqual(starts, 0); XCTAssertEqual(sends, 0); XCTAssertFalse(model.cameraOn)
        await model.start(); await waitUntil { sends > 0 }
        XCTAssertEqual(starts, 1); XCTAssertTrue(model.running)
        model.update(cameraOn: false, held: true)
        await waitUntil { stops == 1 }
        XCTAssertFalse(model.running); XCTAssertFalse(model.hasPreview)
        let delivered = sends
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sends, delivered)
        await model.start(); XCTAssertEqual(starts, 1)
        model.end()
    }
    func testPrivateStillPreviewHasNoPeriodicComposition() async throws {
        let model = PresenterModel(observeLifecycle: false)
        defer { model.end() }
        model.selectCanvas(); model.open(); await waitUntil { model.hasPreview }
        let count = model.compositionCount
        try await Task.sleep(nanoseconds: 1_150_000_000)
        XCTAssertEqual(model.compositionCount, count)
        XCTAssertEqual(model.heartbeatCount, 0)
        model.scene.speaking = true
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.compositionCount, count, "Speech does not change a plain backdrop")
        model.scene.backdrop = .warm
        await waitUntil { model.compositionCount > count }
    }
    func testIdleShareReusesPixelsWithFreshTimingAndNoComposition() async throws {
        let model = PresenterModel(observeLifecycle: false)
        defer { model.end() }
        var samples: [CMSampleBuffer] = []
        model.startSharing = { samples.append($0) }; model.sendSample = { samples.append($0) }; model.stopSharing = {}
        model.selectCanvas(); model.open(); await waitUntil { model.hasPreview }
        await model.start()
        let count = model.compositionCount
        await waitUntil { samples.count >= 2 }
        XCTAssertEqual(model.compositionCount, count); XCTAssertEqual(model.heartbeatCount, 1)
        XCTAssertTrue(CMSampleBufferGetImageBuffer(samples[0]) === CMSampleBufferGetImageBuffer(samples[1]))
        XCTAssertGreaterThan(CMSampleBufferGetPresentationTimeStamp(samples[1]), CMSampleBufferGetPresentationTimeStamp(samples[0]))
        model.scene.backdrop = .warm
        await waitUntil { samples.count >= 3 }
        XCTAssertFalse(CMSampleBufferGetImageBuffer(samples[1]) === CMSampleBufferGetImageBuffer(samples[2]))
        model.stop(); let delivered = samples.count
        try await Task.sleep(nanoseconds: 1_050_000_000)
        XCTAssertEqual(samples.count, delivered, "A scheduled heartbeat must not outlive Stop")
    }
    func testNewCameraFramesAndRapidEditsShareOnePacingLimit() async throws {
        let model = PresenterModel(observeLifecycle: false)
        defer { model.end() }
        let capture = Capture()
        var emit: ((CVPixelBuffer, Int) -> Void)?
        capture.onFrames = { emit = $0 }; model.makePrivateCamera = { _ in capture }
        model.selectCanvas(); model.open(); model.includeCamera = true
        await waitUntil { emit != nil && model.hasPreview }
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(screenSample()))
        let before = model.compositionCount
        for index in 0..<60 {
            emit?(buffer, 0); model.scene.placement.x = CGFloat(index % 10) / 100
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertLessThanOrEqual(model.compositionCount - before, 9, "Frames and edits share a 15 fps ceiling")
        let settled = model.compositionCount
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.compositionCount, settled, "Identical retained camera pixels must not be composited on a timer")
        model.includeCamera = false
        await waitUntil { capture.stopped }
    }
    func testStillEditRetriesWhenEncoderReleasesPoolBuffers() async throws {
        let model = PresenterModel(observeLifecycle: false)
        defer { model.end() }
        var held: [CMSampleBuffer] = []
        model.startSharing = { held.append($0) }; model.sendSample = { held.append($0) }; model.stopSharing = {}
        model.selectCanvas(); model.open(); await waitUntil { model.hasPreview }; await model.start()
        model.scene.backdrop = .warm; await waitUntil { held.count == 2 }
        model.scene.backdrop = .stage; await waitUntil { held.count == 3 }
        let count = model.compositionCount
        model.scene.backdrop = .dark
        await waitUntil { model.compositionCount > count }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(held.count, 3, "Encoder-owned buffers must not be overwritten")
        held.removeAll()
        await waitUntil { !held.isEmpty }
        XCTAssertTrue(model.hasPreview, "The last still edit must survive temporary buffer pressure")
    }
    func testRetiredStartCannotReviveSharing() async {
        let model = PresenterModel(observeLifecycle: false)
        var continuation: CheckedContinuation<Void, Never>?
        var stops = 0
        model.startSharing = { _ in await withCheckedContinuation { continuation = $0 } }
        model.stopSharing = { stops += 1 }
        model.selectCanvas(); model.open(); await waitUntil { model.hasPreview }
        let task = Task { await model.start() }
        await waitUntil { continuation != nil }
        model.end(); continuation?.resume(); await task.value
        XCTAssertFalse(model.running); XCTAssertFalse(model.available); XCTAssertGreaterThan(stops, 0)
    }
    func testCancelledStartIsRetryableAndDoesNotExposeTechnicalError() async {
        let model = PresenterModel(observeLifecycle: false)
        model.selectCanvas(); model.open(); await waitUntil { model.hasPreview }
        model.startSharing = { _ in throw CancellationError() }
        await model.start()
        XCTAssertFalse(model.starting); XCTAssertFalse(model.running); XCTAssertNil(model.error)
        XCTAssertTrue(model.hasPreview)
        model.startSharing = { _ in }; model.stopSharing = {}
        await model.start()
        XCTAssertTrue(model.running)
        model.end()
    }
    func testCaptureAndSceneChangesDuringStartDoNotCancelPublication() async {
        let model = PresenterModel(observeLifecycle: false)
        var continuation: CheckedContinuation<Void, Never>?
        var stops = 0
        model.startSharing = { _ in await withCheckedContinuation { continuation = $0 } }
        model.stopSharing = { stops += 1 }
        model.selectCanvas(); model.open(); await waitUntil { model.hasPreview }
        let task = Task { await model.start() }
        await waitUntil { continuation != nil }
        // The guest SDK changes camera state as it starts screen sharing.
        model.update(cameraOn: true, held: false)
        model.update(cameraOn: false, held: false)
        model.scene.backdrop = .warm
        continuation?.resume(); await task.value
        XCTAssertTrue(model.running); XCTAssertFalse(model.starting); XCTAssertEqual(stops, 0)
        model.end()
    }
    func testAnnotationStorageIsBoundedAndClampsCoordinates() {
        let model = PresenterModel(observeLifecycle: false)
        for _ in 0..<50 { model.appendAnnotation(Array(repeating: CGPoint(x: 2, y: -1), count: 1000)) }
        XCTAssertEqual(model.scene.strokes.count, 32)
        XCTAssertEqual(model.scene.strokes.first?.count, 512)
        XCTAssertEqual(model.scene.strokes.first?.first, CGPoint(x: 1, y: 0))
        model.end()
        XCTAssertTrue(model.scene.strokes.isEmpty)
    }
    private final class Screen: PresenterScreenSource {
        var starts = 0, stopped = false
        func start() { starts += 1 }
        func stop() async { stopped = true }
    }
    private func screenSample(width: Int = 160, height: Int = 90) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(PresenterCompositor.sample(XCTUnwrap(buffer), time: CMTime(value: 1, timescale: 30)))
    }
    func testLiveScreenIsPrivateUntilShareAndContinuesWithoutGPUInBackground() async throws {
        let model = PresenterModel(observeLifecycle: false)
        var sent: [CMSampleBuffer] = []
        model.startSharing = { _ in }; model.sendSample = { sent.append($0) }; model.stopSharing = {}
        model.selectCanvas(); model.open(); await waitUntil { model.hasPreview }
        let source = try screenSample(width: 90, height: 160)
        model.acceptScreen(source)
        await waitUntil { model.hasPreview && model.aspectRatio < 1 }
        XCTAssertTrue(sent.isEmpty)
        await model.start(); XCTAssertTrue(model.running)
        model.setForeground(false)
        let count = sent.count
        let compositions = model.compositionCount
        // Background passthrough shares the outgoing cadence with foreground
        // composition. Admit the next frame after that interval, then reject
        // an immediate burst without copying its pixels or running the GPU.
        try await Task.sleep(for: .seconds(1.0 / Double(MediaEnergyBudget.shared.sharingFPS) + 0.02))
        model.acceptScreen(source)
        XCTAssertTrue(model.running); XCTAssertFalse(model.hasPreview)
        XCTAssertEqual(sent.count, count + 1)
        XCTAssertTrue(sent.last.flatMap(CMSampleBufferGetImageBuffer) === CMSampleBufferGetImageBuffer(source),
                      "Screen-only background path must avoid GPU work/pixel copies")
        XCTAssertEqual(model.compositionCount, compositions)
        model.acceptScreen(source)
        XCTAssertEqual(sent.count, count + 1, "Background frame bursts must remain paced")
        model.setForeground(true); await waitUntil { model.hasPreview }
        model.end(); model.acceptScreen(source)
        XCTAssertFalse(model.running)
    }
    func testSourceCancellationAndLateFramesCannotReviveOldScreen() async throws {
        let model = PresenterModel(observeLifecycle: false)
        let capture = Screen()
        var receive: ((CMSampleBuffer) -> Void)?
        var cancelled: ((String?) -> Void)?
        model.makeScreenSource = { frame, _, _, end in receive = frame; cancelled = end; return capture }
        model.selectCanvas(); model.open(); model.selectScreen()
        await waitUntil { capture.starts == 1 }
        cancelled?(nil)
        await waitUntil { capture.stopped }
        XCTAssertFalse(model.screenPicking); XCTAssertFalse(model.screenSelected)
        receive?(try screenSample())
        XCTAssertFalse(model.screenSelected)
        model.end()
    }
    func testScreenPreparationCannotStartCaptureAfterSourceChanges() async {
        let model = PresenterModel(observeLifecycle: false), capture = Screen()
        var prepared: CheckedContinuation<Void, Never>?
        model.prepareScreenSource = { await withCheckedContinuation { prepared = $0 } }
        model.makeScreenSource = { _, _, _, _ in capture }
        model.selectCanvas(); model.open(); model.selectScreen()
        await waitUntil { prepared != nil }
        model.selectCanvas()
        prepared?.resume(); await Task.yield(); await Task.yield()
        XCTAssertEqual(capture.starts, 0); XCTAssertFalse(model.screenPicking)
        model.end()
    }
    func testDragUpdatesDoNotStarvePublicationAndPlacementSurvivesRestartWithoutConsent() async {
        let suite = "presenter-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PresenterModel(observeLifecycle: false, preferences: defaults)
        var sends = 0
        model.startSharing = { _ in }; model.sendSample = { _ in sends += 1 }; model.stopSharing = {}
        model.selectCanvas(); model.open(); await waitUntil { model.hasPreview }; await model.start()
        for index in 0..<30 {
            model.scene.placement.x = CGFloat(index) / 100
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(sends, 3)
        let placement = model.scene.placement
        model.savePlacement(); model.end()
        let next = PresenterModel(observeLifecycle: false, preferences: defaults)
        XCTAssertEqual(next.scene.placement, placement)
        XCTAssertFalse(next.includeCamera); XCTAssertFalse(next.running); XCTAssertNil(next.scene.image)
        next.end()
    }
    func testCameraReadinessExpiresAfterFramesStop() async throws {
        let model = PresenterModel(observeLifecycle: false)
        let capture = Capture()
        var emit: ((CVPixelBuffer, Int) -> Void)?
        capture.onFrames = { emit = $0 }
        model.makePrivateCamera = { _ in capture }
        model.selectCanvas(); model.open(); model.includeCamera = true
        await waitUntil { emit != nil }
        emit?(try XCTUnwrap(CMSampleBufferGetImageBuffer(screenSample())), 0)
        XCTAssertTrue(model.hasCameraFrames)
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertFalse(model.hasCameraFrames)
        model.end()
    }
    func testSystemSelectionIsNotMisrepresentedAsAppliedCapture() {
        XCTAssertEqual(CameraEffectStatus.state(selected: true, supported: nil, active: nil), .selected)
        XCTAssertEqual(CameraEffectStatus.state(selected: true, supported: false, active: false), .unavailable)
        XCTAssertEqual(CameraEffectStatus.state(selected: true, supported: true, active: false), .selected)
        XCTAssertEqual(CameraEffectStatus.state(selected: true, supported: true, active: true), .active)
    }
    func testOwnedCameraNeedsExplicitSelectionAndAwaitsPriorCaptureRelease() async {
        let model = PresenterModel(observeLifecycle: false)
        let capture = Capture(); model.makePrivateCamera = { _ in capture }
        var prepared = false
        model.preparePrivateCamera = { prepared = true }
        model.selectCanvas(); model.open(); await waitUntil { model.hasPreview }
        XCTAssertFalse(capture.started)
        model.includeCamera = true
        await waitUntil { capture.started }
        XCTAssertTrue(prepared); XCTAssertFalse(model.running)
        await model.releaseCamera()
        XCTAssertTrue(capture.stopped)
        model.end()
    }
    func testRetiredCameraStartCompletesCleanupBeforeSDKCanTakeCamera() async {
        let model = PresenterModel(observeLifecycle: false)
        let capture = Capture(); capture.delay = true
        model.makePrivateCamera = { _ in capture }
        model.selectCanvas(); model.open(); model.includeCamera = true
        await waitUntil { capture.waiting != nil }
        var released = false
        let release = Task { await model.releaseCamera(); released = true }
        await Task.yield()
        XCTAssertFalse(released)
        capture.waiting?.resume(); await release.value
        XCTAssertTrue(released); XCTAssertTrue(capture.stopped); XCTAssertFalse(capture.started)
        model.end()
    }
}

/// Opt-in live transport qualification with a manually selected safe Mac window.
@MainActor
final class PresenterLiveTests: XCTestCase {
    func testMacScreenSourceStaysActive() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              let invite = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PRESENTER_INVITE"] else {
            throw XCTSkip("Opt-in live Mac Presenter qualification")
        }
        let root = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first)
        let target = try JoinTarget.parse(invite)
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore())
        try engine.configure(container: root, networkURL: target.originURL, displayName: "Presenter QA")
        try engine.join(target: target, displayName: "Presenter QA")
        defer { engine.leave() }
        for _ in 0..<600 {
            if engine.isSharingScreen { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertTrue(engine.isSharingScreen, "Choose a safe test window and start Presenter sharing")
        try await Task.sleep(nanoseconds: 180_000_000_000)
        XCTAssertTrue(engine.isSharingScreen, "The stream must survive camera/source/layout changes")
    }
}
