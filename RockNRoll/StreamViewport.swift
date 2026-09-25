import UIKit

/// Owned by the stream, so replacing a participant tile does not discard its viewport.
final class StreamViewportState {
    var scale: CGFloat = 1
    var center = CGPoint(x: 0.5, y: 0.5)
    fileprivate var owner = UUID()
}

final class StreamViewport: UIView, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private let content = UIView()
    private let video: UIView
    private let state: StreamViewportState
    private let owner = UUID()
    private var viewportSize = CGSize.zero
    private var restoring = false

    init(video: UIView, state: StreamViewportState, zoomable: Bool,
         name: String, showInfo: Bool, microphoneOn: Bool, pinned: Bool,
         watermark: String?, showsPlaceholder: Bool = false) {
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

        if showsPlaceholder {
            let label = UILabel()
            label.text = name
            label.font = .preferredFont(forTextStyle: .title2)
            label.textColor = .white
            label.numberOfLines = 0
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9)
            ])
        }

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

    func containsRenderer(_ renderer: UIView) -> Bool { renderer.superview === content }

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
        scroll.contentSize = viewportSize
        scroll.setZoomScale(scale, animated: false)
        let size = scroll.contentSize
        scroll.contentOffset = CGPoint(
            x: min(max(center.x * size.width - bounds.width / 2, 0), max(size.width - bounds.width, 0)),
            y: min(max(center.y * size.height - bounds.height / 2, 0), max(size.height - bounds.height, 0)))
        restoring = false
        updateAccessibility()
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
