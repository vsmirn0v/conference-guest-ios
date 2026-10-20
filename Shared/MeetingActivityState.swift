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
