import Foundation
import VideoToolbox
import WebRTC
import ConferenceCore
#if DEBUG
import CryptoKit
#endif

/// Thread-safe, per-call/per-socket negotiation. Unknown protocols, rooms and
/// capabilities pass through unchanged. Incoming codecs are never rewritten.
final class GuestPublishingCodecPolicy: @unchecked Sendable {
    static let shared = GuestPublishingCodecPolicy(hardwareH264: hardwareH264Available, screenPolicy: .shared)
    static let fallbackNotification = Notification.Name("dev.vsmirn0v.guest-codec-fallback")
    private let lock = NSLock()
    private let hardwareH264: Bool
    private let screenPolicy: GuestScreenSharePolicy?
    private var generation: UUID?
    private var roomID: String?
    private struct Socket { let generation: UUID; let room: String; var codecs: Set<String> = [] }
    private var sockets: [UUID: Socket] = [:]
    // Retain bounded identities across calls; a late join on an old socket
    // cannot inherit the capabilities or lifecycle of the replacement call.
    private var seen: [UUID] = []
    private var disabled = false
    private let presenterSubscriptions = GuestPresenterCameraSubscriptions(
        bind: { GuestSignalCodecBridge.bindObservedSocket($0) },
        unbind: { GuestSignalCodecBridge.unbindAfterPendingSends($0) }) { socket, data, current in
        GuestSignalCodecBridge.send(data, socket: socket) {
            guard current() else { return false }
            #if DEBUG
            GuestMediaSubscriptionTrace.record(data, incoming: false)
            #endif
            return true
        }
    }
    private var screenPreference: ShareEncodingPreference = .efficient
    var currentPresenterCameraLease: GuestPresenterCameraLease? { presenterSubscriptions.currentLease }
    var onPresenterCameraLeaseChange: ((GuestPresenterCameraLease?) -> Void)? {
        get { presenterSubscriptions.onLeaseChange }
        set { presenterSubscriptions.onLeaseChange = newValue }
    }
    var onPresenterCameraSubscriberAnswer: ((GuestPresenterCameraLease) -> Void)? {
        get { presenterSubscriptions.onSubscriberAnswer }
        set { presenterSubscriptions.onSubscriberAnswer = newValue }
    }
    #if DEBUG
    var retainedCameraSIDForTesting: String? { presenterSubscriptions.retainedCameraSIDForTesting }
    #endif
    private var screenCodecHandler: ((UUID, String) -> Void)?
    private var capabilityHandler: ((UUID, Bool) -> Void)?
    var onScreenPublication: ((UUID, String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return screenCodecHandler }
        set { lock.lock(); screenCodecHandler = newValue; lock.unlock() }
    }
    var onScreenCapability: ((UUID, Bool) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return capabilityHandler }
        set { lock.lock(); capabilityHandler = newValue; lock.unlock() }
    }
    func beginScreenSharing(_ preference: ShareEncodingPreference) {
        lock.lock(); screenPreference = preference; lock.unlock()
    }
    var supportsScreenVP9: Bool {
        lock.lock(); defer { lock.unlock() }
        return !disabled && sockets.values.contains { $0.generation == generation && $0.codecs.contains("video/vp9") }
    }
    private var selectionHandler: ((UUID, String) -> Void)?
    var onSelection: ((UUID, String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return selectionHandler }
        set { lock.lock(); selectionHandler = newValue; lock.unlock() }
    }

    init(hardwareH264: Bool, screenPolicy: GuestScreenSharePolicy? = nil) {
        self.hardwareH264 = hardwareH264; self.screenPolicy = screenPolicy
    }
    static var hardwareH264Available: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        var encoders: CFArray?
        guard RTCDefaultVideoEncoderFactory.supportedCodecs().contains(where: { $0.name == "H264" }),
              VTCopyVideoEncoderList(nil, &encoders) == noErr,
              let values = encoders as? [[CFString: Any]] else { return false }
        return values.contains {
            ($0[kVTVideoEncoderList_CodecType] as? NSNumber)?.uint32Value == kCMVideoCodecType_H264 &&
            ($0[kVTVideoEncoderList_IsHardwareAccelerated] as? NSNumber)?.boolValue == true
        }
        #endif
    }
    static func prepare() {
        GuestScreenSharePolicy.prepare()
        #if DEBUG
        print("GUEST_CODEC_CAPABILITY hardwareH264=\(hardwareH264Available) mac=\(ProcessInfo.processInfo.isiOSAppOnMac)")
        #endif
        _ = GuestSignalCodecBridge.install(outgoing: { socket, data in
            let retained = shared.presenterSubscriptions.outgoing(socket: socket as UUID, data: data)
            return shared.outgoing(socket: socket as UUID, data: retained ?? data) ?? retained
        }, incoming: { socket, data in
            shared.presenterSubscriptions.incoming(socket: socket as UUID, data: data)
            shared.incoming(socket: socket as UUID, data: data)
        })
    }
    func setVisiblePresenterCameraCandidates(_ identities: [String], generation: UUID) {
        presenterSubscriptions.setVisibleCandidates(identities, generation: generation)
    }
    func begin(generation: UUID, roomID: String) {
        presenterSubscriptions.begin(generation: generation, room: roomID)
        lock.lock(); defer { lock.unlock() }
        if self.generation != generation { screenPreference = .efficient }
        self.generation = generation; self.roomID = roomID; disabled = false
        screenPolicy?.begin(generation)
    }
    func end(generation: UUID) {
        presenterSubscriptions.end(generation: generation)
        lock.lock(); defer { lock.unlock() }
        guard self.generation == generation else { return }
        self.generation = nil; roomID = nil; selectionHandler = nil
        screenCodecHandler = nil; capabilityHandler = nil; screenPreference = .efficient
        screenPolicy?.end(generation)
    }
    func disable(generation: UUID) {
        lock.lock()
        guard self.generation == generation, !disabled else { lock.unlock(); return }
        disabled = true; lock.unlock()
        #if DEBUG
        print("GUEST_CODEC_FALLBACK generation=\(generation)")
        #endif
        NotificationCenter.default.post(name: Self.fallbackNotification, object: self, userInfo: ["generation": generation])
    }
    func incoming(socket: UUID, data: Data) {
        #if DEBUG
        GuestMediaSubscriptionTrace.record(data, incoming: true)
        #endif
        lock.lock()
        guard let generation, !disabled, var socketState = sockets[socket], socketState.generation == generation,
              data.count <= 1_048_576,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["event"] as? String == "media-out",
              let payload = json["payload"] as? [String: Any],
              let join = payload["join"] as? [String: Any],
              let room = join["room"] as? [String: Any] else { lock.unlock(); return }
        guard json["roomId"] as? String == socketState.room,
              let codecs = room["enabledCodecs"] as? [[String: Any]] else { lock.unlock(); return }
        socketState.codecs = Set(codecs.compactMap { ($0["mime"] as? String)?.lowercased() })
        sockets[socket] = socketState
        let callback = capabilityHandler
        let vp9 = socketState.codecs.contains("video/vp9") && !disabled
        lock.unlock(); callback?(generation, vp9)
    }
    func outgoing(socket: UUID, data: Data) -> Data? {
        #if DEBUG
        GuestMediaSubscriptionTrace.record(data, incoming: false)
        #endif
        lock.lock()
        guard let generation, data.count <= 1_048_576,
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var payload = json["payload"] as? [String: Any] else { lock.unlock(); return nil }
        if json["event"] as? String == "join", let room = json["roomId"] as? String, room == roomID,
           payload["jazzToken"] is String, payload["participantName"] is String, !seen.contains(socket) {
            seen.append(socket); sockets[socket] = Socket(generation: generation, room: room)
            if seen.count > 128 { sockets.removeValue(forKey: seen.removeFirst()) }
        }
        var screenPublication: String?
        var notifyScreen: ((UUID, String) -> Void)?
        defer { if let screenPublication { notifyScreen?(generation, screenPublication) } }
        if let state = sockets[socket], state.generation == generation,
           json["roomId"] as? String == state.room, json["event"] as? String == "media-in",
           let request = payload["addTrackRequest"] as? [String: Any], request["type"] as? String == "VIDEO",
           request["source"] as? String == "SCREEN_SHARE", let cid = request["cid"] as? String {
            screenPolicy?.register(cid, generation: generation)
            screenPublication = cid; notifyScreen = screenCodecHandler
        }
        #if DEBUG
        if let request = payload["addTrackRequest"] as? [String: Any], request["type"] as? String == "VIDEO" {
            let offered = request["simulcastCodecs"] as? [[String: Any]] ?? []
            let qualified = sockets[socket].map { $0.generation == generation } ?? false
            let h264 = sockets[socket]?.codecs.contains("video/h264") ?? false
            let formats = offered.compactMap { $0["codec"] as? String }
            let matchingCID = offered.first?["cid"] as? String == request["cid"] as? String
            print("GUEST_CODEC_REQUEST hardware=\(hardwareH264) socket=\(qualified) h264=\(h264) formats=\(formats) matchingCID=\(matchingCID) source=\(request["source"] ?? "unknown") cid=\(request["cid"] ?? "unknown")")
        }
        #endif
        guard !disabled, let state = sockets[socket], state.generation == generation,
              json["roomId"] as? String == state.room,
              json["event"] as? String == "media-in",
              var request = payload["addTrackRequest"] as? [String: Any],
              request["type"] as? String == "VIDEO", let cid = request["cid"] as? String,
              !cid.isEmpty, let offered = request["simulcastCodecs"] as? [[String: Any]],
              offered.count == 1, (offered[0]["codec"] as? String)?.lowercased() == "vp8",
              offered[0]["cid"] as? String == cid else { lock.unlock(); return nil }
        let isScreen = request["source"] as? String == "SCREEN_SHARE"
        var prefersVP9 = isScreen && screenPreference == .textDetail
        #if DEBUG
        if isScreen && ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SCREEN_CODEC"] == "vp9" { prefersVP9 = true }
        #endif
        let selectedCodec: String
        if prefersVP9 && state.codecs.contains("video/vp9") { selectedCodec = "vp9" }
        else if hardwareH264 && state.codecs.contains("video/h264") { selectedCodec = "h264" }
        else { lock.unlock(); return nil }
        request["simulcastCodecs"] = [["codec": selectedCodec, "cid": cid]]
        payload["addTrackRequest"] = request; json["payload"] = payload
        let result = try? JSONSerialization.data(withJSONObject: json)
        let selected = selectionHandler
        lock.unlock()
        if result != nil {
            #if DEBUG
            print("GUEST_HARDWARE_CODEC selected=\(selectedCodec)")
            #endif
            selected?(generation, cid)
        }
        return result
    }
}

