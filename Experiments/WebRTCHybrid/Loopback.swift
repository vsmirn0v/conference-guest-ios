import Foundation
import LiveKitWebRTC

private final class HybridFactory: LKRTCDefaultVideoDecoderFactory {
    private let lock = NSLock()
    private var hardware: [VP9HardwareDecoder] = []
    private var creations = 0
    private let useAppFactory: Bool
    private let app = NativeVideoDecoderFactory()
    init(useAppFactory: Bool) { self.useAppFactory = useAppFactory; super.init() }
    var instances: Int { lock.lock(); defer { lock.unlock() }; return creations }
    var evidence: [[String: Any]] {
        if useAppFactory { return NativeVideoDecoderFactory.evidenceForTesting }
        lock.lock(); let decoders = hardware; lock.unlock()
        return decoders.map(\.evidenceForTesting)
    }
    override func createDecoder(_ codec: LKRTCVideoCodecInfo) -> (any LKRTCVideoDecoder)? {
        guard codec.name == "VP9", (codec.parameters["profile-id"] ?? "0") == "0" else { return super.createDecoder(codec) }
        lock.lock(); creations += 1; lock.unlock()
        if useAppFactory { return app.createDecoder(codec) }
        let decoder = VP9HardwareDecoder()
        lock.lock(); hardware.append(decoder); lock.unlock()
        return LKRTCVideoDecoderVP9.vp9Decoder(hardwareDecoder: decoder)
    }
    func forceFailure() {
        if useAppFactory { NativeVideoDecoderFactory.failForTesting(); return }
        lock.lock(); let decoders = hardware; lock.unlock(); decoders.forEach { $0.failForTesting() }
    }
}

struct HybridLoopback {
    @MainActor static func run() async throws {
        _ = LKRTCInitializeSSL()
        guard VP9HardwareDecoder.available, NativeVP9Hybrid.available else { throw ProbeError.expectedMediaMissing }
        for (mode, useAppFactory) in [("L1T3", false), ("L3T3_KEY", false), ("L1T3", true), ("L3T3_KEY", true)] {
            let decoders = HybridFactory(useAppFactory: useAppFactory)
            let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: decoders, audioDevice: SyntheticAudio())
            let sender = MediaPeer(target: "PUBLISHER", ice: [], factory: factory)
            let receiver = MediaPeer(target: "SUBSCRIBER", ice: [], factory: factory)
            precondition(sender.connection.setBweMinBitrateBps(2_000_000, currentBitrateBps: 3_000_000, maxBitrateBps: 5_000_000))
            sender.sendCandidate = { value in Task { try? await receiver.candidate(value) } }
            receiver.sendCandidate = { value in Task { try? await sender.candidate(value) } }
            defer { sender.close(); receiver.close() }
            try await sender.acceptAnswer(receiver.answer(sender.publishPattern(sharing: true, codecPolicy: .vp9Only, scalabilityMode: mode, width: 1280, height: 720)))
            try await Task.sleep(nanoseconds: 5_000_000_000)
            let frames = receiver.receivedFrames, size = receiver.receivedDimensions
            await sender.stats(); await receiver.stats()
            probeLog("hybrid-before-assertions", ["mode": mode, "frames": frames, "width": size.0, "height": size.1, "instances": decoders.instances, "hardware": decoders.evidence])
            precondition(frames >= 15 && size == (1280, 720))
            precondition(decoders.instances == 1, "Fallback must preserve the receive stream")
            if mode == "L1T3" {
                precondition(decoders.evidence.contains { ($0["hardwareFrames"] as? Int ?? 0) >= 15 && $0["verifiedHardwareSession"] as? Bool == true })
                decoders.forceFailure()
                try await Task.sleep(nanoseconds: 5_000_000_000)
                precondition(receiver.receivedFrames >= frames + 15 && decoders.instances == 1)
            } else if !useAppFactory {
                precondition(decoders.evidence.allSatisfy { ($0["hardwareFrames"] as? Int ?? 0) == 0 })
            }
            await sender.stats(); await receiver.stats()
            precondition(NativeVideoDecoderPolicy.shared.snapshot.enabled)
            probeLog("native-hybrid-verified", ["mode": mode, "appFactory": useAppFactory, "frames": receiver.receivedFrames, "width": size.0, "height": size.1, "instances": decoders.instances, "hardware": decoders.evidence])
        }
    }
}
