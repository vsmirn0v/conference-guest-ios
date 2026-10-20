#if DEBUG
import ConferenceCore
import SwiftUI
import UIKit

/// Uses the real call controls with synthetic calendar data and no media/network.
final class ReminderCallFixture: UIViewController {
    private let call: UIViewController = ProcessInfo.processInfo.environment["CONFERENCE_TEST_REMINDER_HOST"] == "guest"
        ? GuestCallLayoutFixture() : RockCallViewController(title: "Current meeting", catchUp: CatchUpStore(), chat: ChatStore())
    private var coordinator: CalendarReminderCoordinator?
    private let reminder = MeetingReminderPresenter()
    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(call); view.addSubview(call.view); call.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        call.view.frame = view.bounds; call.didMove(toParent: self)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard coordinator == nil else { return }
        let prefs = UserDefaults(suiteName: "ReminderCallFixture")!
        prefs.removePersistentDomain(forName: "ReminderCallFixture")
        prefs.set(true, forKey: "calendarMeetings.enabled"); prefs.set(["work"], forKey: "calendarMeetings.selected")
        let owner = CalendarReminderCoordinator(preferences: prefs, storage: CalendarUIFixture.Storage(), notifications: Notifications())
        coordinator = owner
        owner.scene = { [weak self, weak owner] in .init(visible: self?.view.window != nil && UIApplication.shared.applicationState == .active,
            room: MeetingRoomIdentity(URL(string: "https://salutejazz.ru/calls/current")!, engine: .guest), usable: owner?.presenting == false) }
        owner.onPresentation = { [weak self, weak owner] events in
            guard let self, let owner else { return [] }
            let endpoint = (call as? RockCallViewController)?.reminderHost ?? (call as? GuestCallLayoutFixture)?.reminderHostForTesting
            return reminder.render(events, host: endpoint, coordinator: owner)
        }
        owner.onBackground = { [weak self] in self?.reminder.backgrounded() }
        owner.onOpen = { [weak self, weak owner] occurrence, _ in
            guard let self, let owner else { return }
            owner.presenting = true
            let panel = UIHostingController(rootView: ReminderMeetingView(occurrence: occurrence, switching: true,
                onJoin: { if let room = occurrence?.room { owner.joined(room: room, eventID: occurrence?.eventID) } },
                onMove: { _ in }, onDismiss: { [weak owner] in owner?.presenting = false }))
            self.present(panel, animated: true)
        }
        Task {
            await owner.setEnabled(true)
            let delayed = ProcessInfo.processInfo.environment["CONFERENCE_TEST_REMINDER_DELAY"] == "1"
            if delayed { var profile = owner.profile; profile.timing.followUp.delay = 5; owner.setProfile(profile) }
            let meetings = ["Design review", "Planning"].enumerated().map { index, title in
                var meeting = CalendarMeeting(id: String(index), seriesID: String(index), calendarID: "work", calendarTitle: "Work", title: title,
                    start: Date().addingTimeInterval(delayed ? 0 : -180), end: Date().addingTimeInterval(1800))
                meeting.invitation = URL(string: "https://salutejazz.ru/calls/next\(index)")!; meeting.engine = .guest
                return meeting
            }
            owner.update(meetings: meetings, available: true)
        }
    }
    private final class Notifications: ReminderNotifying {
        func authorization() -> ReminderAuthorization { .allowed }
        func request(sensitive: Bool) -> Bool { true }
        func pending() -> [String: String] { [:] }
        func add(_ reminder: ReminderNotification) {}
        func removePending(_ ids: [String]) {}
        func removeDelivered(occurrenceIDs: Set<String>) {}
        func removeAllDelivered() {}
    }
}
#endif
