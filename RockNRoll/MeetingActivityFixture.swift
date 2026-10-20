#if DEBUG
import ActivityKit
import SwiftUI
import UIKit

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
        renderCard()
    }
    private func apply(end: Bool = false) {
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
