import Foundation
import LiveKitWebRTC

@main struct VP9HardwareCheck {
    static func main() throws {
        let factory = NativeVideoDecoderFactory()
        precondition(factory.createDecoder(LKRTCVideoCodecInfo(name: "VP9", parameters: ["profile-id": "0"])) is VP9HardwareDecoder)
        precondition(!(factory.createDecoder(LKRTCVideoCodecInfo(name: "VP9", parameters: ["profile-id": "2"])) is VP9HardwareDecoder))
        print("VP9_FACTORY_VERIFIED")
        let fixtures = try JSONDecoder().decode([VP9Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        var failures = 0, delivered = 0, expected = "", timestamp: UInt32 = 90_000
        let decoder = VP9HardwareDecoder { failures += 1 }
        _ = decoder.startDecode(withNumberOfCores: 2)
        decoder.setCallback { frame in
            precondition(VP9Fixture.digest(frame) == expected, "Decoded pixels differ from independent software reference")
            precondition(frame.timeStamp == Int32(bitPattern: timestamp) && frame.rotation == ._90)
            delivered += 1
        }
        for fixture in fixtures {
            for frame in fixture.frames {
                expected = frame.sha256
                let status = decoder.decode(frame.image(timestamp: timestamp), missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0)
                print("decode",fixture.width,fixture.height,"key",frame.key,"status",status,decoder.evidenceForTesting)
                precondition(status == 0)
                timestamp &+= 6000
            }
        }
        precondition(delivered == fixtures.reduce(0) { $0 + $1.frames.count } && failures == 0)
        print("VP9_HARDWARE_VERIFIED",decoder.evidenceForTesting)
        _ = decoder.release()
        print("VP9_RELEASE",decoder.evidenceForTesting)
    }
}
