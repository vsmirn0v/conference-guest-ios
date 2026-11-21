import Foundation

public enum TaskWorkflowStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case todo = "todo"
    case inProgress = "in_progress"
    case blocked = "blocked"
    case inReview = "in_review"
    case done = "done"
    case cancelled = "cancelled"

    public var id: String { rawValue }

    public var isTerminalDone: Bool {
        self == .done || self == .cancelled
    }

    public var localizedTitle: String {
        switch self {
        case .todo: return L("To Do")
        case .inProgress: return L("In Progress")
        case .blocked: return L("Blocked")
        case .inReview: return L("In Review")
        case .done: return L("Done")
        case .cancelled: return L("Cancelled")
        }
    }

    public var systemImage: String {
        switch self {
        case .todo: return "circle"
        case .inProgress: return "clock.arrow.circlepath"
        case .blocked: return "exclamationmark.octagon.fill"
        case .inReview: return "eye.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }
}

public enum TaskPriorityLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case low
    case medium
    case high
    case critical

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .low: return L("Low")
        case .medium: return L("Medium")
        case .high: return L("High")
        case .critical: return L("Critical")
        }
    }

    public var eventKitPriority: Int {
        switch self {
        case .critical, .high: return 1
        case .medium: return 5
        case .low: return 9
        }
    }

    public init?(eventKitPriority: Int) {
        switch eventKitPriority {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: return nil
        }
    }
}

public enum TaskContextSource: String, Codable, Sendable {
    case meetingExtraction = "meeting_extraction"
    case meetingFollowUp = "meeting_follow_up"
    case userEdit = "user_edit"
    case jiraSync = "jira_sync"
    case remindersSync = "reminders_sync"
}

public struct TaskMeetingContextEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID?
    public var meetingTitle: String
    public var observedAt: Date
    public var previousStatus: TaskWorkflowStatus?
    public var updatedStatus: TaskWorkflowStatus?
    public var note: String
    public var evidenceQuote: String?
    public var source: TaskContextSource

    public init(
        id: UUID = UUID(),
        sessionID: UUID? = nil,
        meetingTitle: String,
        observedAt: Date = Date(),
        previousStatus: TaskWorkflowStatus? = nil,
        updatedStatus: TaskWorkflowStatus? = nil,
        note: String,
        evidenceQuote: String? = nil,
        source: TaskContextSource
    ) {
        self.id = id
        self.sessionID = sessionID
        self.meetingTitle = String(meetingTitle.prefix(240))
        self.observedAt = observedAt
        self.previousStatus = previousStatus
        self.updatedStatus = updatedStatus
        self.note = String(note.prefix(2000))
        self.evidenceQuote = evidenceQuote.map { String($0.prefix(600)) }
        self.source = source
    }
}

public enum ExternalTaskProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case jira
    case appleReminders = "apple_reminders"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .jira: return "Jira"
        case .appleReminders: return L("Apple Reminders")
        }
    }
}

public struct ExternalTaskBinding: Codable, Equatable, Identifiable, Sendable {
    public var provider: ExternalTaskProviderKind
    public var externalID: String
    public var externalKey: String?
    public var externalURL: String?
    public var projectOrList: String?
    public var remoteStatus: String?
    public var remoteAssignee: String?
    public var lastSyncedAt: Date
    public var remoteUpdatedAt: Date?
    public var lastSyncedDigest: String?

    public var id: String { "\(provider.rawValue):\(externalID)" }

    public init(
        provider: ExternalTaskProviderKind,
        externalID: String,
        externalKey: String? = nil,
        externalURL: String? = nil,
        projectOrList: String? = nil,
        remoteStatus: String? = nil,
        remoteAssignee: String? = nil,
        lastSyncedAt: Date = Date(),
        remoteUpdatedAt: Date? = nil,
        lastSyncedDigest: String? = nil
    ) {
        self.provider = provider
        self.externalID = externalID
        self.externalKey = externalKey
        self.externalURL = externalURL
        self.projectOrList = projectOrList
        self.remoteStatus = remoteStatus
        self.remoteAssignee = remoteAssignee
        self.lastSyncedAt = lastSyncedAt
        self.remoteUpdatedAt = remoteUpdatedAt
        self.lastSyncedDigest = lastSyncedDigest
    }
}

