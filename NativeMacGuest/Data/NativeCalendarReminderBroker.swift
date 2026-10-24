import Foundation
import UserNotifications

/// Native notification delivery delegates every decision to the shared reminder coordinator.
/// Notification callbacks may open a window; media admission remains a foreground action.
final class CalendarReminderBroker: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CalendarReminderBroker()
    static let category = "MEETING_REMINDER"
    static let join = "REMINDER_JOIN", snooze = "REMINDER_SNOOZE", skip = "REMINDER_SKIP"
    @MainActor private var coordinator: CalendarReminderCoordinator?
    @MainActor private var queued: [(String, Bool)] = []
    @MainActor var sharedCoordinator: CalendarReminderCoordinator {
        if let coordinator { return coordinator }
        let value = CalendarReminderCoordinator()
        coordinator = value
        value.onOpen = { [weak self] occurrence, join in
            if let occurrence { self?.queued.append((occurrence.reference, join)) }
        }
        return value
    }

    @MainActor func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            var categories = await center.notificationCategories().filter { $0.identifier != Self.category }
            let actions = [
                UNNotificationAction(identifier: Self.join, title: L("Join"), options: [.foreground, .authenticationRequired]),
                UNNotificationAction(identifier: Self.snooze, title: L("In 2 min"), options: []),
                UNNotificationAction(identifier: Self.skip, title: L("Skip reminders"), options: [])
            ]
            categories.insert(UNNotificationCategory(identifier: Self.category, actions: actions,
                intentIdentifiers: [], options: []))
            center.setNotificationCategories(categories)
        }
    }

    @MainActor func attach(_ owner: CalendarReminderCoordinator) {
        coordinator = owner
        let pending = queued; queued = []
        for (reference, join) in pending { owner.open(reference: reference, join: join) }
    }

    @MainActor var hasPendingIntent: Bool { !queued.isEmpty }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.notification.request.content.categoryIdentifier == Self.category,
              let reference = response.notification.request.content.userInfo["reference"] as? String else {
            completionHandler(); return
        }
        Task { @MainActor in
            let owner = sharedCoordinator
            switch response.actionIdentifier {
            case Self.snooze, Self.skip:
                await owner.action(reference: reference, snooze: response.actionIdentifier == Self.snooze)
            case Self.join, UNNotificationDefaultActionIdentifier:
                owner.open(reference: reference, join: true)
            default: break
            }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        guard notification.request.content.categoryIdentifier == Self.category else {
            completionHandler([.banner, .list, .sound]); return
        }
        Task { @MainActor in
            guard let coordinator, coordinator.scene().visible,
                  let reference = notification.request.content.userInfo["reference"] as? String,
                  let fingerprint = notification.request.content.userInfo["fingerprint"] as? String else {
                completionHandler([.banner, .list, .sound]); return
            }
            coordinator.foregroundReminder(reference: reference, requestID: notification.request.identifier, fingerprint: fingerprint)
            completionHandler([])
        }
    }
}
