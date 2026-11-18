import Foundation

/// A private check cannot create a second physical owner beside a meeting.
/// Concurrent owners belong to additional simultaneous meetings: they coexist with
/// meeting owners, never with a private check, and block new exclusive owners.
public final class GuestAudioOwnerLease: @unchecked Sendable {
    private static let lock = NSLock()
    private struct Owner { let privateCheck: Bool; let exclusive: Bool; let concurrent: Bool }
    private static var owners: [UUID: Owner] = [:]
    private static var cleanupFailed = false
    private let id = UUID()
    public var diagnosticID: String { id.uuidString }
    public let privateCheck: Bool
    public init?(privateCheck: Bool, exclusive: Bool = false, concurrent: Bool = false) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let admitted = privateCheck || exclusive ? Self.owners.isEmpty
            : concurrent ? !Self.owners.values.contains(where: \.privateCheck)
            : !Self.owners.values.contains(where: { $0.privateCheck || $0.exclusive })
        guard !Self.cleanupFailed, admitted else { return nil }
        self.privateCheck = privateCheck
        Self.owners[id] = Owner(privateCheck: privateCheck, exclusive: exclusive, concurrent: concurrent && !privateCheck && !exclusive)
    }
    deinit { Self.lock.lock(); Self.owners[id] = nil; Self.lock.unlock() }
    public static func reportFailedStop() { lock.lock(); cleanupFailed = true; lock.unlock() }
    /// Bounded process-local reservations; this is not a count of active hardware devices.
    public static var ownershipDiagnostics: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let ordered = owners.keys.sorted { $0.uuidString < $1.uuidString }
        let values = ordered.prefix(16).compactMap { id -> [String: Any]? in
            guard let owner = owners[id] else { return nil }
            return ["id": id.uuidString, "privateCheck": owner.privateCheck,
                    "exclusive": owner.exclusive, "concurrent": owner.concurrent]
        }
        return ["count": owners.count, "leases": values,
                "truncated": max(0, owners.count - values.count), "cleanupFailed": cleanupFailed]
    }
}

/// A private check borrows hardware only for its own lifetime. Explicit user or
/// accessory activation survives check completion until the meeting owner stops.
public struct GuestInputActivationPolicy {
    private var persistent: Bool
    private var checking = false
    public init(persistent: Bool) { self.persistent = persistent }
    public var inputAvailable: Bool { persistent || checking }
    public mutating func activate() { persistent = true }
    public mutating func beginCheck() { checking = true }
    public mutating func endCheck() { checking = false }
}
