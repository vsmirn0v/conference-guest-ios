import AVFoundation
import Foundation
import WebRTC

/// UIKit window orientation is not camera sensor orientation on a Mac.
/// Use the capture device's horizon; preserve phone orientation with native NV12
/// rotation before the SDK's software path can discard color information.
final class GuestCameraFrameDelegate: NSObject, RTCVideoCapturerDelegate {
    private weak var downstream: (any RTCVideoCapturerDelegate)?
    private weak var camera: RTCCameraVideoCapturer?
    private let rotationReference = MacCameraFrameOrientation()
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
        super.init()
    }
    static func rotation(upright: Double, physical: Double) -> RTCVideoRotation? {
        MacCameraFrameOrientation.relativeAngle(upright: upright, physical: physical).flatMap(RTCVideoRotation.init(rawValue:))
    }

    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        lock.lock(); let forwarding = active
        if forwarding { frames &+= 1 }
        lock.unlock()
        guard forwarding, let downstream, let camera else { return }
        let rotation = rotationReference.rotation(in: camera.captureSession).flatMap(RTCVideoRotation.init(rawValue:))
        // Unqualified cameras and older Mac hosts keep the SDK's original frame.
        let corrected: RTCVideoFrame
        if let rotation, rotation != frame.rotation {
            corrected = RTCVideoFrame(buffer: frame.buffer, rotation: rotation, timeStampNs: frame.timeStampNs)
            corrected.timeStamp = frame.timeStamp
        } else { corrected = frame }
        switch orientation.orient(corrected) {
        case .frame(let native):
            downstream.capturer(capturer, didCapture: native)
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
