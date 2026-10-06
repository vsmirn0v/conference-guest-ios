#if DEBUG
import ConferenceCore
import Foundation
import UIKit

/// Deterministic UI coverage without signing a simulator into a person's account.
@MainActor
enum RoomSyncUIFixture {
    static func makeModel() -> ConferenceModel {
        let environment = ProcessInfo.processInfo.environment
        if environment["CONFERENCE_TEST_UI_FIXTURE"] == "home" {
            let identifier = environment["CONFERENCE_TEST_FIXTURE_ROOM_ID"] ?? "home"
            let preferences = UserDefaults(suiteName: "HomeUIFixture." + identifier)!
            let model = ConferenceModel(history: RoomHistoryStore(storage: PersistentStorage(preferences)), preferences: preferences)
            model.installSyncFixture(RoomSyncCoordinator(history: model.history, name: model.displayName,
                preferences: preferences, storage: PersistentStorage(preferences, key: "sync"), transport: Cloud(available: false)))
            return model
        }
        guard environment["CONFERENCE_TEST_SYNC_FIXTURE"] != nil else { return ConferenceModel() }
        return ConferenceModel(history: RoomHistoryStore(storage: Storage()),
            preferences: UserDefaults(suiteName: "SyncUIFixture")!)
    }
    private final class PersistentStorage: RoomHistoryStorage {
        let preferences: UserDefaults
        let key: String
        init(_ preferences: UserDefaults, key: String = "history") { self.preferences = preferences; self.key = key }
        func read() -> Data? { preferences.data(forKey: key) }
        func write(_ data: Data) throws { preferences.set(data, forKey: key) }
    }
    private final class Storage: RoomHistoryStorage {
        var data: Data?
        func read() -> Data? { data }
        func write(_ data: Data) throws { self.data = data }
    }
    private final class Cloud: RoomCloudTransport {
        var records: [String: RoomSyncRecord] = [:]
        let available: Bool
        init(available: Bool) {
            self.available = available
            var document = RoomSyncDocument(device: "fixture-cloud")
            document.setName("Ani")
            records = Dictionary(uniqueKeysWithValues: document.records.map { ($0.id, $0) })
        }
        func connect() async throws -> RoomCloudSession {
            guard available else { throw RoomCloudError.noAccount }
            return .init(account: "fixture-account", generation: "fixture-generation")
        }
        func fetch(session: RoomCloudSession, after token: Data?) async throws -> RoomCloudChanges {
            .init(records: Array(records.values), token: nil)
        }
        func save(_ values: [RoomSyncRecord], session: RoomCloudSession) async throws -> [RoomSyncRecord] {
            values.map { value in
                let merged = records[value.id].map { value.merging($0) } ?? value
                records[value.id] = merged; return merged
            }
        }
        func clear(session: RoomCloudSession) async throws { records = [:] }
    }
    static func configure(_ model: ConferenceModel) {
        guard let mode = ProcessInfo.processInfo.environment["CONFERENCE_TEST_SYNC_FIXTURE"] else { return }
        model.history.applySyncedRooms([])
        if mode == "favorite-order" {
            // Keep XCTest from waiting on native context-menu animations.
            UIView.setAnimationsEnabled(false)
            let names = ["Warm-up", "Thursday rehearsal", "Songwriting circle"]
            let rooms = names.enumerated().map { index, name in
                RecentRoom(invitationURL: URL(string: "https://fixture.example.test/room\(index)?psw=fixture")!,
                    title: name, identifier: "order\(index)", isStarred: true,
                    lastJoined: Date(timeIntervalSince1970: Double(3 - index)))
            }
            model.history.applySyncedRooms(rooms)
        }
        let coordinator = RoomSyncCoordinator(history: model.history, name: "Aram",
                                              preferences: UserDefaults(suiteName: "SyncUIFixture")!,
                                              storage: Storage(), transport: Cloud(available: mode == "available"))
        model.installSyncFixture(coordinator)
        model.displayName = "Aram"
    }
}
#endif
