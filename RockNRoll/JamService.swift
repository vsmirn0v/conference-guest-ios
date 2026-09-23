import ConferenceCore
import Foundation

struct JamCredentials: Decodable {
    let serverURL: URL
    let participantToken: String
    let jam: JamDetails

    enum CodingKeys: String, CodingKey {
        case serverURL = "server_url"
        case participantToken = "participant_token"
        case jam
    }
}

struct JamDetails: Decodable {
    let id: String
    let title: String
    let community: String
    let description: String
}

struct JamService {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func join(_ target: JamTarget, name: String) async throws -> JamCredentials {
        var components = URLComponents(url: target.originURL, resolvingAgainstBaseURL: false)
        components?.path = "/api/jams/\(target.jamID)/join"
        guard let url = components?.url else { throw JamServiceError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(["name": name])
        let data: Data
        let response: URLResponse
        var result: (Data, URLResponse)?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                result = try await session.data(for: request)
                break
            } catch let error as URLError where attempt < 2 &&
                [.networkConnectionLost, .timedOut, .cannotConnectToHost].contains(error.code) {
                try await Task.sleep(for: .milliseconds(attempt == 0 ? 400 : 1_200))
            }
        }
        guard let received = result else { throw JamServiceError.invalidResponse }
        (data, response) = received
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.url?.scheme?.lowercased() == "https",
              http.url?.host?.lowercased() == target.originURL.host?.lowercased(),
              data.count <= 16_384,
              let credentials = try? JSONDecoder().decode(JamCredentials.self, from: data),
              credentials.serverURL.scheme?.lowercased() == "wss",
              credentials.serverURL.host?.lowercased() == target.originURL.host?.lowercased(),
              credentials.serverURL.user == nil,
              credentials.serverURL.password == nil,
              credentials.serverURL.query == nil,
              credentials.serverURL.fragment == nil,
              credentials.jam.id == target.jamID,
              (16...8_192).contains(credentials.participantToken.utf8.count) else {
            throw JamServiceError.invalidResponse
        }
        return credentials
    }
}

enum JamServiceError: LocalizedError {
    case invalidResponse
    var errorDescription: String? { "This jam could not provide a secure connection." }
}
