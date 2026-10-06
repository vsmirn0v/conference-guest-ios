#if DEBUG
import UIKit

/// Capture-free layout fixture. No camera, microphone, or network is opened.
@MainActor
final class StudioCameraFixture: PrivateCameraPreviewing {
    let view: UIView = {
        let view = UIView()
        view.backgroundColor = .systemIndigo
        view.accessibilityIdentifier = "studio.fixture-camera"
        return view
    }()
    func start() async throws { try Task.checkCancellation() }
    func stop() async {}
}
#endif
