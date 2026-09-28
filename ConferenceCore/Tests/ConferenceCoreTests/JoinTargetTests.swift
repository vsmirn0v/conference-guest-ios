import XCTest
@testable import ConferenceCore

final class JoinTargetTests: XCTestCase {
    private let raw = "https://meeting.example.test/calls/svcavt?psw=a%2Bb%26c"

    func testInvitationDerivesRoomAndOriginFromLink() throws {
        let target = try JoinTarget.parse(raw)
        XCTAssertEqual(target.roomID, "svcavt")
        XCTAssertEqual(target.password, "a+b&c")
        XCTAssertEqual(target.originURL.absoluteString, "https://meeting.example.test")
    }

    func testRootRoomInvitationPreservesOriginCredentialsAndPath() throws {
        let invitation = "https://enterprise.example.test/team-ikc006?psw=a%2Bb%26c"
        let target = try JoinTarget.parse(invitation)
        XCTAssertEqual(target.roomID, "team-ikc006")
        XCTAssertEqual(target.password, "a+b&c")
        XCTAssertEqual(target.originURL.absoluteString, "https://enterprise.example.test")
        XCTAssertEqual(target.invitationURL.absoluteString, invitation)
        XCTAssertEqual(try JoinDestination.parse(invitation), .guest(target))

        var handoff = URLComponents(string: "conferenceguest://join")!
        handoff.queryItems = [URLQueryItem(name: "url", value: invitation)]
        XCTAssertEqual(try JoinDestination.parse(handoff.url!.absoluteString), .guest(target))
    }

    func testCustomSchemeAndOwnedUniversalLinkCarryInvitation() throws {
        var custom = URLComponents()
        custom.scheme = "conferenceguest"
        custom.host = "join"
        custom.queryItems = [URLQueryItem(name: "url", value: raw)]
        XCTAssertEqual(try JoinTarget.parse(custom.url!.absoluteString), try JoinTarget.parse(raw))

        var universal = URLComponents(string: "https://join.example.com/join")!
        universal.queryItems = [URLQueryItem(name: "url", value: raw)]
        XCTAssertEqual(try JoinTarget.parse(universal.url!.absoluteString, joinLinkHost: "join.example.com"),
                       try JoinTarget.parse(raw))
        XCTAssertThrowsError(try JoinTarget.parse(universal.url!.absoluteString,
                                                  joinLinkHost: "other.example.com"))
    }

    func testRejectsIncompleteOrUnsafeInvitations() {
        for text in [
            "http://meeting.example.test/calls/svcavt?psw=x",
            "https://person@meeting.example.test/calls/svcavt?psw=x",
            "https://meeting.example.test/calls/create",
            "https://meeting.example.test/calls/svcavt",
            "https://meeting.example.test/calls/other/path?psw=x",
            "https://meeting.example.test/calls/svcavt?psw=x&psw=y",
            "https://meeting.example.test/?psw=x",
            "https://meeting.example.test/other/svcavt?psw=x",
            "https://meeting.example.test/team-ikc006",
            "https://meeting.example.test/team-ikc006?psw=x&psw=y",
            "https://meeting.example.test/team%20ikc006?psw=x",
            "http://meeting.example.test/team-ikc006?psw=x",
            "https://person@meeting.example.test/team-ikc006?psw=x"
        ] {
            XCTAssertThrowsError(try JoinTarget.parse(text), text)
        }
    }

    func testDiscoveryUsesInvitationOriginAndRejectsInsecureResult() async throws {
        let target = try JoinTarget.parse(raw)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let resolver = ConferenceEndpointResolver(serviceName: "service", session: session)

        DiscoveryStub.response = #"{"service":{"serverUrl":"https://api.example.test"},"unrelated":{"other":true}}"#.data(using: .utf8)!
        let endpoint = try await resolver.resolve(for: target)
        XCTAssertEqual(endpoint.absoluteString, "https://api.example.test")
        XCTAssertEqual(DiscoveryStub.requestedURL?.absoluteString,
                       "https://meeting.example.test/.well-known/s2b-services.json")

        let rootTarget = try JoinTarget.parse("https://enterprise.example.test/team-ikc006?psw=x")
        let rootEndpoint = try await resolver.resolve(for: rootTarget)
        XCTAssertEqual(rootEndpoint, endpoint)
        XCTAssertEqual(DiscoveryStub.requestedURL?.absoluteString,
                       "https://enterprise.example.test/.well-known/s2b-services.json")

        DiscoveryStub.response = #"{"service":{"serverUrl":"http://api.example.test"}}"#.data(using: .utf8)!
        await XCTAssertThrowsErrorAsync(try await resolver.resolve(for: target))

        DiscoveryStub.response = #"{"service":{"serverUrl":"https://api.example.test"}}"#.data(using: .utf8)!
        DiscoveryStub.responseURL = URL(string: "https://redirect.example.test/.well-known/s2b-services.json")
        await XCTAssertThrowsErrorAsync(try await resolver.resolve(for: target))
        DiscoveryStub.responseURL = nil
    }
}

private final class DiscoveryStub: URLProtocol {
    static var response = Data()
    static var requestedURL: URL?
    static var responseURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestedURL = request.url
        let response = HTTPURLResponse(url: Self.responseURL ?? request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error")
    } catch {}
}
