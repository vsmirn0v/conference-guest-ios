import Foundation

/// One writer, latest intent, with two bounded retries for transient SDK failures.
@MainActor
final class VideoSubscriptionCoordinator<Key: Hashable> {
    struct Request {
        let key: Key
        let subscribed: Bool
        let apply: (Bool) async throws -> Void
    }
    private var desired: [Key: Request] = [:]
    private var applied: [Key: Bool] = [:]
    private var failures: [Key: Int] = [:]
    private var worker: Task<Void, Never>?
    private var generation = 0
    private let retryDelay: UInt64
    var onError: ((Error) -> Void)?
    init(retryDelay: UInt64 = 250_000_000) { self.retryDelay = retryDelay }

    func update(_ requests: [Request]) {
        let next = Dictionary(requests.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        failures = failures.filter { desired[$0.key]?.subscribed == next[$0.key]?.subscribed && next[$0.key] != nil }
        desired = next
        applied = applied.filter { desired[$0.key] != nil }
        guard worker == nil else { return }
        let epoch = generation
        worker = Task { [weak self] in await self?.drain(epoch: epoch) }
    }
    func reset() {
        generation += 1
        worker?.cancel(); worker = nil
        desired.removeAll(); applied.removeAll(); failures.removeAll()
    }
    private func drain(epoch: Int) async {
        while generation == epoch, !Task.isCancelled,
              let request = desired.values.first(where: {
                  applied[$0.key] != $0.subscribed && (failures[$0.key] ?? 0) < 3
              }) {
            let attempt = failures[request.key] ?? 0
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: retryDelay * UInt64(attempt))
                guard generation == epoch, !Task.isCancelled else { return }
                guard desired[request.key]?.subscribed == request.subscribed else { continue }
            }
            do {
                try await request.apply(request.subscribed)
                guard generation == epoch, !Task.isCancelled else { return }
                if desired[request.key] != nil { applied[request.key] = request.subscribed }
                failures[request.key] = nil
            } catch {
                guard generation == epoch, !Task.isCancelled else { return }
                guard desired[request.key]?.subscribed == request.subscribed else { continue }
                failures[request.key] = attempt + 1
                if attempt == 2 { onError?(error) }
            }
        }
        guard generation == epoch else { return }
        worker = nil
    }
}
