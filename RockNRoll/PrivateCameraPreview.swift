import AVFoundation
import UIKit

@MainActor
protocol PrivateCameraPreviewing: AnyObject {
    var view: UIView { get }
    func start() async throws
    func stop() async
}

/// Local capture only: no microphone input, encoder, publication, or PiP source.
@MainActor
final class PrivateCameraPreview: PrivateCameraPreviewing {
    private let capture = Capture()
    private lazy var surface = PreviewSurface(session: capture.session)
    var view: UIView { surface }

    func start() async throws {
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        try Task.checkCancellation()
        guard authorized else { throw PreviewError.permission }
        try await capture.start(position: .front)
        surface.mirrored = true
    }

    func stop() async { await capture.stop() }

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
        init() { session.automaticallyConfiguresApplicationAudioSession = false }

        func start(position: AVCaptureDevice.Position) async throws {
            try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    do {
                        if input?.device.position != position {
                            let discovery = AVCaptureDevice.DiscoverySession(
                                deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: position)
                            // Macs may expose an unspecified-position camera.
                            guard let device = discovery.devices.first ?? (position == .front ? AVCaptureDevice.default(for: .video) : nil)
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
                    if let input { session.removeInput(input) }
                    input = nil
                    session.commitConfiguration()
                    result.resume()
                }
            }
        }
    }

    private final class PreviewSurface: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        private var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var mirrored = true { didSet { setNeedsLayout() } }
        init(session: AVCaptureSession) {
            super.init(frame: .zero)
            backgroundColor = .black
            preview.session = session
            preview.videoGravity = .resizeAspect
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let connection = preview.connection else { return }
            if connection.isVideoOrientationSupported {
                switch window?.windowScene?.interfaceOrientation {
                case .landscapeLeft: connection.videoOrientation = .landscapeLeft
                case .landscapeRight: connection.videoOrientation = .landscapeRight
                case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
                default: connection.videoOrientation = .portrait
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
