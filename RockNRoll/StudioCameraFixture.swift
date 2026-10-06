#if DEBUG
import UIKit
import AVFoundation

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
@MainActor
final class StudioMicrophoneFixture: PrivateMicrophoneCapturing {
    func start(standalone: Bool, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws { try Task.checkCancellation() }
    func beginRecording() {}
    func finishRecording() -> Data? { nil }
    func stop() {}
}
#endif
