import LiveKit
import LiveKitWebRTC
import Foundation
import CoreMedia

/// Prime one AVKit frame, then process only while PiP is starting/visible.
/// Observing a track never creates another capturer or encoder.
final class RoomFloatingVideoSink: NSObject, VideoRenderer, LKRTCVideoRenderer, @unchecked Sendable {
    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { .zero }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.vsmirn0v.conferenceguest.floating-frame", qos: .userInitiated)
    private var wanted = false
    private var primed = false
    private var pending = false
    private var lastFrame: TimeInterval = -.infinity
    private var interval: TimeInterval = 1.0 / 15
    private var retired = false
    private let nativeConverter = NativeVideoPixelBuffer()
    let deliver: @MainActor (CMSampleBuffer, Int) -> Void
    @MainActor init(deliver: @escaping @MainActor (CMSampleBuffer, Int) -> Void) { self.deliver = deliver }
    func setWanted(_ value: Bool, fps: Int) { lock.lock(); wanted = value; interval = 1.0 / Double(max(1, fps)); lock.unlock() }
    func retire() { lock.lock(); retired = true; lock.unlock() }
    func render(frame: VideoFrame) {
        submit(rotation: frame.rotation.rawValue) { frame.toCVPixelBuffer() }
    }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        submit(rotation: frame.rotation.rawValue) { [weak self] in self?.nativeConverter.convert(frame) }
    }
    private func submit(rotation: Int, pixels: @escaping () -> CVPixelBuffer?) {
        let time = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !retired, !pending, (!primed || wanted), time - lastFrame >= interval else { lock.unlock(); return }
        pending = true; lastFrame = time
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let sample = autoreleasepool {
                pixels().flatMap { PresenterCompositor.sample($0, time: CMTime(seconds: time, preferredTimescale: 1_000_000_000)) }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let accepted = self.complete(success: sample != nil)
                if accepted, let sample { self.deliver(sample, rotation) }
            }
        }
    }
    private func complete(success: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pending = false
        guard !retired else { return false }
        if success { primed = true }
        return success
    }
}
