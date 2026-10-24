import Foundation
import Darwin

/// Local control transport only. Media and SDK objects never cross this boundary.
public enum NativeGuestProtocol {
    public static let version = 1
    public static let appGroupIdentifier = "group.dev.vsmirn0v.conferenceguest"
    public static let bundleIdentifier = "dev.vsmirn0v.conferenceguest.nativeguest"
    public static let teamIdentifier = "5V64BP2H3P"
    public static let maximumSessionLifetime: TimeInterval = 24 * 60 * 60
    public static let launchWindow: TimeInterval = 45
    public static let heartbeatTimeout: TimeInterval = 10
    public static let ownerDeathTimeout: TimeInterval = 15
    public static let maximumRecordBytes = 32_768
}

public struct NativeGuestMetadata: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let sessionID: UUID
    public let createdAt: Date
    public let expiresAt: Date

    public init(sessionID: UUID, now: Date = Date(), expiresAt: Date? = nil) {
        protocolVersion = NativeGuestProtocol.version
        self.sessionID = sessionID
        createdAt = now
        self.expiresAt = expiresAt ?? now.addingTimeInterval(NativeGuestProtocol.maximumSessionLifetime)
    }

    public func validate(sessionID: UUID, now: Date = Date()) throws {
        try validateIdentity(sessionID: sessionID)
        guard createdAt <= now.addingTimeInterval(5), expiresAt > now else {
            throw NativeGuestStoreError.expiredRecord
        }
    }

    public func validateIdentity(sessionID: UUID) throws {
        guard protocolVersion == NativeGuestProtocol.version, self.sessionID == sessionID else {
            throw NativeGuestStoreError.incompatibleRecord
        }
        guard createdAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > createdAt,
              expiresAt.timeIntervalSince(createdAt) <= NativeGuestProtocol.maximumSessionLifetime else {
            throw NativeGuestStoreError.expiredRecord
        }
    }
}

public protocol NativeGuestRecord: Codable, Sendable {
    var metadata: NativeGuestMetadata { get }
    func validatePayload(now: Date) throws
}

public struct NativeGuestTicket: NativeGuestRecord, Equatable {
    public let metadata: NativeGuestMetadata
    public let invitationURL: URL
    public let displayName: String
    public let roomTitle: String?
    public let quiet: Bool
    public let initiallyMuted: Bool

    public init(sessionID: UUID = UUID(), invitationURL: URL, displayName: String,
                roomTitle: String? = nil, quiet: Bool = false, now: Date = Date()) {
        metadata = NativeGuestMetadata(sessionID: sessionID, now: now)
        self.invitationURL = invitationURL
        self.displayName = displayName
        self.roomTitle = roomTitle
        self.quiet = quiet
        initiallyMuted = true
    }

    public func validatePayload(now: Date) throws {
        guard let url = URLComponents(url: invitationURL, resolvingAgainstBaseURL: false),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, invitationURL.absoluteString.utf8.count <= 4096,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              displayName.utf8.count <= 512, (roomTitle?.utf8.count ?? 0) <= 1024, initiallyMuted else {
            throw NativeGuestStoreError.invalidPayload
        }
    }

    public func validateForLaunch(now: Date = Date()) throws {
        try metadata.validate(sessionID: metadata.sessionID, now: now)
        try validatePayload(now: now)
        guard now.timeIntervalSince(metadata.createdAt) <= NativeGuestProtocol.launchWindow else {
            throw NativeGuestStoreError.expiredRecord
        }
    }
}

public enum NativeGuestControlField: String, Codable, CaseIterable, Hashable, Sendable {
    case microphone, camera, output
}

/// Only marked media fields replace intent; showWindowSequence is an edge-triggered request.
public struct NativeGuestCommand: NativeGuestRecord, Equatable {
    public let metadata: NativeGuestMetadata
    public var sequence: UInt64
    public var microphoneOn: Bool
    public var cameraOn: Bool
    public var outputOn: Bool
    public var held: Bool
    public var showWindowSequence: UInt64
    public var leave: Bool
    public var expectedHelperPID: Int32?
    public var mediaFields: Set<NativeGuestControlField>
    #if DEBUG
    public var captureDiagnosticsRequested: Bool?
    public var reconnectForTestingSequence: UInt64?
    #endif

