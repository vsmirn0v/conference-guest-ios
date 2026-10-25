import Combine
import Darwin
import Foundation

/// Serializes direct-distribution app instances and fences an update across process restarts.
/// The process that prepared an update may keep meeting until installation is reserved;
/// another launch of the old build must finish that update before admitting a meeting.
@MainActor final class NativeUpdateSafety: @preconcurrency ObservableObject {
    enum SafetyError: LocalizedError, Equatable {
        case anotherInstanceRunning
        case invalidBuild
        case updateNotPrepared
        case installerMayRun
        case unsafeState(String)

        var errorDescription: String? {
            switch self {
            case .anotherInstanceRunning: return "Another copy of RockNRoll is already running."
            case .invalidBuild: return "The update build number is invalid or older than the pending update."
            case .updateNotPrepared: return "The update has not been safely prepared."
            case .installerMayRun: return "The update installer may already be running."
            case .unsafeState(let detail): return "Update safety could not be verified: \(detail)"
            }
        }
    }

    // Publish after committing every field so synchronous observers cannot reenter
    // meeting admission between setting a reservation and closing its admission gate.
    let objectWillChange = ObservableObjectPublisher()
    private(set) var mayStartMeeting = false
    private(set) var recoveryTargetBuild: Int?
    private(set) var installationReserved = false
    private(set) var storageErrorDescription: String?

    static let fenceFileName = "update-fence.json"
    static let lockFileName = "process.lock"
    private static let maximumFenceBytes = 4_096

    private struct Fence: Codable, Equatable {
        let version: Int
        let sourceBuild: Int
        let targetBuild: Int
        let identifier: UUID
    }

    private let currentBuild: Int
    private let directoryFD: Int32
    private let processFD: Int32
    private var fence: Fence?
    private var ownedFenceID: UUID?
    private var installerMayRun = false

    init(stateDirectoryURL: URL, currentBuild: Int) throws {
        guard currentBuild > 0, stateDirectoryURL.isFileURL else { throw SafetyError.invalidBuild }
        let directory = try Self.openPrivateDirectory(stateDirectoryURL)
        var lease: Int32 = -1
        do {
            lease = try Self.acquireProcessLease(directory)
            let existing = try Self.readFence(directory)
            if let existing, currentBuild >= existing.targetBuild {
                try Self.removeFence(directory)
                fence = nil
            } else {
                fence = existing
                recoveryTargetBuild = existing?.targetBuild
            }
        } catch {
            if lease >= 0 { close(lease) }
            close(directory)
            throw error
        }
        self.currentBuild = currentBuild
        directoryFD = directory
        processFD = lease
        refreshAdmission()
    }

    deinit {
        // Do not unlink the lease file: another opener must always lock the same inode.
        close(processFD)
        close(directoryFD)
    }

    /// Must complete before handing the update to Sparkle for downloading or presenting.
    /// Re-preparing a recovery never makes the old process eligible to join meetings.
    func prepareUpdate(targetBuild: Int) throws {
        try requireHealthyStorage()
        guard targetBuild > currentBuild,
              targetBuild >= (fence?.targetBuild ?? targetBuild) else { throw SafetyError.invalidBuild }
        try persistSafely {
            try verifyFenceUnchanged()
            if fence?.targetBuild == targetBuild { return }
            guard !installerMayRun, !installationReserved else { throw SafetyError.installerMayRun }
            let next = Fence(version: 1, sourceBuild: currentBuild, targetBuild: targetBuild, identifier: UUID())
            try Self.writeFence(next, directoryFD)
            fence = next
            if recoveryTargetBuild == nil { ownedFenceID = next.identifier }
            else { recoveryTargetBuild = targetBuild }
        }
        refreshAdmission()
    }

    /// The busy check and reservation run synchronously on the meeting admission actor.
    @discardableResult func reserveInstallation(busy: Bool) throws -> Bool {
        try requireHealthyStorage()
        guard fence != nil else { throw SafetyError.updateNotPrepared }
        try persistSafely { try verifyFenceUnchanged() }
        guard !busy else { return false }
        installationReserved = true
        refreshAdmission()
        return true
    }

    /// Call synchronously before Sparkle can extract or start any installer helper.
    /// Ordinary updater completion/error callbacks must not erase this durable fence.
    func markInstallerMayRun() {
        installerMayRun = true
        if fence == nil {
            storageErrorDescription = SafetyError.updateNotPrepared.localizedDescription
        }
        refreshAdmission()
    }

    /// A decline/cancellation is reversible only before an installer could have started,
    /// and only the process that created this exact fence may cancel it.
    @discardableResult func clearPreparedUpdateIfSafe() throws -> Bool {
        try requireHealthyStorage()
        guard !installerMayRun, let ownedFenceID, fence?.identifier == ownedFenceID else { return false }
        try persistSafely {
            try verifyFenceUnchanged()
            try Self.removeFence(directoryFD)
            fence = nil
            self.ownedFenceID = nil
            installationReserved = false
        }
        refreshAdmission()
        return true
    }

