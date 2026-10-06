import Foundation

public struct RecentRoom: Codable, Equatable, Identifiable, Sendable {
    public let invitationURL: URL
    public var title: String
    public var alias: String?
    public let identifier: String
    public var isStarred: Bool
    public var lastJoined: Date
    public var favoritePosition: Int64?
    /// nil is a legacy visited room. false explicitly represents a saved-only room.
    public var hasBeenJoined: Bool?
    public var engine: MeetingEngineKind?
    public var latestInvitationURL: URL?

    public var id: String { invitationURL.absoluteString }
    public var displayTitle: String { alias ?? title }
    public var lastVisit: Date? { hasBeenJoined == false ? nil : lastJoined }
    public var joinURL: URL { latestInvitationURL ?? invitationURL }

    public init(invitationURL: URL, title: String, identifier: String,
                isStarred: Bool = false, lastJoined: Date) {
        self.invitationURL = invitationURL
        self.title = title
        self.alias = nil
        self.identifier = identifier
        self.isStarred = isStarred
        self.lastJoined = lastJoined
        self.favoritePosition = nil
        self.hasBeenJoined = nil; self.engine = nil; self.latestInvitationURL = nil
    }
}

public struct RecentRooms: Codable, Equatable, Sendable {
    public private(set) var items: [RecentRoom]

    public init(items: [RecentRoom] = []) {
        self.items = items
        normalize()
    }

    private enum CodingKeys: String, CodingKey { case items }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(items: try container.decode([RecentRoom].self, forKey: .items))
    }

    public mutating func record(url: URL, title: String, identifier: String,
                                at date: Date = Date(), engine: MeetingEngineKind? = nil) {
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        if let index = matchingIndex(url, engine: engine) {
            items[index].lastJoined = date
            items[index].hasBeenJoined = true
            items[index].engine = engine ?? items[index].engine
            if items[index].invitationURL != url { items[index].latestInvitationURL = url }
            if !cleanTitle.isEmpty { items[index].title = cleanTitle }
        } else {
            items.append(RecentRoom(invitationURL: url,
                                    title: cleanTitle.isEmpty ? identifier : cleanTitle,
                                    identifier: identifier, lastJoined: date))
            items[items.count - 1].engine = engine
        }
        normalize()
    }

    /// Saving is a deliberate room action, never a visit. The legacy timestamp
    /// stores the real save time for schema-1 readers; lastVisit stays nil.
    public mutating func saveFavorite(url: URL, title: String, identifier: String,
                                      engine: MeetingEngineKind? = nil, at date: Date = Date()) {
        if let index = matchingIndex(url, engine: engine) {
            if !items[index].isStarred { toggleStar(for: items[index].invitationURL) }
            return
        }
        var room = RecentRoom(invitationURL: url, title: String(title.prefix(80)), identifier: identifier,
                              lastJoined: date)
        room.hasBeenJoined = false; room.engine = engine
        room.alias = room.title
        items.append(room)
        toggleStar(for: url)
    }

    public func matching(_ url: URL, engine: MeetingEngineKind? = nil) -> RecentRoom? {
        matchingIndex(url, engine: engine).map { items[$0] }
    }

    private func matchingIndex(_ url: URL, engine: MeetingEngineKind?) -> Int? {
        if let index = items.firstIndex(where: { $0.invitationURL == url || $0.joinURL == url }) { return index }
        guard let identity = MeetingRoomIdentity(url, engine: engine) else { return nil }
        return items.firstIndex { MeetingRoomIdentity($0.joinURL, engine: $0.engine) == identity }
    }

    public mutating func updateTitle(for url: URL, title: String) {
        guard let index = items.firstIndex(where: { $0.invitationURL == url }) else { return }
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !cleanTitle.isEmpty else { return }
        items[index].title = cleanTitle
    }

    public mutating func toggleStar(for url: URL) {
        guard let index = items.firstIndex(where: { $0.invitationURL == url }) else { return }
        let previous = items.filter(\.isStarred).map(\.id)
        items[index].isStarred.toggle()
        if items[index].isStarred {
            let ordered = [items[index].id] + previous
            assignFavoritePositions(ordered)
        } else { items[index].favoritePosition = nil }
        normalize()
    }

    /// Missing/currently unstarred IDs are ignored; unseen favorites retain order.
    @discardableResult public mutating func setFavoriteOrder(_ ids: [String]) -> Bool {
        let current = items.filter(\.isStarred).map(\.id)
        let ordered = orderedRoomIDs(ids, current: current)
        guard ordered != current else { return false }
        assignFavoritePositions(ordered)
        normalize()
        return true
    }

    private mutating func assignFavoritePositions(_ ids: [String]) {
        let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, Int64($0.offset)) })
        for index in items.indices where items[index].isStarred {
            items[index].favoritePosition = positions[items[index].id]
        }
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
            if $0.isStarred {
                if let a = $0.favoritePosition, let b = $1.favoritePosition {
                    return a == b ? $0.id < $1.id : a < b
                }
                if ($0.favoritePosition != nil) != ($1.favoritePosition != nil) {
                    return $0.favoritePosition != nil
                }
            }
            if $0.lastJoined != $1.lastJoined { return $0.lastJoined > $1.lastJoined }
            return $0.id < $1.id
        }
        // Migrate legacy favorites once, preserving their displayed order.
        if items.contains(where: { $0.isStarred && $0.favoritePosition == nil }) {
            assignFavoritePositions(items.filter(\.isStarred).map(\.id))
        }
        var unstarred = 0
        items = items.filter { room in
            guard !room.isStarred else { return true }
            guard room.lastVisit != nil else { return false }
            unstarred += 1
            return unstarred <= 10
        }
    }
}

/// Reconcile a requested permutation with current membership in linear time.
func orderedRoomIDs(_ requested: [String], current: [String]) -> [String] {
    let allowed = Set(current)
    var seen: Set<String> = []
    return (requested + current).filter { allowed.contains($0) && seen.insert($0).inserted }
}
