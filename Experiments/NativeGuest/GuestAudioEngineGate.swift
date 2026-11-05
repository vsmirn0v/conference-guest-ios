import Foundation

/// Apple's voice processing can deadlock when one engine tears down its
/// voice-processing unit while another engine in the same process sets one up:
/// both audio worker threads wait inside AudioDSP forever (seen in beta 58 when
/// the microphone moved between two Guest meetings). Native audio work
/// therefore runs one owner at a time, and only after every other owner's
/// audio worker has finished the work it had queued, such as a deferred engine
/// teardown. The owner drains its own worker before leaving the gate too.
final class GuestAudioEngineGate: @unchecked Sendable {
    static let shared = GuestAudioEngineGate()

    private let gate = NSLock()
    private let registry = NSLock()
    private var drains: [ObjectIdentifier: () -> Void] = [:]
    // Evidence for tests and diagnostics.
    private var active = 0
    private(set) var maximumConcurrent = 0
    private(set) var passes = 0

    /// `drain` must block until that owner's audio worker has run everything
    /// queued before the call, and must not take this gate.
    func register(_ owner: ObjectIdentifier, drain: @escaping () -> Void) {
        registry.lock(); drains[owner] = drain; registry.unlock()
    }
    func unregister(_ owner: ObjectIdentifier) {
        registry.lock(); drains[owner] = nil; registry.unlock()
    }
    var registeredOwners: Int { registry.lock(); defer { registry.unlock() }; return drains.count }

    /// Runs `body` alone: others' queued native work first, then `body`, then
    /// this owner's own queued work.
    func run<T>(for owner: ObjectIdentifier, _ body: () -> T) -> T {
        gate.lock(); defer { gate.unlock() }
        registry.lock()
        let others = drains.filter { $0.key != owner }.map(\.value)
        let own = drains[owner]
        registry.unlock()
        for drain in others { drain() }
        active += 1; maximumConcurrent = max(maximumConcurrent, active); passes += 1
        defer { active -= 1 }
        let result = body()
        own?()
        return result
    }

#if DEBUG
    func resetEvidenceForTesting() { gate.lock(); maximumConcurrent = 0; passes = 0; gate.unlock() }
#endif
}
