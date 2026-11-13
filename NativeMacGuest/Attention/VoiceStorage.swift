import Foundation

/// Storage measurements are local, transient UI state. Do not log or export them.
struct VoiceStorageSnapshot: Codable, Equatable, Sendable {
    enum Location: String, Codable, Sendable { case model, temporary }
    var availableBytes: Int64?
    /// Estimated total headroom on the measured volume, not the shortfall.
    var requiredBytes: Int64?
    var location: Location?

    init(availableBytes: Int64? = nil, requiredBytes: Int64? = nil, location: Location? = nil) {
        self.availableBytes = availableBytes
        self.requiredBytes = requiredBytes
        self.location = location
    }

    var shortfallBytes: Int64? {
        guard let availableBytes, let requiredBytes, availableBytes >= 0, requiredBytes > availableBytes else { return nil }
        return requiredBytes - availableBytes
    }
}

enum VoiceStorage {
    /// Query an existing ancestor: the model folder may not have been created yet.
    static func existingAncestor(of path: URL) -> URL? {
        guard path.isFileURL else { return nil }
        var candidate = path.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
        return candidate
    }

    static func capacity(at path: URL) -> Int64? {
        guard let existing = existingAncestor(of: path),
              let value = try? existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage,
              value >= 0 else { return nil }
        return value
    }

    /// An unknown volume is not evidence that a copy requires extra space.
    static func sameVolume(_ first: URL, _ second: URL) -> Bool? {
        guard let first = existingAncestor(of: first), let second = existingAncestor(of: second),
              let a = try? first.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject,
              let b = try? second.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject else { return nil }
        return a.isEqual(b)
    }

    /// Counts only unverified files, less any existing bytes that their replacement
    /// will free. This is a minimum destination requirement; temporary files and
    /// concurrent disk use can make the actual requirement greater.
    struct DownloadFile: Equatable {
        var bytes: Int64
        var existingBytes: Int64
        var verified: Bool
    }

    static func downloadDestinationMinimum(_ files: [DownloadFile]) -> Int64? {
        var total: Int64 = 0
        for file in files where !file.verified {
            guard file.bytes >= 0, file.existingBytes >= 0 else { return nil }
            // A larger replaced file can release space for a later one. Treating
            // every file independently would overstate the minimum and could
            // incorrectly block a valid retry.
            let difference = file.bytes - file.existingBytes
            let (next, overflow) = total.addingReportingOverflow(difference)
            guard !overflow else { return nil }
            total = next
        }
        return max(0, total)
    }

    /// Once URLSession has returned the actual temporary URL, a cross-volume move
    /// requires a copy on the destination. A same-volume move is a rename.
    static func moveRequirement(bytes: Int64, sameVolume: Bool?) -> Int64? {
        guard bytes >= 0, let sameVolume else { return nil }
        return sameVolume ? 0 : bytes
    }

    /// Opaque framework failures must never be reclassified as disk-full.
    static func isOutOfSpace(_ error: Error) -> Bool {
        var pending = [error as NSError], seen = Set<ObjectIdentifier>()
        while let current = pending.popLast(), seen.count < 32 {
            guard seen.insert(ObjectIdentifier(current)).inserted else { continue }
            if current.domain == NSPOSIXErrorDomain && current.code == Int(POSIXErrorCode.ENOSPC.rawValue) { return true }
            if current.domain == NSCocoaErrorDomain && current.code == NSFileWriteOutOfSpaceError { return true }
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError { pending.append(underlying) }
            if let underlying = current.userInfo["NSMultipleUnderlyingErrors"] as? [NSError] { pending.append(contentsOf: underlying) }
        }
        return false
    }
}
