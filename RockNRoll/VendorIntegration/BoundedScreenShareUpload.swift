import CoreMedia
import Foundation

/// Owns the public ReplayKit sender calls on one worker. The pinned Jazz facade
/// has no main-actor contract; processSampleBuffer performs synchronous JPEG work.
/// This orders public calls, not the SDK's private uploader/network queues.
final class BoundedScreenShareUpload: @unchecked Sendable {
    struct Lifecycle {
        let start: () -> Void
        let send: (CMSampleBuffer) -> Void
        let finish: () -> Void
    }

    private enum State { case idle, running, stopping, stopped }
    private let queue: DispatchQueue
    private let makeLifecycle: () -> Lifecycle
    private let lock = NSLock()
    private var state = State.idle
    private var pending: CMSampleBuffer?
    private var scheduled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    // Accessed only by queue, including construction and final release.
    private var lifecycle: Lifecycle?

    init(queue: DispatchQueue = DispatchQueue(label: "dev.vsmirn0v.guest-screen-upload", qos: .userInitiated),
         makeLifecycle: @escaping () -> Lifecycle) {
        self.queue = queue; self.makeLifecycle = makeLifecycle
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard state == .idle else { return }
        state = .running
        queue.async { [self] in
            lock.lock(); let active = state == .running; lock.unlock()
            guard active else { return }
            autoreleasepool {
                lifecycle = makeLifecycle()
                lifecycle?.start()
            }
        }
    }

    func submit(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard state == .running else { return }
        // Strongly retain one newest sample while the worker owns its current
        // sample. ScreenCaptureKit may release its callback sample immediately.
        pending = sample
        guard !scheduled else { return }
        scheduled = true
        queue.async { [self] in drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard state == .running, let sample = pending else {
                scheduled = false; lock.unlock(); return
            }
            pending = nil; lock.unlock()
            autoreleasepool { lifecycle?.send(sample) }
        }
    }

    /// Immediately reject future samples and discard waiting work. A public
    /// send already in progress finishes before public finish runs on the worker.
    func retire() {
        lock.lock(); defer { lock.unlock() }
        guard state != .stopping, state != .stopped else { return }
        state = .stopping; pending = nil
        queue.async { [self] in
            autoreleasepool {
                lifecycle?.finish()
                lifecycle = nil
            }
            lock.lock(); state = .stopped
            let completions = waiters; waiters.removeAll(); lock.unlock()
            completions.forEach { $0.resume() }
        }
    }

    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if state == .stopped { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
}
