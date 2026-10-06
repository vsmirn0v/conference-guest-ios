import Combine
import ConferenceCore
import Foundation
import Security

protocol RoomHistoryStorage {
    func read() -> Data?
    func write(_ data: Data) throws
}

enum RoomHistoryChange {
    case upsert(RecentRoom, visited: Bool)
    case saved(RecentRoom)
    case remove(String)
    case favoriteOrder([String])
}

@MainActor
final class RoomHistoryStore: ObservableObject {
    @Published private(set) var rooms: [RecentRoom] = []
    private var history: RecentRooms
    private let storage: any RoomHistoryStorage
    @Published private(set) var persistenceWarning: String?
    private(set) var removedRoom: RecentRoom?
    var onLocalChange: ((RoomHistoryChange) -> Void)?

    init(storage: any RoomHistoryStorage = KeychainRoomHistoryStorage()) {
        self.storage = storage
        if let data = storage.read(), let restored = try? JSONDecoder().decode(RecentRooms.self, from: data) {
            history = restored
        } else {
            history = RecentRooms()
        }
        rooms = history.items
    }

    func record(url: URL, title: String, identifier: String, engine: MeetingEngineKind? = nil) {
        history.record(url: url, title: title, identifier: identifier, engine: engine)
        save()
        if let room = matching(url, engine: engine) { notify(room.invitationURL, visited: true) }
    }

    func matching(_ url: URL, engine: MeetingEngineKind? = nil) -> RecentRoom? { history.matching(url, engine: engine) }

    func saveFavorite(url: URL, title: String, engine: MeetingEngineKind? = nil) {
        guard let target = try? JoinTarget.parse(url.absoluteString) else { return }
        history.saveFavorite(url: url, title: title, identifier: target.roomID, engine: engine)
        save()
        if let room = matching(url, engine: engine) { onLocalChange?(.saved(room)) }
        onLocalChange?(.favoriteOrder(rooms.filter(\.isStarred).map(\.id)))
    }

    func updateTitle(for url: URL, title: String) {
        guard let room = history.matching(url), room.title != title else { return }
        history.updateTitle(for: room.invitationURL, title: title)
        save()
        notify(room.invitationURL)
    }

    func setFavoriteOrder(_ ids: [String]) {
        guard history.setFavoriteOrder(ids) else { return }
        save()
        onLocalChange?(.favoriteOrder(rooms.filter(\.isStarred).map(\.id)))
    }

    func moveFavorites(from source: IndexSet, to destination: Int) {
        let favorites = rooms.filter(\.isStarred)
        guard source.allSatisfy({ favorites.indices.contains($0) }), (0...favorites.count).contains(destination) else { return }
        let moving = source.sorted().map { favorites[$0].id }
        var ordered = favorites.enumerated().filter { !source.contains($0.offset) }.map { $0.element.id }
        ordered.insert(contentsOf: moving, at: destination - source.filter { $0 < destination }.count)
        setFavoriteOrder(ordered)
    }

    func toggleStar(_ url: URL) {
        let before = history.items.first { $0.invitationURL == url }
        history.toggleStar(for: url)
        save()
        if before?.lastVisit == nil, before?.isStarred == true { onLocalChange?(.remove(url.absoluteString)) }
        else { notify(url) }
        onLocalChange?(.favoriteOrder(rooms.filter(\.isStarred).map(\.id)))
    }

    func remove(_ url: URL) {
        removedRoom = history.items.first { $0.invitationURL == url }
        history.remove(url)
        save()
        onLocalChange?(.remove(url.absoluteString))
    }

    func undoRemoval() {
        guard let removedRoom else { return }
        history.restore(removedRoom)
        self.removedRoom = nil
        save()
        if removedRoom.lastVisit == nil { onLocalChange?(.saved(removedRoom)) }
        else { notify(removedRoom.invitationURL, visited: true) }
    }

    func setAlias(_ alias: String?, for url: URL) {
        history.setAlias(alias, for: url)
        save()
        notify(url)
    }

    func applySyncedRooms(_ rooms: [RecentRoom]) {
        let updated = RecentRooms(items: rooms)
        guard updated != history else { return }
        history = updated
        save()
    }

    private func notify(_ url: URL, visited: Bool = false) {
        if let room = history.items.first(where: { $0.invitationURL == url }) {
            onLocalChange?(.upsert(room, visited: visited))
        }
    }

    func retrySave() { save() }

    private func save() {
        rooms = history.items
        do {
            try storage.write(JSONEncoder().encode(history))
            persistenceWarning = nil
        } catch {
            persistenceWarning = L("Room changes are not saved yet. Tap Retry to keep them after restarting.")
        }
    }
}

struct KeychainRoomHistoryStorage: RoomHistoryStorage {
    var service = "dev.vsmirn0v.conferenceguest.room-history"
    func write(_ data: Data) throws {
        let query = self.query
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func read() -> Data? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "saved-rooms"]
    }
}
