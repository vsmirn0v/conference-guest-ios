import AVFoundation
import LiveKit

/// Observes processed capture through LiveKit's public renderer. Never unmutes it.
final class RoomMicrophoneProbe: AudioRenderer, @unchecked Sendable {
    private let sink: MicrophoneSampleSink
    init(activity: MicrophoneActivity) {
        sink = MicrophoneSampleSink { [weak activity] rms in
            Task { @MainActor in activity?.receive(rms: rms) }
        }
    }
    func render(pcmBuffer: AVAudioPCMBuffer) { sink.receive(pcmBuffer) }
}
