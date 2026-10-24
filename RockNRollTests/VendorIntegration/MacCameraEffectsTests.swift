#if DEBUG
import AVFoundation
import CoreImage
import UIKit
import XCTest
@testable import RockNRoll

/// Opt-in, local-only A/B evidence. No meeting, publication or microphone.
@MainActor
final class MacCameraEffectsTests: XCTestCase {
    func testSystemBackgroundGeometryBeforeRTCProcessing() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_BACKGROUND"] == "1" else {
            throw XCTSkip("Opt-in local Mac system-background qualification")
        }
        guard #available(iOS 18.0, *) else { throw XCTSkip("Background replacement requires iOS 18 or later") }
        print("MAC_BACKGROUND_PERMISSION status=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw XCTSkip("An authorized Mac camera is required")
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let supported = Bundle.main.object(forInfoDictionaryKey: "UISupportedInterfaceOrientations")
        print("MAC_BACKGROUND_SUPPORTED resolved=\(String(describing: supported)) app=\(UIApplication.shared.supportedInterfaceOrientations(for: scene?.windows.first).rawValue)")
        var previousOrientation: UIInterfaceOrientationMask?
        defer {
            if let scene, let previousOrientation {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: previousOrientation))
            }
        }
        print("MAC_BACKGROUND_SCENE before=\(scene?.interfaceOrientation.rawValue ?? -1) device=\(UIDevice.current.orientation.rawValue)")
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_BACKGROUND_LANDSCAPE"] == "1", let scene {
            let previous: UIInterfaceOrientationMask
            switch scene.interfaceOrientation {
            case .portrait: previous = .portrait
            case .portraitUpsideDown: previous = .portraitUpsideDown
            case .landscapeLeft: previous = .landscapeLeft
            case .landscapeRight: previous = .landscapeRight
            default: previous = .all
            }
            previousOrientation = previous
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) {
                print("MAC_BACKGROUND_SCENE requestError=\($0)")
            }
            try await Task.sleep(for: .seconds(1))
            print("MAC_BACKGROUND_SCENE after=\(scene.interfaceOrientation.rawValue) device=\(UIDevice.current.orientation.rawValue)")
        }
        let preferred = try XCTUnwrap(CameraDevices.preferred(in: CameraDevices.available()))
        // Compatibility front/back aliases have different IDs but the same physical-device name.
        // Never wake a connected Continuity Camera while qualifying the selected Mac camera.
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video, position: .unspecified).devices.filter { $0.localizedName == preferred.localizedName }
        var activeBackgrounds = 0
        for device in devices {
            let originalFormat = device.activeFormat
            let minimum = device.activeVideoMinFrameDuration, maximum = device.activeVideoMaxFrameDuration
            defer {
                if (try? device.lockForConfiguration()) != nil {
                    device.activeFormat = originalFormat
                    device.activeVideoMinFrameDuration = minimum; device.activeVideoMaxFrameDuration = maximum
                    device.unlockForConfiguration()
                }
            }
            let formats = [false, true].compactMap { portrait in
                device.formats.first {
                    let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                    return d.width == (portrait ? 1080 : 1920) && d.height == (portrait ? 1920 : 1080)
                }
            }
            let explicitSizing = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_BACKGROUND_DIMENSIONS"] == "1"
            let candidates = explicitSizing ? formats.filter {
                let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription); return d.width < d.height
            }.map(Optional.some) : formats.map(Optional.some) + [nil]
            for format in candidates {
                for aligned in explicitSizing ? [true] : [false, true] {
                    for dimensionMode in explicitSizing ? [0, 1, 2] : [-1] {
                        let session = AVCaptureSession(), output = AVCaptureVideoDataOutput()
                        session.automaticallyConfiguresApplicationAudioSession = false
                        session.beginConfiguration(); session.sessionPreset = format == nil ? .hd1280x720 : .inputPriority
                        session.addInput(try AVCaptureDeviceInput(device: device)); session.addOutput(output)
                        if let format {
                            try device.lockForConfiguration()
                            device.activeFormat = format
                            if let fps = CameraCaptureRate.supported(24,
                                ranges: format.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate }) {
                                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(fps))
                                device.activeVideoMaxFrameDuration = device.activeVideoMinFrameDuration
                            }
                            device.unlockForConfiguration()
                        }
                        output.alwaysDiscardsLateVideoFrames = true
                        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                        let preview = AVCaptureVideoPreviewLayer(session: session)
                        let connection = try XCTUnwrap(output.connection(with: .video))
                        if aligned, let reference = preview.connection, connection.isVideoOrientationSupported {
                            connection.videoOrientation = reference.videoOrientation
                        }
                        if dimensionMode >= 0 {
                            output.automaticallyConfiguresOutputBufferDimensions = false
                            output.deliversPreviewSizedOutputBuffers = false
                            if dimensionMode > 0 {
                                let raw = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                                let size = dimensionMode == 1 ? raw : MacCameraCapturePlan.bounded(raw)
                                let quarter = Int(connection.videoRotationAngle.rounded()) % 180 != 0
                                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                    kCVPixelBufferWidthKey as String: quarter ? size.height : size.width,
                                    kCVPixelBufferHeightKey as String: quarter ? size.width : size.height]
                            }
                        }
                        session.commitConfiguration()
                        let sink = CameraEffectSamples()
                        output.setSampleBufferDelegate(sink, queue: DispatchQueue(label: "background-effect-probe"))
                        await Task.detached { session.startRunning() }.value
                        do {
                            for _ in 0..<40 {
                                if sink.frameCount >= 12 { break }
                                try await Task.sleep(for: .milliseconds(100))
                            }
                            sink.beginEvidence()
                            try await Task.sleep(for: .seconds(1.2))
                        }
                        catch {
                            await Task.detached { session.stopRunning() }.value
                            output.setSampleBufferDelegate(nil, queue: nil); preview.session = nil
                            throw error
                        }
                        let activeFormat = device.activeFormat
                        let dimensions = CMVideoFormatDescriptionGetDimensions(activeFormat.formatDescription)
                        let active = device.isBackgroundReplacementActive
                        if active { activeBackgrounds += 1 }
                        let label = "position=\(device.position.rawValue) preset=\(format == nil ? "managed" : "manual") format=\(dimensions.width)x\(dimensions.height) aligned=\(aligned) sizing=\(dimensionMode)"
                        print("MAC_BACKGROUND_GEOMETRY camera=\(device.localizedName) \(label) selected=\(AVCaptureDevice.isBackgroundReplacementEnabled) active=\(active) angle=\(connection.videoRotationAngle) frames=\(sink.frameCount) backgroundFPS=\(String(describing: activeFormat.videoFrameRateRangeForBackgroundReplacement))")
                        print("MAC_BACKGROUND_OUTPUT settings=\(String(describing: output.videoSettings)) pixels=\(sink.snapshots().first?.cgImage?.width ?? 0)x\(sink.snapshots().first?.cgImage?.height ?? 0)")
                        for (index, image) in sink.snapshots().enumerated() {
                            let attachment = XCTAttachment(image: image)
                            attachment.name = "Mac system background \(label) \(index)"; attachment.lifetime = .keepAlways; add(attachment)
                        }
                        await Task.detached { session.stopRunning() }.value
                        output.setSampleBufferDelegate(nil, queue: nil); preview.session = nil
                        XCTAssertGreaterThan(sink.frameCount, 0)
                    }
                }
            }
        }
        if activeBackgrounds == 0 { throw XCTSkip("No active macOS background replacement; captured images do not qualify effect orientation") }
    }

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
