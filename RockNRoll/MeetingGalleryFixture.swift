#if DEBUG
import UIKit

/// Provider-independent production call UI, with a deterministic camera-off roster.
final class MeetingGalleryFixture: UIViewController {
    private var call: RockCallViewController!
    private var speaker = 2
    private var names = ["Алексей Волков", "Полина", "Роман Тюрин", "Виталий Смирнов", "Олег Никитин", "Елена Соколова", "Alex Morgan", "Дарья Самойлова", "Сергей Фёдоров", "Евгений Сафронов", "Всеволод", "Галина Орлова"]
    override func viewDidLoad() {
        super.viewDidLoad()
        let catchUp = CatchUpStore(); catchUp.enter(roomKey: "gallery-fixture")
        call = RockCallViewController(title: "CTO Daily", catchUp: catchUp, chat: ChatStore())
        addChild(call); view.addSubview(call.view); call.didMove(toParent: self)
        call.view.frame = view.bounds; call.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        call.fixtureActions = [UIAction(title: "Change speaking participant") { [weak self] _ in
            guard let self else { return }; self.speaker = (self.speaker + 1) % self.names.count; self.refresh()
        }]
        refresh()
    }
    private func refresh() {
        call.render(snapshot: CallMediaSnapshot(participants: names.enumerated().map { index, name in
            CallParticipant(id: "person-\(index)", name: name, isLocal: index == 3,
                microphoneOn: index == speaker, cameraOn: false, screenShareOn: false,
                isSpeaking: index == speaker, videoTracks: [])
        }))
    }
}
#endif
