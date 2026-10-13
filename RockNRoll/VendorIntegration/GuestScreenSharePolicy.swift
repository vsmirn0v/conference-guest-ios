import Darwin
import Foundation
import ObjectiveC
import WebRTC

/// Screen tracks are identified by the joined publisher's typed signaling, not
/// dimensions, track names or the presence of a camera. Cameras remain unchanged.
final class GuestScreenSharePolicy: @unchecked Sendable {
    static let shared = GuestScreenSharePolicy(bindSenders: true)
    private let lock = NSLock()
    private var generation: UUID?
    private var tracks: Set<String> = []
    private let preserveResolution: Bool
    private let bindSenders: Bool
    private let bindingQueue = DispatchQueue(label: "dev.vsmirn0v.screen-detail-binding", qos: .utility)
    init(preserveResolution: Bool = true, bindSenders: Bool = false) {
        self.preserveResolution = preserveResolution; self.bindSenders = bindSenders
    }

    func begin(_ generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        self.generation = generation; tracks.removeAll()
    }
    func end(_ generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard self.generation == generation else { return }
        self.generation = nil; tracks.removeAll()
    }
    func register(_ trackID: String, generation: UUID) {
        guard !trackID.isEmpty, trackID.utf8.count <= 512 else { return }
        lock.lock()
        guard self.generation == generation, tracks.count < 128, tracks.insert(trackID).inserted else { lock.unlock(); return }
        lock.unlock()
        if bindSenders { bind(trackID, generation: generation, attempts: 10) }
    }
    private func bind(_ trackID: String, generation: UUID, attempts: Int) {
        // Signaling may identify the track before AddTrack, or after its first
        // parameter write. Apply once when the public sender becomes available;
        // subsequent SDK writes go through the setter below. Never poll forever.
        bindingQueue.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let current = self.generation == generation && self.tracks.contains(trackID); self.lock.unlock()
            guard current else { return }
            for peer in GuestPeerRegistry.snapshot() where peer.connectionState != .closed {
                guard let sender = peer.senders.first(where: { $0.track?.trackId == trackID && $0.track?.kind == "video" }) else { continue }
                let parameters = sender.parameters
                if self.apply(to: parameters, trackID: trackID) { sender.parameters = parameters }
                return
            }
            if attempts > 1 { self.bind(trackID, generation: generation, attempts: attempts - 1) }
        }
    }
    #if DEBUG
    var trackIDsForTesting: Set<String> { lock.lock(); defer { lock.unlock() }; return tracks }
    #endif
    @discardableResult
    func apply(to parameters: RTCRtpParameters, trackID: String) -> Bool {
        lock.lock(); let screen = generation != nil && tracks.contains(trackID); lock.unlock()
        guard screen, preserveResolution else { return false }
        // Keep codec, bitrate, active layers, priorities and transaction identity.
        // Congestion control can reduce update rate before discarding text pixels.
        let wanted = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
        guard parameters.degradationPreference != wanted else { return false }
        parameters.degradationPreference = wanted
        return true
    }
    static func prepare() { _ = installed }
    private static let installed: Bool = {
        let selector = NSSelectorFromString("setParameters:")
        guard let method = class_getInstanceMethod(RTCRtpSender.self, selector) else { return false }
        typealias Set = @convention(c) (RTCRtpSender, Selector, RTCRtpParameters) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Set.self)
        let forward: @convention(block) (RTCRtpSender, RTCRtpParameters) -> Void = { sender, parameters in
            if let track = sender.track, track.kind == "video" {
                _ = shared.apply(to: parameters, trackID: track.trackId)
            }
            original(sender, selector, parameters)
        }
        method_setImplementation(method, imp_implementationWithBlock(forward))
        return true
    }()
}

/// Only the rebuilt component exposes this public extension. An older binary
/// keeps its working hardware encoder; never inspect private session fields.
enum GuestScreenEncoderQuality {
    typealias Configure = @convention(c) (UnsafeMutableRawPointer, Int32, Int32) -> Int32
    private static let configure: Configure? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "RTCConfigureScreenShareEncoderQuality") else { return nil }
        return unsafeBitCast(symbol, to: Configure.self)
    }()
    static func apply(to encoder: any RTCVideoEncoder, mode: RTCVideoCodecMode) -> Bool {
        guard ProcessInfo.processInfo.isiOSAppOnMac, mode == .screensharing, let configure else { return false }
        #if DEBUG
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SCREEN_DETAIL_PRESET"] == "reference" { return false }
        #endif
        var maxQP: Int32 = 24
        var prioritizeSpeed: Int32 = 0
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SCREEN_MAX_QP"].flatMap(Int32.init), (1...51).contains(value) { maxQP = value }
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SCREEN_SPEED"] == "1" { prioritizeSpeed = 1 }
        #endif
        // A bounded quantization limit is a quality ceiling, not a bandwidth
        // guarantee. The native sender still owns congestion and frame dropping.
        return configure(Unmanaged.passUnretained(encoder as AnyObject).toOpaque(), maxQP, prioritizeSpeed) == 1
    }
}
