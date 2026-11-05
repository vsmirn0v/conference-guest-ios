import Foundation

struct JudgeResult: Sendable {
    var verdict: AttentionVerdict
    var latency: TimeInterval
}

protocol AttentionJudge: Sendable {
    func judge(_ request: JudgeRequest) async throws -> JudgeResult
}

struct ReplyResult: Sendable {
    var draft: ReplyDraft
    var latency: TimeInterval
}

/// Drafts the chat reply or reaction a card offers; nothing is sent by it.
protocol ReplyWriter: Sendable {
    func draft(_ request: ReplyRequest) async throws -> ReplyResult
}

enum AttentionJudgeError: LocalizedError, Equatable {
    /// `message` is the provider's own explanation, when it sent one.
    case notConfigured, missingKey, unauthorized(String?), rateLimited(String?), quota(String?), http(Int, String?)
    case transport, emptyAnswer, refused, verdict(AttentionVerdictError)
    var errorDescription: String? {
        switch self {
        case .notConfigured: L("Set the judge's address and model in Settings → Intelligence.")
        case .missingKey: L("Add an API key in Settings → Intelligence.")
        case .unauthorized(let message): Self.with(L("The provider rejected the API key. Check it in Settings → Intelligence."), message)
        case .rateLimited(let message): Self.with(L("The provider is limiting requests. The judge will try again shortly."), message)
        case .quota(let message): Self.with(L("The provider account has no credit or quota left for this key."), message)
        case .http(let code, let message): Self.with(L("The provider answered with error %ld.", code), message)
        case .transport: L("The provider could not be reached.")
        case .emptyAnswer: L("The provider returned no answer.")
        case .refused: L("The model declined to answer.")
        case .verdict(let error): error.errorDescription
        }
    }
    private static func with(_ text: String, _ message: String?) -> String {
        guard let message = message?.trimmed, !message.isEmpty else { return text }
        return text + " " + L("Provider says: %@", String(message.prefix(240)))
    }
    /// Worth one more attempt after a short wait. Quota and key errors are not.
    var retryable: Bool {
        switch self { case .rateLimited, .transport, .emptyAnswer: true; case .http(let code, _): code >= 500; default: false }
    }

    /// Maps a non-success HTTP answer, reading OpenAI-style `{"error": {"message", "code", "type"}}`.
    static func from(status: Int, body: Data) -> AttentionJudgeError {
        let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"]
        let object = error as? [String: Any]
        let message = object?["message"] as? String ?? error as? String
        let code = object?["code"] as? String ?? object?["type"] as? String
        switch status {
        case 401, 403: return .unauthorized(message)
        case 402: return .quota(message)
        case 429: return code == "insufficient_quota" ? .quota(message) : .rateLimited(message)
        default: return .http(status, message)
        }
    }
}

/// Any OpenAI-compatible chat completions endpoint with JSON-schema output.
/// The same provider judges meetings and drafts replies.
struct OpenAIChatJudge: AttentionJudge, ReplyWriter {
    let provider: AttentionProvider
    let key: String?
    var session: URLSession = .shared
    var timeout: TimeInterval = 20
    var retryDelays: [TimeInterval] = [1, 3]

    func judge(_ request: JudgeRequest) async throws -> JudgeResult {
        try await judge(messages: AttentionPrompt.messages(request), window: request.window)
    }

    /// Judges saved messages again, as the model comparison does.
    func judge(messages: [[String: String]], window: AttentionWindow) async throws -> JudgeResult {
        let (content, latency) = try await complete(Self.body(messages: messages, model: provider.model.trimmed,
                                                              name: AttentionPrompt.schemaName, schema: AttentionPrompt.schema))
        do { return .init(verdict: try AttentionPrompt.verdict(from: content, window: window), latency: latency) }
        catch let error as AttentionVerdictError { throw AttentionJudgeError.verdict(error) }
    }

    func draft(_ request: ReplyRequest) async throws -> ReplyResult {
        guard !request.judge.replyChannels.isEmpty else { throw ReplyDraftError.unavailable }
        return try await draft(messages: ReplyPrompt.messages(request), channels: request.judge.replyChannels)
    }

    func draft(messages: [[String: String]], channels: ReplyChannels) async throws -> ReplyResult {
        let (content, latency) = try await complete(Self.body(messages: messages, model: provider.model.trimmed,
                                                              name: ReplyPrompt.schemaName, schema: ReplyPrompt.schema(channels)))
        return .init(draft: try ReplyPrompt.draft(from: content, channels: channels), latency: latency)
    }

