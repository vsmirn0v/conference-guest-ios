import CryptoKit
import Darwin
import Foundation

struct ParticipationReceipt: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        case reserved, cancelled, failed, unknown, serverAccepted, confirmed, voicePlayed, voiceInterrupted

        var title: String {
            switch self {
            case .reserved, .unknown: L("Delivery unknown · Check chat")
            case .cancelled: L("Cancelled")
            case .failed: L("Send failed")
            case .serverAccepted: L("Accepted by the service")
            case .confirmed: L("Observed in meeting chat")
            case .voicePlayed: L("Played into meeting audio")
            case .voiceInterrupted: L("Speech interrupted")
            }
        }
    }

    let id: String
    let sessionID: UUID
    let grantID: UUID
    let payloadHash: String
    let evidenceRevisions: [String]
    let createdAt: Date
    var updatedAt: Date
    var state: State
    let providerMessageID: String?
    var output: ParticipationOutput?

    var title: String {
        if output == .voice, state == .reserved || state == .unknown { return L("Voice playback unknown") }
        return state.title
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct ParticipationReceiptStore {
    let root: URL

    private var directory: URL { root.appendingPathComponent("participation-receipts-v1", isDirectory: true) }

    private func file(for receipt: ParticipationReceipt) -> URL {
        directory.appendingPathComponent(receipt.sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(receipt.id).appendingPathExtension("json")
    }

    /// Reservation precedes transport enqueue. O_EXCL makes duplicates fail
    /// closed across process instances. A partial reservation remains a fence.
    func reserve(_ receipt: ParticipationReceipt) throws {
        let url = file(for: receipt)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: JSONEncoder().encode(receipt))
        try handle.synchronize()
        try synchronize(parent)
        try synchronize(directory)
        try synchronize(root)
    }

    func update(_ receipt: ParticipationReceipt) throws {
        let url = file(for: receipt)
        let existing = try JSONDecoder().decode(ParticipationReceipt.self, from: Data(contentsOf: url))
        guard existing.grantID == receipt.grantID, existing.payloadHash == receipt.payloadHash else {
            throw POSIXError(.EPERM)
        }
        try JSONEncoder().encode(receipt).write(to: url, options: .atomic)
    }

    func receipts(for sessionID: UUID) throws -> [ParticipationReceipt] {
        let folder = directory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles)
        return try files.filter { $0.pathExtension == "json" }.map {
            try JSONDecoder().decode(ParticipationReceipt.self, from: Data(contentsOf: $0))
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private func synchronize(_ folder: URL) throws {
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
