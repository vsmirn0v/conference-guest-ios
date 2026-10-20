import Combine
import UIKit

/// Explicit endpoint shared by the SDK overlay and the three native call renderers.
@MainActor final class MeetingReminderHost {
    weak var surface: UIView?
    weak var access: MeetingAccessControls?
    weak var toolbar: UIView?
    var blocked: () -> Bool = { false }
    var privateContent: () -> Bool = { false }
    var onChange: (() -> Void)?
    var collapseReminder: (() -> Bool)?
    private var scheduled = false
    private var observations: [NSObjectProtocol] = []
    private var keyboardVisible = false
    private weak var observedStudio: StudioModel?
    private var studioSubscription: AnyCancellable?
    private var touch: ReminderTouchObserver?
    private var touchWasActive = false
    private var layoutState: LayoutState?
    private struct LayoutState: Equatable {
        let bounds: CGRect
        let insets: UIEdgeInsets
        let access: CGRect
        let toolbar: CGRect
        let hidden: Bool
        let blocked: Bool
        let privateContent: Bool
        let window: ObjectIdentifier?
        let usable: Bool
    }
    private weak var observedTransition: (any UIViewControllerTransitionCoordinator)?
    var interacting: Bool { touch?.state == .began || touch?.state == .changed }
    var usable: Bool {
        guard let surface, surface.window != nil, !surface.isHidden, !blocked(), !keyboardVisible else { return false }
        if obstructingPresenter != nil { return false }
        return true
    }
    func bind(surface: UIView, access: MeetingAccessControls, toolbar: UIView,
              blocked: @escaping () -> Bool, privateContent: @escaping () -> Bool, studio: StudioModel? = nil) {
        if observedStudio !== studio {
            observedStudio = studio
            studioSubscription = studio?.objectWillChange.sink { [weak self] in self?.changed() }
        }
        self.access = access; self.toolbar = toolbar; self.blocked = blocked; self.privateContent = privateContent
        self.surface = surface
        let watch = surface.window ?? surface
        if touch?.view !== watch {
            if let touch { touch.view?.removeGestureRecognizer(touch) }
            let touch = ReminderTouchObserver(target: self, action: #selector(touched))
            touch.cancelsTouchesInView = false; touch.delaysTouchesBegan = false; touch.delaysTouchesEnded = false
            watch.addGestureRecognizer(touch); self.touch = touch
        }
        if observations.isEmpty {
            for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillHideNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    Task { @MainActor in
                        self?.keyboardVisible = note.name == UIResponder.keyboardWillShowNotification
                        self?.changed()
                    }
                })
            }
        }
        let state = LayoutState(bounds: surface.bounds, insets: surface.safeAreaInsets, access: access.frame,
            toolbar: toolbar.frame, hidden: access.isHidden, blocked: blocked(), privateContent: privateContent(), window: surface.window.map(ObjectIdentifier.init), usable: usable)
        if layoutState != state { layoutState = state; changed() }
    }
    @objc private func touched() {
        let active = interacting
        if touchWasActive != active { touchWasActive = active; changed() }
    }
    private var rootPresenter: UIViewController? {
        var node: UIResponder? = surface
        while let current = node, !(current is UIViewController) { node = current.next }
        guard var controller = node as? UIViewController else { return nil }
        while let parent = controller.parent { controller = parent }
        return controller
    }
    private var obstructingPresenter: UIViewController? {
        func presented(in controller: UIViewController) -> UIViewController? {
            if let next = controller.presentedViewController { return presented(in: next) ?? next }
            for child in controller.children where child.isViewLoaded && child.view.window === surface?.window {
                if let found = presented(in: child) { return found }
            }
            return nil
        }
        return rootPresenter.flatMap { presented(in: $0) }
    }
    private func observeTransition() {
        let top = obstructingPresenter ?? rootPresenter
        guard let transition = top?.transitionCoordinator, observedTransition !== transition else { return }
        observedTransition = transition
        if !transition.animate(alongsideTransition: nil, completion: { [weak self] _ in
            self?.observedTransition = nil; self?.changed()
        }) { observedTransition = nil }
    }
    func changed() {
        guard onChange != nil else { return }
        observeTransition()
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.scheduled = false; self?.observeTransition(); self?.onChange?()
        }
    }
    deinit {
        if let touch { touch.view?.removeGestureRecognizer(touch) }
        observations.forEach(NotificationCenter.default.removeObserver)
    }
}

/// Observes touch ownership without preventing, delaying or cancelling call gestures.
private final class ReminderTouchObserver: UIGestureRecognizer {
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    private var activeTouches: Set<UITouch> = []
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        activeTouches.formUnion(touches); state = state == .possible ? .began : .changed
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { state = .changed }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        activeTouches.subtract(touches); state = activeTouches.isEmpty ? .ended : .changed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        activeTouches.subtract(touches); state = activeTouches.isEmpty ? .cancelled : .changed
    }
    override func reset() { activeTouches = []; super.reset() }
}
