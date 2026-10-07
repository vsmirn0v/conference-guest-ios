import AVFoundation
import Combine
import LiveKit

/// Observes processed capture through LiveKit's public renderer. Never unmutes it.
final class RoomMicrophoneProbe: AudioRenderer, @unchecked Sendable {
    private let sink: MicrophoneSampleSink
    private var observation: AnyCancellable?
    @MainActor init(activity: MicrophoneActivity) {
        sink = MicrophoneSampleSink { [weak activity] rms in
            Task { @MainActor in activity?.receive(rms: rms) }
        }
        observation = activity.$samplingNeeded.sink { [sink] in sink.setEnabled($0) }
    }
    func render(pcmBuffer: AVAudioPCMBuffer) { sink.receive(pcmBuffer) }
}
