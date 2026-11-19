import CloudKit
import Compression
import CryptoKit
import Foundation

public struct CloudZoneSession: Equatable, Sendable {
    public let account: String
    public let generation: String

    public init(account: String, generation: String) {
        self.account = account
        self.generation = generation
    }
}

public struct CloudZoneChanges<Record: SyncZoneRecord>: Sendable {
    public let records: [Record]
    public let deletedCloudRecordNames: [String]
    public let token: Data?

    public init(records: [Record], deletedCloudRecordNames: [String] = [], token: Data?) {
        self.records = records
        self.deletedCloudRecordNames = deletedCloudRecordNames
        self.token = token
    }
}

public enum CloudZoneError: Error, Equatable, Sendable {
    case noAccount
    case restricted
    case incompatibleData
    case payloadTooLarge
    case conflict
    case generationChanged
}

public enum CloudKitRateLimit {
    /// Extracts a backoff duration in seconds for transient CloudKit throttling/availability errors.
    /// Returns `nil` when `error` is not a rate-limit or transient server-busy failure.
    public static func retryAfter(for error: Error, consecutiveFailures: Int = 1) -> TimeInterval? {
        guard let info = inspect(error), info.matched else { return nil }
        let exponent = max(0, min(4, consecutiveFailures - 1))
        let exponential = min(120.0, 15.0 * pow(2.0, Double(exponent)))
        return max(info.explicitRetryAfter ?? 0, exponential)
    }

    private static func inspect(_ error: Error) -> (matched: Bool, explicitRetryAfter: TimeInterval?)? {
        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain else { return nil }
        let code = CKError.Code(rawValue: nsError.code)
        let retryAfter = (nsError.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
        if code == .requestRateLimited || code == .serviceUnavailable || code == .zoneBusy {
            return (true, retryAfter.flatMap { $0 > 0 ? $0 : nil })
        }
        if let partial = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            var bestRetry: TimeInterval?
            var matchedAny = false
            for child in partial.values {
                if let info = inspect(child), info.matched {
                    matchedAny = true
                    if let r = info.explicitRetryAfter {
                        bestRetry = max(bestRetry ?? 0, r)
                    }
                }
            }
            if matchedAny { return (true, bestRetry) }
        }
        return nil
    }
}

@MainActor
public protocol CloudZoneTransporting: AnyObject {
    associatedtype Record: SyncZoneRecord
    func connect() async throws -> CloudZoneSession
    func fetch(session: CloudZoneSession, after token: Data?) async throws -> CloudZoneChanges<Record>
    func save(_ records: [Record], session: CloudZoneSession) async throws -> [Record]
    func delete(syncRecordIDs: [String], session: CloudZoneSession) async throws
    func clear(session: CloudZoneSession) async throws
}

@MainActor
public final class AnyCloudZoneTransport<Record: SyncZoneRecord> {
    private let _connect: () async throws -> CloudZoneSession
    private let _fetch: (CloudZoneSession, Data?) async throws -> CloudZoneChanges<Record>
    private let _save: ([Record], CloudZoneSession) async throws -> [Record]
    private let _delete: ([String], CloudZoneSession) async throws -> Void
    private let _clear: (CloudZoneSession) async throws -> Void

    public init<T: CloudZoneTransporting>(_ transport: T) where T.Record == Record {
        _connect = { try await transport.connect() }
        _fetch = { try await transport.fetch(session: $0, after: $1) }
        _save = { try await transport.save($0, session: $1) }
        _delete = { try await transport.delete(syncRecordIDs: $0, session: $1) }
        _clear = { try await transport.clear(session: $0) }
    }

    public func connect() async throws -> CloudZoneSession { try await _connect() }
    public func fetch(session: CloudZoneSession, after token: Data?) async throws -> CloudZoneChanges<Record> {
        try await _fetch(session, token)
    }
    public func save(_ records: [Record], session: CloudZoneSession) async throws -> [Record] {
        try await _save(records, session)
    }
    public func delete(syncRecordIDs: [String], session: CloudZoneSession) async throws {
        try await _delete(syncRecordIDs, session)
    }
    public func clear(session: CloudZoneSession) async throws {
        try await _clear(session)
    }
}

