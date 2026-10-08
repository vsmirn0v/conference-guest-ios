import XCTest
@testable import ConferenceCore

final class TrueConfTargetTests: XCTestCase {
    func testFormalInvitationDoesNotGuessItsEngineFromTheHost() throws {
        let text = "https://custom.example.test:8443/c/room?password=secret"
        let target = try TrueConfTarget.parse(text)
        XCTAssertEqual(target.roomID, "room"); XCTAssertEqual(target.originURL.absoluteString, "https://custom.example.test:8443")
        guard case .guest = try JoinDestination.parse(text) else { return XCTFail("Formal syntax must be verified by API discovery") }
        XCTAssertFalse(target.descriptionURL.query?.contains("secret") == true)
        for value in ["http://server.test/c/id", "https://user:pass@server.test/c/id", "https://server.test/c/a/b", "https://server.test/c", "https://server.test/c/a%2Fb"] {
            XCTAssertThrowsError(try TrueConfTarget.parse(value))
        }
    }
    func testCapabilityRequiresMatchingRoomAndSameOriginBrowser() throws {
        let target = try TrueConfTarget.parse("https://server.test:8443/c/id")
        func data(id: String = "id", browser: String = "https://server.test:8443/webrtc/id", allowed: Bool = true) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["conference": ["id": id, "web_client_url": browser, "allow_guests": allowed]])
        }
        XCTAssertTrue(target.supportsBrowser(in: try data()))
        for value in [try data(id: "other"), try data(browser: "https://server.test/webrtc/id"), try data(browser: "https://evil.test/webrtc/id"), try data(allowed: false)] {
            XCTAssertFalse(target.supportsBrowser(in: value))
        }
        XCTAssertFalse(target.supportsBrowser(in: Data("{}".utf8)))
        XCTAssertNil(MeetingEngineKind.trueconf.persistenceHint, "Older cloud clients must still decode history")
    }
    func testDiscoveryChecksRoomSpecificBrowserCapabilityWithoutCreatingGuestCredentials() async throws {
        let target = try TrueConfTarget.parse("https://server.test/c/one?psw=secret")
        let response = try JSONSerialization.data(withJSONObject: ["conference": ["id": "one", "web_client_url": "https://server.test/webrtc/one", "allow_guests": true]])
        MeetingEngineDetectorTests.Fixture.reset { request in .init(status: request.url?.path == target.descriptionURL.path ? 200 : 404, body: response) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MeetingEngineDetectorTests.Fixture.self]
        let detector = MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: config))
        let found = try await detector.detect(target.invitationURL)
        XCTAssertEqual(found, .verified(.trueconf))
        XCTAssertFalse(MeetingEngineDetectorTests.Fixture.received.contains { $0.url?.path == "/api/v4/software/clients" })
        XCTAssertFalse(MeetingEngineDetectorTests.Fixture.received.contains { $0.url?.query?.contains("secret") == true })
        let other = try await detector.detect(URL(string: "https://server.test/c/two")!)
        XCTAssertEqual(other, .unknown, "Capability must not leak to another room on the same host")
    }
}
