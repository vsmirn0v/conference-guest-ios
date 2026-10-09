import AVFoundation
import Foundation
import WebRTC

/// UIKit window orientation is not camera sensor orientation on a Mac.
/// Correct Mac sensor rotation; preserve phone orientation with native NV12
/// rotation before the SDK's software path can discard color information.
final class GuestCameraFrameDelegate: NSObject, RTCVideoCapturerDelegate {
    private weak var downstream: (any RTCVideoCapturerDelegate)?
    private weak var camera: RTCCameraVideoCapturer?
    private let coordinator: AnyObject?
    private let lock = NSLock()
    private var active = true
    struct Progress { let generation: UUID; let frames: Int64 }
    private let generation = UUID()
    private var frames: Int64 = 0
    private let orientation = GuestCameraOrientation()
    var originalDelegate: (any RTCVideoCapturerDelegate)? {
        (downstream as? GuestCameraFrameDelegate)?.originalDelegate ?? downstream
    }
    func progress(trackID: String) -> Progress? {
        guard let source = originalDelegate as? RTCVideoSource,
              GuestCameraTrackBinding.source(source, owns: trackID) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return active && camera != nil ? Progress(generation: generation, frames: frames) : nil
    }
    init(camera: RTCCameraVideoCapturer, device: AVCaptureDevice?,
         downstream: any RTCVideoCapturerDelegate) {
        self.camera = camera; self.downstream = downstream
        if #available(iOS 17, *), ProcessInfo.processInfo.isiOSAppOnMac, let device {
            coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        } else { coordinator = nil }
        super.init()
    }
    static func rotation(upright: Double, physical: Double) -> RTCVideoRotation? {
        let angle = (upright - physical).truncatingRemainder(dividingBy: 360)
        let normalized = (angle + 360).truncatingRemainder(dividingBy: 360)
        let quarter = (normalized / 90).rounded() * 90
        guard abs(normalized - quarter) < 0.5 else { return nil }
        return RTCVideoRotation(rawValue: Int(quarter) % 360)
    }
    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        lock.lock(); let forwarding = active
        if forwarding { frames &+= 1 }
        lock.unlock()
        guard forwarding, let downstream, let camera else { return }
        var rotation: RTCVideoRotation?
        if #available(iOS 17, *), let coordinator = coordinator as? AVCaptureDevice.RotationCoordinator,
           let output = camera.captureSession.outputs.first(where: { $0 is AVCaptureVideoDataOutput }) as? AVCaptureVideoDataOutput,
           let connection = output.connection(with: .video) {
            rotation = Self.rotation(upright: coordinator.videoRotationAngleForHorizonLevelCapture,
                                     physical: connection.videoRotationAngle)
        }
        // Unqualified cameras and older Mac hosts keep the SDK's original frame.
        let corrected: RTCVideoFrame
        if let rotation, rotation != frame.rotation {
            corrected = RTCVideoFrame(buffer: frame.buffer, rotation: rotation, timeStampNs: frame.timeStampNs)
            corrected.timeStamp = frame.timeStamp
        } else { corrected = frame }
        switch orientation.orient(corrected) {
        case .frame(let native): downstream.capturer(capturer, didCapture: native)
        case .unsupported: downstream.capturer(capturer, didCapture: corrected)
        case .backpressure: break // Bound retained frames; never relabel range on pressure.
        }
    }
    func deactivate() {
        lock.lock(); active = false; lock.unlock()
    }
    func restore() {
        if let camera, camera.delegate === self { camera.delegate = downstream }
    }
    func retire() { deactivate(); restore() }
}
