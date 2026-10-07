import Foundation
import Network

/// Event-driven reachability with one deadline and cancellation-safe completion.
final class MeetingServiceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    init(host: String, port: UInt16, queue: DispatchQueue) {
        connection = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
        self.queue = queue
    }
    func run(timeout: TimeInterval = 4) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(returning: result); return }
                self.continuation = continuation
                lock.unlock()
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: self?.finish(true)
                    case .failed, .cancelled: self?.finish(false)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(false) }
            }
        } onCancel: { self.finish(false) }
    }
    private func finish(_ value: Bool) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let waiting = continuation; continuation = nil
        lock.unlock()
        connection.cancel()
        waiting?.resume(returning: value)
    }
}
