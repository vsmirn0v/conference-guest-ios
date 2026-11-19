import CloudKit
import ConferenceCore
import Foundation

@MainActor
protocol MeetingContinuationTransport {
    func connect(account: String) async throws
    func snapshot(sourceSession: UUID?) async throws -> (jams: [ActiveJam], command: JamTransfer?)
    func jams() async throws -> [ActiveJam]
    func publish(_ jam: ActiveJam) async throws
    func withdraw(deviceID: String, sessionID: UUID?) async throws
    func claim(_ transfer: JamTransfer) async throws
    func transfer(sourceSession: UUID) async throws -> JamTransfer?
    func transition(_ transfer: JamTransfer, to phase: JamTransfer.Phase, actor: String) async throws -> JamTransfer
    func clear() async throws
    func resetConnection()
}

extension MeetingContinuationTransport {
    func resetConnection() {}
    func snapshot(sourceSession: UUID?) async throws -> (jams: [ActiveJam], command: JamTransfer?) {
        let rooms = try await jams()
        let command: JamTransfer?
        if let sourceSession { command = try await transfer(sourceSession: sourceSession) } else { command = nil }
        return (rooms, command)
    }
}

enum ContinuationError: Error { case unavailable, conflict, expired }

private enum ContinuationPayload: Codable, Sendable {
    case jam(ActiveJam), transfer(JamTransfer), vacant
}

