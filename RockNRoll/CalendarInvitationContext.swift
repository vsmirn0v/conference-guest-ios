import ConferenceCore
import Foundation

extension CalendarMeetingStore {
    /// Shared by scene refreshes and cold notification actions; no media engine is initialized.
    func configureInvitationContext(history: RoomHistoryStore, preferences: UserDefaults) {
        knownOrigins = {
            var origins = Set(history.rooms.compactMap { (try? JoinTarget.parse($0.joinURL.absoluteString))?.originURL.absoluteString.lowercased() })
            let website = preferences.string(forKey: "guestWebsiteOrigin") ?? ""
            let site = website.hasPrefix("https://") ? website : "https://" + website
            if let url = URL(string: site), url.host != nil {
                origins.insert(url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased())
            }
            return origins
        }
        knownEngine = { history.matching($0)?.engine }
        aliases = {
            var aliases: [String: URL] = [:], ambiguous: Set<String> = []
            for room in history.rooms {
                guard let name = room.alias?.lowercased(), name.contains("."),
                      let host = URL(string: "https://" + name)?.host, host == name else { continue }
                if aliases[host] != nil, aliases[host] != room.joinURL { ambiguous.insert(host) }
                aliases[host] = room.joinURL
            }
            for host in ambiguous { aliases.removeValue(forKey: host) }
            return aliases
        }
        invitationNormalizer = { url in
            if GuestSiteLinkAdapter.handles(url) {
                return try? GuestSiteLinkAdapter.invitation(from: url,
                    websiteOrigin: preferences.string(forKey: "guestWebsiteOrigin") ?? "",
                    recentInvitations: JoinDestination.guestInvitations(in: history.rooms))
            }
            return (try? JoinTarget.parse(url.absoluteString))?.invitationURL
        }
    }
}
