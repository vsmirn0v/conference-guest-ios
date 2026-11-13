import CryptoKit
import Darwin
import Foundation

/// A receipt is for one pinned asset set and specialization environment.
struct ClonedVoicePreparation: Codable, Equatable {
    enum State: String, Codable { case preparing, ready, failed }

    /// Advance when changing the loader, specialization options or smoke probe.
    private static let runtime = "voxcpm2-coreai-worker-default-v2"
    static let retryLimit = 3
    static let retryInterval: TimeInterval = 60 * 60

    var identity: String
    var attempt: UUID
    var state: State
    var startedAt: Date
    var recentStarts: [Date]
    var message: String?
    var repairAsset: String?
    var repairedAssets: [String]?
    /// Backwards-compatible diagnosis. Disk measurements are deliberately omitted.
    var failureInfo: ClonedVoiceFailure?
    /// User-initiated storage rechecks/repairs have a short separate cooldown so
    /// an exhausted normal retry budget does not prevent recovery after cleanup.
    var recoveryStarts: [Date]?

    static func identity(for model: ListenModelCatalog.Model, osBuild: String = systemBuild) -> String {
        let pinnedFiles = model.files.sorted { $0.name < $1.name }.map {
            "\($0.name) \($0.size) \($0.sha256)"
        }
        let architecture = model.config["architecture"] ?? "unknown"
        let fields = [runtime, model.id, osBuild, architecture] + pinnedFiles
        return SHA256.hash(data: Data(fields.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func read(_ folder: URL, identity: String) -> Self? {
        guard let data = try? Data(contentsOf: recordURL(folder)),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.identity == identity else { return nil }
        return value
    }

    func write(_ folder: URL) throws {
        var safe = self
        safe.failureInfo = failureInfo?.withoutStorageMeasurement
        try JSONEncoder().encode(safe).write(to: Self.recordURL(folder), options: .atomic)
    }

    private static func recordURL(_ folder: URL) -> URL {
        folder.appendingPathComponent(".voice-preparation-v1.json")
    }

    static let systemBuild: String = {
        var length = 0
        guard sysctlbyname("kern.osversion", nil, &length, nil, 0) == 0, length > 0 else {
            return ProcessInfo.processInfo.operatingSystemVersionString
        }
        var result = [CChar](repeating: 0, count: length)
        guard sysctlbyname("kern.osversion", &result, &length, nil, 0) == 0 else {
            return ProcessInfo.processInfo.operatingSystemVersionString
        }
        return String(cString: result)
    }()
}
