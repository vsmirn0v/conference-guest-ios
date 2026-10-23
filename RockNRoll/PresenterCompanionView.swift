import UIKit

/// A local viewing accessory. Its preview never changes the shared-screen canvas or PiP.
@MainActor
final class PresenterCompanionView: UIView {
    enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
        var title: String {
            switch self {
            case .topLeading: L("Top left")
            case .topTrailing: L("Top right")
            case .bottomLeading: L("Bottom left")
            case .bottomTrailing: L("Bottom right")
            }
        }
        var leading: Bool { self == .topLeading || self == .bottomLeading }
        var top: Bool { self == .topLeading || self == .topTrailing }
    }
    var onFocusCamera: (() -> Void)?
    var onReturnToShare: (() -> Void)?
    var onInteraction: (() -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    var onMenuVisibilityChanged: ((Bool) -> Void)?
    private(set) var isCollapsed = false
    private(set) var corner: Corner = .bottomTrailing
    private(set) var isPreviewVisible = false
    private let surface = MeetingChromeSurface(cornerRadius: 16)
    private let previewHost = UIView()
    private let nameLabel = UILabel()
    private let collapse = UIButton(type: .system)
    private let chip = UIButton(type: .system)
    private let focusCamera = MeetingMenuButton(type: .system)
    private var preview: UIView?
    private var name = ""
    private var cameraFocused = false
    private var available = CGRect.zero
    private var shareFrame = CGRect.zero
    private var exclusions: [CGRect] = []
    private var dragOrigin = CGPoint.zero
    private var applicationActive = UIApplication.shared.applicationState == .active
    private var observers: [NSObjectProtocol] = []

    override var isHidden: Bool { didSet { refreshVisibility() } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "Presenter companion"
        overrideUserInterfaceStyle = .dark
        layer.cornerRadius = 16; clipsToBounds = true
        addSubview(surface); addSubview(previewHost); addSubview(focusCamera)
        addSubview(nameLabel); addSubview(collapse); addSubview(chip)
        previewHost.clipsToBounds = true
        previewHost.backgroundColor = .black
        nameLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 13, weight: .medium), maximumPointSize: 20)
        nameLabel.textColor = .white; nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.lineBreakMode = .byTruncatingTail
        collapse.configuration = .plain()
        collapse.configuration?.image = UIImage(systemName: "minus")
        collapse.tintColor = .white
        collapse.accessibilityIdentifier = "presenter.companion.hide"
        collapse.addAction(UIAction { [weak self] _ in self?.setCollapsed(true) }, for: .touchUpInside)
        focusCamera.accessibilityIdentifier = "presenter.companion.focus"
        focusCamera.showsMenuAsPrimaryAction = true
        focusCamera.onMenuVisibilityChanged = { [weak self] in self?.onMenuVisibilityChanged?($0) }
        chip.configuration = .plain(); chip.tintColor = .white
        chip.configuration?.imagePadding = 8
        chip.configuration?.titleLineBreakMode = .byTruncatingTail
        chip.configuration?.contentInsets = .init(top: 6, leading: 12, bottom: 6, trailing: 12)
        chip.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFontMetrics(forTextStyle: .callout).scaledFont(for: .systemFont(ofSize: 15, weight: .medium), maximumPointSize: 24)
            return attributes
        }
        chip.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if self.cameraFocused { self.interact { self.onReturnToShare?() } }
            else { self.setCollapsed(false) }
        }, for: .touchUpInside)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.didBecomeActiveNotification, UIWindow.didBecomeHiddenNotification, UIWindow.didBecomeVisibleNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if notification.name == UIApplication.willResignActiveNotification || notification.name == UIApplication.didEnterBackgroundNotification {
                        self.applicationActive = false
                    } else if notification.name == UIApplication.didBecomeActiveNotification {
                        self.applicationActive = true
                    } else if let window = notification.object as? UIWindow, window !== self.window { return }
                    self.refreshVisibility()
                }
            })
        }
        isHidden = true
    }
    required init?(coder: NSCoder) { nil }

    func configure(name: String, preview: UIView?, cameraFocused: Bool = false) {
        self.name = name; self.cameraFocused = cameraFocused
        if self.preview !== preview { self.preview?.removeFromSuperview(); self.preview = preview }
        nameLabel.text = name
        collapse.accessibilityLabel = L("Hide %@", name)
        focusCamera.accessibilityLabel = L("%@ presenter controls", name)
        chip.configuration?.title = cameraFocused ? L("Back to share") : L("Show %@", name)
        chip.configuration?.image = UIImage(systemName: cameraFocused ? "rectangle.on.rectangle" : "video")
        chip.accessibilityIdentifier = cameraFocused ? "presenter.companion.return" : "presenter.companion.show"
        isHidden = preview == nil && !cameraFocused
        updateContent(); reposition()
    }
    func setCollapsed(_ collapsed: Bool) {
        guard isCollapsed != collapsed else { return }
        isCollapsed = collapsed; updateContent(); reposition(); onInteraction?()
    }
    func move(to corner: Corner) {
        self.corner = corner; updateContent(); reposition(); onInteraction?()
    }
    func place(in availableBounds: CGRect, fittedShareFrame: CGRect, avoiding exclusionRects: [CGRect] = []) {
        available = availableBounds; shareFrame = fittedShareFrame; exclusions = exclusionRects
        reposition()
    }
    func refreshVisibility() {
        var visible = applicationActive && preview?.superview === previewHost && preview?.window != nil && !isCollapsed && !cameraFocused && window != nil
        var ancestor: UIView? = self
        while let view = ancestor { visible = visible && !view.isHidden && view.alpha > 0; ancestor = view.superview }
        guard visible != isPreviewVisible else { return }
        isPreviewVisible = visible; onVisibilityChanged?(visible)
    }
    override func didMoveToWindow() { super.didMoveToWindow(); refreshVisibility() }

    func menuActions() -> [UIMenuElement] {
        guard preview != nil || cameraFocused else { return [] }
        var actions: [UIMenuElement] = []
        if cameraFocused {
            actions.append(UIAction(title: L("Back to share"), image: UIImage(systemName: "rectangle.on.rectangle"), identifier: .init("presenter.companion.return")) { [weak self] _ in
                self?.interact { self?.onReturnToShare?() }
            })
        } else {
            actions.append(UIAction(title: isCollapsed ? L("Show %@", name) : L("Hide %@", name),
                image: UIImage(systemName: isCollapsed ? "video" : "minus.circle")) { [weak self] _ in
                    guard let self else { return }; self.setCollapsed(!self.isCollapsed)
                })
            actions.append(UIAction(title: L("Focus %@ camera", name), image: UIImage(systemName: "person.crop.rectangle"), identifier: .init("presenter.companion.focus")) { [weak self] _ in
                self?.interact { self?.onFocusCamera?() }
            })
        }
        actions.append(UIMenu(title: L("Move presenter"), image: UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right"),
            children: Corner.allCases.map { corner in
                UIAction(title: corner.title, state: self.corner == corner ? .on : .off) { [weak self] _ in self?.move(to: corner) }
            }))
        return actions
    }
    private func interact(_ action: () -> Void) { action(); onInteraction?() }
    private func updateContent() {
        let expanded = preview != nil && !isCollapsed && !cameraFocused
        if expanded, let preview, preview.superview !== previewHost {
            preview.frame = previewHost.bounds; preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            previewHost.addSubview(preview)
        } else if !expanded { preview?.removeFromSuperview() }
        previewHost.isHidden = !expanded; focusCamera.isHidden = !expanded
        nameLabel.isHidden = !expanded; collapse.isHidden = !expanded; chip.isHidden = expanded
        accessibilityCustomActions = Corner.allCases.map { corner in
            UIAccessibilityCustomAction(name: L("Move presenter: %@", corner.title)) { [weak self] _ in self?.move(to: corner); return true }
        }
        focusCamera.accessibilityCustomActions = accessibilityCustomActions
        chip.accessibilityCustomActions = accessibilityCustomActions
        focusCamera.menu = UIMenu(children: menuActions())
        setNeedsLayout(); refreshVisibility()
    }
    private func reposition() {
        guard available.width > 0, available.height > 0 else { return }
        let chipMode = isCollapsed || cameraFocused
        let width = min(available.width, chipMode ? min(240, max(144, chip.sizeThatFits(CGSize(width: 240, height: 44)).width)) : available.width >= 650 ? 208 : 152)
        let size = CGSize(width: width, height: min(available.height, chipMode ? 44 : width * 9 / 16 + 36))
        let safe = available.insetBy(dx: min(8, max(0, (available.width - size.width) / 2)), dy: min(8, max(0, (available.height - size.height) / 2)))
        var region = safe
        // Letterboxing is usable space. It never changes the screen's own fit or zoom.
        if available.height > available.width, !shareFrame.isEmpty {
            let above = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: max(0, min(safe.maxY, shareFrame.minY - 8) - safe.minY))
            let below = CGRect(x: safe.minX, y: max(safe.minY, shareFrame.maxY + 8), width: safe.width, height: max(0, safe.maxY - max(safe.minY, shareFrame.maxY + 8)))
            if let spare = (corner.top ? [above, below] : [below, above]).first(where: { $0.width >= size.width && $0.height >= size.height }) { region = spare }
        }
        func candidateFrame(at corner: Corner, in rect: CGRect) -> CGRect {
            CGRect(x: corner.leading ? rect.minX : rect.maxX - size.width,
                y: corner.top ? rect.minY : rect.maxY - size.height, width: size.width, height: size.height)
        }
        let preferred = candidateFrame(at: corner, in: region)
        frame = ([preferred] + Corner.allCases.filter { $0 != corner }.map { candidateFrame(at: $0, in: region) })
            .min(by: { lhs, rhs in
                exclusions.reduce(CGFloat.zero) { $0 + lhs.intersection($1).area } <
                exclusions.reduce(CGFloat.zero) { $0 + rhs.intersection($1).area }
            }) ?? preferred
        setNeedsLayout(); refreshVisibility()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        chip.frame = bounds
        let captionHeight = min(36, bounds.height)
        previewHost.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - captionHeight))
        surface.frame = chip.isHidden ? CGRect(x: 0, y: previewHost.frame.maxY, width: bounds.width, height: captionHeight) : bounds
        focusCamera.frame = previewHost.frame
        nameLabel.frame = CGRect(x: 10, y: previewHost.frame.maxY, width: max(0, bounds.width - 54), height: captionHeight)
        collapse.frame = CGRect(x: max(0, bounds.width - 44), y: max(0, bounds.height - 44), width: 44, height: 44)
    }
    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        if gesture.state == .began { dragOrigin = frame.origin; onInteraction?() }
        let translation = gesture.translation(in: parent)
        if gesture.state == .changed {
            frame.origin = CGPoint(x: min(max(available.minX, dragOrigin.x + translation.x), max(available.minX, available.maxX - bounds.width)),
                y: min(max(available.minY, dragOrigin.y + translation.y), max(available.minY, available.maxY - bounds.height)))
        } else if gesture.state == .ended || gesture.state == .cancelled {
            let leading = center.x < available.midX, top = center.y < available.midY
            move(to: top ? (leading ? .topLeading : .topTrailing) : (leading ? .bottomLeading : .bottomTrailing))
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
