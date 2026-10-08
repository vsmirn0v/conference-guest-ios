import Foundation
import ObjectiveC
import WebRTC

// Disposable qualification only; not included in an application target.
#if DEBUG
enum GuestSignalCodecTrial {
    static func install() {
        let selector = NSSelectorFromString("sendMessage:completionHandler:")
        let codec = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_SIGNAL_CODEC"] == "vp9" ? "vp9" : "h264"
        let probeTask = URLSession.shared.webSocketTask(with: URL(string: "wss://example.invalid/")!)
        defer { probeTask.cancel() }
        guard let method = class_getInstanceMethod(type(of: probeTask), selector) else {
            print("GUEST_SIGNAL_CODEC unavailable"); return
        }
        typealias Send = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Send.self)
        let forward: @convention(block) (AnyObject, AnyObject, AnyObject) -> Void = { task, message, completion in
            print("GUEST_SIGNAL_CODEC send=\(type(of: message))")
            if let object = message as? NSObject,
               let data = (object.value(forKey: "string") as? String)?.data(using: .utf8) ?? object.value(forKey: "data") as? Data {
                if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    let payload = json["payload"] as? [String: Any]
                    let request = payload?["addTrackRequest"] as? [String: Any]
                    print("GUEST_SIGNAL_SHAPE keys=\(json.keys.sorted()) type=\(json["type"] as? String ?? "other") payloadKeys=\(payload?.keys.sorted() ?? []) requestKeys=\(request?.keys.sorted() ?? []) requestType=\(request?["type"] ?? "missing")")
                } else { print("GUEST_SIGNAL_SHAPE bytes=\(data.count) magic=\(data.prefix(4).map { String(format: "%02x", $0) }.joined())") }
            }
            guard let object = message as? NSObject,
                  object.responds(to: NSSelectorFromString("string")),
                  let data = (object.value(forKey: "string") as? String)?.data(using: .utf8) ?? object.value(forKey: "data") as? Data,
                  var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  json["event"] as? String == "media-in",
                  var payload = json["payload"] as? [String: Any],
                  var request = payload["addTrackRequest"] as? [String: Any],
                  request["type"] as? String == "VIDEO", let cid = request["cid"] as? String else {
                original(task, selector, message, completion); return
            }
            print("GUEST_SIGNAL_CODEC request fields=\(request.keys.sorted()) codecs=\(request["simulcastCodecs"] ?? "missing")")
            request["simulcastCodecs"] = [["codec": codec, "cid": cid]]
            payload["addTrackRequest"] = request; json["payload"] = payload
            let initializer = NSSelectorFromString("initWithString:")
            guard let encoded = try? JSONSerialization.data(withJSONObject: json),
                  let text = String(data: encoded, encoding: .utf8),
                  let allocate = class_getClassMethod(type(of: object), NSSelectorFromString("alloc")),
                  let initialize = class_getInstanceMethod(type(of: object), initializer) else {
                original(task, selector, message, completion); return
            }
            typealias Allocate = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>
            let allocateMessage = unsafeBitCast(method_getImplementation(allocate), to: Allocate.self)
            let newMessage = allocateMessage(type(of: object), NSSelectorFromString("alloc"))
            typealias Initialize = @convention(c) (UnsafeRawPointer, Selector, NSString) -> Unmanaged<AnyObject>
            let initializeMessage = unsafeBitCast(method_getImplementation(initialize), to: Initialize.self)
            let replacement = initializeMessage(UnsafeRawPointer(newMessage.toOpaque()), initializer, text as NSString).takeRetainedValue()
            original(task, selector, replacement, completion)
        }
        method_setImplementation(method, imp_implementationWithBlock(forward))
        print("GUEST_SIGNAL_CODEC installed")
    }
}

enum GuestEncoderSelectorTrial {
    static func install() {
        let selector = NSSelectorFromString("initWithEncoderFactory:decoderFactory:")
        guard let method = class_getInstanceMethod(RTCPeerConnectionFactory.self, selector) else { return }
        typealias Create = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> AnyObject
        let original = unsafeBitCast(method_getImplementation(method), to: Create.self)
        let forward: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> AnyObject = { factory, encoder, decoder in
            guard let encoder = encoder as? any RTCVideoEncoderFactory else { return original(factory, selector, encoder, decoder) }
            print("GUEST_CODEC_SELECTOR factory=\(type(of: encoder))")
            return original(factory, selector, TrialEncoderFactory(base: encoder), decoder)
        }
        method_setImplementation(method, imp_implementationWithBlock(forward))
    }
}

private final class TrialEncoderFactory: NSObject, RTCVideoEncoderFactory {
    let base: any RTCVideoEncoderFactory
    init(base: any RTCVideoEncoderFactory) { self.base = base }
    func supportedCodecs() -> [RTCVideoCodecInfo] { base.supportedCodecs() }
    func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
        print("GUEST_CODEC_SELECTOR create=\(info.name)")
        return base.createEncoder(info)
    }
    func encoderSelector() -> (any RTCVideoEncoderSelector)? {
        guard let preferred = base.supportedCodecs().first(where: { $0.name == "H264" && $0.parameters["profile-level-id"]?.hasPrefix("42e0") == true }) else { return nil }
        return TrialEncoderSelector(preferred: preferred)
    }
}

private final class TrialEncoderSelector: NSObject, RTCVideoEncoderSelector {
    let preferred: RTCVideoCodecInfo
    private var current: RTCVideoCodecInfo?
    private var requested = false
    init(preferred: RTCVideoCodecInfo) { self.preferred = preferred }
    func registerCurrentEncoderInfo(_ info: RTCVideoCodecInfo) {
        current = info; print("GUEST_CODEC_SELECTOR current=\(info.name)")
    }
    func encoder(forBitrate bitrate: Int) -> RTCVideoCodecInfo? {
        guard current?.name != "H264", !requested else { return nil }
        requested = true; print("GUEST_CODEC_SELECTOR request=H264 bitrate=\(bitrate)")
        return preferred
    }
    func encoderForBrokenEncoder() -> RTCVideoCodecInfo? { nil }
}
#endif
