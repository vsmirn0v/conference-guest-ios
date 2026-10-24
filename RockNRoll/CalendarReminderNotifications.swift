import ConferenceCore
import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import UserNotifications

@MainActor enum NotificationSettingsLink {
    static func destinations(isMac: Bool, bundleIdentifier: String?) -> [URL] {
        if isMac {
            // iPad apps on Mac map the generic UIKit settings URL to Touch Alternatives.
            // Open the system Notifications pane directly; retain a pane-level fallback.
            let pane = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
            guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return [pane] }
            var app = URLComponents(url: pane, resolvingAgainstBaseURL: false)!
            app.queryItems = [URLQueryItem(name: "id", value: bundleIdentifier)]
            return [app.url!, pane]
        }
        #if canImport(UIKit)
        return [URL(string: UIApplication.openNotificationSettingsURLString)!,
                URL(string: UIApplication.openSettingsURLString)!]
        #else
        return destinations(isMac: true, bundleIdentifier: bundleIdentifier)
        #endif
    }

    @discardableResult static func open(
        isMac: Bool = CalendarMeetingStore.isMacPlatform,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        using opener: (URL) async -> Bool = { await openSystemURL($0) }
    ) async -> Bool {
        for url in destinations(isMac: isMac, bundleIdentifier: bundleIdentifier) {
            if await opener(url) { return true }
        }
        return false
    }

    private static func openSystemURL(_ url: URL) async -> Bool {
        #if canImport(UIKit)
        return await UIApplication.shared.open(url)
        #else
        return NSWorkspace.shared.open(url)
        #endif
    }
}

struct ReminderNotification: Equatable {
    let plan: PlannedReminder
    let title: String
    let subtitle: String
    let body: String
    let sound: Bool
    let sensitive: Bool
    var fingerprint: String {
        let fields = [plan.reference, plan.phase.rawValue, String(plan.date.timeIntervalSince1970), title, subtitle, body,
                      String(sound), String(sensitive)]
        return SHA256.hash(data: try! JSONEncoder().encode(fields)).map { String(format: "%02x", $0) }.joined()
    }
    init(plan: PlannedReminder, occurrence: ReminderOccurrence, profile: ReminderProfile) {
        self.plan = plan; sound = profile.sound
        sensitive = profile.timeSensitive && plan.date >= occurrence.start.addingTimeInterval(-3600)
        title = profile.details ? ReminderFormatting.safeTitle(occurrence.title) : L("Meeting reminder")
        let time = occurrence.start.formatted(date: .abbreviated, time: .shortened)
        if profile.details {
            switch plan.phase {
            case .before:
                let seconds = Int(occurrence.start.timeIntervalSince(plan.date))
                subtitle = seconds <= 3600 ? L("Starts in %@", ReminderFormatting.duration(seconds)) : L("Meeting reminder")
            case .start: subtitle = L("Scheduled for now")
            case .after: subtitle = L("Scheduled start: %@", time)
            case .snooze: subtitle = L("Meeting reminder")
            }
            body = time + " · " + (occurrence.invitation.host ?? "")
        } else { subtitle = ""; body = time }
    }
}

enum ReminderAuthorization { case notDetermined, allowed, denied }

@MainActor protocol ReminderNotifying {
    func authorization() async -> ReminderAuthorization
    func request(sensitive: Bool) async throws -> Bool
    func pending() async -> [String: String]
    func add(_ reminder: ReminderNotification) async throws
    func removePending(_ ids: [String])
    func removeDelivered(occurrenceIDs: Set<String>) async
    func removeAllDelivered() async
}

