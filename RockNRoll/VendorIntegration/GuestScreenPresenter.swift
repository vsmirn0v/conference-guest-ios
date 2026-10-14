import JazzSDK
import UIKit

/// Keep logical meeting presentation separate from the SDK's replaceable
/// transport screens. Uses the provider's public custom navigation contract.
@MainActor
final class GuestScreenPresenter: NSObject, JazzMainScreenPresenter {
    private weak var container: UIViewController?
    private let host = UIViewController()
    private var screen: UIViewController?
    private var recoveryScreen: UIViewController?
    private var recovering = false
    private var ended = true
    private let progress = UIActivityIndicatorView(style: .medium)
    private let status = UILabel()
    private let recoveryStack = UIStackView()
    private struct Underlay {
        weak var view: UIView?
        let accessibilityHidden: Bool
    }
    private var underlays: [Underlay] = []
    var onCancel: (() -> Void)?
    var sourceView: UIView { host.view }
    var sdkContainer: UIViewController { host }

    init(container: UIViewController) {
        self.container = container
        super.init()
        host.view.frame = container.view.bounds
        host.view.backgroundColor = .systemBackground
        status.text = L("Restoring jam audio…")
        status.textAlignment = .center; status.numberOfLines = 0
        status.font = .preferredFont(forTextStyle: .body)
        let cancel = UIButton(type: .system)
        cancel.setTitle(L("Cancel"), for: .normal)
        cancel.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let stack = recoveryStack
        [progress, status, cancel].forEach(stack.addArrangedSubview)
        stack.isHidden = true
        stack.axis = .vertical; stack.alignment = .center; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; host.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: host.view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: host.view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: host.view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: host.view.safeAreaLayoutGuide.trailingAnchor, constant: -24)
        ])
    }
    func beginJoin() { ended = false; if !recovering { progress.stopAnimating(); recoveryStack.isHidden = true } }
    func beginRecovery() {
        guard !ended, !recovering else { return }
        recoveryScreen = screen
        recovering = true; recoveryStack.isHidden = false; progress.startAnimating()
        detachScreen()
    }
    func completeRecovery() {
        guard !ended, recovering else { return }
        recovering = false; recoveryStack.isHidden = true; progress.stopAnimating()
        let replacement = recoveryScreen; recoveryScreen = nil
        if let replacement { presentScreen(screen: replacement) }
    }
    func presentScreen(screen: UIViewController) {
        guard !ended else { return }
        if recovering { recoveryScreen = screen; return }
        guard self.screen !== screen else { return }
        detachScreen()
        self.screen = screen
        host.addChild(screen)
        screen.view.frame = host.view.bounds
        screen.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(screen.view); screen.didMove(toParent: host)
        // The persistent SDK container sits above the home page. Main content
        // and SDK subsidiary sheets remain siblings inside that container.
        if host.parent == nil, let container {
            // Child containment does not isolate VoiceOver like a modal. Hide
            // only the existing underlay, leaving later SDK sheets accessible.
            underlays = container.view.subviews.map { Underlay(view: $0, accessibilityHidden: $0.accessibilityElementsHidden) }
            underlays.forEach { $0.view?.accessibilityElementsHidden = true }
            container.addChild(host)
            host.view.frame = container.view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.view.addSubview(host.view); host.didMove(toParent: container)
        }
    }
    func removeScreen(screen: UIViewController) {
        // SDK transport removal is not logical meeting departure. Only end()
        // closes our presentation, after the engine resolves its typed event.
    }
    func end() {
        ended = true; recovering = false; recoveryScreen = nil; detachScreen(); progress.stopAnimating()
        host.presentedViewController?.dismiss(animated: false)
        host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
        underlays.forEach { $0.view?.accessibilityElementsHidden = $0.accessibilityHidden }
        underlays.removeAll(); recoveryStack.isHidden = true
    }
    private func detachScreen() {
        guard let screen else { return }
        self.screen = nil
        screen.presentedViewController?.dismiss(animated: false)
        screen.willMove(toParent: nil); screen.view.removeFromSuperview(); screen.removeFromParent()
    }
    #if DEBUG
    var screenForTesting: UIViewController? { screen }
    var hostForTesting: UIViewController { host }
    #endif
}