private struct ContinuationEnvelope: Codable, Sendable {
    let schema: Int
    let generation: String
    let payload: ContinuationPayload
}

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
    private var cachedTransfers: [CKRecord.ID: JamTransfer] = [:]
    private var cachedJams: [CKRecord.ID: ActiveJam] = [:]
    private var revision = 0
    private var subscriptionSaved = false
    private var lastValidatedAt: Date?
    private var controlID: CKRecord.ID { .init(recordName: "SyncGeneration", zoneID: zone) }
    private typealias Payload = ContinuationPayload
    private typealias Envelope = ContinuationEnvelope
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
        lastValidatedAt = Date()
        if notifications && !subscriptionSaved {
            let subscription = CKRecordZoneSubscription(zoneID: zone, subscriptionID: "ActiveJamsChanges")
            let info = CKSubscription.NotificationInfo(); info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            if (try? await database.save(subscription)) != nil {
                subscriptionSaved = true
            }
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
    func snapshot(sourceSession: UUID?) async throws -> (jams: [ActiveJam], command: JamTransfer?) {
        let rooms = try await jams()
        let command = sourceSession.flatMap { cachedTransfers[.init(recordName: "claim-" + $0.uuidString, zoneID: zone)] }
        return (rooms, command)
    }
    func jams() async throws -> [ActiveJam] {
        do { return try await fetchJams() }
        catch let error as CKError where error.code == .changeTokenExpired {
            token = nil; cachedJams = [:]; cachedTransfers = [:]
            return try await fetchJams()
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            token = nil; cachedJams = [:]; cachedTransfers = [:]; generation = nil
            throw ContinuationError.expired
        }
    }
    private func fetchJams() async throws -> [ActiveJam] {
        if lastValidatedAt == nil || Date().timeIntervalSince(lastValidatedAt!) >= 60 {
            _ = try await validate()
            lastValidatedAt = Date()
        }
        guard let expectedGen = generation else { throw ContinuationError.unavailable }
        let expected = revision
        let expectedControlID = controlID
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = token
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zone], configurationsByRecordZoneID: [zone: configuration])
        operation.fetchAllChanges = true; operation.qualityOfService = .utility
        let fetched: (jams: [CKRecord.ID: ActiveJam], transfers: [CKRecord.ID: JamTransfer], token: CKServerChangeToken?) =
            try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var result = cachedJams
            var transfers = cachedTransfers
            var failure: Error?
            var nextToken: CKServerChangeToken?
            operation.recordWasChangedBlock = { id, value in
                do {
                    let record = try value.get()
                    if id == expectedControlID {
                        guard record.encryptedValues["generation"] as? String == expectedGen else {
                            throw ContinuationError.expired
                        }
                        return
                    }
                    do {
                        switch try Self.decodeRecord(record, expectedGeneration: expectedGen, controlID: expectedControlID) {
                        case .jam(let jam):
                            lock.lock(); result[id] = jam; lock.unlock()
                        case .transfer(let transfer):
                            lock.lock(); transfers[id] = transfer; lock.unlock()
                        case .vacant, .none:
                            lock.lock(); result.removeValue(forKey: id); transfers.removeValue(forKey: id); lock.unlock()
                        }
                    } catch is DecodingError, ContinuationError.expired, ContinuationError.unavailable {
                        // Drop individual stale/incompatible records rather than failing the whole ActiveJams zone.
                        lock.lock(); result.removeValue(forKey: id); transfers.removeValue(forKey: id); lock.unlock()
                    }
                } catch {
                    lock.lock(); failure = error; lock.unlock()
                }
            }
            operation.recordWithIDWasDeletedBlock = { id, _ in
                lock.lock()
                if id == expectedControlID {
                    failure = ContinuationError.expired
                } else {
                    result.removeValue(forKey: id)
                    transfers.removeValue(forKey: id)
                }
                lock.unlock()
            }
            operation.recordZoneFetchResultBlock = { _, zoneResult in
                lock.lock()
                switch zoneResult {
                case .success(let value): nextToken = value.serverChangeToken
                case .failure(let error): failure = error
                }
                lock.unlock()
            }
            operation.fetchRecordZoneChangesResultBlock = { value in
                lock.lock()
                let capturedJams = result
                let capturedTransfers = transfers
                let capturedToken = nextToken
                let capturedFailure = failure
                lock.unlock()
                do {
                    try value.get()
                    if let capturedFailure { throw capturedFailure }
                    continuation.resume(returning: (capturedJams, capturedTransfers, capturedToken))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
        guard expected == revision else { throw ContinuationError.unavailable }
        cachedJams = fetched.jams
        cachedTransfers = fetched.transfers
        token = fetched.token
        let jams = Array(fetched.jams.values)
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
    func resetConnection() { revision += 1; account = nil; generation = nil; token = nil; cachedJams = [:]; cachedTransfers = [:]; subscriptionSaved = false; lastValidatedAt = nil }
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
        for attempt in 0..<5 {
            let control = try await validate()
            let recordID = CKRecord.ID(recordName: id, zoneID: zone)
            let record: CKRecord
            do { record = try await database.record(for: recordID) }
            catch let error as CKError where error.code == .unknownItem { record = CKRecord(recordType: "RoomPreference", recordID: recordID) }
            guard expected == revision else { throw ContinuationError.unavailable }
            let existingPayload: Payload? = (record.recordChangeTag == nil)
                ? nil
                : (id.hasPrefix("device-") ? (try? decode(record)) : (try decode(record)))
            let payload = try update(existingPayload)
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
                if id.hasPrefix("claim-") {
                    if case .transfer(let value) = payload { cachedTransfers[recordID] = value }
                    else { cachedTransfers.removeValue(forKey: recordID) }
                }
                return payload
            } catch let error as CKError where attempt < 4 && Self.conflict(error) {
                try? await Task.sleep(for: .milliseconds(150 * (attempt + 1)))
                continue
            }
        }
        throw ContinuationError.conflict
    }
    private nonisolated static func decodeRecord(
        _ record: CKRecord,
        expectedGeneration: String,
        controlID: CKRecord.ID
    ) throws -> Payload? {
        if record.recordID == controlID { return nil }
        guard let data = record.encryptedValues["payload"] as? Data, data.count < 32 * 1024 else {
            throw ContinuationError.unavailable
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.schema == 1, envelope.generation == expectedGeneration else {
            throw ContinuationError.expired
        }
        return envelope.payload
    }
    private func decode(_ record: CKRecord) throws -> Payload? {
        guard let generation else { throw ContinuationError.unavailable }
        return try Self.decodeRecord(record, expectedGeneration: generation, controlID: controlID)
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
        subscriptionSaved = false
        lastValidatedAt = nil
    }
}
