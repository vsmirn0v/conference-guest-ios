import Foundation

/// A logical clock makes merges deterministic even when device wall clocks disagree.
public struct SyncVersion: Codable, Equatable, Comparable, Sendable {
    public var counter: Int64
    public var device: String
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter ? lhs.device < rhs.device : lhs.counter < rhs.counter
    }
}

public struct SyncValue<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var value: Value
    public var version: SyncVersion
    public init(_ value: Value, version: SyncVersion) { self.value = value; self.version = version }
    public func merging(_ other: Self) -> Self { version < other.version ? other : self }
}

public struct SyncedRoom: Codable, Equatable, Sendable {
    public let invitationURL: URL
    public let identifier: String
    public var title: SyncValue<String>
    public var alias: SyncValue<String?>
    public var starred: SyncValue<Bool>
    /// Optional for compatibility with records written before ordering existed.
    public var favoritePosition: SyncValue<Int64>?
    public var lastJoined: SyncValue<Date>
    public var hasBeenJoined: SyncValue<Bool>?
    public var engine: SyncValue<MeetingEngineKind>?
    public var latestInvitationURL: SyncValue<URL>?
    // Editing a stale room cannot revive a deletion. Only an explicit visit/undo can.
    public var exists: SyncValue<Bool>
    public var id: String { invitationURL.absoluteString }
    public var maximumCounter: Int64 {
        ([title.version, alias.version, starred.version, lastJoined.version, exists.version] +
            (favoritePosition.map { [$0.version] } ?? []) +
            (hasBeenJoined.map { [$0.version] } ?? []) + (engine.map { [$0.version] } ?? []) +
            (latestInvitationURL.map { [$0.version] } ?? []))
            .map(\.counter).max() ?? 0
    }
    public init(_ room: RecentRoom, version: SyncVersion) {
        invitationURL = room.invitationURL; identifier = room.identifier
        title = .init(room.title, version: version); alias = .init(room.alias, version: version)
        starred = .init(room.isStarred, version: version)
        favoritePosition = room.favoritePosition.map { .init($0, version: version) }
        lastJoined = .init(room.lastJoined, version: version); exists = .init(true, version: version)
        hasBeenJoined = room.hasBeenJoined.map { .init($0, version: version) }
        engine = room.engine?.persistenceHint.map { .init($0, version: version) }
        latestInvitationURL = room.latestInvitationURL.map { .init($0, version: version) }
    }
    public var room: RecentRoom {
        var result = RecentRoom(invitationURL: invitationURL, title: title.value,
                                identifier: identifier, isStarred: starred.value, lastJoined: lastJoined.value)
        result.alias = alias.value
        result.favoritePosition = favoritePosition?.value
        result.hasBeenJoined = hasBeenJoined?.value; result.engine = engine?.value
        result.latestInvitationURL = latestInvitationURL?.value
        return result
    }
    public func merging(_ other: Self) -> Self {
        guard id == other.id else { return self }
        var result = self
        result.title = title.merging(other.title); result.alias = alias.merging(other.alias)
        result.starred = starred.merging(other.starred); result.exists = exists.merging(other.exists)
        if let incoming = other.hasBeenJoined {
            if let local = hasBeenJoined {
                result.hasBeenJoined = .init(local.value || incoming.value, version: max(local.version, incoming.version))
            } else if !incoming.value, lastJoined.value != other.lastJoined.value {
                result.hasBeenJoined = .init(true, version: lastJoined.version)
            } else { result.hasBeenJoined = incoming }
        } else if hasBeenJoined?.value == false, other.lastJoined.value != lastJoined.value {
            // Schema-1 readers change this timestamp only on a real visit.
            result.hasBeenJoined = .init(true, version: other.lastJoined.version)
        }
        if let incoming = other.engine { result.engine = engine?.merging(incoming) ?? incoming }
        if let incoming = other.latestInvitationURL {
            result.latestInvitationURL = latestInvitationURL?.merging(incoming) ?? incoming
        }
        if let incoming = other.favoritePosition {
            result.favoritePosition = favoritePosition?.merging(incoming) ?? incoming
        }
        // A save time is only a schema-1 compatibility field, never a real visit.
        // A legacy echo of a saved-only record retains its identical timestamp.
        let localVisit = hasBeenJoined?.value ?? !(other.hasBeenJoined?.value == false && lastJoined.value == other.lastJoined.value)
        let remoteVisit = other.hasBeenJoined?.value ?? !(hasBeenJoined?.value == false && lastJoined.value == other.lastJoined.value)
        if localVisit != remoteVisit { result.lastJoined = localVisit ? lastJoined : other.lastJoined }
        else {
            result.lastJoined = lastJoined.value == other.lastJoined.value ? lastJoined.merging(other.lastJoined) :
                (lastJoined.value < other.lastJoined.value ? other.lastJoined : lastJoined)
        }
        return result
    }
}