@MainActor final class SystemReminderNotifications: ReminderNotifying {
    let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) { self.center = center }
    func authorization() async -> ReminderAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
    func request(sensitive: Bool) async throws -> Bool {
        var options: UNAuthorizationOptions = [.alert, .sound]
        if sensitive { options.insert(.timeSensitive) }
        return try await center.requestAuthorization(options: options)
    }
    func pending() async -> [String: String] {
        Dictionary(uniqueKeysWithValues: await center.pendingNotificationRequests().map {
            ($0.identifier, $0.content.userInfo["fingerprint"] as? String ?? "")
        })
    }
    func add(_ reminder: ReminderNotification) async throws { try await center.add(Self.request(reminder)) }
    static func request(_ reminder: ReminderNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reminder.title; content.subtitle = reminder.subtitle; content.body = reminder.body
        content.categoryIdentifier = CalendarReminderBroker.category
        content.threadIdentifier = PlannedReminder.namespace + reminder.plan.occurrenceID
        content.userInfo = ["reference": reminder.plan.reference, "fingerprint": reminder.fingerprint]
        if reminder.sound { content.sound = .default }
        content.interruptionLevel = reminder.sensitive ? .timeSensitive : .active
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: ceil(reminder.plan.date.timeIntervalSince1970))
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.calendar = calendar; components.timeZone = calendar.timeZone
        return .init(identifier: reminder.plan.id, content: content,
                     trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }
    func removePending(_ ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids) }
    func removeDelivered(occurrenceIDs: Set<String>) async {
        let delivered = await center.deliveredNotifications().filter {
            occurrenceIDs.contains($0.request.content.threadIdentifier.replacingOccurrences(of: PlannedReminder.namespace, with: ""))
        }
        center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier })
    }
    func removeAllDelivered() async {
        let delivered = await center.deliveredNotifications().filter {
            $0.request.identifier.hasPrefix(PlannedReminder.namespace) ||
                $0.request.content.categoryIdentifier == CalendarReminderBroker.category
        }
        center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier })
    }
}

enum ReminderFormatting {
    static func safeTitle(_ title: String) -> String {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: title, range: NSRange(title.startIndex..., in: title)) ?? []
        var safe = title
        for match in matches.reversed() {
            guard let range = Range(match.range, in: safe), let url = match.url else { continue }
            safe.replaceSubrange(range, with: url.host ?? L("Meeting reminder"))
        }
        return safe.isEmpty ? L("Meeting reminder") : safe
    }
    static func duration(_ seconds: Int?) -> String {
        guard let seconds else { return L("Off") }
        let formatter = DateComponentsFormatter(); formatter.unitsStyle = .full; formatter.maximumUnitCount = 2
        formatter.allowedUnits = seconds < 60 ? [.second] : seconds < 3600 ? [.minute, .second] : [.hour, .minute]
        return formatter.string(from: Double(seconds)) ?? String(seconds)
    }
}

