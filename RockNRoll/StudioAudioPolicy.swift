import LiveKit

enum StudioAudioPolicy {
    static func captureOptions(for profile: StudioAudioProfile) -> AudioCaptureOptions {
        if profile == .conversation { return AudioCaptureOptions() }
        // Apple's AEC and suppression can be coupled. Software AEC preserves echo
        // protection without requesting that coupled speech-filtering path.
        return AudioCaptureOptions(echoCancellation: true, autoGainControl: false,
            noiseSuppression: false, echoCancellationMode: .software)
    }

    static func processingOptions(for profile: StudioAudioProfile) -> AudioProcessingOptions {
        if profile == .conversation { return AudioProcessingOptions() }
        return AudioProcessingOptions(echoCancellation: true, autoGainControl: false,
            noiseSuppression: false, echoCancellationMode: .software)
    }
}

/// Serializes runtime changes with mute/resume updates; retired requests cannot
/// overwrite a newer selection. Each room has its own instance.
@MainActor
final class StudioAudioUpdates {
    var profile: StudioAudioProfile = .conversation
    private var active = true
    private var pending: ((StudioAudioProfile) async throws -> Void)?
    private var worker: Task<Void, Error>?

    func apply(_ operation: @escaping (StudioAudioProfile) async throws -> Void) async throws {
        guard active else { throw CancellationError() }
        pending = operation
        if let worker { return try await worker.value }
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            defer { self.worker = nil }
            while let next = self.pending {
                self.pending = nil
                guard self.active else { throw CancellationError() }
                try Task.checkCancellation()
                do { try await next(self.profile) }
                catch { if self.pending == nil { throw error } }
                try Task.checkCancellation()
            }
        }
        worker = task
        try await task.value
    }

    func end() { active = false; pending = nil; worker?.cancel() }
}
