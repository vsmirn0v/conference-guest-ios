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

/// Applies speaker gain to WebRTC's mixed playback. The render callback uses
/// float samples in the Int16 range and runs on WebRTC's audio thread.
final class IPhoneSpeakerPlaybackProcessor: AudioCustomProcessingDelegate {
    @MainActor private var installed = false

    @MainActor func setEnabled(_ enabled: Bool) {
        guard enabled || installed else { return }
        let manager = AudioManager.shared
        if enabled {
            guard manager.renderPreProcessingDelegate == nil else { return }
            manager.renderPreProcessingDelegate = self
            installed = true
        } else {
            if manager.renderPreProcessingDelegate === self {
                manager.renderPreProcessingDelegate = nil
            }
            installed = false
        }
    }

    func audioProcessingInitialize(sampleRate _: Int, channels _: Int) {}
    func audioProcessingRelease() {}

    func audioProcessingProcess(audioBuffer: LKAudioBuffer) {
        let frames = audioBuffer.frames
        for channel in 0..<audioBuffer.channels {
            let samples = audioBuffer.rawBuffer(forChannel: channel)
            for frame in 0..<frames {
                samples[frame] = Self.boostedSample(samples[frame])
            }
        }
    }

    static func boostedSample(_ sample: Float) -> Float {
        let peak = sample < 0 ? -Float(Int16.min) : Float(Int16.max)
        let magnitude = abs(sample)
        if magnitude <= peak / 3 { return sample * 1.5 }

        // Above one third of full scale, a quadratic joins the linear gain
        // with the same slope and flattens smoothly at the original peak.
        let headroom = max(0, peak - magnitude)
        let limited = peak - (1.125 / peak) * headroom * headroom
        return sample < 0 ? -limited : limited
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