public enum TaskIssueKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case task
    case epic
    case story
    case bug

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .task: return L("Task")
        case .epic: return L("Epic")
        case .story: return L("Story")
        case .bug: return L("Bug")
        }
    }

    public var jiraIssueTypeName: String {
        switch self {
        case .task: return "Task"
        case .epic: return "Epic"
        case .story: return "Story"
        case .bug: return "Bug"
        }
    }

    public var systemImage: String {
        switch self {
        case .task: return "checkmark.square"
        case .epic: return "bolt.horizontal.circle.fill"
        case .story: return "book.closed"
        case .bug: return "ladybug"
        }
    }
}

public enum TaskReminderTriggerMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case atSpecificTime = "specific_time"
    case onDueDate = "on_due_date"
    case beforeDue = "before_due"
    case beforeLinkedMeeting = "before_linked_meeting"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .atSpecificTime: return L("Custom date & time")
        case .onDueDate: return L("On due date")
        case .beforeDue: return L("Before due date")
        case .beforeLinkedMeeting: return L("Before linked discussion meeting")
        }
    }
}

public enum TaskReminderRepeatRule: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case every4Hours = "every_4_hours"
    case daily
    case weekdays
    case weekly

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .none: return L("Once")
        case .every4Hours: return L("Every 4 hours")
        case .daily: return L("Every day")
        case .weekdays: return L("Weekdays (Mon–Fri)")
        case .weekly: return L("Every week")
        }
    }
}

