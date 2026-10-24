import Foundation
import LiveKitWebRTC

/// One source/registration/encoder contract. Single encoding, no invented simulcast RID.
struct GuestVideoProfile {
    let width: Int32
    let height: Int32
    let fps: Int32
    let maximumBitrate: Int
    static let pattern = Self(width: 640, height: 360, fps: 15, maximumBitrate: 400_000)
    static let camera = Self(width: 1280, height: 720, fps: 30, maximumBitrate: 1_100_000)
    var layer: [String: Any] {
        ["quality": "HIGH", "width": width, "height": height, "bitrate": maximumBitrate]
    }
    func encoding() -> LKRTCRtpEncodingParameters {
        let encoding = LKRTCRtpEncodingParameters()
        encoding.isActive = false
        encoding.maxBitrateBps = NSNumber(value: maximumBitrate)
        encoding.maxFramerate = NSNumber(value: fps)
        encoding.scaleResolutionDownBy = 1
        return encoding
    }
}
