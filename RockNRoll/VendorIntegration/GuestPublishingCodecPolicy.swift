import Foundation
import VideoToolbox
import WebRTC

/// Thread-safe, per-call/per-socket negotiation. Unknown protocols, rooms and
/// capabilities pass through unchanged. Incoming codecs are never rewritten.
final class GuestPublishingCodecPolicy: @unchecked Sendable {
    static let shared = GuestPublishingCodecPolicy(hardwareH264: hardwareH264Available)
    static let fallbackNotification = Notification.Name("dev.vsmirn0v.guest-codec-fallback")
    private let lock = NSLock()
    private let hardwareH264: Bool
    private var generation: UUID?
    private var roomID: String?
    private struct Socket { let generation: UUID; let room: String; var codecs: Set<String> = [] }
    private var sockets: [UUID: Socket] = [:]
    // Retain bounded identities across calls; a late join on an old socket
    // cannot inherit the capabilities or lifecycle of the replacement call.
    private var seen: [UUID] = []
    private var disabled = false
    private var selectionHandler: ((UUID, String) -> Void)?
    var onSelection: ((UUID, String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return selectionHandler }
        set { lock.lock(); selectionHandler = newValue; lock.unlock() }
    }

    init(hardwareH264: Bool) { self.hardwareH264 = hardwareH264 }
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
        #if DEBUG
        print("GUEST_CODEC_CAPABILITY hardwareH264=\(hardwareH264Available) mac=\(ProcessInfo.processInfo.isiOSAppOnMac)")
        #endif
        _ = GuestSignalCodecBridge.install(outgoing: { socket, data in shared.outgoing(socket: socket as UUID, data: data) },
            incoming: { socket, data in shared.incoming(socket: socket as UUID, data: data) })
    }
    func begin(generation: UUID, roomID: String) {
        lock.lock(); defer { lock.unlock() }
        self.generation = generation; self.roomID = roomID; disabled = false
    }
    func end(generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard self.generation == generation else { return }
        self.generation = nil; roomID = nil; selectionHandler = nil
    }
    func disable(generation: UUID) {
        lock.lock()
        guard self.generation == generation, !disabled else { lock.unlock(); return }
        disabled = true; lock.unlock()
        NotificationCenter.default.post(name: Self.fallbackNotification, object: self, userInfo: ["generation": generation])
    }
    func incoming(socket: UUID, data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard let generation, !disabled, var socketState = sockets[socket], socketState.generation == generation,
              data.count <= 1_048_576,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["event"] as? String == "media-out",
              let payload = json["payload"] as? [String: Any],
              let join = payload["join"] as? [String: Any],
              let room = join["room"] as? [String: Any] else { return }
        guard json["roomId"] as? String == socketState.room,
              let codecs = room["enabledCodecs"] as? [[String: Any]] else { return }
        socketState.codecs = Set(codecs.compactMap { ($0["mime"] as? String)?.lowercased() })
        sockets[socket] = socketState
    }
    func outgoing(socket: UUID, data: Data) -> Data? {
        lock.lock()
        guard let generation, !disabled, data.count <= 1_048_576,
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var payload = json["payload"] as? [String: Any] else { lock.unlock(); return nil }
        if json["event"] as? String == "join", let room = json["roomId"] as? String, room == roomID,
           payload["jazzToken"] is String, payload["participantName"] is String, !seen.contains(socket) {
            seen.append(socket); sockets[socket] = Socket(generation: generation, room: room)
            if seen.count > 128 { sockets.removeValue(forKey: seen.removeFirst()) }
        }
        #if DEBUG
        if let request = payload["addTrackRequest"] as? [String: Any], request["type"] as? String == "VIDEO" {
            let offered = request["simulcastCodecs"] as? [[String: Any]] ?? []
            let qualified = sockets[socket].map { $0.generation == generation } ?? false
            let h264 = sockets[socket]?.codecs.contains("video/h264") ?? false
            let formats = offered.compactMap { $0["codec"] as? String }
            let matchingCID = offered.first?["cid"] as? String == request["cid"] as? String
            print("GUEST_CODEC_REQUEST hardware=\(hardwareH264) socket=\(qualified) h264=\(h264) formats=\(formats) matchingCID=\(matchingCID)")
        }
        #endif
        guard hardwareH264, let state = sockets[socket], state.generation == generation,
              state.codecs.contains("video/h264"), json["roomId"] as? String == state.room,
              json["event"] as? String == "media-in",
              var request = payload["addTrackRequest"] as? [String: Any],
              request["type"] as? String == "VIDEO", let cid = request["cid"] as? String,
              !cid.isEmpty, let offered = request["simulcastCodecs"] as? [[String: Any]],
              offered.count == 1, (offered[0]["codec"] as? String)?.lowercased() == "vp8",
              offered[0]["cid"] as? String == cid else { lock.unlock(); return nil }
        request["simulcastCodecs"] = [["codec": "h264", "cid": cid]]
        payload["addTrackRequest"] = request; json["payload"] = payload
        let result = try? JSONSerialization.data(withJSONObject: json)
        let selected = selectionHandler
        lock.unlock()
        if result != nil {
            #if DEBUG
            print("GUEST_HARDWARE_CODEC selected=H264")
            #endif
            selected?(generation, cid)
        }
        return result
    }
}
