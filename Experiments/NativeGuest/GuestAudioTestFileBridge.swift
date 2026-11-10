#if DEBUG
import CryptoKit
import Darwin
import Foundation

enum GuestAudioTestBridgeError: Error {
    case invalidDescriptor, descriptorAlias, invalidFrame, oversized, io(Int32), archiveFailed, closed
}

/// Explicit inherited file capabilities only. Never opens an external path.
/// Container IPC remains the default when these environment entries are absent.
final class GuestAudioTestFileBridge: @unchecked Sendable {
    struct Descriptors {
        var command: Int32?, response: Int32?, speech: Int32?, archive: Int32?
    }
    struct Envelope: Codable {
        let version: Int, sequence: UInt64, generation: String, size: Int, sha256: String, payload: Data
    }
    enum Artifact {
        case telemetry, response, receiverResponse, fixtureFinal
        case command(UUID), phaseStart(UUID), phaseEnd(UUID), localReference(UUID), remoteMicrophone(UUID), remoteMetadata(UUID)
        case customCapturePostProcessing(UUID)
        var name: String {
            switch self {
            case .telemetry: return "acoustic-telemetry.json"
            case .response: return "acoustic-response.json"
            case .receiverResponse: return "acoustic-receiver-response.json"
            case .fixtureFinal: return "acoustic-fixture-final.json"
            case .command(let id): return "command-\(id.uuidString).json"
            case .phaseStart(let id): return "phase-\(id.uuidString)-start.json"
            case .phaseEnd(let id): return "phase-\(id.uuidString)-end.json"
            case .localReference(let id): return "local-decoded-reference-\(id.uuidString).wav"
            case .remoteMicrophone(let id): return "remote-microphone-\(id.uuidString).wav"
            case .remoteMetadata(let id): return "remote-microphone-\(id.uuidString).json"
            case .customCapturePostProcessing(let id): return "custom-capture-post-processing-\(id.uuidString).wav"
            }
        }
        var maximumBytes: Int { name.hasSuffix(".wav") ? 12_000_044 : 524_288 }
        static func json(named name: String) -> Self? {
            switch name {
            case "acoustic-telemetry.json": return .telemetry
            case "acoustic-response.json": return .response
            case "acoustic-receiver-response.json": return .receiverResponse
            case "acoustic-fixture-final.json": return .fixtureFinal
            default: break
            }
            // Formal protocol filenames, never user-supplied paths.
            for (prefix, suffix, make): (String, String, (UUID) -> Self) in [
                ("command-", ".json", Self.command), ("phase-", "-start.json", Self.phaseStart),
                ("phase-", "-end.json", Self.phaseEnd), ("remote-microphone-", ".json", Self.remoteMetadata)
            ] {
                guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count == prefix.count + 36 + suffix.count else { continue }
                let raw = String(name.dropFirst(prefix.count).dropLast(suffix.count))
                if let id = UUID(uuidString: raw), make(id).name == name { return make(id) }
            }
            return nil
        }
    }

