import Foundation
import LiveKitWebRTC

private final class SDKStyleDecoderFactory: LKRTCDefaultVideoDecoderFactory {}

@main struct CodecFactoryCheck {
    static func main() throws {
        let factory = SDKStyleDecoderFactory(), codec = LKRTCVideoCodecInfo(name: "VP9", parameters: ["profile-id": "0"])
        let otherProfile = LKRTCVideoCodecInfo(name: "VP9", parameters: ["profile-id": "2"])
        let codecs = factory.supportedCodecs().map { ($0.name, $0.parameters as NSDictionary) }
        func decoderType(_ info: LKRTCVideoCodecInfo) -> String? { factory.createDecoder(info).map { String(reflecting: type(of: $0)) } }
        let software = decoderType(codec), other = decoderType(otherProfile)
        var enabled = true, failures = 0
        precondition(DecoderFactoryOverride.install(LKRTCDefaultVideoDecoderFactory.self) { info in
            guard enabled, let info = info as? LKRTCVideoCodecInfo, info.name == "VP9", (info.parameters["profile-id"] ?? "0") == "0" else { return nil }
            return VP9HardwareDecoder { enabled = false; failures += 1 }
        })
        precondition(decoderType(otherProfile) == other)
        precondition(factory.supportedCodecs().enumerated().allSatisfy { i, value in value.name == codecs[i].0 && value.parameters as NSDictionary == codecs[i].1 })
        let decoder = factory.createDecoder(codec) as! VP9HardwareDecoder
        _ = decoder.startDecode(withNumberOfCores: 2)
        let fixtures = try JSONDecoder().decode([VP9Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        var expected = "", frames = 0, timestamp: UInt32 = UInt32.max - 3000
        decoder.setCallback { frame in
            precondition(VP9Fixture.digest(frame) == expected)
            precondition(frame.timeStamp == Int32(bitPattern: timestamp))
            frames += 1
        }
        for fixture in fixtures {
            for frame in fixture.frames {
                expected = frame.sha256
                precondition(decoder.decode(frame.image(timestamp: timestamp), missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0) == 0)
                timestamp &+= 6000
            }
        }
        let corrupt = fixtures[0].frames[0].image(timestamp: timestamp)
        corrupt.frameType = .videoFrameDelta; corrupt.buffer = Data(repeating: 255, count: 80)
        precondition(decoder.decode(corrupt, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0) == -1)
        precondition(failures == 1 && decoderType(codec) == software)
        precondition(decoder.decode(corrupt, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0) == -1 && failures == 1)
        _ = decoder.release()
        enabled = true
        precondition(factory.createDecoder(codec) is VP9HardwareDecoder)
        precondition(frames == 16)
        print("PUBLIC_FACTORY_OVERRIDE_VERIFIED frames=16 pixels=exact profiles=preserved softwareFallback=once restart=hardware")
    }
}
