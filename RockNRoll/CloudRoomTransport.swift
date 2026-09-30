import CloudKit
import ConferenceCore
import CryptoKit
import Foundation

struct RoomCloudSession: Equatable {
    let account: String
    let generation: String
}

struct RoomCloudChanges {
    let records: [RoomSyncRecord]
    let token: Data?
}

enum RoomCloudError: Error {
    case noAccount, restricted, incompatibleData, conflict, generationChanged
}

@MainActor
protocol RoomCloudTransport {
    func connect() async throws -> RoomCloudSession
    func fetch(session: RoomCloudSession, after token: Data?) async throws -> RoomCloudChanges
    func save(_ records: [RoomSyncRecord], session: RoomCloudSession) async throws -> [RoomSyncRecord]
    func clear(session: RoomCloudSession) async throws
}

/// Invitations and names are encrypted payloads in the user's private database.
/// The control record participates in every atomic write, fencing out stale replicas
/// after the user deletes their cloud data.
@MainActor
final class CloudRoomTransport: RoomCloudTransport {
    static let containerIdentifier = "iCloud.dev.vsmirn0v.conferenceguest"
    private lazy var container = CKContainer(identifier: Self.containerIdentifier)
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zone: CKRecordZone.ID
    private let notifications: Bool
    init(zoneName: String = "SavedJams", notifications: Bool = true) {
        zone = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        self.notifications = notifications
    }
    private var controlID: CKRecord.ID { .init(recordName: "SyncGeneration", zoneID: zone) }
    private struct Payload: Codable {
        var schema = 1
        let generation: String
        let record: RoomSyncRecord
    }

    func connect() async throws -> RoomCloudSession {
        let status = try await container.accountStatus()
        guard status == .available else {
            throw status == .restricted ? RoomCloudError.restricted : RoomCloudError.noAccount
        }
        let account = try await container.userRecordID().recordName
        do { _ = try await database.recordZone(for: zone) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            _ = try await database.save(CKRecordZone(zoneID: zone))
        }
        let control: CKRecord
        do { control = try await database.record(for: controlID) }
        catch let error as CKError where error.code == .unknownItem {
            let new = CKRecord(recordType: "SyncControl", recordID: controlID)
            new.encryptedValues["generation"] = UUID().uuidString as CKRecordValue
            do { control = try await database.save(new) }
            catch let conflict as CKError where conflict.code == .serverRecordChanged {
                control = try await database.record(for: controlID)
            }
        }
        guard let generation = control.encryptedValues["generation"] as? String else {
            throw RoomCloudError.incompatibleData
        }
        // Foreground fetches remain sufficient if notifications are unavailable.
        if notifications {
            let subscription = CKRecordZoneSubscription(zoneID: zone, subscriptionID: "SavedJamsChanges")
            let notification = CKSubscription.NotificationInfo()
            notification.shouldSendContentAvailable = true
            subscription.notificationInfo = notification
            _ = try? await database.save(subscription)
        }
        return RoomCloudSession(account: account, generation: generation)
    }

