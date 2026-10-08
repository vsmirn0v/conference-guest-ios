import LiveKit
import LiveKitWebRTC

enum CallVideoKind { case camera, screenShareVideo }

enum CallVideoSource {
    case room(VideoTrack)
    case native(LKRTCVideoTrack)
    var identity: ObjectIdentifier {
        switch self { case .room(let track): ObjectIdentifier(track); case .native(let track): ObjectIdentifier(track) }
    }
    var roomTrack: VideoTrack? { if case .room(let track) = self { track } else { nil } }
    func add(_ sink: RoomFloatingVideoSink) {
        switch self { case .room(let track): track.add(videoRenderer: sink); case .native(let track): track.add(sink) }
    }
    func remove(_ sink: RoomFloatingVideoSink) {
        switch self { case .room(let track): track.remove(videoRenderer: sink); case .native(let track): track.remove(sink) }
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
            isSpeaking: isSpeaking,
            videoKey: videoTracks.first { !$0.isMuted && $0.source == .camera }?.id,
            shareKey: isLocal ? nil : videoTracks.first { !$0.isMuted && $0.source == .screenShareVideo }?.id)
    }
}

struct CallMediaSnapshot {
    let participants: [CallParticipant]
    var remoteParticipants: [CallParticipant] { participants.filter { !$0.isLocal } }
    var localShare: CallVideoSource? { participants.first { $0.isLocal }?.videoTracks.first { !$0.isMuted && $0.source == .screenShareVideo }?.track }
    init(participants: [CallParticipant]) { self.participants = participants }
    init(room: Room) {
        participants = ([room.localParticipant] + room.remoteParticipants.values.sorted {
            ($0.identity?.stringValue ?? "") < ($1.identity?.stringValue ?? "")
        }).map { participant in
            let videos = participant.videoTracks
            return CallParticipant(id: participant.identity?.stringValue ?? participant.sid?.stringValue ?? "local",
                name: participant.name, isLocal: participant === room.localParticipant,
                microphoneOn: participant.audioTracks.contains { !$0.isMuted },
                cameraOn: videos.contains { !$0.isMuted && $0.source != .screenShareVideo },
                screenShareOn: videos.contains { !$0.isMuted && $0.source == .screenShareVideo },
                isSpeaking: participant.isSpeaking,
                videoTracks: videos.compactMap { publication in
                    guard let track = publication.track as? VideoTrack else { return nil }
                    return .init(id: publication.sid.stringValue,
                        source: publication.source == .screenShareVideo ? .screenShareVideo : .camera,
                        track: .room(track), isMuted: publication.isMuted)
                })
        }
    }
}
