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
    var onCancel: (() -> Void)?
    var sourceView: UIView { host.view }

    init(container: UIViewController) {
        self.container = container
        super.init()
        host.modalPresentationStyle = .fullScreen
        host.isModalInPresentation = true
        host.view.backgroundColor = .systemBackground
        status.text = L("Restoring jam audio…")
        status.textAlignment = .center; status.numberOfLines = 0
        status.font = .preferredFont(forTextStyle: .body)
        let cancel = UIButton(type: .system)
        cancel.setTitle(L("Cancel"), for: .normal)
        cancel.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let stack = UIStackView(arrangedSubviews: [progress, status, cancel])
        stack.axis = .vertical; stack.alignment = .center; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; host.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: host.view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: host.view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: host.view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: host.view.safeAreaLayoutGuide.trailingAnchor, constant: -24)
        ])
    }
    func beginJoin() { ended = false; if !recovering { progress.stopAnimating() } }
    func beginRecovery() {
        guard !ended, !recovering else { return }
        recoveryScreen = screen
        recovering = true; progress.startAnimating()
        detachScreen()
    }
    func completeRecovery() {
        guard !ended, recovering else { return }
        recovering = false; progress.stopAnimating()
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
        if host.presentingViewController == nil, let container {
            container.present(host, animated: false)
        }
    }
    func removeScreen(screen: UIViewController) {
        // SDK transport removal is not logical meeting departure. Only end()
        // closes our presentation, after the engine resolves its typed event.
    }
    func end() {
        ended = true; recovering = false; recoveryScreen = nil; detachScreen(); progress.stopAnimating()
        host.dismiss(animated: false)
    }
    private func detachScreen() {
        guard let screen else { return }
        self.screen = nil
        if screen.presentedViewController != nil { screen.dismiss(animated: false) }
        screen.willMove(toParent: nil); screen.view.removeFromSuperview(); screen.removeFromParent()
    }
    #if DEBUG
    var screenForTesting: UIViewController? { screen }
    var hostForTesting: UIViewController { host }
    #endif
}
