import Foundation
import LiveKitWebRTC

struct MeetingScreenShareEncodingEvidence: Equatable, Sendable {
    let codec: String
    let powerEfficient: Bool?
    let encoder: String?
}

struct MeetingScreenShareRequest {
    let profile: GuestVideoProfile
    let codec: String
    let captureFactory: (LKRTCVideoSource) -> any GuestCameraCapture

    init(profile: GuestVideoProfile, codec: String = "h264",
         captureFactory: @escaping (LKRTCVideoSource) -> any GuestCameraCapture) {
        self.profile = profile
        self.codec = codec
        self.captureFactory = captureFactory
    }
}

struct MeetingVideoDemand: Equatable, Sendable {
    var visibleParticipantIDs: Set<String>?
    var focusedParticipantID: String?
    var preferredScreenParticipantID: String?
    var receivesCameras = true
}
