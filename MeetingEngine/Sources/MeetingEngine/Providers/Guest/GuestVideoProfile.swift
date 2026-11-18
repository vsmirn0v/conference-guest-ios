import Foundation
import LiveKitWebRTC

/// One source/registration/encoder contract. Single encoding, no invented simulcast RID.
public struct GuestVideoProfile {
    public let width: Int32
    public let height: Int32
    public let fps: Int32
    public let maximumBitrate: Int
    public static let pattern = Self(width: 640, height: 360, fps: 15, maximumBitrate: 400_000)
    public static let camera = Self(width: 1280, height: 720, fps: 30, maximumBitrate: 1_100_000)
    public init(width: Int32, height: Int32, fps: Int32, maximumBitrate: Int) {
        self.width = width; self.height = height; self.fps = fps; self.maximumBitrate = maximumBitrate
    }
    public var layer: [String: Any] {
        ["quality": "HIGH", "width": width, "height": height, "bitrate": maximumBitrate]
    }
    public func encoding() -> LKRTCRtpEncodingParameters {
        let encoding = LKRTCRtpEncodingParameters()
        encoding.isActive = false
        encoding.maxBitrateBps = NSNumber(value: maximumBitrate)
        encoding.maxFramerate = NSNumber(value: fps)
        encoding.scaleResolutionDownBy = 1
        return encoding
    }
}
