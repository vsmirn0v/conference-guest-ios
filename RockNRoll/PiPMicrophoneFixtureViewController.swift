#if DEBUG
import UIKit

/// A static PiP surface: status redraws must not depend on arriving video frames.
final class PiPMicrophoneFixtureViewController: UIViewController {
    private var floating: FloatingVideoController?
    private let speaker = ActiveSpeakerStore()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let card = UILabel()
        card.text = "Static shared screen"
        card.textAlignment = .center
        card.backgroundColor = UIColor(white: 0.18, alpha: 1)
        card.textColor = .white
        floating = FloatingVideoController(contentView: card, speaker: speaker)
        floating?.setMicrophoneStatus(.muted)
        speaker.update(CallSpeaker(id: "aram", name: "Aram", isLocal: false))
        let start = UIButton(type: .system)
        start.setTitle("Test microphone in PiP", for: .normal)
        start.addAction(UIAction { [weak self] _ in self?.floating?.start() }, for: .touchUpInside)
        start.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(start)
        let end = UIButton(type: .system)
        end.setTitle("End test video", for: .normal)
        end.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.floating?.end()
            self.finishBackgroundTask()
            // Reproduce the late source/layout callback after meeting teardown.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.floating?.setSourceView(self.view)
                self.floating?.setSuspended(false)
                self.floating?.foregrounded()
                self.floating?.refreshPreference()
            }
        }, for: .touchUpInside)
        end.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(end)
        NSLayoutConstraint.activate([
            start.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            start.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            end.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            end.topAnchor.constraint(equalTo: start.bottomAnchor, constant: 16)
        ])
        floating?.onWillStart = { [weak self] in
            guard let self else { return }
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PiP status fixture") {
                self.finishBackgroundTask()
            }
            for (delay, status) in [(12.0, PiPMicrophoneStatus.on), (24.0, .unavailable), (36.0, .muted)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.floating?.setMicrophoneStatus(status)
                    self?.speaker.update(status == .on ? CallSpeaker(id: "ani", name: "Ani", isLocal: false) : nil)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
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
