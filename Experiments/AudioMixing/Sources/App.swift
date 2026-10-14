import AVFoundation
import UIKit

/// Separate-process, nonmixable media player: exercises real iOS arbitration.
/// It never records and sends no data. Launch with --play to begin playback.
@main final class App: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Player", sessionRole: session.role)
        configuration.delegateClass = PlayerScene.self
        return configuration
    }
}

final class PlayerScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = PlayerController()
        self.window = window; window.makeKeyAndVisible()
    }
}

final class PlayerController: UIViewController {
    private var player: AVAudioPlayer?
    private let status = UILabel()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let row: [String: Any] = ["time": Date().timeIntervalSince1970, "event": name.rawValue,
                    "type": note.userInfo?[AVAudioSessionInterruptionTypeKey] ?? -1,
                    "reason": note.userInfo?[AVAudioSessionRouteChangeReasonKey] ?? -1,
                    "interruptionReason": note.userInfo?[AVAudioSessionInterruptionReasonKey] ?? -1,
                    "playing": self?.player?.isPlaying ?? false]
                guard var data = try? JSONSerialization.data(withJSONObject: row) else { return }
                data.append(10)
                let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("player-event-\(UUID().uuidString).json")
                try? data.write(to: url)
            })
        }
        status.accessibilityIdentifier = "playback.status"
        status.numberOfLines = 0; status.textAlignment = .center
        let play = UIButton(type: .system); play.setTitle("Play test audio", for: .normal)
        play.addTarget(self, action: #selector(start), for: .touchUpInside)
        let stop = UIButton(type: .system); stop.setTitle("Stop test audio", for: .normal)
        stop.addTarget(self, action: #selector(end), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [status, play, stop]); stack.axis = .vertical; stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        if ProcessInfo.processInfo.arguments.contains("--play") { start() } else { refresh() }
    }
    @objc private func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            samples.frameLength = 48_000
            for i in 0..<48_000 { samples.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 660 / 48_000)) * 0.035 }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-tone.caf")
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: samples)
            }
            player = try AVAudioPlayer(contentsOf: url); player?.numberOfLoops = -1; player?.play()
            refresh()
        } catch { status.text = "Error: \(error)" }
    }
    @objc private func end() {
        player?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        refresh()
    }
    private func refresh() {
        status.text = "\(player?.isPlaying == true ? "Playing" : "Stopped") · \(String(format: "%.2f", player?.currentTime ?? 0))"
    }
}
