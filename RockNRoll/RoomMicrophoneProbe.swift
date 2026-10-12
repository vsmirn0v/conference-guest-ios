import AVFoundation
import Combine
import LiveKit

/// Observes processed capture through LiveKit's public renderer. Never unmutes it.
final class RoomMicrophoneProbe: AudioRenderer, @unchecked Sendable {
    private let sink: MicrophoneSampleSink
    private let levels: LatestMicrophoneLevel
    private var observation: AnyCancellable?
    private var timer: Timer?
    @MainActor private var attached = false
    @MainActor init(activity: MicrophoneActivity) {
        let levels = LatestMicrophoneLevel(); self.levels = levels
        sink = MicrophoneSampleSink { levels.receive($0) }
        sink.setEnabled(false); levels.setEnabled(false)
        observation = activity.$samplingNeeded.removeDuplicates().sink { [weak self, weak activity] needed in
            guard let self else { return }
            self.sink.setEnabled(needed); self.levels.setEnabled(needed)
            if needed {
                if !self.attached { AudioManager.shared.add(localAudioRenderer: self); self.attached = true }
                guard self.timer == nil else { return }
                let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self, weak activity] _ in
                    MainActor.assumeIsolated {
                        guard let self, let rms = self.levels.take() else { return }
                        activity?.receive(rms: rms)
                    }
                }
                self.timer = timer; RunLoop.main.add(timer, forMode: .common)
            } else { self.detach() }
        }
    }
    deinit { timer?.invalidate() }
    func render(pcmBuffer: AVAudioPCMBuffer) { sink.receive(pcmBuffer) }
    @MainActor private func detach() {
        if attached { AudioManager.shared.remove(localAudioRenderer: self); attached = false }
        timer?.invalidate(); timer = nil
    }
    @MainActor func stop() {
        observation = nil; sink.setEnabled(false); levels.setEnabled(false); detach()
    }
    #if DEBUG
    @MainActor var isAttachedForTesting: Bool { attached }
    #endif
}

/// One scalar, independent of UI availability. Queued PCM observations cannot
/// accumulate UI tasks, and optional metering drops samples on contention.
final class LatestMicrophoneLevel: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var pending: Float?
    func setEnabled(_ value: Bool) { lock.lock(); enabled = value; pending = nil; lock.unlock() }
    func receive(_ value: Float) {
        guard lock.try() else { return }
        if enabled { pending = value }
        lock.unlock()
    }
    func take() -> Float? { lock.lock(); defer { lock.unlock() }; let result = pending; pending = nil; return result }
}
