import Foundation
import VideoToolbox
import WebRTC
import ConferenceCore

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
    private var screenPreference: ShareEncodingPreference = .efficient
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
        _ = GuestSignalCodecBridge.install(outgoing: { socket, data in shared.outgoing(socket: socket as UUID, data: data) },
            incoming: { socket, data in shared.incoming(socket: socket as UUID, data: data) })
    }
    func begin(generation: UUID, roomID: String) {
        lock.lock(); defer { lock.unlock() }
        if self.generation != generation { screenPreference = .efficient }
        self.generation = generation; self.roomID = roomID; disabled = false
        screenPolicy?.begin(generation)
    }
    func end(generation: UUID) {
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
