import Foundation

/// One completion across native callback, timeout and cancellation races.
final class GuestCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var deadline: DispatchWorkItem?
    func install(_ continuation: CheckedContinuation<Value, Error>, timeout: TimeInterval) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return }
        self.continuation = continuation
        let work = DispatchWorkItem { [weak self] in self?.finish(.failure(GuestTransportError.timedOut)) }
        deadline = work
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
    }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation; self.continuation = nil
        let work = deadline; deadline = nil
        lock.unlock()
        work?.cancel(); continuation?.resume(with: result)
    }
}

@MainActor
func guestAwait<Value>(timeout: TimeInterval = 10,
    _ start: @escaping (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
    let completion = GuestCompletion<Value>()
    return try await withTaskCancellationHandler(operation: {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation, timeout: timeout)
            start { completion.finish($0) }
        }
    }, onCancel: { completion.finish(.failure(CancellationError())) })
}
