import LiveKit
import LiveKitWebRTC
import Foundation
import CoreMedia

/// Presenter consumes the live camera track, including its system effects.
/// The bounded converter owns no camera or encoder.
@MainActor
final class TrackPresenterCamera: PresenterCameraSource {
    private let source: CallVideoSource
    private let sink: RoomFloatingVideoSink
    init(source: CallVideoSource, onFrame: @escaping (CVPixelBuffer, Int) -> Void) {
        self.source = source
        sink = RoomFloatingVideoSink { sample, rotation in
            if let pixels = CMSampleBufferGetImageBuffer(sample) { onFrame(pixels, rotation) }
        }
        sink.setWanted(true, fps: 15)
        source.add(sink)
    }
    func stop() { sink.retire(); source.remove(sink) }
}

/// Prime one AVKit frame, then process only while PiP is starting/visible.
/// Observing a track never creates another capturer or encoder.
final class RoomFloatingVideoSink: NSObject, VideoRenderer, LKRTCVideoRenderer, @unchecked Sendable {
    @MainActor var isAdaptiveStreamEnabled: Bool { lock.lock(); defer { lock.unlock() }; return wanted && !retired && adaptiveSize != .zero }
    @MainActor var adaptiveStreamSize: CGSize { lock.lock(); defer { lock.unlock() }; return adaptiveSize }
    private var adaptiveSize = CGSize.zero
    @MainActor func setAdaptiveSize(_ size: CGSize) { lock.lock(); adaptiveSize = size; lock.unlock() }
    private let lock = NSLock()
    private struct Frame {
        let rotation: Int
        let time: TimeInterval
        let pixels: () -> CVPixelBuffer?
    }
    private var wanted = false
    private var primed = false
    private var retired = false
    private var reportedRoomGeometryMismatch = false
    var onRoomGeometryMismatch: (@MainActor () -> Void)?
    private let nativeConverter = NativeVideoPixelBuffer()
    private lazy var frames: LatestVideoFrameProcessor<Frame, (CMSampleBuffer, Int)> = makeProcessor()
    private func makeProcessor() -> LatestVideoFrameProcessor<Frame, (CMSampleBuffer, Int)> {
        let convert: (Frame) -> (CMSampleBuffer, Int)? = { frame in
            autoreleasepool {
                frame.pixels().flatMap { pixels in
                    PresenterCompositor.sample(pixels, time: CMTime(seconds: frame.time, preferredTimescale: 1_000_000_000))
                        .map { ($0, frame.rotation) }
                }
            }
        }
        let label = "dev.vsmirn0v.conferenceguest.floating-frame"
        if let backgroundDeliver {
            return LatestVideoFrameProcessor(label: label, convert: convert, backgroundDeliver: { [weak self] sample, rotation in
                if self?.accept() == true { backgroundDeliver(sample, rotation) }
            })
        }
        return LatestVideoFrameProcessor(label: label, convert: convert, deliver: { [weak self] sample, rotation in
            if self?.accept() == true { self?.deliver?(sample, rotation) }
        })
    }
    private func accept() -> Bool {
        lock.lock()
        let accepted = !retired && (!primed || wanted)
        if accepted { primed = true }
        let enabled = !retired && wanted
        // Demand changes can now arrive while worker delivery primes a frame.
        // Update the scheduler under the same lock, so priming cannot disable
        // a newer request to start PiP.
        if !enabled { frames.setEnabled(false) }
        lock.unlock()
        return accepted
    }
    private let deliver: (@MainActor (CMSampleBuffer, Int) -> Void)?
    private let backgroundDeliver: ((CMSampleBuffer, Int) -> Void)?
    @MainActor init(deliver: @escaping @MainActor (CMSampleBuffer, Int) -> Void) {
        self.deliver = deliver; backgroundDeliver = nil
        super.init()
        frames.setEnabled(true)
    }
    @MainActor init(backgroundDeliver: @escaping (CMSampleBuffer, Int) -> Void) {
        deliver = nil; self.backgroundDeliver = backgroundDeliver
        super.init(); frames.setEnabled(true)
    }
    func setWanted(_ value: Bool, fps: Int) {
        frames.setFrameRate(fps)
        lock.lock(); wanted = value
        let enabled = !retired && (value || !primed)
        frames.setEnabled(enabled)
        lock.unlock()
    }
    func prime() {
        lock.lock(); primed = false; frames.setEnabled(!retired); lock.unlock()
    }
    func retire() {
        lock.lock(); retired = true; frames.setEnabled(false); lock.unlock()
    }
    func render(frame: VideoFrame) {
        // LiveKit's public pixel accessor does not expose native crop metadata.
        // A padded/cropped frame must stay with its SDK renderer instead of
        // guessing offsets or changing the image's field of view.
        if onRoomGeometryMismatch != nil, let buffer = frame.buffer as? CVPixelVideoBuffer,
           (CVPixelBufferGetWidth(buffer.pixelBuffer) != Int(frame.dimensions.width) ||
            CVPixelBufferGetHeight(buffer.pixelBuffer) != Int(frame.dimensions.height)) {
            lock.lock()
            let notify = !retired && !reportedRoomGeometryMismatch
            if notify { reportedRoomGeometryMismatch = true }
            lock.unlock()
            if notify { DispatchQueue.main.async { [weak self] in self?.onRoomGeometryMismatch?() } }
            return
        }
        submit(rotation: frame.rotation.rawValue) { frame.toCVPixelBuffer() }
    }
    func render(pixels: CVPixelBuffer, rotation: Int) { submit(rotation: rotation) { pixels } }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        submit(rotation: frame.rotation.rawValue) { [weak self] in self?.nativeConverter.convert(frame) }
    }
    func renderComposite(_ frame: LKRTCVideoFrame, region: CGRect) {
        submit(rotation: frame.rotation.rawValue) { [weak self] in self?.nativeConverter.convert(frame, region: region) }
    }
    private func submit(rotation: Int, pixels: @escaping () -> CVPixelBuffer?) {
        frames.submit(Frame(rotation: rotation, time: ProcessInfo.processInfo.systemUptime, pixels: pixels))
    }
}
