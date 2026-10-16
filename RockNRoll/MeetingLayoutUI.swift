import ConferenceCore
import UIKit

enum MeetingTileAppearance {
    static func update(_ view: UIView, speaking: Bool) {
        view.layer.cornerRadius = 14
        view.layer.borderWidth = speaking ? 3 : 1
        view.layer.borderColor = (speaking ? UIColor.systemGreen : UIColor.separator).resolvedColor(with: view.traitCollection).cgColor
        view.clipsToBounds = true
    }
}

/// A camera-off tile identifies a person rather than repeating camera status.
final class ParticipantIdentityView: UIView {
    private let initials = UILabel()
    private let name = UILabel()
    private let microphone = ParticipantMediaBadge()
    private var participantName = ""
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .secondarySystemBackground
        initials.textAlignment = .center
        initials.textColor = .secondaryLabel
        initials.backgroundColor = .tertiarySystemBackground
        initials.layer.cornerRadius = 22; initials.clipsToBounds = true
        initials.font = .preferredFont(forTextStyle: .headline)
        name.font = .preferredFont(forTextStyle: .title3)
        name.adjustsFontForContentSizeCategory = true
        name.numberOfLines = 2; name.textAlignment = .center
        name.textColor = .label
        name.accessibilityIdentifier = "Participant name"
        microphone.backgroundColor = .clear
        microphone.accessibilityIdentifier = "Participant microphone"
        [initials, name, microphone].forEach(addSubview)
    }
    required init?(coder: NSCoder) { nil }
    func update(name: String, microphoneOn: Bool, speaking: Bool) {
        participantName = name
        self.name.text = name
        initials.text = name.split(whereSeparator: { $0.isWhitespace }).prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        updateAudio(ParticipantAudioState(microphoneOn: microphoneOn, speaking: speaking))
        setNeedsLayout()
    }
    func updateAudio(_ state: ParticipantAudioState) {
        microphone.update(name: "", microphoneOn: state.microphoneOn, speaking: state.speaking)
        microphone.accessibilityLabel = participantName
        name.accessibilityValue = !state.microphoneOn ? L("Microphone off") : state.speaking ? L("Speaking") : L("Microphone on")
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let text = name.sizeThatFits(CGSize(width: max(0, bounds.width - 32), height: bounds.height))
        let proposedAvatar: CGFloat = bounds.height > 160 ? 44 : 32
        let avatar: CGFloat = text.height + proposedAvatar + 58 <= bounds.height ? proposedAvatar : 0
        let gap: CGFloat = avatar > 0 ? 10 : 0
        let height = min(text.height, max(0, bounds.height - 48))
        let total = avatar + gap + height
        initials.isHidden = avatar == 0
        initials.layer.cornerRadius = avatar / 2
        initials.frame = CGRect(x: (bounds.width - avatar) / 2, y: max(8, (bounds.height - 32 - total) / 2), width: avatar, height: avatar)
        name.frame = CGRect(x: 16, y: initials.frame.maxY + gap, width: max(0, bounds.width - 32), height: height)
        microphone.frame = CGRect(x: max(8, bounds.width - 42), y: max(0, bounds.height - 32), width: 32, height: 24)
    }
}