public enum CloudPayloadCodec {
    private static let lzfseMagic = Data("RNRLZF1".utf8)
    public static let maxRecordBytes = 512 * 1024
    private static let maxUncompressedBytes = 16 * 1024 * 1024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let raw = try JSONEncoder.syncCodec.encode(value)
        let compressed = compressLZFSE(raw)
        let candidate = (compressed != nil && compressed!.count < raw.count) ? compressed! : raw
        guard candidate.count <= maxRecordBytes else {
            throw CloudZoneError.payloadTooLarge
        }
        return candidate
    }

    public static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let jsonData: Data
        if data.starts(with: lzfseMagic) {
            guard let restored = decompressLZFSE(data) else {
                throw CloudZoneError.incompatibleData
            }
            jsonData = restored
        } else {
            jsonData = data
        }
        return try JSONDecoder.syncCodec.decode(T.self, from: jsonData)
    }

    private static func compressLZFSE(_ raw: Data) -> Data? {
        guard !raw.isEmpty, raw.count <= maxUncompressedBytes else { return nil }
        let capacity = raw.count + 64
        var dst = Data(count: capacity)
        let written: Int = raw.withUnsafeBytes { srcBytes in
            guard let srcPtr = srcBytes.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return dst.withUnsafeMutableBytes { dstBytes in
                guard let dstPtr = dstBytes.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(dstPtr, capacity, srcPtr, raw.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written > 0 else { return nil }
        var out = Data()
        out.reserveCapacity(lzfseMagic.count + 4 + written)
        out.append(lzfseMagic)
        var lengthLE = UInt32(raw.count).littleEndian
        withUnsafeBytes(of: &lengthLE) { out.append(contentsOf: $0) }
        out.append(dst.prefix(written))
        return out
    }

    private static func decompressLZFSE(_ payload: Data) -> Data? {
        let headerSize = lzfseMagic.count + 4
        guard payload.count > headerSize else { return nil }
        var lengthLE: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &lengthLE) {
            payload.copyBytes(to: $0, from: lzfseMagic.count..<headerSize)
        }
        let expectedSize = Int(UInt32(littleEndian: lengthLE))
        guard expectedSize > 0, expectedSize <= maxUncompressedBytes else { return nil }
        let compressed = payload.subdata(in: headerSize..<payload.count)
        var dst = Data(count: expectedSize)
        let decoded: Int = compressed.withUnsafeBytes { srcBytes in
            guard let srcPtr = srcBytes.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return dst.withUnsafeMutableBytes { dstBytes in
                guard let dstPtr = dstBytes.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstPtr, expectedSize, srcPtr, compressed.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard decoded == expectedSize else { return nil }
        return dst
    }
}

private extension JSONEncoder {
    static var syncCodec: JSONEncoder {
        let encoder = JSONEncoder()
        return encoder
    }
}

private extension JSONDecoder {
    static var syncCodec: JSONDecoder {
        let decoder = JSONDecoder()
        return decoder
    }
}

/// Encrypted private-database zone transport for high-frequency workspace, transcript, and calendar zones.
/// Unlike `SavedJams`, routine writes do not contend on `SyncControl`'s change tag; `generation` is
/// verified via `SyncControl` on connect/fetch and embedded inside each encrypted record envelope.
@MainActor
public final class CloudEnvelopeTransport<Record: SyncZoneRecord>: CloudZoneTransporting {
    public static var defaultContainerIdentifier: String { "iCloud.dev.vsmirn0v.conferenceguest" }
    public static var maxBatchRecords: Int { 100 }
    public static var maxBatchBytes: Int { 1_200_000 }

    private struct Envelope: Codable {
        var schema = 2
        let generation: String
        let record: Record
    }

    private lazy var container = CKContainer(identifier: containerIdentifier)
    private var database: CKDatabase { container.privateCloudDatabase }
    private let containerIdentifier: String
    private let zone: CKRecordZone.ID
    private let subscriptionID: String
    private let notifications: Bool
    private var cachedSession: CloudZoneSession?
    private var cachedSessionAt: Date?
    private var subscriptionRegistered = false
    private var controlID: CKRecord.ID { .init(recordName: "SyncGeneration", zoneID: zone) }

    public init(
        zoneName: String,
        subscriptionID: String? = nil,
        containerIdentifier: String = "iCloud.dev.vsmirn0v.conferenceguest",
        notifications: Bool = true
    ) {
        self.containerIdentifier = containerIdentifier
        self.zone = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        self.subscriptionID = subscriptionID ?? (zoneName + "Changes")
        self.notifications = notifications
    }

    nonisolated public static func cloudRecordName(for syncRecordID: String) -> String {
        let digest = SHA256.hash(data: Data(syncRecordID.utf8)).map { String(format: "%02x", $0) }.joined()
        return "item-" + digest
    }

    private func recordID(for syncRecordID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: Self.cloudRecordName(for: syncRecordID), zoneID: zone)
    }

    public func connect() async throws -> CloudZoneSession {
        if let cached = cachedSession, let at = cachedSessionAt, Date().timeIntervalSince(at) < 300 {
            return cached
        }
        do {
            let status = try await container.accountStatus()
            guard status == .available else {
                cachedSession = nil
                cachedSessionAt = nil
                subscriptionRegistered = false
                throw status == .restricted ? CloudZoneError.restricted : CloudZoneError.noAccount
            }
            let account = try await container.userRecordID().recordName
            do {
                _ = try await database.recordZone(for: zone)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                _ = try await database.save(CKRecordZone(zoneID: zone))
            }
            let control: CKRecord
            do {
                control = try await database.record(for: controlID)
            } catch let error as CKError where error.code == .unknownItem {
                let new = CKRecord(recordType: "SyncControl", recordID: controlID)
                new.encryptedValues["generation"] = UUID().uuidString as CKRecordValue
                do {
                    control = try await database.save(new)
                } catch let conflict as CKError where conflict.code == .serverRecordChanged {
                    control = try await database.record(for: controlID)
                }
            }
            guard let generation = control.encryptedValues["generation"] as? String else {
                throw CloudZoneError.incompatibleData
            }
            if notifications && !subscriptionRegistered {
                let subscription = CKRecordZoneSubscription(zoneID: zone, subscriptionID: subscriptionID)
                let info = CKSubscription.NotificationInfo()
                info.shouldSendContentAvailable = true
                subscription.notificationInfo = info
                if (try? await database.save(subscription)) != nil {
                    subscriptionRegistered = true
                }
            }
            let session = CloudZoneSession(account: account, generation: generation)
            cachedSession = session
            cachedSessionAt = Date()
            return session
        } catch {
            if let ck = error as? CKError, [.zoneNotFound, .userDeletedZone].contains(ck.code) {
                cachedSession = nil
                cachedSessionAt = nil
                subscriptionRegistered = false
            }
            throw error
        }
    }

    public func fetch(session: CloudZoneSession, after data: Data?) async throws -> CloudZoneChanges<Record> {
        let token = try data.map {
            try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        } ?? nil
        do {
            return try await fetchChanges(session: session, token: token)
        } catch let error as CKError where error.code == .changeTokenExpired {
            return try await fetchChanges(session: session, token: nil)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            cachedSession = nil
            cachedSessionAt = nil
            subscriptionRegistered = false
            throw CloudZoneError.generationChanged
        } catch CloudZoneError.generationChanged {
            cachedSession = nil
            cachedSessionAt = nil
            subscriptionRegistered = false
            throw CloudZoneError.generationChanged
        }
    }

    private func fetchChanges(session: CloudZoneSession, token: CKServerChangeToken?) async throws -> CloudZoneChanges<Record> {
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = token
        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zone],
            configurationsByRecordZoneID: [zone: config]
        )
        operation.fetchAllChanges = true
        operation.qualityOfService = .utility
        let expectedControlID = controlID
        let targetZone = zone
        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var records: [Record] = []
            var deletedNames: [String] = []
            var nextToken: CKServerChangeToken?
            var failure: Error?
            operation.recordWasChangedBlock = { id, result in
                do {
                    let record = try result.get()
                    if id == expectedControlID {
                        if record.encryptedValues["generation"] as? String != session.generation {
                            throw CloudZoneError.generationChanged
                        }
                    } else if let decoded = try Self.decodeRecord(record, generation: session.generation, zone: targetZone) {
                        lock.lock()
                        records.append(decoded)
                        lock.unlock()
                    }
                } catch {
                    lock.lock()
                    failure = error
                    lock.unlock()
                }
            }
            operation.recordWithIDWasDeletedBlock = { id, _ in
                lock.lock()
                if id == expectedControlID {
                    failure = CloudZoneError.generationChanged
                } else {
                    deletedNames.append(id.recordName)
                }
                lock.unlock()
            }
            operation.recordZoneFetchResultBlock = { _, result in
                lock.lock()
                switch result {
                case .success(let value): nextToken = value.serverChangeToken
                case .failure(let error): failure = error
                }
                lock.unlock()
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                lock.lock()
                let capturedRecords = records
                let capturedDeleted = deletedNames
                let capturedToken = nextToken
                let capturedFailure = failure
                lock.unlock()
                do {
                    try result.get()
                    if let capturedFailure { throw capturedFailure }
                    let encoded = try capturedToken.map {
                        try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
                    }
                    continuation.resume(returning: CloudZoneChanges(
                        records: capturedRecords,
                        deletedCloudRecordNames: capturedDeleted,
                        token: encoded
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    public func save(_ records: [Record], session: CloudZoneSession) async throws -> [Record] {
        guard !records.isEmpty else { return [] }
        guard try await container.userRecordID().recordName == session.account else {
            throw CloudZoneError.noAccount
        }
        _ = try await verifyControl(expectedGeneration: session.generation)

        var encodedBatches: [[(record: Record, payload: Data)]] = []
        var currentBatch: [(record: Record, payload: Data)] = []
        var currentBytes = 0

        for item in records {
            let data = try CloudPayloadCodec.encode(Envelope(generation: session.generation, record: item))
            if !currentBatch.isEmpty &&
                (currentBatch.count >= Self.maxBatchRecords || currentBytes + data.count > Self.maxBatchBytes) {
                encodedBatches.append(currentBatch)
                currentBatch = []
                currentBytes = 0
            }
            currentBatch.append((item, data))
            currentBytes += data.count
        }
        if !currentBatch.isEmpty {
            encodedBatches.append(currentBatch)
        }

        var saved: [Record] = []
        for batch in encodedBatches {
            let batchSaved = try await saveBatch(batch.map(\.record), session: session, attempt: 0)
            saved.append(contentsOf: batchSaved)
        }
        return saved
    }

    private func saveBatch(_ items: [Record], session: CloudZoneSession, attempt: Int) async throws -> [Record] {
        guard !items.isEmpty else { return [] }
        let ids = items.map { recordID(for: $0.syncRecordID) }
        let existing: [CKRecord.ID: Result<CKRecord, Error>]
        do {
            existing = try await database.records(for: ids)
        } catch let error as CKError where error.code == .limitExceeded && items.count > 1 {
            let mid = items.count / 2
            let left = try await saveBatch(Array(items[..<mid]), session: session, attempt: attempt)
            let right = try await saveBatch(Array(items[mid...]), session: session, attempt: attempt)
            return left + right
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            throw CloudZoneError.generationChanged
        }

        var ckRecords: [CKRecord] = []
        var itemsByCKID: [CKRecord.ID: Record] = [:]
        var mergedByCKID: [CKRecord.ID: Record] = [:]

        for item in items {
            let id = recordID(for: item.syncRecordID)
            let ckRecord: CKRecord
            switch existing[id] {
            case .success(let serverRecord):
                ckRecord = serverRecord
            case .failure(let error as CKError) where error.code == .unknownItem:
                ckRecord = CKRecord(recordType: "RoomPreference", recordID: id)
            case .failure(let error as CKError) where error.code == .zoneNotFound || error.code == .userDeletedZone:
                throw CloudZoneError.generationChanged
            case .failure(let error):
                throw error
            case .none:
                throw CloudZoneError.incompatibleData
            }
            let merged = try decode(ckRecord, generation: session.generation).map { item.merging($0) } ?? item
            let data = try CloudPayloadCodec.encode(Envelope(generation: session.generation, record: merged))
            ckRecord.encryptedValues["payload"] = data as CKRecordValue
            ckRecords.append(ckRecord)
            itemsByCKID[id] = item
            mergedByCKID[id] = merged
        }

        do {
            let response = try await database.modifyRecords(
                saving: ckRecords,
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: false
            )
            var saved: [Record] = []
            var conflicted: [Record] = []
            for (ckID, result) in response.saveResults {
                switch result {
                case .success:
                    if let value = mergedByCKID[ckID] { saved.append(value) }
                case .failure(let error as CKError) where Self.isConflict(error):
                    if let original = itemsByCKID[ckID] { conflicted.append(original) }
                case .failure(let error as CKError) where error.code == .zoneNotFound || error.code == .userDeletedZone:
                    throw CloudZoneError.generationChanged
                case .failure(let error):
                    throw error
                }
            }
            if !conflicted.isEmpty {
                guard attempt < 3 else { throw CloudZoneError.conflict }
                let retried = try await saveBatch(conflicted, session: session, attempt: attempt + 1)
                saved.append(contentsOf: retried)
            }
            return saved
        } catch let error as CKError where error.code == .limitExceeded && items.count > 1 {
            let mid = items.count / 2
            let left = try await saveBatch(Array(items[..<mid]), session: session, attempt: attempt)
            let right = try await saveBatch(Array(items[mid...]), session: session, attempt: attempt)
            return left + right
        } catch let error as CKError where Self.isConflict(error) {
            guard attempt < 3 else { throw CloudZoneError.conflict }
            return try await saveBatch(items, session: session, attempt: attempt + 1)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            throw CloudZoneError.generationChanged
        }
    }

    public func delete(syncRecordIDs: [String], session: CloudZoneSession) async throws {
        guard !syncRecordIDs.isEmpty else { return }
        guard try await container.userRecordID().recordName == session.account else {
            throw CloudZoneError.noAccount
        }
        _ = try await verifyControl(expectedGeneration: session.generation)
        let ckIDs = syncRecordIDs.map { recordID(for: $0) }
        for offset in stride(from: 0, to: ckIDs.count, by: Self.maxBatchRecords) {
            let slice = Array(ckIDs[offset..<min(offset + Self.maxBatchRecords, ckIDs.count)])
            try await deleteBatch(slice)
        }
    }

    private func deleteBatch(_ ids: [CKRecord.ID]) async throws {
        guard !ids.isEmpty else { return }
        do {
            let result = try await database.modifyRecords(saving: [], deleting: ids, savePolicy: .ifServerRecordUnchanged, atomically: false)
            for (_, itemResult) in result.deleteResults {
                if case .failure(let error as CKError) = itemResult,
                   error.code != .unknownItem,
                   error.code != .zoneNotFound,
                   error.code != .userDeletedZone {
                    throw error
                }
            }
        } catch let error as CKError where error.code == .limitExceeded && ids.count > 1 {
            let mid = ids.count / 2
            try await deleteBatch(Array(ids[..<mid]))
            try await deleteBatch(Array(ids[mid...]))
        }
    }

    public func clear(session: CloudZoneSession) async throws {
        cachedSession = nil
        cachedSessionAt = nil
        subscriptionRegistered = false
        guard try await container.userRecordID().recordName == session.account else {
            throw CloudZoneError.noAccount
        }
        do {
            _ = try await verifyControl(expectedGeneration: session.generation)
            _ = try await database.deleteRecordZone(withID: zone)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // Already deleted.
        }
        _ = try await connect()
    }

    private func verifyControl(expectedGeneration: String) async throws -> CKRecord {
        let control: CKRecord
        do {
            control = try await database.record(for: controlID)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone || error.code == .unknownItem {
            throw CloudZoneError.generationChanged
        }
        guard control.encryptedValues["generation"] as? String == expectedGeneration else {
            throw CloudZoneError.generationChanged
        }
        return control
    }

    nonisolated private static func decodeRecord(
        _ record: CKRecord,
        generation: String,
        zone: CKRecordZone.ID
    ) throws -> Record? {
        guard let data = record.encryptedValues["payload"] as? Data else {
            if record.recordChangeTag == nil { return nil }
            throw CloudZoneError.incompatibleData
        }
        let envelope = try CloudPayloadCodec.decode(data, as: Envelope.self)
        guard envelope.schema == 2,
              envelope.record.maximumSyncCounter >= 0,
              envelope.record.maximumSyncCounter < Int64.max - 1_000_000 else {
            throw CloudZoneError.incompatibleData
        }
        guard envelope.generation == generation else {
            throw CloudZoneError.generationChanged
        }
        let expectedID = CKRecord.ID(recordName: Self.cloudRecordName(for: envelope.record.syncRecordID), zoneID: zone)
        guard expectedID == record.recordID else {
            throw CloudZoneError.incompatibleData
        }
        return envelope.record
    }

    private func decode(_ record: CKRecord, generation: String) throws -> Record? {
        try Self.decodeRecord(record, generation: generation, zone: zone)
    }

    private static func isConflict(_ error: CKError) -> Bool {
        if error.code == .serverRecordChanged { return true }
        if let partial = error.partialErrorsByItemID {
            return partial.values.contains { ($0 as? CKError).map(isConflict) ?? false }
        }
        return false
    }
}