    public init(metadata: NativeGuestMetadata, sequence: UInt64 = 1, microphoneOn: Bool = false,
                cameraOn: Bool = false, outputOn: Bool = true, held: Bool = false,
                showWindowSequence: UInt64 = 0, leave: Bool = false,
                mediaFields: Set<NativeGuestControlField> = [], expectedHelperPID: Int32? = nil) {
        self.metadata = metadata; self.sequence = sequence
        self.microphoneOn = microphoneOn; self.cameraOn = cameraOn; self.outputOn = outputOn
        self.held = held; self.showWindowSequence = showWindowSequence; self.leave = leave
        self.mediaFields = mediaFields; self.expectedHelperPID = expectedHelperPID
    }
    public func validatePayload(now: Date) throws {
        guard sequence > 0, expectedHelperPID == nil || expectedHelperPID! > 0 else { throw NativeGuestStoreError.invalidPayload }
    }

    /// Retain unacknowledged changes when replacing a command file with a newer request.
    /// Once acknowledged, refresh applied state and clear its mask before adding new fields.
    public mutating func advance(changing fields: Set<NativeGuestControlField>,
                                 acknowledged status: NativeGuestStatus?) throws {
        guard !leave, sequence < UInt64.max else { throw NativeGuestStoreError.invalidPayload }
        if let status {
            guard status.metadata == metadata, status.acknowledgedSequence <= sequence else {
                throw NativeGuestStoreError.incompatibleRecord
            }
            if status.acknowledgedSequence == sequence {
                microphoneOn = status.microphoneOn; cameraOn = status.cameraOn; outputOn = status.outputOn
                mediaFields.removeAll()
            }
        }
        sequence += 1
        mediaFields.formUnion(fields)
    }
}

/// The companion must accept through this gate before applying any command.
public struct NativeGuestCommandGate: Sendable {
    private let metadata: NativeGuestMetadata
    public private(set) var acknowledgedSequence: UInt64 = 0
    public private(set) var terminalLeave = false
    public init(metadata: NativeGuestMetadata) { self.metadata = metadata }
    public mutating func accept(_ command: NativeGuestCommand) -> Bool {
        guard command.metadata == metadata, !terminalLeave,
              command.sequence > acknowledgedSequence else { return false }
        acknowledgedSequence = command.sequence
        terminalLeave = command.leave
        return true
    }
}

public enum NativeGuestState: String, Codable, Sendable {
    case launching, connecting, lobby, active, leaving, left, failed
    public var isTerminal: Bool { self == .left || self == .failed }
}

/// Bounded codes deliberately exclude URLs, SDK messages, and credentials.
public enum NativeGuestErrorCode: String, Codable, Sendable {
    case invalidTicket, unsupportedProtocol, parentUnavailable, connectionFailed
    case permissionDenied, mediaFailed, expiredSession, commandFailed, internalFailure
}

public struct NativeGuestStatus: NativeGuestRecord, Equatable {
    public let metadata: NativeGuestMetadata
    public var acknowledgedSequence: UInt64
    public var state: NativeGuestState
    public var microphoneOn: Bool
    public var cameraOn: Bool
    public var outputOn: Bool
    public var screenSharing: Bool
    public var microphoneCapturing: Bool
    public var errorCode: NativeGuestErrorCode?
    public var roomTitle: String?
    public var updatedAt: Date
    public var helperPID: Int32?
    public var remoteVideoFrames: Int
    public var receivedAudioSamples: Int
    public var canShareMicrophone: Bool
    public var canShareCamera: Bool
    public var captureDisabledVerified: Bool?
    public var receiveConnected: Bool?
    public var decodedVideoFrames: Int?
    public var playoutRunning: Bool?
    public var receivedAudioRMS: Double?
    #if DEBUG
    public var captureDiagnostics: NativeGuestCaptureDiagnostics?
    #endif