/// The same visible layout and page controls are used by every media engine.
final class MeetingLayoutControls: UIView {
    let layout = UISegmentedControl(items: [L("Gallery"), L("Focus")])
    private let picker = MeetingMenuButton(type: .system)
    private let surface = MeetingChromeSurface(cornerRadius: 22)
    let automatic = UIButton(type: .system)
    let previous = UIButton(type: .system)
    let nextPage = UIButton(type: .system)
    private let position = UILabel()
    private var renderedMode: MeetingLayoutMode?
    private struct State: Equatable {
        let mode: MeetingLayoutMode
        let manual: Bool
        let page: Int
        let capacity: Int
        let pages: Int
        let count: Int
    }
    private var renderedState: State?
    var onMenuVisibilityChanged: ((Bool) -> Void)? { didSet { picker.onMenuVisibilityChanged = onMenuVisibilityChanged } }
    var onLayout: ((MeetingLayoutMode) -> Void)?
    var onAutomatic: (() -> Void)?
    var onPage: ((Int) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "Meeting layout controls"
        addSubview(surface)
        picker.configuration = .plain()
        picker.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFontMetrics(forTextStyle: .callout).scaledFont(for: .systemFont(ofSize: 15, weight: .medium), maximumPointSize: 24)
            return attributes
        }
        picker.titleLabel?.numberOfLines = 1
        picker.configuration?.titleLineBreakMode = .byTruncatingTail
        picker.showsMenuAsPrimaryAction = true
        picker.accessibilityIdentifier = "Meeting view picker"
        addSubview(picker)
        layout.isHidden = true
        layout.accessibilityIdentifier = "Meeting layout"
        layout.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onLayout?(self.layout.selectedSegmentIndex == 0 ? .grid : .speaker)
        }, for: .valueChanged)
        automatic.configuration = .plain()
        automatic.configuration?.title = L("Follow speaker")
        automatic.configuration?.image = UIImage(systemName: "waveform")
        automatic.configuration?.imagePadding = 5
        automatic.accessibilityIdentifier = "Follow speaker"
        automatic.addAction(UIAction { [weak self] _ in self?.onAutomatic?() }, for: .touchUpInside)
        for (button, symbol, label, step) in [(previous, "chevron.left", "Previous participants", -1), (nextPage, "chevron.right", "Next participants", 1)] {
            button.configuration = .plain(); button.configuration?.image = UIImage(systemName: symbol)
            button.accessibilityLabel = L(label); button.accessibilityIdentifier = label
            button.addAction(UIAction { [weak self] _ in self?.onPage?(step) }, for: .touchUpInside)
        }
        position.font = .preferredFont(forTextStyle: .caption1); position.textColor = .secondaryLabel
        position.textAlignment = .center; position.accessibilityIdentifier = "Gallery page"
        [layout, automatic, previous, position, nextPage].forEach(addSubview)
    }
    required init?(coder: NSCoder) { nil }
    func update(mode: MeetingLayoutMode, manual: Bool, page: Int, pagination: MeetingTileLayout.GalleryPage?, count: Int) {
        let state = State(mode: mode, manual: manual, page: page, capacity: pagination?.capacity ?? 1,
            pages: pagination?.pageCount ?? 1, count: count)
        guard renderedState != state else { return }
        renderedState = state
        let selection = mode == .grid ? 0 : 1
        if renderedMode != mode {
            renderedMode = mode
            layout.selectedSegmentIndex = selection
        }
        automatic.isHidden = mode == .grid
        automatic.isEnabled = manual
        automatic.configuration?.title = L(manual ? "Follow speaker" : "Following speaker")
        picker.configuration?.title = L(mode == .grid ? "Gallery" : manual ? "Pinned" : "Focus")
        picker.configuration?.image = UIImage(systemName: mode == .grid ? "square.grid.2x2" : manual ? "pin.fill" : "person.crop.rectangle")
        picker.configuration?.imagePadding = 6
        picker.menu = UIMenu(children: MeetingLayoutMode.allCases.map { option in
            UIAction(title: option.title, image: UIImage(systemName: option.symbol), state: mode == option ? .on : .off) { [weak self] _ in self?.onLayout?(option) }
        } + [UIAction(title: L("Follow speaker"), image: UIImage(systemName: "waveform")) { [weak self] _ in self?.onAutomatic?() }])
        automatic.isHidden = true
        let pages = mode == .grid ? pagination?.pageCount ?? 1 : 1
        [previous, position, nextPage].forEach { $0.isHidden = pages <= 1 }
        previous.isEnabled = page > 0; nextPage.isEnabled = page < pages - 1
        if let range = pagination?.range(page: page, count: count), !range.isEmpty {
            position.text = L("%ld–%ld of %ld", range.lowerBound + 1, range.upperBound, count)
        }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        surface.frame = bounds
        let width = previous.isHidden ? bounds.width : min(132, max(88, bounds.width - 144))
        picker.frame = CGRect(x: 0, y: 0, width: width, height: 44)
        nextPage.frame = CGRect(x: bounds.width - 44, y: 0, width: 44, height: 44)
        previous.frame = CGRect(x: width + 4, y: 0, width: 44, height: 44)
        position.frame = CGRect(x: previous.frame.maxX, y: 0, width: max(0, nextPage.frame.minX - previous.frame.maxX), height: 44)
    }
}

struct MeetingStripItem: Equatable {
    let id: String
    let name: String
    let isShare: Bool
    let audio: ParticipantAudioState
}

