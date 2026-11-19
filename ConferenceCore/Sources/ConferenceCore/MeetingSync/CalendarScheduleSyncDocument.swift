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
            let fp = meeting.semanticFingerprint
            let localKey = meeting.occurrenceSyncKey
            var candidates = occurrences.values
                .filter { !$0.isDeleted.value && $0.semanticFingerprint.matches(fp) }
                .map(\.occurrenceKey)
            if !candidates.contains(localKey) {
                candidates.append(localKey)
            }
            let key = candidates.min() ?? localKey
            seenKeys.insert(key)

            let rawExisting = occurrences[key]
            var existing = rawExisting
            var migratedDuplicate = false
            for dupKey in candidates where dupKey != key {
                if let dup = occurrences[dupKey], !dup.isDeleted.value {
                    existing = existing?.coalescingSemanticDuplicate(dup) ?? dup
                    migratedDuplicate = true
                }
            }
            if existing == rawExisting {
                // Keep exact uncoalesced record reference unless a distinct duplicate contributed new info
                migratedDuplicate = false
            }

            let boundURL = bindings[meeting.id] ?? bindings[meeting.seriesID]
            let reminder = reminderStates[localKey]
            let isSuppressed = suppressed[meeting.id] != nil || (reminder?.skipped ?? false)

            let localInvitation = boundURL ?? meeting.invitation
            let localEndpoint = MeetingRoomIdentity.normalizedEndpoint(meeting.endpoint)
            let hasOtherDevice = existing?.sourceDevices.keys.contains(where: { $0 != device }) ?? false

            let resolvedSeriesKey: String
            let resolvedTitle: String
            let resolvedCalendarTitle: String
            let resolvedStart: Date
            let resolvedEnd: Date
            let resolvedAllDay: Bool
            let resolvedTentative: Bool
            let resolvedLinks: [URL]
            let resolvedInvitation: URL?
            let resolvedEngine: MeetingEngineKind?
            let resolvedEndpoint: String?
            let resolvedRequiresChoice: Bool
            var metadataChanged = false

            if let existing, hasOtherDevice {
                resolvedSeriesKey = existing.seriesKey
                resolvedCalendarTitle = existing.calendarTitle.isEmpty ? meeting.calendarTitle : existing.calendarTitle

                let titleChanged = meeting.title != existing.title
                let timingChanged = existing.allDay != meeting.allDay
                    || existing.tentative != meeting.tentative
                    || abs(meeting.start.timeIntervalSince(existing.start)) >= 1
                    || abs(meeting.end.timeIntervalSince(existing.end)) >= 1
                resolvedTitle = meeting.title
                resolvedStart = timingChanged ? meeting.start : existing.start
                resolvedEnd = timingChanged ? meeting.end : existing.end
                resolvedAllDay = meeting.allDay
                resolvedTentative = meeting.tentative

                var mergedLinks = existing.links
                var seenLinks = Set(existing.links)
                for url in meeting.links where seenLinks.insert(url).inserted {
                    mergedLinks.append(url)
                }
                resolvedLinks = mergedLinks

                let existingResolved = existing.invitation != nil && existing.engine != nil && !existing.requiresChoice
                let localResolved = localInvitation != nil && meeting.engine != nil && !meeting.requiresChoice
                if boundURL != nil || (!existingResolved && localResolved) || (existing.invitation == nil && localInvitation != nil) {
                    resolvedInvitation = localInvitation ?? existing.invitation
                    resolvedEngine = meeting.engine ?? existing.engine
                    resolvedEndpoint = localEndpoint ?? existing.endpoint
                    resolvedRequiresChoice = (boundURL != nil || localResolved) ? false : meeting.requiresChoice
                } else {
                    resolvedInvitation = existing.invitation
                    resolvedEngine = existing.engine
                    resolvedEndpoint = existing.endpoint ?? localEndpoint
                    resolvedRequiresChoice = existing.requiresChoice
                }

                metadataChanged = titleChanged
                    || timingChanged
                    || resolvedCalendarTitle != existing.calendarTitle
                    || resolvedLinks != existing.links
                    || resolvedInvitation != existing.invitation
                    || resolvedEngine != existing.engine
                    || resolvedEndpoint != existing.endpoint
                    || resolvedRequiresChoice != existing.requiresChoice
            } else {
                resolvedSeriesKey = existing?.seriesKey ?? (meeting.externalSeriesID ?? meeting.seriesID)
                resolvedTitle = meeting.title
                resolvedCalendarTitle = meeting.calendarTitle
                resolvedStart = meeting.start
                resolvedEnd = meeting.end
                resolvedAllDay = meeting.allDay
                resolvedTentative = meeting.tentative
                resolvedLinks = meeting.links
                resolvedInvitation = localInvitation
                resolvedEngine = meeting.engine
                resolvedEndpoint = localEndpoint
                resolvedRequiresChoice = meeting.requiresChoice

                if let existing {
                    metadataChanged = resolvedTitle != existing.title
                        || resolvedCalendarTitle != existing.calendarTitle
                        || abs(resolvedStart.timeIntervalSince(existing.start)) >= 1
                        || abs(resolvedEnd.timeIntervalSince(existing.end)) >= 1
                        || resolvedAllDay != existing.allDay
                        || resolvedTentative != existing.tentative
                        || resolvedLinks != existing.links
                        || resolvedInvitation != existing.invitation
                        || resolvedEngine != existing.engine
                        || resolvedEndpoint != existing.endpoint
                        || resolvedRequiresChoice != existing.requiresChoice
                } else {
                    metadataChanged = true
                }
            }

            var crdtChanged = false
            let nextBoundInvitation: SyncValue<URL?>?
            if let boundURL {
                let res = reusingSyncValue(Optional(boundURL), existing: existing?.boundInvitation)
                nextBoundInvitation = res.value
                crdtChanged = crdtChanged || res.changed
            } else {
                nextBoundInvitation = existing?.boundInvitation
            }

            let nextReminderOverride: SyncValue<ReminderOverride?>?
            if let override = reminder?.override {
                let res = reusingSyncValue(Optional(override), existing: existing?.reminderOverride)
                nextReminderOverride = res.value
                crdtChanged = crdtChanged || res.changed
            } else {
                nextReminderOverride = existing?.reminderOverride
            }

            let nextSkipped: SyncValue<Bool>?
            if isSuppressed {
                let res = reusingSyncValue(true, existing: existing?.skipped)
                nextSkipped = res.value
                crdtChanged = crdtChanged || res.changed
            } else {
                nextSkipped = existing?.skipped
            }

            let nextSnoozeUntil: SyncValue<Date?>?
            if let snooze = reminder?.snooze {
                let res = reusingSyncValue(Optional(snooze), existing: existing?.snoozeUntil)
                nextSnoozeUntil = res.value
                crdtChanged = crdtChanged || res.changed
            } else {
                nextSnoozeUntil = existing?.snoozeUntil
            }

            let nextSnoozeScope: SyncValue<ReminderDeliveryScope?>?
            if let scope = reminder?.snoozeScope {
                let res = reusingSyncValue(Optional(scope), existing: existing?.snoozeScope)
                nextSnoozeScope = res.value
                crdtChanged = crdtChanged || res.changed
            } else {
                nextSnoozeScope = existing?.snoozeScope
            }

            let deletedRes = reusingSyncValue(false, existing: existing?.isDeleted)
            crdtChanged = crdtChanged || deletedRes.changed

            var attended = existing?.attendedDevices ?? []
            var attendedChanged = false
            if reminder?.attended == true && !attended.contains(device) {
                attended.insert(device)
                attendedChanged = true
            }

            let missingLocalSource = existing?.sourceDevices[device] == nil
            let shouldWrite = existing == nil
                || migratedDuplicate
                || missingLocalSource
                || metadataChanged
                || crdtChanged
                || attendedChanged

            guard shouldWrite else { continue }

            var sources = existing?.sourceDevices ?? [:]
            sources[device] = now

            let updated = SyncedCalendarOccurrence(
                occurrenceKey: key,
                seriesKey: resolvedSeriesKey,
                title: resolvedTitle,
                calendarTitle: resolvedCalendarTitle,
                start: resolvedStart,
                end: resolvedEnd,
                allDay: resolvedAllDay,
                tentative: resolvedTentative,
                links: resolvedLinks,
                invitation: resolvedInvitation,
                engine: resolvedEngine,
                endpoint: resolvedEndpoint,
                requiresChoice: resolvedRequiresChoice,
                sourceDevices: sources,
                boundInvitation: nextBoundInvitation,
                reminderOverride: nextReminderOverride,
                skipped: nextSkipped,
                snoozeUntil: nextSnoozeUntil,
                snoozeScope: nextSnoozeScope,
                attendedDevices: attended,
                linkedSessionID: existing?.linkedSessionID,
                isDeleted: deletedRes.value,
                updatedAt: now
            )
            occurrences[key] = updated
        }

        for (key, var occurrence) in occurrences where !seenKeys.contains(key) && !occurrence.isDeleted.value {
            if occurrence.sourceDevices.removeValue(forKey: device) != nil {
                if occurrence.sourceDevices.isEmpty {
                    let deletedRes = reusingSyncValue(true, existing: occurrence.isDeleted)
                    occurrence.isDeleted = deletedRes.value
                }
                occurrence.updatedAt = now
                occurrences[key] = occurrence
            }
        }
    }

    private mutating func reusingSyncValue<V: Equatable>(
        _ newValue: V,
        existing: SyncValue<V>?
    ) -> (value: SyncValue<V>, changed: Bool) {
        if let existing, existing.value == newValue {
            return (existing, false)
        }
        return (SyncValue(newValue, version: nextVersion()), true)
    }

    public mutating func setOccurrenceState(
        occurrenceKey: String,
        matchingFingerprint: CalendarOccurrenceSemanticFingerprint? = nil,
        reminderOverride: ReminderOverride? = nil,
        skipped: Bool? = nil,
        snoozeUntil: Date?? = nil,
        snoozeScope: ReminderDeliveryScope?? = nil,
        attended: Bool? = nil,
        linkedSessionID: UUID? = nil,
        boundInvitation: URL? = nil,
        now: Date = Date()
    ) {
        let targetKey: String?
        if let direct = occurrences[occurrenceKey], !direct.isDeleted.value {
            targetKey = occurrenceKey
        } else if let matchingFingerprint {
            targetKey = occurrences.values
                .filter { !$0.isDeleted.value && $0.semanticFingerprint.matches(matchingFingerprint) }
                .min(by: { $0.occurrenceKey < $1.occurrenceKey })?
                .occurrenceKey ?? (occurrences[occurrenceKey] != nil ? occurrenceKey : nil)
        } else {
            targetKey = occurrences[occurrenceKey] != nil ? occurrenceKey : nil
        }
        guard let targetKey, var occurrence = occurrences[targetKey] else { return }

        var changed = false
        if let reminderOverride {
            let res = reusingSyncValue(Optional(reminderOverride), existing: occurrence.reminderOverride)
            occurrence.reminderOverride = res.value
            changed = changed || res.changed
        }
        if let skipped {
            let res = reusingSyncValue(skipped, existing: occurrence.skipped)
            occurrence.skipped = res.value
            changed = changed || res.changed
        }
        if let snoozeUntil {
            let res = reusingSyncValue(snoozeUntil, existing: occurrence.snoozeUntil)
            occurrence.snoozeUntil = res.value
            changed = changed || res.changed
        }
        if let snoozeScope {
            let res = reusingSyncValue(snoozeScope, existing: occurrence.snoozeScope)
            occurrence.snoozeScope = res.value
            changed = changed || res.changed
        }
        if attended == true && !occurrence.attendedDevices.contains(device) {
            occurrence.attendedDevices.insert(device)
            changed = true
        }
        if let linkedSessionID {
            let res = reusingSyncValue(Optional(linkedSessionID), existing: occurrence.linkedSessionID)
            occurrence.linkedSessionID = res.value
            changed = changed || res.changed
        }
        if let boundInvitation {
            let res = reusingSyncValue(Optional(boundInvitation), existing: occurrence.boundInvitation)
            occurrence.boundInvitation = res.value
            if occurrence.invitation != boundInvitation {
                occurrence.invitation = boundInvitation
                changed = true
            }
            changed = changed || res.changed
        }
        guard changed else { return }
        occurrence.updatedAt = now
        occurrences[targetKey] = occurrence
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
        let active = occurrences.values
            .filter { !$0.isDeleted.value && !$0.sourceDevices.isEmpty && $0.end >= lower && $0.start <= upper }
            .sorted { ($0.start, $0.occurrenceKey) < ($1.start, $1.occurrenceKey) }
        var result: [SyncedCalendarOccurrence] = []
        var fingerprints: [CalendarOccurrenceSemanticFingerprint] = []
        for occ in active {
            let fp = occ.semanticFingerprint
            if let index = fingerprints.firstIndex(where: { $0.matches(fp) }) {
                result[index] = result[index].coalescingSemanticDuplicate(occ)
                fingerprints[index] = result[index].semanticFingerprint
            } else {
                result.append(occ)
                fingerprints.append(fp)
            }
        }
        return result
    }

    public var records: [MeetingScheduleSyncRecord] {
        occurrences.values.map { .occurrence($0) }
    }
}