    public init(metadata: NativeGuestMetadata, acknowledgedSequence: UInt64 = 0,
                state: NativeGuestState = .launching, microphoneOn: Bool = false,
                cameraOn: Bool = false, outputOn: Bool = true, screenSharing: Bool = false,
                microphoneCapturing: Bool = false, errorCode: NativeGuestErrorCode? = nil,
                roomTitle: String? = nil, updatedAt: Date = Date(), helperPID: Int32? = nil,
                remoteVideoFrames: Int = 0, receivedAudioSamples: Int = 0,
                canShareMicrophone: Bool = false, canShareCamera: Bool = false,
                captureDisabledVerified: Bool? = nil, receiveConnected: Bool? = nil,
                decodedVideoFrames: Int? = nil, playoutRunning: Bool? = nil, receivedAudioRMS: Double? = nil) {
        self.metadata = metadata; self.acknowledgedSequence = acknowledgedSequence; self.state = state
        self.microphoneOn = microphoneOn; self.cameraOn = cameraOn; self.outputOn = outputOn
        self.screenSharing = screenSharing; self.microphoneCapturing = microphoneCapturing
        self.errorCode = errorCode; self.roomTitle = roomTitle; self.updatedAt = updatedAt
        self.helperPID = helperPID
        self.remoteVideoFrames = remoteVideoFrames; self.receivedAudioSamples = receivedAudioSamples
        self.canShareMicrophone = canShareMicrophone; self.canShareCamera = canShareCamera
        self.captureDisabledVerified = captureDisabledVerified
        self.receiveConnected = receiveConnected; self.decodedVideoFrames = decodedVideoFrames; self.playoutRunning = playoutRunning
        self.receivedAudioRMS = receivedAudioRMS
    }
    public func validatePayload(now: Date) throws {
        guard updatedAt >= metadata.createdAt, updatedAt <= now.addingTimeInterval(5),
              (roomTitle?.utf8.count ?? 0) <= 1024, helperPID == nil || helperPID! > 0,
              remoteVideoFrames >= 0, receivedAudioSamples >= 0, (decodedVideoFrames ?? 0) >= 0, (receivedAudioRMS ?? 0).isFinite,
              (0...1).contains(receivedAudioRMS ?? 0) else {
            throw NativeGuestStoreError.invalidPayload
        }
    }
    public func isFresh(now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) <= NativeGuestProtocol.heartbeatTimeout
    }
}

#if DEBUG
/// Bounded test telemetry only; no pixels, PCM, SDP or network addresses.
public struct NativeGuestCaptureDiagnostics: Codable, Equatable {
    var connectionCount: UInt64 = 0
    var engineSessionID: String?
    var remoteParticipants = 0
    var audioSnapshotUptime: Double = 0
    var inputAvailable = false
    var microphoneOptIn = false
    var microphoneMuted = false
    var microphoneMutedRequested = false
    var voiceProcessingActive = false
    var voiceProcessingBypassed = true
    var echoCancellationActive = false
    var outputAvailable = false
    var engineRunning = false
    var inputSampleRate: Double = 0
    var outputSampleRate: Double = 0
    var engineStarts = 0
    var engineStops = 0
    var cameraPresent = false
    var cameraFrames = 0
    var cameraPTS = 0
    var cameraWidth = 0
    var cameraHeight = 0
    var subscriberStatsFresh = false
    var statisticsStartedUptime: Double = 0
    var statisticsCompletedUptime: Double = 0
    var videoSampleUptime: Double = 0
    var remoteVideoTrackCount = 0
    var decodedCadence: NativeGuestFrameCadence?
    var presentationCadence: [NativeGuestFrameCadence] = []
    var videoPacketsReceived: Int64 = 0
    var videoBytesReceived: Int64 = 0
    var videoFramesReceived: Int64 = 0
    var videoFramesDecoded: Int64 = 0
    var videoPacketsLost: Int64 = 0
    var videoNACK: Int64 = 0
    var videoPLI: Int64 = 0
    var videoFreezeCount: Int64 = 0
    var selectedReceiveRelay: String?
    var publisherStatsFresh = false
    var audioPacketsSent: Int64 = 0
    var videoFramesSent: Int64 = 0
    var encodedWidth = 0
    var encodedHeight = 0
    var receivedAudioSamples = 0
    var receivedAudioEnergy: Double = 0
    var renderedVideoFrames = 0
    var rawVideoCallbacks = 0
}
public struct NativeGuestFrameCadence: Codable, Equatable {
    var sourceID: String
    var complete: Bool
    var frames: Int
    var fps: Double
    var maximumGap: Double
    var endFrameAge: Double?
}

