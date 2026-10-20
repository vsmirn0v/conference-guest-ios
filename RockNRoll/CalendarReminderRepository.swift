import ConferenceCore
import Foundation

protocol ReminderStorage {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

struct ReminderFileStorage: ReminderStorage {
    private var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingReminders/state.json")
    }
    func read() throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }
    func write(_ data: Data) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        var saved = url; try saved.setResourceValues(resource)
    }
}

struct ReminderProfileEnvelope: Codable, Equatable {
    var schema = 2
    var value = ReminderProfile()
    var counter: Int64 = 0
    var device = UUID().uuidString
    func precedes(_ other: Self) -> Bool { (counter, device) < (other.counter, other.device) }
}

struct CalendarReminderRepository: Codable {
    var schema = 2
    var enabled = false
    var profile = ReminderProfileEnvelope()
    var occurrences: [ReminderOccurrence] = []
    var states: [String: ReminderOccurrenceState] = [:]
    var scheduled: [PlannedReminder] = []
    var account: String?
    var cloudGeneration: String?
    var profileAccount: String?
    var cloudAcknowledged: ReminderProfileEnvelope?
    var device = UUID().uuidString
    var pendingOpen: String?
    var pendingOpenDate: Date?

    mutating func update(_ meetings: [CalendarMeeting], at now: Date) {
        // Multiple calendar copies of the same exact room/interval share reminders.
        struct Copy: Hashable { let room: MeetingRoomIdentity; let start: Date; let end: Date }
        var seen: Set<Copy> = []
        let previous = occurrences
        occurrences = meetings.filter { $0.end.addingTimeInterval(86400) > now }.sorted { $0.id < $1.id }.compactMap { meeting in
            guard var incoming = ReminderOccurrence(meeting: meeting), let room = incoming.room,
                  seen.insert(Copy(room: room, start: incoming.start, end: incoming.end)).inserted else { return nil }
            if let old = previous.first(where: { $0.eventID == incoming.eventID }) ?? previous.first(where: {
                $0.room == incoming.room && $0.start == incoming.start && $0.end == incoming.end
            }) {
                // A separate interval is a new opportunity; metadata/password edits retain attendance.
                let moved = incoming.start >= old.end || incoming.end <= old.start
                if !moved {
                    let changed = incoming.room != old.room || incoming.start != old.start || incoming.end != old.end
                    incoming = ReminderOccurrence(meeting: meeting, id: old.id,
                        reference: changed ? UUID().uuidString : old.reference)!
                    if incoming.room != old.room { states[old.id] = nil }
                    else if incoming.start != old.start || incoming.end != old.end { states[old.id]?.consumed = [] }
                }
            }
            return incoming
        }
        // A transient resolver failure cancels alerts, but cannot erase a person's choices.
        let presentIDs = Set(meetings.map(\.id))
        for var old in previous where presentIDs.contains(old.eventID) && old.end.addingTimeInterval(86400) > now && !occurrences.contains(where: { $0.id == old.id }) {
            old.eligible = false; occurrences.append(old)
        }
        let retained = Set(occurrences.map(\.id))
        states = states.filter { retained.contains($0.key) }
        for request in scheduled where request.date <= now {
            if occurrences.contains(where: { $0.id == request.occurrenceID && $0.reference == request.reference }) {
                states[request.occurrenceID, default: .init()].consumed.insert(request.phase)
                if request.phase == .snooze, states[request.occurrenceID]?.snooze == request.date { states[request.occurrenceID]?.snooze = nil }
            }
        }
    }
    mutating func joined(room: MeetingRoomIdentity, eventID: String? = nil, at now: Date) {
        let matching = occurrences.filter { occurrence in occurrence.eligible && occurrence.room == room &&
            (eventID == nil ? occurrence.start <= now && occurrence.end > now : occurrence.eventID == eventID) }
        // Arbitrary room joins cannot distinguish two scheduled occurrences of the same room.
        guard eventID != nil || matching.count == 1 else { return }
        for occurrence in matching {
            states[occurrence.id, default: .init()].attended = true
            states[occurrence.id]?.snooze = nil
        }
    }
    mutating func observe(_ jams: [ActiveJam], account: String?, now: Date) {
        if self.account != account {
            for id in states.keys { states[id]?.remoteAccount = nil }
            self.account = account
        }
        guard let account else { return }
        for jam in jams where jam.isRecent(at: now) {
            guard let room = MeetingRoomIdentity(jam.invitation, engine: jam.engine) else { continue }
            let matching = occurrences.filter { $0.eligible && $0.room == room && $0.start <= jam.updatedAt && $0.end > jam.updatedAt }
            guard matching.count == 1 else { continue }
            for occurrence in matching {
                states[occurrence.id, default: .init()].remoteAccount = account
                states[occurrence.id]?.snooze = nil
            }
        }
    }
    mutating func setOverride(_ value: ReminderOverride, id: String) {
        states[id, default: .init()].override = value
        if value.mode != .off { states[id]?.skipped = false }
    }
    @discardableResult mutating func snooze(reference: String, now: Date, scope: ReminderDeliveryScope = .system) -> Bool {
        guard let occurrence = occurrences.first(where: { $0.reference == reference }),
              now.addingTimeInterval(120) < occurrence.end else { return false }
        let state = states[occurrence.id] ?? .init()
        guard !state.attended, state.remoteAccount == nil, !state.skipped else { return false }
        states[occurrence.id, default: .init()].snooze = now.addingTimeInterval(120)
        states[occurrence.id]?.snoozeScope = scope
        states[occurrence.id]?.presentation = nil
        return true
    }
    mutating func skip(reference: String) {
        guard let occurrence = occurrences.first(where: { $0.reference == reference }) else { return }
        states[occurrence.id, default: .init()].skipped = true; states[occurrence.id]?.snooze = nil
    }
}
