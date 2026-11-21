import ConferenceCore
import SwiftUI
import UIKit

/// Layout preference and incoming subscriptions are independent. Opening tools
/// captures this value and never asks a renderer or transport to change state.
struct MeetingViewState: Equatable {
    let layout: MeetingLayoutMode
    let display: ConferenceDisplayMode
    var manualFocus = false
    var effectiveLayout: MeetingLayoutMode? = nil
    var galleryAvailable = true
    var selectedLayout: MeetingLayoutMode { display == .audioOnly ? layout : effectiveLayout ?? layout }

    var title: String {
        switch display {
        case .all: return selectedLayout.title
        case .screenShares: return L("Shares only")
        case .audioOnly: return L("Audio only")
        }
    }
    var symbol: String { display == .all ? selectedLayout.symbol : display.symbol }
    var permitsLayout: Bool { true }
}

/// One owned transient panel per call. Deferred actions cannot reach a retired
/// call even when an SDK retains its overlay during an engine transition.
@MainActor
final class MeetingPanelOwner {
    private(set) var generation = UUID()
    private(set) var retired = false
    weak var controller: UIViewController?
    func invalidate() {
        generation = UUID()
        let presented = controller
        // UIKit can ignore a dismissal during an unfinished presentation.
        // Retirement is immediate; only removal of the old surface waits.
        if let presented, presented.isBeingPresented, let transition = presented.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { [weak presented] _ in
                presented?.dismiss(animated: false)
            }
        } else if presented?.isBeingDismissed != true {
            presented?.dismiss(animated: false)
        }
    }
    func retire() { retired = true; invalidate() }
    func validity(from anchor: UIView) -> () -> Bool {
        let generation = generation
        return { [weak self, weak anchor] in
            self?.retired == false && self?.generation == generation && anchor?.window != nil
        }
    }
}

