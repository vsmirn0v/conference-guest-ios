import UIKit

/// Geometry belongs to the visible call window, independently of media providers.
struct CallPresentationGeometry {
    let header: CGRect
    let toolbar: CGRect
    let stage: CGRect
    let rail: Bool
    let compactHeader: Bool

    init(bounds: CGRect, insets: UIEdgeInsets, headerHeight: CGFloat,
         toolbarHeight: CGFloat = 68, hidden: Bool, largeText: Bool = false, allowsRail: Bool = true,
         statusOnly: Bool = false) {
        let safe = bounds.inset(by: insets).insetBy(dx: 8, dy: 4)
        rail = allowsRail && safe.width > safe.height && safe.height < 480 && safe.height >= 284
        compactHeader = (rail && !largeText) || statusOnly
        if statusOnly && hidden {
            header = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: 44)
            toolbar = .zero
            stage = CGRect(x: safe.minX, y: header.maxY + 6, width: safe.width,
                           height: max(0, safe.maxY - header.maxY - 6))
            return
        }
        if hidden {
            header = .zero; toolbar = .zero; stage = safe
            return
        }
        if rail {
            let railWidth: CGFloat = largeText ? min(296, safe.width * 0.45) : 56
            toolbar = CGRect(x: safe.maxX - railWidth, y: safe.minY, width: railWidth, height: safe.height)
            let width = max(0, safe.width - railWidth - 8)
            header = CGRect(x: compactHeader ? safe.minX : safe.minX + max(0, (width - 440) / 2), y: safe.minY,
                            width: compactHeader ? width : min(440, width), height: compactHeader ? 44 : headerHeight)
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
    var showsCaption = true { didSet { if oldValue != showsCaption { setNeedsLayout() } } }
    private let symbolView = UIImageView()
    private let caption = UILabel()
    private var symbolContent: UIView?

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
    /// Custom icons use the same optical slot as ordinary SF Symbols.
    /// UIKit's imageView is deliberately hidden by this control.
    func setSymbolContent(_ content: UIView?) {
        symbolContent?.removeFromSuperview()
        symbolContent = content
        if let content { content.isUserInteractionEnabled = false; addSubview(content) }
        setNeedsLayout()
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
        caption.isHidden = !showsCaption
        symbolView.image = configuration?.image?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: .medium))
        let captionHeight = max(17, ceil(font.lineHeight))
        let groupHeight: CGFloat = showsCaption ? 26 + 4 + captionHeight : 26
        let top = max(2, (bounds.height - groupHeight) / 2)
        symbolView.frame = CGRect(x: bounds.midX - 13, y: top, width: 26, height: 26)
        symbolView.isHidden = symbolContent != nil
        symbolContent?.frame = symbolView.frame
        symbolContent?.alpha = caption.alpha
        caption.frame = CGRect(x: 1, y: top + 30, width: max(0, bounds.width - 2), height: captionHeight)
    }
}

final class CallToolbar: UIView {
    private let baseItems: [UIView]
    private var accessory: UIView?
    private var items: [UIView] {
        guard let accessory else { return baseItems }
        var result = baseItems
        result.insert(accessory, at: max(0, result.count - 2))
        return result
    }
    var rail = false { didSet { if oldValue != rail { setNeedsLayout() } } }
    var largeText = false { didSet { if oldValue != largeText { setNeedsLayout() } } }
    var preferredHeight: CGFloat {
        let font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 12, weight: .medium), compatibleWith: traitCollection)
        return largeText ? 2 * max(69, ceil(font.lineHeight) + 40) + 10 : 68
    }
    init(items: [UIView]) {
        self.baseItems = items
        super.init(frame: .zero)
        items.forEach { $0.translatesAutoresizingMaskIntoConstraints = true; addSubview($0) }
        backgroundColor = UIColor(red: 0.12, green: 0.14, blue: 0.21, alpha: 1)
        layer.cornerRadius = 16
        accessibilityIdentifier = "Meeting toolbar"
    }
    required init?(coder: NSCoder) { nil }
    func setAccessory(_ view: UIView?) {
        guard accessory !== view else { return }
        accessory?.removeFromSuperview(); accessory = view
        if let view { view.translatesAutoresizingMaskIntoConstraints = true; addSubview(view) }
        setNeedsLayout()
    }
    func arrange(rail: Bool, largeText: Bool) { self.rail = rail; self.largeText = largeText }
    override func layoutSubviews() {
        super.layoutSubviews()
        let columns = rail ? (largeText ? 2 : 1) : largeText ? 3 : items.count
        let rows = (items.count + columns - 1) / columns
        let area = bounds.insetBy(dx: 4, dy: 5)
        let width = area.width / CGFloat(columns), height = area.height / CGFloat(rows)
        for (index, item) in items.enumerated() {
            setCaptions(in: item, visible: !rail || largeText)
            item.frame = CGRect(x: area.minX + CGFloat(index % columns) * width,
                                y: area.minY + CGFloat(index / columns) * height,
                                width: width, height: height).insetBy(dx: 1, dy: 0)
        }
    }
    private func setCaptions(in view: UIView, visible: Bool) {
        if let button = view as? AlignedCallButton { button.showsCaption = visible }
        else { view.subviews.forEach { setCaptions(in: $0, visible: visible) } }
    }
}

