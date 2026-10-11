import Combine
import LiveKit
import UIKit

/// Shared bounded surface for decoded native and room tracks. Pixels enqueue
/// off-main on iOS 17+, while geometry, mirroring and layout stay on the UI.
@MainActor
final class CallVideoView: UIView {
    enum Layout { case fit, fill }
    private let video = GuestSampleBufferView()
    private let roomFallback = VideoView()
    private var sink: RoomFloatingVideoSink?
    private var delivery: SampleBufferFrameDelivery?
    private var cameraPreview: CameraCapturePreviewView?
    private var energy: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var foreground = UIApplication.shared.applicationState != .background
    private var renderingEnabled: Bool { isEnabled && foreground }
    var isMirrored = false { didSet { video.mirrored = isMirrored; roomFallback.mirrorMode = isMirrored ? .mirror : .off; cameraPreview?.mirrored = isMirrored } }
    #if DEBUG
    var deliveryForTesting: SampleBufferFrameDelivery? { delivery }
    #endif
    var track: CallVideoSource? { didSet { if oldValue?.identity != track?.identity { bind(oldValue) } } }
    var isEnabled = true { didSet { refreshDemand() } }
    private func refreshDemand() {
        roomFallback.isEnabled = renderingEnabled
        delivery?.setEnabled(renderingEnabled)
        sink?.setWanted(renderingEnabled, fps: MediaEnergyBudget.shared.inlineFPS)
        sink?.setAdaptiveSize(renderingEnabled ? bounds.size : .zero)
        cameraPreview?.enabled = renderingEnabled
    }
    var layoutMode: Layout = .fit {
        didSet { roomFallback.layoutMode = layoutMode == .fit ? .fit : .fill; video.contentMode = layoutMode == .fit ? .scaleAspectFit : .scaleAspectFill; cameraPreview?.contentMode = video.contentMode }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        roomFallback.renderMode = .sampleBuffer; roomFallback.mirrorMode = .off
        roomFallback.layoutMode = .fit; roomFallback.isHidden = true
        roomFallback.translatesAutoresizingMaskIntoConstraints = false; addSubview(roomFallback)
        NSLayoutConstraint.activate([roomFallback.leadingAnchor.constraint(equalTo: leadingAnchor), roomFallback.trailingAnchor.constraint(equalTo: trailingAnchor), roomFallback.topAnchor.constraint(equalTo: topAnchor), roomFallback.bottomAnchor.constraint(equalTo: bottomAnchor)])
        video.contentMode = .scaleAspectFit
        video.translatesAutoresizingMaskIntoConstraints = false; addSubview(video)
        NSLayoutConstraint.activate([video.leadingAnchor.constraint(equalTo: leadingAnchor), video.trailingAnchor.constraint(equalTo: trailingAnchor), video.topAnchor.constraint(equalTo: topAnchor), video.bottomAnchor.constraint(equalTo: bottomAnchor)])
        energy = MediaEnergyBudget.shared.$pressure.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshDemand()
            }
        }
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.foreground = UIApplication.shared.applicationState != .background
                    self.refreshDemand()
                }
            })
        }
    }
    required init?(coder: NSCoder) { nil }
    private func bind(_ previous: CallVideoSource?) {
        delivery?.invalidate(); delivery = nil
        if let sink { sink.retire(); previous?.remove(sink) }
        sink = nil; video.clear(); roomFallback.track = nil; roomFallback.isHidden = true
        cameraPreview?.stop(); cameraPreview?.removeFromSuperview(); cameraPreview = nil
        video.isHidden = track == nil
        guard let track else { return }
        if let source = track.cameraPreview {
            video.isHidden = true
            let preview = source.makeView()
            preview.mirrored = isMirrored; preview.enabled = renderingEnabled
            preview.contentMode = video.contentMode
            preview.translatesAutoresizingMaskIntoConstraints = false; addSubview(preview)
            NSLayoutConstraint.activate([preview.leadingAnchor.constraint(equalTo: leadingAnchor), preview.trailingAnchor.constraint(equalTo: trailingAnchor), preview.topAnchor.constraint(equalTo: topAnchor), preview.bottomAnchor.constraint(equalTo: bottomAnchor)])
            cameraPreview = preview
            return
        }
        if let local = track.roomTrack as? LocalVideoTrack, local.source == .camera {
            // The public room-frame wrapper hides AVCapture crop offsets.
            // Normally local cameras use the borrowed preview above.
            video.isHidden = true; roomFallback.isHidden = false; roomFallback.track = local
            return
        }
        let delivery = video.makeFrameDelivery { _, _ in }
        delivery.setActive(true); delivery.setEnabled(renderingEnabled); self.delivery = delivery
        let sink = RoomFloatingVideoSink(backgroundDeliver: { delivery.deliver($0, rotation: $1) })
        if let roomTrack = track.roomTrack {
            let identity = track.identity
            sink.onRoomGeometryMismatch = { [weak self] in
                guard let self, self.track?.identity == identity else { return }
                self.delivery?.invalidate(); self.delivery = nil
                if let sink = self.sink { sink.retire(); track.remove(sink) }
                self.sink = nil; self.video.clear(); self.video.isHidden = true
                self.roomFallback.isHidden = false; self.roomFallback.track = roomTrack
            }
        }
        self.sink = sink; sink.setWanted(renderingEnabled, fps: MediaEnergyBudget.shared.inlineFPS)
        sink.setAdaptiveSize(renderingEnabled ? bounds.size : .zero)
        track.add(sink)
    }
    override func layoutSubviews() { super.layoutSubviews(); sink?.setAdaptiveSize(renderingEnabled ? bounds.size : .zero) }
    deinit { observers.forEach(NotificationCenter.default.removeObserver); delivery?.invalidate(); if let sink { sink.retire(); track?.remove(sink) } }
}
