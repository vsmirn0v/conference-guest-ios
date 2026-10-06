import Foundation
import XCTest
@testable import ConferenceCore

final class MeetingEngineDetectorTests: XCTestCase {
    final class Fixture: URLProtocol {
        struct Reply {
            var status = 200
            var mime = "application/json"
            var body: Data
            var hold = false
        }
        private static let lock = NSLock()
        private static var requests: [URLRequest] = []
        static var reply: (URLRequest) -> Reply = { _ in Reply(status: 404, body: Data()) }
        static func reset(_ handler: @escaping (URLRequest) -> Reply) {
            lock.lock(); defer { lock.unlock() }; requests = []; reply = handler
        }
        static var received: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock(); Self.requests.append(request); let result = Self.reply(request); Self.lock.unlock()
            if result.hold { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: result.status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": result.mime])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    private let service = "fixture-engine"
    private let room = URL(string: "https://ambiguous.example.test/jams/team")!
    private var guestJSON: Data { Data("{\"fixture-engine\":{\"serverUrl\":\"https://backend.example.test\"}}".utf8) }
    private func communityJSON(id: String = "team", engine: String = "livekit", protocolName: String = "rocknroll-v1") -> Data {
        try! JSONSerialization.data(withJSONObject: ["id": id, "title": "Room", "community": "Group",
            "description": "", "engine": engine, "join_protocol": protocolName])
    }
    private func detector(timeout: TimeInterval = 1, cacheLifetime: TimeInterval = 300) -> MeetingEngineDetector {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Fixture.self]
        return MeetingEngineDetector(serviceName: service, session: URLSession(configuration: config),
                                     timeout: timeout, cacheLifetime: cacheLifetime)
    }
    private func assertDetection(_ client: MeetingEngineDetector, _ url: URL,
                                 _ expected: MeetingEngineDetection, file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await client.detect(url)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func testGuestProofOverridesMisleadingHostAndNeverSendsInvitationCredentials() async throws {
        let json = guestJSON
        Fixture.reset { _ in .init(body: json) }
        let invitation = URL(string: "https://rock.example.test/private-room?psw=secret&name=Alice")!
        let result = try await detector().detect(invitation)
        XCTAssertEqual(result, .verified(.guest(endpoint: URL(string: "https://backend.example.test")!)))
        XCTAssertEqual(Fixture.received.count, 1)
        let request = try XCTUnwrap(Fixture.received.first)
        XCTAssertEqual(request.url?.path, "/.well-known/s2b-services.json")
        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testCommunityRequiresAnExplicitCompatibleProtocolAndMatchingRoom() async throws {
        let json = communityJSON()
        Fixture.reset { request in .init(status: request.url!.path.hasPrefix("/api/") ? 200 : 404, body: json) }
        try await assertDetection(detector(), room, .verified(.community))
        for json in [communityJSON(id: "other"), communityJSON(engine: "unknown"),
                     communityJSON(protocolName: "future-v2"), Data("{\"id\":\"team\",\"title\":\"Room\"}".utf8)] {
            Fixture.reset { _ in .init(body: json) }
            try await assertDetection(detector(), room, .unknown)
        }
    }

    func testBothPositiveProtocolsRequireAChoice() async throws {
        let guest = guestJSON, community = communityJSON()
        Fixture.reset { request in .init(body: request.url!.path.hasPrefix("/api/") ? community : guest) }
        try await assertDetection(detector(), room, .ambiguous)
    }

    func testServerErrorsHTMLAndOversizedBodiesCannotProveAnEngine() async throws {
        for reply in [Fixture.Reply(status: 503, body: guestJSON),
                      Fixture.Reply(mime: "text/html", body: guestJSON),
                      Fixture.Reply(body: Data(repeating: 65, count: 65_537)),
                      Fixture.Reply(body: Data("{\"fixture-engine\":{\"serverUrl\":\"http://unsafe.test\"}}".utf8))] {
            Fixture.reset { _ in reply }
            try await assertDetection(detector(), room, .unknown)
        }
    }

    func testNoNegativeCacheAndSuccessfulDetectionHasBoundedReusableCache() async throws {
        let client = detector()
        Fixture.reset { _ in .init(status: 404, body: Data()) }
        try await assertDetection(client, room, .unknown)
        let json = guestJSON
        Fixture.reset { request in .init(status: request.url!.path.hasPrefix("/api/") ? 404 : 200, body: json) }
        let first = try await client.detect(room)
        let count = Fixture.received.count
        try await assertDetection(client, room, first)
        XCTAssertEqual(Fixture.received.count, count)
        await client.invalidate(room)
        _ = try await client.detect(room)
        XCTAssertGreaterThan(Fixture.received.count, count)
    }

    func testOneProbeTimeoutDoesNotLoseTheOtherPositiveProofAndOverallDeadlineIsBounded() async throws {
        let json = guestJSON
        Fixture.reset { request in .init(body: json, hold: request.url!.path.hasPrefix("/api/")) }
        let start = Date()
        try await assertDetection(detector(timeout: 0.1), room,
                                  .verified(.guest(endpoint: URL(string: "https://backend.example.test")!)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testCancellationDoesNotProduceACachedResult() async throws {
        Fixture.reset { _ in .init(body: Data(), hold: true) }
        let client = detector(timeout: 2)
        let task = Task { try await client.detect(room) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled discovery succeeded") } catch is CancellationError {}
        let json = guestJSON
        Fixture.reset { _ in .init(body: json) }
        try await assertDetection(client, room, .verified(.guest(endpoint: URL(string: "https://backend.example.test")!)))
    }

    func testCommunityCandidatePreservesOriginPortAndRejectsPathInjection() throws {
        let target = try JamTarget.parseCompatibleInvitation("https://other.example.test:8443/jams/team_1")
        XCTAssertEqual(target.originURL.absoluteString, "https://other.example.test:8443")
        for path in ["/jams/team%2Fother", "/jams/..", "/jams/team/", "//jams/team", "/jams/team?url=other"] {
            XCTAssertThrowsError(try JamTarget.parseCompatibleInvitation("https://other.example.test" + path))
        }
    }
}
