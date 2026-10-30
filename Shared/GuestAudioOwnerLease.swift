import Foundation

/// A private check cannot create a second physical owner beside a meeting.
/// Concurrent owners belong to additional simultaneous meetings: they coexist with
/// meeting owners, never with a private check, and block new exclusive owners.
final class GuestAudioOwnerLease: @unchecked Sendable {
    private static let lock = NSLock()
    private struct Owner { let privateCheck: Bool; let exclusive: Bool; let concurrent: Bool }
    private static var owners: [UUID: Owner] = [:]
    private static var cleanupFailed = false
    private let id = UUID()
    let privateCheck: Bool
    init?(privateCheck: Bool, exclusive: Bool = false, concurrent: Bool = false) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let admitted = privateCheck || exclusive ? Self.owners.isEmpty
            : concurrent ? !Self.owners.values.contains(where: \.privateCheck)
            : !Self.owners.values.contains(where: { $0.privateCheck || $0.exclusive })
        guard !Self.cleanupFailed, admitted else { return nil }
        self.privateCheck = privateCheck
        Self.owners[id] = Owner(privateCheck: privateCheck, exclusive: exclusive, concurrent: concurrent && !privateCheck && !exclusive)
    }
    deinit { Self.lock.lock(); Self.owners[id] = nil; Self.lock.unlock() }
    static func reportFailedStop() { lock.lock(); cleanupFailed = true; lock.unlock() }
}

/// A private check borrows hardware only for its own lifetime. Explicit user or
/// accessory activation survives check completion until the meeting owner stops.
struct GuestInputActivationPolicy {
    private var persistent: Bool
    private var checking = false
    init(persistent: Bool) { self.persistent = persistent }
    var inputAvailable: Bool { persistent || checking }
    mutating func activate() { persistent = true }
    mutating func beginCheck() { checking = true }
    mutating func endCheck() { checking = false }
}
