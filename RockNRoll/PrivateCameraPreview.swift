import AVFoundation
import UIKit

@MainActor
protocol PrivateCameraPreviewing: AnyObject {
    var view: UIView { get }
    var device: AVCaptureDevice? { get }
    func start() async throws
    func startFrames(_ frames: @escaping @MainActor (CVPixelBuffer, Int) -> Void) async throws
    func stop() async
}

extension PrivateCameraPreviewing {
    var device: AVCaptureDevice? { nil }
    func startFrames(_ frames: @escaping @MainActor (CVPixelBuffer, Int) -> Void) async throws {
        throw CocoaError(.featureUnsupported)
    }
}

/// Local capture only: no microphone input, encoder, publication, or PiP source.
@MainActor
final class PrivateCameraPreview: PrivateCameraPreviewing {
    private let capture = Capture()
    private let position: AVCaptureDevice.Position
    init(position: AVCaptureDevice.Position = .front) { self.position = position }
    private lazy var surface = PreviewSurface(session: capture.session)
    var view: UIView { surface }
    var device: AVCaptureDevice? {
        guard capture.session.isRunning else { return nil }
        return (capture.session.inputs.first as? AVCaptureDeviceInput)?.device
    }

    func start() async throws {
        try await start(frames: nil)
    }

    func startFrames(_ frames: @escaping @MainActor (CVPixelBuffer, Int) -> Void) async throws {
        try await start(frames: frames)
    }

    private func start(frames: (@MainActor (CVPixelBuffer, Int) -> Void)?) async throws {
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        try Task.checkCancellation()
        guard authorized else { throw PreviewError.permission }
        try await capture.start(position: position, frames: frames)
        surface.device = device
        surface.mirrored = position == .front
    }

    func stop() async { await capture.stop() }

