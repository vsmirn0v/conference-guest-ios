import AVFoundation
import UIKit

@MainActor
protocol PrivateCameraPreviewing: AnyObject {
    var view: UIView { get }
    var device: AVCaptureDevice? { get }
    func selectDevice(_ device: AVCaptureDevice?)
    func start() async throws
    func startFrames(_ frames: @escaping @MainActor (CVPixelBuffer, Int) -> Void) async throws
    func stop() async
}

extension PrivateCameraPreviewing {
    var device: AVCaptureDevice? { nil }
    func selectDevice(_ device: AVCaptureDevice?) {}
    func startFrames(_ frames: @escaping @MainActor (CVPixelBuffer, Int) -> Void) async throws {
        throw CocoaError(.featureUnsupported)
    }
}

/// Actual devices, not front/back positions: several Mac cameras share a position.
enum CameraDevices {
    static func available() -> [AVCaptureDevice] {
        // UIKit-on-Mac also exposes rear-facing compatibility aliases for the
        // same cameras. Discover its front-facing devices once; real external
        // cameras use their own device types without a position restriction.
        let position: AVCaptureDevice.Position = ProcessInfo.processInfo.isiOSAppOnMac ? .front : .unspecified
        var discovered = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video, position: position).devices
        if #available(iOS 17.0, *) {
            discovered += AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .continuityCamera],
                mediaType: .video, position: .unspecified).devices
        }
        var seen = Set<String>()
        return discovered.filter { $0.isConnected && !$0.isSuspended && seen.insert($0.uniqueID).inserted }
    }
    static func preferred(in devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        if ProcessInfo.processInfo.isiOSAppOnMac, let system = AVCaptureDevice.default(for: .video),
           let selected = devices.first(where: { $0.uniqueID == system.uniqueID }) { return selected }
        return devices.first { $0.position == .front } ?? devices.first
    }
    static func nextID(in devices: [String], current: String?) -> String? {
        let unique = devices.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard unique.count > 1 else { return nil }
        guard let current, let index = unique.firstIndex(of: current) else { return unique.first }
        return unique[(index + 1) % unique.count]
    }
}

/// Local capture only: no microphone input, encoder, publication, or PiP source.
@MainActor
final class PrivateCameraPreview: PrivateCameraPreviewing {
    private let capture = Capture()
    private let position: AVCaptureDevice.Position
    private var selectedDevice: AVCaptureDevice?
    private let framesPerSecond: Double?
    init(position: AVCaptureDevice.Position = .front, framesPerSecond: Double? = nil) {
        self.position = position; self.framesPerSecond = framesPerSecond
    }
    private lazy var surface = PreviewSurface(session: capture.session)
    var view: UIView { surface }
    var device: AVCaptureDevice? {
        guard capture.session.isRunning else { return nil }
        return (capture.session.inputs.first as? AVCaptureDeviceInput)?.device
    }

    func selectDevice(_ device: AVCaptureDevice?) { selectedDevice = device }

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
        try await capture.start(position: position, selectedDevice: selectedDevice, frames: frames, framesPerSecond: framesPerSecond)
        surface.device = device
        surface.mirrored = device?.position == .front
        surface.layoutIfNeeded()
    }

    func stop() async { await capture.stop() }

    /// RotationCoordinator reports an absolute angle from the native sensor.
    /// A connection's existing orientation must not be added a second time.
    nonisolated static func connectionAngle(horizon: CGFloat) -> CGFloat {
        return (horizon.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
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
        private var originalDurations: (format: AVCaptureDevice.Format, minimum: CMTime, maximum: CMTime)?
        init() { session.automaticallyConfiguresApplicationAudioSession = false }

        func start(position: AVCaptureDevice.Position, selectedDevice: AVCaptureDevice?, frames: (@MainActor (CVPixelBuffer, Int) -> Void)?, framesPerSecond: Double?) async throws {
            try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    do {
                        let devices = CameraDevices.available()
                        let preferred = selectedDevice.flatMap { selected in devices.first { $0.uniqueID == selected.uniqueID } }
                            ?? (ProcessInfo.processInfo.isiOSAppOnMac ? CameraDevices.preferred(in: devices) : devices.first { $0.position == position })
                        guard let device = preferred else { throw PreviewError.unavailable }
                        if input?.device.uniqueID != device.uniqueID {
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
                                let angle = PrivateCameraPreview.connectionAngle(horizon: rotation.videoRotationAngleForHorizonLevelCapture)
                                if let connection = video.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                                    connection.videoRotationAngle = angle
                                }
                                rotationObservation = rotation.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) {
                                    [weak self, weak video] rotation, _ in
                                    let angle = PrivateCameraPreview.connectionAngle(horizon: rotation.videoRotationAngleForHorizonLevelCapture)
                                    self?.queue.async {
                                        guard let connection = video?.connection(with: .video), connection.isVideoRotationAngleSupported(angle) else { return }
                                        connection.videoRotationAngle = angle
                                    }
                                }
                            } else if let connection = video.connection(with: .video), connection.isVideoOrientationSupported {
                                connection.videoOrientation = ProcessInfo.processInfo.isiOSAppOnMac ? .landscapeRight : .portrait
                            }
                            output = video; sink = receiver
                            session.commitConfiguration()
                        }
                        // Only Presenter-owned capture requests a fixed cadence. Keep
                        // the selected format/system effects and clamp to its range.
                        if frames != nil, let requested = framesPerSecond, requested.isFinite, requested > 0,
                           let device = input?.device,
                           let range = device.activeFormat.videoSupportedFrameRateRanges.min(by: {
                               abs(min($0.maxFrameRate, max($0.minFrameRate, requested)) - requested) <
                               abs(min($1.maxFrameRate, max($1.minFrameRate, requested)) - requested)
                           }) {
                            let rate = min(range.maxFrameRate, max(range.minFrameRate, requested))
                            try device.lockForConfiguration()
                            if originalDurations == nil {
                                originalDurations = (device.activeFormat, device.activeVideoMinFrameDuration, device.activeVideoMaxFrameDuration)
                            }
                            let duration = CMTimeMaximum(range.minFrameDuration, CMTimeMinimum(range.maxFrameDuration,
                                CMTime(seconds: 1 / rate, preferredTimescale: 1_000_000_000)))
                            device.activeVideoMinFrameDuration = duration
                            device.activeVideoMaxFrameDuration = duration
                            device.unlockForConfiguration()
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
                    // Restore our cadence before the SDK can reclaim the device.
                    if let device = input?.device, let original = originalDurations,
                       device.activeFormat === original.format {
                        do {
                            try device.lockForConfiguration()
                            device.activeVideoMinFrameDuration = original.minimum
                            device.activeVideoMaxFrameDuration = original.maximum
                            device.unlockForConfiguration()
                        } catch { /* Capture is stopped; cleanup must still release ownership. */ }
                    }
                    originalDurations = nil
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
                let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
                rotationCoordinator = coordinator
                rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) {
                    [weak self] _, _ in Task { @MainActor in self?.setNeedsLayout() }
                }
            }
            setNeedsLayout()
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            // The preview coordinator reports zero while its layer is detached.
            // Rebind after Studio inserts the asynchronous capture view.
            configureRotation()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let connection = preview.connection else { return }
            if #available(iOS 17.0, *), let coordinator = rotationCoordinator as? AVCaptureDevice.RotationCoordinator {
                let angle = PrivateCameraPreview.connectionAngle(horizon: coordinator.videoRotationAngleForHorizonLevelPreview)
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
