#if DEBUG
import Foundation
import LiveKitWebRTC
import WebRTC

/// Opt-in feasibility check of the SDKs' public Objective-C decoder factory
/// method. Unknown formats use the original implementation. Never in Release.
final class VideoDecoderFactoryExperiment {
    enum Scope { case guest, jam }
    static let shared = VideoDecoderFactoryExperiment()
    private let lock = NSLock()
    private var token: UUID?
    private var scope: Scope?
    private var disabled = false
    private var fallback: (() -> Void)?
    private let guestDecoders = NSHashTable<GuestVP9HardwareDecoder>.weakObjects()
    var guestEvidence: [[String: Any]] {
        lock.lock(); let values = guestDecoders.allObjects; lock.unlock()
        return values.map(\.evidenceForTesting)
    }
    func failGuestForTesting() {
        lock.lock(); let values = guestDecoders.allObjects; lock.unlock()
        values.forEach { $0.failForTesting() }
    }
    private static let installed: Bool = {
        DecoderFactoryOverride.install(RTCDefaultVideoDecoderFactory.self) { info in
            guard let info = info as? RTCVideoCodecInfo,
                  let token = shared.selection(scope: .guest, name: info.name, profile: info.parameters["profile-id"]) else { return nil }
            let decoder = GuestVP9HardwareDecoder { shared.fail(token: token) }
            shared.lock.lock()
            if shared.token == token { shared.guestDecoders.add(decoder) }
            shared.lock.unlock()
            return decoder
        } && DecoderFactoryOverride.install(LKRTCDefaultVideoDecoderFactory.self) { info in
            guard let info = info as? LKRTCVideoCodecInfo,
                  let token = shared.selection(scope: .jam, name: info.name, profile: info.parameters["profile-id"]) else { return nil }
            return VP9HardwareDecoder { shared.fail(token: token) }
        }
    }()
    @discardableResult
    func begin(scope: Scope, fallback: @escaping () -> Void) -> UUID? {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_EXPERIMENT_HARDWARE_VP9"] == "1",
              VideoToolboxVP9Session.available, Self.installed else { return nil }
        lock.lock(); defer { lock.unlock() }
        let next = UUID(); token = next; self.scope = scope; disabled = false; self.fallback = fallback
        guestDecoders.removeAllObjects()
        return next
    }
    func end(token: UUID?) {
        lock.lock(); defer { lock.unlock() }
        guard let token, self.token == token else { return }
        self.token = nil; scope = nil; fallback = nil; guestDecoders.removeAllObjects()
    }
    private func selection(scope: Scope, name: String, profile: String?) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard self.scope == scope, !disabled, name == "VP9", (profile ?? "0") == "0" else { return nil }
        return token
    }
    private func fail(token: UUID) {
        lock.lock()
        guard self.token == token, !disabled else { lock.unlock(); return }
        disabled = true; let fallback = self.fallback; lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let current = self.token == token; self.lock.unlock()
            if current { fallback?() }
        }
    }
}
#endif
