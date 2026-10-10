import AVFoundation
import Foundation
import WebRTC

/// Preserve the capturer's rotation contract. Bake that rotation into qualified
/// native NV12 before the SDK's software path can discard color information.
final class GuestCameraFrameDelegate: NSObject, RTCVideoCapturerDelegate {
    private weak var downstream: (any RTCVideoCapturerDelegate)?
    private weak var camera: RTCCameraVideoCapturer?
    private let lock = NSLock()
    private var active = true
    struct Progress { let generation: UUID; let frames: Int64 }
    private let generation = UUID()
    private var frames: Int64 = 0
    private let orientation = GuestCameraOrientation()
    private let scaler = CameraPixelScaler()
    private var profile = CameraQualityPolicy.Profile(tier: .balance, fps: 20)
    private var adapted: (Int32, Int32, Int)?
    @MainActor private var quality: CameraQualityMonitor?
    var requestedCadence: Int { lock.lock(); defer { lock.unlock() }; return profile.fps }
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
        Task { @MainActor [weak self, weak camera] in
            guard let self, let camera else { return }
            self.lock.lock(); let active = self.active; self.lock.unlock()
            guard active else { return }
            let quality = CameraQualityMonitor(); self.quality = quality
            quality.onChange = { [weak self, weak camera] profile in
                guard let self, let camera else { return }
                self.lock.lock(); self.profile = profile; self.lock.unlock()
                GuestCaptureDeviceObserver.setCadence(camera, fps: profile.fps)
            }
            quality.onChange?(quality.profile)
            quality.start { [weak self] in
                guard let source = self?.originalDelegate as? RTCVideoSource else { return nil }
                return await GuestMicrophoneProbe.cameraUplink(source: source)
            }
        }
    }
    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        lock.lock(); let forwarding = active
        if forwarding { frames &+= 1 }
        lock.unlock()
        guard forwarding, let downstream, camera != nil else { return }
        switch orientation.orient(frame) {
        case .frame(let native): forward(native, capturer: capturer, downstream: downstream)
        case .unsupported: forward(frame, capturer: capturer, downstream: downstream)
        case .backpressure: break // Bound retained frames; never relabel range on pressure.
        }
    }
    private func forward(_ frame: RTCVideoFrame, capturer: RTCVideoCapturer, downstream: any RTCVideoCapturerDelegate) {
        lock.lock(); let profile = profile; lock.unlock()
        let boundedFrame: RTCVideoFrame
        if let native = frame.buffer as? RTCCVPixelBuffer {
            guard let pixels = scaler.scale(native.pixelBuffer, maximum: profile.maximum) else { return }
            if pixels === native.pixelBuffer { boundedFrame = frame }
            else {
                boundedFrame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: frame.rotation, timeStampNs: frame.timeStampNs)
                boundedFrame.timeStamp = frame.timeStamp
            }
        } else {
            let size = CameraQualityPolicy.bounded(.init(width: frame.width, height: frame.height), maximum: profile.maximum)
            guard size.width == frame.width, size.height == frame.height else { return }
            boundedFrame = frame
        }
        if let source = originalDelegate as? RTCVideoSource {
            let size = CameraQualityPolicy.bounded(.init(width: boundedFrame.width, height: boundedFrame.height), maximum: profile.maximum)
            guard size.width > 0, size.height > 0 else { return }
            if adapted?.0 != size.width || adapted?.1 != size.height || adapted?.2 != profile.fps {
                source.adaptOutputFormat(toWidth: size.width, height: size.height, fps: Int32(profile.fps))
                adapted = (size.width, size.height, profile.fps)
            }
        }
        downstream.capturer(capturer, didCapture: boundedFrame)
    }
    func deactivate() {
        lock.lock(); active = false; lock.unlock()
        Task { @MainActor [weak self] in self?.quality = nil }
    }
    func restore() {
        if let camera, camera.delegate === self { camera.delegate = downstream }
    }
    func retire() { deactivate(); restore() }
}
