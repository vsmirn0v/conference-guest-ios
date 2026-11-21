import EventKit
import Foundation

public struct WritableEventCalendarInfo: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var sourceTitle: String

    public init(id: String, title: String, sourceTitle: String) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
    }
}

public struct UpcomingCalendarEventSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var calendarItemIdentifier: String
    public var seriesID: String?
    public var calendarTitle: String
    public var title: String
    public var startAt: Date
    public var endAt: Date
    public var meetingURL: String?
    public var notes: String

    public init(
        id: String,
        calendarItemIdentifier: String,
        seriesID: String? = nil,
        calendarTitle: String,
        title: String,
        startAt: Date,
        endAt: Date,
        meetingURL: String? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.calendarItemIdentifier = calendarItemIdentifier
        self.seriesID = seriesID
        self.calendarTitle = calendarTitle
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.meetingURL = meetingURL
        self.notes = notes
    }
}

public struct TaskCalendarEventDraft: Equatable, Sendable {
    public var calendarIdentifier: String?
    public var title: String
    public var startAt: Date
    public var endAt: Date
    public var meetingURL: String?
    public var agendaNotes: String
    public var alarmOffsetMinutesBefore: Int?

    public init(
        calendarIdentifier: String? = nil,
        title: String,
        startAt: Date,
        endAt: Date,
        meetingURL: String? = nil,
        agendaNotes: String = "",
        alarmOffsetMinutesBefore: Int? = 10
    ) {
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.startAt = startAt
        self.endAt = max(startAt.addingTimeInterval(300), endAt)
        self.meetingURL = meetingURL
        self.agendaNotes = agendaNotes
        self.alarmOffsetMinutesBefore = alarmOffsetMinutesBefore
    }
}

public enum TaskCalendarEventError: LocalizedError, Equatable {
    case permissionDenied
    case noWritableCalendar
    case invalidDateRange

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return L("Calendar access is disabled. Allow Calendar access in System Settings or Settings app.")
        case .noWritableCalendar:
            return L("No writable calendar is available on this device.")
        case .invalidDateRange:
            return L("End time must be after start time.")
        }
    }
}

public protocol TaskCalendarEventConnecting: Sendable {
    func requestAccessAndFetchCalendars() async throws -> [WritableEventCalendarInfo]
    func fetchUpcomingEvents(daysAhead: Int) async throws -> [UpcomingCalendarEventSummary]
    func createDiscussionEvent(_ draft: TaskCalendarEventDraft, forTaskID taskID: UUID) async throws -> TaskLinkedDiscussionMeeting
}