    func releaseReservationBeforeInstall() throws {
        try requireHealthyStorage()
        guard !installerMayRun else { throw SafetyError.installerMayRun }
        installationReserved = false
        refreshAdmission()
    }

    /// The caller must have positive evidence that stage 2/termination was never requested.
    /// This only releases this process; the durable fence still blocks a restarted old app.
    func releaseReservationAfterVerifiedStage2NotRequested() {
        installationReserved = false
        refreshAdmission()
    }

    private func refreshAdmission() {
        mayStartMeeting = !installationReserved && recoveryTargetBuild == nil && storageErrorDescription == nil
        objectWillChange.send()
    }

    private func requireHealthyStorage() throws {
        if let storageErrorDescription { throw SafetyError.unsafeState(storageErrorDescription) }
    }

    private func persistSafely(_ operation: () throws -> Void) throws {
        do { try operation() }
        catch let error as SafetyError where error == .installerMayRun { throw error }
        catch {
            storageErrorDescription = error.localizedDescription
            refreshAdmission()
            throw error
        }
    }

    private func verifyFenceUnchanged() throws {
        guard try Self.readFence(directoryFD) == fence else {
            throw SafetyError.unsafeState("The pending update changed outside this process.")
        }
    }

    private static func openPrivateDirectory(_ url: URL) throws -> Int32 {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw SafetyError.unsafeState("The private update directory could not be created.") }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ioError("Open update directory") }
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw ioError("Inspect update directory") }
            guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == geteuid(),
                  metadata.st_mode & 0o077 == 0, metadata.st_mode & 0o700 == 0o700 else {
                throw SafetyError.unsafeState("The update directory is not private and owned by this user.")
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private static func acquireProcessLease(_ directory: Int32) throws -> Int32 {
        let descriptor = openat(directory, lockFileName, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw ioError("Open process lease") }
        do {
            try validatePrivateFile(descriptor)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK { throw SafetyError.anotherInstanceRunning }
                throw ioError("Acquire process lease")
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private static func validatePrivateFile(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw ioError("Inspect update state") }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(),
              metadata.st_mode & 0o777 == 0o600, metadata.st_nlink == 1 else {
            throw SafetyError.unsafeState("The update state is not a private regular file.")
        }
    }

    private static func readFence(_ directory: Int32) throws -> Fence? {
        let descriptor = openat(directory, fenceFileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw ioError("Open pending update")
        }
        defer { close(descriptor) }
        try validatePrivateFile(descriptor)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw ioError("Measure pending update") }
        guard metadata.st_size > 0, metadata.st_size <= maximumFenceBytes else {
            throw SafetyError.unsafeState("The pending update record has an invalid size.")
        }
        var bytes = [UInt8](repeating: 0, count: maximumFenceBytes + 1)
        var count = 0
        while count < bytes.count {
            let readCount = bytes.withUnsafeMutableBytes { buffer in
                read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw ioError("Read pending update")
            }
            if readCount == 0 { break }
            count += readCount
        }
        guard count == metadata.st_size, count <= maximumFenceBytes else {
            throw SafetyError.unsafeState("The pending update record changed while being read.")
        }
        let decoded: Fence
        do { decoded = try JSONDecoder().decode(Fence.self, from: Data(bytes.prefix(count))) }
        catch { throw SafetyError.unsafeState("The pending update record is corrupt.") }
        guard decoded.version == 1, decoded.sourceBuild > 0, decoded.targetBuild > decoded.sourceBuild else {
            throw SafetyError.unsafeState("The pending update record has invalid build numbers.")
        }
        return decoded
    }

    private static func writeFence(_ fence: Fence, _ directory: Int32) throws {
        let data = try JSONEncoder().encode(fence)
        let temporaryName = ".update-fence-\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporaryName, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ioError("Create pending update") }
        defer { close(descriptor); unlinkat(directory, temporaryName, 0) }
        guard fchmod(descriptor, 0o600) == 0 else { throw ioError("Protect pending update") }
        try data.withUnsafeBytes { buffer in
            var count = 0
            while count < buffer.count {
                let written = write(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw ioError("Write pending update") }
                count += written
            }
        }
        guard fsync(descriptor) == 0 else { throw ioError("Flush pending update") }
        guard renameat(directory, temporaryName, directory, fenceFileName) == 0 else {
            throw ioError("Publish pending update")
        }
        guard fsync(directory) == 0 else { throw ioError("Flush update directory") }
    }

    private static func removeFence(_ directory: Int32) throws {
        guard unlinkat(directory, fenceFileName, 0) == 0 else { throw ioError("Retire pending update") }
        guard fsync(directory) == 0 else { throw ioError("Flush retired update") }
    }

    private static func ioError(_ operation: String) -> SafetyError {
        .unsafeState("\(operation) failed (\(errno)).")
    }
}
