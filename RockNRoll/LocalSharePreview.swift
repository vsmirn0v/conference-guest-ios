import Combine
import CoreImage
import UIKit

/// A bounded local confidence preview, never a claim of remote delivery.
@MainActor
final class LocalSharePreview: ObservableObject {
    enum Source: String {
        case selected = "Selected content", screen = "Entire screen", window = "Shared window", application = "Shared application"
        var title: String { L(rawValue) }
    }
    @Published private(set) var active = false
    @Published private(set) var image: UIImage?
    @Published private(set) var source: Source = .screen
    @Published private(set) var live = false
    @Published var hidden = false
    @Published private(set) var paused = false
    private var enlarged = false
    private var refreshRequested = false
    private var publishedPolicy: Bool?
    private(set) var foreground = true
    var ownSceneIsNotCaptured: (() -> Bool)?
    var onCapturePolicyChanged: ((Bool) -> Void)?
    private var lastFrameTime: TimeInterval = -.infinity
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private var observations: [NSObjectProtocol] = []
    let isMac: Bool

    init(isMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac, observeLifecycle: Bool = true) {
        self.isMac = isMac
        if observeLifecycle {
            foreground = UIApplication.shared.applicationState != .background
            for (name, value) in [(UIApplication.didEnterBackgroundNotification, false),
                                  (UIApplication.willEnterForegroundNotification, true)] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in MainActor.assumeIsolated { self?.setForeground(value) }
                })
            }
        }
    }

    var acceptsFrames: Bool {
        guard active, !hidden else { return false }
        if refreshRequested { return true }
        if !isMac { return !foreground }
        // The compact thumbnail shrinks recursion rather than amplifying it.
        // Enlarging a captured/unknown scene pauses the feedback loop.
        return foreground && !paused && (!enlarged || ownSceneIsNotCaptured?() == true)
    }

    func togglePaused() { paused.toggle(); refreshPolicy() }
    func setEnlarged(_ value: Bool) { enlarged = value; refreshPolicy() }
    func refreshFrame() { refreshRequested = true; lastFrameTime = -.infinity; refreshPolicy() }

    func begin(source: Source = .screen) {
        guard !active else { return }
        self.source = source
        active = true
        paused = false
        enlarged = false
        refreshRequested = false
        publishedPolicy = nil
        hidden = false
        lastFrameTime = -.infinity
        refreshPolicy()
    }

    func end() {
        active = false
        image = nil
        live = false
        hidden = false
        lastFrameTime = -.infinity
        paused = false
        enlarged = false
        refreshRequested = false
        publishedPolicy = nil
        refreshPolicy()
    }

    func setForeground(_ value: Bool) {
        foreground = value
        refreshPolicy()
    }

    func refreshPolicy() {
        let nowLive = active && foreground && isMac && !hidden && !paused &&
            (!enlarged || ownSceneIsNotCaptured?() == true)
        if live != nowLive { live = nowLive }
        let wanted = acceptsFrames
        if publishedPolicy != wanted {
            publishedPolicy = wanted
            onCapturePolicyChanged?(wanted)
        }
    }

    func accept(_ pixelBuffer: CVPixelBuffer, rotation: Int = 0,
                time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        refreshPolicy()
        guard acceptsFrames, time - lastFrameTime >= (isMac ? 0.5 : 1) else { return }
        lastFrameTime = time
        var input = CIImage(cvPixelBuffer: pixelBuffer)
        switch rotation {
        case 90: input = input.oriented(.right)
        case 180: input = input.oriented(.down)
        case 270: input = input.oriented(.left)
        default: break
        }
        let extent = input.extent
        let scale = min(1, 640 / max(extent.width, extent.height))
        input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let thumbnail = context.createCGImage(input, from: input.extent) {
            image = UIImage(cgImage: thumbnail)
            refreshRequested = false
            refreshPolicy()
        }
    }

    func acceptThumbnail(_ thumbnail: UIImage) {
        refreshPolicy()
        guard acceptsFrames else { return }
        image = thumbnail
        refreshRequested = false
        refreshPolicy()
    }

    deinit { observations.forEach(NotificationCenter.default.removeObserver) }
}

