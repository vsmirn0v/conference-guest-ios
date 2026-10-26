import AppKit
import CoreVideo
import Foundation
import LiveKitWebRTC

// The fixture does not link the desktop workspace or initiate a real meeting.
enum NativeDesktopError: Error { case unavailable(String) }
private final class Count: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func add() { lock.lock(); value += 1; lock.unlock() }
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
}
private final class RetainedCameraPixels: @unchecked Sendable {
    private let lock = NSLock()
    private var pixels: CVPixelBuffer?
    private var revision: UInt64 = 0
    func set(_ pixels: CVPixelBuffer?) {
        lock.lock(); defer { lock.unlock() }
        self.pixels = pixels; revision &+= 1
    }
    var snapshot: (pixels: CVPixelBuffer?, revision: UInt64) {
        lock.lock(); defer { lock.unlock() }; return (pixels, revision)
    }
}
private func pixelBytes(_ sample: CMSampleBuffer?) throws -> [UInt8] {
    guard let sample, let pixels = CMSampleBufferGetImageBuffer(sample) else {
        throw NSError(domain: "MissingCutoutPixels", code: 1)
    }
    CVPixelBufferLockBaseAddress(pixels, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    return (0..<CVPixelBufferGetHeight(pixels)).flatMap { y in
        Array(UnsafeBufferPointer(start: base + y * CVPixelBufferGetBytesPerRow(pixels), count: CVPixelBufferGetWidth(pixels) * 4))
    }
}
private func wait(_ semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { done in DispatchQueue.global().async { semaphore.wait(); done.resume() } }
}
private func redSample(_ frame: LKRTCVideoFrame) -> Int {
    guard let native = frame.buffer as? LKRTCCVPixelBuffer else { return -1 }
    let pixels = native.pixelBuffer
    CVPixelBufferLockBaseAddress(pixels, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixels) else { return -1 }
    let offset = CVPixelBufferGetHeight(pixels) / 2 * CVPixelBufferGetBytesPerRow(pixels) + CVPixelBufferGetWidth(pixels) / 4 * 4 + 2
    return Int(base.assumingMemoryBound(to: UInt8.self)[offset])
}
@main struct NativeDesktopShareCaptureTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw NSError(domain: "ShareCaptureTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        let portrait = NativeDesktopShareCapture.compositionSize(.init(width: 1000, height: 2000))
        try expect(portrait == CGSize(width: 540, height: 1080), "Portrait composition preserves aspect ratio")
        try expect(NativeDesktopShareCapture.compositionSize(.init(width: 4000, height: 1000)) == CGSize(width: 1920, height: 480), "Wide composition preserves aspect ratio")
        try expect(NativeDesktopShareCapture.compositionSize(.init(width: 800, height: 600)) == CGSize(width: 800, height: 600), "Small sources are not upscaled")

        let pickerEntered = DispatchSemaphore(value: 0), pickerRelease = DispatchSemaphore(value: 0)
        let cancelled = NativeDesktopShareCapture(canvasForTesting: false) { _ in }
        cancelled.beforePickerForTesting = {
            pickerEntered.signal()
            await wait(pickerRelease)
        }
        let starting = Task { try await cancelled.start() }
        await wait(pickerEntered)
        starting.cancel(); pickerRelease.signal()
        do { _ = try await starting.value; throw NSError(domain: "CancelledPickerStarted", code: 1) }
        catch is CancellationError { checks += 1 }
        try await cancelled.stop()
        try expect(cancelled.snapshot().frames == 0 && cancelled.stopPassesForTesting == 1, "Cancelled setup never opens capture and coalesces teardown")

        let frameEntered = DispatchSemaphore(value: 0), frameRelease = DispatchSemaphore(value: 0), lateCount = Count()
        let blocked = NativeDesktopShareCapture(canvasForTesting: true) { _ in lateCount.add() }
        blocked.beforeDeliveryForTesting = { frameEntered.signal(); frameRelease.wait() }
        let pending = Task { try await blocked.start() }
        await wait(frameEntered)
        blocked.cancel(); frameRelease.signal()
        do { _ = try await pending.value; throw NSError(domain: "CancelledFrameDelivered", code: 1) }
        catch is CancellationError { checks += 1 }
        try await blocked.stop()
        try expect(lateCount.current == 0 && blocked.snapshot().frames == 0, "Cancellation during composition fences final RTC delivery")

        let liveCount = Count(), capture = NativeDesktopShareCapture(canvasForTesting: true) { _ in liveCount.add() }
        let started = try await capture.start()
        try expect(started.width == 1920 && started.height == 1080 && liveCount.current > 0, "Canvas startup completes only after actual frame delivery")
        async let one: Void = capture.stop()
        async let two: Void = capture.stop()
        _ = try await (one, two)
        let atStop = liveCount.current
        capture.setCamera(nil); capture.setScene(PresenterScene())
        try await Task.sleep(for: .milliseconds(250))
        try expect(liveCount.current == atStop && capture.stopPassesForTesting == 1, "Concurrent Stop drains once and later producer edits cannot revive capture")
        do { _ = try await capture.start(); throw NSError(domain: "CaptureReused", code: 1) }
        catch GuestCameraError.alreadyStarted { checks += 1 }

        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 8, 4, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess, let pixels else { fatalError("fixture allocation") }
        CVPixelBufferLockBaseAddress(pixels, [])
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<4 { for x in 0..<8 {
            let offset = y * stride + x * 4
            bytes[offset] = x < 4 ? 0 : 255; bytes[offset + 1] = 0; bytes[offset + 2] = x < 4 ? 255 : 0; bytes[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let tap = NativeDesktopCameraTap()
        let rotated: CVPixelBuffer = try await guestAwait(timeout: 5) { done in
            tap.onFrame = { output in
                if let output { done(.success(output)) }
                else { done(.failure(NativeDesktopRTCError.invalidResponse)) }
            }
            tap.renderFrame(LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._90, timeStampNs: 1))
        }
        tap.stop()
        try expect(CVPixelBufferGetWidth(rotated) == 4 && CVPixelBufferGetHeight(rotated) == 8, "Presenter camera normalizes RTC 90-degree rotation")
        let stableTap = NativeDesktopCameraTap(), deliveredCamera = Count()
        stableTap.onFrame = { output in if output != nil { deliveredCamera.add() } else { fatalError("A dropped frame cleared the camera") } }
        stableTap.renderFrame(LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: 1))
        for _ in 0..<100 where deliveredCamera.current == 0 { try await Task.sleep(for: .milliseconds(5)) }
        stableTap.renderFrame(nil)
        try await Task.sleep(for: .milliseconds(50))
        try expect(deliveredCamera.current == 1, "A missing camera frame preserves the last valid overlay without a clear callback")
        stableTap.stop()
        stableTap.renderFrame(LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: 2))
        try await Task.sleep(for: .milliseconds(50))
        try expect(deliveredCamera.current == 1, "A retired tap never delivers retained camera pixels")

        // Exercise the actual tap and compositor together. A split mask exposes
        // the synthetic person on the left while concealing the blue room.
        var maskBuffer: CVPixelBuffer?, nextCameraBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 8, 4, kCVPixelFormatType_OneComponent8, nil, &maskBuffer) == kCVReturnSuccess,
              let maskBuffer,
              CVPixelBufferCreate(nil, 8, 4, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &nextCameraBuffer) == kCVReturnSuccess,
              let nextCameraBuffer else { fatalError("cutout fixture allocation") }
        CVPixelBufferLockBaseAddress(maskBuffer, [])
        CVPixelBufferLockBaseAddress(nextCameraBuffer, [])
        let maskBytes = CVPixelBufferGetBaseAddress(maskBuffer)!.assumingMemoryBound(to: UInt8.self)
        let nextBytes = CVPixelBufferGetBaseAddress(nextCameraBuffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<4 { for x in 0..<8 {
            maskBytes[y * CVPixelBufferGetBytesPerRow(maskBuffer) + x] = x < 4 ? 255 : 0
            let offset = y * CVPixelBufferGetBytesPerRow(nextCameraBuffer) + x * 4
            nextBytes[offset] = x < 4 ? 0 : 255; nextBytes[offset + 1] = x < 4 ? 255 : 0
            nextBytes[offset + 2] = 0; nextBytes[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(nextCameraBuffer, [])
        CVPixelBufferUnlockBaseAddress(maskBuffer, [])
        let retainedCamera = RetainedCameraPixels(), cutoutTap = NativeDesktopCameraTap()
        cutoutTap.onFrame = { retainedCamera.set($0) }
        let cutoutCompositor = PresenterCompositor(size: CGSize(width: 80, height: 40), personMask: { _, _ in maskBuffer })
        var cutoutScene = PresenterScene(); cutoutScene.layout = .cutout
        cutoutScene.placement = PresenterPlacement(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        func renderedCutout() throws -> [UInt8] {
            let camera = retainedCamera.snapshot
            return try pixelBytes(cutoutCompositor.render(scene: cutoutScene, camera: camera.pixels,
                cameraRevision: camera.revision, time: .zero))
        }
        let cutoutBlank = try renderedCutout(), personPixel = (20 * 80 + 20) * 4, roomPixel = (20 * 80 + 60) * 4
        cutoutTap.renderFrame(LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: 3))
        for _ in 0..<100 where retainedCamera.snapshot.revision < 1 { try await Task.sleep(for: .milliseconds(5)) }
        let firstCutout = try renderedCutout()
        try expect(firstCutout[personPixel + 2] > 200 && firstCutout[roomPixel..<roomPixel + 4] == cutoutBlank[roomPixel..<roomPixel + 4],
                   "Cutout shows the synthetic person while masking the contrasting room pixels")
        cutoutTap.renderFrame(nil)
        try await Task.sleep(for: .milliseconds(50))
        let retainedCutout = try renderedCutout()
        try expect(retainedCutout == firstCutout && cutoutCompositor.segmentationCount == 1,
                   "A missing RTC frame preserves the complete masked cutout without flicker or new segmentation")
        cutoutTap.renderFrame(LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: nextCameraBuffer), rotation: ._0, timeStampNs: 4))
        for _ in 0..<100 where retainedCamera.snapshot.revision < 2 { try await Task.sleep(for: .milliseconds(5)) }
        let nextCutout = try renderedCutout()
        try expect(nextCutout != firstCutout && nextCutout[personPixel + 1] > 200 &&
                   nextCutout[roomPixel..<roomPixel + 4] == cutoutBlank[roomPixel..<roomPixel + 4] && cutoutCompositor.segmentationCount == 2,
                   "The next camera frame changes visible cutout pixels while the room stays masked")
        cutoutTap.stop(); retainedCamera.set(nil)
        let clearedCutout = try renderedCutout(), clearedRevision = retainedCamera.snapshot.revision
        try expect(clearedCutout == cutoutBlank, "Explicit camera removal clears every retained cutout pixel")
        cutoutTap.renderFrame(LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: 5))
        try await Task.sleep(for: .milliseconds(50))
        let retiredCutout = try renderedCutout()
        try expect(retainedCamera.snapshot.revision == clearedRevision && retiredCutout == cutoutBlank,
                   "A retired tap cannot restore camera pixels after explicit removal")
        CVPixelBufferLockBaseAddress(rotated, .readOnly)
        let rotatedBytes = CVPixelBufferGetBaseAddress(rotated)!.assumingMemoryBound(to: UInt8.self)
        let rotatedStride = CVPixelBufferGetBytesPerRow(rotated)
        let first = Int(rotatedBytes[2 * 4 + 2]), last = Int(rotatedBytes[7 * rotatedStride + 2 * 4 + 2])
        CVPixelBufferUnlockBaseAddress(rotated, .readOnly)
        try expect(abs(first - last) > 200, "Asymmetric camera content rotates into top/bottom regions")
        var scene = PresenterScene(); scene.layout = .card
        scene.placement = PresenterPlacement(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let baselineRed = GuestCompletion<Int>()
        let baseline = NativeDesktopShareCapture(canvasForTesting: true) { frame in baselineRed.finish(.success(redSample(frame))) }
        baseline.setScene(scene); baseline.setCamera(pixels); _ = try await baseline.start()
        let presentRed: Int = try await withCheckedThrowingContinuation { baselineRed.install($0, timeout: 5) }
        try expect(presentRed > 200, "Camera-removal fixture visibly contains camera pixels before removal")
        try await baseline.stop()

        let composed = DispatchSemaphore(value: 0), releaseComposed = DispatchSemaphore(value: 0), firstPass = Count()
        let removedRed = GuestCompletion<Int>()
        let removing = NativeDesktopShareCapture(canvasForTesting: true) { frame in removedRed.finish(.success(redSample(frame))) }
        removing.setScene(scene); removing.setCamera(pixels)
        removing.beforeDeliveryForTesting = {
            if firstPass.current == 0 { firstPass.add(); composed.signal(); releaseComposed.wait() }
        }
        let composing = Task { try await removing.start() }
        await wait(composed)
        removing.setCamera(nil); releaseComposed.signal()
        _ = try await composing.value
        let absentRed: Int = try await withCheckedThrowingContinuation { removedRed.install($0, timeout: 5) }
        try expect(absentRed >= 0 && absentRed < 100, "Camera-off fences an already composed camera frame before final delivery")
        try await removing.stop()
        var highResolutionPixels: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &highResolutionPixels) == kCVReturnSuccess,
              let highResolutionPixels,
              let highResolutionSample = PresenterCompositor.sample(highResolutionPixels, time: .zero) else { fatalError("4K fixture allocation") }
        let originalPixels = GuestCompletion<Bool>(), composedDimensions = GuestCompletion<CGSize>(), restoredDimensions = GuestCompletion<CGSize>(), transition = Count()
        let nativeScreen = NativeDesktopShareCapture(screenForTesting: highResolutionSample) { frame in
            if frame.width == 3840 {
                originalPixels.finish(.success((frame.buffer as? LKRTCCVPixelBuffer)?.pixelBuffer === highResolutionPixels))
                if transition.current >= 2 { restoredDimensions.finish(.success(CGSize(width: Int(frame.width), height: Int(frame.height)))) }
            } else if transition.current >= 1 { composedDimensions.finish(.success(CGSize(width: Int(frame.width), height: Int(frame.height)))) }
        }
        nativeScreen.setScene(scene)
        let nativeInfo = try await nativeScreen.start()
        let retainedOriginal: Bool = try await withCheckedThrowingContinuation { originalPixels.install($0, timeout: 5) }
        try expect(nativeInfo.width == 3840 && nativeInfo.height == 2160 && retainedOriginal,
                   "Plain screen keeps original 4K pixels without composition or a buffer copy")
        transition.add(); nativeScreen.setCamera(pixels)
        let composedGeometry: CGSize = try await withCheckedThrowingContinuation { composedDimensions.install($0, timeout: 5) }
        try expect(composedGeometry == CGSize(width: 1920, height: 1080), "Including camera follows the existing bounded composition profile")
        transition.add(); nativeScreen.setCamera(nil)
        let restoredGeometry: CGSize = try await withCheckedThrowingContinuation { restoredDimensions.install($0, timeout: 5) }
        try expect(restoredGeometry == CGSize(width: 3840, height: 2160), "Removing camera restores native screen detail and publishes the new geometry")
        try await nativeScreen.stop()
        print("PASS: \(checks) share-capture cancellation, teardown, aspect-ratio and camera-rotation assertions; no system picker or physical capture")
    }
}
