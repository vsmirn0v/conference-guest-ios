import AppKit
import ConferenceCore
import Foundation

private enum LibraryTestError: Error { case assertion(String) }
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw LibraryTestError.assertion(message) }
}

private final class Storage: RoomHistoryStorage, ReminderStorage {
    var data: Data?
    var failing = false
    func read() -> Data? { data }
    func write(_ data: Data) throws {
        if failing { throw CocoaError(.fileWriteNoPermission) }
        self.data = data
    }
}
@MainActor private final class Notifications: ReminderNotifying {
    func authorization() async -> ReminderAuthorization { .notDetermined }
    func request(sensitive: Bool) async throws -> Bool { false }
    func pending() async -> [String: String] { [:] }
    func add(_ reminder: ReminderNotification) async throws {}
    func removePending(_ ids: [String]) {}
    func removeDelivered(occurrenceIDs: Set<String>) async {}
    func removeAllDelivered() async {}
}
private actor Reader: CalendarReading {
    var permission = CalendarAccess.notDetermined
    var requests = 0
    let events: [CalendarMeeting]
    init(events: [CalendarMeeting] = []) { self.events = events }
    func access() -> CalendarAccess { permission }
    func requestAccess() -> Bool { requests += 1; permission = .allowed; return true }
    func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) -> CalendarSnapshot {
        .init(calendars: [.init(id: "work", name: "Work", source: "Fixture")], meetings: events)
    }
    func requestCount() -> Int { requests }
    func deny() { permission = .denied }
}
private final class Response: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let supported = request.url?.host != "unsupported.example.test" && request.url?.path == "/.well-known/s2b-services.json"
        let data = Data("{\"fixture\":{\"serverUrl\":\"https://backend.example.test\"}}".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: supported ? 200 : 404,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor private final class Cloud: RoomCloudTransport {
    var records: [String: RoomSyncRecord] = [:]
    var account = "fixture-account"
    func connect() async throws -> RoomCloudSession { .init(account: account, generation: "fixture-generation") }
    func fetch(session: RoomCloudSession, after token: Data?) async throws -> RoomCloudChanges {
        .init(records: Array(records.values), token: Data([1]))
    }
    func save(_ values: [RoomSyncRecord], session: RoomCloudSession) async throws -> [RoomSyncRecord] {
        values.map { value in
            let merged = records[value.id].map { value.merging($0) } ?? value
            records[value.id] = merged; return merged
        }
    }
    func clear(session: RoomCloudSession) async throws { records = [:] }
}

@main private struct NativeDesktopLibraryTests {
    @MainActor private static func calendar(preferences: UserDefaults, reader: Reader = Reader(), clock: @escaping () -> Date = Date.init) -> CalendarMeetingStore {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Response.self]
        let reminders = CalendarReminderCoordinator(preferences: preferences, storage: Storage(), notifications: Notifications())
        return CalendarMeetingStore(reader: reader,
            detector: MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: config)),
            preferences: preferences, storage: Storage(), reminders: reminders, isMac: true, clock: clock)
    }
    @MainActor static func persistence() throws {
        let domain = "NativeDesktopLibraryTests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let storage = Storage(), syncStorage = Storage()
        let library = NativeDesktopLibrary(preferences: preferences, history: RoomHistoryStore(storage: storage),
            syncStorage: syncStorage, cloudTransport: Cloud(), calendar: calendar(preferences: preferences))
        library.displayName = "Local guest"
        let first = try library.createFavorite(invitation: "https://meeting.example.test/calls/first?psw=old", title: "First")
        let second = try library.createFavorite(invitation: "https://meeting.example.test/calls/second?psw=fixture", title: "Second")
        try expect(library.recent.isEmpty && library.favorites.count == 2, "Saving favorites must not invent visits")
        library.moveFavorites(from: IndexSet(integer: 1), to: 0)
        try expect(library.favorites.map(\.id) == [first.id, second.id], "Native reorder preserves shared favorite positions")
        library.rename(first, to: "Our rehearsal")
        let rotated = URL(string: "https://meeting.example.test/first?psw=new")!
        library.recordJoin(invitation: rotated, title: "Server title", identifier: "first", engine: .guest)
        try expect(library.history.rooms.count == 2 && library.recent.count == 1, "A successful token refresh retains room identity")
        try expect(library.recent[0].joinURL == rotated && library.recent[0].displayTitle == "Our rehearsal", "Join URL rotates without replacing a personal alias")
        var opened: URL?
        library.onOpenMeeting = { url, _, _, _ in opened = url }
        library.open(library.recent[0])
        try expect(opened == rotated, "Native admission receives the latest invitation")
        library.delete(second); try expect(library.favorites.count == 1, "Delete updates the shared collection")
        library.undoDelete(); try expect(library.favorites.count == 2, "Undo restores a saved-only favorite")
        storage.failing = true; library.rename(first, to: "Retry title")
        try expect(library.persistenceWarning != nil, "Persistence errors remain visible")
        storage.failing = false; library.retryPersistence()
        let restored = NativeDesktopLibrary(preferences: preferences, history: RoomHistoryStore(storage: storage),
            syncStorage: syncStorage, cloudTransport: Cloud(), calendar: calendar(preferences: preferences))
        try expect(restored.history.rooms == library.history.rooms && restored.displayName == "Local guest", "Restart restores the original shared formats")
        let native = try library.normalizedDestination("jazz://join?id=first&password=new&host=meeting.example.test")
        try expect(native.invitationURL == URL(string: "https://meeting.example.test/calls/first?psw=new")!, "Formal native links use the shared adapter")
    }

    @MainActor static func replicaCompatibility() async throws {
        let cloud = Cloud(), mac = RoomHistoryStore(storage: Storage()), phone = RoomHistoryStore(storage: Storage())
        let macDomain = "NativeReplicaMac-" + UUID().uuidString, phoneDomain = "NativeReplicaPhone-" + UUID().uuidString
        let macPreferences = UserDefaults(suiteName: macDomain)!, phonePreferences = UserDefaults(suiteName: phoneDomain)!
        defer { macPreferences.removePersistentDomain(forName: macDomain); phonePreferences.removePersistentDomain(forName: phoneDomain) }
        let macSync = RoomSyncCoordinator(history: mac, name: "Mac guest", preferences: macPreferences, storage: Storage(), transport: cloud)
        let phoneSync = RoomSyncCoordinator(history: phone, name: "", preferences: phonePreferences, storage: Storage(), transport: cloud)
        macSync.setEnabled(true); phoneSync.setEnabled(true)
        mac.saveFavorite(url: URL(string: "https://meeting.example.test/calls/team?psw=fixture")!, title: "Team", engine: .guest)
        await macSync.synchronizeForNotification(); await phoneSync.synchronizeForNotification()
        try expect(mac.rooms == phone.rooms && phone.rooms.first?.lastVisit == nil, "Native and existing replicas exchange saved-only favorites with the same algorithm")
        phone.setAlias("Remote alias", for: phone.rooms[0].invitationURL)
        await phoneSync.synchronizeForNotification(); await macSync.synchronizeForNotification()
        try expect(mac.rooms[0].alias == "Remote alias", "Independent client edits merge into the native collection")
        let previous = mac.rooms
        cloud.account = "another-account"
        await macSync.synchronizeForNotification()
        try expect(macSync.needsFreshAccount && mac.rooms == previous, "Account changes retain local history and require explicit fresh-account consent")
        macSync.setEnabled(false); phoneSync.setEnabled(false)
    }

    @MainActor static func permissionsAndResolvedAgenda() async throws {
        let domain = "NativeAgenda-" + UUID().uuidString, preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let now = Date()
        func event(_ id: String, start: Double, host: String = "meeting.example.test", links: [URL]? = nil) -> CalendarMeeting {
            .init(id: id, seriesID: id, calendarID: "work", calendarTitle: "Work", title: id,
                start: now.addingTimeInterval(start), end: now.addingTimeInterval(3600),
                links: links ?? [URL(string: "https://\(host)/calls/\(id)?psw=fixture")!])
        }
        let ambiguous = [URL(string: "https://meeting.example.test/calls/one")!, URL(string: "https://meeting.example.test/calls/two")!]
        let reader = Reader(events: [event("future", start: 120), event("ongoing", start: -120),
            event("unsupported", start: 30, host: "unsupported.example.test"), event("ambiguous", start: 20, links: ambiguous)])
        let store = calendar(preferences: preferences, reader: reader)
        let library = NativeDesktopLibrary(preferences: preferences, history: RoomHistoryStore(storage: Storage()),
            syncStorage: Storage(), cloudTransport: Cloud(), calendar: store)
        library.foregrounded()
        let initialRequests = await reader.requestCount()
        try expect(initialRequests == 0 && !store.enabled, "Launching the native library never prompts for Calendar access")
        store.setEnabled(true)
        try await ready(store)
        let enabledRequests = await reader.requestCount()
        try expect(enabledRequests == 1 && store.access == .allowed && store.selected.isEmpty, "Explicit opt-in requests access without widening calendar selection")
        store.select("work", included: true); try await ready(store)
        try expect(library.calendarMeetings.map(\.id) == ["ongoing", "future"], "Resolved ongoing events precede upcoming; unsupported and ambiguous rooms stay out of join rows")
        var opened: [String] = []
        var openedInvitation: URL?, openedEngine: MeetingEngineKind?
        library.onOpenMeeting = { url, engine, _, id in
            openedInvitation = url; openedEngine = engine
            if let id { opened.append(id) }
        }
        let current = library.calendarMeetings[0]
        let favorite = try library.createFavorite(invitation: "https://meeting.example.test/calls/ongoing?psw=expired", title: "Saved ongoing")
        library.open(favorite)
        try expect(openedInvitation == current.invitation && openedEngine == current.engine,
            "Rejoining a saved room uses the calendar's current invitation and verified engine")
        try expect(!store.automaticJoinSuppressed(current), "Opening a saved room alone does not invent attendance")
        library.recordJoin(invitation: current.invitation!, title: current.title, identifier: "ongoing", engine: current.engine!)
        try expect(store.automaticJoinSuppressed(current), "A confirmed manual join suppresses automatic joining for the matching scheduled occurrence")
        library.open(library.calendarMeetings[0])
        try expect(opened == ["ongoing"], "Agenda actions retain exact occurrence identity")
        let old = library.calendarMeetings[0]
        await reader.deny(); store.refresh(); try await ready(store)
        library.open(old)
        try expect(library.calendarMeetings.isEmpty && opened.count == 1, "Permission revocation clears rows and blocks stale calendar actions")
        library.backgrounded()
    }
    @MainActor private static func ready(_ store: CalendarMeetingStore) async throws {
        let deadline = Date().addingTimeInterval(4)
        while store.loading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try expect(!store.loading, "Calendar fixture refresh completed")
    }
    @MainActor static func scheduledAdmission() async throws {
        let domain = "NativeScheduledAdmission-" + UUID().uuidString, preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let initial = Date(); var now = initial
        let event = CalendarMeeting(id: "scheduled", seriesID: "scheduled", calendarID: "work", calendarTitle: "Work", title: "Scheduled",
            start: initial.addingTimeInterval(1), end: initial.addingTimeInterval(3600),
            links: [URL(string: "https://meeting.example.test/calls/scheduled")!])
        let reader = Reader(events: [event]), store = calendar(preferences: preferences, reader: reader, clock: { now })
        let library = NativeDesktopLibrary(preferences: preferences, history: RoomHistoryStore(storage: Storage()),
            syncStorage: Storage(), cloudTransport: Cloud(), calendar: store)
        library.setup.finishLaunch(hasMeetingIntent: true); library.displayName = "Scheduled guest"
        store.setEnabled(true); try await ready(store)
        store.select("work", included: true); try await ready(store)
        store.setAutomaticJoinMode(.scheduled); store.setSchedulingAvailable(true); try await ready(store)
        now = initial.addingTimeInterval(2)
        guard let current = store.meetings.first else { throw LibraryTestError.assertion("Resolved scheduled fixture exists") }
        var requests: [NativeDesktopScheduledJoin] = [], invalidations = 0, ordinaryOpens = 0
        library.onScheduledMeeting = { requests.append($0) }
        library.onScheduledInvalidation = { invalidations += 1 }
        library.onOpenMeeting = { _, _, _, _ in ordinaryOpens += 1 }
        store.onScheduledJoin(current)
        try expect(requests.count == 1 && requests[0].admission(), "Scheduled callback carries a valid transport admission")
        try expect(ordinaryOpens == 0, "Scheduled joins do not use manual suppression/opening")
        store.onScheduledJoin(current)
        try expect(requests.count == 2 && !requests[0].admission() && requests[1].admission(), "Replacement retires only the old scheduled token")
        requests[0].finish()
        try expect(requests[1].admission(), "An old completion cannot finish the newer request")
        store.setScheduledUIBlocked(true)
        try expect(!requests[1].admission() && invalidations == 2, "Editing cancels pending native scheduled transport")
        store.setScheduledUIBlocked(false); store.onScheduledJoin(current)
        try expect(requests.count == 3 && requests[2].admission(), "A fresh request can be admitted after editing")
        store.pauseScheduledJoiningToday()
        try expect(!requests[2].admission() && invalidations == 3, "Pause during async resolution revokes admission and notifies native owner")
        requests[2].finish(); requests[2].finish()
        try expect(invalidations == 3, "Finish is idempotent after invalidation")
        library.backgrounded(); store.setSchedulingAvailable(false)
    }
    @MainActor static func handoffReference() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let jam = ActiveJam(deviceID: UUID().uuidString,
            invitation: URL(string: "https://meeting.example.test/calls/private?psw=secret")!,
            title: "Private title", name: "Private name", deviceLabel: "Private Mac")
        let activity = NativeDesktopHandoff.activity(for: jam, now: now)
        try expect(NativeDesktopHandoff.reference(in: activity) == .init(deviceID: jam.deviceID, sessionID: jam.sessionID),
            "Native Handoff resolves the exact source session")
        try expect(Set(activity.userInfo?.keys.compactMap { $0 as? String } ?? []) == ["device", "session"],
            "Only opaque lookup keys enter Handoff")
        try expect(activity.webpageURL == nil && activity.title != jam.title && activity.title != jam.name,
            "Handoff does not disclose invitation, personal title or name")
        try expect(activity.isEligibleForHandoff && !activity.isEligibleForSearch && !activity.isEligibleForPublicIndexing,
            "A private continuation cannot enter search or public indexing")
        try expect(activity.requiredUserInfoKeys == ["device", "session"] && activity.expirationDate == now.addingTimeInterval(180),
            "The reference requires both keys and expires with its advertised lease")
        let unrelated = NSUserActivity(activityType: "example.other")
        unrelated.userInfo = activity.userInfo
        try expect(NativeDesktopHandoff.reference(in: unrelated) == nil, "Unrelated activities cannot route a meeting")
        for information: [String: Any] in [["device": jam.deviceID], ["device": "", "session": jam.sessionID.uuidString],
            ["device": jam.deviceID, "session": "malformed"], ["device": jam.deviceID, "session": 3]] {
            activity.userInfo = information
            try expect(NativeDesktopHandoff.reference(in: activity) == nil, "Incomplete or malformed activity cannot route a meeting")
        }
    }
    @MainActor static func main() async {
        do {
            _ = NSApplication.shared
            try persistence()
            try await replicaCompatibility()
            try await permissionsAndResolvedAgenda()
            try await scheduledAdmission()
            try handoffReference()
            print("PASS: native library persistence, favorite order, aliases, rotated/calendar invitations, scheduled attendance, shared replica/account compatibility, Calendar opt-in, resolved agenda, scheduled transport admission/cancellation and private Handoff activity contract")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
