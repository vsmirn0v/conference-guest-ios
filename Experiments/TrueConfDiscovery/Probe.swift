import Foundation

// Diagnostic only. It requests the credentials advertised by the invitation;
// it never launches another app or connects a participant to the meeting.
@main
enum TrueConfDiscovery {
    struct ConferenceResponse: Decodable {
        let conference: Conference
    }

    struct Conference: Decodable {
        struct Permissions: Decodable { let guest_allowed: Bool }
        struct Connection: Decodable { let manual: String }
        let id: String
        let topic: String
        let permissions: Permissions
        let connect_uri: Connection
    }

    struct Result: Encodable {
        let checkedAt: String
        let invitation: String
        let conferenceID: String
        let conferenceTitle: String
        let guestsAllowed: Bool
        let admissionStatus: Int?
        let responseKeys: [String]
        let advertisedClientKeys: [String]
        let nativeDestination: String?
        let temporaryGuestLogin: Bool
        let nativeCredentialPresent: Bool
        let requestedNameApplied: Bool
        let nativeParameterKeys: [String]
        let browserURLAdvertised: Bool
        let finding: String
    }

    struct ProbeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else {
                throw ProbeError(message: "Usage: TrueConfDiscovery <HTTPS /c/ invitation> <test display name>")
            }
            let result = try await probe(
                invitation: CommandLine.arguments[1],
                name: CommandLine.arguments[2]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
        } catch {
            // Don't print transport bodies or URLs that may contain credentials.
            let message = (error as? ProbeError)?.message ?? "Native HTTP discovery failed."
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }

    static func probe(invitation: String, name: String) async throws -> Result {
        guard var origin = URLComponents(string: invitation),
              origin.scheme == "https", origin.host != nil,
              origin.user == nil, origin.password == nil,
              let invitationURL = origin.url else {
            throw ProbeError(message: "Provide a complete HTTPS invitation without embedded credentials.")
        }
        let segments = origin.path.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count == 2, segments[0] == "c", !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProbeError(message: "This Online-service probe expects /c/<conference ID> and a nonempty name.")
        }
        let conferenceID = String(segments[1])
        origin.path = ""
        origin.query = nil
        origin.fragment = nil
        guard let base = origin.url else { throw ProbeError(message: "Invalid invitation origin.") }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        // Establish the same ephemeral session as the guest landing page.
        _ = try await request(session, URLRequest(url: invitationURL), origin: base)
        let eventURL = base.appendingPathComponent("api/0.1/events").appendingPathComponent(conferenceID)
        let (metadata, metadataStatus) = try await request(session, URLRequest(url: eventURL), origin: base)
        guard metadataStatus == 200 else { throw ProbeError(message: "Conference metadata returned HTTP \(metadataStatus).") }
        let conference = try JSONDecoder().decode(ConferenceResponse.self, from: metadata).conference
        guard conference.id == conferenceID else { throw ProbeError(message: "Returned conference identity does not match the invitation.") }

        var root: [String: Any] = [:]
        var client: [String: Any] = [:]
        var status: Int?
        if conference.permissions.guest_allowed {
            let joinURL = eventURL.appendingPathComponent("connect/guest")
            var join = URLRequest(url: joinURL)
            join.httpMethod = "POST"
            join.setValue("application/json", forHTTPHeaderField: "Content-Type")
            join.setValue("application/json", forHTTPHeaderField: "Accept")
            join.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
            let (admission, admissionStatus) = try await request(session, join, origin: base)
            status = admissionStatus
            guard admissionStatus == 200 else { throw ProbeError(message: "Guest admission returned HTTP \(admissionStatus).") }
            guard let decoded = try JSONSerialization.jsonObject(with: admission) as? [String: Any],
                  let advertised = decoded["client"] as? [String: Any] else {
                throw ProbeError(message: "Unrecognized guest-admission response.")
            }
            root = decoded
            client = advertised
        }

        // TrueConf's command is an opaque native protocol, not a WebRTC URL.
        let command = client["installed"] as? String
        let parts = command?.split(separator: "&", omittingEmptySubsequences: false) ?? []
        var parameters: [String: String] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 {
                parameters[String(pair[0])] = String(pair[1]).removingPercentEncoding ?? String(pair[1])
            }
        }
        let nativeDestination = parts.first.map(String.init)?.removingPercentEncoding
        let login = parameters["login"] ?? ""
        let browserURL = (client["web"] as? String) ?? (client["web_url"] as? String)
        let hasBrowser = browserURL.flatMap(URL.init(string:)).map { $0.scheme == "https" } ?? false

        return Result(
            checkedAt: ISO8601DateFormatter().string(from: Date()),
            invitation: base.appendingPathComponent("c").appendingPathComponent(conferenceID).absoluteString,
            conferenceID: conference.id,
            conferenceTitle: conference.topic,
            guestsAllowed: conference.permissions.guest_allowed,
            admissionStatus: status,
            responseKeys: root.keys.sorted(),
            advertisedClientKeys: client.keys.sorted(),
            nativeDestination: nativeDestination,
            temporaryGuestLogin: parameters["templogin"] == "1",
            nativeCredentialPresent: parameters["password"]?.isEmpty == false,
            requestedNameApplied: login.hasPrefix("*guest*") && String(login.dropFirst("*guest*".count)) == name,
            nativeParameterKeys: parameters.keys.sorted(),
            browserURLAdvertised: hasBrowser,
            finding: !conference.permissions.guest_allowed ? "Guest access is not advertised."
                : hasBrowser ? "A browser URL is advertised; native WebRTC compatibility still requires media validation."
                : "Only native-client admission is advertised. No WebRTC media connection has been established."
        )
    }

    static func request(_ session: URLSession, _ request: URLRequest, origin: URL) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == origin.scheme,
              http.url?.host == origin.host,
              http.url?.port == origin.port,
              data.count <= 1_048_576 else {
            throw ProbeError(message: "Unexpected origin, response type or response size.")
        }
        return (data, http.statusCode)
    }
}
