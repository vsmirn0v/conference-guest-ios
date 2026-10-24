import CoreVideo
import Foundation
import LiveKitWebRTC

private final class CountingBuffer: LKRTCCVPixelBuffer {
    var conversions = 0
    override func toI420() -> LKRTCI420BufferProtocol { conversions += 1; return super.toI420() }
}

@main struct FrameCounterTests {
    static func buffer(_ width: Int, _ height: Int) -> CVPixelBuffer {
        var value: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &value) == kCVReturnSuccess)
        return value!
    }
    static func main() {
        let pixels = buffer(32,32), wrapped = CountingBuffer(pixelBuffer: pixels)
        let lightweight = GuestFrameCounter(verifyPixels: false), verified = GuestFrameCounter()
        for n in 1...12 {
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), n % 2 == 0 ? 255 : 0, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            let frame = LKRTCVideoFrame(buffer: wrapped, rotation: ._0, timeStampNs: Int64(n))
            let before = wrapped.conversions
            lightweight.renderFrame(frame)
            precondition(wrapped.conversions == before, "Ordinary receive accounting must never convert pixels")
            verified.renderFrame(frame)
        }
        precondition(wrapped.conversions == 12)
        precondition(verified.evidence["pixelChanges"] as? Int == 11)
        precondition(lightweight.evidence["pixelChanges"] as? Int == 0)
        for key in ["frames", "advancingFrames", "width", "height"] {
            precondition(String(describing: lightweight.evidence[key]!) == String(describing: verified.evidence[key]!))
        }
        let track = GuestTrackRenderer(counter: lightweight)
        track.renderFrame(LKRTCVideoFrame(buffer: wrapped, rotation: ._0, timeStampNs: 1))
        precondition(lightweight.evidence["advancingFrames"] as? Int == 13)
        track.stop(); track.renderFrame(LKRTCVideoFrame(buffer: wrapped, rotation: ._0, timeStampNs: 2))
        precondition(lightweight.evidence["advancingFrames"] as? Int == 13)
        let hd = LKRTCCVPixelBuffer(pixelBuffer: buffer(1920,1080))
        var measurements: [String: [Double]] = ["pixelVerification": [], "arrivalOnly": []]
        for trial in 0..<6 {
            for enabled in trial % 2 == 0 ? [true,false] : [false,true] {
                let counter = GuestFrameCounter(verifyPixels: enabled)
                for n in 0..<20 { counter.renderFrame(LKRTCVideoFrame(buffer: hd, rotation: ._0, timeStampNs: Int64(n))) }
                let start = ProcessInfo.processInfo.systemUptime
                for n in 20..<220 { counter.renderFrame(LKRTCVideoFrame(buffer: hd, rotation: ._0, timeStampNs: Int64(n))) }
                measurements[enabled ? "pixelVerification" : "arrivalOnly"]!.append((ProcessInfo.processInfo.systemUptime-start)*1000/200)
            }
        }
        print(String(decoding: try! JSONSerialization.data(withJSONObject: measurements, options: [.sortedKeys]), as: UTF8.self))
        print("PASS: arrival-only accounting avoids pixel conversion; explicit pixel verification and track epochs preserved")
    }
}
