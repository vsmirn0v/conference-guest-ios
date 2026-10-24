import Foundation

/// No network, RTC factory, devices or arbitrary scheduling sleeps are used here.
@main @MainActor struct AsyncTests {
    private enum FixtureError: Error { case expected, duplicate }

    static func main() async throws {
        // A lost continuation or deadlock fails this executable instead of hanging the test run.
        let watchdog = DispatchWorkItem { fatalError("Async completion tests exceeded 20 seconds") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
        defer { watchdog.cancel() }
        try await resultBeforeInstall()
        try await duplicateCallbacks()
        try await callbackFailure()
        try await timeoutAndLateCallback()
        try await cancellationBeforeStart()
        try await cancellationWhileWaiting()
        try await callbackWinsBeforeCancellation()
        try await concurrentCompletion()
        print("PASS: async callback success/failure, result before install, duplicates, timeout, late callbacks, cancellation ordering, 128 concurrent completion rounds")
    }

    private static func installedValue(_ completion: GuestCompletion<Int>, timeout: TimeInterval = 1) async throws -> Int {
        try await withCheckedThrowingContinuation { completion.install($0, timeout: timeout) }
    }

    private static func resultBeforeInstall() async throws {
        let success = GuestCompletion<Int>()
        success.finish(.success(47))
        success.finish(.failure(FixtureError.duplicate))
        // An immediate timeout cannot replace an already delivered result.
        let value = try await installedValue(success, timeout: 0)
        precondition(value == 47)
        let failure = GuestCompletion<Int>()
        failure.finish(.failure(FixtureError.expected))
        failure.finish(.success(99))
        do { _ = try await installedValue(failure, timeout: 0); preconditionFailure("Early error was discarded") }
        catch FixtureError.expected {}
    }

    private static func duplicateCallbacks() async throws {
        var callbacks = 0
        let value: Int = try await guestAwait(timeout: 1) { finish in
            callbacks += 1; finish(.success(11))
            callbacks += 1; finish(.success(12))
            callbacks += 1; finish(.failure(FixtureError.duplicate))
        }
        precondition(value == 11 && callbacks == 3)
    }

    private static func callbackFailure() async throws {
        do {
            let _: Int = try await guestAwait(timeout: 1) { finish in
                finish(.failure(FixtureError.expected))
                finish(.success(12))
            }
            preconditionFailure("Callback error was discarded")
        } catch FixtureError.expected {}
    }

    private static func timeoutAndLateCallback() async throws {
        var callback: ((Result<Int, Error>) -> Void)?
        do {
            let _: Int = try await guestAwait(timeout: 0.01) { callback = $0 }
            preconditionFailure("Missing callback did not time out")
        } catch GuestTransportError.timedOut {}
        precondition(callback != nil)
        callback?(.success(1))
        callback?(.failure(FixtureError.duplicate))
        // Also prove the stored terminal timeout remains authoritative for a later installer.
        let completion = GuestCompletion<Int>()
        do { _ = try await installedValue(completion, timeout: 0); preconditionFailure("Deadline did not fire") }
        catch GuestTransportError.timedOut {}
        completion.finish(.success(15))
        do { _ = try await installedValue(completion); preconditionFailure("Late completion replaced timeout") }
        catch GuestTransportError.timedOut {}
    }

    private static func cancellationBeforeStart() async throws {
        var started = false
        let task = Task { @MainActor in
            let value: Int = try await guestAwait(timeout: 1) { finish in started = true; finish(.success(1)) }
            return value
        }
        // This actor has not yielded, so the child cannot have entered the start closure yet.
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Pre-cancelled task completed") }
        catch is CancellationError {}
        precondition(!started, "Pre-cancelled task started a native operation")
    }

    private static func cancellationWhileWaiting() async throws {
        let started = Signal()
        var callback: ((Result<Int, Error>) -> Void)?
        let task = Task { @MainActor in
            let value: Int = try await guestAwait(timeout: 2) { finish in
                callback = finish
                Task { await started.fire() }
            }
            return value
        }
        await started.wait()
        precondition(callback != nil)
        task.cancel()
        // Cancellation wins synchronously through its handler before these late callbacks.
        callback?(.success(1)); callback?(.failure(FixtureError.duplicate))
        do { _ = try await task.value; preconditionFailure("Pending task ignored cancellation") }
        catch is CancellationError {}
    }

    private static func callbackWinsBeforeCancellation() async throws {
        let started = Signal()
        var callback: ((Result<Int, Error>) -> Void)?
        let task = Task { @MainActor in
            let value: Int = try await guestAwait(timeout: 2) { finish in
                callback = finish
                Task { await started.fire() }
            }
            return value
        }
        await started.wait()
        precondition(callback != nil)
        callback?(.success(31))
        task.cancel()
        let value = try await task.value
        precondition(value == 31, "Cancellation replaced an already completed callback")
    }

    private static func concurrentCompletion() async throws {
        for round in 0..<128 {
            let completion = GuestCompletion<Int>(), finished = DispatchGroup()
            finished.enter()
            let winner: Result<Int, Error>
            do {
                let value: Int = try await withCheckedThrowingContinuation { continuation in
                    completion.install(continuation, timeout: 3)
                    DispatchQueue.global().async {
                        DispatchQueue.concurrentPerform(iterations: 64) { index in
                            switch index % 3 {
                            case 0: completion.finish(.success(index))
                            case 1: completion.finish(.failure(FixtureError.expected))
                            default: completion.finish(.failure(CancellationError()))
                            }
                        }
                        finished.leave()
                    }
                }
                winner = .success(value)
            } catch { winner = .failure(error) }
            // Wait for every contender without blocking this actor, so no work escapes its round.
            await withCheckedContinuation { done in finished.notify(queue: .global()) { done.resume() } }
            switch winner {
            case .success(let value): precondition((0..<64).contains(value) && value % 3 == 0)
            case .failure(FixtureError.expected), .failure(is CancellationError): break
            default: preconditionFailure("Unexpected concurrent completion in round \(round): \(winner)")
            }
            // The exact winner is intentionally free; the invariant is one stable terminal result.
            let subsequent: Result<Int, Error>
            do { subsequent = .success(try await installedValue(completion)) }
            catch { subsequent = .failure(error) }
            switch (winner, subsequent) {
            case (.success(let first), .success(let second)): precondition(first == second)
            case (.failure(FixtureError.expected), .failure(FixtureError.expected)): break
            case (.failure(is CancellationError), .failure(is CancellationError)): break
            default: preconditionFailure("Concurrent terminal result changed")
            }
        }
    }

    private actor Signal {
        private var fired = false
        private var waiter: CheckedContinuation<Void, Never>?
        func fire() { fired = true; waiter?.resume(); waiter = nil }
        func wait() async {
            if fired { return }
            await withCheckedContinuation { waiter = $0 }
        }
    }
}
