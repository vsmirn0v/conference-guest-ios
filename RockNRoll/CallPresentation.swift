import ConferenceCore
import UIKit

/// Fit and Fill share the same renderer and preserve the source aspect ratio.
enum SharedScreenScale {
    static func fill(content: CGSize, viewport: CGSize) -> CGFloat? {
        guard content.width > 0, content.height > 0, viewport.width > 0, viewport.height > 0 else { return nil }
        let x = viewport.width / content.width, y = viewport.height / content.height
        let scale = max(x, y) / min(x, y)
        return scale.isFinite ? max(1, scale) : nil
    }
    static func configure(_ button: UIButton, zoomed: Bool, available: Bool) {
        let label = zoomed ? L("Fit whole share") : L("Fill screen")
        guard button.accessibilityIdentifier != "Shared screen scale" || button.accessibilityLabel != label || button.isEnabled != available else { return }
        button.configuration?.image = UIImage(systemName: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        button.accessibilityLabel = label
        button.accessibilityIdentifier = "Shared screen scale"
        button.isEnabled = available
        button.superview?.setNeedsLayout()
    }
}

/// Geometry belongs to the visible call window, independently of media providers.
struct CallPresentationGeometry {
    let header: CGRect
    let toolbar: CGRect
    let stage: CGRect
    let rail: Bool
    let compactHeader: Bool

    init(bounds: CGRect, insets: UIEdgeInsets, headerHeight: CGFloat,
         toolbarHeight: CGFloat = 68, hidden: Bool, largeText: Bool = false, allowsRail: Bool = true,
         statusOnly: Bool = false, floating: Bool = false) {
        if floating && hidden {
            let visible = Self(bounds: bounds, insets: insets, headerHeight: headerHeight,
                toolbarHeight: toolbarHeight, hidden: false, largeText: largeText,
                allowsRail: allowsRail, statusOnly: false, floating: true)
            header = statusOnly ? CGRect(x: visible.header.minX, y: visible.header.minY,
                width: visible.header.width, height: 44) : .zero
            toolbar = .zero; stage = visible.stage
            rail = visible.rail; compactHeader = statusOnly || visible.compactHeader
            return
        }
        let safe = bounds.inset(by: insets).insetBy(dx: 8, dy: 4)
        rail = allowsRail && safe.width > safe.height && safe.height < 480 && safe.height >= 284
        compactHeader = floating || (rail && !largeText) || statusOnly
        if statusOnly && hidden {
            header = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: 44)
            toolbar = .zero
            stage = CGRect(x: bounds.minX, y: header.maxY + 6, width: bounds.width,
                           height: max(0, bounds.maxY - header.maxY - 6))
            return
        }
        if hidden {
            header = .zero; toolbar = .zero; stage = bounds
            return
        }
        if rail {
            let railWidth: CGFloat = largeText ? min(296, safe.width * 0.45) : 56
            let height = floating && !largeText ? min(safe.height, 320) : safe.height
            toolbar = CGRect(x: safe.maxX - railWidth, y: safe.midY - height / 2, width: railWidth, height: height)
            let width = max(0, safe.width - railWidth - 8)
            header = CGRect(x: compactHeader ? safe.minX : safe.minX + max(0, (width - 440) / 2), y: safe.minY,
                            width: compactHeader ? width : min(440, width), height: compactHeader ? 44 : headerHeight)
            stage = CGRect(x: safe.minX, y: header.maxY + 6, width: width,
                           height: max(0, safe.maxY - header.maxY - 6))
        } else {
            let width = min(520, safe.width)
            toolbar = CGRect(x: safe.midX - width / 2, y: safe.maxY - toolbarHeight,
                             width: width, height: toolbarHeight)
            header = CGRect(x: floating ? safe.minX : safe.midX - min(440, safe.width) / 2, y: safe.minY,
                            width: floating ? safe.width : min(440, safe.width), height: compactHeader ? 44 : headerHeight)
            stage = CGRect(x: safe.minX, y: header.maxY + 6, width: safe.width,
                           height: max(0, toolbar.minY - header.maxY - 14))
        }
    }
}