public enum RoomSyncRecord: Codable, Equatable, Sendable {
    case profile(SyncValue<String>)
    case room(SyncedRoom)
    public var id: String {
        switch self { case .profile: return "profile"; case .room(let room): return room.id }
    }
    public var maximumCounter: Int64 {
        switch self { case .profile(let name): return name.version.counter; case .room(let room): return room.maximumCounter }
    }
    public func merging(_ other: Self) -> Self {
        switch (self, other) {
        case (.profile(let a), .profile(let b)): return .profile(a.merging(b))
        case (.room(let a), .room(let b)): return .room(a.merging(b))
        default: return self
        }
    }
}

/// Local replica. Tombstones survive history trimming and offline edits.
public struct RoomSyncDocument: Codable, Equatable, Sendable {
    public let device: String
    public private(set) var counter: Int64 = 0
    public private(set) var name: SyncValue<String>?
    public private(set) var rooms: [String: SyncedRoom] = [:]
    public init(device: String = UUID().uuidString) { self.device = device }

    private mutating func nextVersion() -> SyncVersion {
        counter += 1
        return SyncVersion(counter: counter, device: device)
    }

    public mutating func setName(_ value: String) {
        guard name?.value != value else { return }
        name = .init(value, version: nextVersion())
    }

    public mutating func upsert(_ room: RecentRoom, visited: Bool = false, saved: Bool = false) {
        let version = nextVersion()
        guard var existing = rooms[room.id] else {
            rooms[room.id] = SyncedRoom(room, version: version); return
        }
        if existing.title.value != room.title { existing.title = .init(room.title, version: version) }
        if existing.alias.value != room.alias { existing.alias = .init(room.alias, version: version) }
        if existing.starred.value != room.isStarred {
            existing.starred = .init(room.isStarred, version: version)
            if let position = room.favoritePosition { existing.favoritePosition = .init(position, version: version) }
        }
        if let engine = room.engine?.persistenceHint, engine != existing.engine?.value { existing.engine = .init(engine, version: version) }
        if let url = room.latestInvitationURL, url != existing.latestInvitationURL?.value {
            existing.latestInvitationURL = .init(url, version: version)
        }
        if visited || saved {
            let hadVisit = existing.hasBeenJoined?.value != false
            if visited { existing.hasBeenJoined = .init(true, version: version) }
            if !existing.exists.value, let position = room.favoritePosition {
                existing.favoritePosition = .init(position, version: version)
            }
            existing.exists = .init(true, version: version)
            if visited, !hadVisit || room.lastJoined > existing.lastJoined.value {
                existing.lastJoined = .init(room.lastJoined, version: version)
            }
        }
        rooms[room.id] = existing
    }

    /// Only rank fields change. One logical version makes concurrent full-list
    /// moves converge consistently without overwriting names, stars or tombstones.
    public mutating func setFavoriteOrder(_ ids: [String]) {
        let current = visibleRooms.filter(\.isStarred).map(\.id)
        let ordered = orderedRoomIDs(ids, current: current)
        guard ordered.enumerated().contains(where: { rooms[$0.element]?.favoritePosition?.value != Int64($0.offset) }) else { return }
        let version = nextVersion()
        for (position, id) in ordered.enumerated() {
            rooms[id]?.favoritePosition = .init(Int64(position), version: version)
        }
    }

    /// Freeze the displayed legacy order before subsequent visits can change it.
    public mutating func migrateFavoriteOrderIfNeeded() {
        let favorites = visibleRooms.filter(\.isStarred)
        guard favorites.contains(where: { rooms[$0.id]?.favoritePosition == nil }) else { return }
        setFavoriteOrder(favorites.map(\.id))
    }

    public mutating func remove(_ id: String) {
        guard var room = rooms[id], room.exists.value else { return }
        room.exists = .init(false, version: nextVersion()); rooms[id] = room
    }

    public mutating func merge(_ records: [RoomSyncRecord]) {
        for record in records {
            counter = max(counter, record.maximumCounter)
            switch record {
            case .profile(let incoming): name = name?.merging(incoming) ?? incoming
            case .room(let incoming): rooms[incoming.id] = rooms[incoming.id]?.merging(incoming) ?? incoming
            }
        }
    }

    public var visibleRooms: [RecentRoom] {
        RecentRooms(items: rooms.values.filter { $0.exists.value }.map(\.room)).items
    }

    public var records: [RoomSyncRecord] {
        (name.map { [.profile($0)] } ?? []) + rooms.values.map { .room($0) }
    }

    /// Trimming creates durable removals so old history cannot reappear later.
    public mutating func trimHistory() {
        let retained = Set(visibleRooms.map(\.id))
        for room in rooms.values where room.exists.value && !retained.contains(room.id) { remove(room.id) }
    }
}
