import ConferenceCore
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class MeetingEngineRoutingTests: XCTestCase {
    final class Proof: URLProtocol {
        enum Mode { case community, guest, both, unknown }
        static var mode = Mode.community
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let metadata = request.url?.path.hasPrefix("/api/") == true
            let status = Self.mode == .unknown || (!metadata && Self.mode == .community) ||
                (metadata && Self.mode == .guest) ? 404 : 200
            let json = metadata ? "{\"id\":\"team\",\"title\":\"Room\",\"community\":\"Group\",\"description\":\"\",\"engine\":\"livekit\",\"join_protocol\":\"rocknroll-v1\"}" :
                "{\"fixture\":{\"serverUrl\":\"https://backend.example.test\"}}"
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    private let invitation = URL(string: "https://opaque.example.test/jams/team")!
    private func make(storage: any RoomHistoryStorage = RoomSyncCoordinatorTests.Storage(),
                      cloud: RoomSyncCoordinatorTests.Cloud? = nil) -> (ConferenceModel, UIViewController) {
        ConferenceJoinOptionsTests.FailedJoin.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Proof.self]
        let joinConfig = URLSessionConfiguration.ephemeral; joinConfig.protocolClasses = [ConferenceJoinOptionsTests.FailedJoin.self]
        let preferences = UserDefaults(suiteName: "RoutingTests-" + UUID().uuidString)!
        preferences.set("Configured name", forKey: "savedDisplayName")
        let model = ConferenceModel(jamService: JamService(session: URLSession(configuration: joinConfig)),
            history: RoomHistoryStore(storage: storage), preferences: preferences,
            engineDetector: MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: config)))
        model.installSyncFixture(RoomSyncCoordinator(history: model.history, name: model.displayName,
            preferences: preferences, storage: RoomSyncCoordinatorTests.Storage(), transport: cloud ?? RoomSyncCoordinatorTests.Cloud()))
        let container = UIViewController(); model.configure(container: container)
        return (model, container)
    }
    private func finish(_ model: ConferenceModel) async throws {
        let end = Date().addingTimeInterval(2)
        while model.isJoining, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isJoining)
    }
    func testProvenCommunityProtocolOverridesDefaultGuestParsing() async throws {
        Proof.mode = .community
        let (model, container) = make()
        model.receive(url: invitation); model.join(); try await finish(model)
        XCTAssertNil(model.engineSelection)
        XCTAssertEqual(ConferenceJoinOptionsTests.FailedJoin.requestedNames, ["Configured name"])
        withExtendedLifetime(container) {}
    }
    func testBothProtocolsWaitForChoiceBeforeSendingAJoinRequest() async throws {
        Proof.mode = .both
        let (model, container) = make()
        model.receive(url: invitation); model.join(); try await finish(model)
        XCTAssertNotNil(model.engineSelection)
        XCTAssertTrue(ConferenceJoinOptionsTests.FailedJoin.requestedNames.isEmpty)
        model.chooseEngine(community: true); try await finish(model)
        XCTAssertNil(model.engineSelection)
        XCTAssertEqual(ConferenceJoinOptionsTests.FailedJoin.requestedNames, ["Configured name"])
        withExtendedLifetime(container) {}
    }
    func testKnownSavedEngineRemainsUsableWhenShortProbesAreUnavailable() async throws {
        Proof.mode = .unknown
        let (model, container) = make()
        model.history.saveFavorite(url: invitation, title: "Room", engine: .community)
        model.rejoin(model.history.rooms[0]); try await finish(model)
        XCTAssertEqual(ConferenceJoinOptionsTests.FailedJoin.requestedNames, ["Configured name"])
        withExtendedLifetime(container) {}
    }
    func testNameIsRevalidatedForResolvedEngineWithoutPublishingOrLosingInvitation() async throws {
        Proof.mode = .community
        let (model, container) = make()
        model.displayName = String(repeating: "n", count: 70)
        model.receive(url: invitation); model.join(); try await finish(model)
        XCTAssertTrue(model.isNameRequiredForJoin)
        XCTAssertEqual(model.namePolicy.maximumNameScalars, 60)
        XCTAssertTrue(ConferenceJoinOptionsTests.FailedJoin.requestedNames.isEmpty)
        model.displayName = "Short name"; model.join(); try await finish(model)
        XCTAssertEqual(ConferenceJoinOptionsTests.FailedJoin.requestedNames, ["Short name"])
        withExtendedLifetime(container) {}
    }

    func testCalendarAndHandoffKeepVerifiedRoutesBeforeRequestingAName() {
        for (kind, text) in [(MeetingEngineKind.trueconf, "https://custom.example.test/c/team"),
                             (.telemost, "https://telemost.yandex.ru/j/12345678901234"),
                             (.community, "https://custom.example.test/jams/team")] {
            let url = URL(string: text)!
            let (calendarModel, calendarContainer) = make()
            calendarModel.displayName = ""
            var meeting = CalendarMeeting(id: "event", seriesID: "series", calendarID: "work", calendarTitle: "Work",
                title: "Room", start: Date(), end: Date().addingTimeInterval(60))
            meeting.invitation = url; meeting.engine = kind
            calendarModel.joinCalendarMeeting(meeting)
            XCTAssertEqual(calendarModel.awaitingNameEngineForTesting, kind)
            XCTAssertEqual(calendarModel.invite, url.absoluteString)
            XCTAssertTrue(calendarModel.isNameRequiredForJoin)
            XCTAssertFalse(calendarModel.isJoining)

            let (handoffModel, handoffContainer) = make()
            let jam = ActiveJam(deviceID: "mac", invitation: url, title: "Room", name: "", deviceLabel: "Mac", engine: kind)
            XCTAssertNil(handoffModel.joinFromContinuation(jam, quiet: false))
            XCTAssertEqual(handoffModel.awaitingNameEngineForTesting, kind)
            XCTAssertEqual(handoffModel.invite, url.absoluteString)
            XCTAssertTrue(handoffModel.isNameRequiredForJoin)
            XCTAssertTrue(ConferenceJoinOptionsTests.FailedJoin.requestedNames.isEmpty)
            withExtendedLifetime([calendarContainer, handoffContainer]) {}
        }
    }

    func testGuestAppLinkHistoryExcludesKnownTrueConfButKeepsUntypedLegacy() {
        let link = URL(string: "jcp://jazz?code=team&psw=secret")!
        let (model, container) = make()
        model.displayName = ""
        model.history.saveFavorite(url: URL(string: "https://trueconf.example.test/c/team?psw=secret")!, title: "Native", engine: .trueconf)
        model.receive(url: link)
        XCTAssertNotNil(model.siteSelection)
        XCTAssertFalse(model.isNameRequiredForJoin)

        let (legacyModel, legacyContainer) = make()
        legacyModel.displayName = ""
        let legacy = URL(string: "https://legacy.example.test/c/team?psw=secret")!
        legacyModel.history.saveFavorite(url: legacy, title: "Legacy")
        legacyModel.receive(url: link)
        XCTAssertNil(legacyModel.siteSelection)
        XCTAssertEqual(legacyModel.awaitingNameEngineForTesting, .guest)
        XCTAssertTrue(legacyModel.isNameRequiredForJoin)
        XCTAssertEqual(legacyModel.invite, legacy.absoluteString)
        withExtendedLifetime([container, legacyContainer]) {}
    }

    func testCalendarAndHandoffVisitsKeepTheirNamesAndPersistForEveryEngine() async throws {
        for kind in [MeetingEngineKind.guest, .community, .telemost, .trueconf] {
            for handoff in [false, true] {
                Proof.mode = kind == .guest ? .guest : .community
                let storage = RoomSyncCoordinatorTests.Storage()
                let cloud = RoomSyncCoordinatorTests.Cloud()
                let (model, container) = make(storage: storage, cloud: cloud)
                let url = URL(string: kind == .telemost ? "https://telemost.yandex.ru/j/12345678901234" :
                    kind == .guest ? "https://meeting.example.test/calls/q01xx4?psw=fixture" :
                    kind == .trueconf ? "https://custom.example.test/c/team" : invitation.absoluteString)!
                var complete: ((CallEvent) -> Void)?
                let ready = expectation(description: "Join transport \(kind) \(handoff)")
                model.joinTransportForTesting = { destination, callback in
                    XCTAssertEqual(destination.engineKind, kind)
                    complete = callback; ready.fulfill()
                }
                if handoff {
                    let jam = ActiveJam(deviceID: "other", invitation: url, title: "Design review", name: "Ani",
                        deviceLabel: "Mac", engine: kind)
                    XCTAssertNotNil(model.joinFromContinuation(jam, quiet: false))
                } else {
                    var meeting = CalendarMeeting(id: "event", seriesID: "series", calendarID: "work", calendarTitle: "Work",
                        title: "Design review", start: Date(), end: Date().addingTimeInterval(600))
                    meeting.invitation = url; meeting.engine = kind
                    model.joinCalendarMeeting(meeting)
                }
                await fulfillment(of: [ready], timeout: 5)
                XCTAssertTrue(model.history.rooms.isEmpty, "Starting a join must not create a visit")
                complete?(.joined)
                complete?(.active)
                let room = try XCTUnwrap(model.history.rooms.first)
                XCTAssertEqual(model.history.rooms.count, 1)
                XCTAssertEqual(room.title, "Design review")
                XCTAssertEqual(room.joinURL, url)
                XCTAssertEqual(room.engine, kind)
                XCTAssertNotNil(room.lastVisit)
                XCTAssertEqual(room.hasBeenJoined, true)
                XCTAssertFalse(room.isStarred)
                XCTAssertEqual(RoomHistoryStore(storage: storage).rooms, model.history.rooms)
                model.sync.setEnabled(true)
                await model.sync.synchronizeForNotification()
                let (other, otherContainer) = make(cloud: cloud)
                other.sync.setEnabled(true)
                await other.sync.synchronizeForNotification()
                XCTAssertEqual(other.history.rooms, model.history.rooms, "Calendar/handoff visits must reach another device")
                complete?(.left)
                complete?(.active) // A late callback must not resurrect the ended session.
                XCTAssertFalse(model.isInConference)
                XCTAssertEqual(model.history.rooms.count, 1)
                withExtendedLifetime([container, otherContainer]) {}
            }
        }
    }

    func testCalendarNamePromptKeepsTitleAndFailedJoinDoesNotCreateHistory() async throws {
        Proof.mode = .guest
        let (model, container) = make()
        model.displayName = ""
        let url = URL(string: "https://meeting.example.test/calls/scheduled?psw=fixture")!
        var meeting = CalendarMeeting(id: "event", seriesID: "series", calendarID: "work", calendarTitle: "Work",
            title: "Scheduled design review", start: Date(), end: Date().addingTimeInterval(600))
        meeting.invitation = url; meeting.engine = .guest
        model.joinCalendarMeeting(meeting)
        XCTAssertTrue(model.isNameRequiredForJoin)
        XCTAssertTrue(model.history.rooms.isEmpty)
        model.displayName = "Ani"
        var complete: ((CallEvent) -> Void)?
        let first = expectation(description: "First transport")
        model.joinTransportForTesting = { _, callback in complete = callback; first.fulfill() }
        model.join()
        await fulfillment(of: [first], timeout: 5)
        complete?(.failed)
        complete?(.active)
        XCTAssertTrue(model.history.rooms.isEmpty)

        let retry = expectation(description: "Retry transport")
        model.joinTransportForTesting = { _, callback in complete = callback; retry.fulfill() }
        model.joinCalendarMeeting(meeting)
        await fulfillment(of: [retry], timeout: 5)
        complete?(.joined)
        XCTAssertEqual(model.history.rooms.first?.title, meeting.title)
        XCTAssertEqual(model.history.rooms.first?.joinURL, url)
        withExtendedLifetime(container) {}
    }
}
