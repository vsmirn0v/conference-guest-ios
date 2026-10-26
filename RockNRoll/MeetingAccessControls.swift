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
    var permitsLayout: Bool { display != .audioOnly }
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
    var textButton: UIButton? {
        didSet {
            guard oldValue !== textButton else { return }
            oldValue?.removeFromSuperview()
            if let textButton { surface.contentView.addSubview(textButton) }
            setNeedsLayout()
        }
    }
    var capturedTextMode = false
    private var textWidth: CGFloat { textButton?.isHidden == false ? 44 : 0 }
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
        return CGSize(width: min(max(88 + textWidth, availableWidth), viewWidth + 44 + textWidth), height: 48)
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "Meeting access controls"
        addSubview(surface)
        divider.backgroundColor = .separator
        surface.contentView.addSubview(divider)
        for button in [viewButton, moreButton, viewSizingButton] {
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
            surface.contentView.addSubview(button)
        }
        viewSizingButton.isHidden = true
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
        surface.frame = bounds; surface.layoutIfNeeded()
        textButton?.frame = CGRect(x: 0, y: 0, width: textWidth, height: bounds.height)
        viewButton.frame = CGRect(x: textWidth, y: 0, width: max(44, bounds.width - 44 - textWidth), height: bounds.height)
        moreButton.frame = CGRect(x: viewButton.frame.maxX, y: 0, width: 44, height: bounds.height)
        let title = viewButton.bounds.width >= viewWidth ? L("View") + " ▾" : nil
        if viewButton.configuration?.title != title { viewButton.configuration?.title = title }
        divider.frame = CGRect(x: viewButton.frame.maxX, y: 10, width: 1, height: max(0, bounds.height - 20))
        reminderIndicator.frame = CGRect(x: 31, y: 10, width: 6, height: 6)
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
    static func availableAccessWidth(base: CallPresentationGeometry, gallery: Bool) -> CGFloat {
        let width = gallery || base.rail ? base.stage.width : base.toolbar.width
        return max(88, width - (gallery ? 160 : 0))
    }
    init(base: CallPresentationGeometry, bounds: CGRect, insets: UIEdgeInsets, accessSize: CGSize, largeText: Bool,
         gallery: Bool = false) {
        let safe = bounds.inset(by: insets).insetBy(dx: 8, dy: 4)
        inline = !gallery && !base.rail && !largeText && accessSize.height <= 48 && safe.width >= 360 + accessSize.width + 8
        if gallery {
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
                    if !state.permitsLayout { Text(L("Your layout is remembered while Audio only is selected.")) }
                    else if !state.galleryAvailable { Text(L("Gallery is available when more participants or screens are present.")) }
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
