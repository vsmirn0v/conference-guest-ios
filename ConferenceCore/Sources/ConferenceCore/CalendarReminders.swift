import Foundation

public struct ReminderFollowUp: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case off, anotherMeeting, always }
    public var mode: Mode
    public var delay: Int
    public init(mode: Mode = .anotherMeeting, delay: Int = 30) { self.mode = mode; self.delay = delay }
    public var validated: Self { .init(mode: mode, delay: min(3600, max(1, delay))) }
}

public struct ReminderTiming: Codable, Equatable, Sendable {
    public var before: Int?
    public var atStart: Bool
    public var followUp: ReminderFollowUp
    public var rememberedBefore: Int = 120
    public var rememberedAfter: Int = 30
    /// Legacy source compatibility. Setting this explicitly retains unconditional delivery.
    public var after: Int? {
        get { followUp.mode == .off ? nil : followUp.delay }
        set { followUp = .init(mode: newValue == nil ? .off : .always, delay: newValue ?? followUp.delay) }
    }
    public init(before: Int? = nil, atStart: Bool = true, after: Int? = nil,
                followUp: ReminderFollowUp? = nil) {
        self.before = before; self.atStart = atStart
        self.followUp = followUp ?? after.map { .init(mode: .always, delay: $0) } ?? .init()
    }
    private enum CodingKeys: String, CodingKey { case before, atStart, after, followUp, rememberedBefore, rememberedAfter }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        before = try c.decodeIfPresent(Int.self, forKey: .before)
        atStart = try c.decode(Bool.self, forKey: .atStart)
        rememberedBefore = try c.decodeIfPresent(Int.self, forKey: .rememberedBefore) ?? 120
        rememberedAfter = try c.decodeIfPresent(Int.self, forKey: .rememberedAfter) ?? 120
        if let policy = try c.decodeIfPresent(ReminderFollowUp.self, forKey: .followUp) { followUp = policy }
        else {
            let legacy = try c.decodeIfPresent(Int.self, forKey: .after)
            followUp = .init(mode: legacy == nil ? .off : .always, delay: legacy ?? rememberedAfter)
        }
        self = validated
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(before, forKey: .before); try c.encode(atStart, forKey: .atStart)
        try c.encode(followUp, forKey: .followUp)
        try c.encode(rememberedBefore, forKey: .rememberedBefore); try c.encode(rememberedAfter, forKey: .rememberedAfter)
    }
    public var validated: Self {
        var value = self
        value.before = before.flatMap { (1...86400).contains($0) ? $0 : nil }
        value.followUp = followUp.validated
        value.rememberedBefore = min(86400, max(1, rememberedBefore))
        value.rememberedAfter = min(3600, max(1, rememberedAfter))
        return value
    }
}

public struct ReminderProfile: Codable, Equatable, Sendable {
    public var timing = ReminderTiming()
    public var sound = true
    public var details = true
    public var timeSensitive = false
    public init() {}
}

public struct ReminderOverride: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case defaults, custom, off }
    public var mode: Mode
    public var custom: ReminderTiming
    public var customized = false
    public init(mode: Mode = .defaults, custom: ReminderTiming = .init()) { self.mode = mode; self.custom = custom }
    public func timing(profile: ReminderProfile) -> ReminderTiming? {
        switch mode {
        case .off: return nil
        case .custom: return custom.validated
        case .defaults: return profile.timing.validated
        }
    }
}

/// Credentials stay in protected device storage, never notification identifiers or cloud preferences.
public struct ReminderOccurrence: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var reference: String
    public var eventID: String
    public var calendarID: String
    public var title: String
    public var start: Date
    public var end: Date
    public var tentative: Bool
    public var eligible = true
    public var invitation: URL
    public var engine: MeetingEngineKind
    public var room: MeetingRoomIdentity? { MeetingRoomIdentity(invitation, engine: engine) }
    public init?(meeting: CalendarMeeting, id: String = UUID().uuidString, reference: String = UUID().uuidString) {
        guard meeting.hasResolvedInvitation, !meeting.allDay, meeting.end > meeting.start,
              let invitation = meeting.invitation, let engine = meeting.engine else { return nil }
        self.id = id; self.reference = reference; eventID = meeting.id; calendarID = meeting.calendarID
        title = meeting.title; start = meeting.start; end = meeting.end; tentative = meeting.tentative
        self.invitation = invitation; self.engine = engine
    }
}

