import Foundation

public struct RecentRoom: Codable, Equatable, Identifiable, Sendable {
    public let invitationURL: URL
    public var title: String
    public var alias: String?
    public let identifier: String
    public var isStarred: Bool
    public var lastJoined: Date

    public var id: String { invitationURL.absoluteString }
    public var displayTitle: String { alias ?? title }

    public init(invitationURL: URL, title: String, identifier: String,
                isStarred: Bool = false, lastJoined: Date) {
        self.invitationURL = invitationURL
        self.title = title
        self.alias = nil
        self.identifier = identifier
        self.isStarred = isStarred
        self.lastJoined = lastJoined
    }
}

public struct RecentRooms: Codable, Equatable, Sendable {
    public private(set) var items: [RecentRoom]

    public init(items: [RecentRoom] = []) {
        self.items = items
        normalize()
    }

    public mutating func record(url: URL, title: String, identifier: String,
                                at date: Date = Date()) {
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        if let index = items.firstIndex(where: { $0.invitationURL == url }) {
            items[index].lastJoined = date
            if !cleanTitle.isEmpty { items[index].title = cleanTitle }
        } else {
            items.append(RecentRoom(invitationURL: url,
                                    title: cleanTitle.isEmpty ? identifier : cleanTitle,
                                    identifier: identifier, lastJoined: date))
        }
        normalize()
    }

    public mutating func updateTitle(for url: URL, title: String) {
        guard let index = items.firstIndex(where: { $0.invitationURL == url }) else { return }
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !cleanTitle.isEmpty else { return }
        items[index].title = cleanTitle
    }

    public mutating func toggleStar(for url: URL) {
        guard let index = items.firstIndex(where: { $0.invitationURL == url }) else { return }
        items[index].isStarred.toggle()
        normalize()
    }

    public mutating func remove(_ url: URL) {
        items.removeAll { $0.invitationURL == url }
    }

    public mutating func setAlias(_ alias: String?, for url: URL) {
        guard let index = items.firstIndex(where: { $0.invitationURL == url }) else { return }
        let clean = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        items[index].alias = clean.isEmpty ? nil : String(clean.prefix(80))
    }

    public mutating func restore(_ room: RecentRoom) {
        items.removeAll { $0.invitationURL == room.invitationURL }
        items.append(room)
        normalize()
    }

    private mutating func normalize() {
        items.sort {
            if $0.isStarred != $1.isStarred { return $0.isStarred }
            if $0.lastJoined != $1.lastJoined { return $0.lastJoined > $1.lastJoined }
            return $0.id < $1.id
        }
        var unstarred = 0
        items = items.filter { room in
            guard !room.isStarred else { return true }
            unstarred += 1
            return unstarred <= 10
        }
    }
}
