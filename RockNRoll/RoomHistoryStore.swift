import Combine
import ConferenceCore
import Foundation
import Security

@MainActor
final class RoomHistoryStore: ObservableObject {
    @Published private(set) var rooms: [RecentRoom] = []
    private var history: RecentRooms
    private(set) var removedRoom: RecentRoom?

    init() {
        if let data = Self.read(), let restored = try? JSONDecoder().decode(RecentRooms.self, from: data) {
            history = restored
        } else {
            history = RecentRooms()
        }
        rooms = history.items
    }

    func record(url: URL, title: String, identifier: String) {
        history.record(url: url, title: title, identifier: identifier)
        save()
    }

    func updateTitle(for url: URL, title: String) {
        history.updateTitle(for: url, title: title)
        save()
    }

    func toggleStar(_ url: URL) {
        history.toggleStar(for: url)
        save()
    }

    func remove(_ url: URL) {
        removedRoom = history.items.first { $0.invitationURL == url }
        history.remove(url)
        save()
    }

    func undoRemoval() {
        guard let removedRoom else { return }
        history.restore(removedRoom)
        self.removedRoom = nil
        save()
    }

    func setAlias(_ alias: String?, for url: URL) {
        history.setAlias(alias, for: url)
        save()
    }

    private func save() {
        rooms = history.items
        guard let data = try? JSONEncoder().encode(history) else { return }
        let query = Self.query
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(addition as CFDictionary, nil)
        }
    }

    private static func read() -> Data? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.vsmirn0v.conferenceguest.room-history",
         kSecAttrAccount as String: "saved-rooms"]
    }
}
