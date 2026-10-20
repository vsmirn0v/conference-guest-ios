#if DEBUG
import ConferenceCore
import Foundation

enum CalendarUIFixture {
    final class Storage: RoomHistoryStorage, ReminderStorage {
        var data: Data?
        func read() -> Data? { data }
        func write(_ data: Data) { self.data = data }
    }
    actor Reader: CalendarReading {
        private let start = Date()
        func access() -> CalendarAccess { .allowed }
        func requestAccess() -> Bool { true }
        func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) async -> CalendarSnapshot {
            if let delay = Double(ProcessInfo.processInfo.environment["CONFERENCE_TEST_CALENDAR_DELAY"] ?? ""), delay > 0 {
                try? await Task.sleep(for: .seconds(min(delay, 10)))
            }
            func event(_ id: String, title: String, offset: Double, link: String?, series: String? = nil,
                       quoted: String? = nil) -> CalendarMeeting {
                .init(id: id, seriesID: series ?? id, calendarID: "work", calendarTitle: "Work",
                      title: title, start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset + 3600),
                      linkGroups: CalendarLinkDiscovery.groups(url: nil, location: link, notes: quoted,
                        knownOrigins: ["https://meeting.example.test", "https://music.example.test"], hintedHostFragments: []))
            }
            let choice = ProcessInfo.processInfo.environment["CONFERENCE_TEST_CALENDAR"] == "engine-choice"
            let mode = ProcessInfo.processInfo.environment["CONFERENCE_TEST_CALENDAR"] ?? ""
            let home = mode.hasPrefix("home")
            let preview = mode.hasPrefix("home-preview")
            var events = [event("daily", title: preview ? "Rehearsal and arrangements for the upcoming community concert" : "Daily rehearsal",
                                offset: mode == "home-later" || mode == "home-delayed-later" ? 1200 : mode == "home-preview-current" || mode == "home-overlap" ? -300 : 30,
                                link: choice ? "https://music.example.test/jams/team" :
                                    mode == "home-handoff" ? "https://meeting.example.test/calls/quartet?psw=calendar" : "https://meeting.example.test/team?psw=fixture",
                                quoted: ProcessInfo.processInfo.environment["CONFERENCE_TEST_CALENDAR"] == "forwarded" ?
                                    "https://meeting.example.test/older?psw=before" : nil),
                          event("sync", title: "Sync", offset: 7200, link: nil, series: "weekly-sync"),
                          event("planning", title: "Next day planning", offset: home ? 7200 : 86_400,
                                link: "https://meeting.example.test/calls/team?psw=new"),
                          event("community", title: "Open rehearsal", offset: 90_000,
                                link: "https://music.example.test/jams/team")]
            if mode == "home-overlap" {
                events += [("overlap1", -240.0), ("overlap2", -180.0), ("soon", 180.0),
                           ("later1", 1200.0), ("later2", 1800.0), ("later3", 2700.0)].map { id, offset in
                    event(id, title: id, offset: offset, link: "https://meeting.example.test/" + id)
                }
            }
            return .init(calendars: [.init(id: "work", name: "Work", source: "Test account"),
                                     .init(id: "personal", name: "Personal", source: "Test account")],
                         meetings: selected.contains("work") && mode != "home-empty" ? events : [])
        }
    }
    final class Response: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            if request.httpMethod == "POST" {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 503,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("{}".utf8)); client?.urlProtocolDidFinishLoading(self)
                return
            }
            let community = request.url?.host == "music.example.test"
            let metadata = request.url?.path.hasPrefix("/api/") == true
            let choice = ProcessInfo.processInfo.environment["CONFERENCE_TEST_CALENDAR"] == "engine-choice"
            let status = choice || community == metadata ? 200 : 404
            let text = metadata ? "{\"id\":\"team\",\"title\":\"Open rehearsal\",\"community\":\"Group\",\"description\":\"\",\"engine\":\"livekit\",\"join_protocol\":\"rocknroll-v1\"}" :
                "{\"fixture\":{\"serverUrl\":\"https://backend.example.test\"}}"
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    @MainActor static func makeModel() -> ConferenceModel? {
        guard let mode = ProcessInfo.processInfo.environment["CONFERENCE_TEST_CALENDAR"] else { return nil }
        let preferences = UserDefaults(suiteName: "CalendarUIFixture")!
        if mode != "restore" { preferences.removePersistentDomain(forName: "CalendarUIFixture") }
        preferences.set(true, forKey: "calendarMeetings.enabled")
        preferences.set(["work"], forKey: "calendarMeetings.selected")
        preferences.set(mode == "countdown" || mode == "home-countdown", forKey: "calendarMeetings.automaticJoin")
        preferences.set("Calendar QA", forKey: "savedDisplayName")
        preferences.set(true, forKey: "iCloudSyncOfferSeen")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Response.self]
        let detector = MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: config))
        let reminders = CalendarReminderCoordinator(preferences: preferences, storage: Storage())
        let calendar = CalendarMeetingStore(reader: Reader(), detector: detector, preferences: preferences, storage: Storage(), reminders: reminders)
        let model = ConferenceModel(jamService: JamService(session: URLSession(configuration: config)),
                               history: RoomHistoryStore(storage: Storage()), preferences: preferences,
                               engineDetector: detector, calendar: calendar)
        if mode.hasPrefix("home") {
            let titles = ["Warm-up", "Thursday rehearsal", "Songwriting circle", "Quartet", "Arrangement", "Practice"]
            let favorites = titles.enumerated().map { index, title in
                var room = RecentRoom(invitationURL: URL(string: (mode == "home-details" || mode.hasPrefix("home-delayed") || mode.hasPrefix("home-preview")) && index == 0 ?
                    "https://meeting.example.test/team?psw=fixture" : "https://meeting.example.test/favorite\(index)")!,
                    title: title, identifier: "favorite\(index)", isStarred: true,
                    lastJoined: Date().addingTimeInterval(Double(-index * 60)))
                if mode == "home-details" && index == 1 { room.hasBeenJoined = false }
                if mode.hasPrefix("home-preview") && index == 0 { room.alias = "Our rehearsal room" }
                return room
            }
            let recent = (0..<3).map { index in
                RecentRoom(invitationURL: URL(string: "https://meeting.example.test/recent\(index)")!,
                    title: "Recent room \(index + 1)", identifier: "recent\(index)",
                    lastJoined: Date().addingTimeInterval(Double(-(index + 6) * 60)))
            }
            model.history.applySyncedRooms(favorites + recent)
        }
        if mode == "engine-choice" { model.invite = "https://music.example.test/jams/team" }
        return model
    }
}
#endif
