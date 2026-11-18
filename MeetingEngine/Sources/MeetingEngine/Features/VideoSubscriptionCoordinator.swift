import Foundation

/// One writer, latest intent, with two bounded retries for transient SDK failures.
@MainActor
public final class MediaConfigurationCoordinator<Key: Hashable, Value: Equatable> {
    public struct Request {
        public let key: Key
        public let value: Value
        public let apply: (Value) async throws -> Void
        public init(key: Key, value: Value, apply: @escaping (Value) async throws -> Void) {
            self.key = key; self.value = value; self.apply = apply
        }
    }
    private var desired: [Key: Request] = [:]
    private var applied: [Key: Value] = [:]
    private var failures: [Key: Int] = [:]
    private var worker: Task<Void, Never>?
    private var generation = 0
    private let retryDelay: UInt64
    public var onError: ((Error) -> Void)?
    public init(retryDelay: UInt64 = 250_000_000) { self.retryDelay = retryDelay }

    public func update(_ requests: [Request]) {
        let next = Dictionary(requests.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        failures = failures.filter { desired[$0.key]?.value == next[$0.key]?.value && next[$0.key] != nil }
        desired = next
        applied = applied.filter { desired[$0.key] != nil }
        guard worker == nil else { return }
        let epoch = generation
        worker = Task { [weak self] in await self?.drain(epoch: epoch) }
    }
    public func reset() {
        generation += 1
        worker?.cancel(); worker = nil
        desired.removeAll(); applied.removeAll(); failures.removeAll()
    }
    public func waitForReconciliation() async {
        while let worker { await worker.value }
    }
    public func isApplied(_ key: Key, value: Value) -> Bool { applied[key] == value }
    public func didFail(_ key: Key, value: Value) -> Bool {
        desired[key]?.value == value && (failures[key] ?? 0) >= 3
    }
    private func drain(epoch: Int) async {
        while generation == epoch, !Task.isCancelled,
              let request = desired.values.first(where: {
                  applied[$0.key] != $0.value && (failures[$0.key] ?? 0) < 3
              }) {
            let attempt = failures[request.key] ?? 0
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: retryDelay * UInt64(attempt))
                guard generation == epoch, !Task.isCancelled else { return }
                guard desired[request.key]?.value == request.value else { continue }
            }
            do {
                try await request.apply(request.value)
                guard generation == epoch, !Task.isCancelled else { return }
                if desired[request.key] != nil { applied[request.key] = request.value }
                failures[request.key] = nil
            } catch {
                guard generation == epoch, !Task.isCancelled else { return }
                guard desired[request.key]?.value == request.value else { continue }
                failures[request.key] = attempt + 1
                if attempt == 2 { onError?(error) }
            }
        }
        guard generation == epoch else { return }
        worker = nil
    }
}

// Preserve the subscription facade used by existing integration tests.
public typealias VideoSubscriptionCoordinator<Key: Hashable> = MediaConfigurationCoordinator<Key, Bool>
public extension MediaConfigurationCoordinator.Request where Value == Bool {
    init(key: Key, subscribed: Bool, apply: @escaping (Bool) async throws -> Void) {
        self.init(key: key, value: subscribed, apply: apply)
    }
}