    static func body(messages: [[String: String]], model: String, name: String, schema: [String: Any]) -> [String: Any] {
        ["model": model, "messages": messages,
         "response_format": ["type": "json_schema", "json_schema": ["name": name, "strict": true, "schema": schema]]]
    }

    static func body(_ request: JudgeRequest, model: String) -> [String: Any] {
        ["model": model, "messages": AttentionPrompt.messages(request),
         "response_format": ["type": "json_schema",
                             "json_schema": ["name": AttentionPrompt.schemaName, "strict": true, "schema": AttentionPrompt.schema]]]
    }

    static func replyBody(_ request: ReplyRequest, model: String) -> [String: Any] {
        ["model": model, "messages": ReplyPrompt.messages(request),
         "response_format": ["type": "json_schema", "json_schema": ["name": ReplyPrompt.schemaName, "strict": true,
                                                                   "schema": ReplyPrompt.schema(request.judge.replyChannels)]]]
    }

    /// The model's answer text and how long the successful attempt took.
    private func complete(_ object: [String: Any]) async throws -> (String, TimeInterval) {
        guard let endpoint = provider.endpoint, !provider.model.trimmed.isEmpty else { throw AttentionJudgeError.notConfigured }
        if provider.needsKey && (key ?? "").isEmpty { throw AttentionJudgeError.missingKey }
        let body = try JSONSerialization.data(withJSONObject: object)
        var attempt = 0
        while true {
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let content = try await send(body, to: endpoint)
                return (content, ProcessInfo.processInfo.systemUptime - started)
            } catch let error as AttentionJudgeError where error.retryable && attempt < retryDelays.count {
                try await Task.sleep(for: .seconds(retryDelays[attempt])); attempt += 1
            }
        }
    }

    private func send(_ body: Data, to endpoint: URL) async throws -> String {
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
        guard (200..<300).contains(status) else { throw AttentionJudgeError.from(status: status, body: data) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else { throw AttentionJudgeError.emptyAnswer }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw AttentionJudgeError.refused }
        guard let content = message["content"] as? String, !content.trimmed.isEmpty else { throw AttentionJudgeError.emptyAnswer }
        return content
    }
}

/// One model a provider offers, from its `/models` list.
struct AttentionModelInfo: Identifiable, Equatable, Sendable {
    let id: String
    var name: String?
    var contextLength: Int?
    /// Known only when the provider lists supported parameters (OpenRouter does).
    var structuredOutput: Bool?
    /// US dollars per million prompt tokens, when the provider lists prices.
    var promptPrice: Double?
}

enum AttentionModelCatalog {
    /// Lists the provider's models from `GET {address}/models`, the
    /// OpenAI-compatible catalog every supported provider serves.
    static func fetch(_ provider: AttentionProvider, key: String?, session: URLSession = .shared) async throws -> [AttentionModelInfo] {
        guard let chat = provider.endpoint else { throw AttentionJudgeError.notConfigured }
        let url = chat.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("models")
        var request = URLRequest(url: url, timeoutInterval: 20)
        if let key, !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AttentionJudgeError.transport }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AttentionJudgeError.from(status: status, body: data) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (object["data"] ?? object["models"]) as? [[String: Any]] else { throw AttentionJudgeError.emptyAnswer }
        return parse(items)
    }

    static func parse(_ items: [[String: Any]]) -> [AttentionModelInfo] {
        var seen = Set<String>()
        let models: [AttentionModelInfo] = items.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { return nil }
            let parameters = item["supported_parameters"] as? [String]
            let price = ((item["pricing"] as? [String: Any])?["prompt"]).flatMap { ($0 as? String).flatMap(Double.init) ?? $0 as? Double }
            return .init(id: id, name: item["name"] as? String, contextLength: item["context_length"] as? Int,
                         structuredOutput: parameters.map { $0.contains("structured_outputs") || $0.contains("response_format") },
                         promptPrice: price.map { $0 * 1_000_000 })
        }
        return models.sorted { lhs, rhs in
            let left = lhs.structuredOutput ?? true, right = rhs.structuredOutput ?? true
            return left == right ? lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending : left
        }
    }

    /// Case- and diacritic-insensitive match on every word of the query against id and name.
    static func filter(_ models: [AttentionModelInfo], query: String) -> [AttentionModelInfo] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return models }
        return models.filter { model in
            let text = model.id + " " + (model.name ?? "")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