/// Meeting chrome grows with text preferences while keeping the media and touch targets usable.
@MainActor
enum MeetingControlMetrics {
    static func captionFont(for traits: UITraitCollection) -> UIFont {
        UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 12, weight: .medium),
            maximumPointSize: 18, compatibleWith: traits)
    }
    static func boundSymbol(in button: UIButton) {
        button.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        button.imageView?.adjustsImageSizeForAccessibilityContentSizeCategory = false
        (button as? MeetingMenuButton)?.boundedSymbolSide = 22
    }
}

/// Keep meeting controls visible for the entire lifetime of a system menu.
class MeetingMenuButton: UIButton {
    var onMenuVisibilityChanged: ((Bool) -> Void)?
    var boundedSymbolSide: CGFloat? { didSet { setNeedsLayout() } }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let side = boundedSymbolSide, let image = imageView else { return }
        // Configurations can grow the image independently of their capped title font.
        let center = image.center
        image.adjustsImageSizeForAccessibilityContentSizeCategory = false
        image.contentMode = .scaleAspectFit
        image.transform = .identity
        image.bounds.size = CGSize(width: side, height: side)
        image.center = center
    }
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
}

/// All captioned actions share an optical icon center and a caption baseline.
final class AlignedCallButton: MeetingMenuButton {
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
        caption.adjustsFontSizeToFitWidth = true
        caption.minimumScaleFactor = 0.75
        caption.allowsDefaultTighteningForTruncation = true
        caption.isUserInteractionEnabled = false
        addSubview(symbolView); addSubview(caption)
    }
    required init?(coder: NSCoder) { nil }
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
        let font = MeetingControlMetrics.captionFont(for: traitCollection)
        caption.font = font
        caption.text = configuration?.title
        let color = configuration?.baseForegroundColor ?? tintColor ?? .white
        caption.textColor = color; symbolView.tintColor = color
        caption.alpha = isEnabled ? 1 : 0.4; symbolView.alpha = caption.alpha
        caption.isHidden = !showsCaption
        symbolView.image = configuration?.image?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: .medium))
        let textHeight = caption.sizeThatFits(CGSize(width: max(1, bounds.width - 2), height: .greatestFiniteMagnitude)).height
        let captionHeight = max(17, min(ceil(textHeight), max(17, bounds.height - 34)))
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
    private let surface = MeetingChromeSurface(cornerRadius: 28)
    private let endSurface = MeetingChromeSurface(cornerRadius: 28)
    var separatesLast = false { didSet { if oldValue != separatesLast { setNeedsLayout() } } }
    var inlineAccessWidth: CGFloat = 0 { didSet { if oldValue != inlineAccessWidth { setNeedsLayout() } } }
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
        let font = MeetingControlMetrics.captionFont(for: traitCollection)
        return largeText ? CGFloat((items.count + 1) / 2) * max(64, ceil(font.lineHeight) + 40) + 10 : 68
    }
    init(items: [UIView]) {
        self.baseItems = items
        super.init(frame: .zero)
        overrideUserInterfaceStyle = .dark
        surface.frame = bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(surface)
        addSubview(endSurface)
        endSurface.isHidden = true
        items.forEach { $0.translatesAutoresizingMaskIntoConstraints = true; addSubview($0) }
        layer.cornerRadius = 28
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
        let separated = separatesLast && !rail && !largeText && items.count > 1
        endSurface.isHidden = !separated
        if separated {
            let end = CGRect(x: bounds.maxX - 54, y: 0, width: 54, height: bounds.height)
            surface.frame = CGRect(x: 0, y: 0, width: end.minX - 8 - inlineAccessWidth, height: bounds.height)
            endSurface.frame = end
            let area = surface.frame.insetBy(dx: 4, dy: 5)
            let width = area.width / CGFloat(items.count - 1)
            for (index, item) in items.enumerated() {
                setCaptions(in: item, visible: true)
                item.frame = index == items.count - 1 ? end.insetBy(dx: 4, dy: 5) :
                    CGRect(x: area.minX + CGFloat(index) * width, y: area.minY, width: width, height: area.height)
            }
            return
        }
        surface.frame = bounds
        let columns = rail ? (largeText ? 2 : 1) : largeText ? 2 : items.count
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

/// A stable floating row for meeting identity and actions at every window size.
final class CompactCallHeader: UIView {
    let details = MeetingMenuButton(type: .system)
    let previous = MeetingMenuButton(type: .system)
    let nextStream = MeetingMenuButton(type: .system)
    let automatic = MeetingMenuButton(type: .system)
    let pin = MeetingMenuButton(type: .system)
    let layoutButton = MeetingMenuButton(type: .system)
    let participants = MeetingMenuButton(type: .system)
    let missed = MeetingMenuButton(type: .system)
    let conversation = MeetingMenuButton(type: .system)
    let focus = MeetingMenuButton(type: .system)
    private let overflow = MeetingMenuButton(type: .system)
    var onMenuVisibilityChanged: ((Bool) -> Void)? {
        didSet {
            layoutButton.onMenuVisibilityChanged = onMenuVisibilityChanged
            overflow.onMenuVisibilityChanged = onMenuVisibilityChanged
        }
    }
    private let chatBadge = UILabel()
    private let missedBadge = UILabel()
    private let sourceLabel = UILabel()
    private let privacyIcon = UIImageView()
    private let speakerIndicator = ActiveSpeakerIndicator(font: .systemFont(ofSize: 15, weight: .medium))
    private let identitySurface = MeetingChromeSurface(cornerRadius: 22)
    private let actionsSurface = MeetingChromeSurface(cornerRadius: 22)
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
    private struct Layout: Equatable {
        let mode: MeetingLayoutMode
        let followsSpeaker: Bool
    }
    private var renderedLayout: Layout?
    private var availableActions = Set<ObjectIdentifier>()
    private var layoutAvailable = false
    private var disclosureOnly = false
    private struct OverflowItem: Equatable {
        let button: ObjectIdentifier
        let title: String
        let enabled: Bool
        let menu: ObjectIdentifier?
    }
    private var overflowItems: [OverflowItem] = []
    private var actions: [UIButton] { [layoutButton, previous, automatic, nextStream, pin, participants, missed, conversation, focus] }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "Compact meeting header"
        backgroundColor = .clear
        addSubview(identitySurface); addSubview(actionsSurface)
        details.contentHorizontalAlignment = .leading
        details.configuration = .plain()
        details.configuration?.titleLineBreakMode = .byTruncatingTail
        details.configuration?.image = UIImage(systemName: "info.circle")
        details.configuration?.imagePadding = 6
        details.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFontMetrics(forTextStyle: .callout).scaledFont(for: .systemFont(ofSize: 15, weight: .medium), maximumPointSize: 20)
            return attributes
        }
        MeetingControlMetrics.boundSymbol(in: details)
        details.accessibilityIdentifier = "Meeting details"
        addSubview(details)
        sourceLabel.font = .systemFont(ofSize: 11)
        sourceLabel.textColor = .lightGray
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.isUserInteractionEnabled = false
        sourceLabel.isAccessibilityElement = false
        speakerIndicator.isAccessibilityElement = false
        speakerIndicator.contentInset = 0
        details.addSubview(sourceLabel); details.addSubview(speakerIndicator)
        privacyIcon.contentMode = .scaleAspectFit
        privacyIcon.isUserInteractionEnabled = false
        privacyIcon.isAccessibilityElement = false
        details.addSubview(privacyIcon)
        for (button, symbol, label) in [
            (layoutButton, "square.grid.2x2", L("Meeting layout")),
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
            MeetingControlMetrics.boundSymbol(in: button)
            button.accessibilityLabel = label
            addSubview(button)
        }
        availableActions = Set(actions.filter { $0 !== layoutButton }.map(ObjectIdentifier.init))
        overflow.configuration = .plain()
        overflow.configuration?.image = UIImage(systemName: "ellipsis")
        MeetingControlMetrics.boundSymbol(in: overflow)
        overflow.showsMenuAsPrimaryAction = true
        overflow.accessibilityLabel = L("More meeting controls")
        overflow.accessibilityIdentifier = "More meeting controls"
        overflow.isHidden = true
        addSubview(overflow)
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

    func setLayout(mode: ConferenceCore.MeetingLayoutMode, available: Bool,
                   choose: @escaping (ConferenceCore.MeetingLayoutMode) -> Void,
                   followSpeaker: (() -> Void)? = nil) {
        layoutAvailable = available
        layoutButton.isHidden = !available
        setNeedsLayout()
        guard available else { return }
        let layout = Layout(mode: mode, followsSpeaker: followSpeaker != nil)
        guard renderedLayout != layout else { return }
        renderedLayout = layout
        layoutButton.configuration?.image = UIImage(systemName: mode == .grid ? "square.grid.2x2" : "rectangle.inset.filled")
        layoutButton.accessibilityIdentifier = "Meeting layout menu"
        layoutButton.accessibilityLabel = L("Layout: %@", mode.title)
        layoutButton.showsMenuAsPrimaryAction = true
        var options: [UIMenuElement] = ConferenceCore.MeetingLayoutMode.allCases.map { option in
            UIAction(title: option.title, image: UIImage(systemName: option.symbol), state: mode == option ? .on : .off) { _ in choose(option) }
        }
        if let followSpeaker {
            options.append(UIAction(title: L("Follow speaker"), image: UIImage(systemName: "waveform")) { _ in followSpeaker() })
        }
        layoutButton.menu = UIMenu(children: options)
        setNeedsLayout()
    }
    func update(name: String, navigation: Bool, browsing: Bool, pinned: Bool,
                pinLabel: String?, participantsLabel: String?, chatValue: String?,
                chatCount: Int = 0, missedCount: Int = 0, status: String?, speaking: CallSpeaker? = nil, focusAvailable: Bool,
                privacySymbol: String? = nil, privacyDescription: String? = nil, disclosureOnly: Bool = false,
                chatAvailable: Bool = true, meetingName: String? = nil) {
        sourceName = name
        callStatus = status
        self.privacySymbol = privacySymbol; self.privacyDescription = privacyDescription
        details.accessibilityLabel = [L("Jam details"), meetingName, name].compactMap { $0 }.joined(separator: ", ")
        setSpeaker(speaking)
        actions.filter { $0 !== layoutButton }.forEach { $0.isHidden = false }
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
        conversation.isHidden = !chatAvailable
        chatBadge.text = chatCount > 99 ? "99+" : String(chatCount)
        chatBadge.isHidden = chatCount == 0
        missed.isHidden = missedCount == 0
        missed.configuration?.baseForegroundColor = .systemOrange
        missed.accessibilityLabel = L("Catch up, %ld missed sections", missedCount)
        missedBadge.text = missedCount > 99 ? "99+" : String(missedCount)
        focus.isHidden = !focusAvailable
        self.disclosureOnly = disclosureOnly
        if disclosureOnly { actions.forEach { $0.isHidden = true } }
        availableActions = Set(actions.filter { $0 !== layoutButton && !$0.isHidden }.map(ObjectIdentifier.init))
        setNeedsLayout()
    }
    func setSpeaker(_ speaker: CallSpeaker?) {
        let visible = callStatus == nil ? speaker : nil
        let identity = Identity(source: sourceName, status: callStatus, speaker: visible, privacySymbol: privacySymbol, privacyDescription: privacyDescription)
        guard renderedIdentity != identity else { return }
        renderedIdentity = identity
        sourceLabel.text = sourceName
        sourceLabel.textColor = callStatus != nil ? .systemOrange : visible == nil ? .white : .lightGray
        sourceLabel.isHidden = false
        speakerIndicator.setSpeaker(visible)
        details.configuration?.title = nil
        details.configuration?.image = nil
        privacyIcon.image = UIImage(systemName: privacySymbol ?? "info.circle")
        privacyIcon.tintColor = privacySymbol == "record.circle" ? .systemRed : privacySymbol == nil ? .lightGray : .systemOrange
        privacyIcon.isHidden = false
        details.configuration?.baseForegroundColor = callStatus == nil ? .white : .systemOrange
        details.accessibilityValue = [callStatus, privacyDescription, visible?.accessibilityLabel].compactMap { $0 }.joined(separator: ", ")
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let available = disclosureOnly ? [] : actions.filter {
            $0 === layoutButton ? layoutAvailable : availableActions.contains(ObjectIdentifier($0))
        }
        let showsIdentity = bounds.width >= 104 || available.isEmpty
        let capacity = max(1, Int(max(0, bounds.width - (showsIdentity ? 116 : 8)) / 44))
        let needsOverflow = available.count > capacity || !showsIdentity
        let priority: [UIButton] = [participants, conversation, focus, layoutButton, pin, missed, previous, automatic, nextStream]
        let availableIDs = Set(available.map(ObjectIdentifier.init))
        let direct = Set(priority.filter { availableIDs.contains(ObjectIdentifier($0)) }
            .prefix(needsOverflow ? max(0, capacity - 1) : capacity).map(ObjectIdentifier.init))
        var visible = available.filter { direct.contains(ObjectIdentifier($0)) }
        actions.forEach { $0.isHidden = !direct.contains(ObjectIdentifier($0)) }
        overflow.isHidden = !needsOverflow
        if needsOverflow {
            updateOverflow((showsIdentity ? [] : [details]) + available.filter { !direct.contains(ObjectIdentifier($0)) })
            visible.append(overflow)
        }
        let start = bounds.maxX - CGFloat(visible.count) * 44 - 4
        details.isHidden = !showsIdentity
        identitySurface.isHidden = !showsIdentity
        details.frame = CGRect(x: 4, y: 0, width: min(220, max(0, start - 12)), height: 44)
        identitySurface.frame = details.frame
        actionsSurface.isHidden = visible.isEmpty
        actionsSurface.frame = CGRect(x: start - 2, y: 0, width: CGFloat(visible.count) * 44 + 6, height: 44)
        let textX: CGFloat = 40
        let textWidth = max(0, details.bounds.width - textX - 14)
        let speaking = !speakerIndicator.isHidden
        sourceLabel.font = speaking ? .systemFont(ofSize: 11) : UIFontMetrics(forTextStyle: .callout).scaledFont(for: .systemFont(ofSize: 15, weight: .medium), maximumPointSize: 20)
        sourceLabel.frame = CGRect(x: textX, y: speaking ? 6 : 8, width: textWidth, height: speaking ? 14 : 28)
        privacyIcon.frame = CGRect(x: 14, y: 12, width: 18, height: 20)
        speakerIndicator.frame = CGRect(x: textX, y: 20, width: textWidth, height: 20)
        for (index, button) in visible.enumerated() {
            button.frame = CGRect(x: start + CGFloat(index) * 44, y: 0, width: 44, height: 44)
        }
        for badge in [chatBadge, missedBadge] {
            let width = min(22, max(14, ceil(badge.intrinsicContentSize.width) + 6))
            badge.frame = CGRect(x: 39 - width, y: 6, width: width, height: 14)
        }
    }
    private func updateOverflow(_ buttons: [UIButton]) {
        let items = buttons.map { button in
            OverflowItem(button: ObjectIdentifier(button),
                title: [button.accessibilityLabel ?? button.configuration?.title, button.accessibilityValue]
                    .compactMap { $0 }.joined(separator: ", "),
                enabled: button.isEnabled, menu: button.menu.map(ObjectIdentifier.init))
        }
        guard overflowItems != items else { return }
        overflowItems = items
        overflow.menu = UIMenu(children: zip(buttons, items).map { button, item -> UIMenuElement in
            if let menu = button.menu, button.showsMenuAsPrimaryAction {
                return UIMenu(title: item.title, image: button.configuration?.image, children: menu.children)
            }
            return UIAction(title: item.title, image: button.configuration?.image,
                attributes: item.enabled ? [] : .disabled) { [weak button] _ in
                button?.sendActions(for: .touchUpInside)
            }
        })
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
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