public struct ReminderOccurrenceState: Codable, Equatable, Sendable {
    public var override: ReminderOverride?
    public var attended = false
    public var remoteAccount: String?
    public var skipped = false
    public var snooze: Date?
    public var snoozeScope: ReminderDeliveryScope?
    public var presentation: ReminderForegroundEvent?
    public var consumed: Set<ReminderPhase> = []
    public init() {}
}

public enum ReminderPhase: String, Codable, CaseIterable, Sendable { case before, start, after, snooze }

public struct PlannedReminder: Codable, Equatable, Identifiable, Sendable {
    public static let namespace = "calendar-reminder."
    public let occurrenceID: String
    public let reference: String
    public let phase: ReminderPhase
    public let date: Date
    public var id: String { Self.namespace + occurrenceID + "." + phase.rawValue }
    public init(occurrence: ReminderOccurrence, phase: ReminderPhase, date: Date) {
        occurrenceID = occurrence.id; reference = occurrence.reference; self.phase = phase; self.date = date
    }
}

public enum CalendarReminderPlanner {
    /// Fair allocation: one earliest useful alert per occurrence, then extra phases.
    /// Past phases are never replayed on launch or after Focus delays.
    public static func plan(occurrences: [ReminderOccurrence], states: [String: ReminderOccurrenceState],
                            profile: ReminderProfile, now: Date, budget: Int = 56) -> [PlannedReminder] {
        let horizon = now.addingTimeInterval(7 * 86400)
        var first: [PlannedReminder] = [], rest: [PlannedReminder] = []
        for occurrence in occurrences where occurrence.eligible && occurrence.end > now && occurrence.room != nil {
            let state = states[occurrence.id] ?? .init()
            guard !state.attended, state.remoteAccount == nil, !state.skipped,
                  !occurrence.tentative || state.override?.mode == .custom,
                  let timing = (state.override ?? .init()).timing(profile: profile) else { continue }
            var dates: [(ReminderPhase, Date)] = []
            if let before = timing.before { dates.append((.before, occurrence.start.addingTimeInterval(-Double(before)))) }
            if timing.atStart { dates.append((.start, occurrence.start)) }
            if timing.followUp.mode == .always, let after = timing.after { dates.append((.after, occurrence.start.addingTimeInterval(Double(after)))) }
            dates = dates.filter { phase, date in
                !state.consumed.contains(phase) && (state.snooze.map { date > $0 } ?? true)
            }
            if state.snoozeScope != .anotherMeeting, let snooze = state.snooze { dates.append((.snooze, snooze)) }
            let requests = dates.filter { $0.1 > now && $0.1 < occurrence.end && $0.1 <= horizon }
                .map { PlannedReminder(occurrence: occurrence, phase: $0.0, date: $0.1) }.sorted(by: ordered)
            if let earliest = requests.first { first.append(earliest); rest.append(contentsOf: requests.dropFirst()) }
        }
        // Snoozes are explicit choices and receive reserved capacity before automatic phases.
        let snoozes = Array((first + rest).filter { $0.phase == .snooze }.sorted(by: ordered).prefix(max(0, budget)))
        let automatic = first.filter { $0.phase != .snooze }.sorted(by: ordered) + rest.filter { $0.phase != .snooze }.sorted(by: ordered)
        return (snoozes + automatic.prefix(min(48, max(0, budget - snoozes.count)))).sorted(by: ordered)
    }
    private static func ordered(_ lhs: PlannedReminder, _ rhs: PlannedReminder) -> Bool {
        (lhs.date, lhs.id) < (rhs.date, rhs.id)
    }
}
