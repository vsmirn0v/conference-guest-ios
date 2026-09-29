import XCTest
@testable import ConferenceCore

final class BoundedHTTPTests: XCTestCase {
    final class Fixture: URLProtocol {
        static var handler: ((URLRequest) -> (Int, [String: String], Data))!
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let (status, headers, data) = Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Fixture.self]
        return URLSession(configuration: config)
    }
    func testExactBudgetAndChunkedOversize() async throws {
        let request = URLRequest(url: URL(string: "https://fixture.example.test/data")!)
        Fixture.handler = { _ in (200, [:], Data(repeating: 65, count: 64)) }
        let data = try await BoundedHTTP.load(request, session: session, maximumBytes: 64).0
        XCTAssertEqual(data.count, 64)
        Fixture.handler = { _ in (200, [:], Data(repeating: 65, count: 65)) }
        do { _ = try await BoundedHTTP.load(request, session: session, maximumBytes: 64); XCTFail("Oversize accepted") }
        catch { XCTAssertEqual(error as? BoundedHTTPError, .oversizedBody) }
        Fixture.handler = { _ in (200, ["Content-Length": "10000"], Data()) }
        do { _ = try await BoundedHTTP.load(request, session: session, maximumBytes: 64); XCTFail("Oversize accepted") }
        catch { XCTAssertEqual(error as? BoundedHTTPError, .oversizedBody) }
    }
    func testRedirectPolicyPreservesOriginAndPort() {
        let origin = URL(string: "https://meeting.example.test:443/start")!
        XCTAssertTrue(SameOriginRedirects.matches(URL(string: "https://MEETING.example.test/next")!, origin))
        for url in ["http://meeting.example.test/next", "https://other.example.test/next",
                    "https://meeting.example.test:444/next", "https://user@meeting.example.test/next"] {
            XCTAssertFalse(SameOriginRedirects.matches(URL(string: url)!, origin))
        }
    }
    func testCancellationAndInvalidOrigin() async {
        Fixture.handler = { _ in (200, [:], Data(repeating: 65, count: 10000)) }
        let client = session
        let task = Task { try await BoundedHTTP.load(URLRequest(url: URL(string: "https://fixture.example.test/data")!),
                                                   session: client, maximumBytes: 12000) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request succeeded") } catch {}
        do { _ = try await BoundedHTTP.load(URLRequest(url: URL(string: "http://fixture.example.test/data")!),
                                           session: client, maximumBytes: 12000); XCTFail("HTTP accepted") } catch {}
    }
}
