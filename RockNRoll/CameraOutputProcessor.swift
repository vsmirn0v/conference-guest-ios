import AVFoundation
import LiveKit

/// Camera-only, before encoder input. LiveKit's capture options remain stable;
/// tier changes do not restart the camera or touch screen-share publications.
final class CameraOutputProcessor: NSObject, VideoProcessor {
    private let lock = NSLock()
    private var profile = CameraQualityPolicy.Profile(tier: .balance, fps: 20)
    private var lastTime: Int64?
    private var nextTime: Int64?
    private let scaler = CameraPixelScaler()
    func setProfile(_ profile: CameraQualityPolicy.Profile) {
        lock.lock(); self.profile = profile; lock.unlock()
    }
    func process(frame: VideoFrame) -> VideoFrame? {
        lock.lock(); let profile = profile; lock.unlock()
        let interval = Int64(1_000_000_000 / max(1, profile.fps))
        if let lastTime, frame.timeStampNs < lastTime { nextTime = nil }
        lastTime = frame.timeStampNs
        if let nextTime, frame.timeStampNs < nextTime { return nil }
        if let nextTime, frame.timeStampNs - nextTime <= interval * 2 { self.nextTime = nextTime + interval }
        else { nextTime = frame.timeStampNs + interval }
        guard let source = frame.toCVPixelBuffer(), let output = scaler.scale(source, maximum: profile.maximum) else { return nil }
        // This owner sends the full physical camera image, retaining its aspect.
        // The SDK's logical center crop is intentionally not a camera framing policy.
        return VideoFrame(dimensions: .init(width: Int32(CVPixelBufferGetWidth(output)), height: Int32(CVPixelBufferGetHeight(output))), rotation: frame.rotation,
            timeStampNs: frame.timeStampNs, buffer: CVPixelVideoBuffer(pixelBuffer: output))
    }
}
