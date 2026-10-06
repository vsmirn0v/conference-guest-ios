import Foundation

/// Resolves a deployment's API host from the HTTPS origin in the invitation.
/// The origin's TLS identity is the trust anchor for its published service URL.
public struct ConferenceEndpointResolver {
    private let session: URLSession
    private let serviceName: String

    public init(serviceName: String, session: URLSession = .shared) {
        self.serviceName = serviceName
        self.session = session
    }

    public func resolve(for target: JoinTarget) async throws -> URL {
        var components = URLComponents(url: target.originURL, resolvingAgainstBaseURL: false)
        components?.path = "/.well-known/s2b-services.json"
        guard let discoveryURL = components?.url else {
            throw EndpointDiscoveryError.invalidDiscovery
        }
        var request = URLRequest(url: discoveryURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        let (data, http) = try await BoundedHTTP.load(request, session: session, maximumBytes: 65_536)
        return try Self.endpoint(in: data, response: http, origin: target.originURL, serviceName: serviceName)
    }

    static func endpoint(in data: Data, response http: HTTPURLResponse, origin: URL, serviceName: String) throws -> URL {
        guard http.statusCode == 200,
              http.url?.scheme?.lowercased() == "https",
              http.url?.host?.lowercased() == origin.host?.lowercased(),
              (http.url?.port ?? 443) == (origin.port ?? 443),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let service = document[serviceName] as? [String: Any],
              let serverURL = service["serverUrl"] as? String,
              let endpoint = URLComponents(string: serverURL),
              endpoint.scheme?.lowercased() == "https",
              endpoint.host != nil,
              endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil,
              let url = endpoint.url else {
            throw EndpointDiscoveryError.invalidDiscovery
        }
        return url
    }
}

public enum EndpointDiscoveryError: LocalizedError {
    case invalidDiscovery

    public var errorDescription: String? {
        CoreL("This jam link did not provide a valid connection endpoint.")
    }
}
