import AVFoundation
import Foundation

/// Admission is checked on the worker immediately before touching the shared
/// session. Leave, hold and replacement can retire queued work without waiting.
final class AudioSessionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func invalidate() { lock.lock(); active = false; lock.unlock() }
    func check() throws { if !isActive { throw CancellationError() } }
}

/// One process-wide ordering for app-owned session mutations. SDKs retain their
/// audio devices and real-time processing; this queue never handles PCM/video.
final class AudioSessionWorker: @unchecked Sendable {
    static let shared = AudioSessionWorker()
    private let queue: DispatchQueue
    private let activate: @Sendable () throws -> Void
    private let deactivateSession: @Sendable () throws -> Void
    init(queue: DispatchQueue = DispatchQueue(label: "dev.vsmirn0v.audio-session", qos: .userInitiated),
         activate: @escaping @Sendable () throws -> Void = { try AVAudioSession.sharedInstance().setActive(true) },
         deactivate: @escaping @Sendable () throws -> Void = {
             try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
         }) {
        self.queue = queue; self.activate = activate; self.deactivateSession = deactivate
    }
    func enqueue(lease: AudioSessionLease? = nil, operation: @escaping @Sendable () throws -> Void,
                 completion: @escaping @Sendable (Result<Void, Error>) -> Void = { _ in }) {
        queue.async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            completion(Result { try lease?.check(); try operation(); try lease?.check() })
        }
    }
    func perform(lease: AudioSessionLease, operation: @escaping @Sendable () throws -> Void) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueue(lease: lease, operation: operation) { continuation.resume(with: $0) }
        }
        try Task.checkCancellation()
    }
    func activate(lease: AudioSessionLease, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        enqueue(lease: lease, operation: activate, completion: completion)
    }
    func deactivate() {
        // Enqueued synchronously at retirement, before a replacement can enqueue
        // activation. It must run even after the retired lease is invalidated.
        enqueue(operation: deactivateSession)
    }
    func deactivate(lease: AudioSessionLease) async throws {
        try await perform(lease: lease, operation: deactivateSession)
    }
}