/// User-configured reminder trigger, recurrence, and escalation policy for a task or epic.
public struct TaskReminderRule: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var triggerMode: TaskReminderTriggerMode
    public var customDate: Date?
    public var hourOfDay: Int
    public var minuteOfHour: Int
    public var offsetMinutesBefore: Int
    public var repeatRule: TaskReminderRepeatRule
    public var escalateWhenBlockedOrOverdue: Bool

    public init(
        isEnabled: Bool = true,
        triggerMode: TaskReminderTriggerMode = .atSpecificTime,
        customDate: Date? = nil,
        hourOfDay: Int = 9,
        minuteOfHour: Int = 0,
        offsetMinutesBefore: Int = 60,
        repeatRule: TaskReminderRepeatRule = .none,
        escalateWhenBlockedOrOverdue: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.triggerMode = triggerMode
        self.customDate = customDate
        self.hourOfDay = min(23, max(0, hourOfDay))
        self.minuteOfHour = min(59, max(0, minuteOfHour))
        self.offsetMinutesBefore = max(1, offsetMinutesBefore)
        self.repeatRule = repeatRule
        self.escalateWhenBlockedOrOverdue = escalateWhenBlockedOrOverdue
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        triggerMode = try c.decodeIfPresent(TaskReminderTriggerMode.self, forKey: .triggerMode) ?? .atSpecificTime
        customDate = try c.decodeIfPresent(Date.self, forKey: .customDate)
        hourOfDay = min(23, max(0, try c.decodeIfPresent(Int.self, forKey: .hourOfDay) ?? 9))
        minuteOfHour = min(59, max(0, try c.decodeIfPresent(Int.self, forKey: .minuteOfHour) ?? 0))
        offsetMinutesBefore = max(1, try c.decodeIfPresent(Int.self, forKey: .offsetMinutesBefore) ?? 60)
        repeatRule = try c.decodeIfPresent(TaskReminderRepeatRule.self, forKey: .repeatRule) ?? .none
        escalateWhenBlockedOrOverdue = try c.decodeIfPresent(Bool.self, forKey: .escalateWhenBlockedOrOverdue) ?? false
    }

    public static func inOneHour(now: Date = Date(), calendar: Calendar = .current) -> Self {
        let target = now.addingTimeInterval(3600)
        let comps = calendar.dateComponents([.hour, .minute], from: target)
        return TaskReminderRule(
            isEnabled: true,
            triggerMode: .atSpecificTime,
            customDate: target,
            hourOfDay: comps.hour ?? 9,
            minuteOfHour: comps.minute ?? 0
        )
    }

    public static func tonight(now: Date = Date(), calendar: Calendar = .current) -> Self {
        var target = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(3600)
        if target <= now {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? now.addingTimeInterval(86_400)
        }
        return TaskReminderRule(isEnabled: true, triggerMode: .atSpecificTime, customDate: target, hourOfDay: 18, minuteOfHour: 0)
    }

    public static func tomorrowMorning(now: Date = Date(), calendar: Calendar = .current) -> Self {
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        let target = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: nextDay) ?? nextDay
        return TaskReminderRule(isEnabled: true, triggerMode: .atSpecificTime, customDate: target, hourOfDay: 9, minuteOfHour: 0)
    }

    public static func nextMondayMorning(now: Date = Date(), calendar: Calendar = .current) -> Self {
        var components = DateComponents()
        components.weekday = 2 // Monday
        components.hour = 9
        components.minute = 0
        components.second = 0
        let target = calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(7 * 86_400)
        return TaskReminderRule(isEnabled: true, triggerMode: .atSpecificTime, customDate: target, hourOfDay: 9, minuteOfHour: 0)
    }

    public static func oneDayBeforeDue(hour: Int = 9, minute: Int = 0) -> Self {
        TaskReminderRule(
            isEnabled: true,
            triggerMode: .beforeDue,
            hourOfDay: hour,
            minuteOfHour: minute,
            offsetMinutesBefore: 24 * 60
        )
    }

    public static func dailyFollowUp(hour: Int = 9, minute: Int = 0, now: Date = Date(), calendar: Calendar = .current) -> Self {
        var target = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now.addingTimeInterval(3600)
        if target <= now {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? target.addingTimeInterval(86_400)
        }
        return TaskReminderRule(
            isEnabled: true,
            triggerMode: .atSpecificTime,
            customDate: target,
            hourOfDay: hour,
            minuteOfHour: minute,
            repeatRule: .daily
        )
    }

    /// Computes the next reminder instant strictly after `now`, returning `nil` if the task is completed or the rule has expired.
    public func nextFireDate(
        after now: Date,
        dueDay: String?,
        dueAt: Date?,
        status: TaskWorkflowStatus = .todo,
        done: Bool = false,
        scheduledDiscussions: [TaskLinkedDiscussionMeeting] = [],
        calendar: Calendar = .current
    ) -> Date? {
        guard isEnabled, !done, !status.isTerminalDone else { return nil }

        let parsedDueDay = Self.parseDay(dueDay, hour: hourOfDay, minute: minuteOfHour, calendar: calendar)
        let deadlineInstant = Self.dueDeadlineInstant(dueDay: dueDay, dueAt: dueAt, calendar: calendar)
        var candidate: Date?

        switch triggerMode {
        case .atSpecificTime:
            candidate = customDate
        case .onDueDate:
            candidate = parsedDueDay ?? dueAt
        case .beforeDue:
            let anchor = dueAt ?? parsedDueDay
            candidate = anchor?.addingTimeInterval(-TimeInterval(offsetMinutesBefore * 60))
        case .beforeLinkedMeeting:
            let nextMeeting = scheduledDiscussions
                .filter { $0.startAt > now }
                .min { $0.startAt < $1.startAt }
            if let nextMeeting {
                let raw = nextMeeting.startAt.addingTimeInterval(-TimeInterval(offsetMinutesBefore * 60))
                candidate = raw > now ? raw : now.addingTimeInterval(60)
            }
        }

        if repeatRule != .none, candidate == nil || candidate! <= now {
            candidate = nextRepeatedFireDate(after: now, anchor: candidate ?? customDate ?? now, calendar: calendar)
        } else if let c = candidate, c <= now {
            candidate = nil
        }

        if escalateWhenBlockedOrOverdue {
            let isOverdue = deadlineInstant.map { $0 < now } ?? false
            if status == .blocked || isOverdue {
                let escalation = nextDailyOccurrence(after: now, hour: hourOfDay, minute: minuteOfHour, calendar: calendar)
                if candidate == nil || candidate! > escalation.addingTimeInterval(3600) {
                    candidate = escalation
                }
            }
        }

        return candidate
    }

    public func summaryLabel(calendar: Calendar = .current) -> String {
        var parts: [String] = []
        switch triggerMode {
        case .atSpecificTime:
            if let customDate {
                parts.append(customDate.formatted(date: .abbreviated, time: .shortened))
            } else {
                parts.append(triggerMode.localizedTitle)
            }
        case .onDueDate:
            parts.append(String(format: "%@ · %02d:%02d", L("Due day"), hourOfDay, minuteOfHour))
        case .beforeDue:
            parts.append(Self.formatOffsetLabel(offsetMinutesBefore) + " " + L("before due"))
        case .beforeLinkedMeeting:
            parts.append(Self.formatOffsetLabel(offsetMinutesBefore) + " " + L("before meeting"))
        }
        if repeatRule != .none {
            parts.append(repeatRule.localizedTitle)
        }
        if escalateWhenBlockedOrOverdue {
            parts.append(L("Escalate"))
        }
        return parts.joined(separator: " · ")
    }

    private func nextRepeatedFireDate(after now: Date, anchor: Date, calendar: Calendar) -> Date {
        switch repeatRule {
        case .none:
            return anchor
        case .every4Hours:
            let step: TimeInterval = 4 * 3600
            if anchor > now { return anchor }
            let elapsed = now.timeIntervalSince(anchor)
            let jumps = floor(elapsed / step) + 1
            return anchor.addingTimeInterval(jumps * step)
        case .daily:
            return nextDailyOccurrence(after: now, hour: hourOfDay, minute: minuteOfHour, calendar: calendar)
        case .weekdays:
            var cursor = nextDailyOccurrence(after: now, hour: hourOfDay, minute: minuteOfHour, calendar: calendar)
            for _ in 0..<7 {
                let weekday = calendar.component(.weekday, from: cursor)
                if weekday != 1 && weekday != 7 { return cursor }
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86_400)
            }
            return cursor
        case .weekly:
            var cursor = anchor
            while cursor <= now {
                cursor = calendar.date(byAdding: .day, value: 7, to: cursor) ?? cursor.addingTimeInterval(7 * 86_400)
            }
            return cursor
        }
    }

    private func nextDailyOccurrence(after now: Date, hour: Int, minute: Int, calendar: Calendar) -> Date {
        var todayCandidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now.addingTimeInterval(3600)
        if todayCandidate <= now {
            todayCandidate = calendar.date(byAdding: .day, value: 1, to: todayCandidate) ?? todayCandidate.addingTimeInterval(86_400)
        }
        return todayCandidate
    }

    private static func formatOffsetLabel(_ minutes: Int) -> String {
        if minutes >= 1440 && minutes % 1440 == 0 {
            return "\(minutes / 1440)d"
        }
        if minutes >= 60 && minutes % 60 == 0 {
            return "\(minutes / 60)h"
        }
        return "\(minutes)m"
    }

    private static func parseDay(_ dueDay: String?, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        guard let dueDay else { return nil }
        let parts = dueDay.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))
    }

    private static func dueDeadlineInstant(dueDay: String?, dueAt: Date?, calendar: Calendar) -> Date? {
        guard let dueDay else { return dueAt }
        let parts = dueDay.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              let dayStart = calendar.date(from: DateComponents(year: y, month: m, day: d)) else { return dueAt }
        return calendar.dateInterval(of: .day, for: dayStart)?.end ?? dayStart
    }
}

