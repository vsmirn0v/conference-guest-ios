import Foundation

/// A private check cannot create a second physical owner beside a meeting.
final class GuestAudioOwnerLease: @unchecked Sendable {
    private static let lock = NSLock()
    private struct Owner { let privateCheck: Bool; let exclusive: Bool }
    private static var owners: [UUID: Owner] = [:]
    private static var cleanupFailed = false
    private let id = UUID()
    let privateCheck: Bool
    init?(privateCheck: Bool, exclusive: Bool = false) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard !Self.cleanupFailed,
              (privateCheck || exclusive) ? Self.owners.isEmpty : !Self.owners.values.contains(where: { $0.privateCheck || $0.exclusive }) else { return nil }
        self.privateCheck = privateCheck; Self.owners[id] = Owner(privateCheck: privateCheck, exclusive: exclusive)
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
