import SwiftUI
import UIKit

@MainActor
final class MeetingWebsitePresenter {
    private var window: UIWindow?
    private weak var previousWindow: UIWindow?

    func present(in source: UIWindow?, view: MeetingWebsiteSelectionView) {
        dismiss(fallback: source)
        guard let scene = source?.windowScene else { return }
        let overlay = UIWindow(windowScene: scene)
        overlay.windowLevel = .alert + 1
        overlay.rootViewController = UIHostingController(rootView: view)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = overlay
        overlay.makeKeyAndVisible()
    }
    func dismiss(fallback: UIWindow?) {
        window?.isHidden = true
        window = nil
        (previousWindow ?? fallback)?.makeKey()
        previousWindow = nil
    }
}