/// A calendar meeting or upcoming session explicitly linked to discuss a task or epic.
public struct TaskLinkedDiscussionMeeting: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var calendarEventIdentifier: String?
    public var calendarSeriesID: String?
    public var linkedSessionID: UUID?
    public var title: String
    public var startAt: Date
    public var endAt: Date
    public var meetingURL: String?
    public var calendarTitle: String?
    public var agendaNotes: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        calendarEventIdentifier: String? = nil,
        calendarSeriesID: String? = nil,
        linkedSessionID: UUID? = nil,
        title: String,
        startAt: Date,
        endAt: Date,
        meetingURL: String? = nil,
        calendarTitle: String? = nil,
        agendaNotes: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.calendarEventIdentifier = calendarEventIdentifier
        self.calendarSeriesID = calendarSeriesID
        self.linkedSessionID = linkedSessionID
        self.title = String(title.prefix(240))
        self.startAt = startAt
        self.endAt = max(startAt, endAt)
        self.meetingURL = meetingURL
        self.calendarTitle = calendarTitle
        self.agendaNotes = String(agendaNotes.prefix(4_000))
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        calendarEventIdentifier = try c.decodeIfPresent(String.self, forKey: .calendarEventIdentifier)
        calendarSeriesID = try c.decodeIfPresent(String.self, forKey: .calendarSeriesID)
        linkedSessionID = try c.decodeIfPresent(UUID.self, forKey: .linkedSessionID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        startAt = try c.decodeIfPresent(Date.self, forKey: .startAt) ?? Date()
        endAt = try c.decodeIfPresent(Date.self, forKey: .endAt) ?? startAt
        meetingURL = try c.decodeIfPresent(String.self, forKey: .meetingURL)
        calendarTitle = try c.decodeIfPresent(String.self, forKey: .calendarTitle)
        agendaNotes = try c.decodeIfPresent(String.self, forKey: .agendaNotes) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

public struct TaskExtendedMetadata: Codable, Equatable, Sendable {
    public static let externalImportsSessionID = UUID(uuidString: "00000000-0000-0000-0000-00000000E7A5")!
    public static let externalImportsOutcomeID = UUID(uuidString: "00000000-0000-0000-0000-00000000E7A6")!

    public var workflowStatus: TaskWorkflowStatus
    public var priority: TaskPriorityLevel?
    public var issueKind: TaskIssueKind
    public var parentEpicKey: String?
    public var parentEpicTitle: String?
    public var reminderRule: TaskReminderRule?
    public var scheduledDiscussions: [TaskLinkedDiscussionMeeting]
    public var contextNotes: String
    public var contextHistory: [TaskMeetingContextEntry]
    public var externalBindings: [ExternalTaskBinding]

    public init(
        workflowStatus: TaskWorkflowStatus = .todo,
        priority: TaskPriorityLevel? = nil,
        issueKind: TaskIssueKind = .task,
        parentEpicKey: String? = nil,
        parentEpicTitle: String? = nil,
        reminderRule: TaskReminderRule? = nil,
        scheduledDiscussions: [TaskLinkedDiscussionMeeting] = [],
        contextNotes: String = "",
        contextHistory: [TaskMeetingContextEntry] = [],
        externalBindings: [ExternalTaskBinding] = []
    ) {
        self.workflowStatus = workflowStatus
        self.priority = priority
        self.issueKind = issueKind
        self.parentEpicKey = parentEpicKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : parentEpicKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.parentEpicTitle = parentEpicTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : parentEpicTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reminderRule = reminderRule
        self.scheduledDiscussions = scheduledDiscussions
        self.contextNotes = String(contextNotes.prefix(8_000))
        self.contextHistory = Array(contextHistory.suffix(50))
        self.externalBindings = externalBindings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workflowStatus = try c.decodeIfPresent(TaskWorkflowStatus.self, forKey: .workflowStatus) ?? .todo
        priority = try c.decodeIfPresent(TaskPriorityLevel.self, forKey: .priority)
        issueKind = try c.decodeIfPresent(TaskIssueKind.self, forKey: .issueKind) ?? .task
        parentEpicKey = try c.decodeIfPresent(String.self, forKey: .parentEpicKey)
        parentEpicTitle = try c.decodeIfPresent(String.self, forKey: .parentEpicTitle)
        reminderRule = try c.decodeIfPresent(TaskReminderRule.self, forKey: .reminderRule)
        scheduledDiscussions = try c.decodeIfPresent([TaskLinkedDiscussionMeeting].self, forKey: .scheduledDiscussions) ?? []
        contextNotes = try c.decodeIfPresent(String.self, forKey: .contextNotes) ?? ""
        contextHistory = try c.decodeIfPresent([TaskMeetingContextEntry].self, forKey: .contextHistory) ?? []
        externalBindings = try c.decodeIfPresent([ExternalTaskBinding].self, forKey: .externalBindings) ?? []
    }

    public var isEmpty: Bool {
        workflowStatus == .todo &&
            priority == nil &&
            issueKind == .task &&
            (parentEpicKey?.isEmpty ?? true) &&
            (parentEpicTitle?.isEmpty ?? true) &&
            reminderRule == nil &&
            scheduledDiscussions.isEmpty &&
            contextNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            contextHistory.isEmpty &&
            externalBindings.isEmpty
    }

    public mutating func upsertScheduledDiscussion(_ meeting: TaskLinkedDiscussionMeeting) {
        if let idx = scheduledDiscussions.firstIndex(where: {
            $0.id == meeting.id ||
                (meeting.calendarEventIdentifier != nil && $0.calendarEventIdentifier == meeting.calendarEventIdentifier)
        }) {
            scheduledDiscussions[idx] = meeting
        } else {
            scheduledDiscussions.append(meeting)
        }
        scheduledDiscussions.sort { ($0.startAt, $0.id.uuidString) < ($1.startAt, $1.id.uuidString) }
    }

    public mutating func removeScheduledDiscussion(id: UUID) {
        scheduledDiscussions.removeAll { $0.id == id }
    }

    public mutating func applyDoneFlag(_ done: Bool) {
        if done {
            if !workflowStatus.isTerminalDone {
                workflowStatus = .done
            }
        } else if workflowStatus.isTerminalDone {
            workflowStatus = .todo
        }
    }

    public mutating func appendContextNote(_ addition: String) {
        let clean = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if contextNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contextNotes = String(clean.prefix(8_000))
            return
        }
        let foldedExisting = contextNotes.workspaceFolded
        let foldedAddition = clean.workspaceFolded
        guard !foldedExisting.contains(foldedAddition) else { return }
        contextNotes = String((contextNotes + "\n\n" + clean).prefix(8_000))
    }

    public mutating func appendHistory(_ entry: TaskMeetingContextEntry) {
        if let idx = contextHistory.firstIndex(where: { $0.id == entry.id }) {
            contextHistory[idx] = entry
        } else {
            contextHistory.append(entry)
        }
        contextHistory.sort { ($0.observedAt, $0.id.uuidString) < ($1.observedAt, $1.id.uuidString) }
        if contextHistory.count > 50 {
            contextHistory = Array(contextHistory.suffix(50))
        }
    }

    public mutating func upsertBinding(_ binding: ExternalTaskBinding) {
        if let idx = externalBindings.firstIndex(where: { $0.provider == binding.provider && $0.externalID == binding.externalID })
            ?? externalBindings.firstIndex(where: { $0.provider == binding.provider }) {
            externalBindings[idx] = binding
        } else {
            externalBindings.append(binding)
        }
    }

    public func binding(for provider: ExternalTaskProviderKind) -> ExternalTaskBinding? {
        externalBindings.first { $0.provider == provider }
    }

    public func merging(_ other: TaskExtendedMetadata, preferOtherScalars: Bool) -> TaskExtendedMetadata {
        var result = preferOtherScalars ? other : self
        let secondary = preferOtherScalars ? self : other

        if result.contextNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.contextNotes = secondary.contextNotes
        } else if !secondary.contextNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  result.contextNotes.workspaceFolded != secondary.contextNotes.workspaceFolded {
            result.appendContextNote(secondary.contextNotes)
        }
        if result.priority == nil {
            result.priority = secondary.priority
        }
        if result.issueKind == .task && secondary.issueKind != .task {
            result.issueKind = secondary.issueKind
        }
        if result.parentEpicKey == nil {
            result.parentEpicKey = secondary.parentEpicKey
        }
        if result.parentEpicTitle == nil {
            result.parentEpicTitle = secondary.parentEpicTitle
        }
        if result.reminderRule == nil {
            result.reminderRule = secondary.reminderRule
        }

        var mergedDiscussions = Dictionary(uniqueKeysWithValues: secondary.scheduledDiscussions.map { ($0.id, $0) })
        for discussion in result.scheduledDiscussions {
            mergedDiscussions[discussion.id] = discussion
        }
        result.scheduledDiscussions = mergedDiscussions.values.sorted {
            ($0.startAt, $0.id.uuidString) < ($1.startAt, $1.id.uuidString)
        }

        var mergedHistory = Dictionary(uniqueKeysWithValues: secondary.contextHistory.map { ($0.id, $0) })
        for entry in result.contextHistory {
            mergedHistory[entry.id] = entry
        }
        result.contextHistory = mergedHistory.values
            .sorted { ($0.observedAt, $0.id.uuidString) < ($1.observedAt, $1.id.uuidString) }
            .suffix(50)
            .map { $0 }

        var byProvider: [ExternalTaskProviderKind: ExternalTaskBinding] = [:]
        for binding in secondary.externalBindings + result.externalBindings {
            if let existing = byProvider[binding.provider] {
                if binding.lastSyncedAt >= existing.lastSyncedAt {
                    byProvider[binding.provider] = binding
                }
            } else {
                byProvider[binding.provider] = binding
            }
        }
        result.externalBindings = ExternalTaskProviderKind.allCases.compactMap { byProvider[$0] }
        return result
    }
}
