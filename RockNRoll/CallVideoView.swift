import LiveKit
import UIKit

/// Shared stage surface. Changing speaker metadata never replaces its renderer.
@MainActor
final class CallVideoView: UIView {
    enum Layout { case fit, fill }
    private let roomView = VideoView()
    private let nativeView = GuestSampleBufferView()
    private var sink: RoomFloatingVideoSink?
    var track: CallVideoSource? { didSet { if oldValue?.identity != track?.identity { bind(oldValue) } } }
    var isEnabled = true { didSet { roomView.isEnabled = isEnabled; sink?.setWanted(isEnabled, fps: 30) } }
    var layoutMode: Layout = .fill {
        didSet { roomView.layoutMode = layoutMode == .fit ? .fit : .fill; nativeView.contentMode = layoutMode == .fit ? .scaleAspectFit : .scaleAspectFill }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        roomView.renderMode = .sampleBuffer
        for child in [roomView, nativeView] as [UIView] {
            child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child)
            NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: leadingAnchor), child.trailingAnchor.constraint(equalTo: trailingAnchor), child.topAnchor.constraint(equalTo: topAnchor), child.bottomAnchor.constraint(equalTo: bottomAnchor)])
        }
        nativeView.isHidden = true
    }
    required init?(coder: NSCoder) { nil }
    private func bind(_ previous: CallVideoSource?) {
        if let sink { sink.retire(); previous?.remove(sink) }
        sink = nil; roomView.track = nil; nativeView.clear()
        roomView.isHidden = track?.roomTrack == nil; nativeView.isHidden = track?.roomTrack != nil || track == nil
        guard let track else { return }
        if let roomTrack = track.roomTrack { roomView.track = roomTrack; return }
        let identity = track.identity
        let sink = RoomFloatingVideoSink { [weak self] sample, rotation in
            guard let self, self.track?.identity == identity, self.isEnabled else { return }
            self.nativeView.enqueue(sample, rotation: rotation)
        }
        self.sink = sink; sink.setWanted(isEnabled, fps: 30); track.add(sink)
    }
    deinit { if let sink { sink.retire(); track?.remove(sink) } }
}
