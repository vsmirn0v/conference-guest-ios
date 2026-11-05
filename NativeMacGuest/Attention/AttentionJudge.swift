import Foundation

struct JudgeResult: Sendable {
    var verdict: AttentionVerdict
    var latency: TimeInterval
}

protocol AttentionJudge: Sendable {
    func judge(_ request: JudgeRequest) async throws -> JudgeResult
}

enum AttentionJudgeError: LocalizedError, Equatable {
    case notConfigured, missingKey, unauthorized, rateLimited, http(Int), transport, emptyAnswer, refused, verdict(AttentionVerdictError)
    var errorDescription: String? {
        switch self {
        case .notConfigured: L("Set the judge's address and model in Settings → Intelligence.")
        case .missingKey: L("Add an API key in Settings → Intelligence.")
        case .unauthorized: L("The provider rejected the API key. Check it in Settings → Intelligence.")
        case .rateLimited: L("The provider is limiting requests. The judge will try again shortly.")
        case .http(let code): L("The provider answered with error %ld.", code)
        case .transport: L("The provider could not be reached.")
        case .emptyAnswer: L("The provider returned no answer.")
        case .refused: L("The model declined to answer.")
        case .verdict(let error): error.errorDescription
        }
    }
    /// Worth one more attempt after a short wait.
    var retryable: Bool {
        switch self { case .rateLimited, .transport, .emptyAnswer: true; case .http(let code): code >= 500; default: false }
    }
}

/// Any OpenAI-compatible chat completions endpoint with JSON-schema output.
struct OpenAIChatJudge: AttentionJudge {
    let provider: AttentionProvider
    let key: String?
    var session: URLSession = .shared
    var timeout: TimeInterval = 20
    var retryDelays: [TimeInterval] = [1, 3]

    func judge(_ request: JudgeRequest) async throws -> JudgeResult {
        guard let endpoint = provider.endpoint, !provider.model.trimmed.isEmpty else { throw AttentionJudgeError.notConfigured }
        if provider.needsKey && (key ?? "").isEmpty { throw AttentionJudgeError.missingKey }
        let body = try JSONSerialization.data(withJSONObject: Self.body(request, model: provider.model.trimmed))
        var attempt = 0
        while true {
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let verdict = try await send(body, to: endpoint, window: request.window)
                return .init(verdict: verdict, latency: ProcessInfo.processInfo.systemUptime - started)
            } catch let error as AttentionJudgeError where error.retryable && attempt < retryDelays.count {
                try await Task.sleep(for: .seconds(retryDelays[attempt])); attempt += 1
            }
        }
    }

    static func body(_ request: JudgeRequest, model: String) -> [String: Any] {
        ["model": model, "messages": AttentionPrompt.messages(request),
         "response_format": ["type": "json_schema",
                             "json_schema": ["name": AttentionPrompt.schemaName, "strict": true, "schema": AttentionPrompt.schema]]]
    }

    private func send(_ body: Data, to endpoint: URL, window: AttentionWindow) async throws -> AttentionVerdict {
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"; urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { urlRequest.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        if provider.kind == .openRouter { urlRequest.setValue("Rock'N'Roll for Mac", forHTTPHeaderField: "X-Title") }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: urlRequest) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AttentionJudgeError.transport }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: break
        case 401, 403: throw AttentionJudgeError.unauthorized
        case 429: throw AttentionJudgeError.rateLimited
        default: throw AttentionJudgeError.http(status)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else { throw AttentionJudgeError.emptyAnswer }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw AttentionJudgeError.refused }
        guard let content = message["content"] as? String, !content.trimmed.isEmpty else { throw AttentionJudgeError.emptyAnswer }
        do { return try AttentionPrompt.verdict(from: content, window: window) }
        catch let error as AttentionVerdictError { throw AttentionJudgeError.verdict(error) }
    }
}
