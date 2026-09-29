import LiveKit
import Foundation

/// Observes the existing local track; no second capturer, encoder, or unbounded frame tasks.
final class LocalShareTrackPreview: @unchecked Sendable {
    private final class Sink: NSObject, VideoRenderer, @unchecked Sendable {
        weak var owner: LocalShareTrackPreview?
        let epoch: Int
        @MainActor var isAdaptiveStreamEnabled: Bool { false }
        @MainActor var adaptiveStreamSize: CGSize { .zero }
        init(owner: LocalShareTrackPreview, epoch: Int) { self.owner = owner; self.epoch = epoch }
        nonisolated func render(frame: VideoFrame) { owner?.receive(frame, epoch: epoch) }
    }
    @MainActor let preview: LocalSharePreview
    @MainActor private var track: VideoTrack?
    @MainActor private var sink: Sink?
    private let lock = NSLock()
    private var pending = false
    private var lastFrame: TimeInterval = -.infinity
    private var generation = 0
    @MainActor init(preview: LocalSharePreview) { self.preview = preview }
    @MainActor func setTrack(_ track: VideoTrack?) {
        guard self.track !== track else { return }
        lock.lock(); generation += 1; lastFrame = -.infinity; let epoch = generation; lock.unlock()
        if let sink { self.track?.remove(videoRenderer: sink) }
        self.track = track
        preview.end()
        if let track {
            preview.begin()
            let sink = Sink(owner: self, epoch: epoch)
            self.sink = sink
            track.add(videoRenderer: sink)
        } else { sink = nil }
    }
    private func receive(_ frame: VideoFrame, epoch: Int) {
        let time = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard generation == epoch, !pending, time - lastFrame >= 1 else { lock.unlock(); return }
        pending = true; lastFrame = time
        lock.unlock()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.completeFrame() }
            guard self.currentGeneration() == epoch, self.track != nil else { return }
            self.preview.refreshPolicy()
            guard self.preview.acceptsFrames, let buffer = frame.toCVPixelBuffer() else { return }
            self.preview.accept(buffer, rotation: frame.rotation.rawValue, time: time)
        }
    }
    private func completeFrame() { lock.lock(); pending = false; lock.unlock() }
    private func currentGeneration() -> Int { lock.lock(); defer { lock.unlock() }; return generation }
}
