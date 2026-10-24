import ConferenceCore
import Combine
import AVFoundation
import ImageIO
import VideoToolbox
import XCTest
@testable import RockNRoll

final class PresenterCompositorTests: XCTestCase {
    func testResizeContextReuseMeasurement() throws {
        let sizes = [CGSize(width: 640, height: 360), CGSize(width: 360, height: 640), CGSize(width: 800, height: 300)]
        var scene = PresenterScene(); scene.strokes = [[CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)]]
        var timings = [Bool: [Double]]()
        for reuse in [false, true, true, false] {
            let retained = reuse ? PresenterCompositor(size: sizes[0]) : nil
            for index in 0..<18 {
                let elapsed = try autoreleasepool { () throws -> Double in
                    let began = ProcessInfo.processInfo.systemUptime
                    let compositor = retained ?? PresenterCompositor(size: sizes[index % sizes.count])
                    compositor.resize(to: sizes[index % sizes.count])
                    _ = try XCTUnwrap(compositor.render(scene: scene, camera: nil, time: .zero))
                    return (ProcessInfo.processInfo.systemUptime - began) * 1_000
                }
                if index >= 3 { timings[reuse, default: []].append(elapsed) }
            }
        }
        for reuse in [false, true] {
            let values = try XCTUnwrap(timings[reuse]).sorted()
            print("PRESENTER_RESIZE_COST reuse=\(reuse) medianMS=\(values[values.count / 2]) samples=\(values.count)")
        }
    }
    func testResizeReusesContextAndRebuildsSizeDependentDrawingCaches() throws {
        let compositor = PresenterCompositor(size: CGSize(width: 160, height: 90), software: true)
        let identity = compositor.contextIdentity
        var scene = PresenterScene(); scene.strokes = [[CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)]]
        for size in [CGSize(width: 160, height: 90), CGSize(width: 90, height: 160), CGSize(width: 240, height: 90)] {
            compositor.resize(to: size)
            let sample = try XCTUnwrap(compositor.render(scene: scene, camera: nil, time: .zero))
            let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            XCTAssertEqual(CVPixelBufferGetWidth(image), Int(size.width)); XCTAssertEqual(CVPixelBufferGetHeight(image), Int(size.height))
            XCTAssertEqual(compositor.contextIdentity, identity)
            let fresh = PresenterCompositor(size: size, software: true)
            XCTAssertEqual(try pixels(sample), try pixels(XCTUnwrap(fresh.render(scene: scene, camera: nil, time: .zero))),
                           "Resizing must invalidate cached annotations/background at the previous geometry")
        }
    }
    func testCameraMirrorChangesOnlyCameraPixelsAndKeepsSceneGeometry() throws {
        let camera = try solid(50)
        CVPixelBufferLockBaseAddress(camera, [])
        let stride = CVPixelBufferGetBytesPerRow(camera)
        let bytes = CVPixelBufferGetBaseAddress(camera)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<90 { for x in 80..<160 {
            for channel in 0..<3 { bytes[y * stride + x * 4 + channel] = 210 }
        } }
        CVPixelBufferUnlockBaseAddress(camera, [])
        for layout in [PresenterScene.Layout.card, .beside, .instrument] {
            let compositor = PresenterCompositor(size: CGSize(width: 160, height: 90), software: true)
            var scene = PresenterScene(); scene.layout = layout
            scene.placement = .init(x: 0.1, y: 0.1, width: 0.4, height: 0.6)
            scene.focus = CGPoint(x: 0.35, y: 0.5); scene.zoom = 1.3
            scene.strokes = [[CGPoint(x: 0.02, y: 0.1), CGPoint(x: 0.02, y: 0.9)]]
            let natural = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: camera, time: .zero)))
            scene.cameraMirrored = true
            let mirrored = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: camera, time: .zero)))
            XCTAssertNotEqual(mirrored, natural)
            let sample = try XCTUnwrap(compositor.render(scene: scene, camera: camera, time: .zero))
            let output = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            let row = CVPixelBufferGetBytesPerRow(output)
            let cameraBounds = layout == .beside ? CGRect(x: 160 * 0.74, y: 90 * 0.08, width: 160 * 0.24, height: 90 * 0.84) : scene.placement.pixels(in: CGSize(width: 160, height: 90))
            for y in 0..<90 { for x in 0..<160 {
                if CGFloat(x) < floor(cameraBounds.minX) - 1 || CGFloat(x) > ceil(cameraBounds.maxX) + 1 {
                    for c in 0..<4 { XCTAssertEqual(mirrored[y * row + x * 4 + c], natural[y * row + x * 4 + c]) }
                }
            } }
            XCTAssertEqual(compositor.backgroundBuilds, 1, "Mirroring must not rebuild the slide/background")
            XCTAssertEqual(compositor.annotationRasterizations, 1)
        }
    }

    func testMirroringCutoutReusesTheMaskAndNeverExposesUnmaskedCamera() throws {
        let camera = try solid(220)
        var mask: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_OneComponent8,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &mask), kCVReturnSuccess)
        let half = try XCTUnwrap(mask)
        CVPixelBufferLockBaseAddress(half, [])
        let stride = CVPixelBufferGetBytesPerRow(half)
        let bytes = CVPixelBufferGetBaseAddress(half)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<90 { memset(bytes + y * stride, 255, 80); memset(bytes + y * stride + 80, 0, stride - 80) }
        CVPixelBufferUnlockBaseAddress(half, [])
        var requests = 0
        let compositor = PresenterCompositor(size: CGSize(width: 160, height: 90), software: true,
            personMask: { _, _ in requests += 1; return half })
        var scene = PresenterScene(); scene.layout = .cutout
        let natural = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: camera, cameraRevision: 1, time: .zero)))
        scene.cameraMirrored = true
        let mirrored = try pixels(XCTUnwrap(compositor.render(scene: scene, camera: camera, cameraRevision: 1, time: .zero)))
        XCTAssertNotEqual(natural, mirrored)
        XCTAssertEqual(requests, 1)
        let rejected = PresenterCompositor(size: CGSize(width: 160, height: 90), software: true, personMask: { _, _ in nil })
        XCTAssertEqual(try pixels(XCTUnwrap(rejected.render(scene: scene, camera: camera, time: .zero))),
            try pixels(XCTUnwrap(rejected.render(scene: scene, camera: nil, time: .zero))))
    }

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
        var scene = PresenterScene(layout: .card)
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
        var scene = PresenterScene(layout: .card); scene.cameraRotation = 90
        let manual = try XCTUnwrap(compositor.render(scene: scene, camera: camera, time: .zero))
        let device = try XCTUnwrap(compositor.render(scene: PresenterScene(layout: .card), camera: camera, rotation: 90, time: .zero))
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
        var scene = PresenterScene(layout: .card)
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
    func testMissingOrUnknownLayoutDefaultsToCutoutWithoutCameraConsent() {
        XCTAssertEqual(PresenterScene().layout, .cutout)
        for stored in [nil, "unknown-layout"] as [String?] {
            let suite = "presenter-default-test-" + UUID().uuidString
            let preferences = UserDefaults(suiteName: suite)!
            defer { preferences.removePersistentDomain(forName: suite) }
            if let stored { preferences.set(stored, forKey: "presenter.layout.v1") }
            let model = PresenterModel(observeLifecycle: false, preferences: preferences, cameraDevices: { [] })
            XCTAssertEqual(model.scene.layout, .cutout)
            XCTAssertFalse(model.includeCamera); XCTAssertFalse(model.running); XCTAssertFalse(model.hasCameraFrames)
            XCTAssertEqual(preferences.string(forKey: "presenter.layout.v1"), stored,
                           "Reading a default must not overwrite a stored choice")
            model.end()
        }
    }
    func testEverySavedLayoutSurvivesRestartWithoutEnablingCamera() {
        for layout in PresenterScene.Layout.allCases {
            let suite = "presenter-layout-test-" + UUID().uuidString
            let preferences = UserDefaults(suiteName: suite)!
            defer { preferences.removePersistentDomain(forName: suite) }
            preferences.set(layout.rawValue, forKey: "presenter.layout.v1")
            for _ in 0..<2 {
                let model = PresenterModel(observeLifecycle: false, preferences: preferences, cameraDevices: { [] })
                XCTAssertEqual(model.scene.layout, layout, "A new default must preserve an existing layout")
                XCTAssertFalse(model.includeCamera); XCTAssertFalse(model.running)
                model.end()
            }
            XCTAssertEqual(preferences.string(forKey: "presenter.layout.v1"), layout.rawValue)
        }
    }
    func testCameraMirroringDefaultsOnAndPersistsAcrossPresenterRestart() {
        let suite = "presenter-mirror-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = PresenterModel(observeLifecycle: false, preferences: preferences)
        XCTAssertTrue(first.mirrorCamera)
        first.mirrorCamera = false; first.end()
        let next = PresenterModel(observeLifecycle: false, preferences: preferences)
        XCTAssertFalse(next.mirrorCamera)
        next.end()
    }
    private final class LiveCamera: PresenterCameraSource {
        var stopped = false
        func stop() { stopped = true }
    }
    private final class Capture: PrivateCameraPreviewing {
        let view = UIView()
        var started = false, stopped = false
        var frameRate = 0
        func setFrameRate(_ fps: Int) { frameRate = fps }
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
    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 { if predicate() { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Presenter did not settle", file: file, line: line)
    }
    func testPublishingUpdatesPreserveLiveCameraButReleasePrivateCapture() async throws {
        let model = PresenterModel(observeLifecycle: false)
        defer { model.end() }
        let capture = Capture(), live = LiveCamera()
        model.makePrivateCamera = { _ in capture }
        model.selectCanvas(); model.includeCamera = true; model.open()
        await waitUntil { capture.started }
        await model.releasePrivateCamera()
        XCTAssertTrue(capture.stopped)
        var deliver: ((CVPixelBuffer, Int) -> Void)?
        model.makeCameraSource = { deliver = $0; return live }
        model.update(cameraOn: true, held: false)
        await waitUntil { deliver != nil }
        let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(screenSample()))
        deliver?(pixels, 0)
        XCTAssertTrue(model.hasCameraFrames)
        let generation = model.cameraGeneration
        for _ in 0..<3 { await model.releasePrivateCamera() }
        XCTAssertFalse(live.stopped, "Share, microphone and sound-profile updates reuse the same live tap")
        XCTAssertEqual(model.cameraGeneration, generation)
        deliver?(pixels, 0)
        XCTAssertTrue(model.hasCameraFrames)
        model.update(cameraOn: true, held: true)
        await waitUntil { live.stopped }
        XCTAssertFalse(model.hasCameraFrames)
    }
    func testSetupDoesNotSendUntilExplicitShareAndHoldStopsSharing() async {
        let model = PresenterModel(observeLifecycle: false)
        var starts = 0, sends = 0, stops = 0
        model.startSharing = { _, _ in starts += 1 }
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
        model.startSharing = { sample, _ in samples.append(sample) }; model.sendSample = { samples.append($0) }; model.stopSharing = {}
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
        let started = ProcessInfo.processInfo.systemUptime
        let ceiling = MediaEnergyBudget.shared.previewFPS
        for index in 0..<60 {
            emit?(buffer, 0); model.scene.placement.x = CGFloat(index % 10) / 100
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThanOrEqual(model.compositionCount - before, Int(ceil(elapsed * Double(ceiling))) + 2,
            "Frames and edits share the preview ceiling, including one pending composition")
        let settled = model.compositionCount
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertLessThanOrEqual(model.compositionCount, settled + 2,
            "Only a pending frame and one camera-expiry transition may compose after the source stops")
        model.includeCamera = false
        await waitUntil { capture.stopped }
    }
    func testStillEditRetriesWhenEncoderReleasesPoolBuffers() async throws {
        let model = PresenterModel(observeLifecycle: false)
        defer { model.end() }
        var held: [CMSampleBuffer] = []
        model.startSharing = { sample, _ in held.append(sample) }; model.sendSample = { held.append($0) }; model.stopSharing = {}
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
        model.startSharing = { _, _ in await withCheckedContinuation { continuation = $0 } }
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
        model.startSharing = { _, _ in throw CancellationError() }
        await model.start()
        XCTAssertFalse(model.starting); XCTAssertFalse(model.running); XCTAssertNil(model.error)
        XCTAssertTrue(model.hasPreview)
        model.startSharing = { _, _ in }; model.stopSharing = {}
        await model.start()
        XCTAssertTrue(model.running)
        model.end()
    }
    func testCaptureAndSceneChangesDuringStartDoNotCancelPublication() async {
        let model = PresenterModel(observeLifecycle: false)
        var continuation: CheckedContinuation<Void, Never>?
        var stops = 0
        model.startSharing = { _, _ in await withCheckedContinuation { continuation = $0 } }
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
    private func screenSample(width: Int = 160, height: Int = 90, gray: UInt8 = 0) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for row in 0..<height {
            for column in 0..<width {
                let index = row * stride + column * 4
                bytes[index] = gray; bytes[index + 1] = gray; bytes[index + 2] = gray; bytes[index + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return try XCTUnwrap(PresenterCompositor.sample(pixels, time: CMTime(value: 1, timescale: 30)))
    }
    private func centerGray(_ sample: CMSampleBuffer?) -> UInt8? {
        guard let sample, let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return bytes[CVPixelBufferGetHeight(buffer) / 2 * CVPixelBufferGetBytesPerRow(buffer) + CVPixelBufferGetWidth(buffer) / 2 * 4]
    }
    func testMacPublishedPresenterKeepsLiveCameraPixelsAcrossDesktopChanges() async throws {
        let model = PresenterModel(observeLifecycle: false, backgroundCompositionSupported: true)
        defer { model.end() }
        let capture = Capture()
        var emit: ((CVPixelBuffer, Int) -> Void)?
        var last: CMSampleBuffer?, sends = 0
        model.makePrivateCamera = { _ in capture }; capture.onFrames = { emit = $0 }
        model.startSharing = { sample, _ in last = sample }; model.sendSample = { last = $0; sends += 1 }; model.stopSharing = {}
        model.scene = PresenterScene(layout: .card)
        model.scene.placement = PresenterPlacement(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        model.open(); model.acceptScreen(try screenSample(gray: 20)); model.includeCamera = true
        await waitUntil { emit != nil && model.hasPreview }
        emit?(try XCTUnwrap(CMSampleBufferGetImageBuffer(screenSample(gray: 150))), 0)
        await waitUntil { model.hasCameraFrames && model.compositionCount >= 2 }
        await model.start()
        let generation = model.cameraGeneration
        model.setForeground(false); model.close()
        XCTAssertTrue(model.running); XCTAssertFalse(model.cameraHiddenInBackground)
        XCTAssertFalse(capture.stopped); XCTAssertEqual(model.cameraGeneration, generation)
        // New camera pixels must keep reaching the published composite, even
        // with the inspector closed and the app on another desktop.
        for gray in [UInt8(170), UInt8(220)] {
            let before = sends
            emit?(try XCTUnwrap(CMSampleBufferGetImageBuffer(screenSample(gray: gray))), 0)
            model.acceptScreen(try screenSample(gray: 40))
            await waitUntil { sends > before && self.centerGray(last).map { abs(Int($0) - Int(gray)) <= 3 } == true }
        }
        XCTAssertTrue(model.hasCameraFrames); XCTAssertFalse(capture.stopped)
        model.stop(); await waitUntil { capture.stopped }
        let stopped = sends
        emit?(try XCTUnwrap(CMSampleBufferGetImageBuffer(screenSample(gray: 255))), 0)
        model.acceptScreen(try screenSample())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sends, stopped); XCTAssertFalse(model.hasCameraFrames)
    }
    func testMacBackgroundDuringShareStartPreservesCameraAndCompletesPublication() async throws {
        let model = PresenterModel(observeLifecycle: false, backgroundCompositionSupported: true)
        defer { model.end() }
        let live = LiveCamera()
        var emit: ((CVPixelBuffer, Int) -> Void)?
        var continuation: CheckedContinuation<Void, Never>?
        var last: CMSampleBuffer?, sends = 0
        model.makeCameraSource = { emit = $0; return live }
        model.startSharing = { _, _ in await withCheckedContinuation { continuation = $0 } }
        model.sendSample = { last = $0; sends += 1 }; model.stopSharing = {}
        model.scene = PresenterScene(layout: .card)
        model.scene.placement = PresenterPlacement(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        model.open(); model.acceptScreen(try screenSample()); model.includeCamera = true
        model.update(cameraOn: true, held: false)
        await waitUntil { model.canStartSharing && emit != nil }
        let start = Task { await model.start() }
        await waitUntil { continuation != nil }
        model.setForeground(false)
        XCTAssertFalse(live.stopped)
        continuation?.resume(); await start.value
        XCTAssertTrue(model.running); XCTAssertFalse(model.starting)
        let frame = try XCTUnwrap(CMSampleBufferGetImageBuffer(screenSample(gray: 210)))
        // Keep the live source moving while the first worker job finishes;
        // a lone frame can expire during a slow simulator render.
        for _ in 0..<40 {
            emit?(frame, 0)
            if sends > 0 && centerGray(last).map({ $0 > 200 }) == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(sends, 0)
        XCTAssertGreaterThan(try XCTUnwrap(centerGray(last)), 200)
        model.update(cameraOn: true, held: true)
        await waitUntil { live.stopped }
        XCTAssertFalse(model.running); XCTAssertFalse(model.hasCameraFrames)
    }
    func testMacPrivateCameraStillStopsWhileHiddenWithoutPublishing() async throws {
        let model = PresenterModel(observeLifecycle: false, backgroundCompositionSupported: true)
        defer { model.end() }
        let capture = Capture()
        var emit: ((CVPixelBuffer, Int) -> Void)?, sends = 0
        model.makePrivateCamera = { _ in capture }; capture.onFrames = { emit = $0 }
        model.startSharing = { _, _ in sends += 1 }; model.sendSample = { _ in sends += 1 }
        model.open(); model.acceptScreen(try screenSample()); model.includeCamera = true
        await waitUntil { emit != nil && model.hasPreview }
        model.setForeground(false); await waitUntil { capture.stopped }
        let composed = model.compositionCount
        emit?(try XCTUnwrap(CMSampleBufferGetImageBuffer(screenSample(gray: 255))), 0)
        model.acceptScreen(try screenSample()); await model.start()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.hasCameraFrames); XCTAssertFalse(model.hasPreview)
        XCTAssertEqual(model.compositionCount, composed); XCTAssertEqual(sends, 0)
    }
    func testPhonePublishedScreenDropsCameraAndAvoidsBackgroundComposition() async throws {
        let model = PresenterModel(observeLifecycle: false, backgroundCompositionSupported: false)
        defer { model.end() }
        let capture = Capture()
        var last: CMSampleBuffer?
        model.makePrivateCamera = { _ in capture }
        model.startSharing = { _, _ in }; model.sendSample = { last = $0 }; model.stopSharing = {}
        model.open(); model.acceptScreen(try screenSample()); model.includeCamera = true
        await waitUntil { capture.started && model.canStartSharing }
        await model.start(); model.setForeground(false)
        await waitUntil { capture.stopped }
        let composed = model.compositionCount
        try await Task.sleep(for: .seconds(1.0 / Double(MediaEnergyBudget.shared.sharingFPS) + 0.02))
        let sample = try screenSample(gray: 40)
        model.acceptScreen(sample)
        XCTAssertTrue(model.running); XCTAssertTrue(model.cameraHiddenInBackground)
        XCTAssertEqual(model.compositionCount, composed)
        XCTAssertTrue(last.flatMap(CMSampleBufferGetImageBuffer) === CMSampleBufferGetImageBuffer(sample))
    }
    func testMacPublishedCanvasKeepsComposingWhileHiddenUntilEnd() async throws {
        let model = PresenterModel(observeLifecycle: false, backgroundCompositionSupported: true)
        defer { model.end() }
        var sends = 0
        model.startSharing = { _, _ in }; model.sendSample = { _ in sends += 1 }; model.stopSharing = {}
        model.selectCanvas(); model.open(); await waitUntil { model.canStartSharing }
        await model.start(); model.setForeground(false)
        let before = sends
        model.scene.backdrop = .warm
        await waitUntil { sends > before }
        XCTAssertTrue(model.running); XCTAssertNil(model.error)
        model.end(); let stopped = sends
        model.scene.backdrop = .stage
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sends, stopped)
    }
    private final class CountingMacCamera: PrivateCameraPreviewing {
        let capture = PrivateCameraPreview(framesPerSecond: 15)
        var frameCount = 0
        var view: UIView { capture.view }
        func start() async throws { try await capture.start() }
        func startFrames(_ frames: @escaping @MainActor (CVPixelBuffer, Int) -> Void) async throws {
            try await capture.startFrames { [weak self] buffer, rotation in
                self?.frameCount += 1
                frames(buffer, rotation)
            }
        }
        func stop() async { await capture.stop() }
    }
    func testMacNativePresenterCameraKeepsProducingPublishedFramesWhileHidden() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac else { throw XCTSkip("Mac native camera lifecycle") }
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_PRESENTER_CAMERA"] == "1" else {
            throw XCTSkip("Opt-in real Mac camera qualification")
        }
        let model = PresenterModel(), camera = CountingMacCamera()
        defer {
            NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
            model.end()
        }
        var sends = 0
        model.makePrivateCamera = { _ in camera }
        model.startSharing = { _, _ in }; model.sendSample = { _ in sends += 1 }; model.stopSharing = {}
        model.setForeground(true); model.open(); model.acceptScreen(try screenSample())
        model.includeCamera = true
        for _ in 0..<2_000 {
            if model.hasCameraFrames && model.canStartSharing || model.error != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        print("MAC_PRESENTER_CAMERA_READY auth=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue) frames=\(camera.frameCount) error=\(model.error ?? "none") state=\(model.cameraEvidenceForTesting)")
        XCTAssertTrue(model.hasCameraFrames, "Native camera must work before testing background composition")
        guard model.hasCameraFrames else { return }
        await model.start()
        XCTAssertTrue(model.running)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        model.close()
        let framesBefore = camera.frameCount, sendsBefore = sends
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(camera.capture.captureSessionForTesting.isRunning)
        XCTAssertGreaterThan(camera.frameCount - framesBefore, 15, "Real AVCapture callbacks must keep arriving off-desktop")
        XCTAssertGreaterThan(sends - sendsBefore, 8, "Publishing must compose moving camera frames, not stale heartbeats")
        XCTAssertTrue(model.hasCameraFrames); XCTAssertFalse(model.cameraHiddenInBackground)
        print("MAC_PRESENTER_HIDDEN cameraFrames=\(camera.frameCount - framesBefore) publishedFrames=\(sends - sendsBefore) elapsed=2s lifecycle=injected")
        model.end(); await model.releaseCamera()
        XCTAssertFalse(camera.capture.captureSessionForTesting.isRunning)
    }
    func testMacDesktopBackgroundPreservesPendingPrivatePresenterSelection() async throws {
        let studio = StudioModel(audioControl: .noiseSuppression), capture = Screen()
        defer { studio.end() }
        let model = studio.presenter
        var selected: ((PresenterScreenSelection) -> Void)?, receive: ((CMSampleBuffer) -> Void)?
        var published = 0
        model.startSharing = { _, _ in published += 1 }
        model.makeScreenSource = { frame, _, selection, _ in
            receive = frame; selected = selection; return capture
        }
        studio.open(.presenter); model.selectScreen()
        await waitUntil { capture.starts == 1 }
        model.setForeground(false); studio.handleBackground(isMac: true)
        XCTAssertTrue(studio.presented); XCTAssertTrue(model.screenPicking)
        selected?(.selected); receive?(try screenSample(width: 640, height: 480))
        XCTAssertTrue(model.screenSelected); XCTAssertFalse(model.hasPreview)
        XCTAssertFalse(capture.stopped); XCTAssertEqual(published, 0)
        model.setForeground(true)
        await waitUntil { model.canStartSharing }
        XCTAssertEqual(model.aspectRatio, 4 / 3)
        await model.start()
        XCTAssertTrue(model.running); XCTAssertEqual(published, 1)
        model.stop(); await model.waitForScreenStop()
        XCTAssertTrue(capture.stopped)
    }
    func testPhoneBackgroundStillClosesPrivatePresenterAndRejectsLateSelection() async throws {
        let studio = StudioModel(audioControl: .noiseSuppression), capture = Screen()
        defer { studio.end() }
        let model = studio.presenter
        var selected: ((PresenterScreenSelection) -> Void)?, receive: ((CMSampleBuffer) -> Void)?
        model.makeScreenSource = { frame, _, selection, _ in
            receive = frame; selected = selection; return capture
        }
        studio.open(.presenter); model.selectScreen()
        await waitUntil { capture.starts == 1 }
        model.setForeground(false); studio.handleBackground(isMac: false)
        await model.waitForScreenStop()
        XCTAssertFalse(studio.presented); XCTAssertTrue(capture.stopped)
        selected?(.selected); receive?(try screenSample())
        XCTAssertFalse(model.screenSelected); XCTAssertFalse(model.running)
    }
    func testMacBackgroundNotificationDoesNotDismissThePresenterInspector() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac else { throw XCTSkip("Mac desktop lifecycle") }
        let studio = StudioModel(audioControl: .noiseSuppression), capture = Screen()
        defer {
            NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
            studio.end()
        }
        var selected: ((PresenterScreenSelection) -> Void)?, receive: ((CMSampleBuffer) -> Void)?
        studio.presenter.makeScreenSource = { frame, _, selection, _ in
            receive = frame; selected = selection; return capture
        }
        studio.presenter.setForeground(true)
        studio.open(.presenter); studio.presenter.selectScreen()
        await waitUntil { capture.starts == 1 }
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertTrue(studio.presented, "Switching macOS Spaces must not dismiss the requesting inspector")
        selected?(.selected); receive?(try screenSample())
        XCTAssertFalse(studio.presenter.hasPreview)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await waitUntil { studio.presenter.hasPreview }
        XCTAssertTrue(studio.presenter.screenSelected); XCTAssertFalse(capture.stopped)
    }
    func testPrivateScreenPreparationWaitsForReturnFromAnotherDesktop() async throws {
        let model = PresenterModel(observeLifecycle: false, screenPreparationTimeout: 0.04), capture = Screen()
        defer { model.end() }
        var selected: ((PresenterScreenSelection) -> Void)?, receive: ((CMSampleBuffer) -> Void)?
        var published = 0
        model.startSharing = { _, _ in published += 1 }
        model.makeScreenSource = { frame, _, selection, _ in
            receive = frame; selected = selection; return capture
        }
        model.open(); model.selectScreen(); await waitUntil { capture.starts == 1 }
        selected?(.selected); model.setForeground(false)
        receive?(try screenSample())
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(model.error); XCTAssertFalse(capture.stopped)
        XCTAssertTrue(model.screenPreparing); XCTAssertFalse(model.hasPreview)
        XCTAssertEqual(model.compositionCount, 0); XCTAssertEqual(published, 0)
        model.setForeground(true); await waitUntil { model.canStartSharing }
        XCTAssertNil(model.error); XCTAssertFalse(model.running)
    }
    func testScreenPreviewTimeoutStartsWhenReturningToItsInspector() async throws {
        let model = PresenterModel(observeLifecycle: false, screenPreparationTimeout: 0.04), capture = Screen()
        defer { model.end() }
        var selected: ((PresenterScreenSelection) -> Void)?
        model.makeScreenSource = { _, _, selection, _ in selected = selection; return capture }
        model.open(); model.selectScreen(); await waitUntil { capture.starts == 1 }
        model.setForeground(false); selected?(.selected)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(model.error); XCTAssertFalse(capture.stopped)
        model.setForeground(true)
        await waitUntil { model.error != nil && capture.stopped }
        XCTAssertFalse(model.screenPicking); XCTAssertFalse(model.screenPreparing)
        XCTAssertFalse(model.screenSelected); XCTAssertFalse(model.running)
    }
    func testLiveScreenIsPrivateUntilShareAndContinuesWithoutGPUInBackground() async throws {
        let model = PresenterModel(observeLifecycle: false, backgroundCompositionSupported: false)
        var sent: [CMSampleBuffer] = []
        model.startSharing = { _, _ in }; model.sendSample = { sent.append($0) }; model.stopSharing = {}
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
        var selected: ((PresenterScreenSelection) -> Void)?
        var cancelled: ((String?) -> Void)?
        model.makeScreenSource = { frame, _, selection, end in receive = frame; selected = selection; cancelled = end; return capture }
        model.selectCanvas(); model.open(); model.selectScreen()
        await waitUntil { capture.starts == 1 }
        selected?(.selected); cancelled?(nil)
        await waitUntil { capture.stopped }
        XCTAssertFalse(model.screenPicking); XCTAssertFalse(model.screenSelected)
        XCTAssertEqual(model.source, .canvas)
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
    func testScreenSelectionBeforeFirstFrameKeepsScreenSourceAndPrivatePreview() async throws {
        let model = PresenterModel(observeLifecycle: false), capture = Screen()
        defer { model.end() }
        var receive: ((CMSampleBuffer) -> Void)?
        var selected: ((PresenterScreenSelection) -> Void)?
        var prepared = false, published = 0
        model.prepareScreenSource = { prepared = true }
        model.makeScreenSource = { frame, _, selection, _ in
            XCTAssertTrue(prepared, "Retire the ordinary share before registering a second picker")
            receive = frame; selected = selection; return capture
        }
        model.startSharing = { _, _ in published += 1 }
        model.selectCanvas(); model.open(); await waitUntil { model.hasPreview }
        model.selectScreen(); await waitUntil { capture.starts == 1 }
        selected?(.selected)
        XCTAssertEqual(model.source, .screen)
        XCTAssertFalse(model.screenPicking); XCTAssertFalse(model.screenSelected)
        receive?(try screenSample(width: 640, height: 480))
        await waitUntil { model.hasPreview }
        XCTAssertEqual(model.source, .screen); XCTAssertEqual(model.aspectRatio, 4 / 3)
        XCTAssertEqual(published, 0, "Selecting a screen remains a private setup action")
        await model.start()
        XCTAssertTrue(model.running); XCTAssertEqual(published, 1)
    }
    func testShareWaitsForFirstRenderedFrameAndPreparationTimeoutIsRetryable() async throws {
        let model = PresenterModel(observeLifecycle: false, screenPreparationTimeout: 0.08)
        defer { model.end() }
        let capture = Screen()
        var selected: ((PresenterScreenSelection) -> Void)?, receive: ((CMSampleBuffer) -> Void)?
        var starts = 0
        model.startSharing = { _, _ in starts += 1 }
        model.makeScreenSource = { frame, _, selection, _ in selected = selection; receive = frame; return capture }
        model.open(); model.selectScreen(); await waitUntil { capture.starts == 1 }
        XCTAssertTrue(model.screenPicking); XCTAssertFalse(model.canStartSharing)
        selected?(.selected); XCTAssertTrue(model.screenPreparing)
        await model.start(); XCTAssertEqual(starts, 0)
        await waitUntil { model.error != nil }
        XCTAssertEqual(model.screenSelectionPhase, .idle); XCTAssertFalse(model.screenSelected)
        await model.waitForScreenStop(); XCTAssertTrue(capture.stopped)
        model.selectScreen(); await waitUntil { capture.starts == 2 }; selected?(.selected)
        receive?(try screenSample()); XCTAssertFalse(model.canStartSharing, "A captured frame still needs a rendered preview")
        await waitUntil { model.canStartSharing }
        XCTAssertEqual(model.screenSelectionPhase, .ready)
        await model.start(); XCTAssertTrue(model.running); XCTAssertEqual(starts, 1)
    }
    func testOldFramesCannotDismissReplacementChooserAndCancelledSelectionKeepsShare() async throws {
        let model = PresenterModel(observeLifecycle: false), capture = Screen()
        defer { model.end() }
        var selected: ((PresenterScreenSelection) -> Void)?, receive: ((CMSampleBuffer) -> Void)?
        var stops = 0
        model.startSharing = { _, _ in }; model.stopSharing = { stops += 1 }
        model.makeScreenSource = { frame, _, selection, _ in selected = selection; receive = frame; return capture }
        model.open(); model.selectScreen(); await waitUntil { capture.starts == 1 }; selected?(.selected)
        receive?(try screenSample()); await waitUntil { model.canStartSharing }; await model.start()
        model.selectScreen(); XCTAssertTrue(model.screenPicking)
        receive?(try screenSample()); XCTAssertTrue(model.screenPicking)
        // A cancelled replacement keeps its existing capture.
        selected?(.cancelled); XCTAssertTrue(model.running); XCTAssertTrue(model.screenSelected)
        XCTAssertEqual(stops, 0); XCTAssertFalse(capture.stopped)
    }
    func testScreenResizePreservesRunningSenderAndChangesPlainAndComposedOutput() async throws {
        for composed in [false, true] {
            let model = PresenterModel(observeLifecycle: false)
            var sizes = [CGSize](), starts = 0, stops = 0
            model.startSharing = { _, _ in starts += 1 }; model.stopSharing = { stops += 1 }
            model.sendSample = { sample in
                if let pixels = CMSampleBufferGetImageBuffer(sample) {
                    sizes.append(CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)))
                }
            }
            model.open()
            if composed { model.appendAnnotation([CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)]) }
            model.acceptScreen(try screenSample(width: 640, height: 480))
            await waitUntil { model.hasPreview }
            await model.start(); XCTAssertTrue(model.running)
            var resizeSizes = [CGSize(width: 360, height: 640), CGSize(width: 1200, height: 450), CGSize(width: 550, height: 350)]
            if ProcessInfo.processInfo.isiOSAppOnMac {
                resizeSizes += [CGSize(width: 2560, height: 1600), CGSize(width: 3840, height: 2160)]
            }
            for size in resizeSizes {
                model.acceptScreen(try screenSample(width: Int(size.width), height: Int(size.height)))
                XCTAssertTrue(model.hasPreview, "Keep the visible preview until a resized frame is ready")
                await waitUntil { sizes.last == size }
                XCTAssertEqual(model.aspectRatio, size.width / size.height)
                XCTAssertTrue(model.hasPreview); XCTAssertTrue(model.running)
            }
            XCTAssertEqual(starts, 1); XCTAssertEqual(stops, 0)
            XCTAssertEqual(model.compositionCount > 0, composed)
            model.end(); await model.waitForScreenStop()
        }
    }
    func testStableScreenFramesDoNotRepublishSelectionState() async throws {
        let model = PresenterModel(observeLifecycle: false)
        defer { model.end() }
        model.open()
        let frame = try screenSample()
        model.acceptScreen(frame); await waitUntil { model.hasPreview }
        var changes = 0
        let selection = model.$screenSelected.dropFirst().sink { _ in changes += 1 }
        let source = model.$source.dropFirst().sink { _ in changes += 1 }
        for _ in 0..<30 { model.acceptScreen(frame) }
        XCTAssertEqual(changes, 0, "New pixels must not rebuild controls for unchanged source selection")
        withExtendedLifetime((selection, source)) {}
    }
    func testDragUpdatesDoNotStarvePublicationAndPlacementSurvivesRestartWithoutConsent() async {
        let suite = "presenter-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PresenterModel(observeLifecycle: false, preferences: defaults)
        XCTAssertEqual(model.scene.layout, .cutout)
        model.scene.layout = .beside
        var sends = 0
        model.startSharing = { _, _ in }; model.sendSample = { _ in sends += 1 }; model.stopSharing = {}
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
        XCTAssertEqual(next.scene.layout, .beside)
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

extension PresenterModelTests {
    func testReplacementWaitsForNewSourcePixels() async throws {
        let model = PresenterModel(observeLifecycle: false, screenPreparationTimeout: 0.15,
                                   backgroundCompositionSupported: true)
        defer { model.end() }
        let screen = Screen()
        var selected: ((PresenterScreenSelection) -> Void)?, receive: ((CMSampleBuffer) -> Void)?
        var lastSent: CMSampleBuffer?
        model.startSharing = { sample, _ in lastSent = sample }; model.stopSharing = {}
        model.makeScreenSource = { frame, _, selection, _ in
            receive = frame; selected = selection; return screen
        }
        model.open(); model.selectScreen()
        await waitUntil { screen.starts == 1 }
        selected?(.selected); receive?(try screenSample(gray: 31))
        await waitUntil { model.canStartSharing }
        model.selectScreen()
        XCTAssertTrue(model.screenPicking)
        selected?(.selected) // The replacement SCStream starts, but has not delivered a frame.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.canStartSharing, "Old source pixels must not enable Share for the newly selected window")
        await model.start()
        XCTAssertNil(lastSent, "A private replacement must not publish the previous window")
        receive?(try screenSample(gray: 210))
        await waitUntil { model.canStartSharing }
        await model.start()
        XCTAssertEqual(centerGray(lastSent), 210)
    }

    func testRetiredStartCannotStopNewPublication() async throws {
        let model = PresenterModel(observeLifecycle: false, backgroundCompositionSupported: true)
        defer { model.end() }
        var suspended: CheckedContinuation<Void, Never>?
        var starts = 0, stops = 0, live = false
        model.startSharing = { _, request in
            starts += 1
            if starts == 1 { await withCheckedContinuation { suspended = $0 } }
            try request.checkCancellation()
            live = true
        }
        model.stopSharing = { stops += 1; live = false; model.sharingEnded() }
        model.selectCanvas(); model.open()
        await waitUntil { model.canStartSharing }
        let previous = Task { await model.start() }
        await waitUntil { suspended != nil }
        model.stop()
        await waitUntil { !model.stopping && model.canStartSharing }
        await model.start()
        XCTAssertTrue(model.running); XCTAssertTrue(live)
        let before = stops
        suspended?.resume(); await previous.value
        XCTAssertEqual(stops, before, "An obsolete start must not stop the current publisher")
        XCTAssertTrue(model.running); XCTAssertTrue(live)
    }

    func testReturnReplaysLatestStaticPreview() async throws {
        let model = PresenterModel(observeLifecycle: false, backgroundCompositionSupported: true)
        defer { model.end() }
        var lastSent: CMSampleBuffer?
        model.startSharing = { sample, _ in lastSent = sample }; model.sendSample = { lastSent = $0 }; model.stopSharing = {}
        model.open(); model.acceptScreen(try screenSample(gray: 31))
        await waitUntil { model.canStartSharing }
        await model.start()
        let before = model.preview.evidenceForTesting["accepted"] as? Int ?? 0
        XCTAssertGreaterThan(before, 0)
        model.setForeground(false)
        model.acceptScreen(try screenSample(gray: 210))
        await waitUntil { self.centerGray(lastSent) == 210 }
        XCTAssertEqual(model.preview.evidenceForTesting["accepted"] as? Int ?? 0, before)
        model.setForeground(true)
        try await Task.sleep(for: .milliseconds(100))
        let after = model.preview.evidenceForTesting["accepted"] as? Int ?? 0
        XCTAssertGreaterThan(after, before, "Returning to a still Presenter must display the newest background-composed frame")
    }
}

@MainActor extension PresenterModelTests {
    func testOwnedPresenterCameraAdaptsToPressureWithoutRestart() async throws {
        let budget = MediaEnergyBudget(observeSystem: false, recoveryDelay: 1)
        let model = PresenterModel(observeLifecycle: false, energyBudget: budget), capture = Capture()
        defer { model.end() }
        model.makePrivateCamera = { _ in capture }
        model.selectCanvas(); model.includeCamera = true; model.open()
        await waitUntil { capture.started && capture.frameRate == 15 }
        let generation = model.cameraGeneration
        budget.update(lowPower: true, thermal: .nominal)
        await waitUntil { capture.frameRate == 10 }
        budget.update(lowPower: false, thermal: .critical)
        await waitUntil { capture.frameRate == 5 }
        budget.update(lowPower: false, thermal: .nominal)
        await waitUntil { capture.frameRate == 15 }
        XCTAssertEqual(model.cameraGeneration, generation)
        XCTAssertFalse(capture.stopped, "Pressure changes must not interrupt the live camera")
    }
}

@MainActor extension PresenterModelTests {
    func testFailedLiveWindowReplacementRetiresFrozenPublication() async throws {
        let model = PresenterModel(observeLifecycle: false, screenPreparationTimeout: 0.05)
        defer { model.end() }
        let screen = Screen()
        var selection: ((PresenterScreenSelection) -> Void)?, frame: ((CMSampleBuffer) -> Void)?
        var stops = 0
        model.startSharing = { _, _ in }; model.stopSharing = { stops += 1 }
        model.makeScreenSource = { receive, _, selected, _ in frame = receive; selection = selected; return screen }
        model.open(); model.selectScreen(); await waitUntil { screen.starts == 1 }
        selection?(.selected); frame?(try screenSample())
        await waitUntil { model.canStartSharing }; await model.start()
        model.selectScreen(); selection?(.selected)
        await waitUntil { model.error != nil && !model.running && !model.stopping }
        await model.waitForScreenStop()
        XCTAssertEqual(stops, 1); XCTAssertTrue(screen.stopped)
        XCTAssertFalse(model.hasPreview); XCTAssertFalse(model.screenSelected)
    }
}

@MainActor extension PresenterModelTests {
    func testSourceFailureRetiresMissingWindowButPreservesLiveCanvas() async throws {
        for canvas in [false, true] {
            let model = PresenterModel(observeLifecycle: false), screen = Screen()
            var frame: ((CMSampleBuffer) -> Void)?, selection: ((PresenterScreenSelection) -> Void)?, ended: ((String?) -> Void)?
            var stops = 0
            model.startSharing = { _, _ in }; model.stopSharing = { stops += 1 }
            model.makeScreenSource = { receive, _, selected, end in frame = receive; selection = selected; ended = end; return screen }
            model.open()
            if canvas { model.selectCanvas() }
            else {
                model.selectScreen(); await waitUntil { screen.starts == 1 }
                selection?(.selected); frame?(try screenSample())
            }
            await waitUntil { model.canStartSharing }; await model.start()
            model.selectScreen(); await waitUntil { screen.starts == (canvas ? 1 : 2) }
            selection?(.selected); ended?("Source failed")
            await waitUntil { !model.stopping }
            XCTAssertEqual(model.running, canvas)
            XCTAssertEqual(stops, canvas ? 0 : 1)
            XCTAssertEqual(model.error, "Source failed")
            if canvas { XCTAssertEqual(model.source, .canvas) }
            model.end()
        }
    }
}
