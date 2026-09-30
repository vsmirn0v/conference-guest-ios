#if DEBUG
import ConferenceCore
import Foundation

/// Deterministic UI coverage without signing a simulator into a person's account.
@MainActor
enum RoomSyncUIFixture {
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
        model.displayName = "Aram"
        let coordinator = RoomSyncCoordinator(history: model.history, name: "Aram",
                                              preferences: UserDefaults(suiteName: "SyncUIFixture")!,
                                              storage: Storage(), transport: Cloud(available: mode == "available"))
        model.installSyncFixture(coordinator)
    }
}
#endif
