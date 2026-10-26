import Foundation
import Combine
import ObjectiveC
import WebRTC
import Darwin

/// Observe the pinned SDK's bundled public WebRTC factory/stats surface.
/// Forward every creation unchanged; never replace its audio device or touch mute.
enum GuestPeerRegistry {
    struct Scope: Equatable, Sendable { let generation: UUID; let attempt: UUID }
    private final class ScopeBox {
        let value: Scope
        init(_ value: Scope) { self.value = value }
    }
    private static let lock = NSLock()
    private static let peers = NSHashTable<RTCPeerConnection>.weakObjects()
    private static let scopes = NSMapTable<RTCPeerConnection, ScopeBox>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private static var currentScope: Scope?
    static func prepare() { _ = installed }
    static func beginScope(_ scope: Scope) {
        prepare()
        lock.lock(); currentScope = scope; lock.unlock()
    }
    static func endScope(_ scope: Scope) {
        lock.lock(); defer { lock.unlock() }
        if currentScope == scope { currentScope = nil }
    }
    private static func scopeAtCreation() -> Scope? {
        lock.lock(); defer { lock.unlock() }; return currentScope
    }
    private static func record(_ peer: RTCPeerConnection, scope: Scope?) {
        lock.lock(); defer { lock.unlock() }
        peers.add(peer)
        if let scope { scopes.setObject(ScopeBox(scope), forKey: peer) }
    }
    private static let installed: Bool = {
        let selector = #selector(RTCPeerConnectionFactory.peerConnection(with:constraints:delegate:))
        guard let method = class_getInstanceMethod(RTCPeerConnectionFactory.self, selector) else { return false }
        typealias Create = @convention(c) (AnyObject, Selector, RTCConfiguration, RTCMediaConstraints, AnyObject?) -> RTCPeerConnection?
        let original = unsafeBitCast(method_getImplementation(method), to: Create.self)
        let forward: @convention(block) (AnyObject, RTCConfiguration, RTCMediaConstraints, AnyObject?) -> RTCPeerConnection? = { factory, configuration, constraints, delegate in
            let scope = scopeAtCreation()
            let peer = original(factory, selector, configuration, constraints, delegate)
            if let peer { record(peer, scope: scope) }
            return peer
        }
        method_setImplementation(method, imp_implementationWithBlock(forward))
        let verifiedSelector = #selector(RTCPeerConnectionFactory.peerConnection(with:constraints:certificateVerifier:delegate:))
        if let verifiedMethod = class_getInstanceMethod(RTCPeerConnectionFactory.self, verifiedSelector) {
            typealias VerifiedCreate = @convention(c) (AnyObject, Selector, RTCConfiguration, RTCMediaConstraints, AnyObject, AnyObject?) -> RTCPeerConnection?
            let verifiedOriginal = unsafeBitCast(method_getImplementation(verifiedMethod), to: VerifiedCreate.self)
            let verifiedForward: @convention(block) (AnyObject, RTCConfiguration, RTCMediaConstraints, AnyObject, AnyObject?) -> RTCPeerConnection? = { factory, configuration, constraints, verifier, delegate in
                let scope = scopeAtCreation()
                let peer = verifiedOriginal(factory, verifiedSelector, configuration, constraints, verifier, delegate)
                if let peer { record(peer, scope: scope) }
                return peer
            }
            method_setImplementation(verifiedMethod, imp_implementationWithBlock(verifiedForward))
        }
        return true
    }()
    static func snapshot() -> [RTCPeerConnection] {
        lock.lock(); defer { lock.unlock() }; return peers.allObjects
    }
    @MainActor static func receiverCandidates() -> [GuestPresenterCameraReceiver.Candidate] {
        lock.lock()
        let scoped = peers.allObjects.map { ($0, scopes.object(forKey: $0)?.value) }
        lock.unlock()
        return scoped.flatMap { peer, scope -> [GuestPresenterCameraReceiver.Candidate] in
            peer.transceivers.compactMap { transceiver -> GuestPresenterCameraReceiver.Candidate? in
                guard let track = transceiver.receiver.track as? RTCVideoTrack else { return nil }
                var direction: RTCRtpTransceiverDirection = .inactive
                let hasDirection = transceiver.currentDirection(&direction)
                return GuestPresenterCameraReceiver.Candidate(scope: scope, closed: peer.connectionState == .closed,
                    stopped: transceiver.isStopped, direction: hasDirection ? direction : nil, track: track)
            }
        }
    }
}

