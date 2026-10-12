import ConferenceCore
import Combine
import UIKit

/// One color-managed sink per visible gallery tile. The provider retains its
/// original view; this surface never reparents or changes the SDK's layout.
@MainActor
private final class GuestGalleryTile: UIView {
    private let video = GuestSampleBufferView()
    private let processor = GuestVideoFrameProcessor()
    private var energy: AnyCancellable?
    private var tap: GuestVideoFrameTap?
    private weak var renderer: UIView?
    private var localCamera = false
    private var mediaActive = false
    private var visible = false
    private var hasFrame = false
    private var viewport: StreamViewport!
    private let status = UILabel()
#if DEBUG
    var evidenceForTesting: [String: Any] {
        ["visible": visible, "mediaActive": mediaActive, "hasFrame": hasFrame,
         "tapFrames": tap?.receivedFramesForTesting ?? 0, "preparedFrames": processor.preparedFrameCount,
         "sink": video.evidenceForTesting]
    }
#endif
    var onToggleControls: (() -> Void)? { didSet { viewport.onToggleControls = onToggleControls } }
    var onSelect: (() -> Void)? { didSet { viewport.onSelect = onSelect } }
    init(item: GuestStreamViews.GalleryItem, pin: @escaping () -> Void) {
        super.init(frame: .zero)
        video.contentMode = .scaleAspectFit
        viewport = StreamViewport(video: video, state: StreamViewportState(), zoomable: false,
            name: item.name, showInfo: true, microphoneOn: item.microphoneOn, pinned: false,
            watermark: item.watermark, showsPlaceholder: !item.active, onPin: pin)
        addSubview(viewport)
        viewport.pinInHeader = true
        status.textColor = .lightGray; status.font = .preferredFont(forTextStyle: .caption1)
        status.numberOfLines = 0; status.textAlignment = .center
        status.isUserInteractionEnabled = false
        addSubview(status)
        energy = MediaEnergyBudget.shared.$pressure.sink { [weak self] _ in
            Task { @MainActor in self?.processor.setFrameRate(MediaEnergyBudget.shared.inlineFPS) }
        }
        processor.setFrameRate(MediaEnergyBudget.shared.inlineFPS)
        processor.setMainDeliveryEnabled(false)
        update(item, pin: pin)
    }
    required init?(coder: NSCoder) { nil }
    func update(_ item: GuestStreamViews.GalleryItem, pin: @escaping () -> Void) {
        if renderer !== item.renderer || mediaActive != item.active {
            stop(); renderer = item.renderer; video.clear(); hasFrame = false
        }
        mediaActive = item.active
        localCamera = item.isLocalCamera
        video.mirrored = item.mirrored
        viewport.updatePresentation(name: item.name, showInfo: true, microphoneOn: item.microphoneOn,
            watermark: item.watermark, zoomable: false, placeholderText: item.name,
            isSpeaking: item.speaking)
        viewport.updatePin(name: item.name, isShare: item.id.isShare, pinned: false, onPin: pin)
        viewport.setMediaActive(item.active)
        status.text = item.active ? L("Waiting for video…") : nil
        status.isHidden = !item.active || hasFrame
        updateAudio(ParticipantAudioState(microphoneOn: item.microphoneOn, speaking: item.speaking))
        accessibilityIdentifier = "gallery." + item.id.participant + (item.id.isShare ? ".screen" : ".camera")
        refreshDemand()
    }
    func updateAudio(_ state: ParticipantAudioState) {
        viewport.updateMicrophone(on: state.microphoneOn, speaking: state.speaking)
        MeetingTileAppearance.update(self, speaking: state.speaking)
        accessibilityValue = state.speaking ? L("Speaking") : nil
    }
    func setVisible(_ value: Bool) { visible = value; refreshDemand() }
    private func refreshDemand() {
        guard visible, mediaActive, let renderer else { stop(); return }
        if localCamera, let source = GuestCaptureDeviceObserver.cameraPreview() {
            processor.setEnabled(false); tap?.invalidate(); tap = nil
            video.setCameraPreview(source, enabled: visible)
            hasFrame = true; status.isHidden = true
            return
        }
        if tap?.matches(renderer) != true {
            stop()
            let delivery = video.makeFrameDelivery { [weak self] _, _ in
                guard let self, self.visible, self.mediaActive else { return }
                self.hasFrame = true; self.status.isHidden = true
            }
            delivery.setActive(true)
            processor.setFrameDeliveries([delivery])
            let source = processor.replaceSource(), processor = processor
            tap = GuestVideoFrameTap(view: renderer) { [weak processor] frame in processor?.submit(frame, source: source) }
        }
        processor.setEnabled(tap != nil)
    }
    private func stop() { processor.setEnabled(false); processor.setFrameDeliveries([]); video.clear(); tap?.invalidate(); tap = nil; video.setCameraPreview(nil) }
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
    private var items: [GuestStreamViews.GalleryItem] = []
    private var speaker: (id: String?, available: Bool)?
    private var observers: [NSObjectProtocol] = []
    private(set) var page = 0
    private(set) var pagination: MeetingTileLayout.GalleryPage?
    private var arranging = false
    var onPageChanged: (() -> Void)?
#if DEBUG
    var evidenceForTesting: [[String: Any]] { tiles.values.map(\.evidenceForTesting) }
#endif
    var onPin: ((GuestStreamViews.PinTarget) -> Void)?
    var onInteraction: (() -> Void)?
    var onToggleControls: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self; backgroundColor = .black; alwaysBounceVertical = false
        isPagingEnabled = true; showsHorizontalScrollIndicator = false
        accessibilityIdentifier = "Meeting grid"
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDemand() }
            })
        }
    }
    required init?(coder: NSCoder) { nil }
    func update(_ items: [GuestStreamViews.GalleryItem]) {
        self.items = items
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
                tile.onSelect = pin
                tiles[item.id] = tile; addSubview(tile)
            }
        }
        updateAudio()
        setNeedsLayout()
    }
    func setSpeaker(_ id: String?, available: Bool) {
        speaker = (id, available)
        updateAudio()
    }
    private func updateAudio() {
        for item in items {
            let speaking = speaker.map { $0.id == item.id.participant } ?? item.speaking
            tiles[item.id]?.updateAudio(ParticipantAudioState(microphoneOn: item.microphoneOn,
                speaking: speaking, receptionAvailable: speaker?.available ?? true))
        }
    }
    func setActive(_ value: Bool) { active = value; refreshDemand() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let previous = pagination
        let layout = MeetingTileLayout.gallery(count: order.count, size: bounds.size,
            largeText: traitCollection.preferredContentSizeCategory.isAccessibilityCategory)
        arranging = true
        if let previous, previous.capacity != layout.capacity {
            page = page * previous.capacity / layout.capacity
        }
        pagination = layout
        page = min(page, layout.pageCount - 1)
        for (key, frame) in zip(order, layout.frames) { tiles[key]?.frame = frame }
        let next = CGSize(width: layout.contentWidth, height: bounds.height)
        if contentSize != next { contentSize = next }
        if previous?.capacity != layout.capacity || previous?.contentWidth != layout.contentWidth {
            setContentOffset(CGPoint(x: CGFloat(page) * bounds.width, y: 0), animated: false)
        }
        arranging = false
        if previous?.capacity != layout.capacity || previous?.contentWidth != layout.contentWidth { onPageChanged?() }
        refreshDemand()
    }
    func movePage(_ step: Int) {
        guard let pagination else { return }
        page = max(0, min(pagination.pageCount - 1, page + step))
        setContentOffset(CGPoint(x: CGFloat(page) * bounds.width, y: 0), animated: true)
        onPageChanged?()
    }
    private func refreshDemand() {
        let enabled = active && window != nil && UIApplication.shared.applicationState != .background
        for tile in tiles.values { tile.setVisible(enabled && bounds.intersects(tile.frame)) }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); refreshDemand() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        refreshDemand()
        guard !arranging, bounds.width > 0, let pagination else { return }
        let next = max(0, min(pagination.pageCount - 1, Int((contentOffset.x / bounds.width).rounded())))
        if page != next { page = next; onPageChanged?() }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { onInteraction?() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