/// Installed before scenes are made; background admission requires an explicit notification action.
#if canImport(UIKit)
final class CalendarReminderBroker: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CalendarReminderBroker()
    static let category = "MEETING_REMINDER"
    static let join = "REMINDER_JOIN", snooze = "REMINDER_SNOOZE", skip = "REMINDER_SKIP"
    @MainActor private weak var coordinator: CalendarReminderCoordinator?
    @MainActor private var queued: [(String, Bool)] = []
    @MainActor private var background: CalendarReminderCoordinator?
    @MainActor private var backgroundCalendar: CalendarMeetingStore?
    @MainActor var sharedCoordinator: CalendarReminderCoordinator {
        if let coordinator { return coordinator }
        if let background { return background }
        let owner = CalendarReminderCoordinator(); background = owner
        owner.onOpen = { [weak self] occurrence, join in
            if let occurrence { self?.queued.append((occurrence.reference, join)) }
        }
        return owner
    }
    @MainActor private func prepareBackgroundCalendar(owner: CalendarReminderCoordinator) {
        guard coordinator == nil, backgroundCalendar == nil else { return }
        let calendar = CalendarMeetingStore(detector: VendorEndpointResolver.makeDetector(), reminders: owner)
        calendar.configureInvitationContext(history: RoomHistoryStore(), preferences: .standard)
        backgroundCalendar = calendar
    }
    @MainActor func install() {
        let center = UNUserNotificationCenter.current(); center.delegate = self
        // Preserve any categories owned by other features.
        Task {
            let current = await center.notificationCategories()
            center.setNotificationCategories(Self.categories(replacing: current,
                backgroundAudioJoin: BackgroundAudioJoinPrototype.shared.enabled))
        }
    }
    @MainActor static func categories(replacing current: Set<UNNotificationCategory>, backgroundAudioJoin: Bool) -> Set<UNNotificationCategory> {
        var categories = current.filter { $0.identifier != Self.category && $0.identifier != BackgroundAudioJoinPrototype.fallbackCategory }
        var actions = [
            .init(identifier: Self.join, title: L("Join"), options: [.foreground, .authenticationRequired]),
            .init(identifier: Self.snooze, title: L("In 2 min"), options: []),
            .init(identifier: Self.skip, title: L("Skip reminders"), options: [])
        ] as [UNNotificationAction]
        if backgroundAudioJoin { actions.insert(BackgroundAudioJoinPrototype.notificationAction, at: 1) }
        categories.insert(BackgroundAudioJoinPrototype.notificationCategory)
        categories.insert(UNNotificationCategory(identifier: Self.category, actions: actions, intentIdentifiers: [], options: []))
        return categories
    }
    @MainActor func attach(_ coordinator: CalendarReminderCoordinator) {
        self.coordinator = coordinator
        backgroundCalendar?.backgrounded(); backgroundCalendar = nil
        for (reference, join) in queued { coordinator.open(reference: reference, join: join) }
        queued = []; background = nil
    }
    @MainActor var hasPendingIntent: Bool {
        if BackgroundAudioJoinPrototype.shared.hasPendingIntent { return true }
        return !queued.isEmpty
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        var acceptedCategory = response.notification.request.content.categoryIdentifier == Self.category
        acceptedCategory = acceptedCategory || response.notification.request.content.categoryIdentifier == BackgroundAudioJoinPrototype.fallbackCategory
        guard acceptedCategory,
              let reference = response.notification.request.content.userInfo["reference"] as? String else {
            completionHandler(); return
        }
        Task { @MainActor in
            await respond(reference: reference, action: response.actionIdentifier)
            completionHandler()
        }
    }
    @MainActor func respond(reference: String, action: String) async {
        #if DEBUG
        if await BackgroundJoinDeviceFixture.respond(reference: reference, action: action) { return }
        #endif
        switch action {
        case BackgroundAudioJoinPrototype.action:
            await BackgroundAudioJoinPrototype.shared.join(reference: reference)
        case Self.snooze, Self.skip:
            let owner = sharedCoordinator
            prepareBackgroundCalendar(owner: owner)
            await owner.action(reference: reference, snooze: action == Self.snooze)
        case Self.join, UNNotificationDefaultActionIdentifier:
            BackgroundAudioJoinPrototype.shared.supersedeForForeground()
            if let coordinator { coordinator.open(reference: reference, join: true) }
            else if !queued.contains(where: { $0.0 == reference && $0.1 }) { queued.append((reference, true)) }
        default: break
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        guard notification.request.content.categoryIdentifier == Self.category else { completionHandler([.banner, .list, .sound]); return }
        Task { @MainActor in
            if let reference = notification.request.content.userInfo["reference"] as? String,
               let fingerprint = notification.request.content.userInfo["fingerprint"] as? String {
                if let coordinator, coordinator.scene().visible {
                    coordinator.foregroundReminder(reference: reference, requestID: notification.request.identifier, fingerprint: fingerprint)
                } else {
                    completionHandler([.banner, .list, .sound]); return
                }
            }
            completionHandler([]) // No extra meeting audio or modal system alert in the foreground.
        }
    }
}
#endif
