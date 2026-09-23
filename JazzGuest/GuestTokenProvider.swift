import Foundation
import JazzSDK

final class GuestTokenProvider: JazzConferenceTokenProvider, @unchecked Sendable {
    private let endpoint: URL?
    private let identity: GuestIdentity

    init(endpoint: URL?, identity: GuestIdentity) {
        self.endpoint = endpoint
        self.identity = identity
    }

    func provideToken(completion: @escaping AuthTokenCompletion) {
        Task {
            let result = await token()
            completion(result)
        }
    }

    func token() async -> Result<String, ConferenceTokenError> {
        guard let endpoint,
              endpoint.scheme == "https" ||
              (endpoint.scheme == "http" && ["127.0.0.1", "localhost"].contains(endpoint.host ?? "")),
              endpoint.user == nil, endpoint.password == nil else {
            return .failure(.invalidToken)
        }
        let name = identity.userName() ?? "Guest"
        let body = ["guestId": identity.id.uuidString, "displayName": name]
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = json["token"] as? String, !value.isEmpty else {
                return .failure(.invalidToken)
            }
            return .success(value)
        } catch {
            return .failure(.invalidToken)
        }
    }
}