/// Single retained glass surface; changes to the view label never move More.
final class MeetingAccessControls: UIView {
    let viewButton = UIButton(type: .system)
    let moreButton = UIButton(type: .system)
    let scaleButton = UIButton(type: .system)
    let pinButton = UIButton(type: .system)
    private let controls = UIView()
    var sharesToolbarSurface = false {
        didSet {
            guard sharesToolbarSurface != oldValue else { return }
            surface.isHidden = sharesToolbarSurface
            (sharesToolbarSurface ? self : surface.contentView).addSubview(controls)
            if !sharesToolbarSurface { controls.accessibilityElements = nil }
            setNeedsLayout()
        }
    }
    var textButton: UIButton? {
        didSet {
            guard oldValue !== textButton else { return }
            oldValue?.removeFromSuperview()
            if let textButton {
                textButton.configuration?.imagePadding = 6
                textButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
                textButton.configuration?.titleTextAttributesTransformer = scaleButton.configuration?.titleTextAttributesTransformer
                controls.addSubview(textButton)
            }
            setNeedsLayout()
        }
    }
    var capturedTextMode = false
    private var textWidth: CGFloat { textButton?.isHidden == false ? 44 : 0 }
    private var scaleWidth: CGFloat { scaleButton.isHidden ? 0 : 44 }
    private let viewSizingButton = UIButton(type: .system)
    private var measuredViewWidth: CGFloat?
    private let reminderIndicator = UIView()
    let reminderHost = MeetingReminderHost()
    private var reminderBadgeCount = 0
    var reminderActions: [UIMenuElement] = []
    func menuWithReminders(_ menu: UIMenu?) -> UIMenu? {
        guard !reminderActions.isEmpty else { return menu }
        return UIMenu(children: [UIMenu(title: L("Next meeting"), options: .displayInline, children: reminderActions)] + (menu?.children ?? []))
    }
    func setReminderBadge(_ count: Int) {
        guard count != reminderBadgeCount else { return }
        reminderBadgeCount = count
        reminderIndicator.isHidden = count == 0
        moreButton.accessibilityValue = count > 0 ? L("%d meeting reminders", count) : nil
    }
    private let surface = MeetingChromeContainer()
    private let divider = UIView()
    private var renderedState: MeetingViewState?
    private var font: UIFont {
        UIFontMetrics(forTextStyle: .callout).scaledFont(for: .systemFont(ofSize: 15, weight: .medium), maximumPointSize: 24,
            compatibleWith: traitCollection)
    }
    private var viewWidth: CGFloat {
        if let measuredViewWidth { return measuredViewWidth }
        var configuration = viewButton.configuration
        configuration?.title = L("View") + " ▾"
        var width: CGFloat = 88
        for symbol in MeetingLayoutMode.allCases.map(\.symbol) + ConferenceDisplayMode.allCases.map(\.symbol) {
            configuration?.image = UIImage(systemName: symbol)
            viewSizingButton.configuration = configuration
            width = max(width, ceil(viewSizingButton.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 48)).width))
        }
        measuredViewWidth = width
        return width
    }
    func fittingSize(availableWidth: CGFloat) -> CGSize {
        if capturedTextMode { return CGSize(width: 264, height: 48) }
        let extras = textWidth + scaleWidth
        return CGSize(width: min(max(88 + extras, availableWidth), viewWidth + 44 + extras), height: 48)
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "Meeting access controls"
        addSubview(surface)
        surface.contentView.addSubview(controls)
        divider.backgroundColor = .separator
        controls.addSubview(divider)
        divider.isUserInteractionEnabled = false
        for button in [viewButton, moreButton, scaleButton, pinButton, viewSizingButton] {
            button.configuration = .plain()
            button.configuration?.baseForegroundColor = .label
            button.configuration?.imagePadding = 6
            button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            button.configuration?.titleLineBreakMode = .byTruncatingTail
            button.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            button.imageView?.adjustsImageSizeForAccessibilityContentSizeCategory = false
            button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [weak self] attributes in
                var attributes = attributes
                attributes.font = self?.font
                return attributes
            }
            controls.addSubview(button)
        }
        viewSizingButton.isHidden = true
        scaleButton.isHidden = true
        pinButton.isHidden = true
        pinButton.accessibilityIdentifier = "call.share.pin"
        viewSizingButton.isUserInteractionEnabled = false
        viewSizingButton.isAccessibilityElement = false
        viewButton.accessibilityIdentifier = "call.view"
        moreButton.accessibilityIdentifier = "call.more"
        moreButton.configuration?.image = UIImage(systemName: "ellipsis")
        moreButton.accessibilityLabel = L("More")
        reminderIndicator.backgroundColor = .systemOrange
        reminderIndicator.layer.cornerRadius = 3
        reminderIndicator.isHidden = true
        reminderIndicator.isUserInteractionEnabled = false
        reminderIndicator.isAccessibilityElement = false
        reminderIndicator.accessibilityIdentifier = "Meeting reminder indicator"
        moreButton.addSubview(reminderIndicator)
    }
    required init?(coder: NSCoder) { nil }
    func setSharePin(from source: UIButton?) {
        if pinButton.isHidden != (source == nil) {
            pinButton.isHidden = source == nil
            setNeedsLayout()
        }
        guard let source else { return }
        if pinButton.accessibilityLabel != source.accessibilityLabel || pinButton.configuration?.image != source.configuration?.image {
            pinButton.configuration?.image = source.configuration?.image
            pinButton.accessibilityLabel = source.accessibilityLabel
            pinButton.largeContentTitle = source.accessibilityLabel
            pinButton.accessibilityHint = source.accessibilityHint
            setNeedsLayout()
        }
        pinButton.isEnabled = source.isEnabled
    }
    private var scaleZoomed = false
    func configureScale(zoomed: Bool, available: Bool) {
        SharedScreenScale.configure(scaleButton, zoomed: zoomed, available: available)
        if zoomed != scaleZoomed { scaleZoomed = zoomed; setNeedsLayout() }
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        measuredViewWidth = nil
        setNeedsLayout(); superview?.setNeedsLayout()
    }
    func update(_ state: MeetingViewState) {
        guard renderedState != state else { return }
        renderedState = state
        viewButton.configuration?.image = UIImage(systemName: state.symbol)
        viewButton.accessibilityLabel = L("View: %@", state.title)
        viewButton.accessibilityValue = L("Layout: %@", state.display == .all ? state.selectedLayout.title : state.layout.title)
        viewButton.accessibilityHint = L("Choose layout and incoming video")
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        surface.frame = bounds
        surface.layoutIfNeeded()
        controls.frame = bounds
        divider.isHidden = sharesToolbarSurface
        if sharesToolbarSurface {
            layoutShareTools()
            return
        }
        if textButton?.configuration?.title != nil { textButton?.configuration?.title = nil }
        if scaleButton.configuration?.title != nil { scaleButton.configuration?.title = nil }
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let leading = textWidth + scaleWidth
        let viewW = max(44, bounds.width - 44 - leading)
        if rtl {
            moreButton.frame = CGRect(x: 0, y: 0, width: 44, height: bounds.height)
            viewButton.frame = CGRect(x: 44, y: 0, width: viewW, height: bounds.height)
            scaleButton.frame = CGRect(x: viewButton.frame.maxX, y: 0, width: scaleWidth, height: bounds.height)
            textButton?.frame = CGRect(x: scaleButton.frame.maxX, y: 0, width: textWidth, height: bounds.height)
            divider.frame = CGRect(x: 44, y: 10, width: 1, height: max(0, bounds.height - 20))
            reminderIndicator.frame = CGRect(x: 7, y: 10, width: 6, height: 6)
        } else {
            textButton?.frame = CGRect(x: 0, y: 0, width: textWidth, height: bounds.height)
            scaleButton.frame = CGRect(x: textWidth, y: 0, width: scaleWidth, height: bounds.height)
            viewButton.frame = CGRect(x: leading, y: 0, width: viewW, height: bounds.height)
            moreButton.frame = CGRect(x: viewButton.frame.maxX, y: 0, width: 44, height: bounds.height)
            divider.frame = CGRect(x: viewButton.frame.maxX, y: 10, width: 1, height: max(0, bounds.height - 20))
            reminderIndicator.frame = CGRect(x: 31, y: 10, width: 6, height: 6)
        }
        let title = viewButton.bounds.width >= viewWidth ? L("View") + " ▾" : nil
        if viewButton.configuration?.title != title { viewButton.configuration?.title = title }
    }

    private func layoutShareTools() {
        let buttons = [textButton, scaleButton, pinButton, viewButton, moreButton].compactMap { $0 }.filter { !$0.isHidden }
        let inset: CGFloat = 4
        var widths = Dictionary(uniqueKeysWithValues: buttons.map { (ObjectIdentifier($0), CGFloat(44)) })
        var spare = max(0, bounds.width - 2 * inset - CGFloat(buttons.count) * 44)
        // Keep at least a 44 pt target for each command. Drop captions that
        // would truncate on narrow phones or at larger Dynamic Type sizes.
        for (button, caption) in [(viewButton, L("View") + " ▾"), (scaleButton, scaleZoomed ? L("Fit") : L("Fill")), (textButton, L("Text"))] {
            guard let button, !button.isHidden else { continue }
            let textWidth = ceil((caption as NSString).size(withAttributes: [.font: font]).width)
            let desiredWidth = max(44, textWidth + 42)
            let extra = desiredWidth - 44
            let title = extra <= spare ? caption : nil
            if title != nil {
                widths[ObjectIdentifier(button)] = desiredWidth
                spare -= extra
            }
            if button.configuration?.title != title { button.configuration?.title = title }
        }
        var x = inset
        let margin = spare / CGFloat(buttons.count)
        for button in buttons {
            let width = widths[ObjectIdentifier(button), default: 44] + margin
            let leading = effectiveUserInterfaceLayoutDirection == .rightToLeft ? bounds.maxX - x - width : x
            button.frame = CGRect(x: leading, y: 0, width: width, height: bounds.height)
            x += width
        }
        controls.accessibilityElements = buttons
        reminderIndicator.frame = CGRect(x: moreButton.bounds.midX + 9, y: 10, width: 6, height: 6)
    }
}

