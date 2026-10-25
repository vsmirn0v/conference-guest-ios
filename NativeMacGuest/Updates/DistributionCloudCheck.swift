#if NATIVE_DIRECT_UPDATES
import CloudKit
import ConferenceCore
import Foundation

/// Explicit release qualification, scoped to a generated private test zone.
/// It does not load the user's library or alter sync preferences.
@MainActor enum NativeDistributionCloudCheck {
    static func run(arguments: [String]) async throws {
        guard let option = arguments.firstIndex(of: "--check-distribution-cloud"), arguments.count > option + 2,
              ["write", "verify", "cleanup"].contains(arguments[option + 1]),
              let marker = UUID(uuidString: arguments[option + 2]) else { throw RoomCloudError.incompatibleData }
        let phase = arguments[option + 1], id = marker.uuidString
        let name = "SyncVerification-" + id
        let container = CKContainer(identifier: CloudRoomTransport.containerIdentifier)
        guard try await container.accountStatus() == .available else { throw RoomCloudError.incompatibleData }
        let transport = CloudRoomTransport(zoneName: name, notifications: false)
        let zone = CKRecordZone.ID(zoneName: name, ownerName: CKCurrentUserDefaultName)
        if phase == "cleanup" {
            _ = try await container.privateCloudDatabase.deleteRecordZone(withID: zone)
        } else {
            let session = try await transport.connect()
            let invitation = URL(string: "https://sync-fixture.example.test/\(id)?psw=generated-fixture")!
            if phase == "write" {
                var document = RoomSyncDocument(); document.setName("Direct distribution check")
                var room = RecentRoom(invitationURL: invitation, title: "Generated update fixture", identifier: id,
                    isStarred: true, lastJoined: Date())
                room.alias = "Preserved through automatic update"
                document.upsert(room, visited: true)
                _ = try await transport.save(document.records, session: session)
            }
            let changes = try await transport.fetch(session: session, after: nil)
            var document = RoomSyncDocument(); document.merge(changes.records)
            guard document.visibleRooms.count == 1, document.visibleRooms.first?.invitationURL == invitation,
                  document.visibleRooms.first?.alias == "Preserved through automatic update",
                  document.visibleRooms.first?.isStarred == true,
                  document.name?.value == "Direct distribution check" else { throw RoomCloudError.incompatibleData }
        }
        print("DISTRIBUTION_CLOUD_PASS phase=\(phase) marker=\(id) build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown")")
    }
}
#endif