    private static let processBridge: Result<GuestAudioTestFileBridge, Error> = Result {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["ROCK_STARTUP_CHANNEL"], let generation = UUID(uuidString: raw),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw GuestAudioTestBridgeError.invalidFrame }
        func descriptor(_ name: String) throws -> Int32? {
            guard let raw = environment[name] else { return nil }
            guard let fd = Int32(raw), fd >= 3, String(fd) == raw else { throw GuestAudioTestBridgeError.invalidDescriptor }
            return fd
        }
        let descriptors = try Descriptors(command: descriptor("ROCK_ACOUSTIC_COMMAND_FD"), response: descriptor("ROCK_ACOUSTIC_RESPONSE_FD"),
            speech: descriptor("ROCK_ACOUSTIC_SPEECH_FD"), archive: descriptor("ROCK_ACOUSTIC_EXPORT_FD"))
        let fixture = environment["ROCK_STARTUP_RECEIVER"] == "1"
        guard fixture || descriptors.speech == nil,
              (descriptors.command == nil) == (descriptors.response == nil) else { throw GuestAudioTestBridgeError.invalidDescriptor }
        return try GuestAudioTestFileBridge(generation: generation,
            directory: support.appendingPathComponent("StartupCapture").appendingPathComponent(generation.uuidString),
            descriptors: descriptors)
    }
    static func current() throws -> GuestAudioTestFileBridge { try processBridge.get() }
    let generation: UUID
    private let directory: URL, descriptors: Descriptors
    private let queue = DispatchQueue(label: "AcousticValidation.export", qos: .utility)
    private let lock = NSLock()
    private var lastCommandSequence: UInt64 = 0, lastCommandDigest: String?
    private var archiveBytes = 0, artifactCount = 0, pendingDataBytes = 0
    private var failure: Error?, closed = false
    var hasCommand: Bool { descriptors.command != nil }
    var hasSpeech: Bool { descriptors.speech != nil }

    init(generation: UUID, directory: URL, descriptors: Descriptors) throws {
        self.generation = generation; self.directory = directory.standardizedFileURL; self.descriptors = descriptors
        var identities = Set<String>(), numbers = Set<Int32>()
        for (fd, readable, writable, appendOnly) in [
            (descriptors.command, true, false, false), (descriptors.response, false, true, false),
            (descriptors.speech, true, false, false), (descriptors.archive, false, true, true)
        ] {
            guard let fd else { continue }
            var info = stat(); let flags = fcntl(fd, F_GETFL)
            guard fd >= 3, flags >= 0, fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  (!readable || flags & O_ACCMODE != O_WRONLY), (!writable || flags & O_ACCMODE != O_RDONLY),
                  (!appendOnly || flags & O_APPEND != 0) else { throw GuestAudioTestBridgeError.invalidDescriptor }
            if fd == descriptors.speech, flags & O_ACCMODE != O_RDONLY { throw GuestAudioTestBridgeError.invalidDescriptor }
            if fd == descriptors.response, flags & O_APPEND != 0 { throw GuestAudioTestBridgeError.invalidDescriptor }
            if fd == descriptors.archive, info.st_size != 0 { throw GuestAudioTestBridgeError.invalidDescriptor }
            guard numbers.insert(fd).inserted, identities.insert("\(info.st_dev):\(info.st_ino)").inserted else { throw GuestAudioTestBridgeError.descriptorAlias }
        }
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func digest(sequence: UInt64, generation: String, payload: Data) -> String {
        var signed = Data("rock-acoustic-fd-v1\n\(sequence)\n\(generation)\n\(payload.count)\n".utf8)
        signed.append(payload); return hash(signed)
    }
    static func frame(_ payload: Data, sequence: UInt64, generation: UUID) throws -> Data {
        let raw = generation.uuidString
        return try JSONEncoder().encode(Envelope(version: 1, sequence: sequence, generation: raw, size: payload.count,
            sha256: digest(sequence: sequence, generation: raw, payload: payload), payload: payload))
    }
    static func unframe(_ data: Data, generation: UUID, maximumPayload: Int) throws -> Envelope {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1, envelope.sequence > 0, UUID(uuidString: envelope.generation) == generation,
              envelope.size == envelope.payload.count, envelope.size <= maximumPayload,
              envelope.sha256 == digest(sequence: envelope.sequence, generation: envelope.generation, payload: envelope.payload) else { throw GuestAudioTestBridgeError.invalidFrame }
        return envelope
    }
    private static func read(_ fd: Int32, maximum: Int) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw GuestAudioTestBridgeError.io(errno) }
        guard info.st_size >= 0, info.st_size <= maximum else { throw GuestAudioTestBridgeError.oversized }
        var data = Data(count: Int(info.st_size)), used = 0
        try data.withUnsafeMutableBytes { bytes in
            while used < bytes.count {
                let count = pread(fd, bytes.baseAddress!.advanced(by: used), bytes.count - used, off_t(used))
                if count < 0 { if errno == EINTR { continue }; throw GuestAudioTestBridgeError.io(errno) }
                if count == 0 { break }; used += count
            }
        }
        data.count = used; return data
    }
    private static func write(_ data: Data, fd: Int32, at offset: Int? = nil) throws {
        try data.withUnsafeBytes { bytes in
            var used = 0
            while used < bytes.count {
                let count = offset.map { pwrite(fd, bytes.baseAddress!.advanced(by: used), bytes.count - used, off_t($0 + used)) }
                    ?? Darwin.write(fd, bytes.baseAddress!.advanced(by: used), bytes.count - used)
                if count < 0 { if errno == EINTR { continue }; throw GuestAudioTestBridgeError.io(errno) }
                guard count > 0 else { throw GuestAudioTestBridgeError.io(EIO) }; used += count
            }
        }
    }
    func commandData() throws -> Data? {
        guard let fd = descriptors.command else { return nil }
        let first = try Self.read(fd, maximum: 8192), second = try Self.read(fd, maximum: 8192)
        guard first == second, let envelope = try? Self.unframe(first, generation: generation, maximumPayload: 4096) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard !closed, envelope.sequence >= lastCommandSequence else { return nil }
        if envelope.sequence == lastCommandSequence, lastCommandDigest != envelope.sha256 { return nil }
        lastCommandSequence = envelope.sequence; lastCommandDigest = envelope.sha256
        return envelope.payload
    }
    func mirrorResponse(_ data: Data) throws {
        guard let fd = descriptors.response else { return }
        lock.lock(); let sequence = lastCommandSequence, closed = closed; lock.unlock()
        guard !closed else { throw GuestAudioTestBridgeError.closed }
        guard data.count <= 524_288, sequence > 0 else { throw GuestAudioTestBridgeError.invalidFrame }
        let frame = try Self.frame(data, sequence: sequence, generation: generation)
        try Self.write(frame, fd: fd, at: 0)
        guard ftruncate(fd, off_t(frame.count)) == 0 else { throw GuestAudioTestBridgeError.io(errno) }
    }
    func speechData() throws -> Data {
        guard let fd = descriptors.speech else { throw GuestAudioTestBridgeError.invalidDescriptor }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0 else { throw GuestAudioTestBridgeError.io(errno) }
        let data = try Self.read(fd, maximum: 12_001_024)
        guard fstat(fd, &after) == 0, data.count == before.st_size, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw GuestAudioTestBridgeError.invalidFrame }
        return data
    }
    private func reserve(_ count: Int, pending: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw GuestAudioTestBridgeError.closed }
        if let failure { throw failure }
        guard count >= 0, artifactCount < 1024, archiveBytes + count + 1024 <= 192_000_000,
              !pending || pendingDataBytes + count <= 4_000_000 else { throw GuestAudioTestBridgeError.oversized }
        artifactCount += 1; archiveBytes += count + 1024
        if pending { pendingDataBytes += count }
    }
    private func remember(_ error: Error) { lock.lock(); if failure == nil { failure = error }; lock.unlock() }
    func noteFailure(_ error: Error) { remember(error) }
    func validateHealth() throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }; if closed { throw GuestAudioTestBridgeError.closed }
    }
    private func header(_ artifact: Artifact, size: Int, hash: String) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["name": artifact.name, "size": size, "sha256": hash,
            "generation": generation.uuidString], options: [.sortedKeys])
        guard data.count <= 1023 else { throw GuestAudioTestBridgeError.oversized }; data.append(10); return data
    }
    func export(_ data: Data, as artifact: Artifact) throws {
        guard let fd = descriptors.archive else { return }
        do {
            guard !artifact.name.hasSuffix(".wav"), data.count <= artifact.maximumBytes else { throw GuestAudioTestBridgeError.oversized }
            try reserve(data.count, pending: true)
        } catch { remember(error); throw error }
        queue.async { [self] in
            defer { lock.lock(); pendingDataBytes -= data.count; lock.unlock() }
            do { try Self.write(header(artifact, size: data.count, hash: Self.hash(data)), fd: fd); try Self.write(data, fd: fd) }
            catch { remember(error) }
        }
    }
    /// Only a completed recording with its exact generated name in this channel.
    func exportRecording(_ url: URL, as artifact: Artifact) async throws {
        guard descriptors.archive != nil else { return }
        guard artifact.name.hasSuffix(".wav"), url.standardizedFileURL.deletingLastPathComponent().path == directory.path,
              url.lastPathComponent == artifact.name else {
            let error = GuestAudioTestBridgeError.invalidFrame; remember(error); throw error
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    let input = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
                    guard input >= 0 else { throw GuestAudioTestBridgeError.io(errno) }; defer { Darwin.close(input) }
                    var info = stat()
                    guard fstat(input, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                          info.st_size >= 44, info.st_size <= artifact.maximumBytes else { throw GuestAudioTestBridgeError.oversized }
                    try reserve(Int(info.st_size), pending: false)
                    var hash = SHA256(), offset = 0
                    func block(_ offset: Int) throws -> Data {
                        var bytes = Data(count: min(65_536, Int(info.st_size) - offset))
                        let count = try bytes.withUnsafeMutableBytes { buffer -> Int in
                            var used = 0
                            while used < buffer.count {
                                let count = pread(input, buffer.baseAddress!.advanced(by: used), buffer.count - used, off_t(offset + used))
                                if count < 0, errno == EINTR { continue }
                                guard count > 0 else { throw GuestAudioTestBridgeError.io(count < 0 ? errno : EIO) }; used += count
                            }
                            return used
                        }
                        bytes.count = count; return bytes
                    }
                    while offset < info.st_size { let data = try block(offset); hash.update(data: data); offset += data.count }
                    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                    let fd = descriptors.archive!
                    try Self.write(header(artifact, size: Int(info.st_size), hash: digest), fd: fd)
                    offset = 0
                    while offset < info.st_size { let data = try block(offset); try Self.write(data, fd: fd); offset += data.count }
                    continuation.resume(returning: ())
                } catch { remember(error); continuation.resume(throwing: error) }
            }
        }
    }
    /// Call only after the last generated artifact; drains the serial writer and
    /// closes each inherited capability exactly once before process exit.
    func finishAndClose() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                lock.lock()
                if !closed {
                    closed = true
                    for fd in [descriptors.command, descriptors.response, descriptors.speech, descriptors.archive].compactMap({ $0 }) {
                        if Darwin.close(fd) != 0, failure == nil { failure = GuestAudioTestBridgeError.io(errno) }
                    }
                }
                let error = failure; lock.unlock()
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: ()) }
            }
        }
    }
}
#endif
