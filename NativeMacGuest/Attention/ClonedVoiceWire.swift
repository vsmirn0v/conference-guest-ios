import Darwin
import Foundation

/// A user-facing diagnosis. Storage measurements are transient and never written
/// to the preparation receipt or emitted to diagnostics.
struct ClonedVoiceFailure: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case storage, preparationSpace, compilation, cache, unknown, busy, interrupted, rateLimited }
    var kind: Kind
    var storage: VoiceStorageSnapshot?
    var technicalDetails: String?
    var repairAsset: String?
    var failedAt: Date?
    var retryAfter: Date?
    /// Which independent budget blocked the last action, when rate-limited.
    var rateLimitedRepair: Bool?
    var rateLimitedStorage: Bool?
    /// Bounded technical metadata, never speech, voice features or filesystem paths.
    var asset: String?
    var errorDomain: String?
    var errorCode: Int?

    var repairAvailable: Bool { (kind == .cache || kind == .preparationSpace || kind == .busy || kind == .interrupted || kind == .rateLimited) && repairAsset != nil }

    var preparationRecovery: Bool { kind == .storage || kind == .preparationSpace || kind == .compilation }

    /// Persist the failure category, not a fingerprint of the Mac's disk usage.
    var withoutStorageMeasurement: Self {
        var copy = self; copy.storage = nil; return copy
    }

    /// Persist enough to diagnose a worker failure without recording speech,
    /// enrollment features, disk measurements or arbitrary error descriptions.
    var diagnosticFields: [String: Any] {
        var fields: [String: Any] = ["kind": kind.rawValue, "repairAvailable": repairAvailable]
        let identifierCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        for (key, value) in [("asset", asset ?? repairAsset), ("domain", errorDomain)] {
            if let value, !value.isEmpty, value.count <= 160,
               value.unicodeScalars.allSatisfy(identifierCharacters.contains), !value.contains("..") {
                fields[key] = value
            }
        }
        if let errorCode { fields["code"] = errorCode }
        return fields
    }
}

/// A private, bounded protocol between the app and its bundled speech helper.
/// Requests carry only the installed model path and an optional text/voice pair.
enum ClonedVoiceWire {
    struct Request: Codable, Equatable, Sendable {
        enum Operation: String, Codable, Sendable { case ping, cacheScope, prepare, speak }
        var operation: Operation
        var folder: URL?
        var text: String?
        var voice: VoxVoice?
        var repairAsset: String?
    }

    struct Response: Codable, Sendable {
        enum Failure: String, Codable, Sendable { case busy, context, runtime }
        enum Stage: String, Codable, Sendable { case load, validate, synthesize }
        var stage: Stage?
        var failure: Failure?
        var message: String?
        var repairAsset: String?
        var failureInfo: ClonedVoiceFailure?
        /// A cache entry actually removed during this request, even if later work failed.
        var repairedAsset: String?
        var pcm: Bool = false
        var memoryBytes: UInt64?
    }

    static let controlLimit = 4 * 1024 * 1024
    // 4,096 patches at 4 × 1,920 samples, float32 mono.
    static let pcmLimit = 128 * 1024 * 1024

    static func read(from handle: FileHandle, limit: Int) throws -> Data? {
        guard let header = try readExactly(4, from: handle, allowEOF: true) else { return nil }
        let count = Int(header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard count > 0, count <= limit else { throw ClonedVoiceWorkerError.protocolFailure }
        return try readExactly(count, from: handle)
    }

    static func write(_ data: Data, to handle: FileHandle, limit: Int) throws {
        guard !data.isEmpty, data.count <= limit else { throw ClonedVoiceWorkerError.protocolFailure }
        var count = UInt32(data.count).littleEndian
        try withUnsafeBytes(of: &count) { try handle.write(contentsOf: $0) }
        try handle.write(contentsOf: data)
    }

    private static func readExactly(_ count: Int, from handle: FileHandle, allowEOF: Bool = false) throws -> Data? {
        var bytes = Data()
        while bytes.count < count {
            guard let part = try handle.read(upToCount: min(count - bytes.count, 1024 * 1024)), !part.isEmpty else {
                if allowEOF && bytes.isEmpty { return nil }
                throw ClonedVoiceWorkerError.protocolFailure
            }
            bytes.append(part)
        }
        return bytes
    }

    static func validatePCM(_ samples: [Float]) throws {
        guard samples.count >= 4_800 else { throw VoxError.audio("less than 100 ms of PCM") }
        var sum = 0.0
        for sample in samples {
            guard sample.isFinite else { throw VoxError.audio("non-finite PCM") }
            sum += Double(sample) * Double(sample)
        }
        guard sum / Double(samples.count) > 0.000_000_01 else { throw VoxError.audio("silent PCM") }
    }
}

enum ClonedVoiceWorkerError: LocalizedError, Equatable {
    case busy, stopped, timeout, protocolFailure, unavailable
    case context(String), runtime(String, repairAsset: String? = nil)
    case diagnosed(ClonedVoiceFailure, repairedAsset: String? = nil)

    var errorDescription: String? {
        switch self {
        case .busy: "The cloned voice worker is busy. Try again after the current request finishes."
        case .stopped: "The cloned voice worker stopped."
        case .timeout: "The cloned voice worker reached its time limit. Try Again in Voice settings."
        case .protocolFailure: "The cloned voice worker returned an incomplete or invalid response."
        case .unavailable: "The cloned voice worker could not start."
        case .context(let message), .runtime(let message, _): message
        case .diagnosed(let failure, _): failure.technicalDetails ?? "The cloned voice worker failed."
        }
    }
}

/// Advisory ownership survives competing app instances and releases on process exit.
/// Keep the lock file next to the model directory, where Delete Model cannot unlink it.
final class ClonedVoiceLease {
    private let descriptor: Int32

    init(folder: URL, purpose: String) throws {
        let url = folder.deletingLastPathComponent().appendingPathComponent(".\(folder.lastPathComponent).\(purpose).lock")
        descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { throw ClonedVoiceWorkerError.busy }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    deinit { close(descriptor) }
}
