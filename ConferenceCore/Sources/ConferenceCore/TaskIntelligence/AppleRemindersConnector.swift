import EventKit
import Foundation

public struct ReminderListInfo: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var allowsModification: Bool

    public init(id: String, title: String, allowsModification: Bool) {
        self.id = id
        self.title = title
        self.allowsModification = allowsModification
    }
}

public struct ReminderItemSnapshot: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var externalIdentifier: String
    public var title: String
    public var notes: String
    public var isCompleted: Bool
    public var completionDate: Date?
    public var dueDay: String?
    public var dueAt: Date?
    public var priority: TaskPriorityLevel?
    public var reminderAlarmDate: Date?
    public var repeatRule: TaskReminderRepeatRule
    public var lastModifiedAt: Date?
    public var listID: String?
    public var listTitle: String?

    public init(
        id: String,
        externalIdentifier: String,
        title: String,
        notes: String = "",
        isCompleted: Bool = false,
        completionDate: Date? = nil,
        dueDay: String? = nil,
        dueAt: Date? = nil,
        priority: TaskPriorityLevel? = nil,
        reminderAlarmDate: Date? = nil,
        repeatRule: TaskReminderRepeatRule = .none,
        lastModifiedAt: Date? = nil,
        listID: String? = nil,
        listTitle: String? = nil
    ) {
        self.id = id
        self.externalIdentifier = externalIdentifier
        self.title = title
        self.notes = notes
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.dueDay = dueDay
        self.dueAt = dueAt
        self.priority = priority
        self.reminderAlarmDate = reminderAlarmDate
        self.repeatRule = repeatRule
        self.lastModifiedAt = lastModifiedAt
        self.listID = listID
        self.listTitle = listTitle
    }
}

public enum AppleRemindersError: LocalizedError, Equatable {
    case permissionDenied
    case listNotFound
    case unavailableOnPlatform

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return L("Reminders access is disabled. Allow access in System Settings or Settings app.")
        case .listNotFound:
            return L("Could not find or create a Reminders list.")
        case .unavailableOnPlatform:
            return L("Apple Reminders is unavailable on this device.")
        }
    }
}

public protocol AppleRemindersConnecting: Sendable {
    func requestAccess() async throws -> Bool
    func fetchLists() async throws -> [ReminderListInfo]
    func ensureList(named title: String, preferredID: String?) async throws -> ReminderListInfo
    func fetchReminders(inListID listID: String?, includeCompleted: Bool) async throws -> [ReminderItemSnapshot]
    func upsertReminder(
        existingExternalID: String?,
        listID: String?,
        listTitle: String,
        title: String,
        notes: String,
        dueDay: String?,
        dueAt: Date?,
        priority: TaskPriorityLevel?,
        isCompleted: Bool,
        reminderAlarmDate: Date?,
        repeatRule: TaskReminderRepeatRule
    ) async throws -> ReminderItemSnapshot
}

