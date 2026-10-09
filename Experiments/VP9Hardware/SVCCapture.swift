import Foundation
import LiveKitWebRTC

private final class Capture: NSObject, LKRTCVideoDecoder {
    private let lock = NSLock()
    private var frames: [[String: Any]] = []
    func implementationName() -> String { "VP9 capture" }
    func setCallback(_ callback: @escaping (LKRTCVideoFrame) -> Void) {}
    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int { 0 }
    func release() -> Int { 0 }
    func decode(_ image: LKRTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any LKRTCCodecSpecificInfo)?, renderTimeMs: Int64) -> Int {
        lock.lock(); defer { lock.unlock() }
        if frames.count < 90 { frames.append(["data": image.buffer.base64EncodedString(), "key": image.frameType == .videoFrameKey, "timestamp": image.timeStamp, "width": image.encodedWidth, "height": image.encodedHeight]) }
        return 0
    }
    func save(_ path: String) throws {
        lock.lock(); defer { lock.unlock() }
        try JSONSerialization.data(withJSONObject: frames, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path))
        print("CAPTURED",frames.count,frames.prefix(5).map { ["key":$0["key"]!,"width":$0["width"]!,"height":$0["height"]!] })
    }
}
private final class Factory: LKRTCDefaultVideoDecoderFactory {
    let capture = Capture()
    override func createDecoder(_ codec: LKRTCVideoCodecInfo) -> (any LKRTCVideoDecoder)? { codec.name == "VP9" ? capture : super.createDecoder(codec) }
}
@main struct LayeredCapture {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        _ = LKRTCInitializeSSL()
        let decoderFactory = Factory()
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: decoderFactory, audioDevice: SyntheticAudio())
        let sender = MediaPeer(target:"PUBLISHER",ice:[],factory:factory), receiver = MediaPeer(target:"SUBSCRIBER",ice:[],factory:factory)
        sender.sendCandidate = { value in Task { try? await receiver.candidate(value) } }
        receiver.sendCandidate = { value in Task { try? await sender.candidate(value) } }
        defer { sender.close(); receiver.close() }
        try await sender.acceptAnswer(receiver.answer(sender.publishPattern(sharing: true, codecPolicy: .vp9Only, scalabilityMode: "L3T3_KEY", width: 1280, height: 720)))
        try await Task.sleep(nanoseconds: 4_000_000_000)
        await sender.stats()
        try decoderFactory.capture.save(CommandLine.arguments[1])
    }
}
