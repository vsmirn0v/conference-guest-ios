import AVFoundation
import Foundation
import LiveKitWebRTC

/// One remote audio stream a meeting can transcribe. A mixed stream has no identity.
struct MeetingAudioSource {
    let id: String
    let participantIdentity: String?
    let attach: (MeetingAudioSink) -> Void
    let detach: (MeetingAudioSink) -> Void

    static func webRTC(_ track: LKRTCAudioTrack, identity: String?) -> Self {
        .init(id: track.trackId, participantIdentity: identity, attach: { track.add($0) }, detach: { track.remove($0) })
    }
}

/// A sink on one remote track. It copies each buffer and returns at once: the
/// audio thread never waits for conversion or recognition.
final class MeetingAudioSink: NSObject, LKRTCAudioRenderer, @unchecked Sendable {
    /// Opaque provider-owned renderer handle stored by the provider bridge so attach and detach share one instance.
    var adapterRenderer: AnyObject?
    let trackID: String
    let deliver: (String, AVAudioPCMBuffer) -> Void
    init(trackID: String, deliver: @escaping (String, AVAudioPCMBuffer) -> Void) { self.trackID = trackID; self.deliver = deliver }
    func render(pcmBuffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(pcmBuffer) else { return }
        deliver(trackID, copy)
    }
    static func copy(_ pcmBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard pcmBuffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: pcmBuffer.format, frameCapacity: pcmBuffer.frameLength) else { return nil }
        copy.frameLength = pcmBuffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let input = from.mData, let output = to.mData else { continue }
            memcpy(output, input, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}
