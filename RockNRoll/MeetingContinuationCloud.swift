import CloudKit
import ConferenceCore
import Foundation

@MainActor
protocol MeetingContinuationTransport {
    func connect(account: String) async throws
    func jams() async throws -> [ActiveJam]
    func publish(_ jam: ActiveJam) async throws
    func withdraw(deviceID: String, sessionID: UUID?) async throws
    func claim(_ transfer: JamTransfer) async throws
    func transfer(sourceSession: UUID) async throws -> JamTransfer?
    func transition(_ transfer: JamTransfer, to phase: JamTransfer.Phase, actor: String) async throws -> JamTransfer
    func clear() async throws
    func resetConnection()
}

extension MeetingContinuationTransport { func resetConnection() {} }

enum ContinuationError: Error { case unavailable, conflict, expired }

/// Short-lived coordination uses a separate private zone and the existing encrypted
/// record types. No meeting access secret appears in an activity title or record name.
@MainActor
final class MeetingContinuationCloud: MeetingContinuationTransport {
    private lazy var container = CKContainer(identifier: CloudRoomTransport.containerIdentifier)
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zone: CKRecordZone.ID
    private let notifications: Bool
    private var account: String?
    private var generation: String?
    private var token: CKServerChangeToken?
    private var cachedJams: [CKRecord.ID: ActiveJam] = [:]
    private var revision = 0
    private var controlID: CKRecord.ID { .init(recordName: "SyncGeneration", zoneID: zone) }
    private enum Payload: Codable { case jam(ActiveJam), transfer(JamTransfer), vacant }
    private struct Envelope: Codable { let schema: Int; let generation: String; let payload: Payload }
    init(zoneName: String = "ActiveJams", notifications: Bool = true) {
        zone = .init(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        self.notifications = notifications
    }
    func connect(account expected: String) async throws {
        if account == expected, generation != nil { return }
        let binding = revision
        guard try await container.accountStatus() == .available,
              try await container.userRecordID().recordName == expected else { throw ContinuationError.unavailable }
        guard binding == revision else { throw ContinuationError.unavailable }
        account = expected
        do { _ = try await database.recordZone(for: zone) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            _ = try await database.save(CKRecordZone(zoneID: zone))
        }
        let control: CKRecord
        do { control = try await database.record(for: controlID) }
        catch let error as CKError where error.code == .unknownItem {
            let record = CKRecord(recordType: "SyncControl", recordID: controlID)
            record.encryptedValues["generation"] = UUID().uuidString as CKRecordValue
            do { control = try await database.save(record) }
            catch let error as CKError where error.code == .serverRecordChanged { control = try await database.record(for: controlID) }
        }
        guard binding == revision else { throw ContinuationError.unavailable }
        guard let value = control.encryptedValues["generation"] as? String else { throw ContinuationError.unavailable }
        if let generation, generation != value { throw ContinuationError.expired }
        generation = value
        if notifications {
            let subscription = CKRecordZoneSubscription(zoneID: zone, subscriptionID: "ActiveJamsChanges")
            let info = CKSubscription.NotificationInfo(); info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            _ = try? await database.save(subscription)
        }
    }
    private func validate() async throws -> CKRecord {
        let expected = revision
        guard let account, try await container.userRecordID().recordName == account,
              let generation else { throw ContinuationError.unavailable }
        let control: CKRecord
        do { control = try await database.record(for: controlID) }
        catch let error as CKError where [.zoneNotFound, .userDeletedZone, .unknownItem].contains(error.code) {
            throw ContinuationError.expired
        }
        guard expected == revision else { throw ContinuationError.unavailable }
        guard control.encryptedValues["generation"] as? String == generation else { throw ContinuationError.expired }
        return control
    }
    func jams() async throws -> [ActiveJam] {
        do { return try await fetchJams() }
        catch let error as CKError where error.code == .changeTokenExpired {
            token = nil; cachedJams = [:]
            return try await fetchJams()
        }
    }
    private func fetchJams() async throws -> [ActiveJam] {
        _ = try await validate()
        let expected = revision
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = token
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zone], configurationsByRecordZoneID: [zone: configuration])
        operation.fetchAllChanges = true; operation.qualityOfService = .utility
        let jams: [ActiveJam] = try await withCheckedThrowingContinuation { continuation in
            var result = cachedJams; var failure: Error?; var nextToken: CKServerChangeToken?
            operation.recordWasChangedBlock = { [self] id, value in
                guard id.recordName.hasPrefix("device-") else { return }
                do {
                    if case .jam(let jam) = try decode(value.get()) { result[id] = jam }
                    else { result.removeValue(forKey: id) }
                }
                catch { failure = error }
            }
            operation.recordWithIDWasDeletedBlock = { id, _ in result.removeValue(forKey: id) }
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let value): nextToken = value.serverChangeToken
                case .failure(let error): failure = error
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { [self] value in
                do {
                    try value.get(); if let failure { throw failure }
                    guard expected == revision else { throw ContinuationError.unavailable }
                    cachedJams = result; token = nextToken
                    continuation.resume(returning: Array(result.values))
                }
                catch { continuation.resume(throwing: error) }
            }
            database.add(operation)
        }
        // Remove invitation/name content from expired advertisements. Conditional
        // writes re-read the record so a fresh replacement session is preserved.
        for jam in jams where Date().timeIntervalSince(jam.updatedAt) > 900 {
            _ = try? await write(id: "device-" + jam.deviceID) { existing in
                if case .jam(let latest) = existing, Date().timeIntervalSince(latest.updatedAt) > 900 { return .vacant }
                return existing ?? .vacant
            }
        }
        return jams
    }
    func publish(_ jam: ActiveJam) async throws {
        _ = try await write(id: "device-" + jam.deviceID) { _ in .jam(jam) }
    }
    func withdraw(deviceID: String, sessionID: UUID?) async throws {
        _ = try await write(id: "device-" + deviceID) { existing in
            if case .jam(let jam) = existing, jam.sessionID != sessionID { return .jam(jam) }
            return .vacant
        }
    }
    func resetConnection() { revision += 1; account = nil; generation = nil; token = nil; cachedJams = [:] }
    func claim(_ transfer: JamTransfer) async throws {
        _ = try await write(id: "claim-" + transfer.sourceSession.uuidString) { existing in
            if case .transfer(let previous) = existing, !previous.isTerminal, previous.expiresAt > Date() {
                guard previous.id == transfer.id else { throw ContinuationError.conflict }
                return .transfer(previous)
            }
            return .transfer(transfer)
        }
    }
    func transfer(sourceSession: UUID) async throws -> JamTransfer? {
        _ = try await validate()
        do {
            let record = try await database.record(for: .init(recordName: "claim-" + sourceSession.uuidString, zoneID: zone))
            if case .transfer(let value) = try decode(record) { return value }; return nil
        } catch let error as CKError where error.code == .unknownItem { return nil }
    }
    func transition(_ transfer: JamTransfer, to phase: JamTransfer.Phase, actor: String) async throws -> JamTransfer {
        let result = try await write(id: "claim-" + transfer.sourceSession.uuidString) { existing in
            guard case .transfer(var current) = existing, current.id == transfer.id else { throw ContinuationError.conflict }
            if current.phase == phase { return .transfer(current) }
            guard current.permitsTransition(to: phase, actor: actor, now: Date()) else { throw ContinuationError.expired }
            current.phase = phase; return .transfer(current)
        }
        guard case .transfer(let value) = result else { throw ContinuationError.unavailable }; return value
    }
    private func write(id: String, update: (Payload?) throws -> Payload) async throws -> Payload {
        let expected = revision
        for attempt in 0..<3 {
            let control = try await validate()
            let recordID = CKRecord.ID(recordName: id, zoneID: zone)
            let record: CKRecord
            do { record = try await database.record(for: recordID) }
            catch let error as CKError where error.code == .unknownItem { record = CKRecord(recordType: "RoomPreference", recordID: recordID) }
            guard expected == revision else { throw ContinuationError.unavailable }
            let payload = try update(record.recordChangeTag == nil ? nil : decode(record))
            guard let generation else { throw ContinuationError.unavailable }
            let data = try JSONEncoder().encode(Envelope(schema: 1, generation: generation, payload: payload))
            guard data.count < 32 * 1024 else { throw ContinuationError.unavailable }
            record.encryptedValues["payload"] = data as CKRecordValue
            control.encryptedValues["write"] = UUID().uuidString as CKRecordValue
            do {
                let result = try await database.modifyRecords(saving: [record, control], deleting: [],
                                                              savePolicy: .ifServerRecordUnchanged, atomically: true)
                for value in result.saveResults.values { _ = try value.get() }
                guard expected == revision else { throw ContinuationError.unavailable }
                return payload
            } catch let error as CKError where attempt < 2 && Self.conflict(error) { continue }
        }
        throw ContinuationError.conflict
    }
    private func decode(_ record: CKRecord) throws -> Payload? {
        if record.recordID == controlID { return nil }
        guard let data = record.encryptedValues["payload"] as? Data, data.count < 32 * 1024 else { throw ContinuationError.unavailable }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.schema == 1, envelope.generation == generation else { throw ContinuationError.expired }
        return envelope.payload
    }
    private static func conflict(_ error: CKError) -> Bool {
        error.code == .serverRecordChanged || error.partialErrorsByItemID?.values.contains {
            ($0 as? CKError).map(conflict) ?? false
        } == true
    }
    func clear() async throws {
        _ = try await validate()
        _ = try await database.deleteRecordZone(withID: zone)
        generation = nil
    }
}
