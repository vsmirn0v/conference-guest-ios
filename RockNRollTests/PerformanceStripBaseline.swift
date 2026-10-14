#if DEBUG
import UIKit
@testable import RockNRoll

// Exact baseline renderer from 50f5420, confined to the opt-in comparison.
final class PerformanceStripBaseline: UIScrollView {
    private var buttons: [String: UIButton] = [:]
    private var items: [MeetingStripItem] = []
    private var selectedID: String?
    var onSelect: ((String) -> Void)?
    var vertical = false { didSet { if oldValue != vertical { setNeedsLayout() } } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "Focus participants"
        delaysContentTouches = false
        showsVerticalScrollIndicator = true; showsHorizontalScrollIndicator = true
    }
    required init?(coder: NSCoder) { nil }
    override func touchesShouldCancel(in view: UIView) -> Bool {
        // Buttons highlight immediately, but a drag must cancel their tap and
        // scroll from anywhere on the chip, not only the gaps between chips.
        view is UIButton || super.touchesShouldCancel(in: view)
    }
    func update(_ items: [MeetingStripItem], selected: String?) {
        guard self.items != items || selectedID != selected else { return }
        self.items = items
        selectedID = selected
        let current = Set(items.map(\.id))
        for key in buttons.keys.filter({ !current.contains($0) }) { buttons.removeValue(forKey: key)?.removeFromSuperview() }
        for item in items {
            let button: UIButton
            if let existing = buttons[item.id] { button = existing }
            else {
                button = UIButton(type: .system); button.configuration = .tinted()
                button.accessibilityIdentifier = "Focus participant." + item.id
                button.addAction(UIAction { [weak self] _ in self?.onSelect?(item.id) }, for: .touchUpInside)
                buttons[item.id] = button; addSubview(button)
            }
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
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        for (index, item) in items.enumerated() {
            buttons[item.id]?.frame = vertical
                ? CGRect(x: 0, y: CGFloat(index) * 52, width: bounds.width, height: 46)
                : CGRect(x: CGFloat(index) * 160, y: 0, width: 152, height: bounds.height)
        }
        contentSize = vertical ? CGSize(width: bounds.width, height: CGFloat(items.count) * 52) :
            CGSize(width: CGFloat(items.count) * 160, height: bounds.height)
    }
}

#endif
