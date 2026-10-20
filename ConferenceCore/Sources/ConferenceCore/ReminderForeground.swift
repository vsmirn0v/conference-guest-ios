import Foundation

public enum ReminderDeliveryScope: String, Codable, Sendable { case system, anotherMeeting }

/// A presentation identity is independent of view/controller lifetime.
public struct ReminderForegroundEvent: Codable, Equatable, Identifiable, Sendable {
    public let plan: PlannedReminder
    public let scope: ReminderDeliveryScope
    public var id: String { plan.id + "." + plan.reference + "." + String(plan.date.timeIntervalSince1970) }
    public init(plan: PlannedReminder, scope: ReminderDeliveryScope) { self.plan = plan; self.scope = scope }
}

public struct ReminderScene: Equatable, Sendable {
    public var visible: Bool
    public var room: MeetingRoomIdentity?
    public var usable: Bool
    public init(visible: Bool = false, room: MeetingRoomIdentity? = nil, usable: Bool = true) {
        self.visible = visible; self.room = room; self.usable = usable
    }
}

public struct ReminderForegroundDecision: Equatable, Sendable {
    public var events: [ReminderForegroundEvent] = []
    public var invalidatedIDs: Set<String> = []
    public var nextDeadline: Date?
}

public enum ReminderForegroundPlanner {
    /// No polling, media state mutation, or replay of past native notifications.
    public static func decide(occurrences: [ReminderOccurrence], states: [String: ReminderOccurrenceState],
                              profile: ReminderProfile, enabled: Bool, scene: ReminderScene, now: Date) -> ReminderForegroundDecision {
        var result = ReminderForegroundDecision()
        func deadline(_ date: Date) {
            if date > now { result.nextDeadline = min(result.nextDeadline ?? date, date) }
        }
        for occurrence in occurrences {
            let state = states[occurrence.id] ?? .init()
            guard occurrence.eligible, occurrence.end > now, let room = occurrence.room,
                  !state.attended, state.remoteAccount == nil, !state.skipped,
                  !occurrence.tentative || state.override?.mode == .custom,
                  let timing = (state.override ?? .init()).timing(profile: profile) else {
                result.invalidatedIDs.insert(occurrence.id); continue
            }
            guard enabled else { continue }
            deadline(occurrence.end)
            var event: ReminderForegroundEvent?
            if let saved = state.presentation, saved.plan.reference == occurrence.reference {
                let allowed: Bool
                switch saved.plan.phase {
                case .before: allowed = timing.before != nil
                case .start: allowed = timing.atStart
                case .after: allowed = timing.followUp.mode != .off
                case .snooze: allowed = saved.scope == .system || timing.followUp.mode == .anotherMeeting
                }
                if allowed { event = saved }
            }
            if timing.followUp.mode == .anotherMeeting &&
                (!state.consumed.contains(.after) || state.presentation?.plan.phase == .after) {
                let date = occurrence.start.addingTimeInterval(Double(timing.followUp.delay))
                if date <= now, state.snooze == nil, let current = scene.room, current != room {
                    event = .init(plan: .init(occurrence: occurrence, phase: .after, date: date), scope: .anotherMeeting)
                } else { deadline(date) }
            }
            if let snooze = state.snooze {
                if event?.scope != .system || event?.plan.phase != .snooze || event?.plan.date != snooze || snooze > now {
                    event = nil
                }
                if state.snoozeScope == .anotherMeeting {
                    if snooze <= now {
                        event = .init(plan: .init(occurrence: occurrence, phase: .snooze, date: snooze), scope: .anotherMeeting)
                    } else { deadline(snooze) }
                }
            }
            guard let event, scene.room != room else { continue }
            if event.scope == .anotherMeeting {
                guard timing.followUp.mode == .anotherMeeting, let current = scene.room, current != room else { continue }
            }
            if scene.visible && scene.usable { result.events.append(event) }
        }
        let starts = Dictionary(uniqueKeysWithValues: occurrences.map { ($0.id, $0.start) })
        result.events.sort {
            (starts[$0.plan.occurrenceID] ?? $0.plan.date, $0.plan.occurrenceID) <
            (starts[$1.plan.occurrenceID] ?? $1.plan.date, $1.plan.occurrenceID)
        }
        if !scene.visible { result.nextDeadline = nil }
        return result
    }
}
