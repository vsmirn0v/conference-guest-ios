import Foundation

public struct ActiveJam: Codable, Equatable, Identifiable, Sendable {
    public let deviceID: String
    public let sessionID: UUID
    public let invitation: URL
    public var title: String
    public let name: String
    public let deviceLabel: String
    public var updatedAt: Date
    public var connected: Bool
    public var isSharingScreen: Bool
    public var supportsCompanion: Bool
    public var audioPaused: Bool?
    public var id: String { deviceID }
    public init(deviceID: String, sessionID: UUID = UUID(), invitation: URL, title: String,
                name: String, deviceLabel: String, updatedAt: Date = Date(), connected: Bool = true,
                isSharingScreen: Bool = false, supportsCompanion: Bool = false, audioPaused: Bool? = nil) {
        self.deviceID = deviceID; self.sessionID = sessionID; self.invitation = invitation
        self.title = title; self.name = name; self.deviceLabel = deviceLabel
        self.updatedAt = updatedAt; self.connected = connected; self.isSharingScreen = isSharingScreen
        self.supportsCompanion = supportsCompanion
        self.audioPaused = audioPaused
    }
    public func isRecent(at now: Date) -> Bool {
        connected && now.timeIntervalSince(updatedAt) >= -60 && now.timeIntervalSince(updatedAt) < 180
    }
    public func isVisible(at now: Date) -> Bool { connected && abs(now.timeIntervalSince(updatedAt)) < 900 }
}

public struct JamTransfer: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case requested, prepared, connected, finishing, completed, cancelled, rejected }
    public let id: UUID
    public let sourceDevice: String
    public let sourceSession: UUID
    public let targetDevice: String
    public let targetLabel: String
    public let expiresAt: Date
    public let allowsStoppingShare: Bool
    /// New receivers connect before a new source pauses. Optional for older clients.
    public let connectsBeforePausing: Bool?
    public var phase: Phase
    public init(source: ActiveJam, targetDevice: String, targetLabel: String, now: Date = Date(),
                connectsBeforePausing: Bool? = nil) {
        id = UUID(); sourceDevice = source.deviceID; sourceSession = source.sessionID
        self.targetDevice = targetDevice; self.targetLabel = targetLabel
        allowsStoppingShare = source.isSharingScreen
        self.connectsBeforePausing = connectsBeforePausing
        expiresAt = now.addingTimeInterval(75); phase = .requested
    }
    public func canPrepare(current: ActiveJam?, now: Date) -> Bool {
        phase == .requested && expiresAt > now && current?.connected == true &&
        current?.deviceID == sourceDevice && current?.sessionID == sourceSession
    }
    public func canComplete(current: ActiveJam?, now: Date) -> Bool {
        (phase == .connected || phase == .finishing) && expiresAt > now && current?.connected == true &&
        current?.deviceID == sourceDevice && current?.sessionID == sourceSession
    }
    public var isTerminal: Bool { [.completed, .cancelled, .rejected].contains(phase) }
    public func permitsTransition(to next: Phase, actor: String, now: Date) -> Bool {
        if next == .cancelled { return actor == targetDevice && !isTerminal && phase != .finishing }
        guard expiresAt > now else { return false }
        switch (phase, next) {
        case (.requested, .prepared), (.requested, .rejected), (.connected, .finishing), (.finishing, .completed): return actor == sourceDevice
        case (.prepared, .connected): return actor == targetDevice
        default: return false
        }
    }
}
