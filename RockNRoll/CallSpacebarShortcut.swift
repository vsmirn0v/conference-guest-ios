import UIKit

/// Unmodified Space is a meeting shortcut only when it bubbles out of controls.
/// Handle physical presses rather than key-command repeats: one toggle per hold.
@MainActor
final class CallSpacebarShortcut {
    private var down = false
    private var resignObserver: NSObjectProtocol?

    init() {
        resignObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reset() } }
    }
    deinit { if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) } }

    func began(_ presses: Set<UIPress>, in view: UIView, toggle: () -> Void) -> Set<UIPress> {
        guard ProcessInfo.processInfo.isiOSAppOnMac, let window = view.window,
              window.windowScene?.activationState == .foregroundActive,
              Self.allowsShortcut(in: window) else { return presses }
        var front = window.rootViewController
        while let presented = front?.presentedViewController { front = presented }
        guard let content = front?.viewIfLoaded, view.isDescendant(of: content) else { return presses }
        let spaces = presses.filter { Self.isSpace($0) }
        guard !spaces.isEmpty else { return presses }
        if pressBegan() { toggle() }
        return presses.subtracting(spaces)
    }

    func ended(_ presses: Set<UIPress>) -> Set<UIPress> {
        guard down else { return presses }
        let spaces = presses.filter { $0.key?.keyCode == .keyboardSpacebar }
        if !spaces.isEmpty { reset() }
        return presses.subtracting(spaces)
    }

    func pressBegan() -> Bool {
        guard !down else { return false }
        down = true
        return true
    }
    func reset() { down = false }

    static func allowsShortcut(in view: UIView) -> Bool {
        // Also protects docked chat, search fields and accessible focused buttons.
        if view.isFirstResponder, view is UIKeyInput || view is UIControl { return false }
        return view.subviews.allSatisfy { allowsShortcut(in: $0) }
    }
    private static func isSpace(_ press: UIPress) -> Bool {
        guard let key = press.key, key.keyCode == .keyboardSpacebar else { return false }
        return key.modifierFlags.intersection([.command, .alternate, .control, .shift]).isEmpty
    }
}
