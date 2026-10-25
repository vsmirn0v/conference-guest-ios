import AppKit
import ConferenceCore
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

private final class UpdateAdmissionStorage: RoomHistoryStorage, ReminderStorage, @unchecked Sendable {
    var value: Data?
    func read() -> Data? { value }
    func write(_ data: Data) throws { value = data }
}

private actor UpdateAdmissionCalendarReader: CalendarReading {
    func access() -> CalendarAccess { .notDetermined }
    func requestAccess() -> Bool { false }
    func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) -> CalendarSnapshot {
        .init(calendars: [], meetings: [])
    }
}

private final class UpdateAdmissionNoNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
    override func stopLoading() {}
}

@MainActor private final class UpdateAdmissionNotifications: ReminderNotifying {
    func authorization() async -> ReminderAuthorization { .notDetermined }
    func request(sensitive: Bool) async throws -> Bool { false }
    func pending() async -> [String: String] { [:] }
    func add(_ reminder: ReminderNotification) async throws {}
    func removePending(_ ids: [String]) {}
    func removeDelivered(occurrenceIDs: Set<String>) async {}
    func removeAllDelivered() async {}
}

@MainActor private final class UpdateAdmissionCloud: RoomCloudTransport {
    func connect() async throws -> RoomCloudSession { throw RoomCloudError.noAccount }
    func fetch(session: RoomCloudSession, after token: Data?) async throws -> RoomCloudChanges { .init(records: [], token: nil) }
    func save(_ records: [RoomSyncRecord], session: RoomCloudSession) async throws -> [RoomSyncRecord] { records }
    func clear(session: RoomCloudSession) async throws {}
}

@MainActor private final class UpdateAdmissionContinuation: MeetingContinuationTransport {
    func connect(account: String) async throws {}
    func jams() async throws -> [ActiveJam] { [] }
    func publish(_ jam: ActiveJam) async throws {}
    func withdraw(deviceID: String, sessionID: UUID?) async throws {}
    func claim(_ transfer: JamTransfer) async throws { throw ContinuationError.unavailable }
    func transfer(sourceSession: UUID) async throws -> JamTransfer? { nil }
    func transition(_ transfer: JamTransfer, to phase: JamTransfer.Phase, actor: String) async throws -> JamTransfer {
        throw ContinuationError.unavailable
    }
    func clear() async throws {}
}

@MainActor private final class UpdateAdmissionLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

/// No fixture starts a network connection, capture device or playout track.
@MainActor private final class UpdateAdmissionEngine: NativeDesktopMeetingEngine {
    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    var factory: LKRTCPeerConnectionFactory? { nil }
    var incomingVideo: [NativeDesktopExternalVideo] { [] }
    var snapshot = NativeDesktopExternalSnapshot()
    var connections = 0
    var leaves = 0
    var clean = true
    var leaveLatch: UpdateAdmissionLatch?
    func connect(invitation: URL, name: String, quiet: Bool) async throws {
        connections += 1; setPhase(.connected)
    }
    func reconnect() async throws {}
    func setMicrophone(_ enabled: Bool) async throws {}
    func setCamera(_ enabled: Bool) async throws {}
    func setPlayout(_ enabled: Bool) async throws {}
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {}
    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?) async throws {}
    func leave() async -> Bool {
        leaves += 1
        await leaveLatch?.wait()
        setPhase(clean ? .left : .failed)
        return clean
    }
    func setPhase(_ phase: NativeDesktopMeetingPhase) { snapshot.phase = phase; onState?(snapshot) }
}

@MainActor final class UpdateAdmissionTests: XCTestCase {
    private let invitation = URL(string: "https://example.test/calls/update-admission")!
    private final class Calls { var detections = 0; var models = 0 }
    private struct Fixture {
        let workspace: NativeDesktopWorkspace
        let library: NativeDesktopLibrary
        let engine: UpdateAdmissionEngine
        let calls: Calls
    }

