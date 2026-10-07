import Foundation
import Combine
import ObjectiveC
import WebRTC

/// Observe the pinned SDK's bundled public WebRTC factory/stats surface.
/// Forward every creation unchanged; never replace its audio device or touch mute.
private enum GuestPeerRegistry {
    private static let lock = NSLock()
    private static let peers = NSHashTable<RTCPeerConnection>.weakObjects()
    static func prepare() { _ = installed }
    private static let installed: Bool = {
        let selector = #selector(RTCPeerConnectionFactory.peerConnection(with:constraints:delegate:))
        guard let method = class_getInstanceMethod(RTCPeerConnectionFactory.self, selector) else { return false }
        typealias Create = @convention(c) (AnyObject, Selector, RTCConfiguration, RTCMediaConstraints, AnyObject?) -> RTCPeerConnection?
        let original = unsafeBitCast(method_getImplementation(method), to: Create.self)
        let forward: @convention(block) (AnyObject, RTCConfiguration, RTCMediaConstraints, AnyObject?) -> RTCPeerConnection? = { factory, configuration, constraints, delegate in
            let peer = original(factory, selector, configuration, constraints, delegate)
            if let peer { lock.lock(); peers.add(peer); lock.unlock() }
            return peer
        }
        method_setImplementation(method, imp_implementationWithBlock(forward))
        let verifiedSelector = #selector(RTCPeerConnectionFactory.peerConnection(with:constraints:certificateVerifier:delegate:))
        if let verifiedMethod = class_getInstanceMethod(RTCPeerConnectionFactory.self, verifiedSelector) {
            typealias VerifiedCreate = @convention(c) (AnyObject, Selector, RTCConfiguration, RTCMediaConstraints, AnyObject, AnyObject?) -> RTCPeerConnection?
            let verifiedOriginal = unsafeBitCast(method_getImplementation(verifiedMethod), to: VerifiedCreate.self)
            let verifiedForward: @convention(block) (AnyObject, RTCConfiguration, RTCMediaConstraints, AnyObject, AnyObject?) -> RTCPeerConnection? = { factory, configuration, constraints, verifier, delegate in
                let peer = verifiedOriginal(factory, verifiedSelector, configuration, constraints, verifier, delegate)
                if let peer { lock.lock(); peers.add(peer); lock.unlock() }
                return peer
            }
            method_setImplementation(verifiedMethod, imp_implementationWithBlock(verifiedForward))
        }
        return true
    }()
    static func snapshot() -> [RTCPeerConnection] {
        lock.lock(); defer { lock.unlock() }; return peers.allObjects
    }
}

@MainActor
final class GuestMicrophoneProbe {
    private var task: Task<Void, Never>?
    private var observation: AnyCancellable?
    private weak var observedActivity: MicrophoneActivity?
    static func prepare() { GuestPeerRegistry.prepare() }
    func update(activity: MicrophoneActivity) {
        if observedActivity !== activity {
            observation = nil; stop(); observedActivity = activity
            observation = activity.$samplingNeeded.removeDuplicates().sink { [weak self, weak activity] needed in
                guard let self, let activity else { return }
                // Published emits before assignment; consume the emitted demand.
                if needed { self.start(activity: activity) } else { self.stop() }
            }
        }
    }
    private func start(activity: MicrophoneActivity) {
        guard task == nil else { return }
        task = Task { [weak self, weak activity] in
            while !Task.isCancelled {
                guard self != nil, let activity, activity.samplingNeeded else { return }
                let peers = GuestPeerRegistry.snapshot()
                for peer in peers where peer.connectionState == .connected {
                    guard let sender = peer.senders.first(where: { $0.track?.kind == "audio" && $0.track?.isEnabled == true }) else { continue }
                    let report: RTCStatisticsReport = await withCheckedContinuation { continuation in
                        peer.statistics(for: sender) { continuation.resume(returning: $0) }
                    }
                    guard !Task.isCancelled, activity.samplingNeeded else { return }
                    let levels = report.statistics.values.compactMap { item -> Float? in
                        guard item.type == "media-source", item.values["kind"] as? String == "audio" else { return nil }
                        return (item.values["audioLevel"] as? NSNumber)?.floatValue
                    }
                    if let rms = levels.max() { activity.receive(rms: rms) }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