    func fetch(session: RoomCloudSession, after data: Data?) async throws -> RoomCloudChanges {
        guard try await container.userRecordID().recordName == session.account else { throw RoomCloudError.noAccount }
        let token = try data.map { try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        do { return try await fetchChanges(session: session, token: token ?? nil) }
        catch let error as CKError where error.code == .changeTokenExpired {
            return try await fetchChanges(session: session, token: nil)
        }
    }

    private func fetchChanges(session: RoomCloudSession, token: CKServerChangeToken?) async throws -> RoomCloudChanges {
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = token
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zone], configurationsByRecordZoneID: [zone: config])
        operation.fetchAllChanges = true
        operation.qualityOfService = .utility
        return try await withCheckedThrowingContinuation { continuation in
            var records: [RoomSyncRecord] = []
            var nextToken: CKServerChangeToken?
            var failure: Error?
            operation.recordWasChangedBlock = { [self] id, result in
                do {
                    let record = try result.get()
                    if id == controlID {
                        if record.encryptedValues["generation"] as? String != session.generation {
                            throw RoomCloudError.generationChanged
                        }
                    } else if let payload = try decode(record, generation: session.generation) {
                        records.append(payload)
                    }
                } catch { failure = error }
            }
            operation.recordWithIDWasDeletedBlock = { _, _ in
                // Individual records are tombstoned, never physically deleted by this app.
                failure = RoomCloudError.generationChanged
            }
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let value): nextToken = value.serverChangeToken
                case .failure(let error): failure = error
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                do {
                    try result.get()
                    if let failure { throw failure }
                    let encoded = try nextToken.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
                    continuation.resume(returning: RoomCloudChanges(records: records, token: encoded))
                } catch { continuation.resume(throwing: error) }
            }
            database.add(operation)
        }
    }

    func save(_ records: [RoomSyncRecord], session: RoomCloudSession) async throws -> [RoomSyncRecord] {
        var saved: [RoomSyncRecord] = []
        // CloudKit batches stay comfortably below its record-operation limits.
        for offset in stride(from: 0, to: records.count, by: 100) {
            guard try await container.userRecordID().recordName == session.account else { throw RoomCloudError.noAccount }
            let batch = Array(records[offset..<min(offset + 100, records.count)])
            let control = try await database.record(for: controlID)
            guard control.encryptedValues["generation"] as? String == session.generation else {
                throw RoomCloudError.generationChanged
            }
            let existing = try await database.records(for: batch.map { recordID($0.id) })
            var merged: [RoomSyncRecord] = []
            var writes: [CKRecord] = []
            for item in batch {
                let id = recordID(item.id)
                let record: CKRecord
                switch existing[id] {
                case .success(let value): record = value
                case .failure(let error as CKError) where error.code == .unknownItem:
                    record = CKRecord(recordType: "RoomPreference", recordID: id)
                case .failure(let error): throw error
                case .none: throw RoomCloudError.incompatibleData
                }
                let value = try decode(record, generation: session.generation).map { item.merging($0) } ?? item
                let payload = try JSONEncoder().encode(Payload(generation: session.generation, record: value))
                guard payload.count <= 128 * 1024 else { throw RoomCloudError.incompatibleData }
                record.encryptedValues["payload"] = payload as CKRecordValue
                merged.append(value); writes.append(record)
            }
            control.encryptedValues["write"] = UUID().uuidString as CKRecordValue
            writes.append(control)
            do {
                let result = try await database.modifyRecords(saving: writes, deleting: [],
                                                              savePolicy: .ifServerRecordUnchanged, atomically: true)
                for value in result.saveResults.values { _ = try value.get() }
            } catch let error as CKError where Self.isConflict(error) {
                throw RoomCloudError.conflict
            }
            saved.append(contentsOf: merged)
        }
        return saved
    }

    func clear(session: RoomCloudSession) async throws {
        guard try await container.userRecordID().recordName == session.account else { throw RoomCloudError.noAccount }
        let control = try await database.record(for: controlID)
        guard control.encryptedValues["generation"] as? String == session.generation else { throw RoomCloudError.generationChanged }
        _ = try await database.deleteRecordZone(withID: zone)
        // A fresh generation prevents offline copies from republishing the old data.
        _ = try await connect()
    }

    private func recordID(_ id: String) -> CKRecord.ID {
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: "item-" + digest, zoneID: zone)
    }

    private func decode(_ record: CKRecord, generation: String) throws -> RoomSyncRecord? {
        guard let data = record.encryptedValues["payload"] as? Data else {
            if record.recordChangeTag == nil { return nil }
            throw RoomCloudError.incompatibleData
        }
        guard data.count <= 128 * 1024 else { throw RoomCloudError.incompatibleData }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.schema == 1, payload.record.maximumCounter >= 0,
              payload.record.maximumCounter < Int64.max - 1_000_000 else { throw RoomCloudError.incompatibleData }
        guard payload.generation == generation else { throw RoomCloudError.generationChanged }
        guard recordID(payload.record.id) == record.recordID else { throw RoomCloudError.incompatibleData }
        return payload.record
    }

    private static func isConflict(_ error: CKError) -> Bool {
        if error.code == .serverRecordChanged { return true }
        if let errors = error.partialErrorsByItemID {
            return errors.values.contains { ($0 as? CKError).map(isConflict) ?? false }
        }
        return false
    }
    #if DEBUG
    func deleteVerificationZone() async throws {
        guard zone.zoneName.hasPrefix("SyncVerification-"), !notifications else { throw RoomCloudError.incompatibleData }
        _ = try await database.deleteRecordZone(withID: zone)
    }
    #endif
}
