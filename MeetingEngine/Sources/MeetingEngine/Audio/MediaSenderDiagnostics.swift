import Foundation

/// Diagnostic readers share a short report deadline. A timed-out native read
/// may still be stuck, so only its actual callback frees the sampling slot.
@MainActor public final class MediaSenderDiagnostics {
    public enum Source: Hashable, Sendable { case meeting(UUID), companion }

    public struct Observation {
        public let state: GuestMicrophoneTrackObservation
        public let uptime: TimeInterval
        public let isCurrent: () -> Bool

        public init(state: GuestMicrophoneTrackObservation, uptime: TimeInterval, isCurrent: @escaping () -> Bool) {
            self.state = state; self.uptime = uptime; self.isCurrent = isCurrent
        }

        @MainActor public var reportFields: [String: Any] {
            guard isCurrent() else { return ["state": GuestMicrophoneTrackObservation.unavailable.rawValue] }
            return ["state": state.rawValue, "observedUptime": uptime]
        }
    }

    @MainActor private final class Batch {
        let completion = GuestCompletion<Void>()
        let isCurrent: [Source: () -> Bool]
        var remaining: Int
        var observations: [Source: Observation] = [:]

        init(probes: [Source: GuestMicrophoneTrackProbe]) {
            isCurrent = probes.mapValues(\.isCurrent)
            remaining = probes.count
        }
    }

    public static let shared = MediaSenderDiagnostics()
    private let maximumInFlight = 32
    private var pending: [Source: Batch] = [:]
    private var pendingRockReads = 0

    public func sample(_ probes: [Source: GuestMicrophoneTrackProbe],
                timeout: TimeInterval = 0.3) async -> [Source: Observation] {
        guard !Task.isCancelled, pending.count < maximumInFlight else { return [:] }
        let rockQueueAvailable = pendingRockReads == 0
        let eligible = probes.filter { source, probe in
            self.pending[source] == nil && (rockQueueAvailable || probe.queue != .rockSDK)
                && probe.isCurrent()
        }
        let requests = Dictionary(uniqueKeysWithValues: Array(eligible.prefix(max(0, maximumInFlight - pending.count))))
        guard !requests.isEmpty else { return [:] }
        let batch = Batch(probes: requests)
        let deadline = DispatchTime.now() + timeout
        for (source, probe) in requests {
            let usesRockQueue = probe.queue == .rockSDK
            pending[source] = batch
            if usesRockQueue { pendingRockReads += 1 }
            probe.start(deadline) { [weak self, weak batch] state, uptime in
                let metDeadline = DispatchTime.now() < deadline
                Task { @MainActor in
                    guard let self, let batch, self.pending[source] === batch else { return }
                    self.pending[source] = nil
                    if usesRockQueue { self.pendingRockReads -= 1 }
                    if metDeadline, state != .unavailable, let isCurrent = batch.isCurrent[source], isCurrent() {
                        batch.observations[source] = Observation(state: state, uptime: uptime, isCurrent: isCurrent)
                    }
                    batch.remaining -= 1
                    if batch.remaining == 0 { batch.completion.finish(.success(())) }
                }
            }
        }
        let completion = batch.completion
        _ = try? await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { completion.install($0, timeout: timeout) }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
        }
        return batch.observations
    }
}
