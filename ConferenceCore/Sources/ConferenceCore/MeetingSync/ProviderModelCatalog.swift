import Foundation

public struct ProviderModelInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let contextLength: Int?
    public let structuredOutput: Bool?
    /// US dollars per million input tokens, when the provider lists prices.
    public let promptPrice: Double?
}

public enum ProviderModelCatalog {
    public static func fetch(
        configuration: PortableOutcomeConfiguration, key: String?, session: URLSession = .shared
    ) async throws -> [ProviderModelInfo] {
        guard let url = configuration.modelCatalogEndpoint else { throw PortableOutcomeError.notConfigured }
        if configuration.providerKind.needsKey && (key?.isEmpty != false) {
            throw PortableOutcomeError.missingKey
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        if let key, !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let (data, response): (Data, URLResponse)
        if session === URLSession.shared {
            (data, response) = try await BoundedHTTP.load(request, session: session, maximumBytes: 8_388_608)
        } else {
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw PortableOutcomeError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw PortableOutcomeService.httpError(status: http.statusCode, data: data)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (object["data"] ?? object["models"]) as? [[String: Any]] else {
            throw PortableOutcomeError.invalidResponse
        }
        return parse(items)
    }

    public static func parse(_ items: [[String: Any]]) -> [ProviderModelInfo] {
        var seen = Set<String>()
        let models: [ProviderModelInfo] = items.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { return nil }
            let parameters = item["supported_parameters"] as? [String]
            let rawPrice = (item["pricing"] as? [String: Any])?["prompt"]
            let price = (rawPrice as? String).flatMap(Double.init) ?? rawPrice as? Double
            return ProviderModelInfo(
                id: id, name: item["name"] as? String, contextLength: item["context_length"] as? Int,
                structuredOutput: parameters.map { $0.contains("structured_outputs") || $0.contains("response_format") },
                promptPrice: price.map { $0 * 1_000_000 }
            )
        }
        return models.sorted { lhs, rhs in
            let left = lhs.structuredOutput ?? true
            let right = rhs.structuredOutput ?? true
            return left == right ? lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending : left
        }
    }

    public static func filter(_ models: [ProviderModelInfo], query: String) -> [ProviderModelInfo] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return models }
        return models.filter { model in
            let text = model.id + " " + (model.name ?? "")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
