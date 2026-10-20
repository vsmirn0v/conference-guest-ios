import ActivityKit
import UIKit

@MainActor
enum MeetingActivitySupport {
    static var supported: Bool {
        if #available(iOS 16.2, *) {
            return !ProcessInfo.processInfo.isiOSAppOnMac && UIDevice.current.userInterfaceIdiom == .phone
        }
        return false
    }
    static func makeDriver() -> any MeetingActivityDriver {
        if #available(iOS 16.2, *), supported { return SystemMeetingActivityDriver() }
        return UnavailableMeetingActivityDriver()
    }
}

@available(iOS 16.2, *)
@MainActor
final class SystemMeetingActivityDriver: MeetingActivityDriver {
    var available: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    var onDismiss: ((String) -> Void)?
    private var observations: [String: Task<Void, Never>] = [:]
    private var activities: [String: Activity<MeetingActivityAttributes>] = [:]

    func existingIDs() -> [String] {
        for activity in Activity<MeetingActivityAttributes>.activities { activities[activity.id] = activity }
        return Array(activities.keys)
    }
    func start(_ snapshot: MeetingActivitySnapshot, staleDate: Date) throws -> String {
        let activity = try Activity.request(attributes: MeetingActivityAttributes(sessionID: snapshot.sessionID),
            content: ActivityContent(state: snapshot.state, staleDate: staleDate), pushType: nil)
        activities[activity.id] = activity
        observations[activity.id] = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if state == .dismissed || state == .ended {
                    self?.onDismiss?(activity.id)
                    self?.activities.removeValue(forKey: activity.id)
                    self?.observations.removeValue(forKey: activity.id)
                    return
                }
            }
        }
        return activity.id
    }
    func update(_ id: String, snapshot: MeetingActivitySnapshot, staleDate: Date) async {
        await activities[id]?.update(ActivityContent(state: snapshot.state, staleDate: staleDate))
    }
    func end(_ id: String) async {
        observations.removeValue(forKey: id)?.cancel()
        guard let activity = activities.removeValue(forKey: id) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }
    deinit { observations.values.forEach { $0.cancel() } }
}
