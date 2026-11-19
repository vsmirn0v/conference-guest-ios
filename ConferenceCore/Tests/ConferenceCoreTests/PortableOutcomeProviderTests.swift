import Foundation
import XCTest
@testable import ConferenceCore

final class PortableOutcomeProviderTests: XCTestCase {
    func testOpenAISummaryUsesCurrentCompletionLimitWithoutSamplingOverride() {
        let body = PortableOutcomeService.requestBody(messages: [], model: "gpt-5.4-mini", provider: .openAI)
        XCTAssertEqual(body["model"] as? String, "gpt-5.4-mini")
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 2_000)
        XCTAssertNil(body["max_tokens"])
        XCTAssertNil(body["temperature"])

        let custom = PortableOutcomeService.requestBody(messages: [], model: "custom-model", provider: .custom)
        XCTAssertEqual(custom["max_tokens"] as? Int, 2_000)
        XCTAssertNil(custom["max_completion_tokens"])
    }

    func testHTTPErrorKeepsOnlySafeProviderDetails() {
        let body = Data(#"{"error":{"code":"unsupported_parameter","param":"max_tokens","message":"secret meeting content"}}"#.utf8)
        let error = PortableOutcomeService.httpError(status: 400, data: body)
        XCTAssertEqual(error, .http(status: 400, code: "unsupported_parameter", parameter: "max_tokens"))
        XCTAssertFalse(error.localizedDescription.contains("secret meeting content"))

        let unsafe = Data(#"{"error":{"code":"secret-token","param":"secret-param"}}"#.utf8)
        XCTAssertEqual(
            PortableOutcomeService.httpError(status: 403, data: unsafe),
            .http(status: 403, code: "other", parameter: "other")
        )
    }

    func testModelsUseSelectedProvidersEndpointAndSharedRanking() async throws {
        let configuration = PortableOutcomeConfiguration(providerKind: .openAI, baseURL: "https://old.example.invalid/v1")
        XCTAssertEqual(configuration.endpoint?.absoluteString, "https://api.openai.com/v1/chat/completions")
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [CatalogFixture.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }

        let models = try await ProviderModelCatalog.fetch(configuration: configuration, key: "fixture-key", session: session)
        XCTAssertEqual(models.map(\.id), ["gpt-5.4-mini", "audio-model"])
        XCTAssertEqual(models.first?.contextLength, 400_000)
        XCTAssertEqual(ProviderModelCatalog.filter(models, query: "MINI gpt").map(\.id), ["gpt-5.4-mini"])
    }
}

private final class CatalogFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.absoluteString == "https://api.openai.com/v1/models",
              request.httpMethod == "GET",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Data(#"""
        {"data":[{"id":"audio-model","supported_parameters":[]},
                 {"id":"gpt-5.4-mini","context_length":400000,"supported_parameters":["response_format"]},
                 {"id":"gpt-5.4-mini"}]}
        """#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
