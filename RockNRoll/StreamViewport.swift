import CoreMedia
import UIKit

/// Owned by the stream, so replacing a participant tile does not discard its viewport.
final class StreamViewportState {
    var scale: CGFloat = 1
    var center = CGPoint(x: 0.5, y: 0.5)
    fileprivate var owner = UUID()
}

final class StreamViewport: UIView, UIScrollViewDelegate, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
    private let scroll = UIScrollView()
    private let content = UIView()
    private let video: UIView
    private var correctedVideo: GuestSampleBufferView?
    private let mediaPlaceholder = UILabel()
    private let participantInfo = UILabel()
    private let watermarkLabel = UILabel()
    private let state: StreamViewportState
    private let owner = UUID()
    private var viewportSize = CGSize.zero
    private var restoring = false
    private var infoBottom: NSLayoutConstraint?
    private let pinButton = UIButton(type: .system)
    private let zoomControls = UIStackView()
    private var pinAction: (() -> Void)?
    private var pinName = ""
    private var pinIsShare = false
    private var pinnedLocally = false
    var onMenuVisibilityChanged: ((Bool) -> Void)?
    var onBrowse: ((Int) -> Void)?
    var onToggleControls: (() -> Void)?
    var controlsHidden = false { didSet {
        guard oldValue != controlsHidden else { return }
        pinButton.isHidden = controlsHidden || pinAction == nil
        zoomControls.isHidden = controlsHidden
        participantInfo.alpha = controlsHidden ? 0 : 1
    } }
    var zoomScale: CGFloat { scroll.zoomScale }
    var onVisibilityChanged: (() -> Void)?
    var rendererView: UIView { video }

    init(video: UIView, state: StreamViewportState, zoomable: Bool,
         name: String, showInfo: Bool, microphoneOn: Bool, pinned: Bool,
         watermark: String?, showsPlaceholder: Bool = false,
         placeholderText: String? = nil,
         onPin: (() -> Void)? = nil) {
        self.video = video
        self.state = state
        super.init(frame: .zero)
        state.owner = owner
        clipsToBounds = true
        backgroundColor = .black
        tintColor = .white
        scroll.delegate = self
        scroll.panGestureRecognizer.isEnabled = false
        CallStageLayout.register(self)
        let single = UITapGestureRecognizer(target: self, action: #selector(tappedStage))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTappedStage))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        single.delegate = self; double.delegate = self
        single.cancelsTouchesInView = false
        addGestureRecognizer(single); addGestureRecognizer(double)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedStage(_:)))
            swipe.direction = direction; swipe.delegate = self
            addGestureRecognizer(swipe)
        }
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = zoomable ? 5 : 1
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        pinAction = onPin
        pinName = name
        pinIsShare = false
        pinnedLocally = pinned
        if zoomable {
            scroll.isAccessibilityElement = true
            scroll.accessibilityIdentifier = "Shared screen viewport"
            scroll.accessibilityLabel = L("Pinch to zoom screen share")
            scroll.accessibilityValue = "100%"
        }
        addSubview(scroll)
        scroll.addSubview(content)
        video.translatesAutoresizingMaskIntoConstraints = true
        video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.addSubview(video)
        pinButton.configuration = .tinted()
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        pinButton.addAction(UIAction { [weak self] _ in
            self?.pinAction?()
        }, for: .touchUpInside)
        addSubview(pinButton)
        addInteraction(UIContextMenuInteraction(delegate: self))
        NSLayoutConstraint.activate([
            pinButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pinButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            pinButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            pinButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        if zoomable {
            zoomControls.axis = .horizontal
            zoomControls.spacing = 4
            zoomControls.translatesAutoresizingMaskIntoConstraints = false
            for (title, symbol, action) in [
                (L("Zoom out"), "minus.magnifyingglass", -1),
                (L("Fit shared screen at 100%"), "arrow.down.right.and.arrow.up.left", 0),
                (L("Zoom in"), "plus.magnifyingglass", 1)
            ] {
                let button = UIButton(type: .system)
                button.configuration = .tinted()
                button.configuration?.image = UIImage(systemName: symbol)
                button.accessibilityLabel = title
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
                button.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    let scale = action == 0 ? 1 : self.scroll.zoomScale * (action > 0 ? 1.5 : 1 / 1.5)
                    self.scroll.setZoomScale(min(self.scroll.maximumZoomScale,
                                                 max(self.scroll.minimumZoomScale, scale)), animated: true)
                }, for: .touchUpInside)
                zoomControls.addArrangedSubview(button)
            }
            addSubview(zoomControls)
            NSLayoutConstraint.activate([
                zoomControls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                zoomControls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -44)
            ])
        }
        updatePin(name: name, isShare: false, pinned: pinned, onPin: onPin)
        mediaPlaceholder.text = placeholderText ?? name
        mediaPlaceholder.font = .preferredFont(forTextStyle: .title2)
        mediaPlaceholder.textColor = .white
        mediaPlaceholder.numberOfLines = 0
        mediaPlaceholder.textAlignment = .center
        mediaPlaceholder.isHidden = true
        mediaPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mediaPlaceholder)
        NSLayoutConstraint.activate([
            mediaPlaceholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            mediaPlaceholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            mediaPlaceholder.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9)
        ])
        setMediaActive(!showsPlaceholder)

        do {
            let label = participantInfo
            label.font = .preferredFont(forTextStyle: .caption1)
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.65)
            label.layer.cornerRadius = 6
            label.clipsToBounds = true
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            let bottom = label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
            infoBottom = bottom
            label.lineBreakMode = .byTruncatingTail
            label.accessibilityIdentifier = "Participant name"
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                bottom,
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
            ])
        }
        do {
            let label = watermarkLabel
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = UIColor.white.withAlphaComponent(0.65)
            label.font = .preferredFont(forTextStyle: .headline)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9)
            ])
        }
        updatePresentation(name: name, showInfo: showInfo, microphoneOn: microphoneOn,
                           pinned: pinned, watermark: watermark, zoomable: zoomable,
                           placeholderText: placeholderText)
    }

    required init?(coder: NSCoder) { nil }

    /// Participant metadata changes without changing the decoded stream. Keep
    /// the corrected surface and scroll state while updating its visible labels.
    func updatePresentation(name: String, showInfo: Bool, microphoneOn: Bool,
                            pinned: Bool, watermark: String?, zoomable: Bool,
                            placeholderText: String? = nil) {
        participantInfo.text = "  \(name)\(microphoneOn ? "" : L(" · Mic off"))\(pinned ? L(" · Pinned") : "")  "
        participantInfo.isHidden = !showInfo
        mediaPlaceholder.text = placeholderText ?? name
        watermarkLabel.text = watermark
        watermarkLabel.isHidden = watermark == nil
        scroll.maximumZoomScale = zoomable ? 5 : 1
        if scroll.zoomScale > scroll.maximumZoomScale {
            scroll.setZoomScale(scroll.maximumZoomScale, animated: false)
        }
    }

    func updatePin(name: String, isShare: Bool, pinned: Bool, onPin: (() -> Void)?) {
        pinName = name
        pinIsShare = isShare
        pinnedLocally = pinned
        pinAction = onPin
        pinButton.isHidden = controlsHidden || onPin == nil
        pinButton.configuration?.image = UIImage(systemName: pinned ? "pin.fill" : "pin")
        pinButton.accessibilityLabel = "\(pinned ? L("Unpin") : L("Pin")) \(name) \(isShare ? L("screen share") : L("video"))"
        pinButton.accessibilityHint = L("Changes only your view")
        pinButton.showsLargeContentViewer = true
        pinButton.largeContentTitle = pinButton.accessibilityLabel
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let pinAction else { return nil }
        let label = "\(pinnedLocally ? L("Unpin") : L("Pin")) \(pinName) \(pinIsShare ? L("screen share") : L("video"))"
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: label,
                image: UIImage(systemName: self.pinnedLocally ? "pin.slash" : "pin")) { _ in
                    pinAction()
                }])
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        onMenuVisibilityChanged?(true)
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        if let animator { animator.addCompletion { [weak self] in self?.onMenuVisibilityChanged?(false) } }
        else { onMenuVisibilityChanged?(false) }
    }

    @objc private func tappedStage() {
        if let onToggleControls { onToggleControls() }
        else { CallStageLayout.record(for: window)?.toggleControls() }
    }
    @objc private func doubleTappedStage() {
        guard scroll.maximumZoomScale > 1 else { return }
        scroll.setZoomScale(scroll.zoomScale > 1.01 ? 1 : 2, animated: true)
    }
    @objc private func swipedStage(_ gesture: UISwipeGestureRecognizer) {
        onBrowse?(gesture.direction == .left ? 1 : -1)
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UISwipeGestureRecognizer {
            return onBrowse != nil && !pinnedLocally && scroll.zoomScale <= 1.01
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var target = touch.view
        while let current = target {
            if current is UIControl { return false }
            target = current.superview
        }
        return true
    }

    func containsRenderer(_ renderer: UIView) -> Bool { renderer.superview === content }

    func setMediaActive(_ active: Bool) {
        if video.isHidden == !active { return }
        video.isHidden = !active
        mediaPlaceholder.isHidden = active
        if !active { clearCorrectedVideo() }
    }

    func showCorrectedVideo(_ sample: CMSampleBuffer, rotation: Int) {
        guard !video.isHidden else { return }
        if correctedVideo == nil {
            let overlay = GuestSampleBufferView()
            overlay.isHidden = true
            overlay.isUserInteractionEnabled = false
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            content.addSubview(overlay)
            correctedVideo = overlay
        }
        guard let correctedVideo else { return }
        correctedVideo.frame = content.bounds
        if correctedVideo.enqueue(sample, rotation: rotation) {
            correctedVideo.isHidden = false
        }
    }

    func clearCorrectedVideo() {
        correctedVideo?.clear()
        correctedVideo?.removeFromSuperview()
        correctedVideo = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onVisibilityChanged?()
    }

    // The SDK measures custom tiles through sizeThatFits; UIView's default zero
    // size would prevent the supplied video renderer from receiving any bounds.
    override func sizeThatFits(_ size: CGSize) -> CGSize { size }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let record = CallStageLayout.record(for: window), let window {
            let visible = convert(record.rect, from: window).intersection(bounds)
            if !visible.isNull { infoBottom?.constant = min(-8, visible.maxY - bounds.maxY - 8) }
            controlsHidden = record.hidden
        } else { infoBottom?.constant = -8 }
        guard bounds.width > 0, bounds.height > 0, bounds.size != viewportSize else { return }
        // Only a real viewport resize changes the base canvas. Media and participant
        // updates can lay out this view repeatedly without resetting a user's pinch.
        let scale = min(max(state.scale, scroll.minimumZoomScale), scroll.maximumZoomScale)
        let center = state.center
        restoring = true
        scroll.setZoomScale(1, animated: false)
        scroll.frame = bounds
        viewportSize = bounds.size
        content.frame = CGRect(origin: .zero, size: viewportSize)
        if video.superview === content { video.frame = content.bounds }
        correctedVideo?.frame = content.bounds
        scroll.contentSize = viewportSize
        scroll.setZoomScale(scale, animated: false)
        let size = scroll.contentSize
        scroll.contentOffset = CGPoint(
            x: min(max(center.x * size.width - bounds.width / 2, 0), max(size.width - bounds.width, 0)),
            y: min(max(center.y * size.height - bounds.height / 2, 0), max(size.height - bounds.height, 0)))
        restoring = false
        updateAccessibility()
        onVisibilityChanged?()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        rememberViewport()
        updateAccessibility()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { rememberViewport() }

    private func rememberViewport() {
        guard !restoring, state.owner == owner, window != nil,
              viewportSize != .zero, scroll.contentSize.width > 0, scroll.contentSize.height > 0 else { return }
        state.scale = scroll.zoomScale
        state.center = CGPoint(
            x: (scroll.contentOffset.x + scroll.bounds.width / 2) / scroll.contentSize.width,
            y: (scroll.contentOffset.y + scroll.bounds.height / 2) / scroll.contentSize.height)
    }

    private func updateAccessibility() {
        scroll.accessibilityValue = "\(Int((scroll.zoomScale * 100).rounded()))%"
        scroll.panGestureRecognizer.isEnabled = scroll.zoomScale > 1.01
    }
}
