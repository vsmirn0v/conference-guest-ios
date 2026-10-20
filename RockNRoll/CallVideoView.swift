import Combine
import LiveKit
import UIKit

/// Shared bounded surface for decoded native and room tracks. Pixels enqueue
/// off-main on iOS 17+, while geometry, mirroring and layout stay on the UI.
@MainActor
final class CallVideoView: UIView, TrackDelegate {
    enum Layout { case fit, fill }
    private let video = GuestSampleBufferView()
    var displaySize: CGSize {
        if !roomFallback.isHidden, let size = roomFallback.track?.dimensions {
            return CGSize(width: Int(size.width), height: Int(size.height))
        }
        return video.displaySize
    }
    var onDisplaySizeChanged: (() -> Void)?
    private let roomFallback = VideoView()
    private var sink: RoomFloatingVideoSink?
    private var delivery: SampleBufferFrameDelivery?
    private var cameraPreview: CameraCapturePreviewView?
    private var bindingRevision: UInt64 = 0
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
        video.onDisplaySizeChanged = { [weak self] in self?.onDisplaySizeChanged?() }
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
        previous?.roomTrack?.remove(delegate: self)
        track?.roomTrack?.add(delegate: self)
        bindingRevision &+= 1
        let revision = bindingRevision, retiredCamera = cameraPreview, retiredSink = sink, retiredDelivery = delivery
        cameraPreview = nil; sink = nil; delivery = nil
        retiredDelivery?.invalidate()
        if let retiredSink { retiredSink.retire(); previous?.remove(retiredSink) }
        retiredCamera?.stop(); retiredCamera?.removeFromSuperview()
        guard revision == bindingRevision else { return }
        video.clear()
        guard revision == bindingRevision else { return }
        roomFallback.track = nil
        guard revision == bindingRevision else { return }
        roomFallback.isHidden = true
        video.isHidden = track == nil
        guard let track else { return }
        if let source = track.cameraPreview {
            video.isHidden = true
            let preview = source.makeView()
            guard revision == bindingRevision else { preview.stop(); return }
            preview.mirrored = isMirrored; preview.enabled = renderingEnabled
            preview.contentMode = video.contentMode
            cameraPreview = preview
            preview.translatesAutoresizingMaskIntoConstraints = false; addSubview(preview)
            guard revision == bindingRevision else { return }
            NSLayoutConstraint.activate([preview.leadingAnchor.constraint(equalTo: leadingAnchor), preview.trailingAnchor.constraint(equalTo: trailingAnchor), preview.topAnchor.constraint(equalTo: topAnchor), preview.bottomAnchor.constraint(equalTo: bottomAnchor)])
            return
        }
        if let local = track.roomTrack as? LocalVideoTrack, local.source == .camera {
            // The public room-frame wrapper hides AVCapture crop offsets.
            // Normally local cameras use the borrowed preview above.
            video.isHidden = true; roomFallback.isHidden = false; roomFallback.track = local
            onDisplaySizeChanged?()
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
                self.onDisplaySizeChanged?()
            }
        }
        self.sink = sink; sink.setWanted(renderingEnabled, fps: MediaEnergyBudget.shared.inlineFPS)
        sink.setAdaptiveSize(renderingEnabled ? bounds.size : .zero)
        track.add(sink)
    }
    override func layoutSubviews() { super.layoutSubviews(); sink?.setAdaptiveSize(renderingEnabled ? bounds.size : .zero) }
    nonisolated func track(_ track: VideoTrack, didUpdateDimensions dimensions: Dimensions?) {
        Task { @MainActor [weak self] in
            guard let self, self.track?.roomTrack === track else { return }
            self.onDisplaySizeChanged?()
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver); delivery?.invalidate(); if let sink { sink.retire(); track?.remove(sink) } }
}
