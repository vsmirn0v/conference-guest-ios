import UIKit

@MainActor
final class CallFocusController {
    static let preferenceKey = "automaticallyHideMeetingControls"
    private(set) var hidden = false
    var onChange: ((Bool) -> Void)?
    var canHide: (() -> Bool)?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var keyboardVisible = false
    private var hideAfterMenu = false
    var menuVisible = false { didSet {
        if menuVisible { invalidate() }
        else if hideAfterMenu { hideAfterMenu = false; hide() }
        else { interaction() }
    } }

    init() {
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
        get { UserDefaults.standard.bool(forKey: Self.preferenceKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.preferenceKey); interaction() }
    }
    func toggle() { hidden ? show() : hide() }
    func hide(automatic: Bool = false) {
        if menuVisible && !automatic { hideAfterMenu = true; return }
        guard !keyboardVisible, !menuVisible, canHide?() != false,
              !automatic || !UIAccessibility.isVoiceOverRunning else { return }
        timer?.invalidate(); timer = nil
        guard !hidden else { return }
        hidden = true; onChange?(true)
    }
    func show() {
        hideAfterMenu = false
        timer?.invalidate(); timer = nil
        if hidden { hidden = false; onChange?(false) }
    }
    func interaction() {
        timer?.invalidate(); timer = nil
        guard automaticallyHides, !hidden, !menuVisible, !UIAccessibility.isVoiceOverRunning else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in Task { @MainActor [weak self] in self?.hide(automatic: true) } }
    }
    func invalidate() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver) }
}
