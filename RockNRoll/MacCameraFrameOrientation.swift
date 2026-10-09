import AVFoundation
import Foundation

/// WebRTC's phone orientation metadata is not the Mac sensor orientation.
/// Derive the remaining rotation from the active capture connection instead.
final class MacCameraFrameOrientation {
    private let lock = NSLock()
    private weak var device: AVCaptureDevice?
    private var coordinator: AnyObject?

    struct OutputGeometry {
        var physicalAngle: Double
        var isActive: Bool
        var isEnabled: Bool
    }

    func rotation(in session: AVCaptureSession) -> Int? {
        guard ProcessInfo.processInfo.isiOSAppOnMac, #available(iOS 17.0, *),
              let actual = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) })?.device else { return nil }
        lock.lock(); defer { lock.unlock() }
        if device !== actual {
            device = actual
            coordinator = AVCaptureDevice.RotationCoordinator(device: actual, previewLayer: nil)
        }
        guard let coordinator = coordinator as? AVCaptureDevice.RotationCoordinator else { return nil }
        let outputs = session.outputs.map { output -> OutputGeometry? in
            guard output is AVCaptureVideoDataOutput, let connection = output.connection(with: .video) else { return nil }
            return OutputGeometry(physicalAngle: connection.videoRotationAngle,
                                  isActive: connection.isActive, isEnabled: connection.isEnabled)
        }
        return Self.rotation(upright: coordinator.videoRotationAngleForHorizonLevelCapture, outputs: outputs)
    }

    static func rotation(upright: Double, outputs: [OutputGeometry?]) -> Int? {
        // A restarted Mac capture session can retain disconnected outputs.
        // Prefer the live connection; startup frames can precede isActive.
        let connected = outputs.compactMap { $0 }.filter { $0.physicalAngle.isFinite }
        guard let selected = connected.first(where: { $0.isActive && $0.isEnabled })
                ?? connected.first(where: { $0.isEnabled }) ?? connected.first else { return nil }
        return relativeAngle(upright: upright, physical: selected.physicalAngle)
    }

    static func relativeAngle(upright: Double, physical: Double) -> Int? {
        guard upright.isFinite, physical.isFinite else { return nil }
        let angle = (upright - physical).truncatingRemainder(dividingBy: 360)
        let normalized = (angle + 360).truncatingRemainder(dividingBy: 360)
        let quarter = (normalized / 90).rounded() * 90
        guard abs(normalized - quarter) < 0.5 else { return nil }
        return Int(quarter) % 360
    }
}
