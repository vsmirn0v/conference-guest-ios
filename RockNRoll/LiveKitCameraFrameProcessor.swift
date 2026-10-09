import Foundation
import LiveKit

/// Correct the Mac capture metadata before LiveKit publishes its first frame.
/// Keep the SDK's native buffer and timing; phone frames pass through unchanged.
final class LiveKitCameraFrameProcessor: NSObject, VideoProcessor {
    weak var capturer: CameraCapturer?
    private let orientation = MacCameraFrameOrientation()

    static func corrected(_ frame: VideoFrame, rotation: VideoRotation?) -> VideoFrame {
        guard let rotation, rotation != frame.rotation else { return frame }
        return VideoFrame(dimensions: frame.dimensions, rotation: rotation,
                          timeStampNs: frame.timeStampNs, buffer: frame.buffer)
    }

    func process(frame: VideoFrame) -> VideoFrame? {
        let rotation = capturer.flatMap { orientation.rotation(in: $0.captureSession) }
            .flatMap(VideoRotation.init(rawValue:))
        return Self.corrected(frame, rotation: rotation)
    }
}
