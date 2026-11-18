import AppKit
import AVFoundation
import ConferenceCore
import LiveKitWebRTC
import XCTest
@testable import MeetingEngine
@testable import RockNativeDesktop

@MainActor private final class SameRoomTestEngine: NativeDesktopMeetingEngine {
    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    var factory: LKRTCPeerConnectionFactory? { nil }
    var snapshot = NativeDesktopExternalSnapshot()
    var incomingVideo: [NativeDesktopExternalVideo] { [] }

    func connect(invitation: URL, name: String, quiet: Bool) async throws {
        snapshot.phase = .connecting
        onState?(snapshot)
        snapshot = .init(phase: .connected, playoutOn: !quiet)
        onState?(snapshot)
    }

    func reconnect() async throws {}
    func setMicrophone(_ enabled: Bool) async throws { snapshot.microphoneOn = enabled; onState?(snapshot) }
    func setCamera(_ enabled: Bool) async throws { snapshot.cameraOn = enabled; onState?(snapshot) }
    func setPlayout(_ enabled: Bool) async throws { snapshot.playoutOn = enabled; onState?(snapshot) }
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws { snapshot.sharing = track != nil; onState?(snapshot) }
    func setPhysicalInputPermitted(_ permitted: Bool, keepDeviceWarm: Bool) async -> Bool { true }
    func prewarmInput() async -> Bool { false }
    var supportsVoiceReply: Bool { false }
    func setMicrophoneGate(open: Bool) async -> Bool { true }
    var voiceMicrophoneGateIsClosed: Bool { true }
    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool { false }

    func leave() async -> Bool {
        snapshot.phase = .left
        onState?(snapshot)
        return true
    }
}

private final class SameRoomReminderStorage: ReminderStorage, RoomHistoryStorage {
    var data: Data?
    func read() -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}

@MainActor private final class SameRoomReminderNotifications: ReminderNotifying {
    var permission: ReminderAuthorization = .allowed
    var items: [String: ReminderNotification] = [:]
    var removedDeliveredIDs: Set<String> = []
    var deliveredIDs: Set<String> = []

    func authorization() async -> ReminderAuthorization { permission }
    func request(sensitive: Bool) async throws -> Bool { permission == .allowed }
    func pending() async -> [String: String] { Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0.value.fingerprint) }) }
    func add(_ reminder: ReminderNotification) async throws { items[reminder.plan.id] = reminder }
    func removePending(_ ids: [String]) { for id in ids { items[id] = nil } }
    func removeDelivered(occurrenceIDs: Set<String>) async {
        removedDeliveredIDs.formUnion(occurrenceIDs)
        for id in occurrenceIDs {
            deliveredIDs.remove(PlannedReminder.namespace + id)
        }
    }
    func removeAllDelivered() async { deliveredIDs.removeAll() }
}

private actor SameRoomCalendarReader: CalendarReading {
    private var snapshotMeetings: [CalendarMeeting] = []
    private let calendar = MeetingCalendar(id: "work", name: "Work", source: "Fixture")

    func setMeetings(_ meetings: [CalendarMeeting]) { snapshotMeetings = meetings }
    func access() -> CalendarAccess { .allowed }
    func requestAccess() -> Bool { true }
    func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) -> CalendarSnapshot {
        CalendarSnapshot(calendars: [calendar], meetings: snapshotMeetings)
    }
}

