#if DEBUG
import AVFoundation
import CoreImage
import UIKit
import XCTest
@testable import RockNRoll

/// Opt-in, local-only A/B evidence. No meeting, publication or microphone.
@MainActor
final class MacCameraEffectsTests: XCTestCase {
    func testSystemEffectGeometryBeforeRTCProcessing() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_EFFECTS"] == "1" else {
            throw XCTSkip("Opt-in Mac physical-camera effect qualification")
        }
        print("MAC_EFFECT_PERMISSION status=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue) devices=\(CameraDevices.available().count)")
        guard #available(iOS 17.0, *), AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let device = CameraDevices.available().first(where: { $0.deviceType == .builtInWideAngleCamera }),
              let plan = MacCameraCapturePlan.resolve(device: device,
                formats: device.formats, fps: 24) else {
            throw XCTSkip("An authorized Mac camera is required")
        }
        let format = device.activeFormat
        print("MAC_EFFECT_DEVICE type=\(device.deviceType.rawValue) position=\(device.position.rawValue) name=\(device.localizedName)")
        let minimum = device.activeVideoMinFrameDuration, maximum = device.activeVideoMaxFrameDuration
        defer {
            if (try? device.lockForConfiguration()) != nil {
                device.activeFormat = format
                device.activeVideoMinFrameDuration = minimum; device.activeVideoMaxFrameDuration = maximum
                device.unlockForConfiguration()
            }
        }
        var inconclusive: [String] = []
        for method in ["orientation", "angle"] {
            let candidate = plan.format
            let session = AVCaptureSession()
            session.automaticallyConfiguresApplicationAudioSession = false
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            session.beginConfiguration()
            session.sessionPreset = .inputPriority
            session.addInput(input); session.addOutput(output)
            try device.lockForConfiguration()
            device.activeFormat = candidate
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(plan.captureFPS))
            device.activeVideoMaxFrameDuration = device.activeVideoMinFrameDuration
            device.unlockForConfiguration()
            let preview = AVCaptureVideoPreviewLayer(session: session)
            let connection = try XCTUnwrap(output.connection(with: .video))
            let originalAngle = connection.videoRotationAngle
            let referenceAngle = try XCTUnwrap(preview.connection).videoRotationAngle
            if method == "orientation" {
                connection.videoOrientation = try XCTUnwrap(preview.connection).videoOrientation
            } else if connection.isVideoRotationAngleSupported(referenceAngle) {
                connection.videoRotationAngle = referenceAngle
            }
            session.commitConfiguration()
            let sink = CameraEffectSamples()
            output.setSampleBufferDelegate(sink, queue: DispatchQueue(label: "camera-effect-probe"))
            await Task.detached { session.startRunning() }.value
            do {
                for _ in 0..<80 {
                    if sink.frameCount >= 12 && device.reactionEffectsInProgress.isEmpty { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard sink.frameCount >= 12, device.reactionEffectsInProgress.isEmpty else {
                    throw XCTSkip("Capture did not settle before reaction qualification")
                }
                guard device.canPerformReactionEffects, device.availableReactionTypes.contains(.thumbsUp) else {
                    throw XCTSkip("The chosen format does not currently support system reactions")
                }
                let observation = device.observe(\.reactionEffectsInProgress, options: [.old, .new]) { _, change in
                    print("MAC_EFFECT_STATE method=\(method) old=\(change.oldValue?.count ?? 0) new=\(change.newValue?.count ?? 0)")
                }
                device.performEffect(for: .thumbsUp)
                for _ in 0..<30 {
                    if !device.reactionEffectsInProgress.isEmpty { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard !device.reactionEffectsInProgress.isEmpty else {
                    observation.invalidate()
                    throw XCTSkip("macOS did not start a new reaction interval")
                }
                sink.beginEvidence()
                try await Task.sleep(for: .seconds(4))
                observation.invalidate()
                let samples = sink.snapshots()
                XCTAssertFalse(samples.isEmpty)
                let dimensions = CMVideoFormatDescriptionGetDimensions(candidate.formatDescription)
                print("MAC_EFFECT_GEOMETRY method=\(method) format=\(dimensions.width)x\(dimensions.height) fov=\(candidate.videoFieldOfView) initial=\(originalAngle) reference=\(referenceAngle) output=\(connection.videoRotationAngle) orientation=\(connection.videoOrientation.rawValue) frames=\(sink.frameCount) samples=\(samples.count)")
                for (index, image) in samples.enumerated() {
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Mac reaction \(dimensions.width)x\(dimensions.height) \(method) \(index)"
                    attachment.lifetime = .keepAlways; add(attachment)
                }
            } catch {
                await Task.detached { session.stopRunning() }.value
                output.setSampleBufferDelegate(nil, queue: nil); preview.session = nil
                if error is XCTSkip { inconclusive.append(method); continue }
                throw error
            }
            await Task.detached { session.stopRunning() }.value
            output.setSampleBufferDelegate(nil, queue: nil); preview.session = nil
        }
        if !inconclusive.isEmpty { throw XCTSkip("No reaction evidence for: \(inconclusive.joined(separator: ", "))") }
    }
}

private final class CameraEffectSamples: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let context = CIContext()
    private var began: Double?
    private var images: [UIImage] = []
    private var count = 0
    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func beginEvidence() { lock.lock(); began = ProcessInfo.processInfo.systemUptime; lock.unlock() }
    func snapshots() -> [UIImage] { lock.lock(); defer { lock.unlock() }; return images }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        count += 1
        let wanted = began.map { ProcessInfo.processInfo.systemUptime - $0 >= Double(images.count) + 0.5 && images.count < 4 } ?? false
        lock.unlock()
        guard wanted, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        let input = CIImage(cvPixelBuffer: pixels)
        guard let image = context.createCGImage(input, from: input.extent) else { return }
        lock.lock(); images.append(UIImage(cgImage: image)); lock.unlock()
    }
}
#endif
