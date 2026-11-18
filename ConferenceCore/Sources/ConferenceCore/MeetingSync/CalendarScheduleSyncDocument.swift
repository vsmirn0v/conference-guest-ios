import Foundation

public struct CalendarScheduleSyncDocument: Codable, Equatable, Sendable {
    public static let pastHorizon: TimeInterval = 48 * 3600
    public static let futureHorizon: TimeInterval = 14 * 86_400
    public static let maxProjectedUpcoming = 250

    public let device: String
    public private(set) var counter: Int64 = 0
    public private(set) var occurrences: [String: SyncedCalendarOccurrence] = [:]

    public init(device: String = UUID().uuidString) {
        self.device = device
    }

    public mutating func nextVersion() -> SyncVersion {
        counter += 1
        return SyncVersion(counter: counter, device: device)
    }

    public mutating func updateLocalMeetings(
        _ localMeetings: [CalendarMeeting],
        bindings: [String: URL],
        suppressed: [String: Date],
        reminderStates: [String: (override: ReminderOverride?, skipped: Bool, snooze: Date?, snoozeScope: ReminderDeliveryScope?, attended: Bool)],
        now: Date = Date()
    ) {
        let lower = now.addingTimeInterval(-Self.pastHorizon)
        let upper = now.addingTimeInterval(Self.futureHorizon)
        let eligible = Array(
            localMeetings
                .filter { !$0.isRemoteSynced && $0.end >= lower && $0.start <= upper }
                .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
                .prefix(Self.maxProjectedUpcoming)
        )

        var seenKeys: Set<String> = []
        for meeting in eligible {
            let key = meeting.occurrenceSyncKey
            seenKeys.insert(key)
            let version = nextVersion()
            let existing = occurrences[key]
            var sources = existing?.sourceDevices ?? [:]
            sources[device] = now

            let boundURL = bindings[meeting.id] ?? bindings[meeting.seriesID]
            let reminder = reminderStates[key]
            let isSuppressed = suppressed[meeting.id] != nil || (reminder?.skipped ?? false)

            var attended = existing?.attendedDevices ?? []
            if reminder?.attended == true {
                attended.insert(device)
            }

            let updated = SyncedCalendarOccurrence(
                occurrenceKey: key,
                seriesKey: meeting.externalSeriesID ?? meeting.seriesID,
                title: meeting.title,
                calendarTitle: meeting.calendarTitle,
                start: meeting.start,
                end: meeting.end,
                allDay: meeting.allDay,
                tentative: meeting.tentative,
                links: meeting.links,
                invitation: boundURL ?? meeting.invitation,
                engine: meeting.engine,
                endpoint: MeetingRoomIdentity.normalizedEndpoint(meeting.endpoint),
                requiresChoice: meeting.requiresChoice,
                sourceDevices: sources,
                boundInvitation: boundURL.map { SyncValue($0, version: version) } ?? existing?.boundInvitation,
                reminderOverride: reminder?.override.map { SyncValue($0, version: version) } ?? existing?.reminderOverride,
                skipped: isSuppressed ? SyncValue(true, version: version) : existing?.skipped,
                snoozeUntil: reminder?.snooze.map { SyncValue($0, version: version) } ?? existing?.snoozeUntil,
                snoozeScope: reminder?.snoozeScope.map { SyncValue($0, version: version) } ?? existing?.snoozeScope,
                attendedDevices: attended,
                linkedSessionID: existing?.linkedSessionID,
                isDeleted: SyncValue(false, version: version),
                updatedAt: now
            )
            occurrences[key] = existing?.merging(updated) ?? updated
        }

        for (key, var occurrence) in occurrences where !seenKeys.contains(key) {
            if occurrence.sourceDevices.removeValue(forKey: device) != nil {
                if occurrence.sourceDevices.isEmpty {
                    occurrence.isDeleted = SyncValue(true, version: nextVersion())
                }
                occurrence.updatedAt = now
                occurrences[key] = occurrence
            }
        }
    }

    public mutating func setOccurrenceState(
        occurrenceKey: String,
        reminderOverride: ReminderOverride? = nil,
        skipped: Bool? = nil,
        snoozeUntil: Date?? = nil,
        snoozeScope: ReminderDeliveryScope?? = nil,
        attended: Bool? = nil,
        linkedSessionID: UUID? = nil,
        boundInvitation: URL? = nil,
        now: Date = Date()
    ) {
        guard var occurrence = occurrences[occurrenceKey] else { return }
        let version = nextVersion()
        if let reminderOverride {
            occurrence.reminderOverride = SyncValue(reminderOverride, version: version)
        }
        if let skipped {
            occurrence.skipped = SyncValue(skipped, version: version)
        }
        if let snoozeUntil {
            occurrence.snoozeUntil = SyncValue(snoozeUntil, version: version)
        }
        if let snoozeScope {
            occurrence.snoozeScope = SyncValue(snoozeScope, version: version)
        }
        if attended == true {
            occurrence.attendedDevices.insert(device)
        }
        if let linkedSessionID {
            occurrence.linkedSessionID = SyncValue(linkedSessionID, version: version)
        }
        if let boundInvitation {
            occurrence.boundInvitation = SyncValue(boundInvitation, version: version)
            occurrence.invitation = boundInvitation
        }
        occurrence.updatedAt = now
        occurrences[occurrenceKey] = occurrence
    }

    @discardableResult
    public mutating func merge(_ records: [MeetingScheduleSyncRecord]) -> Bool {
        var changed = false
        for record in records {
            counter = max(counter, record.maximumSyncCounter)
            switch record {
            case .occurrence(let incoming):
                let merged = occurrences[incoming.occurrenceKey]?.merging(incoming) ?? incoming
                if occurrences[incoming.occurrenceKey] != merged {
                    occurrences[incoming.occurrenceKey] = merged
                    changed = true
                }
            }
        }
        return changed
    }

    /// Removes expired calendar occurrences beyond the past horizon and returns their
    /// CloudKit record IDs for zone cleanup.
    public mutating func pruneExpired(now: Date = Date()) -> [String] {
        let cutoff = now.addingTimeInterval(-Self.pastHorizon)
        let expiredKeys = occurrences.values.filter { $0.end < cutoff }.map(\.occurrenceKey)
        for key in expiredKeys {
            occurrences.removeValue(forKey: key)
        }
        return expiredKeys.map { "cal:" + $0 }
    }

    public func projectedOccurrences(now: Date = Date()) -> [SyncedCalendarOccurrence] {
        let lower = now.addingTimeInterval(-Self.pastHorizon)
        let upper = now.addingTimeInterval(Self.futureHorizon)
        return occurrences.values
            .filter { !$0.isDeleted.value && !$0.sourceDevices.isEmpty && $0.end >= lower && $0.start <= upper }
            .sorted { ($0.start, $0.occurrenceKey) < ($1.start, $1.occurrenceKey) }
    }

    public var records: [MeetingScheduleSyncRecord] {
        occurrences.values.map { .occurrence($0) }
    }
}