public actor AppleRemindersConnector: AppleRemindersConnecting {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    public static func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    public func requestAccess() async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(iOS 17.0, macOS 14.0, *) {
            if status == .fullAccess { return true }
            if status == .denied || status == .restricted { return false }
            return try await store.requestFullAccessToReminders()
        } else {
            if status == .authorized { return true }
            if status == .denied || status == .restricted { return false }
            return try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: .reminder) { granted, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: granted) }
                }
            }
        }
    }

    public func fetchLists() async throws -> [ReminderListInfo] {
        guard try await requestAccess() else { throw AppleRemindersError.permissionDenied }
        return store.calendars(for: .reminder).map {
            ReminderListInfo(id: $0.calendarIdentifier, title: $0.title, allowsModification: $0.allowsContentModifications)
        }
    }

    public func ensureList(named title: String, preferredID: String?) async throws -> ReminderListInfo {
        guard try await requestAccess() else { throw AppleRemindersError.permissionDenied }
        let calendars = store.calendars(for: .reminder)
        if let preferredID,
           let match = calendars.first(where: { $0.calendarIdentifier == preferredID && $0.allowsContentModifications }) {
            return ReminderListInfo(id: match.calendarIdentifier, title: match.title, allowsModification: true)
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty,
           let existingByTitle = calendars.first(where: { $0.title.localizedCaseInsensitiveCompare(cleanTitle) == .orderedSame && $0.allowsContentModifications }) {
            return ReminderListInfo(id: existingByTitle.calendarIdentifier, title: existingByTitle.title, allowsModification: true)
        }
        if !cleanTitle.isEmpty, let source = store.defaultCalendarForNewReminders()?.source ?? store.sources.first(where: {
            $0.sourceType == .calDAV || $0.sourceType == .local
        }) {
            let created = EKCalendar(for: .reminder, eventStore: store)
            created.title = cleanTitle
            created.source = source
            if (try? store.saveCalendar(created, commit: true)) != nil {
                return ReminderListInfo(id: created.calendarIdentifier, title: created.title, allowsModification: true)
            }
        }
        if let defaultCal = store.defaultCalendarForNewReminders() {
            return ReminderListInfo(id: defaultCal.calendarIdentifier, title: defaultCal.title, allowsModification: defaultCal.allowsContentModifications)
        }
        throw AppleRemindersError.listNotFound
    }

    public func fetchReminders(inListID listID: String?, includeCompleted: Bool) async throws -> [ReminderItemSnapshot] {
        guard try await requestAccess() else { throw AppleRemindersError.permissionDenied }
        let calendars: [EKCalendar]?
        if let listID {
            let matching = store.calendars(for: .reminder).filter { $0.calendarIdentifier == listID }
            calendars = matching.isEmpty ? nil : matching
        } else {
            calendars = nil
        }
        let predicate = store.predicateForReminders(in: calendars)
        let ekReminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { items in
                continuation.resume(returning: items ?? [])
            }
        }
        return ekReminders.compactMap { reminder in
            if !includeCompleted && reminder.isCompleted { return nil }
            return snapshot(from: reminder)
        }
    }

    public func upsertReminder(
        existingExternalID: String?,
        listID: String?,
        listTitle: String,
        title: String,
        notes: String,
        dueDay: String?,
        dueAt: Date?,
        priority: TaskPriorityLevel?,
        isCompleted: Bool,
        reminderAlarmDate: Date? = nil,
        repeatRule: TaskReminderRepeatRule = .none
    ) async throws -> ReminderItemSnapshot {
        let listInfo = try await ensureList(named: listTitle, preferredID: listID)
        let calendar = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == listInfo.id })
            ?? store.defaultCalendarForNewReminders()

        let existing: EKReminder?
        if let existingExternalID, !existingExternalID.isEmpty {
            if let item = store.calendarItem(withIdentifier: existingExternalID) as? EKReminder {
                existing = item
            } else {
                existing = store.calendarItems(withExternalIdentifier: existingExternalID).compactMap { $0 as? EKReminder }.first
            }
        } else {
            existing = nil
        }

        let reminder = existing ?? EKReminder(eventStore: store)
        if existing == nil, let calendar {
            reminder.calendar = calendar
        }
        reminder.title = String(title.prefix(500))
        reminder.notes = String(notes.prefix(8_000))
        reminder.isCompleted = isCompleted
        reminder.completionDate = isCompleted ? (reminder.completionDate ?? Date()) : nil
        if let priority {
            reminder.priority = priority.eventKitPriority
        }
        if let dueDay, let comps = parseDayComponents(dueDay) {
            reminder.dueDateComponents = comps
        } else if let dueAt {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueAt)
        } else {
            reminder.dueDateComponents = nil
        }

        reminder.alarms = []
        if !isCompleted, let alarmDate = reminderAlarmDate {
            reminder.addAlarm(EKAlarm(absoluteDate: alarmDate))
        }
        reminder.recurrenceRules = Self.eventKitRecurrenceRules(for: repeatRule)

        try store.save(reminder, commit: true)
        return snapshot(from: reminder)
    }

    private func snapshot(from reminder: EKReminder) -> ReminderItemSnapshot {
        let comps = reminder.dueDateComponents
        var dueDay: String?
        var dueAt: Date?
        if let comps, let year = comps.year, let month = comps.month, let day = comps.day {
            if comps.hour == nil && comps.minute == nil {
                dueDay = String(format: "%04d-%02d-%02d", year, month, day)
            } else {
                dueAt = Calendar.current.date(from: comps)
                dueDay = String(format: "%04d-%02d-%02d", year, month, day)
            }
        }
        let externalID = (reminder.calendarItemExternalIdentifier.isEmpty ? nil : reminder.calendarItemExternalIdentifier)
            ?? reminder.calendarItemIdentifier
        let alarmDate = reminder.alarms?.compactMap(\.absoluteDate).sorted().first
        let mappedRepeat = Self.mapRecurrenceRule(reminder.recurrenceRules?.first)
        return ReminderItemSnapshot(
            id: reminder.calendarItemIdentifier,
            externalIdentifier: externalID,
            title: reminder.title ?? "",
            notes: reminder.notes ?? "",
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            dueDay: dueDay,
            dueAt: dueAt,
            priority: TaskPriorityLevel(eventKitPriority: reminder.priority),
            reminderAlarmDate: alarmDate,
            repeatRule: mappedRepeat,
            lastModifiedAt: reminder.lastModifiedDate,
            listID: reminder.calendar?.calendarIdentifier,
            listTitle: reminder.calendar?.title
        )
    }

    private static func eventKitRecurrenceRules(for repeatRule: TaskReminderRepeatRule) -> [EKRecurrenceRule] {
        switch repeatRule {
        case .none, .every4Hours:
            return []
        case .daily:
            return [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)]
        case .weekdays:
            let days: [EKRecurrenceDayOfWeek] = [.monday, .tuesday, .wednesday, .thursday, .friday].map {
                EKRecurrenceDayOfWeek($0)
            }
            return [EKRecurrenceRule(
                recurrenceWith: .weekly,
                interval: 1,
                daysOfTheWeek: days,
                daysOfTheMonth: nil,
                monthsOfTheYear: nil,
                weeksOfTheYear: nil,
                daysOfTheYear: nil,
                setPositions: nil,
                end: nil
            )]
        case .weekly:
            return [EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)]
        }
    }

    private static func mapRecurrenceRule(_ rule: EKRecurrenceRule?) -> TaskReminderRepeatRule {
        guard let rule else { return .none }
        switch rule.frequency {
        case .daily:
            return .daily
        case .weekly:
            if let days = rule.daysOfTheWeek, days.count == 5 {
                return .weekdays
            }
            return .weekly
        default:
            return .none
        }
    }

    private func parseDayComponents(_ value: String) -> DateComponents? {
        let parts = value.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return DateComponents(year: y, month: m, day: d)
    }
}
