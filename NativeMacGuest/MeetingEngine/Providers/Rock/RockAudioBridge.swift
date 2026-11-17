import AVFoundation
import LiveKit

extension MeetingAudioSource {
    static func liveKit(_ track: RemoteAudioTrack, id: String, identity: String?) -> Self {
        .init(id: id, participantIdentity: identity, attach: { sink in
            let renderer: LiveKitAudioSink
            if let existing = sink.adapterRenderer as? LiveKitAudioSink {
                renderer = existing
            } else {
                let created = LiveKitAudioSink(sink)
                sink.adapterRenderer = created
                renderer = created
            }
            track.add(audioRenderer: renderer)
        }, detach: { sink in
            guard let renderer = sink.adapterRenderer as? LiveKitAudioSink else { return }
            track.remove(audioRenderer: renderer)
        })
    }
}

/// LiveKit's renderer protocol has its own Objective-C selector; this forwards to the sink.
private final class LiveKitAudioSink: NSObject, AudioRenderer, @unchecked Sendable {
    let sink: MeetingAudioSink
    init(_ sink: MeetingAudioSink) { self.sink = sink }
    func render(pcmBuffer: AVAudioPCMBuffer) { sink.render(pcmBuffer: pcmBuffer) }
}
