import CryptoKit
import Darwin
import Foundation

/// A separately selected Markdown file. This authority is independent of Obsidian export.
/// Callers must hold an active macOS security-scoped bookmark while using this reader.
struct ParticipationKnowledgeSnapshot: Equatable, Sendable {
    let relativePath: String
    let title: String
    let markdown: String
    let revision: String
    let rootDevice: UInt64
    let rootInode: UInt64
    let fileDevice: UInt64
    let fileInode: UInt64
}

struct ParticipationKnowledgeAudience: Equatable, Sendable {
    let sessionID: UUID
    let roomIdentity: String
    let rosterEpoch: UInt64
}

/// Constructed by native UI after the user reviews the exact source and audience.
/// A template or access to the export vault must never create this grant implicitly.
struct ParticipationKnowledgeGrant: Equatable, Sendable {
    let id: UUID
    let revision: UInt64
    let source: ParticipationKnowledgeSnapshot
    let audience: ParticipationKnowledgeAudience
    let allowedProcessors: Set<String>
    let expiresAt: Date
}

enum ParticipationKnowledgeError: Error, Equatable {
    case invalidPath, inaccessible, unsupportedFile, tooLarge, invalidText
    case nonlocalVolume, sourceChanged, audienceChanged, processorDenied, expired, revoked
}

/// Exact-file, read-only access. It deliberately does not walk links or resolve embeds.
/// Each path component is opened relative to its already-open parent without following
/// symlinks, so a concurrent rename cannot redirect the read outside the selected root.
enum ParticipationKnowledgeReader {
    static let maxBytes = 1_048_576

    static func inspect(root: URL, relativePath: String, byteLimit: Int = maxBytes) throws -> ParticipationKnowledgeSnapshot {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard root.isFileURL, !relativePath.hasPrefix("/"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") && !$0.contains("\0") }),
              (parts.last! as NSString).pathExtension.lowercased() == "md" else {
            throw ParticipationKnowledgeError.invalidPath
        }
        let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw ParticipationKnowledgeError.inaccessible }
        defer { Darwin.close(rootFD) }
        try requireLocalVolume(rootFD)
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw ParticipationKnowledgeError.inaccessible
        }
        var parent = rootFD
        var opened: [Int32] = []
        defer { for descriptor in opened.reversed() { Darwin.close(descriptor) } }
        for component in parts.dropLast() {
            let descriptor = component.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard descriptor >= 0 else { throw ParticipationKnowledgeError.inaccessible }
            opened.append(descriptor)
            try requireLocalVolume(descriptor)
            parent = descriptor
        }
        let descriptor = parts.last!.withCString { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw ParticipationKnowledgeError.inaccessible }
        opened.append(descriptor)
        try requireLocalVolume(descriptor)
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1 else { throw ParticipationKnowledgeError.unsupportedFile }
        guard before.st_size >= 0, before.st_size <= byteLimit else { throw ParticipationKnowledgeError.tooLarge }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw ParticipationKnowledgeError.inaccessible
            }
            if count == 0 { break }
            guard bytes.count + count <= byteLimit else { throw ParticipationKnowledgeError.tooLarge }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              Int64(bytes.count) == after.st_size else { throw ParticipationKnowledgeError.sourceChanged }
        guard let markdown = String(data: bytes, encoding: .utf8), !markdown.contains("\0") else {
            throw ParticipationKnowledgeError.invalidText
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return ParticipationKnowledgeSnapshot(relativePath: relativePath,
            title: (parts.last! as NSString).deletingPathExtension, markdown: markdown,
            revision: digest, rootDevice: UInt64(rootInfo.st_dev), rootInode: UInt64(rootInfo.st_ino),
            fileDevice: UInt64(before.st_dev), fileInode: UInt64(before.st_ino))
    }

    private static func requireLocalVolume(_ descriptor: Int32) throws {
        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0 else { throw ParticipationKnowledgeError.inaccessible }
        guard filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw ParticipationKnowledgeError.nonlocalVolume }
    }

    /// Re-read immediately before public use; a changed file is never silently approved.
    static func readAuthorized(root: URL, grant: ParticipationKnowledgeGrant,
                               audience: ParticipationKnowledgeAudience, processor: String,
                               now: Date = Date()) throws -> ParticipationKnowledgeSnapshot {
        guard now < grant.expiresAt else { throw ParticipationKnowledgeError.expired }
        guard grant.audience == audience else { throw ParticipationKnowledgeError.audienceChanged }
        guard grant.allowedProcessors.contains(processor) else { throw ParticipationKnowledgeError.processorDenied }
        let current = try inspect(root: root, relativePath: grant.source.relativePath)
        guard current.rootDevice == grant.source.rootDevice, current.rootInode == grant.source.rootInode,
              current.fileDevice == grant.source.fileDevice, current.fileInode == grant.source.fileInode,
              current.revision == grant.source.revision else { throw ParticipationKnowledgeError.sourceChanged }
        return current
    }
}

/// Process-local authority for explicitly approved sources. The caller must also
/// serialize the final send against changes to this authority and the meeting grant.
final class ParticipationKnowledgeScope: @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [UUID: ParticipationKnowledgeGrant] = [:]

    func approve(_ grant: ParticipationKnowledgeGrant) {
        lock.lock(); defer { lock.unlock() }
        grants[grant.id] = grant
    }

    func revoke(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        grants.removeValue(forKey: id)
    }

    func read(root: URL, id: UUID, audience: ParticipationKnowledgeAudience,
              processor: String, now: Date = Date()) throws -> ParticipationKnowledgeSnapshot {
        lock.lock()
        let grant = grants[id]
        lock.unlock()
        guard let grant else { throw ParticipationKnowledgeError.revoked }
        let source = try ParticipationKnowledgeReader.readAuthorized(root: root, grant: grant,
            audience: audience, processor: processor, now: now)
        lock.lock()
        let stillCurrent = grants[id] == grant
        lock.unlock()
        guard stillCurrent else { throw ParticipationKnowledgeError.revoked }
        return source
    }

    /// Identity check only. The executor must re-read the source and serialize its
    /// dispatch against revocation and pause; this alone does not authorize a send.
    func contains(_ grant: ParticipationKnowledgeGrant) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return grants[grant.id] == grant
    }
}