/// Camera-safe content reserves one context row; shared media still uses its
/// full display canvas. Hidden chrome uses the same safe content geometry.
struct MeetingAccessGeometry {
    let toolbar: CGRect
    let access: CGRect
    let pagination: CGRect
    let stage: CGRect
    let inline: Bool
    let combinedShareDock: Bool
    static func availableAccessWidth(base: CallPresentationGeometry, gallery: Bool) -> CGFloat {
        let width = gallery || base.rail ? base.stage.width : base.toolbar.width
        return max(88, width - (gallery ? 160 : 0))
    }
    init(base: CallPresentationGeometry, bounds: CGRect, insets: UIEdgeInsets, accessSize: CGSize, largeText: Bool,
         gallery: Bool = false, focusedShare: Bool = false) {
        let safe = CallPresentationGeometry.safeContentRect(bounds: bounds, insets: insets)
        combinedShareDock = focusedShare && !gallery && base.fold == nil && bounds.height > bounds.width &&
            safe.width >= 228 && safe.width < CallPresentationGeometry.singleRowWidth
        inline = !combinedShareDock && base.fold == nil && !gallery && !base.rail && !largeText && accessSize.height <= 48 && safe.width >= 360 + accessSize.width + 8
        if combinedShareDock {
            access = CGRect(x: base.toolbar.minX, y: base.toolbar.minY - accessSize.height,
                width: base.toolbar.width, height: accessSize.height)
            toolbar = base.toolbar.union(access)
            pagination = .zero
            stage = CGRect(x: base.stage.minX, y: base.stage.minY, width: base.stage.width,
                height: max(0, access.minY - base.stage.minY - 8))
        } else if let fold = base.fold {
            toolbar = base.toolbar
            let width = min(accessSize.width, fold.second.width)
            access = CGRect(x: fold.second.maxX - width, y: toolbar.minY - accessSize.height - 8,
                width: width, height: accessSize.height)
            pagination = CGRect(x: base.stage.minX, y: base.stage.maxY - accessSize.height,
                width: base.stage.width, height: accessSize.height)
            stage = gallery ? CGRect(x: base.stage.minX, y: base.stage.minY, width: base.stage.width,
                height: max(0, pagination.minY - base.stage.minY - 8)) : base.stage
        } else if gallery {
            toolbar = base.toolbar
            let y = base.rail ? safe.maxY - accessSize.height : toolbar.minY - accessSize.height - 8
            access = CGRect(x: base.stage.maxX - accessSize.width, y: y, width: accessSize.width, height: accessSize.height)
            pagination = CGRect(x: base.stage.minX, y: y, width: max(0, access.minX - base.stage.minX - 8), height: accessSize.height)
            stage = CGRect(x: base.stage.minX, y: base.stage.minY, width: base.stage.width,
                height: max(0, y - base.stage.minY - 8))
        } else if base.rail {
            pagination = .zero
            toolbar = base.toolbar
            access = CGRect(x: max(safe.minX, toolbar.minX - accessSize.width - 8), y: safe.maxY - accessSize.height,
                width: accessSize.width, height: accessSize.height)
            stage = CGRect(x: base.stage.minX, y: base.stage.minY, width: base.stage.width,
                height: max(0, access.minY - base.stage.minY - 8))
        } else if inline {
            pagination = .zero
            let width = min(440, safe.width - accessSize.width - 8)
            let x = safe.midX - (width + accessSize.width + 8) / 2
            toolbar = CGRect(x: x, y: base.toolbar.minY, width: width + accessSize.width + 8, height: base.toolbar.height)
            access = CGRect(x: toolbar.maxX - 54 - 8 - accessSize.width, y: toolbar.midY - accessSize.height / 2,
                width: accessSize.width, height: accessSize.height)
            stage = base.stage
        } else {
            pagination = .zero
            toolbar = base.toolbar
            access = CGRect(x: toolbar.maxX - min(accessSize.width, toolbar.width),
                y: toolbar.minY - accessSize.height - 8, width: min(accessSize.width, toolbar.width), height: accessSize.height)
            stage = CGRect(x: base.stage.minX, y: base.stage.minY, width: base.stage.width,
                height: max(0, access.minY - base.stage.minY - 8))
        }
    }
}

