/// Tracks when CallKit has returned the conference's audio session after a hold.
public struct CallAudioRecoveryGate {
    private var isActive = false
    private var isHeld = false
    private var needsRecovery = false

    public init() {}

    public var canUseMedia: Bool { isActive && !isHeld }

    public func isReadyForMedia(signalingActive: Bool, transportConnected: Bool) -> Bool {
        canUseMedia && signalingActive && transportConnected
    }

    public mutating func activate() {
        isActive = true
        needsRecovery = true
    }

    public mutating func deactivate() {
        isActive = false
        needsRecovery = true
    }

    public mutating func setHeld(_ held: Bool) {
        isHeld = held
        if held { needsRecovery = true }
    }

    public mutating func markInterrupted() { needsRecovery = true }

    public mutating func takeRecovery() -> Bool {
        guard canUseMedia, needsRecovery else { return false }
        needsRecovery = false
        return true
    }
}