/// A single stable row outside the media. The fuller portrait header remains intact.
final class CompactCallHeader: UIView {
    let details = UIButton(type: .system)
    let previous = UIButton(type: .system)
    let nextStream = UIButton(type: .system)
    let automatic = UIButton(type: .system)
    let pin = UIButton(type: .system)
    let participants = UIButton(type: .system)
    let missed = UIButton(type: .system)
    let conversation = UIButton(type: .system)
    let focus = UIButton(type: .system)
    private let chatBadge = UILabel()
    private let missedBadge = UILabel()
    private let sourceLabel = UILabel()
    private let privacyIcon = UIImageView()
    private let speakerIndicator = ActiveSpeakerIndicator(font: .systemFont(ofSize: 15, weight: .medium))
    private var sourceName = ""
    private var callStatus: String?
    private var privacySymbol: String?
    private var privacyDescription: String?
    private struct Identity: Equatable {
        let source: String
        let status: String?
        let speaker: CallSpeaker?
        let privacySymbol: String?
        let privacyDescription: String?
    }
    private var renderedIdentity: Identity?
    private var actions: [UIButton] { [previous, automatic, nextStream, pin, participants, missed, conversation, focus] }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "Compact meeting header"
        backgroundColor = UIColor.black.withAlphaComponent(0.8)
        layer.cornerRadius = 12
        details.contentHorizontalAlignment = .leading
        details.configuration = .plain()
        details.configuration?.titleLineBreakMode = .byTruncatingTail
        details.configuration?.image = UIImage(systemName: "info.circle")
        details.configuration?.imagePadding = 6
        details.accessibilityIdentifier = "Meeting details"
        addSubview(details)
        sourceLabel.font = .systemFont(ofSize: 11)
        sourceLabel.textColor = .lightGray
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.isUserInteractionEnabled = false
        sourceLabel.isAccessibilityElement = false
        speakerIndicator.isAccessibilityElement = false
        details.addSubview(sourceLabel); details.addSubview(speakerIndicator)
        privacyIcon.contentMode = .scaleAspectFit
        privacyIcon.isUserInteractionEnabled = false
        privacyIcon.isAccessibilityElement = false
        details.addSubview(privacyIcon)
        for (button, symbol, label) in [
            (previous, "chevron.left", L("Previous stream")),
            (automatic, "arrow.triangle.2.circlepath", L("Automatic view")),
            (nextStream, "chevron.right", L("Next stream")),
            (pin, "pin", L("Pin")),
            (participants, "person.2.fill", L("Musicians")),
            (missed, "clock.arrow.circlepath", L("Catch up")),
            (conversation, "bubble.left", L("Chat")),
            (focus, "arrow.up.left.and.arrow.down.right", L("Hide controls"))
        ] {
            button.configuration = .plain()
            button.configuration?.image = UIImage(systemName: symbol)
            button.accessibilityLabel = label
            addSubview(button)
        }
        for (button, badge) in [(conversation, chatBadge), (missed, missedBadge)] {
            badge.font = .systemFont(ofSize: 10, weight: .semibold)
            badge.textAlignment = .center
            badge.textColor = .black; badge.backgroundColor = .systemOrange
            badge.layer.cornerRadius = 7; badge.clipsToBounds = true
            badge.isAccessibilityElement = false; badge.isUserInteractionEnabled = false
            button.addSubview(badge)
        }
        automatic.configuration?.image = nil
        automatic.configuration?.title = L("Auto")
        automatic.configuration?.contentInsets = .zero
        automatic.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.systemFont(ofSize: 12, weight: .medium)
            return attributes
        }
    }
    required init?(coder: NSCoder) { nil }

    func update(name: String, navigation: Bool, browsing: Bool, pinned: Bool,
                pinLabel: String?, participantsLabel: String?, chatValue: String?,
                chatCount: Int = 0, missedCount: Int = 0, status: String?, speaking: CallSpeaker? = nil, focusAvailable: Bool,
                privacySymbol: String? = nil, privacyDescription: String? = nil, disclosureOnly: Bool = false) {
        sourceName = name
        callStatus = status
        self.privacySymbol = privacySymbol; self.privacyDescription = privacyDescription
        details.accessibilityLabel = L("Jam details") + ", " + name
        setSpeaker(speaking)
        actions.forEach { $0.isHidden = false }
        for button in [previous, automatic, nextStream] { button.isHidden = !navigation }
        previous.isEnabled = !pinned; nextStream.isEnabled = !pinned
        automatic.isEnabled = browsing || pinned
        pin.isHidden = pinLabel == nil
        pin.configuration?.image = UIImage(systemName: pinned ? "pin.fill" : "pin")
        pin.configuration?.baseForegroundColor = pinned ? .systemOrange : .white
        pin.accessibilityLabel = pinLabel
        pin.accessibilityHint = L("Changes only your view")
        participants.accessibilityLabel = participantsLabel
        conversation.configuration?.image = UIImage(systemName: chatValue == nil ? "bubble.left" : "bubble.left.fill")
        conversation.configuration?.baseForegroundColor = chatValue == nil ? .white : .systemOrange
        conversation.accessibilityValue = chatValue
        chatBadge.text = chatCount > 99 ? "99+" : String(chatCount)
        chatBadge.isHidden = chatCount == 0
        missed.isHidden = missedCount == 0
        missed.configuration?.baseForegroundColor = .systemOrange
        missed.accessibilityLabel = L("Catch up, %ld missed sections", missedCount)
        missedBadge.text = missedCount > 99 ? "99+" : String(missedCount)
        focus.isHidden = !focusAvailable
        if disclosureOnly { actions.forEach { $0.isHidden = true } }
        setNeedsLayout()
    }
    func setSpeaker(_ speaker: CallSpeaker?) {
        let visible = callStatus == nil ? speaker : nil
        let identity = Identity(source: sourceName, status: callStatus, speaker: visible, privacySymbol: privacySymbol, privacyDescription: privacyDescription)
        guard renderedIdentity != identity else { return }
        renderedIdentity = identity
        sourceLabel.text = sourceName
        sourceLabel.isHidden = visible == nil
        speakerIndicator.setSpeaker(visible)
        details.configuration?.title = visible == nil ? sourceName : nil
        details.configuration?.image = visible == nil ? UIImage(systemName: privacySymbol ?? "info.circle") : nil
        privacyIcon.image = privacySymbol.flatMap { UIImage(systemName: $0) }
        privacyIcon.tintColor = privacySymbol == "record.circle" ? .systemRed : .systemOrange
        privacyIcon.isHidden = visible == nil || privacySymbol == nil
        details.configuration?.baseForegroundColor = callStatus == nil ? .white : .systemOrange
        details.accessibilityValue = [callStatus, privacyDescription, visible?.accessibilityLabel].compactMap { $0 }.joined(separator: ", ")
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let visible = actions.filter { !$0.isHidden }
        let start = bounds.maxX - CGFloat(visible.count) * 44 - 4
        details.frame = CGRect(x: 4, y: 0, width: max(0, start - 8), height: 44)
        let inset: CGFloat = privacyIcon.isHidden ? 7 : 24
        sourceLabel.frame = CGRect(x: inset, y: 3, width: max(0, details.bounds.width - inset - 7), height: 14)
        privacyIcon.frame = CGRect(x: 7, y: 3, width: 13, height: 14)
        speakerIndicator.frame = CGRect(x: 0, y: 18, width: details.bounds.width, height: 23)
        for (index, button) in visible.enumerated() {
            button.frame = CGRect(x: start + CGFloat(index) * 44, y: 0, width: 44, height: 44)
        }
        chatBadge.frame = CGRect(x: 21, y: 3, width: 23, height: 14)
        missedBadge.frame = chatBadge.frame
    }
}

