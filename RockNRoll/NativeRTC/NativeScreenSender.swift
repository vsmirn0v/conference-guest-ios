import Combine
import CoreMedia
import LiveKit
import LiveKitWebRTC

/// Captures with the existing system chooser/ReplayKit extension. LiveKit is
/// used only for its public capture transport, never to join a second meeting.
@MainActor
final class NativeScreenSender {
    let track: LKRTCVideoTrack
    private let source: LKRTCVideoSource
    private let sink: Sink
    private let preview: LocalSharePreview
    private var capture: GuestScreenCapture?
    private var broadcastTrack: LocalVideoTrack?
    private var closed = false
    private(set) var composed = false
    private var stopping: Task<Void, Never>?
    private var energySubscription: AnyCancellable?
    private let onEnd: (String?) -> Void
    init(factory: LKRTCPeerConnectionFactory, preview: LocalSharePreview,
         onFirstFrame: @escaping () -> Void, onEnd: @escaping (String?) -> Void) {
        source = factory.videoSource(forScreenCast: true)
        track = factory.videoTrack(with: source, trackId: "screen")
        self.preview = preview; self.onEnd = onEnd
        sink = Sink(source: source, preview: preview, onFirst: onFirstFrame)
        energySubscription = MediaEnergyBudget.shared.$pressure.removeDuplicates().sink { [weak sink] pressure in
            sink?.setFPS(pressure == .normal ? 15 : pressure == .constrained ? 10 : 5)
        }
    }
    func start(broadcast: Bool) async throws {
        guard !closed else { throw CancellationError() }
        if broadcast {
            let track = await LocalVideoTrack.createBroadcastScreenCapturerTrack(options: ScreenShareCaptureOptions(dimensions: .h1080_169, fps: 15, appAudio: false))
            guard !closed, !Task.isCancelled else { throw CancellationError() }
            broadcastTrack = track; track.add(videoRenderer: sink)
            preview.begin()
            try await track.start()
            if closed || Task.isCancelled { try? await track.stop(); throw CancellationError() }
        } else {
            capture = GuestScreenCaptureFactory.make(preview: preview, onFrame: { [weak self] sample in self?.sink.receive(sample) },
                onEnd: { [weak self] message in self?.onEnd(message) }, onError: { _ in })
            preview.begin(source: .selected); capture?.start()
        }
    }
    func stop() async {
        if let stopping { await stopping.value; return }
        guard !closed else { return }
        closed = true; energySubscription = nil; sink.retire(); preview.end()
        let capture = self.capture, track = broadcastTrack
        self.capture = nil; broadcastTrack = nil
        track?.remove(videoRenderer: sink)
        stopping = Task { await capture?.stop(); try? await track?.stop() }
        await stopping?.value; stopping = nil
    }
    func startComposed() throws {
        guard !closed else { throw CancellationError() }
        composed = true
        preview.begin(source: .presenter)
    }
    func send(_ sample: CMSampleBuffer) { sink.receive(sample) }
    #if DEBUG
    func receiveForTesting(_ pixels: CVPixelBuffer, timestamp: Int64) {
        sink.render(frame: VideoFrame(dimensions: Dimensions(width: Int32(CVPixelBufferGetWidth(pixels)), height: Int32(CVPixelBufferGetHeight(pixels))), rotation: ._0,
            timeStampNs: timestamp, buffer: CVPixelVideoBuffer(pixelBuffer: pixels)))
    }
    #endif
    /// RTC delivery stays synchronous and bounded. At most one preview update is
    /// queued on the main actor; stopping invalidates even a late capture frame.
    private final class Sink: NSObject, VideoRenderer, @unchecked Sendable {
        let source: LKRTCVideoSource
        let capturer: LKRTCVideoCapturer
        let preview: LocalSharePreview
        let onFirst: @MainActor () -> Void
        private let lock = NSLock()
        private var retired = false, started = false, previewPending = false
        private var lastTime: Int64 = -1
        private var outputSize = CGSize.zero
        private var fps = 15
        private var adaptedFPS = 0
        var isAdaptiveStreamEnabled: Bool { false }
        var adaptiveStreamSize: CGSize { .zero }
        init(source: LKRTCVideoSource, preview: LocalSharePreview, onFirst: @escaping @MainActor () -> Void) {
            self.source = source; capturer = LKRTCVideoCapturer(delegate: source)
            self.preview = preview; self.onFirst = onFirst
        }
        func render(frame: VideoFrame) {
            guard let pixels = frame.toCVPixelBuffer() else { return }
            deliver(pixels, rotation: frame.rotation.rawValue, timestamp: frame.timeStampNs)
        }
        func receive(_ sample: CMSampleBuffer) {
            guard sample.isValid, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
            let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / 1e9 else { return }
            deliver(pixels, rotation: 0, timestamp: Int64(seconds * 1e9))
        }
        func setFPS(_ value: Int) { lock.lock(); fps = max(1, value); lock.unlock() }
        private func deliver(_ pixels: CVPixelBuffer, rotation: Int, timestamp: Int64) {
            lock.lock()
            guard !retired, timestamp >= 0, (!started || timestamp - lastTime >= Int64(1_000_000_000 / fps)),
                CVPixelBufferGetWidth(pixels) <= 4096, CVPixelBufferGetHeight(pixels) <= 4096 else { lock.unlock(); return }
            lastTime = timestamp
            let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
            let scale = min(1, min(Double(width >= height ? 1920 : 1080) / Double(width), Double(width >= height ? 1080 : 1920) / Double(height)))
            let size = CGSize(width: max(2, Int(Double(width) * scale) / 2 * 2), height: max(2, Int(Double(height) * scale) / 2 * 2))
            if outputSize != size || adaptedFPS != fps {
                outputSize = size; adaptedFPS = fps
                source.adaptOutputFormat(toWidth: Int32(size.width), height: Int32(size.height), fps: Int32(fps))
            }
            let first = !started; started = true
            let previewWanted = !previewPending
            if previewWanted { previewPending = true }
            let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixels), rotation: LKRTCVideoRotation(rawValue: rotation) ?? ._0, timeStampNs: timestamp)
            source.capturer(capturer, didCapture: frame)
            lock.unlock()
            if first || previewWanted {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lock.lock(); let active = !self.retired; self.previewPending = false; self.lock.unlock()
                    guard active else { return }
                    if first { self.onFirst() }
                    if previewWanted { self.preview.accept(pixels, rotation: rotation) }
                }
            }
        }
        func retire() { lock.lock(); retired = true; lock.unlock() }
    }
}
