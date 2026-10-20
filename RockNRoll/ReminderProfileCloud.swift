import CloudKit
import Foundation

/// Separate zone: old saved-room clients never have to decode reminder preferences.
/// The saved-room generation fences data left by an offline client after cloud deletion.
@MainActor final class ReminderProfileCloud {
    private let container = CKContainer(identifier: CloudRoomTransport.containerIdentifier)
    private let zone: CKRecordZone.ID
    init(zoneName: String = "MeetingReminderPreferences") {
        zone = .init(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }
    private var database: CKDatabase { container.privateCloudDatabase }
    private var id: CKRecord.ID { .init(recordName: "Profile-v1", zoneID: zone) }
    private struct Payload: Codable { var schema = 2; let generation: String; let profile: ReminderProfileEnvelope }
    func session(account: String) async throws -> RoomCloudSession {
        let session = try await CloudRoomTransport(notifications: false).connect()
        guard session.account == account else { throw RoomCloudError.noAccount }
        do { _ = try await database.recordZone(for: zone) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            _ = try await database.save(CKRecordZone(zoneID: zone))
        }
        return session
    }
    func exchange(_ local: ReminderProfileEnvelope, acknowledged: ReminderProfileEnvelope?,
                  session: RoomCloudSession) async throws -> ReminderProfileEnvelope {
        for attempt in 0..<3 {
            guard !Task.isCancelled, try await container.userRecordID().recordName == session.account else {
                throw RoomCloudError.noAccount
            }
            let controlID = CKRecord.ID(recordName: "SyncGeneration", zoneID: .init(zoneName: "SavedJams", ownerName: CKCurrentUserDefaultName))
            let control = try await database.record(for: controlID)
            guard control.encryptedValues["generation"] as? String == session.generation else { throw RoomCloudError.generationChanged }
            let record: CKRecord
            do { record = try await database.record(for: id) }
            catch let error as CKError where error.code == .unknownItem { record = CKRecord(recordType: "RoomPreference", recordID: id) }
            var remote: ReminderProfileEnvelope?
            if let data = record.encryptedValues["payload"] as? Data {
                guard data.count <= 16384 else { throw RoomCloudError.incompatibleData }
                let payload = try JSONDecoder().decode(Payload.self, from: data)
                guard (1...2).contains(payload.schema), (1...2).contains(payload.profile.schema), payload.profile.counter >= 0,
                      payload.profile.counter < Int64.max - 1000 else { throw RoomCloudError.incompatibleData }
                if payload.generation == session.generation { remote = payload.profile }
            }
            let chosen: ReminderProfileEnvelope
            if let remote, local.precedes(remote) || acknowledged == nil && local.counter == 0 { chosen = remote }
            else { chosen = local }
            if chosen == remote, chosen.schema == 2 { return chosen }
            var upgraded = chosen; upgraded.schema = 2
            record.encryptedValues["payload"] = try JSONEncoder().encode(Payload(generation: session.generation, profile: upgraded)) as CKRecordValue
            do {
                let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
                for result in result.saveResults.values { _ = try result.get() }
                return upgraded
            } catch let error as CKError where error.code == .serverRecordChanged && attempt < 2 { continue }
        }
        throw RoomCloudError.conflict
    }
    func delete() async throws {
        do { _ = try await database.deleteRecordZone(withID: zone) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone { return }
    }
}