@MainActor
final class LocalSharePreviewCard: UIView {
    private let model: LocalSharePreview
    private let imageButton = UIButton(type: .system)
    private let thumbnailView = UIImageView()
    private var thumbnailHeight: NSLayoutConstraint!
    private let title = UIButton(type: .system)
    private let visibility = UIButton(type: .system)
    private let pause = UIButton(type: .system)
    private let refresh = UIButton(type: .system)
    private let detail = UILabel()
    private var subscriptions = Set<AnyCancellable>()
    var onStop: (() -> Void)?
    var onLayoutChanged: (() -> Void)?
    private var preferredHeight: CGFloat = 0
    private var enlarged: UIViewController?
    private var lastLandscape: Bool?

    init(model: LocalSharePreview) {
        self.model = model
        super.init(frame: .zero)
        backgroundColor = UIColor(red: 0.10, green: 0.12, blue: 0.17, alpha: 0.96)
        layer.cornerRadius = 12
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        title.setTitle(L("Preview"), for: .normal)
        title.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        title.setTitleColor(.white, for: .normal)
        title.accessibilityLabel = L("Enlarge local sharing preview")
        title.addAction(UIAction { [weak self] _ in self?.enlarge() }, for: .touchUpInside)
        visibility.tintColor = .lightGray
        visibility.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.model.hidden.toggle()
            self.model.refreshPolicy()
        }, for: .touchUpInside)
        pause.tintColor = .lightGray
        pause.isHidden = !model.isMac
        pause.addAction(UIAction { [weak model] _ in model?.togglePaused() }, for: .touchUpInside)
        refresh.tintColor = .lightGray
        refresh.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        refresh.accessibilityLabel = L("Refresh sharing preview")
        refresh.addAction(UIAction { [weak model] _ in model?.refreshFrame() }, for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [title, pause, refresh, visibility])
        header.spacing = 4
        accessibilityIdentifier = "Local sharing preview card"
        thumbnailView.contentMode = .scaleAspectFit
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        imageButton.addSubview(thumbnailView)
        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: imageButton.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: imageButton.trailingAnchor),
            thumbnailView.topAnchor.constraint(equalTo: imageButton.topAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: imageButton.bottomAnchor)
        ])
        thumbnailHeight = imageButton.heightAnchor.constraint(equalToConstant: 82)
        imageButton.backgroundColor = .black
        imageButton.clipsToBounds = true
        imageButton.accessibilityLabel = L("Local shared screen thumbnail")
        imageButton.addAction(UIAction { [weak self] _ in self?.enlarge() }, for: .touchUpInside)
        detail.font = .preferredFont(forTextStyle: .caption2)
        detail.textColor = .lightGray
        detail.numberOfLines = 2
        let stop = UIButton(type: .system)
        stop.setTitle(L("Stop Sharing"), for: .normal)
        stop.tintColor = .systemOrange
        stop.accessibilityLabel = L("Stop local screen sharing")
        stop.addAction(UIAction { [weak self] _ in self?.onStop?() }, for: .touchUpInside)
        let column = UIStackView(arrangedSubviews: [header, imageButton, detail, stop])
        column.axis = .vertical
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            visibility.widthAnchor.constraint(equalToConstant: 44),
            pause.widthAnchor.constraint(equalToConstant: 44),
            refresh.widthAnchor.constraint(equalToConstant: 44),
            header.heightAnchor.constraint(equalToConstant: 44),
            stop.heightAnchor.constraint(equalToConstant: 44)
        ])
        model.ownSceneIsNotCaptured = { [weak self] in
            guard let self, self.window != nil else { return false }
            // Designed-for-iPad on Mac does not reliably expose capture membership.
            if self.model.isMac { return false }
            if #available(iOS 17, *) { return self.traitCollection.sceneCaptureState == .inactive }
            return false
        }
        model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.render() }
        }.store(in: &subscriptions)
        render()
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshLayout()
    }
    func refreshLayout() {
        let landscape = !model.isMac && traitCollection.verticalSizeClass == .compact
        if lastLandscape != landscape { render() }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); model.refreshPolicy(); refreshLayout() }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshLayout()
    }

    private func render() {
        accessibilityElementsHidden = !model.active
        isHidden = !model.active
        let landscape = !model.isMac && traitCollection.verticalSizeClass == .compact
        lastLandscape = landscape
        let showImage = !model.hidden && model.image != nil && !landscape
        if !showImage { thumbnailHeight.isActive = false }
        imageButton.isHidden = !showImage
        if showImage { thumbnailHeight.isActive = true }
        thumbnailView.image = model.image
        title.isEnabled = model.image != nil
        pause.setImage(UIImage(systemName: model.paused ? "play.fill" : "pause.fill"), for: .normal)
        pause.accessibilityLabel = model.paused ? L("Resume sharing preview") : L("Pause sharing preview")
        visibility.setImage(UIImage(systemName: model.hidden ? "eye" : "eye.slash"), for: .normal)
        visibility.accessibilityLabel = model.hidden ? L("Show local preview") : L("Hide local preview")
        if model.image == nil {
            let hint = model.isMac ? (model.live ? L("Waiting for preview…") : L("Preview paused to avoid repetition")) :
                L("Switch apps to share content")
            detail.text = "\(model.source.title)\n\(hint)"
        } else {
            detail.text = model.live ? L("%@ · Live preview", model.source.title) :
                L("Last shared frame · Preview paused")
        }
        if !model.active { enlarged?.dismiss(animated: false); enlarged = nil }
        let height = systemLayoutSizeFitting(CGSize(width: max(216, bounds.width), height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        if height != preferredHeight { preferredHeight = height; onLayoutChanged?() }
    }

    private func enlarge() {
        guard model.image != nil, enlarged == nil else { return }
        guard var controller = window?.rootViewController else { return }
        while let presented = controller.presentedViewController { controller = presented }
        guard !controller.isBeingDismissed else { return }
        let panel = LocalSharePreviewPanel(model: model, onStop: { [weak self] in self?.onStop?() })
        model.setEnlarged(true)
        panel.onClose = { [weak self] in self?.model.setEnlarged(false); self?.enlarged = nil }
        panel.modalPresentationStyle = .pageSheet
        panel.sheetPresentationController?.detents = [.large()]
        enlarged = panel
        controller.present(panel, animated: true)
    }
}

@MainActor
private final class LocalSharePreviewPanel: UIViewController, UIScrollViewDelegate, UIAdaptivePresentationControllerDelegate {
    private let model: LocalSharePreview
    private let onStop: () -> Void
    private let imageView = UIImageView()
    private let detail = UILabel()
    private var subscriptions = Set<AnyCancellable>()
    var onClose: (() -> Void)?
    init(model: LocalSharePreview, onStop: @escaping () -> Void) {
        self.model = model; self.onStop = onStop
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        view.backgroundColor = .black
        presentationController?.delegate = self
        let close = UIButton(type: .system)
        close.setTitle(L("Close"), for: .normal)
        close.accessibilityLabel = L("Close preview")
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true); self?.onClose?() }, for: .touchUpInside)
        let stop = UIButton(type: .system)
        stop.setTitle(L("Stop"), for: .normal)
        stop.accessibilityLabel = L("Stop Sharing")
        stop.tintColor = .systemOrange
        stop.addAction(UIAction { [weak self] _ in self?.onStop() }, for: .touchUpInside)
        let refresh = UIButton(type: .system)
        refresh.setTitle(L("Refresh"), for: .normal)
        refresh.accessibilityLabel = L("Refresh sharing preview")
        refresh.addAction(UIAction { [weak model] _ in model?.refreshFrame() }, for: .touchUpInside)
        let bar = UIStackView(arrangedSubviews: [close, refresh, stop])
        bar.distribution = .fillEqually
        detail.textColor = .lightGray
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.numberOfLines = 0
        detail.textAlignment = .center
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 4; scroll.delegate = self
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(imageView)
        for item in [bar, scroll, detail] { item.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(item) }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 48),
            detail.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            detail.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -12),
            scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        model.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.render() } }.store(in: &subscriptions)
        render()
    }
    private func render() {
        imageView.image = model.image
        detail.text = model.live ? L("Local preview · Remote delivery may differ.") :
            L("Last shared frame · Preview paused while this app is visible to avoid a repeating screen.")
        if !model.active { dismiss(animated: false); onClose?() }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.setEnlarged(false)
        onClose?()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onClose?() }
}
