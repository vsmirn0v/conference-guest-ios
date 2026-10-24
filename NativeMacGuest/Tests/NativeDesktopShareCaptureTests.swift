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
        print("PASS: \(checks) share-capture cancellation, teardown, aspect-ratio and camera-rotation assertions; no system picker or physical capture")
    }
}
