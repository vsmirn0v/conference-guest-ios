import UIKit

/// Geometry belongs to the visible call window, independently of media providers.
struct CallPresentationGeometry {
    let header: CGRect
    let toolbar: CGRect
    let stage: CGRect
    let rail: Bool

    init(bounds: CGRect, insets: UIEdgeInsets, headerHeight: CGFloat,
         toolbarHeight: CGFloat = 68, hidden: Bool, largeText: Bool = false, allowsRail: Bool = true) {
        let safe = bounds.inset(by: insets).insetBy(dx: 8, dy: 4)
        rail = allowsRail && safe.width > safe.height && safe.height < 480 && safe.height >= 284
        if hidden {
            header = .zero; toolbar = .zero; stage = safe
            return
        }
        if rail {
            let railWidth: CGFloat = largeText ? min(296, safe.width * 0.45) : 68
            toolbar = CGRect(x: safe.maxX - railWidth, y: safe.minY, width: railWidth, height: safe.height)
            let width = max(0, safe.width - railWidth - 8)
            header = CGRect(x: safe.minX + max(0, (width - 440) / 2), y: safe.minY,
                            width: min(440, width), height: headerHeight)
            stage = CGRect(x: safe.minX, y: header.maxY + 6, width: width,
                           height: max(0, safe.maxY - header.maxY - 6))
        } else {
            let width = min(520, safe.width)
            toolbar = CGRect(x: safe.midX - width / 2, y: safe.maxY - toolbarHeight,
                             width: width, height: toolbarHeight)
            header = CGRect(x: safe.midX - min(440, safe.width) / 2, y: safe.minY,
                            width: min(440, safe.width), height: headerHeight)
            stage = CGRect(x: safe.minX, y: header.maxY + 6, width: safe.width,
                           height: max(0, toolbar.minY - header.maxY - 14))
        }
    }
}

/// All captioned actions share an optical icon center and a caption baseline.
final class AlignedCallButton: UIButton {
    var onMenuVisibilityChanged: ((Bool) -> Void)?
    private let symbolView = UIImageView()
    private let caption = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        symbolView.contentMode = .scaleAspectFit
        symbolView.isUserInteractionEnabled = false
        caption.textAlignment = .center
        caption.numberOfLines = 1
        caption.lineBreakMode = .byTruncatingTail
        caption.adjustsFontForContentSizeCategory = true
        caption.isUserInteractionEnabled = false
        addSubview(symbolView); addSubview(caption)
    }
    required init?(coder: NSCoder) { nil }
    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        onMenuVisibilityChanged?(true)
    }
    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        if let animator { animator.addCompletion { [weak self] in self?.onMenuVisibilityChanged?(false) } }
        else { onMenuVisibilityChanged?(false) }
    }
    override var intrinsicContentSize: CGSize { CGSize(width: 44, height: 60) }
    override func layoutSubviews() {
        super.layoutSubviews()
        imageView?.isHidden = true; titleLabel?.isHidden = true
        let font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 12, weight: .medium))
        caption.font = font
        caption.text = configuration?.title
        let color = configuration?.baseForegroundColor ?? tintColor ?? .white
        caption.textColor = color; symbolView.tintColor = color
        caption.alpha = isEnabled ? 1 : 0.4; symbolView.alpha = caption.alpha
        symbolView.image = configuration?.image?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: .medium))
        let captionHeight = max(17, ceil(font.lineHeight))
        let groupHeight: CGFloat = 26 + 4 + captionHeight
        let top = max(2, (bounds.height - groupHeight) / 2)
        symbolView.frame = CGRect(x: bounds.midX - 13, y: top, width: 26, height: 26)
        caption.frame = CGRect(x: 1, y: top + 30, width: max(0, bounds.width - 2), height: captionHeight)
    }
}

final class CallToolbar: UIView {
    private let items: [UIView]
    var rail = false { didSet { if oldValue != rail { setNeedsLayout() } } }
    var largeText = false { didSet { if oldValue != largeText { setNeedsLayout() } } }
    var preferredHeight: CGFloat {
        let font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 12, weight: .medium), compatibleWith: traitCollection)
        return largeText ? 2 * max(69, ceil(font.lineHeight) + 40) + 10 : 68
    }
    init(items: [UIView]) {
        self.items = items
        super.init(frame: .zero)
        items.forEach { $0.translatesAutoresizingMaskIntoConstraints = true; addSubview($0) }
        backgroundColor = UIColor(red: 0.12, green: 0.14, blue: 0.21, alpha: 1)
        layer.cornerRadius = 16
        accessibilityIdentifier = "Meeting toolbar"
    }
    required init?(coder: NSCoder) { nil }
    func arrange(rail: Bool, largeText: Bool) { self.rail = rail; self.largeText = largeText }
    override func layoutSubviews() {
        super.layoutSubviews()
        let columns = rail ? (largeText ? 2 : 1) : largeText ? 3 : items.count
        let rows = (items.count + columns - 1) / columns
        let area = bounds.insetBy(dx: 4, dy: 5)
        let width = area.width / CGFloat(columns), height = area.height / CGFloat(rows)
        for (index, item) in items.enumerated() {
            item.frame = CGRect(x: area.minX + CGFloat(index % columns) * width,
                                y: area.minY + CGFloat(index / columns) * height,
                                width: width, height: height).insetBy(dx: 1, dy: 0)
        }
    }
}

/// Empty areas pass through to the SDK; visible media and controls own their touches.
final class CallChromeSurface: UIView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsLayout() }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// Provider tiles use the same unobstructed stage as the controls above them.
@MainActor
enum CallStageLayout {
    final class Record: NSObject {
        let owner: UUID
        var rect: CGRect
        var hidden: Bool
        var toggleControls: () -> Void
        init(owner: UUID, rect: CGRect, hidden: Bool, toggle: @escaping () -> Void) {
            self.owner = owner; self.rect = rect; self.hidden = hidden; toggleControls = toggle
        }
    }
    private static let records = NSMapTable<UIWindow, Record>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private static let tiles = NSHashTable<StreamViewport>.weakObjects()
    static func register(_ tile: StreamViewport) { tiles.add(tile) }
    static func record(for window: UIWindow?) -> Record? { window.flatMap { records.object(forKey: $0) } }
    static func update(window: UIWindow, owner: UUID, rect: CGRect, hidden: Bool, toggle: @escaping () -> Void) {
        let previous = records.object(forKey: window)
        guard previous?.owner != owner || previous?.rect != rect || previous?.hidden != hidden else { return }
        records.setObject(Record(owner: owner, rect: rect, hidden: hidden, toggle: toggle), forKey: window)
        tiles.allObjects.filter { $0.window === window }.forEach { $0.setNeedsLayout() }
    }
    static func remove(window: UIWindow?, owner: UUID) {
        guard let window, records.object(forKey: window)?.owner == owner else { return }
        records.removeObject(forKey: window)
        tiles.allObjects.filter { $0.window === window }.forEach { $0.setNeedsLayout() }
    }
}
