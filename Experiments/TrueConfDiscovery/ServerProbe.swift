import Foundation
import LiveKitWebRTC

@MainActor
final class ServerProbe {
    private let session = URLSession(configuration: .ephemeral)
    private let audio = SyntheticAudio()
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private var peer: MediaPeer?
    private var connection: ServerConnection?
    private var cid = ""
    private var peerID = ""
    private var stream = ""
    private var connectedMedia = false
    private var sentSDP = false
    private var pendingCandidates: [[String: Any]] = []
    private var failure: Error?
    private var rosterCount = 0
    private var publish = false
    private var sharing = false
    private var didPublish = false
    private var codecPolicy = CodecPolicy.serverDefault
    private var preferReceiveH264 = false
    private lazy var factory = LKRTCPeerConnectionFactory(
        encoderFactory: codecPolicy == .hevcOnly ? HEVCEncoderFactory() : ServerEncoderFactory(),
        decoderFactory: codecPolicy == .hevcOnly ? HEVCDecoderFactory() : ServerDecoderFactory(), audioDevice: audio
    )

    func run(invitation: URL, name: String, seconds: UInt64, publish: Bool, sharing: Bool, codecPolicy: CodecPolicy, preferReceiveH264: Bool) async throws {
        self.publish = publish
        self.sharing = sharing
        self.codecPolicy = codecPolicy
        self.preferReceiveH264 = preferReceiveH264
        LKRTCInitializeSSL()
        let connection = try await ServerConnection.fetch(invitation, name: name)
        self.connection = connection
        probeLog("bootstrap", ["guest": true, "browserURL": true, "nativeHTTP": true])
        let task = session.webSocketTask(with: connection.socket)
        socket = task
        task.resume()
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    let bytes: Data
                    switch message {
                    case .string(let text): bytes = Data(text.utf8)
                    case .data(let data): bytes = data
                    @unknown default: throw ProbeError.invalidPayload
                    }
                    guard bytes.count < 2_000_000,
                          let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                        throw ProbeError.invalidPayload
                    }
                    try await self?.receive(object)
                }
            } catch {
                if !Task.isCancelled { self?.failure = error; probeLog("transport-error", ["errorType": String(describing: type(of: error))]) }
            }
        }
        try await send(["method": "ping"])
        try await send([
            "method": "loginUser", "AppID": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            "login": connection.login, "credentials": connection.credential, "credentialsType": 3,
            "chatV2Enabled": false, "browser": "RockNRoll Native Probe", "appLang": "en",
            "appVersion": "5.1.0", "appName": "RockNRoll Native Probe"
        ])
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if !Task.isCancelled { try? await self?.send(["method": "ping"]) }
            }
        }
        for _ in 0..<seconds {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if let failure { throw failure }
        }
        let encoded = await peer?.stats() ?? 0
        audio.report()
        guard !publish || encoded > 10 else { throw ProbeError.mediaNotConnected }
        guard connectedMedia, let peer, peer.isConnected, peer.receivedFrames > 10 else {
            throw ProbeError.mediaNotConnected
        }
        probeLog("finished", ["nativeWebRTC": true, "receivedFrames": peer.receivedFrames,
                              "initialRosterCount": rosterCount, "syntheticSending": publish,
                              "syntheticPresentation": sharing,
                              "physicalMicEnabled": false, "physicalCameraEnabled": false])
    }

    private func receive(_ object: [String: Any]) async throws {
        guard let method = object["method"] as? String else { throw ProbeError.invalidPayload }
        if method != "webrtc" && method != "pong" { probeLog("received", ["method": method]) }
        switch method {
        case "loginResponse":
            let result = object["result"] as? Int ?? -1
            guard result == 0 else { throw ProbeError.rejected(result) }
            guard let cid = object["CID"] as? String, let peerID = object["trueconfId"] as? String,
                  let connection else { throw ProbeError.invalidPayload }
            self.cid = cid
            self.peerID = peerID
            try await send(["method": "join", "conferenceId": connection.room, "Password": "", "simulcastSupported": true])
        case "conferenceStateChange":
            guard let conference = object["conference"] as? [String: Any] else { throw ProbeError.invalidPayload }
            if let message = conference["message"] as? String { probeLog("conference-state", ["message": message]) }
            guard stream.isEmpty, let stream = conference["streamConferenceId"] as? String, !stream.isEmpty else { return }
            self.stream = stream
            try await send(["method": "getIceConfig", "streamConferenceId": stream])
        case "getIceConfig":
            guard !stream.isEmpty, peer == nil, let servers = object["iceServers"] as? [[String: Any]] else { return }
            let ice = try decodeIceServers(servers, cid: cid, stream: stream)
            let peer = MediaPeer(target: "TRUECONF", ice: ice, factory: factory)
            peer.sendCandidate = { [weak self] value in
                Task { @MainActor in
                    guard let self else { return }
                    let candidate: [String: Any] = ["type": "candidate", "candidate": value["candidate"] ?? "",
                        "sdpMLineIndex": value["sdpMlineIndex"] ?? 0, "sdpMid": value["sdpMid"] ?? "0"]
                    if self.sentSDP { try? await self.sendMedia(candidate) }
                    else { self.pendingCandidates.append(candidate) }
                }
            }
            self.peer = peer
            probeLog("ice-config", ["servers": ice.count, "turnPasswordsDecoded": true])
            try await send(["method": "connectMedia", "streamConferenceId": stream, "type": 1])
            // Observed browser status for disabled microphone and camera.
            try await send(["method": "DeviceStatus", "value": 262148])
        case "connectMedia":
            connectedMedia = object["result"] as? Bool == true
        case "webrtc":
            guard let type = object["type"] as? String, let peer else { return }
            if type == "offer" {
                sentSDP = false
                if preferReceiveH264, let sdp = object["sdp"] as? String {
                    try await peer.setRemote(.init(type: .offer, sdp: sdp))
                    let codecs = factory.rtpReceiverCapabilities(forKind: "video").codecs
                    for transceiver in peer.connection.transceivers where transceiver.mediaType == .video {
                        try transceiver.setCodecPreferences(codecs.filter { $0.name == "H264" } + codecs.filter { $0.name != "H264" }, error: ())
                    }
                }
                let answer = try await peer.answer(object)
                try await sendMedia(["type": "answer", "sdp": answer["sdp"] ?? "", "browser": "RockNRoll Native Probe"])
                sentSDP = true
                let candidates = pendingCandidates
                pendingCandidates.removeAll()
                for candidate in candidates { try await sendMedia(candidate) }
                probeLog("answered-offer")
                if publish && !didPublish {
                    didPublish = true
                    sentSDP = false
                    let offer = try await peer.publishPattern(sharing: false, codecPolicy: codecPolicy)
                    try await sendMedia(["type": "offer", "sdp": offer["sdp"] ?? "", "browser": "RockNRoll Native Probe"])
                    sentSDP = true
                    let queued = pendingCandidates
                    pendingCandidates.removeAll()
                    for candidate in queued { try await sendMedia(candidate) }
                    try await send(["method": "DeviceStatus", "value": 0])
                    probeLog("synthetic-offer-sent")
                }
            } else if type == "answer" {
                try await peer.acceptAnswer(object)
                probeLog("synthetic-offer-accepted")
                if sharing {
                    try await send(["method": "VideoSourceType", "Type": 2, "Conference": stream])
                    probeLog("synthetic-presentation-announced")
                }
            } else if type == "candidate" {
                var candidate = object
                candidate["sdpMlineIndex"] = object["sdpMLineIndex"]
                try await peer.candidate(candidate)
            } else if type == "layout" {
                if ProcessInfo.processInfo.environment["TRUECONF_LAYOUT_DISCOVERY"] == "1" {
                    probeLog("layout-discovery", ["list": object["list"] ?? []])
                }
                probeLog("mixed-layout", ["width": object["width"] ?? 0, "height": object["height"] ?? 0,
                                          "slots": (object["list"] as? [Any])?.count ?? 0])
            }
        case "SendPartsList":
            if let list = object["list"] as? [[String: Any]] {
                probeLog("roster-media", ["updateType": object["type"] ?? 0,
                                          "videoTypes": list.compactMap { $0["videoType"] as? Int }])
            }
            if object["type"] as? Int == 1 {
                rosterCount = (object["list"] as? [Any])?.count ?? 0
                probeLog("participants", ["count": rosterCount])
            }
        default: break
        }
    }

    private func sendMedia(_ fields: [String: Any]) async throws {
        try await send(fields.merging(["method": "webrtc", "my_peer_id": peerID, "conf_id": stream]) { _, rhs in rhs })
    }

    private func send(_ fields: [String: Any]) async throws {
        guard let socket else { throw ProbeError.transportLost }
        var object = fields
        if !cid.isEmpty { object["CID"] = cid }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func stop() async {
        keepAlive?.cancel()
        if let connection, !cid.isEmpty {
            try? await send(["method": "hangup", "result": 0, "conferenceId": connection.room])
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        reader?.cancel()
        peer?.close()
        peer = nil
        let closing = socket
        socket = nil
        closing?.cancel(with: .normalClosure, reason: nil)
        for _ in 0..<50 {
            if closing?.state == .completed { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        session.invalidateAndCancel()
        probeLog("stopped")
    }
}

@main
enum ServerProbeMain {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2, let invitation = URL(string: args[1]) else {
            print("Usage: TrueConfServerProbe <HTTPS invitation> [seconds, max 60] [test name] [--publish|--share] [--h264|--h264-only|--hevc-only]")
            exit(2)
        }
        let probe = ServerProbe()
        var code: Int32 = 0
        do {
            try await probe.run(invitation: invitation, name: args.count > 3 ? args[3] : "Rock Native Probe",
                                seconds: min(60, max(5, UInt64(args.count > 2 ? args[2] : "25") ?? 25)),
                                publish: args.contains("--publish") || args.contains("--share"),
                                sharing: args.contains("--share"),
                                codecPolicy: args.contains("--hevc-only") ? .hevcOnly : (args.contains("--h264-only") ? .h264Only : (args.contains("--h264") ? .preferH264 : .serverDefault)),
                                preferReceiveH264: args.contains("--receive-h264"))
        } catch { probeLog("failed", ["error": String(describing: error)]); code = 1 }
        await probe.stop()
        exit(code)
    }
}