    /// UIKit-on-Mac uses the connection's native default as its rotation origin.
    /// Device horizon angles are absolute on iOS and relative to that origin on Mac.
    nonisolated static func connectionAngle(horizon: CGFloat, nativeDefault: CGFloat, isMac: Bool) -> CGFloat {
        let angle = horizon + (isMac ? nativeDefault : 0)
        return (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    private enum PreviewError: LocalizedError {
        case permission, unavailable
        var errorDescription: String? {
            switch self {
            case .permission: return L("Allow camera access in Settings to preview your video.")
            case .unavailable: return L("Camera preview is unavailable on this device.")
            }
        }
    }

    private final class Capture: @unchecked Sendable {
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "dev.vsmirn0v.conferenceguest.private-camera")
        private var input: AVCaptureDeviceInput?
        private var output: AVCaptureVideoDataOutput?
        private var sink: FrameSink?
        private var rotationCoordinator: AnyObject?
        private var rotationObservation: NSKeyValueObservation?
        init() { session.automaticallyConfiguresApplicationAudioSession = false }

        func start(position: AVCaptureDevice.Position, frames: (@MainActor (CVPixelBuffer, Int) -> Void)?) async throws {
            try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    do {
                        if input?.device.position != position {
                            let discovery = AVCaptureDevice.DiscoverySession(
                                deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: position)
                            // Mac camera positions are bridged from UIKit. Respect
                            // the system default rather than selecting a phone camera
                            // merely because it advertises a front-facing position.
                            let preferred = ProcessInfo.processInfo.isiOSAppOnMac ? AVCaptureDevice.default(for: .video) : discovery.devices.first
                            guard let device = preferred ?? (position == .front ? AVCaptureDevice.default(for: .video) : nil)
                            else { throw PreviewError.unavailable }
                            let next = try AVCaptureDeviceInput(device: device)
                            session.beginConfiguration()
                            if let input { session.removeInput(input) }
                            guard session.canAddInput(next) else {
                                if let input, session.canAddInput(input) { session.addInput(input) }
                                session.commitConfiguration()
                                throw PreviewError.unavailable
                            }
                            session.addInput(next); input = next
                            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                            session.commitConfiguration()
                        }
                        if let frames, output == nil {
                            let video = AVCaptureVideoDataOutput()
                            video.alwaysDiscardsLateVideoFrames = true
                            video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                            let receiver = FrameSink(handler: frames)
                            session.beginConfiguration()
                            guard session.canAddOutput(video) else { session.commitConfiguration(); throw PreviewError.unavailable }
                            session.addOutput(video)
                            video.setSampleBufferDelegate(receiver, queue: queue)
                            if #available(iOS 17.0, *), let device = input?.device {
                                // Continuity cameras can be mounted differently from
                                // the Mac's built-in camera. Use capture-device rotation.
                                let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
                                rotationCoordinator = rotation
                                let nativeDefault = video.connection(with: .video)?.videoRotationAngle ?? 0
                                let isMac = ProcessInfo.processInfo.isiOSAppOnMac
                                let angle = PrivateCameraPreview.connectionAngle(horizon: rotation.videoRotationAngleForHorizonLevelCapture, nativeDefault: nativeDefault, isMac: isMac)
                                if let connection = video.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                                    connection.videoRotationAngle = angle
                                }
                                rotationObservation = rotation.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) {
                                    [weak self, weak video] rotation, _ in
                                    let angle = PrivateCameraPreview.connectionAngle(horizon: rotation.videoRotationAngleForHorizonLevelCapture, nativeDefault: nativeDefault, isMac: isMac)
                                    self?.queue.async {
                                        guard let connection = video?.connection(with: .video), connection.isVideoRotationAngleSupported(angle) else { return }
                                        connection.videoRotationAngle = angle
                                    }
                                }
                            } else if let connection = video.connection(with: .video), connection.isVideoOrientationSupported {
                                connection.videoOrientation = .portrait
                            }
                            output = video; sink = receiver
                            session.commitConfiguration()
                        }
                        if session.isMultitaskingCameraAccessSupported { session.isMultitaskingCameraAccessEnabled = true }
                        if !session.isRunning { session.startRunning() }
                        guard session.isRunning else { throw PreviewError.unavailable }
                        result.resume()
                    } catch { result.resume(throwing: error) }
                }
            }
        }

        func stop() async {
            await withCheckedContinuation { result in
                queue.async { [self] in
                    if session.isRunning { session.stopRunning() }
                    // Release the camera device before handing ownership to the meeting SDK.
                    session.beginConfiguration()
                    output?.setSampleBufferDelegate(nil, queue: nil)
                    rotationObservation = nil; rotationCoordinator = nil
                    if let output { session.removeOutput(output) }
                    output = nil; sink = nil
                    if let input { session.removeInput(input) }
                    input = nil
                    session.commitConfiguration()
                    result.resume()
                }
            }
        }
    }

    /// Conflates camera callbacks instead of enqueueing a main-thread task/frame.
    private final class FrameSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        private let handler: @MainActor (CVPixelBuffer, Int) -> Void
        private let lock = NSLock()
        private var latest: CVPixelBuffer?
        private var pending = false
        init(handler: @escaping @MainActor (CVPixelBuffer, Int) -> Void) { self.handler = handler }
        func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
            lock.lock(); latest = pixels
            if pending { lock.unlock(); return }
            pending = true; lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); let frame = self.latest; self.latest = nil; self.pending = false; self.lock.unlock()
                if let frame { self.handler(frame, 0) }
            }
        }
    }

    private final class PreviewSurface: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        private var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var device: AVCaptureDevice? { didSet { configureRotation() } }
        private var rotationCoordinator: AnyObject?
        private var rotationObservation: NSKeyValueObservation?
        private var nativeDefaultRotation: CGFloat = 0
        var mirrored = true { didSet { setNeedsLayout() } }
        init(session: AVCaptureSession) {
            super.init(frame: .zero)
            backgroundColor = .black
            preview.session = session
            preview.videoGravity = .resizeAspect
        }
        required init?(coder: NSCoder) { nil }
        private func configureRotation() {
            rotationObservation = nil; rotationCoordinator = nil
            if #available(iOS 17.0, *), let device {
                nativeDefaultRotation = preview.connection?.videoRotationAngle ?? 0
                let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
                rotationCoordinator = coordinator
                rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) {
                    [weak self] _, _ in Task { @MainActor in self?.setNeedsLayout() }
                }
            }
            setNeedsLayout()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let connection = preview.connection else { return }
            if #available(iOS 17.0, *), let coordinator = rotationCoordinator as? AVCaptureDevice.RotationCoordinator {
                let angle = PrivateCameraPreview.connectionAngle(horizon: coordinator.videoRotationAngleForHorizonLevelPreview,
                    nativeDefault: nativeDefaultRotation, isMac: ProcessInfo.processInfo.isiOSAppOnMac)
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            } else if connection.isVideoOrientationSupported {
                if ProcessInfo.processInfo.isiOSAppOnMac {
                    connection.videoOrientation = .landscapeRight
                } else {
                switch window?.windowScene?.interfaceOrientation {
                case .landscapeLeft: connection.videoOrientation = .landscapeLeft
                case .landscapeRight: connection.videoOrientation = .landscapeRight
                case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
                default: connection.videoOrientation = .portrait
                }
                }
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
        }
    }
}

@MainActor
struct StudioLivePreview {
    let view: UIView
    let stop: () -> Void
}