#if DEBUG
/// Opt-in diagnostic only: bounded structured fields, with no signaling secrets.
enum GuestMediaSubscriptionTrace {
    static let enabled = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_NATIVE_SHARE_TRACE"] == "1"
    private static let lock = NSLock()
    private static var emitted = 0
    static func identifier(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    static func record(_ data: Data, incoming: Bool) {
        guard enabled, data.count <= 1_048_576,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              ["media-in", "media-out"].contains(json["event"] as? String ?? ""),
              let payload = json["payload"] as? [String: Any] else { return }
        var row: [String: Any] = ["incoming": incoming, "uptime": ProcessInfo.processInfo.systemUptime]
        for key in ["subscription", "trackSetting", "trackSettings"] {
            guard let value = payload[key] as? [String: Any] else { continue }
            var fields: [String: Any] = [:]
            for name in ["trackSids", "participantSids"] {
                if let ids = value[name] as? [String] { fields[name] = ids.prefix(64).map(identifier) }
            }
            for name in ["subscribe", "disabled", "width", "height", "fps", "quality"] {
                if let number = value[name] as? NSNumber { fields[name] = number }
                else if let quality = value[name] as? String, ["LOW", "MEDIUM", "HIGH", "OFF"].contains(quality) { fields[name] = quality }
            }
            row[key] = fields
        }
        for key in ["description", "offer", "answer"] {
            if let description = payload[key] as? [String: Any], let sdp = description["sdp"] as? String {
                row[key] = videoSections(sdp)
            }
        }
        let join = payload["join"] as? [String: Any] ?? [:]
        let update = payload["update"] as? [String: Any] ?? [:]
        var participants = (join["otherParticipants"] as? [[String: Any]] ?? []) + (update["participants"] as? [[String: Any]] ?? [])
        if let local = join["participant"] as? [String: Any] { participants.append(local) }
        if !participants.isEmpty {
            row["participants"] = participants.prefix(32).map { participant -> [String: Any] in
                var result: [String: Any] = [:]
                if let sid = participant["sid"] as? String { result["id"] = identifier(sid) }
                result["versionPresent"] = participant["version"] != nil
                result["versionNumeric"] = participant["version"] is NSNumber
                if let version = participant["version"] as? Int { result["version"] = version }
                if let identity = participant["identity"] as? String { result["identity"] = identifier(identity) }
                result["tracks"] = (participant["tracks"] as? [[String: Any]] ?? []).prefix(32).map(track)
                return result
            }
        }
        if let published = payload["trackPublishedResponse"] as? [String: Any], let value = published["track"] as? [String: Any] { row["published"] = track(value) }
        guard row.count > 2 else { return }
        row["roomPresent"] = json["roomId"] != nil
        row["groupPresent"] = json["groupId"] != nil
        lock.lock()
        guard emitted < 256 else { lock.unlock(); return }
        emitted += 1; row["sequence"] = emitted
        lock.unlock()
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print("LEGACY_MEDIA_TRACE \(text)") }
    }
    private static func track(_ value: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        if let sid = value["sid"] as? String { result["id"] = identifier(sid) }
        if let muted = value["muted"] as? Bool { result["muted"] = muted }
        for key in ["type", "source"] {
            if let number = value[key] as? NSNumber { result[key] = number }
            else if let text = value[key] as? String, ["AUDIO", "VIDEO", "CAMERA", "MICROPHONE", "SCREEN_SHARE", "SCREEN_SHARE_AUDIO", "UNKNOWN"].contains(text) { result[key] = text }
        }
        return result
    }
    static func videoSections(_ sdp: String) -> [[String: Any]] {
        guard sdp.utf8.count <= 1_048_576 else { return [] }
        var sections: [[String: Any]] = [], current: [String: Any]?
        for line in sdp.components(separatedBy: .newlines) {
            if line.hasPrefix("m=") {
                if let current, sections.count < 64 { sections.append(current) }
                current = line.hasPrefix("m=video ") ? ["ssrcPresent": false] : nil
            }
            guard current != nil else { continue }
            if line.hasPrefix("a=mid:"), let mid = Int(line.dropFirst(6)), (0...65535).contains(mid) { current?["mid"] = mid }
            else if ["a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive"].contains(line) { current?["direction"] = String(line.dropFirst(2)) }
            else if line.hasPrefix("a=ssrc:") { current?["ssrcPresent"] = true }
            else if line.hasPrefix("a=msid:") {
                let fields = line.dropFirst(7).split(separator: " ")
                if fields.count == 2 { current?["track"] = identifier(String(fields[1])) }
            }
        }
        if let current, sections.count < 64 { sections.append(current) }
        return sections
    }
}
#endif
