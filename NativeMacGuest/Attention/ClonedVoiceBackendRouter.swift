import Combine
import Foundation

/// Chooses a verified backend at utterance boundaries. The router does not load
/// a model or make a backend ready: its owner must first verify the installed
/// model, runtime and saved-voice compatibility. In particular, an unavailable
/// GPU backend is never silently presented as working.
actor ClonedVoiceBackendRouter {
    enum Backend: Hashable, Sendable { case neuralEngine, gpu }
    enum Readiness: Equatable, Sendable { case unavailable, preparing, ready }
    enum State: Equatable, Sendable { case unavailable, preparing, ready, synthesizing }
    enum Failure: Error, Equatable { case unavailable, busy, expired, invalidated }

    struct BackendFailure: LocalizedError {
        let backend: Backend
        let underlying: Error
        var errorDescription: String? { underlying.localizedDescription }
    }

    struct Snapshot: Equatable, Sendable {
        var neuralEngine: State
        var gpu: State
        var active: Backend?
    }

    struct Output: Sendable {
        let backend: Backend
        let samples: [Float]
    }

    /// Each concrete backend must bound its own operation and terminate a
    /// noncooperative worker on deadline. Router expiry checks reject late
    /// results; they do not interrupt a framework that ignores cancellation.
    typealias Synthesize = @Sendable (_ text: String, _ voice: VoxVoice) async throws -> [Float]
    private let neuralEngine: Synthesize
    private let gpu: Synthesize
    private let stopGPU: @Sendable () async -> Void
    private let now: @Sendable () -> Date
    private var readiness: [Backend: Readiness] = [.neuralEngine: .unavailable, .gpu: .unavailable]
    private var active: Backend?
    private var activeRequest: UUID?
    private var cancellingRequest: UUID?
    private var cancelledRequests: Set<UUID> = []
    private var generation: UInt64 = 0
    nonisolated let changes = CurrentValueSubject<Snapshot, Never>(.init(neuralEngine: .unavailable, gpu: .unavailable, active: nil))

    init(neuralEngine: @escaping Synthesize, gpu: @escaping Synthesize,
         stopGPU: @escaping @Sendable () async -> Void = {},
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.neuralEngine = neuralEngine
        self.gpu = gpu
        self.stopGPU = stopGPU
        self.now = now
    }

    func setReadiness(_ value: Readiness, for backend: Backend) {
        guard readiness[backend] != value else { return }
        readiness[backend] = value
        // Losing the active backend invalidates its eventual output. A different
        // backend becoming ready must not interrupt an utterance already running.
        if active == backend && value != .ready { generation &+= 1 }
        changes.send(snapshot)
    }

    /// Invoke when approval, audience, voice enrollment or the caller's request
    /// changes. A noncooperative worker remains busy until it actually exits.
    func invalidatePending() { generation &+= 1 }

    /// Stop only the matching GPU operation; the reservation prevents a late
    /// cancellation from interrupting the next utterance while the helper exits.
    func cancelGPURequest(_ request: UUID) async {
        guard active == .gpu, activeRequest == request, cancellingRequest == nil else { return }
        cancellingRequest = request
        cancelledRequests.insert(request)
        generation &+= 1
        await stopGPU()
        if cancellingRequest == request { cancellingRequest = nil }
    }

    var snapshot: Snapshot {
        func state(_ backend: Backend) -> State {
            if active == backend { return .synthesizing }
            switch readiness[backend] ?? .unavailable {
            case .unavailable: return .unavailable
            case .preparing: return .preparing
            case .ready: return .ready
            }
        }
        return .init(neuralEngine: state(.neuralEngine), gpu: state(.gpu), active: active)
    }

    func speak(_ text: String, voice: VoxVoice, expiresAt: Date, request: UUID = UUID()) async throws -> Output {
        try Task.checkCancellation()
        guard now() < expiresAt else { throw Failure.expired }
        guard active == nil, cancellingRequest == nil else { throw Failure.busy }
        let selected: Backend
        if readiness[.neuralEngine] == .ready { selected = .neuralEngine }
        else if readiness[.gpu] == .ready { selected = .gpu }
        else { throw Failure.unavailable }

        let operationGeneration = generation
        active = selected
        activeRequest = request
        changes.send(snapshot)
        defer { active = nil; activeRequest = nil; cancelledRequests.remove(request); changes.send(snapshot) }
        // A failure is returned to the caller. Retrying it on the other backend
        // could replay an expired or already-authorized meeting utterance.
        let samples: [Float]
        do { samples = try await (selected == .neuralEngine ? neuralEngine : gpu)(text, voice) }
        catch is CancellationError { throw CancellationError() }
        catch {
            // Stopping a helper to honor caller cancellation may surface as a
            // worker error; cancellation must not mark the backend broken.
            if cancelledRequests.contains(request) { throw CancellationError() }
            try Task.checkCancellation()
            throw BackendFailure(backend: selected, underlying: error)
        }
        try Task.checkCancellation()
        if cancelledRequests.contains(request) { throw CancellationError() }
        guard generation == operationGeneration else { throw Failure.invalidated }
        guard now() < expiresAt else { throw Failure.expired }
        do { try ClonedVoiceWire.validatePCM(samples) }
        catch { throw BackendFailure(backend: selected, underlying: error) }
        return .init(backend: selected, samples: samples)
    }
}
