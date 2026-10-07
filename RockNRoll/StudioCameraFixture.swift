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
    func stop() {}
}
/// Deterministic input for visible-toolbar screenshot checks. No capture/network.
@MainActor
final class MicrophoneActivityFixture {
    private let activity: MicrophoneActivity
    private var timer: Timer?
    init(activity: MicrophoneActivity) { self.activity = activity }
    var actions: [UIAction] {
        [UIAction(title: "Fixture mic quiet") { [self] _ in feed(0) },
         UIAction(title: "Fixture mic loud") { [self] _ in feed(1) }]
    }
    private func feed(_ rms: Float) {
        timer?.invalidate(); activity.clear(); activity.setStatus(.on)
        for _ in 0..<8 { activity.receive(rms: rms) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.activity.receive(rms: rms) }
        }
    }
    deinit { timer?.invalidate() }
}
#endif