struct MeetingViewContent: View {
    let state: MeetingViewState
    var companionActions: [UIMenuElement] = []
    var performAction: (UIAction) -> Void = { _ in }
    let close: () -> Void
    let chooseLayout: (MeetingLayoutMode) -> Void
    let chooseDisplay: (ConferenceDisplayMode) -> Void
    let followSpeaker: () -> Void
    var body: some View {
        NavigationStack {
            List {
                if !companionActions.isEmpty {
                    Section(L("Shared content")) { MeetingActionRows(elements: companionActions, perform: performAction) }
                }
                Section {
                    ForEach(MeetingLayoutMode.allCases, id: \.self) { mode in
                        choice(mode.title, symbol: mode.symbol, selected: state.selectedLayout == mode,
                            identifier: "meeting.view.layout.\(mode == .grid ? "gallery" : "focus")") { chooseLayout(mode) }
                            .disabled(!state.permitsLayout || (mode == .grid && !state.galleryAvailable))
                    }
                } header: { Text(L("Layout")) } footer: {
                    if !state.galleryAvailable { Text(L("Gallery is available when more participants or screens are present.")) }
                }
                Section {
                    ForEach(Array(ConferenceDisplayMode.allCases.enumerated()), id: \.offset) { _, mode in
                        choice(mode == .screenShares ? L("Screen sharing only") : mode.title, symbol: mode.symbol,
                            selected: state.display == mode, identifier: "meeting.view.receive.\(mode.identifier)") { chooseDisplay(mode) }
                    }
                } header: { Text(L("Receive video")) } footer: { Text(L("Changes your incoming video only.")) }
                if state.manualFocus && state.permitsLayout {
                    Button(action: followSpeaker) { Label(L("Follow speaker"), systemImage: "waveform").frame(minHeight: 44) }
                        .accessibilityIdentifier("meeting.view.follow")
                }
            }.listStyle(.insetGrouped).accessibilityIdentifier("meeting.view.list")
                .navigationTitle(L("View")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done"), action: close).accessibilityIdentifier("meeting.view.done")
                } }
        }.tint(Color(red: 1, green: 0.60, blue: 0.33))
    }
    private func choice(_ title: String, symbol: String, selected: Bool, identifier: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 24).accessibilityHidden(true)
                Text(title).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }.frame(minHeight: 44)
        }.accessibilityIdentifier(identifier).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension ConferenceDisplayMode {
    var identifier: String {
        switch self { case .all: "all"; case .screenShares: "shares"; case .audioOnly: "audio" }
    }
}
