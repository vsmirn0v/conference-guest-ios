#if DEBUG
import ActivityKit
import ConferenceCore
import SwiftUI
import UIKit
import UserNotifications

/// Exercises real ActivityKit and the actual widget without joining a room.
@available(iOS 16.2, *)
@MainActor
final class MeetingActivityFixture: UIViewController {
    private var driver = SystemMeetingActivityDriver()
    private lazy var coordinator = MeetingActivityCoordinator(driver: driver)
    private var snapshot = MeetingActivitySnapshot(sessionID: UUID(), state: .init(startedAt: Date(),
        connection: .connected, microphone: .muted, title: nil, route: "Speaker"))
    private let result = UILabel()
    private let card = UIHostingController(rootView: AnyView(EmptyView()))
    private var contentObservation: Task<Void, Never>?
    private let notificationID = ProcessInfo.processInfo.environment["CONFERENCE_TEST_ACTIVITY_REMINDER_ID"] ?? UUID().uuidString
    private let notificationResult = UILabel()
    private var notificationRequests: [String] = []
    deinit { contentObservation?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)])
        result.accessibilityIdentifier = "activity-fixture.status"
        result.text = driver.available ? "ready" : "unavailable"
        stack.addArrangedSubview(result)
        addChild(card); stack.addArrangedSubview(card.view); card.didMove(toParent: self)
        card.view.heightAnchor.constraint(equalToConstant: 160).isActive = true
        for (id, title, action) in [
            ("start", "Start activity", { [weak self] in self?.apply() }),
            ("microphone", "Change microphone", { [weak self] in self?.snapshot.state.microphone = self?.snapshot.state.microphone == .on ? .muted : .on; self?.apply() }),
            ("reconnect", "Reconnect", { [weak self] in self?.snapshot.state.connection = .reconnecting; self?.snapshot.state.microphone = .paused; self?.apply() }),
            ("recover", "Recover", { [weak self] in self?.snapshot.state.connection = .connected; self?.snapshot.state.microphone = .muted; self?.apply() }),
            ("end", "End activity", { [weak self] in self?.apply(end: true) })
        ] {
            let button = UIButton(type: .system); button.setTitle(title, for: .normal)
            button.accessibilityIdentifier = "activity-fixture." + id
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addAction(UIAction { _ in action() }, for: .touchUpInside); stack.addArrangedSubview(button)
        }
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_ACTIVITY_COEXISTENCE"] == "1" {
            notificationResult.accessibilityIdentifier = "activity-fixture.notification"
            notificationResult.text = "idle"; stack.addArrangedSubview(notificationResult)
            let actions: [(String, () -> Void)] = [
                ("Schedule device reminder", { [weak self] in Task { await self?.scheduleReminder() } }),
                ("Read delivered reminder", { [weak self] in Task { await self?.readReminder() } })
            ]
            for (title, action) in actions {
                let button = UIButton(type: .system); button.setTitle(title, for: .normal)
                button.addAction(UIAction { _ in action() }, for: .touchUpInside)
                stack.addArrangedSubview(button)
            }
            let pip = RoomFloatingVideoFixture()
            addChild(pip); stack.addArrangedSubview(pip.view); pip.didMove(toParent: self)
            pip.view.heightAnchor.constraint(equalToConstant: 300).isActive = true
        }
        renderCard()
    }
    private func scheduleReminder() async {
        do {
            let notifications = SystemReminderNotifications()
            guard try await notifications.request(sensitive: false) else {
                notificationResult.text = "permission denied"; return
            }
            let now = Date()
            var meeting = CalendarMeeting(id: notificationID, seriesID: notificationID, calendarID: "device-verification",
                calendarTitle: "Synthetic verification", title: "Rock device reminder verification",
                start: now.addingTimeInterval(30), end: now.addingTimeInterval(600))
            meeting.invitation = URL(string: "https://meeting.example.test/device-verification")!; meeting.engine = .guest
            guard let occurrence = ReminderOccurrence(meeting: meeting, id: notificationID) else { return }
            let plan = PlannedReminder(occurrence: occurrence, phase: .before, date: now.addingTimeInterval(20))
            try await notifications.add(.init(plan: plan, occurrence: occurrence, profile: .init()))
            notificationRequests.append(plan.id)
            notificationResult.text = "scheduled"
            // Read while still backgrounded: the ordinary Home coordinator
            // correctly prunes this synthetic, unregistered event on return.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(23))
                await self?.readReminder()
            }
        } catch { notificationResult.text = "error: \(error)" }
    }
    private func readReminder() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        notificationResult.text = delivered.contains { $0.request.content.threadIdentifier == PlannedReminder.namespace + notificationID } ? "delivered" : "not delivered"
    }
    private func apply(end: Bool = false) {
        if end {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: notificationRequests)
            let id = notificationID
            Task {
                let center = UNUserNotificationCenter.current()
                let requests = await center.pendingNotificationRequests().filter {
                    $0.content.threadIdentifier == PlannedReminder.namespace + id
                }
                center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier))
                await SystemReminderNotifications().removeDelivered(occurrenceIDs: [id])
            }
        }
        result.accessibilityValue = end ? "ended" : "\(snapshot.state.microphone.rawValue)|\(snapshot.state.connection.rawValue)"
        renderCard(); coordinator.update(end ? nil : snapshot)
        Task { [weak self] in
            guard let self else { return }
            await coordinator.task?.value
            let activities = Activity<MeetingActivityAttributes>.activities
            guard let activity = activities.first else {
                contentObservation?.cancel(); contentObservation = nil
                result.text = "0|none|none"; return
            }
            guard contentObservation == nil else { return }
            show(activity.content.state)
            contentObservation = Task { [weak self] in
                for await content in activity.contentUpdates {
                    guard !Task.isCancelled else { return }
                    self?.show(content.state)
                }
            }
        }
    }
    private func show(_ state: MeetingActivityState) {
        result.text = "1|\(state.microphone.rawValue)|\(state.connection.rawValue)"
    }
    private func renderCard() {
        card.rootView = AnyView(MeetingActivityDetails(state: snapshot.state, stale: false, openURL: snapshot.openURL))
    }
}
#endif
