import Foundation
import LiveKitWebRTC

private final class SDKStyleDecoderFactory: LKRTCDefaultVideoDecoderFactory {}
private final class DecoderEvidence {
    private let lock = NSLock()
    private var decoders: [VP9HardwareDecoder] = []
    func add(_ decoder: VP9HardwareDecoder) { lock.lock(); decoders.append(decoder); lock.unlock() }
    var values: [[String: Any]] { lock.lock(); let current = decoders; lock.unlock(); return current.map(\.evidenceForTesting) }
}

@main struct FactoryLoopback {
    @MainActor static func main() async {
        _ = LKRTCInitializeSSL()
        let evidence = DecoderEvidence()
        guard VP9HardwareDecoder.available, DecoderFactoryOverride.install(LKRTCDefaultVideoDecoderFactory.self, make: { info in
            guard let info = info as? LKRTCVideoCodecInfo, info.name == "VP9", (info.parameters["profile-id"] ?? "0") == "0" else { return nil }
            let decoder = VP9HardwareDecoder { probeLog("decoder-failed"); exit(1) }
            evidence.add(decoder); return decoder
        }) else { probeLog("hardware-or-public-factory-unavailable"); exit(1) }
        let audio = SyntheticAudio()
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: SDKStyleDecoderFactory(), audioDevice: audio)
        let sender = MediaPeer(target: "PUBLISHER", ice: [], factory: factory)
        let receiver = MediaPeer(target: "SUBSCRIBER", ice: [], factory: factory)
        sender.sendCandidate = { value in Task { try? await receiver.candidate(value) } }
        receiver.sendCandidate = { value in Task { try? await sender.candidate(value) } }
        defer { sender.close(); receiver.close() }
        do {
            try await sender.acceptAnswer(receiver.answer(sender.publishPattern(sharing: true, codecPolicy: .vp9Only)))
            try await Task.sleep(nanoseconds: 15_000_000_000)
            let encoded = await sender.stats(); await receiver.stats()
            let hardware = evidence.values
            guard encoded >= 10, receiver.receivedFrames >= 10,
                  hardware.contains(where: { ($0["hardwareFrames"] as? Int ?? 0) >= 10 && $0["verifiedHardwareSession"] as? Bool == true }) else {
                throw ProbeError.expectedMediaMissing
            }
            probeLog("public-factory-loopback-verified", ["encoded": encoded, "decoded": receiver.receivedFrames, "hardware": hardware])
        } catch { probeLog("loopback-failed", ["error": String(describing: error)]); exit(1) }
    }
}