/// Reads writable calendars/upcoming events and creates Apple Calendar discussion events linked to tasks or epics.
public actor TaskCalendarEventConnector: TaskCalendarEventConnecting {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    public func requestAccess() async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, macOS 14.0, *) {
            if status == .fullAccess { return true }
            if status == .denied || status == .restricted { return false }
            return try await store.requestFullAccessToEvents()
        } else {
            if status == .authorized { return true }
            if status == .denied || status == .restricted { return false }
            return try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: .event) { granted, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: granted) }
                }
            }
        }
    }

    public func requestAccessAndFetchCalendars() async throws -> [WritableEventCalendarInfo] {
        guard try await requestAccess() else { throw TaskCalendarEventError.permissionDenied }
        return store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map {
                WritableEventCalendarInfo(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    sourceTitle: $0.source?.title ?? L("Calendar")
                )
            }
            .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
    }

    public func fetchUpcomingEvents(daysAhead: Int = 21) async throws -> [UpcomingCalendarEventSummary] {
        guard try await requestAccess() else { throw TaskCalendarEventError.permissionDenied }
        let start = Date().addingTimeInterval(-3600)
        let end = Calendar.current.date(byAdding: .day, value: max(1, daysAhead), to: start)
            ?? start.addingTimeInterval(Double(daysAhead) * 86_400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled && $0.endDate > start }
            .sorted { ($0.startDate ?? start) < ($1.startDate ?? start) }
            .prefix(80)
            .map { event in
                let rawID = event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier
                let meetingURL = event.url?.absoluteString
                    ?? Self.firstURLString(in: event.location)
                    ?? Self.firstURLString(in: event.notes)
                return UpcomingCalendarEventSummary(
                    id: "\(event.calendarItemIdentifier)|\(Int64((event.startDate ?? start).timeIntervalSince1970))",
                    calendarItemIdentifier: event.calendarItemIdentifier,
                    seriesID: rawID,
                    calendarTitle: event.calendar?.title ?? L("Calendar"),
                    title: event.title ?? L("Meeting"),
                    startAt: event.startDate ?? start,
                    endAt: event.endDate ?? start.addingTimeInterval(1800),
                    meetingURL: meetingURL,
                    notes: event.notes ?? ""
                )
            }
    }

    public func createDiscussionEvent(
        _ draft: TaskCalendarEventDraft,
        forTaskID taskID: UUID
    ) async throws -> TaskLinkedDiscussionMeeting {
        guard try await requestAccess() else { throw TaskCalendarEventError.permissionDenied }
        guard draft.endAt > draft.startAt else { throw TaskCalendarEventError.invalidDateRange }

        let writable = store.calendars(for: .event).filter(\.allowsContentModifications)
        let targetCalendar = writable.first(where: { $0.calendarIdentifier == draft.calendarIdentifier })
            ?? store.defaultCalendarForNewEvents
            ?? writable.first
        guard let targetCalendar else { throw TaskCalendarEventError.noWritableCalendar }

        let event = EKEvent(eventStore: store)
        event.calendar = targetCalendar
        event.title = String(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        event.startDate = draft.startAt
        event.endDate = draft.endAt

        let cleanURL = draft.meetingURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanURL, !cleanURL.isEmpty, let parsedURL = URL(string: cleanURL) {
            event.url = parsedURL
            event.location = cleanURL
        }

        let marker = "[RnR-Task: \(taskID.uuidString)]"
        let cleanAgenda = draft.agendaNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        var noteSections = [marker]
        if !cleanAgenda.isEmpty { noteSections.append(cleanAgenda) }
        if let cleanURL, !cleanURL.isEmpty { noteSections.append(cleanURL) }
        event.notes = noteSections.joined(separator: "\n\n")

        if let minutes = draft.alarmOffsetMinutesBefore, minutes >= 0 {
            event.alarms = [EKAlarm(relativeOffset: -Double(minutes * 60))]
        }

        try store.save(event, span: .thisEvent, commit: true)

        return TaskLinkedDiscussionMeeting(
            calendarEventIdentifier: event.calendarItemIdentifier,
            calendarSeriesID: event.calendarItemExternalIdentifier,
            title: event.title ?? draft.title,
            startAt: event.startDate ?? draft.startAt,
            endAt: event.endDate ?? draft.endAt,
            meetingURL: cleanURL?.isEmpty == false ? cleanURL : nil,
            calendarTitle: targetCalendar.title,
            agendaNotes: cleanAgenda
        )
    }

    /// Generates an RFC 5545 iCalendar payload embedding `[RnR-Task: <UUID>]` for sharing or external calendar import.
    public static func buildICSData(draft: TaskCalendarEventDraft, taskID: UUID) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"

        func escapeICS(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,")
                .replacingOccurrences(of: "\r\n", with: "\\n")
                .replacingOccurrences(of: "\n", with: "\\n")
        }

        let uid = "\(taskID.uuidString)-\(Int64(draft.startAt.timeIntervalSince1970))@rocknroll"
        let marker = "[RnR-Task: \(taskID.uuidString)]"
        let combinedDescription = [marker, draft.agendaNotes.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//RockNRoll//TaskDiscussion//EN",
            "BEGIN:VEVENT",
            "UID:\(uid)",
            "DTSTAMP:\(formatter.string(from: Date()))",
            "DTSTART:\(formatter.string(from: draft.startAt))",
            "DTEND:\(formatter.string(from: draft.endAt))",
            "SUMMARY:\(escapeICS(draft.title))",
            "DESCRIPTION:\(escapeICS(combinedDescription))"
        ]
        if let url = draft.meetingURL?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            lines.append("URL:\(url)")
            lines.append("LOCATION:\(escapeICS(url))")
        }
        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private static func firstURLString(in text: String?) -> String? {
        guard let text, !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        return detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url?.absoluteString
    }
}
