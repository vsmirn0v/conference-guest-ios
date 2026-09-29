import CoreMedia
import UIKit

/// Owned by the stream, so replacing a participant tile does not discard its viewport.
final class StreamViewportState {
    var scale: CGFloat = 1
    var center = CGPoint(x: 0.5, y: 0.5)
    fileprivate var owner = UUID()
}

final class StreamViewport: UIView, UIScrollViewDelegate, UIContextMenuInteractionDelegate {
    private let scroll = UIScrollView()
    private let content = UIView()
    private let video: UIView
    private var correctedVideo: GuestSampleBufferView?
    private let mediaPlaceholder = UILabel()
    private let state: StreamViewportState
    private let owner = UUID()
    private var viewportSize = CGSize.zero
    private var restoring = false
    private let pinButton = UIButton(type: .system)
    private let zoomControls = UIStackView()
    private var pinAction: (() -> Void)?
    private var pinName = ""
    private var pinIsShare = false
    private var pinnedLocally = false
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
        scroll.delegate = self
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
            scroll.accessibilityLabel = "Pinch to zoom screen share"
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
                ("Zoom out", "minus.magnifyingglass", -1),
                ("Fit shared screen", "arrow.down.right.and.arrow.up.left", 0),
                ("Zoom in", "plus.magnifyingglass", 1)
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
                zoomControls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
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

        if showInfo {
            let label = UILabel()
            label.text = "  \(name)\(microphoneOn ? "" : " · Mic off")\(pinned ? " · Pinned" : "")  "
            label.font = .preferredFont(forTextStyle: .caption1)
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.65)
            label.layer.cornerRadius = 6
            label.clipsToBounds = true
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
            ])
        }
        if let watermark {
            let label = UILabel()
            label.text = watermark
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
    }

    required init?(coder: NSCoder) { nil }

    func updatePin(name: String, isShare: Bool, pinned: Bool, onPin: (() -> Void)?) {
        pinName = name
        pinIsShare = isShare
        pinnedLocally = pinned
        pinAction = onPin
        pinButton.isHidden = onPin == nil
        pinButton.configuration?.image = UIImage(systemName: pinned ? "pin.fill" : "pin")
        pinButton.accessibilityLabel = "\(pinned ? "Unpin" : "Pin") \(name) \(isShare ? "screen share" : "video")"
        pinButton.accessibilityHint = "Changes only your view"
        pinButton.showsLargeContentViewer = true
        pinButton.largeContentTitle = pinButton.accessibilityLabel
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let pinAction else { return nil }
        let label = "\(pinnedLocally ? "Unpin" : "Pin") \(pinName) \(pinIsShare ? "screen share" : "video")"
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: label,
                image: UIImage(systemName: self.pinnedLocally ? "pin.slash" : "pin")) { _ in
                    pinAction()
                }])
        }
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
    }
}
