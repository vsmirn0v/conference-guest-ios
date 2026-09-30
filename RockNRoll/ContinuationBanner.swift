import UIKit

/// Status lives above the stage, never over the bottom conference controls.
@MainActor
final class ContinuationBanner {
    private let panel = UIStackView()
    private let label = UILabel()
    private let action = UIButton(type: .system)
    private weak var host: UIView?
    private var handler: (() -> Void)?
    private var dismissal: Task<Void, Never>?
    init() {
        panel.axis = .vertical; panel.spacing = 5; panel.isLayoutMarginsRelativeArrangement = true
        panel.directionalLayoutMargins = .init(top: 10, leading: 14, bottom: 10, trailing: 14)
        panel.backgroundColor = .secondarySystemBackground; panel.layer.cornerRadius = 14
        panel.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .subheadline); label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.isAccessibilityElement = true
        label.accessibilityIdentifier = "continuationStatus"
        action.addAction(UIAction { [weak self] _ in self?.handler?() }, for: .touchUpInside)
        action.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        action.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        panel.addArrangedSubview(label); panel.addArrangedSubview(action)
    }
    func show(_ text: String?, in view: UIView?, button: String? = nil, autoDismiss: Bool = false, action handler: (() -> Void)? = nil) {
        dismissal?.cancel(); dismissal = nil
        guard let text, let view else { panel.removeFromSuperview(); host = nil; return }
        let changed = label.text != text || host !== view
        label.text = text; self.handler = handler
        action.setTitle(button, for: .normal); action.isHidden = button == nil
        if host !== view {
            panel.removeFromSuperview(); view.addSubview(panel); host = view
            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 72),
                panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                panel.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
                panel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
                panel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12)
            ])
        }
        view.bringSubviewToFront(panel)
        if changed { UIAccessibility.post(notification: .announcement, argument: text) }
        if autoDismiss {
            dismissal = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.panel.removeFromSuperview(); self?.host = nil
            }
        }
    }
}