/// Zoom tools are discoverable after an interaction, without covering content indefinitely.
@MainActor
final class TransientCallControls {
    private weak var view: UIView?
    private let delay: TimeInterval
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var available = false
    private var suppressed = false
    private var interacting = false
    private var revealed = false
    init(view: UIView, delay: TimeInterval = 3) {
        self.view = view; self.delay = delay
        view.alpha = 0; view.isUserInteractionEnabled = false; view.accessibilityElementsHidden = true
        observer = NotificationCenter.default.addObserver(forName: UIAccessibility.voiceOverStatusDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.activity() }
            }
    }
    func setAvailable(_ value: Bool) {
        guard available != value else { return }
        available = value
        if value { activity() } else { invalidate(); revealed = false; render() }
    }
    func setSuppressed(_ value: Bool) {
        guard suppressed != value else { return }
        suppressed = value
        if value { invalidate(); render() } else { activity() }
    }
    func activity() {
        invalidate()
        guard available, !suppressed else { return }
        revealed = true; render()
        guard !interacting, !UIAccessibility.isVoiceOverRunning else { return }
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.revealed = false; self.render()
            }
        }
    }
    func beginInteraction() { interacting = true; activity() }
    func endInteraction() { interacting = false; activity() }
    private func render() {
        guard let view else { return }
        let visible = available && !suppressed && revealed
        view.isUserInteractionEnabled = visible
        view.accessibilityElementsHidden = !visible
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2,
                       delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { view.alpha = visible ? 1 : 0 }
    }
    private func invalidate() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate(); if let observer { NotificationCenter.default.removeObserver(observer) } }
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
