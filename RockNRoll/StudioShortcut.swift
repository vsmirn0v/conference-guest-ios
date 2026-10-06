import UIKit
import ObjectiveC

/// A held press consumes the short-tap action. Secondary click and VoiceOver
/// expose the same direct action without adding a toolbar row.
@MainActor
final class StudioShortcut: NSObject {
    private static var association: UInt8 = 0
    private let show: () -> Void
    private init(show: @escaping () -> Void) { self.show = show }

    static func install(on button: UIView, pane: StudioModel.Pane, model: StudioModel) {
        let shortcut = StudioShortcut { [weak button, weak model] in
            guard let button, let model else { return }
            StudioPresentation.show(model, from: button, pane: pane)
        }
        objc_setAssociatedObject(button, &association, shortcut, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let hold = UILongPressGestureRecognizer(target: shortcut, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.45
        hold.cancelsTouchesInView = true
        button.addGestureRecognizer(hold)
        let secondary = UITapGestureRecognizer(target: shortcut, action: #selector(open))
        secondary.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        secondary.buttonMaskRequired = .secondary
        button.addGestureRecognizer(secondary)
        button.showsLargeContentViewer = false
        let label = pane == .camera ? L("Preview and camera settings") : L("Sound settings")
        button.accessibilityHint = L("Touch and hold to configure without turning it on.")
        button.accessibilityCustomActions = [UIAccessibilityCustomAction(name: label, target: shortcut, selector: #selector(open))]
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        show()
    }
    @objc private func open() -> Bool { show(); return true }
}
