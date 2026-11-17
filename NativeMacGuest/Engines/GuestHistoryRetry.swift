import Foundation

/// Initial history is optional, but a transient signaling error must not leave
/// a meeting permanently without it. The owner supplies current-attempt and
/// permission checks, and cancels this job when either changes.
@MainActor enum GuestHistoryRetry {
    static func run(
        delays: [UInt64] = [500_000_000, 1_000_000_000, 2_000_000_000],
        isCurrent: () -> Bool,
        isTransient: (Error) -> Bool,
        record: (Int, String) -> Void = { _, _ in },
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        operation: () async throws -> Void
    ) async throws {
        for attempt in 0...delays.count {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            record(attempt + 1, "started")
            do {
                try await operation()
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                record(attempt + 1, "succeeded")
                return
            } catch {
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                guard isTransient(error), attempt < delays.count else {
                    record(attempt + 1, "failed")
                    throw error
                }
                record(attempt + 1, "retrying")
                try await sleep(delays[attempt])
            }
        }
    }
}
