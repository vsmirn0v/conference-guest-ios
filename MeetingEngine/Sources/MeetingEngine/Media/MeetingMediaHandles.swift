import Foundation
import LiveKitWebRTC

public struct MeetingScreenShareEncodingEvidence: Equatable, Sendable {
    public let codec: String
    public let powerEfficient: Bool?
    public let encoder: String?

    public init(codec: String, powerEfficient: Bool?, encoder: String?) {
        self.codec = codec
        self.powerEfficient = powerEfficient
        self.encoder = encoder
    }
}

public struct MeetingScreenShareRequest {
    public let profile: GuestVideoProfile
    public let codec: String
    public let captureFactory: (LKRTCVideoSource) -> any GuestCameraCapture

    public init(profile: GuestVideoProfile, codec: String = "h264",
         captureFactory: @escaping (LKRTCVideoSource) -> any GuestCameraCapture) {
        self.profile = profile
        self.codec = codec
        self.captureFactory = captureFactory
    }
}

public struct MeetingVideoDemand: Equatable, Sendable {
    public var visibleParticipantIDs: Set<String>?
    public var focusedParticipantID: String?
    public var preferredScreenParticipantID: String?
    public var receivesCameras = true
    public var prioritizesPresenterCamera: Bool

    public init(visibleParticipantIDs: Set<String>? = nil,
                focusedParticipantID: String? = nil,
                preferredScreenParticipantID: String? = nil,
                receivesCameras: Bool = true,
                prioritizesPresenterCamera: Bool = false) {
        self.visibleParticipantIDs = visibleParticipantIDs
        self.focusedParticipantID = focusedParticipantID
        self.preferredScreenParticipantID = preferredScreenParticipantID
        self.receivesCameras = receivesCameras
        self.prioritizesPresenterCamera = prioritizesPresenterCamera
    }
}
