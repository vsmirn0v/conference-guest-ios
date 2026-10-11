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
    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { .zero }
    private let lock = NSLock()
    private struct Frame {
        let rotation: Int
        let time: TimeInterval
        let pixels: () -> CVPixelBuffer?
    }
    private var wanted = false
    private var primed = false
    private var retired = false
    private let nativeConverter = NativeVideoPixelBuffer()
    private lazy var frames: LatestVideoFrameProcessor<Frame, (CMSampleBuffer, Int)> = LatestVideoFrameProcessor(
        label: "dev.vsmirn0v.conferenceguest.floating-frame", convert: { frame in
            autoreleasepool {
                frame.pixels().flatMap { pixels in
                    PresenterCompositor.sample(pixels, time: CMTime(seconds: frame.time, preferredTimescale: 1_000_000_000))
                        .map { ($0, frame.rotation) }
                }
            }
        }, deliver: { [weak self] sample, rotation in
            guard let self else { return }
            self.lock.lock()
            let accepted = !self.retired && (!self.primed || self.wanted)
            if accepted { self.primed = true }
            let enabled = !self.retired && self.wanted
            self.lock.unlock()
            if accepted { self.deliver(sample, rotation) }
            if !enabled { self.frames.setEnabled(false) }
        })
    let deliver: @MainActor (CMSampleBuffer, Int) -> Void
    @MainActor init(deliver: @escaping @MainActor (CMSampleBuffer, Int) -> Void) {
        self.deliver = deliver
        super.init()
        frames.setEnabled(true)
    }
    func setWanted(_ value: Bool, fps: Int) {
        lock.lock(); wanted = value
        let enabled = !retired && (value || !primed)
        lock.unlock()
        frames.setFrameRate(fps); frames.setEnabled(enabled)
    }
    func prime() {
        lock.lock(); primed = false; let enabled = !retired; lock.unlock()
        frames.setEnabled(enabled)
    }
    func retire() {
        lock.lock(); retired = true; lock.unlock()
        frames.setEnabled(false)
    }
    func render(frame: VideoFrame) {
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
