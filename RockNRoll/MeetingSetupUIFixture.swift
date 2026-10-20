#if DEBUG
import ConferenceCore
import Foundation

/// Isolated settings/permission states. No private calendars, CloudKit or live meetings.
@MainActor enum MeetingSetupUIFixture {
    final class Storage: RoomHistoryStorage, ReminderStorage {
        let preferences: UserDefaults
        let key: String
        init(_ preferences: UserDefaults, _ key: String) { self.preferences = preferences; self.key = "fixture." + key }
        func read() -> Data? { preferences.data(forKey: key) }
        func write(_ data: Data) { preferences.set(data, forKey: key) }
    }
    actor Reader: CalendarReading {
        private var granted = false
        let denied: Bool
        let onSelected: @MainActor @Sendable () -> Void
        init(denied: Bool, onSelected: @escaping @MainActor @Sendable () -> Void = {}) { self.denied = denied; self.onSelected = onSelected }
        func access() -> CalendarAccess { granted ? .allowed : denied ? .denied : .notDetermined }
        func requestAccess() -> Bool { granted = !denied; return granted }
        func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) async -> CalendarSnapshot {
            if selected.contains("work") { await onSelected() }
            return .init(calendars: [.init(id: "work", name: "Work", source: "Test account"),
                              .init(id: "personal", name: "Personal", source: "Test account")], meetings: [])
        }
    }
    final class Notifications: ReminderNotifying {
        private var granted = false
        let denied: Bool
        var requests = 0
        var onRequest: () -> Void = {}
        init(denied: Bool) { self.denied = denied }
        func authorization() -> ReminderAuthorization { granted ? .allowed : denied ? .denied : .notDetermined }
        func request(sensitive: Bool) -> Bool { requests += 1; granted = !denied; onRequest(); return granted }
        func pending() -> [String: String] { [:] }
        func add(_ reminder: ReminderNotification) {}
        func removePending(_ ids: [String]) {}
        func removeDelivered(occurrenceIDs: Set<String>) {}
        func removeAllDelivered() {}
    }
    private final class Cloud: RoomCloudTransport {
        func connect() throws -> RoomCloudSession { throw RoomCloudError.noAccount }
        func fetch(session: RoomCloudSession, after token: Data?) -> RoomCloudChanges { .init(records: [], token: nil) }
        func save(_ records: [RoomSyncRecord], session: RoomCloudSession) -> [RoomSyncRecord] { records }
        func clear(session: RoomCloudSession) {}
    }
    @MainActor private final class Actions {
        weak var model: ConferenceModel?
        var fired = false
        let mode: String
        init(_ mode: String) { self.mode = mode }
        func open() {
            guard !fired else { return }; fired = true
            if mode == "warm-website" { model?.receive(url: URL(string: "jcp://jazz?code=q01xx4&psw=fixture")!) }
            else { model?.calendar.reminders.onOpen(nil, false) }
        }
    }
    static func model(preferences: UserDefaults, denied: Bool = false, mode: String = "") -> ConferenceModel {
        let detector = MeetingEngineDetector(serviceName: "setup-fixture")
        let actions = Actions(mode), notifications = Notifications(denied: denied)
        if mode == "warm-reminder" || mode == "warm-website" {
            notifications.onRequest = { DispatchQueue.main.async { actions.open() } }
        }
        let reminders = CalendarReminderCoordinator(preferences: preferences, storage: Storage(preferences, "reminders"),
                                                     notifications: notifications)
        let calendar = CalendarMeetingStore(reader: Reader(denied: denied, onSelected: {
            if mode == "warm-reminder-chooser" { actions.open() }
        }), detector: detector, preferences: preferences,
            storage: Storage(preferences, "calendar"), reminders: reminders)
        let model = ConferenceModel(history: RoomHistoryStore(storage: Storage(preferences, "rooms")),
            preferences: preferences, engineDetector: detector, calendar: calendar)
        model.installSyncFixture(RoomSyncCoordinator(history: model.history, name: model.displayName, preferences: preferences,
            storage: Storage(preferences, "sync"), transport: Cloud()))
        model.installContinuationFixture(MeetingContinuationCoordinator(deviceID: model.sync.deviceID,
            deviceLabel: "Setup QA", preferences: preferences, automatic: false))
        actions.model = model
        return model
    }
    static func makeModel() -> ConferenceModel? {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["CONFERENCE_TEST_MEETING_SETUP"] else { return nil }
        let name = "MeetingSetupUIFixture." + (environment["CONFERENCE_TEST_SETUP_ID"] ?? "default")
        let preferences = UserDefaults(suiteName: name)!
        let model = model(preferences: preferences, denied: mode == "denied", mode: mode)
        if mode == "custom", preferences.object(forKey: "fixture.seeded") == nil {
            preferences.set(true, forKey: "fixture.seeded")
            model.calendar.setAutomaticJoin(true)
            var profile = ReminderProfile(); profile.timing.before = 90; profile.timing.atStart = true
            profile.timing.followUp.mode = .always; profile.sound = false
            model.calendar.reminders.setProfile(profile)
        }
        if mode == "invitation" { model.receive(url: URL(string: "https://salutejazz.ru/calls/setup?psw=fixture")!) }
        if mode == "same-turn-website" {
            model.setup.begin()
            model.receive(url: URL(string: "jcp://jazz?code=q01xx4&psw=fixture")!)
        }
        return model
    }
}
#endif