    private func fixture(detectionLatch: UpdateAdmissionLatch? = nil) -> Fixture {
        let domain = "native-update-admission-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        addTeardownBlock { preferences.removePersistentDomain(forName: domain) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateAdmissionNoNetwork.self]
        let reminders = CalendarReminderCoordinator(preferences: preferences, storage: UpdateAdmissionStorage(),
                                                     notifications: UpdateAdmissionNotifications())
        let calendar = CalendarMeetingStore(reader: UpdateAdmissionCalendarReader(),
            detector: MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: configuration)),
            preferences: preferences, storage: UpdateAdmissionStorage(), reminders: reminders, isMac: true)
        let library = NativeDesktopLibrary(preferences: preferences,
            history: RoomHistoryStore(storage: UpdateAdmissionStorage()), syncStorage: UpdateAdmissionStorage(),
            cloudTransport: UpdateAdmissionCloud(), calendar: calendar, continuationTransport: UpdateAdmissionContinuation())
        library.displayName = "Update admission fixture"
        library.setup.suspendForMeeting()
        let engine = UpdateAdmissionEngine(), calls = Calls()
        let workspace = NativeDesktopWorkspace(library: library, detect: { url in
            calls.detections += 1
            // Deliberately finish late even if the discovery owner was cancelled.
            await detectionLatch?.wait()
            return .verified(.guest(endpoint: url))
        }, makeMeeting: { destination, name, title, quiet in
            calls.models += 1
            return NativeDesktopMeetingModel(destination: destination, name: name, title: title, quiet: quiet, engine: engine)
        })
        return Fixture(workspace: workspace, library: library, engine: engine, calls: calls)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard condition() else {
            XCTFail("The asynchronous fixture did not reach its expected state", file: file, line: line)
            throw CancellationError()
        }
    }

    private func calendarMeeting() -> CalendarMeeting {
        var meeting = CalendarMeeting(id: "scheduled-update-gate", seriesID: "scheduled-update-gate",
            calendarID: "fixture", calendarTitle: "Fixture", title: "Scheduled fixture",
            start: Date(), end: Date().addingTimeInterval(3_600), links: [invitation])
        meeting.invitation = invitation; meeting.engine = .guest
        return meeting
    }

    private func jam() -> ActiveJam {
        ActiveJam(deviceID: "fixture-phone", sessionID: UUID(), invitation: invitation,
            title: "Continuation fixture", name: "Fixture", deviceLabel: "Phone")
    }

    func testClosedUpdateGateRejectsManualInputBeforeDiscoveryOrTransport() {
        let fixture = fixture(), workspace = fixture.workspace
        workspace.mayAdmitMeeting = { false }
        workspace.invitation = invitation.absoluteString
        workspace.joinInput()
        XCTAssertFalse(workspace.preparing)
        XCTAssertFalse(workspace.busyForUpdate)
        XCTAssertNil(workspace.meeting)
        XCTAssertNotNil(workspace.error)
        XCTAssertEqual(fixture.calls.detections, 0)
        XCTAssertEqual(fixture.calls.models, 0)
        XCTAssertEqual(fixture.engine.connections, 0)
        XCTAssertTrue(fixture.library.recent.isEmpty)
    }

    func testClosedUpdateGateDisarmsCalendarAndFinishesExactScheduledRequest() {
        let fixture = fixture(), workspace = fixture.workspace
        let meeting = calendarMeeting()
        XCTAssertTrue(fixture.library.canAutomaticallyJoin())
        XCTAssertTrue(fixture.library.calendar.canAutomaticallyJoin(meeting))
        workspace.mayAdmitMeeting = { false }
        XCTAssertFalse(fixture.library.canAutomaticallyJoin())
        XCTAssertFalse(fixture.library.calendar.canAutomaticallyJoin(meeting))
        var finished = 0
        fixture.library.onScheduledMeeting?(.init(meeting: meeting, admission: { true }, finish: { finished += 1 }))
        XCTAssertEqual(finished, 1)
        XCTAssertFalse(workspace.preparing)
        XCTAssertFalse(workspace.busyForUpdate)
        XCTAssertNil(workspace.meeting)
        XCTAssertEqual(fixture.calls.detections, 0)
        XCTAssertEqual(fixture.calls.models, 0)
        XCTAssertEqual(fixture.engine.connections, 0)
        XCTAssertTrue(fixture.library.recent.isEmpty)
    }

    func testClosedUpdateGateRefusesOrdinaryAndQuietContinuationTargets() {
        let fixture = fixture(), workspace = fixture.workspace
        workspace.mayAdmitMeeting = { false }
        for quiet in [false, true] {
            XCTAssertNil(fixture.library.continuation.onJoinTarget?(jam(), quiet))
        }
        fixture.library.continuation.joinHere(jam())
        XCTAssertFalse(workspace.preparing)
        XCTAssertFalse(workspace.busyForUpdate)
        XCTAssertNil(workspace.meeting)
        XCTAssertEqual(fixture.calls.detections, 0)
        XCTAssertEqual(fixture.calls.models, 0)
        XCTAssertEqual(fixture.engine.connections, 0)
        XCTAssertTrue(fixture.library.recent.isEmpty)
    }

    func testRealUpdateReservationClosesEveryWorkspaceAdmissionPath() throws {
        let fixture = fixture(), workspace = fixture.workspace
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-update-gate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let safety = try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100)
        workspace.mayAdmitMeeting = { safety.mayStartMeeting }
        try safety.prepareUpdate(targetBuild: 101)
        XCTAssertTrue(try safety.reserveInstallation(busy: workspace.busyForUpdate))
        workspace.join(invitation)
        var scheduledFinished = false
        fixture.library.onScheduledMeeting?(.init(meeting: calendarMeeting(), admission: { true }, finish: { scheduledFinished = true }))
        XCTAssertNil(fixture.library.continuation.onJoinTarget?(jam(), false))
        XCTAssertFalse(fixture.library.canAutomaticallyJoin())
        XCTAssertTrue(scheduledFinished)
        XCTAssertNil(workspace.meeting)
        XCTAssertEqual(fixture.calls.detections, 0)
        XCTAssertEqual(fixture.engine.connections, 0)
        XCTAssertTrue(try safety.clearPreparedUpdateIfSafe())
        XCTAssertTrue(fixture.library.canAutomaticallyJoin())
    }

    func testDiscoveryAndCancelledDiscoveryDrainStayBusyUntilOwnerFinishes() async throws {
        let latch = UpdateAdmissionLatch(); defer { latch.open() }
        let fixture = fixture(detectionLatch: latch), workspace = fixture.workspace
        XCTAssertFalse(workspace.busyForUpdate)
        workspace.join(invitation)
        XCTAssertTrue(workspace.busyForUpdate)
        try await eventually { fixture.calls.detections == 1 }
        var leaveFinished = false
        let leaving = Task { let clean = await workspace.leave(); leaveFinished = true; return clean }
        await Task.yield()
        XCTAssertFalse(leaveFinished)
        XCTAssertTrue(workspace.busyForUpdate)
        workspace.join(invitation)
        XCTAssertNil(fixture.library.continuation.onJoinTarget?(jam(), false))
        XCTAssertFalse(fixture.library.canAutomaticallyJoin())
        XCTAssertEqual(fixture.calls.detections, 1)
        XCTAssertEqual(fixture.calls.models, 0)
        latch.open()
        let clean = await leaving.value
        XCTAssertTrue(clean)
        XCTAssertFalse(workspace.busyForUpdate)
        XCTAssertNil(workspace.meeting)
        XCTAssertEqual(fixture.engine.connections, 0)
        XCTAssertTrue(fixture.library.recent.isEmpty)
    }

    func testConnectedRecoveringAndFailedMeetingsRemainBusyUntilSuccessfulLeave() async throws {
        let fixture = fixture(), workspace = fixture.workspace
        workspace.join(invitation)
        try await eventually { workspace.meeting?.connected == true && !workspace.preparing }
        XCTAssertTrue(workspace.busyForUpdate)
        fixture.engine.setPhase(.reconnecting)
        XCTAssertTrue(workspace.busyForUpdate)
        fixture.engine.setPhase(.failed)
        XCTAssertTrue(workspace.busyForUpdate)
        XCTAssertNotNil(workspace.meeting)
        let clean = await workspace.leave()
        XCTAssertTrue(clean)
        XCTAssertFalse(workspace.busyForUpdate)
        XCTAssertNil(workspace.meeting)
    }

    func testMediaCleanupBarrierStaysBusyAndPreventsNewDiscoveryUntilDrained() async throws {
        let fixture = fixture(), workspace = fixture.workspace
        let latch = UpdateAdmissionLatch(); defer { latch.open() }
        fixture.engine.leaveLatch = latch
        workspace.join(invitation)
        try await eventually { workspace.meeting?.connected == true && !workspace.preparing }
        let leaving = Task { await workspace.leave() }
        try await eventually { fixture.engine.leaves == 1 }
        XCTAssertTrue(workspace.busyForUpdate)
        workspace.join(invitation)
        XCTAssertNil(fixture.library.continuation.onJoinTarget?(jam(), false))
        XCTAssertEqual(fixture.calls.detections, 1)
        latch.open()
        let clean = await leaving.value
        XCTAssertTrue(clean)
        XCTAssertFalse(workspace.busyForUpdate)
        XCTAssertNil(workspace.meeting)
        XCTAssertEqual(fixture.engine.leaves, 1)
    }

    func testFailedCleanupRetainsBusyFenceAndRejectsReplacementMeeting() async throws {
        let fixture = fixture(), workspace = fixture.workspace
        workspace.join(invitation)
        try await eventually { workspace.meeting?.connected == true && !workspace.preparing }
        fixture.engine.clean = false
        let clean = await workspace.leave()
        XCTAssertFalse(clean)
        XCTAssertFalse(workspace.preparing)
        XCTAssertTrue(workspace.busyForUpdate)
        XCTAssertNotNil(workspace.meeting)
        XCTAssertNotNil(workspace.error)
        workspace.join(URL(string: "https://example.test/calls/blocked-replacement")!)
        XCTAssertNil(fixture.library.continuation.onJoinTarget?(jam(), false))
        XCTAssertFalse(fixture.library.canAutomaticallyJoin())
        XCTAssertEqual(fixture.calls.detections, 1)
        XCTAssertEqual(fixture.engine.connections, 1)
        let retried = await workspace.leave()
        XCTAssertFalse(retried)
        XCTAssertTrue(workspace.busyForUpdate)
        XCTAssertEqual(fixture.engine.leaves, 1)
    }
}
