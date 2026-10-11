import LiveKit
import LiveKitWebRTC

enum CallVideoKind { case camera, screenShareVideo }

enum CallVideoSource {
    case room(VideoTrack)
    case native(LKRTCVideoTrack)
    case composite(CompositeVideoSource)
    case cameraPreview(CameraCapturePreview)
    var identity: ObjectIdentifier {
        switch self { case .room(let track): ObjectIdentifier(track); case .native(let track): ObjectIdentifier(track); case .composite(let source): ObjectIdentifier(source); case .cameraPreview(let source): ObjectIdentifier(source) }
    }
    var roomTrack: VideoTrack? { if case .room(let track) = self { track } else { nil } }
    var cameraPreview: CameraCapturePreview? { if case .cameraPreview(let source) = self { source } else { nil } }
    func add(_ sink: RoomFloatingVideoSink) {
        switch self { case .room(let track): track.add(videoRenderer: sink); case .native(let track): track.add(sink); case .composite(let source): source.add(sink); case .cameraPreview: break }
    }
    func remove(_ sink: RoomFloatingVideoSink) {
        switch self { case .room(let track): track.remove(videoRenderer: sink); case .native(let track): track.remove(sink); case .composite(let source): source.remove(sink); case .cameraPreview: break }
    }
}

struct CallVideoStream {
    let id: String
    let source: CallVideoKind
    let track: CallVideoSource
    var isMuted = false
}

struct CallParticipant {
    let id: String
    let name: String?
    let isLocal: Bool
    var microphoneOn: Bool
    var cameraOn: Bool
    var screenShareOn: Bool
    var isSpeaking: Bool
    var videoTracks: [CallVideoStream]
    var status: ParticipantStatus {
        .init(id: id, name: name ?? L("Musician"), isLocal: isLocal,
            microphoneOn: microphoneOn, cameraOn: cameraOn, screenShareOn: screenShareOn,
            isSpeaking: ParticipantAudioState(microphoneOn: microphoneOn, speaking: isSpeaking).speaking,
            videoKey: videoTracks.first { !$0.isMuted && $0.source == .camera }?.id,
            shareKey: isLocal ? nil : videoTracks.first { !$0.isMuted && $0.source == .screenShareVideo }?.id)
    }
}

struct CallMediaSnapshot {
    let participants: [CallParticipant]
    var remoteParticipants: [CallParticipant] { participants.filter { !$0.isLocal } }
    var localShare: CallVideoSource? { participants.first { $0.isLocal }?.videoTracks.first { !$0.isMuted && $0.source == .screenShareVideo }?.track }
    init(participants: [CallParticipant]) { self.participants = participants }
    init(room: Room, localCameraPreview: CameraCapturePreview? = nil) {
        participants = ([room.localParticipant] + room.remoteParticipants.values.sorted {
            ($0.identity?.stringValue ?? "") < ($1.identity?.stringValue ?? "")
        }).map { participant in
            let videos = participant.videoTracks
            return CallParticipant(id: participant.identity?.stringValue ?? participant.sid?.stringValue ?? "local",
                name: participant.name, isLocal: participant === room.localParticipant,
                microphoneOn: participant.audioTracks.contains { $0.source == .microphone && !$0.isMuted },
                cameraOn: videos.contains { !$0.isMuted && $0.source != .screenShareVideo },
                screenShareOn: videos.contains { !$0.isMuted && $0.source == .screenShareVideo },
                isSpeaking: participant.isSpeaking,
                videoTracks: videos.compactMap { publication in
                    guard let track = publication.track as? VideoTrack else { return nil }
                    return .init(id: publication.sid.stringValue,
                        source: publication.source == .screenShareVideo ? .screenShareVideo : .camera,
                        track: participant === room.localParticipant && publication.source == .camera
                            ? localCameraPreview.map { .cameraPreview($0) } ?? .room(track) : .room(track),
                        isMuted: publication.isMuted)
                })
        }
    }
}
