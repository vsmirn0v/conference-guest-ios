import CryptoKit
import Foundation

/// Coordinated read → backup → temp write → atomic replace → verify for vault files.
/// A byte-exact backup is written into the app container (never the vault) before an
/// existing shared file is replaced; backup failure blocks the destructive write.
actor ObsidianFileWriter {
    struct FileIdentity: Equatable {
        var size: Int
        var modificationDate: Date?
        var sha256: String

        static func fingerprint(_ url: URL) throws -> FileIdentity? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return FileIdentity(
                size: data.count,
                modificationDate: attributes?[.modificationDate] as? Date,
                sha256: Self.hash(data))
        }

        static func hash(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Fault points for tests: inject failures around each durability boundary.
    enum Fault: String, CaseIterable {
        case beforeBackup, afterBackupBeforeReplace, afterReplace, beforeVerify
    }

    private let backupRoot: URL
    private var injectedFaults: Set<Fault> = []
    static let maxBackupsPerFile = 20
    static let backupRetention: TimeInterval = 30 * 24 * 3600

    init(backupRoot: URL) {
        self.backupRoot = backupRoot
    }

    func injectFaults(_ faults: Set<Fault>) { injectedFaults = faults }

    struct WriteOutcome {
        var identity: FileIdentity
        var backupURL: URL?
    }

    /// Writes `content` to `target` atomically. `expectedIdentity` nil means the file
    /// must not exist yet (creation); a mismatch means an external writer raced us and
    /// the caller re-evaluates with fresh bytes — nothing is overwritten from a stale read.
    func write(target: URL, content: String, expectedIdentity: FileIdentity?) throws -> WriteOutcome {
        let existing = try FileIdentity.fingerprint(target)
        if let expectedIdentity, existing != expectedIdentity {
            throw ObsidianExportError.destinationChanged
        }
        if expectedIdentity == nil, existing != nil {
            throw ObsidianExportError.destinationChanged
        }
        let bytes = Data(content.utf8)
        var backup: URL? = nil
        if let existing {
            try checkFault(.beforeBackup, target: target)
            backup = try makeBackup(of: target)
            try checkFault(.afterBackupBeforeReplace, target: target)
        }
        let temp = target.deletingLastPathComponent().appendingPathComponent(
            ".\(target.lastPathComponent).rocknroll-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: temp.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: temp, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temp.path)
            try replace(temp: temp, target: target)
            try checkFault(.afterReplace, target: target)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        try checkFault(.beforeVerify, target: target)
        guard let written = try FileIdentity.fingerprint(target), written.sha256 == FileIdentity.hash(bytes) else {
            throw ObsidianExportError.verifyFailed(target.lastPathComponent)
        }
        return WriteOutcome(identity: written, backupURL: backup)
    }

    private func replace(temp: URL, target: URL) throws {
        // Atomic rename within one directory; a crash leaves either the old or the new
        // complete file, never a partial one.
        _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
    }

    private func makeBackup(of url: URL) throws -> URL {
        let data = try Data(contentsOf: url)
        let folder = backupRoot.appendingPathComponent(Self.safeBackupName(for: url), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = folder.appendingPathComponent(stamp + ".md")
        try data.write(to: backup, options: .atomic)
        try pruneBackups(in: folder, keepingLatest: Self.maxBackupsPerFile)
        return backup
    }

    /// Keeps the newest N backups newer than the retention window; the sole recovery
    /// copy is never pruned.
    private func pruneBackups(in folder: URL, keepingLatest limit: Int) throws {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.compactMap { url -> (URL, Date)? in
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
            return (url, date)
        }.sorted { $0.1 > $1.1 }
        let cutoff = Date().addingTimeInterval(-Self.backupRetention)
        for (index, entry) in dated.enumerated() {
            let beyondLimit = index >= limit
            let expired = entry.1 < cutoff
            if (beyondLimit || expired), dated.count > 1 {
                try? FileManager.default.removeItem(at: entry.0)
            }
        }
    }

    /// Backup folder name from the vault-relative path: safe, non-secret components only.
    static func safeBackupName(for url: URL) -> String {
        url.path.replacingOccurrences(of: "/", with: "_").prefix(120).description
    }

    private func checkFault(_ fault: Fault, target: URL) throws {
        if injectedFaults.contains(fault) {
            throw ObsidianExportError.verifyFailed("injected fault at \(fault.rawValue) for \(target.lastPathComponent)")
        }
    }
}
