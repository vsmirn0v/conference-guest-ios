import ConferenceCore
import XCTest
@testable import RockNRoll

final class JamServiceTests: XCTestCase {
    final class Response: URLProtocol {
        static var status = 400
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    func testValidationRateLimitAndServiceFailuresHaveActionableErrors() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Response.self]
        let service = JamService(session: URLSession(configuration: config))
        let target = try JamTarget.parse("https://rock.glowsoft.ru/jams/test")
        for (status, text) in [(400, "name"), (429, "Wait"), (503, "temporarily")] {
            Response.status = status
            do { _ = try await service.join(target, name: "Ani"); XCTFail("Failure accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription) }
        }
    }
}