private final class SameRoomWellKnownURLProtocol: URLProtocol {
    static var endpointByHost: [String: String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url?.host?.lowercased() ?? ""
        let serverURL = Self.endpointByHost[host] ?? "https://rtc.example.test"
        let supported = request.url?.path == "/.well-known/s2b-services.json"
        let data = Data("{\"fixture\":{\"serverUrl\":\"\(serverURL)\"}}".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: supported ? 200 : 404,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class SameRoomClockBox: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor private final class RecordingOutcomeWriter: MeetingOutcomeWriter, @unchecked Sendable {
    var requests: [MeetingOutcomeRequest] = []
    func outcome(_ request: MeetingOutcomeRequest) async throws -> MeetingOutcomeContent {
        requests.append(request)
        return MeetingOutcomeContent(
            summary: "Summary for \(request.meetingTitle) (\(request.window.lines.count) lines)",
            decisions: [], tasks: [], openQuestions: [])
    }
}

@MainActor final class SameRoomBackToBackTests: XCTestCase {
    private let roomA = URL(string: "https://salutejazz.ru/calls/shared-room?psw=alpha")!
    private let roomAOrigin2 = URL(string: "https://partner.example.test/calls/shared-room?psw=beta")!
    private let sharedEndpoint = URL(string: "https://rtc.example.test")!

    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("same-room-tests-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makePreferences() -> UserDefaults {
        let suite = "SameRoomBackToBackTests." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite) }
        prefs.set(true, forKey: "calendarMeetings.enabled")
        prefs.set(["work"], forKey: "calendarMeetings.selected")
        prefs.set(true, forKey: "calendarReminders.enabled")
        return prefs
    }

    private func makeAttention(root: URL, prefs: UserDefaults) -> AttentionCoordinator {
        let keychain = AttentionKeychain(service: "dev.vsmirn0v.conferenceguest.sameroom.tests.\(UUID().uuidString)")
        addTeardownBlock { keychain.deleteAll() }
        let store = AttentionStore(root: root, defaults: prefs, keychain: keychain)
        store.generateOutcomes = true
        store.provider = AttentionProvider(kind: .local, baseURL: "http://127.0.0.1:1/v1", model: "local-test")
        closeLibraryAtTeardown(store)
        return AttentionCoordinator(store: store)
    }

    private func makeCalendarMeeting(id: String, seriesID: String, title: String, start: Date, end: Date, url: URL) -> CalendarMeeting {
        CalendarMeeting(id: id, seriesID: seriesID, calendarID: "work", calendarTitle: "Work",
                        title: title, start: start, end: end, links: [url])
    }

    private func makeHarness(clockBox: SameRoomClockBox) -> (
        workspace: NativeDesktopWorkspace,
        calendar: CalendarMeetingStore,
        reader: SameRoomCalendarReader,
        notifications: SameRoomReminderNotifications,
        attention: AttentionCoordinator,
        writer: RecordingOutcomeWriter
    ) {
        let root = folder()
        let prefs = makePreferences()
        let reminderStorage = SameRoomReminderStorage()
        let notifications = SameRoomReminderNotifications()
        let reminders = CalendarReminderCoordinator(preferences: prefs, storage: reminderStorage,
                                                    notifications: notifications, clock: { clockBox.now })
        let reader = SameRoomCalendarReader()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SameRoomWellKnownURLProtocol.self]
        let detector = MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: config), now: { clockBox.now })
        let calendar = CalendarMeetingStore(reader: reader, detector: detector, preferences: prefs,
                                            storage: SameRoomReminderStorage(), reminders: reminders, isMac: true, clock: { clockBox.now })
        let library = NativeDesktopLibrary(preferences: prefs,
                                           history: RoomHistoryStore(storage: SameRoomReminderStorage()),
                                           syncStorage: SameRoomReminderStorage(),
                                           calendar: calendar)
        library.displayName = "Host User"
        library.setup.suspendForMeeting()

        let attention = makeAttention(root: root, prefs: prefs)
        let writer = RecordingOutcomeWriter()
        attention.makeOutcomeWriter = { _, _ in writer }
        let endpoint = self.sharedEndpoint
        let workspace = NativeDesktopWorkspace(
            library: library,
            detect: { _ in .verified(.guest(endpoint: endpoint)) },
            makeMeeting: { destination, name, title, quiet in
                NativeDesktopMeetingModel(
                    destination: destination, name: name, title: title, quiet: quiet,
                    engine: SameRoomTestEngine(),
                    joinReadiness: NativeDesktopJoinReadinessPolicy(microphone: .off, camera: .off),
                    power: joinTestPower())
            },
            attention: attention)
        return (workspace, calendar, reader, notifications, attention, writer)
    }

    private func spin(file: StaticString = #filePath, line: UInt = #line, _ predicate: () async -> Bool) async throws {
        for _ in 0..<250 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition did not become true in time", file: file, line: line)
    }

    // MARK: - Reminder & Cross-Device Tests

    func testCoordinatorBackToBackSuppressionWithdrawalRestoreBoundaryAndOtherDeviceToggle() async throws {
        var now = Date()
        let prefs = makePreferences()
        let notifications = SameRoomReminderNotifications()
        let coordinator = CalendarReminderCoordinator(preferences: prefs, storage: SameRoomReminderStorage(),
                                                    notifications: notifications, clock: { now })
        XCTAssertTrue(coordinator.suppressOtherDevices)

        let connEndpoint1 = URL(string: "https://rtc.example.test")!
        let m1URL = URL(string: "https://salutejazz.ru/calls/shared-room?psw=one")!
        let m2URL = URL(string: "https://partner.example.test/calls/shared-room?psw=two")!

        var m1 = makeCalendarMeeting(id: "m1", seriesID: "s1", title: "M1",
                                     start: now.addingTimeInterval(-300), end: now.addingTimeInterval(600), url: m1URL)
        m1.invitation = m1URL; m1.engine = .guest; m1.endpoint = connEndpoint1

        var m2 = makeCalendarMeeting(id: "m2", seriesID: "s2", title: "M2",
                                     start: now.addingTimeInterval(600), end: now.addingTimeInterval(2400), url: m2URL)
        m2.invitation = m2URL; m2.engine = .guest; m2.endpoint = connEndpoint1

        var active: [ActiveRoomConnection] = []
        coordinator.activeConnections = { active }
        coordinator.scene = { .init(visible: false, connections: active, usable: true) }
        coordinator.update(meetings: [m1, m2], available: true)
        let occ2 = try XCTUnwrap(coordinator.occurrence(for: m2))
        try await spin { notifications.items.values.contains { $0.plan.occurrenceID == occ2.id } }

        // Connecting across a different web origin with the same resolved server endpoint suppresses & withdraws M2.
        notifications.deliveredIDs.insert(PlannedReminder.namespace + occ2.id)
        active = [ActiveRoomConnection(room: MeetingRoomIdentity(m1URL, engine: .guest)!, endpoint: connEndpoint1)]
        coordinator.activeConnectionsChanged()
        try await spin { !notifications.items.values.contains { $0.plan.occurrenceID == occ2.id } }
        XCTAssertTrue(notifications.removedDeliveredIDs.contains(occ2.id))
        XCTAssertTrue(coordinator.shouldSuppressSystemNotification(reference: occ2.reference))

        // Early leave before M2 starts restores M2.
        active = []
        coordinator.activeConnectionsChanged()
        try await spin { notifications.items.values.contains { $0.plan.occurrenceID == occ2.id } }

        // Staying past M2's start latches M2 as attended on subsequent disconnect.
        active = [ActiveRoomConnection(room: MeetingRoomIdentity(m1URL, engine: .guest)!, endpoint: connEndpoint1)]
        coordinator.activeConnectionsChanged()
        now = m2.start.addingTimeInterval(60)
        active = []
        coordinator.activeConnectionsChanged()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(notifications.items.values.contains { $0.plan.occurrenceID == occ2.id })

        // suppressOtherDevices toggle on/off for remote ActiveJam.
        var m3 = makeCalendarMeeting(id: "m3", seriesID: "s3", title: "Remote Next",
                                     start: now.addingTimeInterval(1200), end: now.addingTimeInterval(3000), url: m1URL)
        m3.invitation = m1URL; m3.engine = .guest
        coordinator.update(meetings: [m3], available: true)
        let occ3 = try XCTUnwrap(coordinator.occurrence(for: m3))
        coordinator.observe([ActiveJam(deviceID: "iphone", sessionID: UUID(), invitation: m1URL,
                                       title: "Ongoing", name: "User", deviceLabel: "iPhone", updatedAt: now)], account: "acct")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(notifications.items.values.contains { $0.plan.occurrenceID == occ3.id })

        coordinator.setSuppressOtherDevices(false)
        try await spin { notifications.items.values.contains { $0.plan.occurrenceID == occ3.id } }
    }

    // MARK: - Title Precedence & Series Isolation Tests

    func testMeetingModelTitlePrecedenceAndManualRenameOverride() throws {
        let engine = SameRoomTestEngine()
        let destination = try JoinDestination.verified(roomA, engine: .guest)
        let model = NativeDesktopMeetingModel(
            destination: destination, name: "Host", title: nil, quiet: false, engine: engine,
            joinReadiness: .init(microphone: .off, camera: .off), power: joinTestPower())

        XCTAssertEqual(model.title, destination.roomIdentifier)

        // Server title overrides bare Room ID fallback when no scheduled title exists.
        engine.onTitle?("Server Bridge")
        XCTAssertEqual(model.title, "Server Bridge")

        // Scheduled Calendar title beats Server title; subsequent server title cannot clobber it.
        model.applyScheduledTitle("Scheduled M1", seriesID: "series-1", calendarMeeting: nil)
        XCTAssertEqual(model.title, "Scheduled M1")
        engine.onTitle?("Noisy Server Rename")
        XCTAssertEqual(model.title, "Scheduled M1")

        // Next scheduled meeting updates live title unless user manually renamed.
        model.applyScheduledTitle("Scheduled M2", seriesID: "series-2", calendarMeeting: nil)
        XCTAssertEqual(model.title, "Scheduled M2")

        // Manual override takes highest precedence over subsequent calendar transitions.
        model.noteUserRenamedSession("My Custom Name")
        XCTAssertEqual(model.title, "My Custom Name")
        model.applyScheduledTitle("Scheduled M3", seriesID: "series-3", calendarMeeting: nil)
        XCTAssertEqual(model.title, "My Custom Name")
    }

    func testAssistantDataIsolatesPersonalRoomOutcomesBySeriesID() async throws {
        let root = folder()
        let data = AssistantDataStore(root: root)
        await data.waitForLoad()

        let personalRoom = URL(string: "https://salutejazz.ru/calls/personal-room?psw=secret")!
        let olderA = MeetingOutcome(meetingTitle: "Series A", invitation: personalRoom, seriesID: "series-a",
                                    endedAt: Date().addingTimeInterval(-3600), summary: "Alpha summary",
                                    decisions: ["Alpha decision"], tasks: [], openQuestions: [])
        let newerB = MeetingOutcome(meetingTitle: "Series B", invitation: personalRoom, seriesID: "series-b",
                                    endedAt: Date().addingTimeInterval(-600), summary: "Beta summary",
                                    decisions: ["Beta decision"], tasks: [], openQuestions: [])
        data.addOutcome(olderA)
        data.addOutcome(newerB)
        await data.waitForSave()

        XCTAssertEqual(data.latestOutcome(invitation: personalRoom, series: "series-a")?.id, olderA.id)
        XCTAssertEqual(data.seriesOutcomes(invitation: personalRoom, series: "series-a").map(\.id), [olderA.id])
        XCTAssertEqual(data.latestOutcome(invitation: personalRoom, series: "series-b")?.id, newerB.id)
        let retrievedA = data.retrieve(meetingTitle: "Series A", invitation: personalRoom, series: "series-a", people: [])
        XCTAssertTrue(retrievedA.contains { $0.text.contains("Alpha summary") })
        XCTAssertFalse(retrievedA.contains { $0.text.contains("Beta summary") })

        // Unscheduled ad-hoc call (series == nil) still sees latest room outcome.
        XCTAssertEqual(data.latestOutcome(invitation: personalRoom, series: nil)?.id, newerB.id)
    }

    // MARK: - Option A, Overrun Grace, Cursor Protection & Lossless A <-> B Switching

    func testWorkspaceOptionARolloverCursorProtectionAndSeparateOutcomes() async throws {
        let base = Date()
        let clockBox = SameRoomClockBox(base.addingTimeInterval(-180)) // 3m before M1 ends
        let harness = makeHarness(clockBox: clockBox)

        let m1 = makeCalendarMeeting(id: "m1", seriesID: "series-a", title: "Standup",
                                     start: base.addingTimeInterval(-300), end: base, url: roomA)
        let m2 = makeCalendarMeeting(id: "m2", seriesID: "series-b", title: "Design Review",
                                     start: base, end: base.addingTimeInterval(600), url: roomA)
        await harness.reader.setMeetings([m1, m2])
        harness.calendar.refresh()
        try await spin { harness.calendar.meetings.count == 2 }

        harness.workspace.join(roomA)
        try await spin { harness.workspace.meeting?.connected == true && !harness.workspace.preparing }
        let model = try XCTUnwrap(harness.workspace.meeting)
        XCTAssertEqual(model.title, "Standup")
        let s1 = model.workspaceSessionID

        // Dirty/non-empty Live Note on M1 must stay pinned during boundary rollover.
        harness.attention.store.notes.update(sessionID: s1, text: "Action items from standup", at: clockBox.now)
        XCTAssertEqual(model.activeNoteSessionID, s1)

        model.receiveLocalLineForTesting(.init(id: "l1", trackID: "a", text: "We finished backend migration.",
                                               start: base.addingTimeInterval(-90), end: base.addingTimeInterval(-88)))

        // Cross M1 -> M2 boundary and refresh calendar clock.
        clockBox.now = base.addingTimeInterval(15)
        harness.calendar.refresh()
        try await spin { model.segments.count == 2 && model.workspaceSessionID != s1 }

        let s2 = model.workspaceSessionID
        XCTAssertEqual(model.title, "Design Review")
        XCTAssertEqual(model.sameRoomTransitionBanner?.mode, .separateSessions)
        XCTAssertEqual(model.sameRoomTransitionBanner?.currentTitle, "Design Review")
        XCTAssertEqual(model.activeNoteSessionID, s1, "Cursor protection keeps M1 note active until switched")
        XCTAssertEqual(model.pendingNoteRolloverTitle, "Design Review")

        // Switch note explicitly via banner action.
        model.switchLiveNoteToCurrentSession()
        XCTAssertEqual(model.activeNoteSessionID, s2)
        XCTAssertNil(model.pendingNoteRolloverTitle)

        model.receiveLocalLineForTesting(.init(id: "l2", trackID: "a", text: "Let us review the navigation mocks.",
                                               start: base.addingTimeInterval(150), end: base.addingTimeInterval(152)))

        // Leave > 2 minutes into M2 so both outcomes are emitted sequentially with distinct windows.
        clockBox.now = base.addingTimeInterval(200)
        let left = await harness.workspace.leave(model)
        XCTAssertTrue(left)

        try await spin { harness.attention.store.assistant.outcomes.count == 2 }
        let titles = Set(harness.writer.requests.map(\.meetingTitle))
        XCTAssertEqual(titles, ["Standup", "Design Review"])

        let req1 = try XCTUnwrap(harness.writer.requests.first { $0.meetingTitle == "Standup" })
        let req2 = try XCTUnwrap(harness.writer.requests.first { $0.meetingTitle == "Design Review" })
        XCTAssertTrue(req1.window.lines.contains { $0.text.contains("backend migration") })
        XCTAssertFalse(req1.window.lines.contains { $0.text.contains("navigation mocks") })
        XCTAssertTrue(req2.window.lines.contains { $0.text.contains("navigation mocks") })
        XCTAssertFalse(req2.window.lines.contains { $0.text.contains("backend migration") })
    }

    func testWorkspaceTwoMinuteOverrunGraceFoldsTailIntoFirstSession() async throws {
        let base = Date()
        let clockBox = SameRoomClockBox(base.addingTimeInterval(-120))
        let harness = makeHarness(clockBox: clockBox)

        let m1 = makeCalendarMeeting(id: "m1", seriesID: "series-a", title: "Weekly Sync",
                                     start: base.addingTimeInterval(-300), end: base, url: roomA)
        let m2 = makeCalendarMeeting(id: "m2", seriesID: "series-b", title: "Next Sync",
                                     start: base, end: base.addingTimeInterval(600), url: roomA)
        await harness.reader.setMeetings([m1, m2])
        harness.calendar.refresh()
        try await spin { harness.calendar.meetings.count == 2 }

        harness.workspace.join(roomA)
        try await spin { harness.workspace.meeting?.connected == true && !harness.workspace.preparing }
        let model = try XCTUnwrap(harness.workspace.meeting)
        let s1 = model.workspaceSessionID
        model.receiveLocalLineForTesting(.init(id: "l1", trackID: "a", text: "Wrapping up weekly sync.",
                                               start: base.addingTimeInterval(-60), end: base.addingTimeInterval(-58)))

        clockBox.now = base.addingTimeInterval(10)
        harness.calendar.refresh()
        try await spin { model.segments.count == 2 && model.workspaceSessionID != s1 }
        let s2 = model.workspaceSessionID

        // Leave within <= 120s overrun grace with no M2 notes -> S2 folds back into S1 and deletes S2 card.
        clockBox.now = base.addingTimeInterval(45)
        let left = await harness.workspace.leave(model)
        XCTAssertTrue(left)

        try await spin { harness.attention.store.assistant.outcomes.count == 1 && harness.attention.outcomeStatus.isEmpty }
        XCTAssertEqual(harness.writer.requests.map(\.meetingTitle), ["Weekly Sync"])
        let deletedSession = try? await harness.attention.store.meetingLibrary.store.session(s2)
        XCTAssertNil(deletedSession)
        let survivingSession = try? await harness.attention.store.meetingLibrary.store.session(s1)
        XCTAssertEqual(survivingSession?.title, "Weekly Sync")
    }

    func testWorkspaceOptionBLosslessSwitchingAndSeriesPreferencePersistence() async throws {
        let base = Date()
        let clockBox = SameRoomClockBox(base.addingTimeInterval(-120))
        let harness = makeHarness(clockBox: clockBox)

        let m1 = makeCalendarMeeting(id: "m1", seriesID: "series-1", title: "Standup",
                                     start: base.addingTimeInterval(-300), end: base, url: roomA)
        let m2 = makeCalendarMeeting(id: "m2", seriesID: "series-2", title: "Product Review",
                                     start: base, end: base.addingTimeInterval(600), url: roomAOrigin2)
        await harness.reader.setMeetings([m1, m2])
        harness.calendar.refresh()
        try await spin { harness.calendar.meetings.count == 2 }

        harness.workspace.join(roomA)
        try await spin { harness.workspace.meeting?.connected == true && !harness.workspace.preparing }
        let model = try XCTUnwrap(harness.workspace.meeting)
        let s1 = model.workspaceSessionID

        harness.attention.store.notes.update(sessionID: s1, text: "Notes from M1", at: clockBox.now)
        model.receiveLocalLineForTesting(.init(id: "l1", trackID: "a", text: "First topic.",
                                               start: base.addingTimeInterval(-60), end: base.addingTimeInterval(-58)))

        // M1 -> M2 starts in Option A by default.
        clockBox.now = base.addingTimeInterval(15)
        harness.calendar.refresh()
        try await spin { model.segments.count == 2 && model.workspaceSessionID != s1 }
        let s2 = model.workspaceSessionID
        try await spin { (try? await harness.attention.store.meetingLibrary.store.session(s2)) != nil }

        model.switchLiveNoteToCurrentSession()
        harness.attention.store.notes.update(sessionID: s2, text: "Notes from M2", at: clockBox.now)
        model.receiveLocalLineForTesting(.init(id: "l2", trackID: "a", text: "Second topic.",
                                               start: base.addingTimeInterval(150), end: base.addingTimeInterval(152)))

        // Lossless switch A -> B ("Keep as one meeting") + remember per-series preference.
        harness.workspace.setSameRoomTransitionMode(for: model, mode: .continuousSession, remember: true)
        try await spin {
            let deleted = try? await harness.attention.store.meetingLibrary.store.session(s2)
            return deleted == nil && model.workspaceSessionID == s1
                && harness.attention.store.notes.buffer(sessionID: s1).contains("## Product Review")
        }
        let mergedNote = harness.attention.store.notes.buffer(sessionID: s1)
        XCTAssertTrue(mergedNote.contains("Notes from M1"))
        XCTAssertTrue(mergedNote.contains("## Product Review"))
        XCTAssertTrue(mergedNote.contains("Notes from M2"))
        XCTAssertEqual(harness.attention.store.savedSameRoomTransition(room: roomA, series: "series-2"), .continuousSession)

        // Lossless switch B -> A ("Separate summary") splits journal back into a new S2'.
        harness.workspace.setSameRoomTransitionMode(for: model, mode: .separateSessions, remember: false)
        XCTAssertNotEqual(model.workspaceSessionID, s1)
        let splitSessionID = model.workspaceSessionID
        try await spin {
            let rec = try? await harness.attention.store.meetingLibrary.store.session(splitSessionID)
            return rec != nil
        }

        // Toggle back B ("Keep as one meeting") and leave to verify chaptered title & chapters on combined outcome.
        harness.workspace.setSameRoomTransitionMode(for: model, mode: .continuousSession, remember: false)
        clockBox.now = base.addingTimeInterval(200)
        let left = await harness.workspace.leave(model)
        XCTAssertTrue(left)

        try await spin { harness.attention.store.assistant.outcomes.count == 1 }
        let combinedRequest = try XCTUnwrap(harness.writer.requests.first)
        XCTAssertEqual(combinedRequest.meetingTitle, "Standup → Product Review")
        XCTAssertTrue(combinedRequest.window.lines.contains { $0.text.contains("First topic.") })
        XCTAssertTrue(combinedRequest.window.lines.contains { $0.text.contains("Second topic.") })
    }
}
