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
        case .notConfigured: L("Set the judge's address and model in Settings → Assistant.")
        case .missingKey: L("Add an API key in Settings → Assistant.")
        case .unauthorized(let message): Self.with(L("The provider rejected the API key. Check it in Settings → Assistant."), message)
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
    var diagnosticCode: String {
        switch self {
        case .notConfigured: "notConfigured"
        case .missingKey: "missingKey"
        case .unauthorized: "unauthorized"
        case .rateLimited: "rateLimited"
        case .quota: "quota"
        case .http: "http"
        case .transport: "transport"
        case .emptyAnswer: "emptyAnswer"
        case .refused: "refused"
        case .verdict: "verdict"
        }
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
        // Rapid-MLX: the model's answer broke the strict schema; not worth retrying as is.
        case 422 where code == "json_schema_violation": return .verdict(.malformed)
        case 429: return code == "insufficient_quota" ? .quota(message) : .rateLimited(message)
        default: return .http(status, message)
        }
    }
}

extension AttentionProvider {
    /// The client that judges and drafts for this provider.
    func client(key: String?) -> any AttentionJudge & ReplyWriter & MomentSummarizer & MeetingOutcomeWriter {
        kind == .apple ? AppleOnDeviceJudge() : OpenAIChatJudge(provider: self, key: key)
    }
}

/// Any OpenAI-compatible chat completions endpoint with JSON-schema output.
/// The same provider judges meetings and drafts replies.
struct OpenAIChatJudge: AttentionJudge, ReplyWriter, MomentSummarizer, MeetingOutcomeWriter {
    let provider: AttentionProvider
    let key: String?
    var session: URLSession = .shared
    var timeout: TimeInterval = 20
    var retryDelays: [TimeInterval] = [1, 3]
    var diagnoseOutcomeTransport = false

    func judge(_ request: JudgeRequest) async throws -> JudgeResult {
        try await judge(messages: AttentionPrompt.messages(request), window: request.window)
    }

    /// Judges saved messages again, as the model comparison does.
    func judge(messages: [[String: String]], window: AttentionWindow) async throws -> JudgeResult {
        let (content, latency) = try await complete(requestBody(messages: messages, name: AttentionPrompt.schemaName,
                                                                schema: AttentionPrompt.schema(for: window), hint: AttentionPrompt.jsonHint))
        do { return .init(verdict: try AttentionPrompt.verdict(from: content, window: window), latency: latency) }
        catch let error as AttentionVerdictError { throw AttentionJudgeError.verdict(error) }
    }

    func draft(_ request: ReplyRequest) async throws -> ReplyResult {
        guard !request.judge.replyChannels.isEmpty else { throw ReplyDraftError.unavailable }
        return try await draft(messages: ReplyPrompt.messages(request), channels: request.judge.replyChannels)
    }

    func draft(messages: [[String: String]], channels: ReplyChannels) async throws -> ReplyResult {
        let (content, latency) = try await complete(requestBody(messages: messages, name: ReplyPrompt.schemaName,
                                                                schema: ReplyPrompt.schema(channels), hint: ReplyPrompt.jsonHint(channels)))
        return .init(draft: try ReplyPrompt.draft(from: content, channels: channels), latency: latency)
    }

    func summarize(_ request: MomentSummaryRequest) async throws -> String {
        let (content, _) = try await complete(requestBody(messages: MomentSummaryPrompt.messages(request),
            name: MomentSummaryPrompt.schemaName, schema: MomentSummaryPrompt.schema, hint: MomentSummaryPrompt.hint))
        return try MomentSummaryPrompt.parse(content)
    }

    func outcome(_ request: MeetingOutcomeRequest) async throws -> MeetingOutcomeContent {
        // Transport failures (including timeouts, which may still be running upstream)
        // throw MeetingOutcomeFailure immediately so only empty or transient provider
        // answers retry automatically.
        var writer = self
        writer.timeout = 120
        writer.diagnoseOutcomeTransport = true
        let (parsed, _) = try await writer.complete(requestBody(messages: MeetingOutcomePrompt.messages(request),
            name: MeetingOutcomePrompt.schemaName, schema: MeetingOutcomePrompt.schema, hint: MeetingOutcomePrompt.hint)) { content in
            do { return try MeetingOutcomePrompt.parse(content) }
            catch {
                probeLog("assistant-outcome-response", ["reason": "unusableContent", "contentBytes": content.utf8.count])
                throw error
            }
        }
        return parsed
    }

    /// Providers elsewhere get the strict schema. A model on this Mac gets JSON mode with
    /// the shape in its instructions: Rapid-MLX's strict schema lengthens the prompt,
    /// loses its prompt cache and halves decode speed, and every answer is validated here anyway.
    func requestBody(messages: [[String: String]], name: String, schema: [String: Any], hint: String) -> [String: Any] {
        let model = provider.model.trimmed
        guard provider.onThisMac else { return Self.body(messages: messages, model: model, name: name, schema: schema) }
        var adjusted = messages
        if let index = adjusted.firstIndex(where: { $0["role"] == "system" }), !(adjusted[index]["content"] ?? "").contains(hint) {
            adjusted[index]["content"] = (adjusted[index]["content"] ?? "") + hint
        }
        let outputLimit = name == MeetingOutcomePrompt.schemaName ? 2000 : name == ReplyPrompt.schemaName ? 1000 : 400
        var body: [String: Any] = ["model": model, "messages": adjusted, "temperature": 0, "max_tokens": outputLimit,
                                   "response_format": ["type": "json_object"]]
        // Qwen-family models would otherwise think first; the verdict needs no reasoning pass.
        if provider.kind == .rapidMLX { body["chat_template_kwargs"] = ["enable_thinking": false] }
        return body
    }

