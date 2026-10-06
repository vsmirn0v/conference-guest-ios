#if DEBUG
import Combine
import UIKit

/// Changes metadata through the production store without touching the selected media.
enum SpeakerFixtureActions {
    static func make(_ speaker: ActiveSpeakerStore) -> [UIAction] {
        let people = [CallSpeaker(id: "speaker-aram", name: "Aram", isLocal: false),
            CallSpeaker(id: "speaker-ani", name: "Николай Александрович — акустическая гитара", isLocal: false),
            CallSpeaker(id: "speaker-self", name: "Ignored local name", isLocal: true)]
        var actions = zip(["Test speaker: Aram", "Test speaker: long name", "Test speaker: You"], people).map { title, person in
            UIAction(title: title) { _ in speaker.update(person) }
        }
        actions.append(UIAction(title: "Test speaker: Silence") { _ in speaker.update(nil) })
        actions.append(UIAction(title: "Test speaker: Hold") { _ in speaker.setAvailable(false) })
        actions.append(UIAction(title: "Test speaker: Resume") { _ in
            speaker.setAvailable(true); speaker.update(people[0])
        })
        return actions
    }
}

final class SpeakerPiPFixtureViewController: UIViewController {
    private let speaker = ActiveSpeakerStore()
    private var buttons: UIStackView!
    private var surface: FloatingVideoContentView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let video = UILabel()
        video.text = "Static shared screen"
        video.textAlignment = .center; video.textColor = .white
        video.backgroundColor = .darkGray
        surface = FloatingVideoContentView(videoContent: video)
        surface.setMicrophoneStatus(.muted)
        view.addSubview(surface)
        speaker.$current.sink { [weak surface] in surface?.setSpeaker($0) }.store(in: &subscriptions)
        buttons = UIStackView(arrangedSubviews: SpeakerFixtureActions.make(speaker).map { action in
            let button = UIButton(type: .system)
            button.setTitle(action.title, for: .normal); button.addAction(action, for: .touchUpInside)
            return button
        })
        buttons.axis = .vertical; buttons.spacing = 2
        view.addSubview(buttons)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        surface.frame = CGRect(x: view.bounds.midX - 144, y: view.safeAreaInsets.top + 16, width: 288, height: 162)
        buttons.frame = CGRect(x: 16, y: surface.frame.maxY + 16, width: view.bounds.width - 32, height: 264)
    }
    private var subscriptions = Set<AnyCancellable>()
}
#endif
