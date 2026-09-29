import Foundation

/// One ordered writer per room, with latest-intent coalescing while an SDK call awaits.
@MainActor
final class VideoSubscriptionCoordinator<Key: Hashable> {
    struct Request {
        let key: Key
        let subscribed: Bool
        let apply: (Bool) async throws -> Void
    }
    private var desired: [Key: Request] = [:]
    private var attempted: [Key: Bool] = [:]
    private var worker: Task<Void, Never>?
    private var generation = 0
    var onError: ((Error) -> Void)?

    func update(_ requests: [Request]) {
        desired = Dictionary(uniqueKeysWithValues: requests.map { ($0.key, $0) })
        attempted = attempted.filter { desired[$0.key] != nil }
        guard worker == nil else { return }
        let epoch = generation
        worker = Task { [weak self] in await self?.drain(epoch: epoch) }
    }

    /// A new room/reconnect cannot inherit the previous room's preferences or failures.
    func reset() {
        generation += 1
        worker?.cancel()
        worker = nil
        desired.removeAll()
        attempted.removeAll()
    }

    private func drain(epoch: Int) async {
        while generation == epoch, !Task.isCancelled,
              let request = desired.values.first(where: { attempted[$0.key] != $0.subscribed }) {
            // Record attempts before awaiting: failure reports once rather than spinning.
            attempted[request.key] = request.subscribed
            do { try await request.apply(request.subscribed) }
            catch {
                guard generation == epoch, !Task.isCancelled else { return }
                onError?(error)
            }
            // Re-read the latest desired state; intermediate toggles are discarded.
        }
        guard generation == epoch else { return }
        worker = nil
    }
}
