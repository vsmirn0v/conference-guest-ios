import UIKit

@MainActor
final class CallFocusController {
    static let preferenceKey = "automaticallyHideMeetingControls"
    static let hintPreferenceKey = "hasSeenMeetingControlsHint"
    private(set) var hidden = false
    var onChange: ((Bool) -> Void)?
    var canHide: (() -> Bool)?
    private var timer: Timer?
    private let hint = UIStackView()
    private var hintTimer: Timer?
    private var hasShownHint = false
    private var observers: [NSObjectProtocol] = []
    private var keyboardVisible = false
    private var hideAfterMenu = false
    private let defaults: UserDefaults
    var menuVisible = false { didSet {
        if menuVisible { invalidate() }
        else if hideAfterMenu { hideAfterMenu = false; hide() }
        else { interaction() }
    } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for name in [UIAccessibility.voiceOverStatusDidChangeNotification,
                     UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillHideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if note.name == UIResponder.keyboardWillShowNotification { self.keyboardVisible = true }
                    if note.name == UIResponder.keyboardWillHideNotification { self.keyboardVisible = false }
                    if self.keyboardVisible || UIAccessibility.isVoiceOverRunning { self.show() }
                }
            })
        }
    }
    var automaticallyHides: Bool {
        get { defaults.bool(forKey: Self.preferenceKey) }
        set { defaults.set(newValue, forKey: Self.preferenceKey); interaction() }
    }
    func installHint(in view: UIView) {
        let label = UILabel()
        label.text = ProcessInfo.processInfo.isiOSAppOnMac ? L("Click anywhere to show controls · Esc") : L("Tap anywhere to show controls")
        label.font = .preferredFont(forTextStyle: .callout)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.accessibilityIdentifier = "Meeting controls hint"
        hint.addArrangedSubview(label)
        hint.isLayoutMarginsRelativeArrangement = true
        hint.layoutMargins = .init(top: 10, left: 14, bottom: 10, right: 14)
        hint.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        hint.layer.cornerRadius = 12
        hint.isUserInteractionEnabled = false
        hint.isHidden = true
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            hint.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32)
        ])
    }
    func toggle() {
        if hidden { show(); interaction() } else { hide() }
    }
    func restoreAccessibilityAction() -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: L("Show controls")) { [weak self] _ in
            guard let self else { return false }
            self.show(); self.interaction()
            return true
        }
    }
    func hide(automatic: Bool = false) {
        if menuVisible && !automatic { hideAfterMenu = true; return }
        guard !keyboardVisible, !menuVisible, canHide?() != false,
              !automatic || !UIAccessibility.isVoiceOverRunning else { return }
        timer?.invalidate(); timer = nil
        guard !hidden else { return }
        hidden = true; onChange?(true)
        if !hasShownHint, hint.superview != nil, !UIAccessibility.isVoiceOverRunning,
           !defaults.bool(forKey: Self.hintPreferenceKey) {
            hasShownHint = true
            defaults.set(true, forKey: Self.hintPreferenceKey)
            hint.alpha = 1; hint.isHidden = false
            hintTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2) { self.hint.alpha = 0 }
                }
            }
        }
    }
    func show() {
        dismissHint()
        hideAfterMenu = false
        timer?.invalidate(); timer = nil
        if hidden { hidden = false; onChange?(false) }
    }
    func interaction() {
        timer?.invalidate(); timer = nil
        guard automaticallyHides, !hidden, !menuVisible, !UIAccessibility.isVoiceOverRunning else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in Task { @MainActor [weak self] in self?.hide(automatic: true) } }
    }
    private func dismissHint() {
        hintTimer?.invalidate(); hintTimer = nil
        hint.layer.removeAllAnimations(); hint.isHidden = true
    }
    func invalidate() { timer?.invalidate(); timer = nil; dismissHint() }
    deinit { timer?.invalidate(); hintTimer?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver) }
}
