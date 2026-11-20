import AVFoundation
import Foundation
import LiveKitWebRTC

/// One remote audio stream a meeting can transcribe. A mixed stream has no identity.
public struct MeetingAudioSource {
    public let id: String
    public let participantIdentity: String?
    public let attach: (MeetingAudioSink) -> Void
    public let detach: (MeetingAudioSink) -> Void

    public static func webRTC(_ track: LKRTCAudioTrack, identity: String?) -> Self {
        .init(id: track.trackId, participantIdentity: identity, attach: { track.add($0) }, detach: { track.remove($0) })
    }
}

public extension GuestRemoteAudio {
    var source: MeetingAudioSource { .webRTC(track, identity: participantIdentity) }
}

/// A sink on one remote track. By default its consumer receives a private copy.
public final class MeetingAudioSink: NSObject, LKRTCAudioRenderer, @unchecked Sendable {
    /// Opaque provider-owned renderer handle stored by the provider bridge so attach and detach share one instance.
    public var adapterRenderer: AnyObject?
    public let trackID: String
    public let deliver: (String, AVAudioPCMBuffer) -> Void
    private let borrowsBuffers: Bool
    public init(trackID: String, deliver: @escaping (String, AVAudioPCMBuffer) -> Void) {
        self.trackID = trackID; self.deliver = deliver; borrowsBuffers = false
    }
    /// The consumer may inspect the renderer's buffer during this callback.
    /// It must copy any audio it accepts for asynchronous processing.
    public init(borrowingBuffersFor trackID: String, deliver: @escaping (String, AVAudioPCMBuffer) -> Void) {
        self.trackID = trackID; self.deliver = deliver; borrowsBuffers = true
    }
    public func render(pcmBuffer: AVAudioPCMBuffer) {
        if borrowsBuffers { deliver(trackID, pcmBuffer) }
        else if let copy = Self.copy(pcmBuffer) { deliver(trackID, copy) }
    }
    public static func copy(_ pcmBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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
