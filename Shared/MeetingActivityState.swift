import ConferenceCore
import Foundation

/// Only presentation data crosses into the widget. No invitation or participant identity.
struct MeetingActivityState: Codable, Hashable, Sendable {
    enum Connection: String, Codable, Sendable { case connected, reconnecting, paused, otherCall }
    enum Microphone: String, Codable, Sendable { case muted, on, paused, unknown }
    var startedAt: Date
    var connection: Connection
    var microphone: Microphone
    var title: String?
    var route: String?
    var additionalMeetingCount: Int = 0

    init(startedAt: Date,
         connection: Connection,
         microphone: Microphone,
         title: String?,
         route: String?,
         additionalMeetingCount: Int = 0) {
        self.startedAt = startedAt
        self.connection = connection
        self.microphone = microphone
        self.title = title
        self.route = route
        self.additionalMeetingCount = max(0, additionalMeetingCount)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        connection = try container.decode(Connection.self, forKey: .connection)
        microphone = try container.decode(Microphone.self, forKey: .microphone)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        route = try container.decodeIfPresent(String.self, forKey: .route)
        additionalMeetingCount = max(0, try container.decodeIfPresent(Int.self, forKey: .additionalMeetingCount) ?? 0)
    }

    func microphoneSymbol(stale: Bool) -> String {
        guard !stale else { return "questionmark.circle" }
        switch microphone {
        case .muted: return "mic.slash.fill"
        case .on: return "mic.fill"
        case .paused: return "pause.circle"
        case .unknown: return "questionmark.circle"
        }
    }
    func microphoneLabel(stale: Bool) -> String {
        guard !stale else { return L("Microphone status unavailable") }
        switch microphone {
        case .muted: return L("Mic off")
        case .on: return L("Mic on")
        case .paused: return L("Mic paused")
        case .unknown: return L("Microphone status unavailable")
        }
    }
    func connectionLabel(stale: Bool) -> String {
        guard !stale else { return L("Open to check meeting") }
        switch connection {
        case .connected: return L("Connected")
        case .reconnecting: return L("Reconnecting…")
        case .paused: return L("Meeting paused")
        case .otherCall: return L("Paused for another call")
        }
    }
}

struct MeetingActivitySnapshot: Equatable {
    let sessionID: UUID
    var state: MeetingActivityState
    var openURL: URL {
        URL(string: "conferenceguest://active-meeting/" + sessionID.uuidString)!
    }
    static func sessionID(from url: URL) -> UUID? {
        guard url.scheme == "conferenceguest", url.host == "active-meeting",
              url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2 else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.2, *)
struct MeetingActivityAttributes: ActivityAttributes {
    typealias ContentState = MeetingActivityState
    let sessionID: UUID
}
#endif