    static func body(messages: [[String: String]], model: String, name: String, schema: [String: Any]) -> [String: Any] {
        ["model": model, "messages": messages,
         "response_format": ["type": "json_schema", "json_schema": ["name": name, "strict": true, "schema": schema]]]
    }

    static func body(_ request: JudgeRequest, model: String) -> [String: Any] {
        ["model": model, "messages": AttentionPrompt.messages(request),
         "response_format": ["type": "json_schema",
                             "json_schema": ["name": AttentionPrompt.schemaName, "strict": true, "schema": AttentionPrompt.schema(for: request.window)]]]
    }

    static func replyBody(_ request: ReplyRequest, model: String) -> [String: Any] {
        ["model": model, "messages": ReplyPrompt.messages(request),
         "response_format": ["type": "json_schema", "json_schema": ["name": ReplyPrompt.schemaName, "strict": true,
                                                                   "schema": ReplyPrompt.schema(request.judge.replyChannels)]]]
    }

    private static let outcomeSchemaMarker = "__MEETING_OUTCOME_SCHEMA__"

    static func encodeBody(_ object: [String: Any]) throws -> Data {
        var copy = object
        if var format = copy["response_format"] as? [String: Any],
           format["type"] as? String == "json_schema",
           var jsonSchema = format["json_schema"] as? [String: Any],
           jsonSchema["name"] as? String == MeetingOutcomePrompt.schemaName {
            jsonSchema["schema"] = outcomeSchemaMarker
            format["json_schema"] = jsonSchema
            copy["response_format"] = format
            var data = try JSONSerialization.data(withJSONObject: copy)
            let token = Data("\"\(outcomeSchemaMarker)\"".utf8)
            if let range = data.range(of: token) {
                data.replaceSubrange(range, with: Data(MeetingOutcomePrompt.orderedSchemaJSON.utf8))
            }
            return data
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// The model's answer text and how long the successful attempt took.
    func complete(_ object: [String: Any]) async throws -> (String, TimeInterval) {
        try await complete(object) { $0 }
    }

    func complete<T>(_ object: [String: Any], parse: (String) throws -> T) async throws -> (T, TimeInterval) {
        guard let endpoint = provider.endpoint, !provider.model.trimmed.isEmpty else { throw AttentionJudgeError.notConfigured }
        if provider.needsKey && (key ?? "").isEmpty { throw AttentionJudgeError.missingKey }
        let body = try Self.encodeBody(object)
        var attempt = 0
        while true {
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let content = try await send(body, to: endpoint, attempt: attempt)
                let value = try parse(content)
                return (value, ProcessInfo.processInfo.systemUptime - started)
            } catch let error as AttentionJudgeError where error.retryable && attempt < retryDelays.count {
                try await Task.sleep(for: .seconds(retryDelays[attempt])); attempt += 1
            }
        }
    }

    private func send(_ body: Data, to endpoint: URL, attempt: Int = 0) async throws -> String {
        // A model on this Mac may still be loading on the first call.
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: provider.onThisMac ? max(timeout, 60) : timeout)
        urlRequest.httpMethod = "POST"; urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { urlRequest.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        if provider.kind == .openRouter { urlRequest.setValue("Rock'N'Roll for Mac", forHTTPHeaderField: "X-Title") }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: urlRequest) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if diagnoseOutcomeTransport {
                let code = (error as? URLError)?.code
                probeLog("assistant-outcome-transport", ["urlErrorCode": code?.rawValue ?? 0])
                throw MeetingOutcomeFailure(transportCode: code)
            }
            throw AttentionJudgeError.transport
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AttentionJudgeError.from(status: status, body: data) }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choice = (object?["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            if let errObj = object?["error"] {
                let errCode = (errObj as? [String: Any])?["code"] as? Int ?? 502
                throw AttentionJudgeError.from(status: errCode, body: data)
            }
            if diagnoseOutcomeTransport {
                probeLog("assistant-outcome-response", ["reason": "missingChoices", "attempt": attempt, "bodyBytes": data.count])
            }
            throw AttentionJudgeError.emptyAnswer
        }
        let finishReason = choice["finish_reason"] as? String ?? ""
        if let refusal = message["refusal"] as? String, !refusal.trimmed.isEmpty {
            if diagnoseOutcomeTransport {
                probeLog("assistant-outcome-response", ["reason": "refusal", "attempt": attempt, "finishReason": finishReason])
            }
            throw AttentionJudgeError.refused
        }
        let extracted: String
        if let text = message["content"] as? String {
            extracted = text
        } else if let parts = message["content"] as? [[String: Any]] {
            extracted = parts.compactMap { part -> String? in
                let type = part["type"] as? String ?? "text"
                guard type == "text" || type == "output_text" else { return nil }
                return part["text"] as? String
            }.joined()
        } else {
            extracted = ""
        }
        guard !extracted.trimmed.isEmpty else {
            if diagnoseOutcomeTransport {
                let usage = object?["usage"] as? [String: Any]
                let completionTokens = usage?["completion_tokens"] as? Int ?? 0
                let reasoningTokens = (usage?["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0
                probeLog("assistant-outcome-response", [
                    "reason": "emptyContent", "attempt": attempt, "finishReason": finishReason,
                    "completionTokens": completionTokens, "reasoningTokens": reasoningTokens,
                ])
            }
            throw AttentionJudgeError.emptyAnswer
        }
        return extracted
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
