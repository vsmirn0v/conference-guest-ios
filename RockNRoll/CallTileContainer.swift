import ConferenceCore
import UIKit

extension MeetingLayoutMode {
    var title: String { self == .grid ? L("Gallery") : L("Focus") }
    var symbol: String { self == .grid ? "square.grid.2x2" : "rectangle.inset.filled" }
}

/// Keeps renderer views mounted while assigning adaptive stage/grid geometry.
final class CallTileContainer: UIView {
    private var frames: [CGRect] = []
    private var height: NSLayoutConstraint?
    private var width: NSLayoutConstraint?
    private(set) var pagination: MeetingTileLayout.GalleryPage?
    var arrangedSubviews: [UIView] { subviews }
    func addArrangedSubview(_ view: UIView) { view.translatesAutoresizingMaskIntoConstraints = true; addSubview(view) }
    func insertArrangedSubview(_ view: UIView, at index: Int) {
        view.translatesAutoresizingMaskIntoConstraints = true; insertSubview(view, at: index)
    }
    func arrange(size: CGSize, mode: MeetingLayoutMode) {
        pagination = mode == .grid ? MeetingTileLayout.gallery(count: subviews.count, size: size,
            largeText: traitCollection.preferredContentSizeCategory.isAccessibilityCategory) : nil
        frames = pagination?.frames ?? MeetingTileLayout.frames(count: subviews.count, size: size, mode: mode)
        let contentWidth = pagination?.contentWidth ?? size.width
        if width == nil { width = widthAnchor.constraint(equalToConstant: contentWidth); width?.isActive = true }
        else { width?.constant = contentWidth }
        let contentHeight = max(size.height, frames.map(\.maxY).max() ?? 0)
        if height == nil { height = heightAnchor.constraint(equalToConstant: contentHeight); height?.isActive = true }
        else { height?.constant = contentHeight }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        for (view, frame) in zip(subviews, frames) { view.frame = frame }
    }
}