#endif

public struct NativeGuestHeartbeat: NativeGuestRecord, Equatable {
    public let metadata: NativeGuestMetadata
    public let updatedAt: Date
    public init(metadata: NativeGuestMetadata, updatedAt: Date = Date()) {
        self.metadata = metadata; self.updatedAt = updatedAt
    }
    public func validatePayload(now: Date) throws {
        guard updatedAt >= metadata.createdAt, updatedAt <= now.addingTimeInterval(5) else {
            throw NativeGuestStoreError.invalidPayload
        }
    }
    public func isFresh(now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) <= NativeGuestProtocol.heartbeatTimeout
    }
}

public enum NativeGuestStoreError: Error, Equatable {
    case appGroupUnavailable, unsafeFile, oversizedRecord, incompatibleRecord, expiredRecord, invalidPayload
    case io(Int32)
}

/// UUID-only directories, fixed filenames, private modes, descriptor-relative atomic IO.
/// The injected root is the NativeGuestSessions directory, not its app-group parent.
public final class NativeGuestSessionStore: @unchecked Sendable {
    public let rootURL: URL
    private enum File: String, CaseIterable { case ticket, command, status, heartbeat, claimed
        var name: String { rawValue + ".json" }
    }

    public init(rootURL: URL) { self.rootURL = rootURL.standardizedFileURL }
    public static func appGroupStore() throws -> NativeGuestSessionStore {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: NativeGuestProtocol.appGroupIdentifier) else {
            throw NativeGuestStoreError.appGroupUnavailable
        }
        return NativeGuestSessionStore(rootURL: container.appendingPathComponent("NativeGuestSessions", isDirectory: true))
    }

    public func create(_ ticket: NativeGuestTicket, now: Date = Date()) throws {
        try ticket.metadata.validate(sessionID: ticket.metadata.sessionID, now: now)
        try ticket.validatePayload(now: now)
        let root = try openRoot(); defer { close(root) }
        guard mkdirat(root, ticket.metadata.sessionID.uuidString, 0o700) == 0 else { throw posixError() }
        do { try write(ticket, file: .ticket, sessionID: ticket.metadata.sessionID, now: now) }
        catch { _ = unlinkat(root, ticket.metadata.sessionID.uuidString, AT_REMOVEDIR); throw error }
    }
    /// Startup-only discovery. Never guess between multiple pending host joins.
    public func pendingLaunchTicket(now: Date = Date()) throws -> NativeGuestTicket? {
        let root = try openRoot(); defer { close(root) }
        let entries = try names(in: root)
        guard entries.count <= 256 else { throw NativeGuestStoreError.oversizedRecord }
        var pending: [NativeGuestTicket] = []
        for name in entries {
            guard let id = UUID(uuidString: name), id.uuidString == name else { continue }
            do {
                let directory = try openSession(id, root: root); defer { close(directory) }
                guard try inspect(File.claimed.name, directory: directory) == nil,
                      let ticket = try readTicket(id, now: now),
                      let heartbeat = try readHeartbeat(id, now: now), heartbeat.metadata == ticket.metadata,
                      heartbeat.isFresh(now: now),
                      let command = try readCommand(id, now: now), command.metadata == ticket.metadata,
                      !command.leave else { continue }
                try ticket.validateForLaunch(now: now)
                pending.append(ticket)
            } catch { continue } // Unsafe/expired/unrelated records never become admission candidates.
        }
        guard pending.count <= 1 else { throw NativeGuestStoreError.incompatibleRecord }
        return pending.first
    }

    /// The host must bind its exact NSWorkspace-returned process before any media starts.
    public func consumeTicket(_ id: UUID, boundTo processID: Int32, now: Date = Date()) throws -> NativeGuestTicket {
        guard processID > 0, let ticket = try readTicket(id, now: now),
              let command = try readCommand(id, now: now), command.metadata == ticket.metadata,
              command.expectedHelperPID == processID, !command.leave,
              let owner = try readHeartbeat(id, now: now), owner.metadata == ticket.metadata,
              owner.isFresh(now: now) else { throw NativeGuestStoreError.incompatibleRecord }
        let admitted = try consumeTicket(id, now: now)
        guard admitted == ticket else { throw NativeGuestStoreError.incompatibleRecord }
        return admitted
    }

    public func readTicket(_ id: UUID, now: Date = Date()) throws -> NativeGuestTicket? {
        try read(.ticket, sessionID: id, now: now)
    }
    /// A launch ticket can be admitted once, even if two helper processes race.
    public func consumeTicket(_ id: UUID, now: Date = Date()) throws -> NativeGuestTicket {
        guard let ticket = try readTicket(id, now: now) else { throw NativeGuestStoreError.invalidPayload }
        try ticket.validateForLaunch(now: now)
        let root = try openRoot(); defer { close(root) }
        let directory = try openSession(id, root: root); defer { close(directory) }
        let claim = openat(directory, File.claimed.name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard claim >= 0 else { throw posixError() }
        defer { close(claim) }
        guard fsync(claim) == 0 else { throw posixError() }
        return ticket
    }
    public func readCommand(_ id: UUID, now: Date = Date()) throws -> NativeGuestCommand? {
        try read(.command, sessionID: id, now: now)
    }
    public func readStatus(_ id: UUID, now: Date = Date()) throws -> NativeGuestStatus? {
        try read(.status, sessionID: id, now: now)
    }
    public func readHeartbeat(_ id: UUID, now: Date = Date()) throws -> NativeGuestHeartbeat? {
        try read(.heartbeat, sessionID: id, now: now)
    }
    public func writeCommand(_ value: NativeGuestCommand, now: Date = Date()) throws {
        try write(value, file: .command, sessionID: value.metadata.sessionID, now: now)
    }
    public func writeStatus(_ value: NativeGuestStatus, now: Date = Date()) throws {
        try write(value, file: .status, sessionID: value.metadata.sessionID, now: now)
    }
    public func writeHeartbeat(_ value: NativeGuestHeartbeat, now: Date = Date()) throws {
        try write(value, file: .heartbeat, sessionID: value.metadata.sessionID, now: now)
    }

    public func removeSession(_ id: UUID) throws {
        let root = try openRoot(); defer { close(root) }
        let directory = try openSession(id, root: root); defer { close(directory) }
        for file in File.allCases {
            if try inspect(file.name, directory: directory) != nil,
               unlinkat(directory, file.name, 0) != 0 { throw posixError() }
        }
        for name in try names(in: directory) where isTemporaryRecord(name) {
            if try inspect(name, directory: directory) != nil, unlinkat(directory, name, 0) != 0 { throw posixError() }
        }
        // Unknown content is never recursively deleted.
        guard unlinkat(root, id.uuidString, AT_REMOVEDIR) == 0 else { throw posixError() }
    }

    /// The helper has a ten-second owner watchdog; cleanup allows a full minute.
    /// A bounded pass also retires expired tickets and abandoned launch directories.
    @discardableResult public func cleanupExpiredSessions(now: Date = Date()) throws -> [UUID] {
        let root = try openRoot(); defer { close(root) }
        let names = try names(in: root)
        var removed: [UUID] = []
        for name in names.sorted().prefix(256) {
            guard let id = UUID(uuidString: name), id.uuidString == name else { continue }
            do {
                let directory = try openSession(id, root: root); defer { close(directory) }
                let ticket: NativeGuestTicket? = try decode(.ticket, directory: directory)
                var info = stat()
                guard fstat(directory, &info) == 0 else { continue }
                let created = ticket?.metadata.createdAt ?? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                guard now.timeIntervalSince(created) > 60 else { continue }
                let heartbeat: NativeGuestHeartbeat? = try decode(.heartbeat, directory: directory)
                let abandoned = now.timeIntervalSince(heartbeat?.updatedAt ?? created) > 60
                if abandoned { try removeSession(id); removed.append(id) }
            } catch { continue } // Unsafe or unrelated entries are left untouched.
        }
        return removed
    }

    private func openRoot() throws -> Int32 {
        guard rootURL.isFileURL else { throw NativeGuestStoreError.unsafeFile }
        if mkdir(rootURL.path, 0o700) != 0, errno != EEXIST { throw posixError() }
        let fd = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        do { try validate(fd, directory: true); return fd } catch { close(fd); throw error }
    }
    private func names(in directory: Int32) throws -> [String] {
        let fd = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        guard let stream = fdopendir(fd) else { close(fd); throw posixError() }
        defer { closedir(stream) }
        var result: [String] = []
        while result.count < 1024, let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
        }
        return result
    }
    private func isTemporaryRecord(_ name: String) -> Bool {
        for file in File.allCases {
            let prefix = "." + file.name + ".", suffix = ".tmp"
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
            let token = String(name.dropFirst(prefix.count).dropLast(suffix.count))
            if let id = UUID(uuidString: token), id.uuidString == token { return true }
        }
        return false
    }
    private func openSession(_ id: UUID, root: Int32) throws -> Int32 {
        let fd = openat(root, id.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        do { try validate(fd, directory: true); return fd } catch { close(fd); throw error }
    }
    private func validate(_ fd: Int32, directory: Bool) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        try validate(info, directory: directory)
    }
    private func validate(_ info: stat, directory: Bool) throws {
        let kind = info.st_mode & S_IFMT
        guard kind == (directory ? S_IFDIR : S_IFREG), info.st_uid == getuid(),
              info.st_mode & 0o777 == (directory ? 0o700 : 0o600),
              directory || info.st_nlink == 1 else { throw NativeGuestStoreError.unsafeFile }
        guard directory || (info.st_size >= 0 && info.st_size <= off_t(NativeGuestProtocol.maximumRecordBytes)) else {
            throw NativeGuestStoreError.oversizedRecord
        }
    }
    private func inspect(_ name: String, directory: Int32) throws -> stat? {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }; throw posixError()
        }
        try validate(info, directory: false)
        return info
    }
    private func read<T: NativeGuestRecord>(_ file: File, sessionID: UUID, now: Date) throws -> T? {
        let root = try openRoot(); defer { close(root) }
        let directory = try openSession(sessionID, root: root); defer { close(directory) }
        guard let value: T = try decode(file, directory: directory) else { return nil }
        if file == .ticket { try value.metadata.validate(sessionID: sessionID, now: now) }
        else { try value.metadata.validateIdentity(sessionID: sessionID) }
        try value.validatePayload(now: now)
        return value
    }
    private func decode<T: Decodable>(_ file: File, directory: Int32) throws -> T? {
        let fd = openat(directory, file.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw posixError() }
        defer { close(fd) }
        try validate(fd, directory: false)
        var bytes = [UInt8](repeating: 0, count: NativeGuestProtocol.maximumRecordBytes + 1)
        var count = 0
        while count < bytes.count {
            let amount = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress!.advanced(by: count), buffer.count - count)
            }
            if amount < 0 { if errno == EINTR { continue }; throw posixError() }
            if amount == 0 { break }; count += amount
        }
        guard count <= NativeGuestProtocol.maximumRecordBytes else { throw NativeGuestStoreError.oversizedRecord }
        return try JSONDecoder().decode(T.self, from: Data(bytes.prefix(count)))
    }
    private func write<T: NativeGuestRecord>(_ value: T, file: File, sessionID: UUID, now: Date) throws {
        try value.metadata.validateIdentity(sessionID: sessionID); try value.validatePayload(now: now)
        let data = try JSONEncoder().encode(value)
        guard data.count <= NativeGuestProtocol.maximumRecordBytes else { throw NativeGuestStoreError.oversizedRecord }
        let root = try openRoot(); defer { close(root) }
        let directory = try openSession(sessionID, root: root); defer { close(directory) }
        _ = try inspect(file.name, directory: directory)
        let temporary = "." + file.name + "." + UUID().uuidString + ".tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd); _ = unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let amount = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if amount < 0 { if errno == EINTR { continue }; throw posixError() }
                guard amount > 0 else { throw NativeGuestStoreError.io(EIO) }; offset += amount
            }
        }
        guard fsync(fd) == 0 else { throw posixError() }
        _ = try inspect(file.name, directory: directory)
        guard renameat(directory, temporary, directory, file.name) == 0 else { throw posixError() }
    }
    private func posixError() -> NativeGuestStoreError { .io(errno) }
}
