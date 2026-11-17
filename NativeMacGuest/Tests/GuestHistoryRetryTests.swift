import Foundation

private enum Failure: Error { case transient, terminal }
private enum TestFailure: Error { case assertion }
private func expect(_ condition: @autoclosure () -> Bool) throws {
    if !condition() { throw TestFailure.assertion }
}

@MainActor private final class Gate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@main struct GuestHistoryRetryTests {
    @MainActor static func main() async throws {
        var attempts = 0, waits: [UInt64] = [], events: [String] = []
        try await GuestHistoryRetry.run(delays: [1, 2, 4], isCurrent: { true },
            isTransient: { if case Failure.transient = $0 { return true }; return false },
            record: { _, result in events.append(result) }, sleep: { waits.append($0) }) {
                attempts += 1
                if attempts == 1 { throw Failure.transient }
            }
        try expect(attempts == 2 && waits == [1] && events == ["started", "retrying", "started", "succeeded"])

        attempts = 0; waits = []
        do {
            try await GuestHistoryRetry.run(delays: [1, 2, 4], isCurrent: { true },
                isTransient: { _ in true }, sleep: { waits.append($0) }) {
                    attempts += 1; throw Failure.transient
                }
            throw TestFailure.assertion
        } catch Failure.transient {}
        try expect(attempts == 4 && waits == [1, 2, 4])

        attempts = 0
        do {
            try await GuestHistoryRetry.run(delays: [1, 2], isCurrent: { true },
                isTransient: { _ in false }, sleep: { _ in throw TestFailure.assertion }) {
                    attempts += 1; throw Failure.terminal
                }
            throw TestFailure.assertion
        } catch Failure.terminal {}
        try expect(attempts == 1)

        attempts = 0; var current = true
        do {
            try await GuestHistoryRetry.run(delays: [1], isCurrent: { current },
                isTransient: { _ in true }, sleep: { _ in current = false }) {
                    attempts += 1; throw Failure.transient
                }
            throw TestFailure.assertion
        } catch is CancellationError {}
        try expect(attempts == 1)

        // Even if a suspended operation ignores cancellation and completes,
        // its old owner cannot report success or issue a retry.
        let gate = Gate(); current = true; attempts = 0; events = []
        let job = Task { @MainActor in
            try await GuestHistoryRetry.run(delays: [1], isCurrent: { current },
                isTransient: { _ in true }, record: { _, event in events.append(event) }, sleep: { _ in }) {
                    attempts += 1; await gate.wait()
                }
        }
        while gate.continuation == nil { await Task.yield() }
        current = false; job.cancel(); gate.release()
        do { try await job.value; throw TestFailure.assertion } catch is CancellationError {}
        try expect(attempts == 1 && events == ["started"])
        print("Guest history retry: 5 scenarios passed")
    }
}
