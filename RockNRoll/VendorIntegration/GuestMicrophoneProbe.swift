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
    enum PublicationState { case retired, paused, publishing }
    static func publicationState(trackID: String) -> PublicationState {
        for peer in GuestPeerRegistry.snapshot() where peer.connectionState != .closed {
            if let sender = peer.senders.first(where: { $0.track?.trackId == trackID }) {
                return peer.connectionState == .connected && sender.track?.isEnabled == true &&
                    sender.parameters.encodings.contains { $0.isActive } ? .publishing : .paused
            }
        }
        return .retired
    }
    /// A bounded publication watchdog, independent of the microphone meter.
    /// Nil means the track has stopped, so it must not trigger recovery.
    static func publicationWorks(trackID: String) async -> Bool? {
        for peer in GuestPeerRegistry.snapshot() where peer.connectionState == .connected {
            guard let sender = peer.senders.first(where: { $0.track?.trackId == trackID && $0.track?.isEnabled == true }) else { continue }
            guard sender.parameters.encodings.contains(where: { $0.isActive }) else { return nil }
            let report: RTCStatisticsReport = await withCheckedContinuation { completion in
                peer.statistics(for: sender) { completion.resume(returning: $0) }
            }
            guard peer.connectionState == .connected, sender.track?.trackId == trackID, sender.track?.isEnabled == true,
                  sender.parameters.encodings.contains(where: { $0.isActive }) else { return nil }
            return report.statistics.values.contains {
                $0.type == "outbound-rtp" && (($0.values["framesEncoded"] as? NSNumber)?.intValue ?? 0) > 0
            }
        }
        return nil
    }
    static func publicationProgress(trackID: String) async -> VideoPublicationHealth.Sample? {
        for peer in GuestPeerRegistry.snapshot() where peer.connectionState == .connected {
            guard let sender = peer.senders.first(where: { $0.track?.trackId == trackID && $0.track?.isEnabled == true }),
                  sender.parameters.encodings.contains(where: { $0.isActive }) else { continue }
            let report: RTCStatisticsReport = await withCheckedContinuation { completion in
                peer.statistics { completion.resume(returning: $0) }
            }
            guard peer.connectionState == .connected, sender.track?.trackId == trackID,
                  sender.track?.isEnabled == true, sender.parameters.encodings.contains(where: { $0.isActive }),
                  let mid = peer.transceivers.first(where: { $0.sender.senderId == sender.senderId })?.mid else { return nil }
            let activeRIDs = Set(sender.parameters.encodings.filter(\.isActive).compactMap(\.rid))
            let outbound = report.statistics.values.filter {
                $0.type == "outbound-rtp" && $0.values["mid"] as? String == mid && $0.values["kind"] as? String == "video" &&
                $0.values["framesEncoded"] is NSNumber &&
                (($0.values["rid"] as? String).map { activeRIDs.contains($0) } ?? true)
            }
            let sources = Set(outbound.compactMap { $0.values["mediaSourceId"] as? String })
            guard !outbound.isEmpty, sources.count == 1, let sourceID = sources.first else { return nil }
            // Raw camera progress continues if a stuck encoder retains every
            // native pool buffer; downstream media-source frames then stop.
            let raw = GuestCaptureDeviceObserver.rawCaptureProgress(trackID: trackID)
            guard let captured = raw?.frames ?? (report.statistics[sourceID]?.values["frames"] as? NSNumber)?.int64Value else { return nil }
            let input = raw.map { "raw-\($0.generation)" } ?? "media-source"
            return .init(stream: outbound.map(\.id).sorted().joined(separator: ",") + "/" + input, captured: captured,
                         encoded: outbound.reduce(0) { $0 + (($1.values["framesEncoded"] as? NSNumber)?.int64Value ?? 0) },
                         bandwidthLimited: outbound.contains { $0.values["qualityLimitationReason"] as? String == "bandwidth" })
        }
        return nil
    }
    #if DEBUG
    /// One-shot qualification only: never poll codec diagnostics in a release.
    static func codecEvidenceForTesting() async -> [[String: Any]] {
        var evidence: [[String: Any]] = []
        for peer in GuestPeerRegistry.snapshot() where peer.connectionState == .connected {
            let report: RTCStatisticsReport = await withCheckedContinuation { completion in
                peer.statistics { completion.resume(returning: $0) }
            }
            for entry in report.statistics.values where ["inbound-rtp", "outbound-rtp"].contains(entry.type) {
                var row: [String: Any] = ["id": entry.id, "type": entry.type]
                let sender = (entry.values["mid"] as? String).flatMap { mid in peer.transceivers.first { $0.mid == mid }?.sender }
                if entry.type == "outbound-rtp", let sender {
                    row["negotiatedCodecs"] = sender.parameters.codecs.map { ["name": $0.name, "parameters": $0.parameters] }
                }
                let keys = ["kind", "mid", "framesEncoded", "framesDecoded", "frameWidth", "frameHeight", "framesPerSecond", "totalEncodeTime", "totalDecodeTime", "encoderImplementation", "decoderImplementation", "powerEfficientEncoder", "powerEfficientDecoder", "bytesSent", "bytesReceived", "totalAudioEnergy"]
                for key in keys { row[key] = entry.values[key] }
                if let codecID = entry.values["codecId"] as? String, let codec = report.statistics[codecID] {
                    row["mimeType"] = codec.values["mimeType"]; row["sdpFmtpLine"] = codec.values["sdpFmtpLine"]
                }
                evidence.append(row)
            }
        }
        return evidence
    }
    #endif
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