/// Only mounted, visible cells request preview rendering from existing media sources.
final class MeetingParticipantStrip: UIScrollView, UIScrollViewDelegate {
    private var buttons: [String: UIButton] = [:]
    private var items: [MeetingStripItem] = []
    private var selectedID: String?
    #if DEBUG
    private(set) var buttonUpdateCount = 0
    #endif
    var onSelect: ((String) -> Void)?
    var previewProvider: ((String) -> UIView?)? { didSet { refreshPreviews() } }
    var onPreviewVisibilityChanged: (() -> Void)?
    private var previews: [String: UIView] = [:]
    private var observers: [NSObjectProtocol] = []
    private(set) var visiblePreviewIDs = Set<String>()
    override var isHidden: Bool { didSet { if oldValue != isHidden { refreshPreviews() } } }
    var vertical = false { didSet { if oldValue != vertical { setNeedsLayout() } } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "Focus participants"
        delaysContentTouches = false
        delegate = self
        showsVerticalScrollIndicator = true; showsHorizontalScrollIndicator = true
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPreviews() }
            })
        }
    }
    required init?(coder: NSCoder) { nil }
    override func touchesShouldCancel(in view: UIView) -> Bool {
        // Buttons highlight immediately, but a drag must cancel their tap and
        // scroll from anywhere on the chip, not only the gaps between chips.
        view is UIButton || super.touchesShouldCancel(in: view)
    }
    func update(_ items: [MeetingStripItem], selected: String?) {
        guard self.items != items || selectedID != selected else { return }
        let previous = Dictionary(self.items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let previousSelection = selectedID
        let layoutChanged = self.items.map(\.id) != items.map(\.id)
        self.items = items
        selectedID = selected
        let current = Set(items.map(\.id))
        for key in buttons.keys.filter({ !current.contains($0) }) { buttons.removeValue(forKey: key)?.removeFromSuperview() }
        for item in items {
            let button: UIButton
            if let existing = buttons[item.id] { button = existing }
            else {
                button = UIButton(type: .system); button.configuration = .tinted()
                button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                    var attributes = attributes; attributes.font = UIFont.preferredFont(forTextStyle: .caption1); return attributes
                }
                button.accessibilityIdentifier = "Focus participant." + item.id
                button.addAction(UIAction { [weak self] _ in self?.onSelect?(item.id) }, for: .touchUpInside)
                buttons[item.id] = button; addSubview(button)
            }
            guard previous[item.id] != item || (previousSelection == item.id) != (selected == item.id) else { continue }
            #if DEBUG
            buttonUpdateCount += 1
            #endif
            button.configuration?.title = item.name
            button.configuration?.titleLineBreakMode = .byTruncatingTail
            button.configuration?.image = UIImage(systemName: item.isShare ? "rectangle.on.rectangle" : !item.audio.microphoneOn ? "mic.slash.fill" : item.audio.speaking ? "waveform" : "mic.fill")
            button.configuration?.imagePadding = 6
            button.configuration?.baseForegroundColor = item.audio.speaking ? .systemGreen : .label
            button.configuration?.baseBackgroundColor = .secondarySystemBackground
            button.layer.cornerRadius = 10; button.layer.borderWidth = 1
            button.layer.borderColor = (selected == item.id ? UIColor.systemOrange : UIColor.separator).resolvedColor(with: traitCollection).cgColor
            button.accessibilityLabel = L("Focus %@", item.name) + (item.isShare ? " · " + L("Screen share") : "")
            button.accessibilityTraits = selected == item.id ? [.button, .selected] : .button
        }
        if layoutChanged { setNeedsLayout() }
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) != false else { return }
        for (id, button) in buttons {
            button.layer.borderColor = (selectedID == id ? UIColor.systemOrange : UIColor.separator).resolvedColor(with: traitCollection).cgColor
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        for (index, item) in items.enumerated() {
            buttons[item.id]?.frame = vertical
                ? CGRect(x: 0, y: CGFloat(index) * 100, width: bounds.width, height: 92)
                : CGRect(x: CGFloat(index) * 112, y: 0, width: 104, height: bounds.height)
        }
        contentSize = vertical ? CGSize(width: bounds.width, height: CGFloat(items.count) * 100) :
            CGSize(width: CGFloat(items.count) * 112, height: bounds.height)
        refreshPreviews()
    }
    override func didMoveToWindow() { super.didMoveToWindow(); refreshPreviews() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { refreshPreviews() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    /// Reconcile an active source replacement or a camera stopping without waiting for a scroll.
    func reloadPreviews() {
        for preview in previews.values { preview.removeFromSuperview() }
        previews.removeAll()
        refreshPreviews()
    }
    private func refreshPreviews() {
        let visible = Set(items.compactMap { item -> String? in
            guard !isHidden, window != nil, UIApplication.shared.applicationState != .background, let button = buttons[item.id], bounds.intersects(button.frame) else { return nil }
            return item.id
        })
        for id in previews.keys.filter({ !visible.contains($0) }) { previews.removeValue(forKey: id)?.removeFromSuperview() }
        for id in visible {
            guard let button = buttons[id] else { continue }
            if previews[id] == nil {
                let fallback = UILabel()
                fallback.font = .preferredFont(forTextStyle: .title3)
                fallback.textAlignment = .center; fallback.textColor = .secondaryLabel
                fallback.backgroundColor = .tertiarySystemBackground
                let view = previewProvider?(id) ?? fallback
                previews[id] = view; view.isUserInteractionEnabled = false
                view.clipsToBounds = true; view.layer.cornerRadius = 10
                button.addSubview(view)
            }
            if let initials = previews[id] as? UILabel, let item = items.first(where: { $0.id == id }) {
                initials.text = item.name.split(whereSeparator: { $0.isWhitespace }).prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
            }
            let font = UIFont.preferredFont(forTextStyle: .caption1)
            let caption = min(button.bounds.height / 2, max(25, ceil(font.lineHeight) + 6))
            // Preview leaves a dedicated, readable microphone/name caption.
            previews[id]?.frame = CGRect(x: 2, y: 2, width: max(0, button.bounds.width - 4), height: max(0, button.bounds.height - caption - 4))
            let inset = max(0, button.bounds.height - caption)
            if button.configuration?.contentInsets.top != inset {
                button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: inset, leading: 6, bottom: 3, trailing: 6)
            }
        }
        if visiblePreviewIDs != visible { visiblePreviewIDs = visible; onPreviewVisibilityChanged?() }
    }
}