@MainActor
final class GuestMicrophoneProbe {
    private var task: Task<Void, Never>?
    private var observation: AnyCancellable?
    private weak var observedActivity: MicrophoneActivity?
    static func prepare() { GuestPeerRegistry.prepare() }
    static func cameraUplink(source: RTCVideoSource) async -> CameraUplinkSample? {
        for peer in GuestPeerRegistry.snapshot() where peer.connectionState == .connected {
            guard let sender = peer.senders.first(where: {
                $0.track?.kind == "video" && $0.track?.isEnabled == true &&
                    $0.track.map { GuestCameraTrackBinding.source(source, owns: $0.trackId) } == true
            }),
            let trackID = sender.track?.trackId,
            let mid = peer.transceivers.first(where: { $0.sender.senderId == sender.senderId })?.mid else { continue }
            let report: RTCStatisticsReport = await withCheckedContinuation { completion in
                peer.statistics { completion.resume(returning: $0) }
            }
            guard peer.connectionState == .connected, sender.track?.isEnabled == true, sender.track?.trackId == trackID,
                  GuestCameraTrackBinding.source(source, owns: trackID),
                  peer.transceivers.first(where: { $0.mid == mid })?.sender.senderId == sender.senderId else { return nil }
            let records: [CameraUplinkStatistics.Record] = report.statistics.values.map {
                .init(id: $0.id, type: $0.type, timestamp: $0.timestamp_us, values: $0.values)
            }
            guard GuestPublicationStatistics.activeVideo(records, mid: mid) != nil else { return nil }
            #if DEBUG
            CameraBackgroundTrace.outgoing(records: records, cameraMID: mid)
            #endif
            return CameraUplinkStatistics.sample(records: records, cameraMID: mid)
        }
        return nil
    }
    enum PublicationState { case retired, paused, publishing }
    static func publicationState(trackID: String) -> PublicationState {
        for peer in GuestPeerRegistry.snapshot() where peer.connectionState != .closed {
            if let sender = peer.senders.first(where: { $0.track?.trackId == trackID }) {
                // This only admits a bound/enabled track for a stats probe.
                // Works/progress below additionally require active RTP evidence.
                return peer.connectionState == .connected && sender.track?.isEnabled == true ? .publishing : .paused
            }
        }
        return .retired
    }
    /// A bounded publication watchdog, independent of the microphone meter.
    /// Nil means the track has stopped, so it must not trigger recovery.
    static func publicationStartupSample(trackID: String) async -> VideoPublicationStartup.Sample? {
        for peer in GuestPeerRegistry.snapshot() where peer.connectionState == .connected {
            guard let sender = peer.senders.first(where: { $0.track?.trackId == trackID && $0.track?.isEnabled == true }),
                  let mid = peer.transceivers.first(where: { $0.sender.senderId == sender.senderId })?.mid else { continue }
            let report: RTCStatisticsReport = await withCheckedContinuation { completion in
                peer.statistics(for: sender) { completion.resume(returning: $0) }
            }
            guard peer.connectionState == .connected, sender.track?.trackId == trackID, sender.track?.isEnabled == true,
                  peer.transceivers.first(where: { $0.mid == mid })?.sender.senderId == sender.senderId else { return nil }
            let records = report.statistics.values.map {
                CameraUplinkStatistics.Record(id: $0.id, type: $0.type, timestamp: $0.timestamp_us, values: $0.values)
            }
            guard let active = GuestPublicationStatistics.activeVideo(records, mid: mid) else { return nil }
            guard let encoded = GuestPublicationStatistics.encodedFrames(active) else { return nil }
            let stream = "\(ObjectIdentifier(peer))/\(sender.senderId)/\(mid)/" + active.map(\.id).sorted().joined(separator: ",")
            return .init(stream: stream, encoded: encoded,
                         bandwidthLimited: active.contains { $0.values["qualityLimitationReason"] as? String == "bandwidth" })
        }
        return nil
    }
    static func publicationProgress(trackID: String) async -> VideoPublicationHealth.Sample? {
        for peer in GuestPeerRegistry.snapshot() where peer.connectionState == .connected {
            guard let sender = peer.senders.first(where: { $0.track?.trackId == trackID && $0.track?.isEnabled == true }),
                  let mid = peer.transceivers.first(where: { $0.sender.senderId == sender.senderId })?.mid else { continue }
            let report: RTCStatisticsReport = await withCheckedContinuation { completion in
                peer.statistics { completion.resume(returning: $0) }
            }
            guard peer.connectionState == .connected, sender.track?.trackId == trackID,
                  sender.track?.isEnabled == true,
                  peer.transceivers.first(where: { $0.mid == mid })?.sender.senderId == sender.senderId else { return nil }
            let records = report.statistics.values.map {
                CameraUplinkStatistics.Record(id: $0.id, type: $0.type, timestamp: $0.timestamp_us, values: $0.values)
            }
            guard let outbound = GuestPublicationStatistics.activeVideo(records, mid: mid),
                  let encoded = GuestPublicationStatistics.encodedFrames(outbound) else { return nil }
            // A CID-bound raw camera counter is independent of optional RTP stats links.
            // Non-camera sources still require one unambiguous media source.
            let raw = GuestCaptureDeviceObserver.rawCaptureProgress(trackID: trackID)
            let captured: Int64
            if let raw { captured = raw.frames }
            else {
                let sources = Set(outbound.compactMap { $0.values["mediaSourceId"] as? String })
                guard sources.count == 1, let sourceID = sources.first,
                      let frames = (report.statistics[sourceID]?.values["frames"] as? NSNumber)?.int64Value else { return nil }
                captured = frames
            }
            let input = raw.map { "raw-\($0.generation)" } ?? "media-source"
            return .init(stream: outbound.map(\.id).sorted().joined(separator: ",") + "/" + input, captured: captured,
                         encoded: encoded,
                         bandwidthLimited: outbound.contains { $0.values["qualityLimitationReason"] as? String == "bandwidth" })
        }
        return nil
    }
    #if DEBUG
    static func receiveDelayRecords() async -> [ReceiveDelayStatistics.Record] {
        var records: [ReceiveDelayStatistics.Record] = []
        for peer in GuestPeerRegistry.snapshot() where peer.connectionState == .connected {
            let report: RTCStatisticsReport = await withCheckedContinuation { completion in
                peer.statistics { completion.resume(returning: $0) }
            }
            guard peer.connectionState == .connected else { continue }
            let prefix = String(ObjectIdentifier(peer).hashValue) + "/"
            records += report.statistics.values.filter { $0.type == "inbound-rtp" }.compactMap {
                ReceiveDelayStatistics.record(id: prefix + $0.id, time: $0.timestamp_us / 1_000_000, values: $0.values)
            }
        }
        return records
    }
    static func constrainScreenForTesting(bitsPerSecond: Int) -> Bool {
        let identities = GuestScreenSharePolicy.shared.trackIDsForTesting
        guard identities.count == 1, bitsPerSecond >= 100_000 else { return false }
        for peer in GuestPeerRegistry.snapshot() where peer.connectionState == .connected {
            guard let sender = peer.senders.first(where: { $0.track.map { identities.contains($0.trackId) } == true }) else { continue }
            let parameters = sender.parameters
            guard parameters.encodings.count == 1 else { return false }
            parameters.encodings[0].minBitrateBps = 100_000
            parameters.encodings[0].maxBitrateBps = NSNumber(value: bitsPerSecond)
            sender.parameters = parameters
            return sender.parameters.encodings.first?.maxBitrateBps?.intValue == bitsPerSecond
        }
        return false
    }
    /// One-shot qualification only: never poll codec diagnostics in a release.
    static func codecEvidenceForTesting() async -> [[String: Any]] {
        var evidence: [[String: Any]] = []
        for peer in GuestPeerRegistry.snapshot() where peer.connectionState == .connected {
            let report: RTCStatisticsReport = await withCheckedContinuation { completion in
                peer.statistics { completion.resume(returning: $0) }
            }
            for entry in report.statistics.values where ["inbound-rtp", "outbound-rtp", "media-source"].contains(entry.type) {
                var row: [String: Any] = ["id": entry.id, "type": entry.type]
                let sender = (entry.values["mid"] as? String).flatMap { mid in peer.transceivers.first { $0.mid == mid }?.sender }
                if entry.type == "outbound-rtp", let sender {
                    row["rawCamera"] = sender.track.map { GuestCaptureDeviceObserver.rawCaptureProgress(trackID: $0.trackId) != nil }
                    row["degradationPreference"] = sender.parameters.degradationPreference
                    row["encodingLimits"] = sender.parameters.encodings.map { ["maxBitrate": $0.maxBitrateBps ?? 0, "maxFramerate": $0.maxFramerate ?? 0, "scaleDown": $0.scaleResolutionDownBy ?? 1] }
                    row["negotiatedCodecs"] = sender.parameters.codecs.map { ["name": $0.name, "parameters": $0.parameters] }
                }
                let keys = ["kind", "mid", "framesEncoded", "framesDecoded", "frameWidth", "frameHeight", "framesPerSecond", "totalEncodeTime", "totalDecodeTime", "encoderImplementation", "decoderImplementation", "powerEfficientEncoder", "powerEfficientDecoder", "bytesSent", "bytesReceived", "totalAudioEnergy", "rid", "mediaSourceId", "qualityLimitationReason", "qpSum", "totalEncodedBytesTarget", "qualityLimitationDurations", "targetBitrate", "packetsSent", "totalSamplesDuration", "audioLevel", "packetsReceived", "packetsLost", "jitter", "concealedSamples", "totalSamplesReceived", "jitterBufferDelay", "jitterBufferEmittedCount"]
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

#if DEBUG
/// Observe public audio-device callbacks without changing SDK audio ownership.
/// A worker heartbeat distinguishes whole-process suspension from a busy UI.
final class GuestAudioIOTrace: NSObject, RTCAudioSessionDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.vsmirn0v.guest-audio-trace", qos: .utility)
    private var timer: DispatchSourceTimer?
    func start() {
        guard ProcessInfo.processInfo.environment["CONFERENCE_TEST_MEDIA_TRACE"] == "1" else { return }
        queue.async {
            guard self.timer == nil else { return }
            RTCAudioSession.sharedInstance().add(self)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .seconds(5))
            timer.setEventHandler { [weak self] in self?.write("heartbeat") }
            self.timer = timer; timer.resume()
        }
    }
    func stop() {
        queue.async {
            self.timer?.cancel(); self.timer = nil
            RTCAudioSession.sharedInstance().remove(self)
        }
    }
    private func record(_ event: String) { queue.async { if self.timer != nil { self.write(event) } } }
    private func write(_ event: String) {
        let rtc = RTCAudioSession.sharedInstance()
        let row: [String: Any] = ["time": Date().timeIntervalSince1970, "event": event,
            "active": rtc.isActive, "manual": rtc.useManualAudio, "enabled": rtc.isAudioEnabled,
            "mode": rtc.mode, "options": rtc.categoryOptions.rawValue,
            "configurationOptions": RTCAudioSessionConfiguration.webRTC().categoryOptions.rawValue,
            "otherAudioPlaying": AVAudioSession.sharedInstance().isOtherAudioPlaying,
            "outputs": rtc.currentRoute.outputs.map { $0.portType.rawValue }]
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              var line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        let file = directory.appendingPathComponent("guest-audio-io.jsonl")
        var data = (try? Data(contentsOf: file)) ?? Data()
        if data.count > 131_072 { data.removeAll(keepingCapacity: true) }
        line.append(10); data.append(line); try? data.write(to: file, options: .atomic)
    }
    func audioSessionDidStartPlayOrRecord(_ session: RTCAudioSession) { record("io-start") }
    func audioSessionDidStopPlayOrRecord(_ session: RTCAudioSession) { record("io-stop") }
    func audioSession(_ session: RTCAudioSession, didChangeCanPlayOrRecord value: Bool) { record("permission-\(value)") }
    func audioSession(_ session: RTCAudioSession, didSetActive active: Bool) { record("active-\(active)") }
}
#endif

/// Controls only the rebuilt SDK's real conference output device. The stock
/// binary has no extension and retains its original audio behavior.
final class GuestConferencePlayoutReservation: @unchecked Sendable {
    private static let lock = NSLock()
    private static var owner: UUID?
    private let token = UUID()
    private let write: ((Bool) -> Void)?
    private var reserved = false
    static var isSupported: Bool { nativeWriter != nil }
    private static let nativeWriter: (@convention(c) (Int32) -> Void)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "RTCSetConferencePlayoutReserved") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Void).self)
    }()
    init(write: ((Bool) -> Void)? = nil) {
        var selected = write ?? (ProcessInfo.processInfo.isiOSAppOnMac ? nil : Self.nativeWriter.map { api in { api($0 ? 1 : 0) } })
        #if DEBUG
        // Matched quiet-background energy control, never available in Release.
        if write == nil, ProcessInfo.processInfo.environment["CONFERENCE_TEST_DISABLE_OUTPUT_RESERVATION"] == "1" { selected = nil }
        #endif
        self.write = selected
        #if DEBUG
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_MEDIA_TRACE"] == "1" {
            print("Guest conference output supported=\(Self.isSupported) enabled=\(self.write != nil) mac=\(ProcessInfo.processInfo.isiOSAppOnMac)")
        }
        #endif
    }
    /// Keep the interrupted device registered so iOS can deliver its resume
    /// event. The native ADM pauses the unit itself; never start it during hold.
    func update(joined: Bool, audioAvailable: Bool, refresh: Bool = false) {
        if !joined { setReserved(false) }
        else if audioAvailable { setReserved(true, refresh: refresh) }
    }
    func setReserved(_ value: Bool, refresh: Bool = false) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let write else { return }
        if value {
            guard refresh || !reserved || Self.owner != token else { return }
            reserved = true; Self.owner = token; write(true)
        } else {
            reserved = false
            guard Self.owner == token else { return }
            Self.owner = nil; write(false)
        }
    }
    deinit { setReserved(false) }
}
