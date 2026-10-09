import ConferenceCore
import UIKit

/// One color-managed sink per visible gallery tile. The provider retains its
/// original view; this surface never reparents or changes the SDK's layout.
@MainActor
private final class GuestGalleryTile: UIView {
    private let video = GuestSampleBufferView()
    private let processor = GuestVideoFrameProcessor()
    private var tap: GuestVideoFrameTap?
    private weak var renderer: UIView?
    private var mediaActive = false
    private var visible = false
    private var hasFrame = false
    private var viewport: StreamViewport!
    private let status = UILabel()
    var onToggleControls: (() -> Void)? { didSet { viewport.onToggleControls = onToggleControls } }
    init(item: GuestStreamViews.GalleryItem, pin: @escaping () -> Void) {
        super.init(frame: .zero)
        video.contentMode = .scaleAspectFit
        viewport = StreamViewport(video: video, state: StreamViewportState(), zoomable: false,
            name: item.name, showInfo: true, microphoneOn: item.microphoneOn, pinned: false,
            watermark: item.watermark, showsPlaceholder: !item.active, onPin: pin)
        addSubview(viewport)
        status.textColor = .lightGray; status.font = .preferredFont(forTextStyle: .caption1)
        status.numberOfLines = 0; status.textAlignment = .center
        status.isUserInteractionEnabled = false
        addSubview(status)
        processor.setFrameRate(15)
        processor.onSample = { [weak self] sample, _, rotation in
            guard let self, self.visible, self.mediaActive else { return }
            if self.video.enqueue(sample, rotation: rotation) {
                self.hasFrame = true; self.status.isHidden = true
            }
        }
        update(item, pin: pin)
    }
    required init?(coder: NSCoder) { nil }
    func update(_ item: GuestStreamViews.GalleryItem, pin: @escaping () -> Void) {
        if renderer !== item.renderer || mediaActive != item.active {
            stop(); renderer = item.renderer; video.clear(); hasFrame = false
        }
        mediaActive = item.active
        viewport.updatePresentation(name: item.name, showInfo: true, microphoneOn: item.microphoneOn,
            pinned: false, watermark: item.watermark, zoomable: false, placeholderText: L("Camera off"))
        viewport.updatePin(name: item.name, isShare: item.id.isShare, pinned: false, onPin: pin)
        viewport.setMediaActive(item.active)
        status.text = item.active ? L("Waiting for video…") : nil
        status.isHidden = !item.active || hasFrame
        layer.borderWidth = item.speaking ? 3 : 0
        layer.borderColor = UIColor.systemGreen.cgColor
        layer.cornerRadius = 12
        clipsToBounds = true
        accessibilityValue = item.speaking ? L("Speaking") : nil
        accessibilityIdentifier = "gallery." + item.id.participant + (item.id.isShare ? ".screen" : ".camera")
        refreshDemand()
    }
    func setVisible(_ value: Bool) { visible = value; refreshDemand() }
    private func refreshDemand() {
        guard visible, mediaActive, let renderer else { stop(); return }
        if tap?.matches(renderer) != true {
            stop()
            let source = processor.replaceSource(), processor = processor
            tap = GuestVideoFrameTap(view: renderer) { [weak processor] frame in processor?.submit(frame, source: source) }
        }
        processor.setEnabled(tap != nil)
    }
    private func stop() { processor.setEnabled(false); tap?.invalidate(); tap = nil }
    override func layoutSubviews() {
        super.layoutSubviews(); viewport.frame = bounds
        status.frame = bounds.insetBy(dx: 16, dy: 48)
    }
    deinit { tap?.invalidate(); processor.setEnabled(false) }
}

@MainActor
final class GuestGalleryView: UIScrollView, UIScrollViewDelegate {
    private var tiles: [GuestStreamViews.PinTarget: GuestGalleryTile] = [:]
    private var order: [GuestStreamViews.PinTarget] = []
    private var active = false
    private var observers: [NSObjectProtocol] = []
    var onPin: ((GuestStreamViews.PinTarget) -> Void)?
    var onInteraction: (() -> Void)?
    var onToggleControls: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self; backgroundColor = .black; alwaysBounceVertical = false
        accessibilityIdentifier = "Meeting grid"
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDemand() }
            })
        }
    }
    required init?(coder: NSCoder) { nil }
    func update(_ items: [GuestStreamViews.GalleryItem]) {
        let keys = Set(items.map(\.id))
        for key in tiles.keys.filter({ !keys.contains($0) }) {
            tiles.removeValue(forKey: key)?.removeFromSuperview()
        }
        order = items.map(\.id)
        for item in items {
            let pin: () -> Void = { [weak self] in self?.onPin?(item.id) }
            if let tile = tiles[item.id] { tile.update(item, pin: pin) }
            else {
                let tile = GuestGalleryTile(item: item, pin: pin)
                tile.onToggleControls = { [weak self] in self?.onToggleControls?() }
                tiles[item.id] = tile; addSubview(tile)
            }
        }
        setNeedsLayout()
    }
    func setActive(_ value: Bool) { active = value; refreshDemand() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let frames = MeetingTileLayout.frames(count: order.count, size: bounds.size, mode: .grid)
        for (key, frame) in zip(order, frames) { tiles[key]?.frame = frame }
        let next = CGSize(width: bounds.width, height: max(bounds.height, frames.map(\.maxY).max() ?? 0))
        if contentSize != next { contentSize = next }
        refreshDemand()
    }
    private func refreshDemand() {
        let enabled = active && window != nil && UIApplication.shared.applicationState != .background
        for tile in tiles.values { tile.setVisible(enabled && bounds.intersects(tile.frame)) }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); refreshDemand() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { refreshDemand() }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { onInteraction?() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
