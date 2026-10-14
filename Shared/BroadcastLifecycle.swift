import Foundation

/// Serializes the upload SDK without retaining a queue of video samples. Stop
/// closes admission immediately; teardown follows any in-flight SDK callback.
final class BroadcastLifecycle: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.vsmirn0v.broadcast-sdk", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    private var stopped = false
    private var started = false // Confined to queue.

    init() { queue.setSpecific(key: queueKey, value: true) }

    @discardableResult func start(_ operation: () -> Void) -> Bool {
        queue.sync {
            guard isActive, !started else { return false }
            started = true
            operation()
            return true
        }
    }

    @discardableResult func send(_ operation: () -> Void) -> Bool {
        queue.sync {
            guard isActive, started else { return false }
            operation()
            return true
        }
    }

    /// SDK error callbacks may call this from inside start/send. Cleanup is
    /// deferred until that callback returns, so it cannot reenter SDK teardown.
    /// ReplayKit's final callback waits for cleanup before returning.
    func finish(wait: Bool = false, _ operation: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        if !stopped {
            stopped = true
            queue.async {
                let wasStarted = self.started
                self.started = false
                operation(wasStarted)
            }
        }
        lock.unlock()
        if wait, DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
    }

    private var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped
    }
}
