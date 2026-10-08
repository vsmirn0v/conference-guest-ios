import CoreGraphics
import LiveKitWebRTC

/// Extract a server-provided region from one decoded composite. Stable stream
/// identity survives layout and speaking updates; no extra decoder or capturer.
final class CompositeVideoSource: @unchecked Sendable {
    let track: LKRTCVideoTrack
    private let lock = NSLock()
    private var rectangle: CGRect
    private var renderers: [ObjectIdentifier: Renderer] = [:]
    init(track: LKRTCVideoTrack, rectangle: CGRect) { self.track = track; self.rectangle = rectangle }
    func update(_ rectangle: CGRect) { lock.lock(); self.rectangle = rectangle; lock.unlock() }
    private var region: CGRect { lock.lock(); defer { lock.unlock() }; return rectangle }
    func add(_ sink: RoomFloatingVideoSink) {
        let key = ObjectIdentifier(sink)
        lock.lock()
        guard renderers[key] == nil else { lock.unlock(); return }
        let renderer = Renderer(source: self, sink: sink); renderers[key] = renderer
        lock.unlock(); track.add(renderer)
    }
    func remove(_ sink: RoomFloatingVideoSink) {
        lock.lock(); let renderer = renderers.removeValue(forKey: ObjectIdentifier(sink)); lock.unlock()
        if let renderer { track.remove(renderer) }
    }
    private final class Renderer: NSObject, LKRTCVideoRenderer {
        weak var source: CompositeVideoSource?
        weak var sink: RoomFloatingVideoSink?
        init(source: CompositeVideoSource, sink: RoomFloatingVideoSink) { self.source = source; self.sink = sink }
        func setSize(_ size: CGSize) {}
        func renderFrame(_ frame: LKRTCVideoFrame?) {
            guard let source, let frame else { return }
            sink?.renderComposite(frame, region: source.region)
        }
    }
    deinit { renderers.values.forEach { track.remove($0) } }
}
