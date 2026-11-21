import CryptoKit
import Foundation
import LiveKitWebRTC

struct VP9Fixture: Decodable {
    struct Frame: Decodable {
        let data: Data
        let key: Bool
        let sha256: String
        func image(timestamp: UInt32) -> LKRTCEncodedImage {
            let image = LKRTCEncodedImage()
            image.buffer = data; image.frameType = key ? .videoFrameKey : .videoFrameDelta
            image.timeStamp = timestamp; image.captureTimeMs = Int64(timestamp / 90); image.rotation = ._90
            return image
        }
    }
    let width: Int
    let height: Int
    let frames: [Frame]

    static func digest(_ frame: LKRTCVideoFrame) -> String {
        let planar = frame.buffer.toI420()
        var hash = SHA256()
        for (bytes, stride, width, height) in [(planar.dataY, planar.strideY, planar.width, planar.height),
                                               (planar.dataU, planar.strideU, planar.chromaWidth, planar.chromaHeight),
                                               (planar.dataV, planar.strideV, planar.chromaWidth, planar.chromaHeight)] {
            for row in 0..<Int(height) { hash.update(data: Data(bytes: bytes.advanced(by: row * Int(stride)), count: Int(width))) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
