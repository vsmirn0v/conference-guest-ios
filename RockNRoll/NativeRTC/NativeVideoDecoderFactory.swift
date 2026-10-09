import Foundation
import LiveKitWebRTC

/// One active meeting owns the decoder preference. Failed hardware is avoided
/// throughout its reconnects; callbacks from retired meetings cannot change it.
final class NativeVideoDecoderPolicy: @unchecked Sendable {
    static let shared = NativeVideoDecoderPolicy()
    static let fallbackNotification = Notification.Name("NativeVideoDecoderFallback")
    private let lock = NSLock()
    private var generation = UUID()
    private var enabled = true

    @discardableResult func beginCall() -> UUID {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); enabled = true; return generation
    }
    var snapshot: (generation: UUID, enabled: Bool) {
        lock.lock(); defer { lock.unlock() }; return (generation, enabled)
    }
    func fallBack(generation: UUID) {
        lock.lock()
        let current = self.generation == generation && enabled
        if current { enabled = false }
        lock.unlock()
        if current { DispatchQueue.main.async { NotificationCenter.default.post(name: Self.fallbackNotification, object: self, userInfo: ["generation": generation]) } }
    }
}

final class NativeVideoDecoderFactory: NSObject, LKRTCVideoDecoderFactory {
    private let base = LKRTCDefaultVideoDecoderFactory()
    func supportedCodecs() -> [LKRTCVideoCodecInfo] { base.supportedCodecs() }
    func createDecoder(_ info: LKRTCVideoCodecInfo) -> (any LKRTCVideoDecoder)? {
        let policy = NativeVideoDecoderPolicy.shared.snapshot
        guard info.name == "VP9", (info.parameters["profile-id"] ?? "0") == "0",
              VP9HardwareDecoder.available else { return base.createDecoder(info) }
        let decoder: VP9HardwareDecoder
        let result: any LKRTCVideoDecoder
        if NativeVP9Hybrid.available {
            decoder = VP9HardwareDecoder()
            guard let hybrid = NativeVP9Hybrid.make(hardware: decoder) else { return base.createDecoder(info) }
            result = hybrid
        } else {
            guard policy.enabled else { return base.createDecoder(info) }
            decoder = VP9HardwareDecoder { NativeVideoDecoderPolicy.shared.fallBack(generation: policy.generation) }
            result = decoder
        }
        #if DEBUG
        Self.registryLock.lock()
        Self.decoders.removeAll { $0.value == nil }; Self.decoders.append(WeakDecoder(decoder))
        Self.registryLock.unlock()
        #endif
        return result
    }
    #if DEBUG
    private final class WeakDecoder {
        weak var value: VP9HardwareDecoder?
        init(_ value: VP9HardwareDecoder) { self.value = value }
    }
    private static let registryLock = NSLock()
    private static var decoders: [WeakDecoder] = []
    private static var liveDecoders: [VP9HardwareDecoder] {
        registryLock.lock(); defer { registryLock.unlock() }; return decoders.compactMap(\.value)
    }
    static var evidenceForTesting: [[String: Any]] { liveDecoders.map(\.evidenceForTesting) }
    static func failForTesting() { liveDecoders.forEach { $0.failForTesting() } }
    #endif
}
