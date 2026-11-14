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

/// Preparation needs compiler scratch space in addition to the downloaded files.
/// This conservative 12 GiB working-space budget is an estimate for the pinned
/// VoxCPM2 bundle, not a measured minimum or a guarantee of successful compilation.
/// A real base-model repair exhausted a compiler temporary file beyond 4.6 GiB;
/// other compiler outputs, cached specializations and concurrent disk use need room too.
enum VoicePreparationStorage {
    static let estimatedRequiredBytes: Int64 = 12 * 1_024 * 1_024 * 1_024
    static let compilerTemporaryFolder = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)

    /// ANE compilation allocates temporary files outside the app's model folder.
    /// Reclaimable "important usage" capacity can overstate what its allocator
    /// can use immediately, so preparation deliberately uses current free bytes.
    static func immediatelyAvailableCapacity(at path: URL) -> Int64? {
        guard let existing = VoiceStorage.existingAncestor(of: path),
              let value = try? existing.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
              value >= 0 else { return nil }
        return Int64(value)
    }

    static func snapshot(
        at modelFolder: URL,
        cacheFolder: URL? = nil,
        compilerTemporaryFolder: URL = compilerTemporaryFolder,
        capacity: (URL) -> Int64? = immediatelyAvailableCapacity,
        sameVolume: (URL, URL) -> Bool? = VoiceStorage.sameVolume
    ) -> VoiceStorageSnapshot {
        // The worker's default CoreAI cache was observed under its Application
        // Support directory. Measure that volume without depending on a private
        // cache subdirectory name or reading its contents.
        let cacheFolder = cacheFolder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        var locations: [(URL, VoiceStorageSnapshot.Location)] = [(modelFolder, .model)]
        if let cacheFolder { locations.append((cacheFolder, .model)) }
        locations.append((compilerTemporaryFolder, .temporary))

        // Do not add the estimate repeatedly for paths sharing a volume. Sampling
        // can race other disk users, so retain the lower known reading in a group.
        var volumes: [(paths: [URL], available: Int64?, location: VoiceStorageSnapshot.Location)] = []
        for (path, location) in locations {
            let available = capacity(path).flatMap { $0 >= 0 ? $0 : nil }
            if let index = volumes.firstIndex(where: { group in
                group.paths.contains { sameVolume(path, $0) == true }
            }) {
                volumes[index].paths.append(path)
                if let available {
                    volumes[index].available = min(volumes[index].available ?? available, available)
                }
            } else {
                volumes.append(([path], available, location))
            }
        }
        // A known deficit on any relevant volume is actionable. Unknown capacity
        // never invents a deficit, even if the other volume has sufficient space.
        let constrained = volumes.filter { $0.available != nil }.min { $0.available! < $1.available! }
        return .init(availableBytes: constrained?.available, requiredBytes: estimatedRequiredBytes,
                     location: constrained?.location)
    }

    static func ensureSpace(
        at modelFolder: URL,
        cacheFolder: URL? = nil,
        compilerTemporaryFolder: URL = compilerTemporaryFolder,
        capacity: (URL) -> Int64? = immediatelyAvailableCapacity,
        sameVolume: (URL, URL) -> Bool? = VoiceStorage.sameVolume
    ) throws {
        let value = snapshot(at: modelFolder, cacheFolder: cacheFolder, compilerTemporaryFolder: compilerTemporaryFolder,
                             capacity: capacity, sameVolume: sameVolume)
        if value.shortfallBytes != nil { throw VoicePreparationStorageError(snapshot: value) }
    }
}

struct VoicePreparationStorageError: LocalizedError, Equatable, Sendable {
    let snapshot: VoiceStorageSnapshot
    var errorDescription: String? { "Voice preparation needs more free working space." }
}
