#if DEBUG
import UIKit

/// A static PiP surface: status redraws must not depend on arriving video frames.
final class PiPMicrophoneFixtureViewController: UIViewController {
    private var floating: FloatingVideoController?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let card = UILabel()
        card.text = "Static shared screen"
        card.textAlignment = .center
        card.backgroundColor = UIColor(white: 0.18, alpha: 1)
        card.textColor = .white
        floating = FloatingVideoController(contentView: card)
        floating?.setMicrophoneStatus(.muted)
        let start = UIButton(type: .system)
        start.setTitle("Test microphone in PiP", for: .normal)
        start.addAction(UIAction { [weak self] _ in self?.floating?.start() }, for: .touchUpInside)
        start.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(start)
        NSLayoutConstraint.activate([
            start.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            start.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        floating?.onWillStart = { [weak self] in
            guard let self else { return }
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PiP status fixture") {
                self.finishBackgroundTask()
            }
            for (delay, status) in [(6.0, PiPMicrophoneStatus.on), (12.0, .unavailable), (18.0, .muted)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.floating?.setMicrophoneStatus(status)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 22) { [weak self] in
                self?.finishBackgroundTask()
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        floating?.setSourceView(view)
    }

    private func finishBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
#endif
