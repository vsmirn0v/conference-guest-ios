import UIKit

/// A retained, noninteractive background for controls outside the meeting video.
final class MeetingChromeSurface: UIView {
    static let toolbarFallbackColor = UIColor(red: 0.12, green: 0.14, blue: 0.21, alpha: 1)

    struct AccessibilityState {
        var reduceTransparency: Bool
        var increaseContrast: Bool
        var reduceMotion: Bool

        static var current: Self {
            Self(reduceTransparency: UIAccessibility.isReduceTransparencyEnabled,
                 increaseContrast: UIAccessibility.isDarkerSystemColorsEnabled,
                 reduceMotion: UIAccessibility.isReduceMotionEnabled)
        }

        var requiresSolid: Bool { reduceTransparency || increaseContrast || reduceMotion }
    }

    private let fallbackColor: UIColor
    private let accessibilityState: () -> AccessibilityState
    private var glassView: UIVisualEffectView?
    private var usesGlass: Bool?
    private var observers: [NSObjectProtocol] = []
    #if DEBUG
    private static let forceSolidForProfiling = ProcessInfo.processInfo.environment["MEETING_CHROME_SOLID"] == "1"
    #endif

    init(cornerRadius: CGFloat = 16, fallbackColor: UIColor = MeetingChromeSurface.toolbarFallbackColor,
         accessibilityState: @escaping () -> AccessibilityState = { .current }) {
        self.fallbackColor = fallbackColor
        self.accessibilityState = accessibilityState
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true
        for name in [UIAccessibility.reduceTransparencyStatusDidChangeNotification,
                     UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
                     UIAccessibility.reduceMotionStatusDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.refreshAccessibilityAppearance()
            })
        }
        refreshAccessibilityAppearance()
    }

    required init?(coder: NSCoder) { nil }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshAccessibilityAppearance()
    }

    private func refreshAccessibilityAppearance() {
        var available = false
        if #available(iOS 26.0, *) { available = true }
        #if DEBUG
        // A launch-only profiling control, never a persisted user preference.
        if Self.forceSolidForProfiling { available = false }
        #endif
        let enabled = available && !accessibilityState().requiresSolid && traitCollection.accessibilityContrast != .high
        guard usesGlass != enabled else { return }
        usesGlass = enabled
        if enabled, glassView == nil, #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = false
            let view = UIVisualEffectView(effect: effect)
            view.isUserInteractionEnabled = false
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.layer.cornerRadius = layer.cornerRadius
            view.layer.cornerCurve = .continuous
            view.cornerConfiguration = .corners(radius: .fixed(Double(layer.cornerRadius)))
            view.clipsToBounds = true
            addSubview(view)
            glassView = view
        }
        backgroundColor = enabled ? .clear : fallbackColor
        glassView?.isHidden = !enabled
    }

    /// A transparent Core Animation mask hides only rendering. The system picker
    /// retains its bounds, interaction, accessibility, and presentation lifecycle.
    static func hidePickerArtwork(in picker: UIView) {
        let mask = CALayer()
        mask.opacity = 0
        picker.layer.mask = mask
    }
}

/// Interactive regular glass: semantic controls live inside the effect's content
/// hierarchy so UIKit can adapt their foreground to the material underneath.
final class MeetingChromeContainer: UIView {
    let contentView = UIView()
    private let effectView = UIVisualEffectView()
    private var observers: [NSObjectProtocol] = []
    private var glassEnabled: Bool?
    #if DEBUG
    private static let forceSolidForProfiling = ProcessInfo.processInfo.environment["MEETING_CHROME_SOLID"] == "1"
    #endif
    init(radius: CGFloat = 24) {
        super.init(frame: .zero)
        layer.cornerRadius = radius; layer.cornerCurve = .continuous; clipsToBounds = true
        addSubview(effectView); effectView.contentView.addSubview(contentView)
        effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        for name in [UIAccessibility.reduceTransparencyStatusDidChangeNotification,
                     UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
                     UIAccessibility.reduceMotionStatusDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateAppearance()
            })
        }
        updateAppearance()
    }
    required init?(coder: NSCoder) { nil }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    override func layoutSubviews() {
        super.layoutSubviews(); effectView.frame = bounds; effectView.layoutIfNeeded()
        contentView.frame = effectView.contentView.bounds
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection); updateAppearance()
    }
    private func updateAppearance() {
        var enabled = false
        if #available(iOS 26, *) {
            enabled = !UIAccessibility.isReduceTransparencyEnabled && !UIAccessibility.isDarkerSystemColorsEnabled && !UIAccessibility.isReduceMotionEnabled && traitCollection.accessibilityContrast != .high
        }
        #if DEBUG
        if Self.forceSolidForProfiling { enabled = false }
        #endif
        guard glassEnabled != enabled else { return }
        glassEnabled = enabled
        if #available(iOS 26, *), enabled {
            let glass = UIGlassEffect(style: .regular); glass.isInteractive = false
            effectView.effect = glass; backgroundColor = .clear
        } else {
            effectView.effect = nil; backgroundColor = .secondarySystemBackground
        }
    }
}
