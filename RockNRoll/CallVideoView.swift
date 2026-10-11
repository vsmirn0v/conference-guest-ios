import LiveKit
import Combine
import UIKit

/// Shared stage surface. Changing speaker metadata never replaces its renderer.
@MainActor
final class CallVideoView: UIView {
    enum Layout { case fit, fill }
    private let roomView = VideoView()
    private let nativeView = GuestSampleBufferView()
    private var sink: RoomFloatingVideoSink?
    private var cameraPreview: CameraCapturePreviewView?
    private var energy: AnyCancellable?
    var isMirrored = false {
        didSet { roomView.mirrorMode = isMirrored ? .mirror : .off; nativeView.mirrored = isMirrored; cameraPreview?.mirrored = isMirrored }
    }
    var track: CallVideoSource? { didSet { if oldValue?.identity != track?.identity { bind(oldValue) } } }
    var isEnabled = true { didSet { roomView.isEnabled = isEnabled; sink?.setWanted(isEnabled, fps: MediaEnergyBudget.shared.inlineFPS); cameraPreview?.enabled = isEnabled } }
    var layoutMode: Layout = .fit {
        didSet { roomView.layoutMode = layoutMode == .fit ? .fit : .fill; nativeView.contentMode = layoutMode == .fit ? .scaleAspectFit : .scaleAspectFill; cameraPreview?.contentMode = nativeView.contentMode }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        roomView.renderMode = .sampleBuffer
        roomView.mirrorMode = .off
        roomView.layoutMode = .fit
        nativeView.contentMode = .scaleAspectFit
        for child in [roomView, nativeView] as [UIView] {
            child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child)
            NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: leadingAnchor), child.trailingAnchor.constraint(equalTo: trailingAnchor), child.topAnchor.constraint(equalTo: topAnchor), child.bottomAnchor.constraint(equalTo: bottomAnchor)])
        }
        nativeView.isHidden = true
        energy = MediaEnergyBudget.shared.$pressure.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sink?.setWanted(self.isEnabled, fps: MediaEnergyBudget.shared.inlineFPS)
            }
        }
    }
    required init?(coder: NSCoder) { nil }
    private func bind(_ previous: CallVideoSource?) {
        if let sink { sink.retire(); previous?.remove(sink) }
        sink = nil; roomView.track = nil; nativeView.clear()
        cameraPreview?.stop(); cameraPreview?.removeFromSuperview(); cameraPreview = nil
        roomView.isHidden = track?.roomTrack == nil; nativeView.isHidden = track?.roomTrack != nil || track == nil
        guard let track else { return }
        if let source = track.cameraPreview {
            nativeView.isHidden = true
            let preview = source.makeView()
            preview.mirrored = isMirrored; preview.enabled = isEnabled
            preview.contentMode = nativeView.contentMode
            preview.translatesAutoresizingMaskIntoConstraints = false; addSubview(preview)
            NSLayoutConstraint.activate([preview.leadingAnchor.constraint(equalTo: leadingAnchor), preview.trailingAnchor.constraint(equalTo: trailingAnchor), preview.topAnchor.constraint(equalTo: topAnchor), preview.bottomAnchor.constraint(equalTo: bottomAnchor)])
            cameraPreview = preview
            return
        }
        if let roomTrack = track.roomTrack { roomView.track = roomTrack; return }
        let identity = track.identity
        let sink = RoomFloatingVideoSink { [weak self] sample, rotation in
            guard let self, self.track?.identity == identity, self.isEnabled else { return }
            self.nativeView.enqueue(sample, rotation: rotation)
        }
        self.sink = sink; sink.setWanted(isEnabled, fps: MediaEnergyBudget.shared.inlineFPS); track.add(sink)
    }
    deinit { if let sink { sink.retire(); track?.remove(sink) } }
}
