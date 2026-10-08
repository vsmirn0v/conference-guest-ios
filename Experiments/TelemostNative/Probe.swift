import Foundation
import LiveKitWebRTC

@MainActor
final class TelemostProbe {
    private let session = URLSession(configuration: .ephemeral)
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?
    private let audio = SyntheticAudio()
    private lazy var factory: LKRTCPeerConnectionFactory = {
        let encoder = LKRTCDefaultVideoEncoderFactory()
        if preferH264, let codec = LKRTCDefaultVideoEncoderFactory.supportedCodecs().first(where: { $0.name == "H264" }) { encoder.preferredCodec = codec }
        return LKRTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: audio)
    }()
    private var subscriber: MediaPeer?
    private var ready = false
    private var publisher: MediaPeer?
    private var sharing = false
    private var preferH264 = false
    private var failure: Error?
    private var name = ""
    private var slotsRequested = false
    private var pending: [String: String] = [:]

    func run(invitation: URL, name: String, duration: UInt64, publish: Bool = false, sharing: Bool = false, preferH264: Bool = false, expectMedia: Bool = false) async throws {
        self.sharing = sharing
        self.preferH264 = preferH264
        self.name = name
        let connection = try await TelemostConnection.fetch(invitation: invitation, name: name)
        probeLog("bootstrap", ["engine": "GOLOOM", "authenticatedAccount": false])
        let peer = MediaPeer(target: "SUBSCRIBER", ice: connection.ice, factory: factory)
        peer.sendCandidate = { [weak self] value in Task { @MainActor in try? await self?.send("webrtcIceCandidate", value) } }
        subscriber = peer
        if publish {
            let publisher = MediaPeer(target: "PUBLISHER", ice: connection.ice, factory: factory)
            publisher.sendCandidate = { [weak self] value in Task { @MainActor in try? await self?.send("webrtcIceCandidate", value) } }
            self.publisher = publisher
        }
        let socket = session.webSocketTask(with: connection.server); self.socket = socket; socket.resume()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    let data: Data
                    switch message { case .data(let bytes): data = bytes; case .string(let text): data = Data(text.utf8); @unknown default: continue }
                    guard data.count < 2_000_000, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    try await self?.receive(value)
                } catch { if !Task.isCancelled { self?.failure = error; probeLog("socket-error", ["error": String(describing: error), "closeCode": socket.closeCode.rawValue, "reason": socket.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""]) }; break }
            }
        }
        let capabilities: [String: [String]] = [
            "offerAnswerMode": ["SEPARATE"], "initialSubscriberOffer": ["ON_HELLO"],
            "slotsMode": ["FROM_CONTROLLER"], "simulcastMode": ["DISABLED"],
            "selfVadStatus": ["FROM_SERVER"], "dataChannelSharing": ["TO_RTP"],
            "videoEncoderConfig": ["NO_CONFIG"], "svcModes": ["FALSE"], "reportTelemetryModes": ["FALSE"],
            "keepDefaultDevicesModes": ["FALSE"],
            "subscriberDtlsPassiveMode": ["SUBSCRIBER_DTLS_PASSIVE_MODE_DISABLED"]
        ]
        try await send("hello", [
            "participantMeta": ["name": name, "role": "SPEAKER", "description": "Native transport experiment", "sendAudio": false, "sendVideo": false],
            "participantAttributes": ["name": name, "role": "SPEAKER", "description": "Native transport experiment"],
            "participantId": connection.peerID, "roomId": connection.roomID, "serviceName": connection.service,
            "credentials": connection.credentials, "sendAudio": false, "sendVideo": false, "sendSharing": false,
            "capabilitiesOffer": capabilities,
            "sdkInfo": ["implementation": "native-experiment", "version": "0.1", "userAgent": "RockNRoll Native Probe", "hwConcurrency": ProcessInfo.processInfo.processorCount],
            "sdkInitializationId": UUID().uuidString, "disablePublisher": !publish, "disableSubscriber": false, "disableSubscriberAudio": false
        ])
        pingTask = Task { [weak self] in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000_000); if !Task.isCancelled { try? await self?.send("ping", [:]) } }
        }
        if let raw = ProcessInfo.processInfo.environment["TELEMOST_TEST_STATS_SECONDS"],
           let seconds = UInt64(raw), (2...60).contains(seconds) {
            statisticsTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
                    guard let self, !Task.isCancelled else { return }
                    await self.subscriber?.stats(); await self.publisher?.stats(); self.audio.report()
                }
            }
        }
        try await Task.sleep(nanoseconds: duration * 1_000_000_000)
        await peer.stats()
        await publisher?.stats()
        audio.report()
        if let failure { throw failure }
        guard ready, peer.isConnected, publisher?.isConnected != false else { throw ProbeError.mediaNotConnected }
        if expectMedia && (peer.receivedFrames < 10 || audio.receivedRMS < 0.001) { throw ProbeError.expectedMediaMissing }
        probeLog("finished", ["serverHello": ready, "iceConnected": true, "seconds": duration, "expectedMediaVerified": expectMedia])
    }

    private func send(_ key: String, _ payload: [String: Any], uid: String = UUID().uuidString) async throws {
        if key != "ack" { pending[uid] = key }
        let data = try JSONSerialization.data(withJSONObject: ["uid": uid, key: payload])
        guard let socket else { throw ProbeError.transportLost }
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        if key != "webrtcIceCandidate" && key != "ping" && key != "ack" { probeLog("sent", ["type": key]) }
    }
    private func receive(_ value: [String: Any]) async throws {
        let uid = value["uid"] as? String ?? ""
        guard !uid.isEmpty else { throw ProbeError.invalidPayload }
        for key in value.keys.sorted() where key != "uid" {
            let object = value[key] as? [String: Any] ?? [:]
            if key == "ack" {
                let request = pending.removeValue(forKey: uid) ?? "unknown"
                if let status = object["status"] as? [String: Any], let code = status["code"] as? String, code != "OK" {
                    failure = ProbeError.signalingRejected("\(request): \(code)")
                    probeLog("rejected", ["code": code, "request": request])
                }
                continue
            }
            probeLog("received", ["type": key, "fields": object.keys.sorted()])
            switch key {
            case "serverHello":
                ready = true
                if let rtc = object["rtcConfiguration"] as? [String: Any] {
                    try subscriber?.applyConfiguration(rtc); try publisher?.applyConfiguration(rtc)
                }
                // The server waits for this ACK before accepting later requests.
                try await send("ack", ["status": ["code": "OK"]], uid: uid)
                probeLog("negotiated", ["capabilities": object["capabilitiesAnswer"] ?? [:], "ping": object["pingPongConfiguration"] ?? [:]])
                if let publisher {
                    let offer = try await publisher.publishPattern(sharing: sharing, preferH264: preferH264)
                    try await send("publisherSdpOffer", offer)
                    try await send("updateMe", ["participantMeta": ["name": name, "role": "SPEAKER", "sendAudio": true, "sendVideo": !sharing], "participantAttributes": ["name": name, "role": "SPEAKER"], "sendAudio": true, "sendVideo": !sharing, "sendSharing": sharing])
                }
            case "subscriberSdpOffer":
                if let subscriber { let answer = try await subscriber.answer(object); try await send("subscriberSdpAnswer", answer) }
            case "publisherSdpAnswer":
                try await publisher?.acceptAnswer(object)
            case "webrtcIceCandidate":
                if object["target"] as? String == "SUBSCRIBER" { try await subscriber?.candidate(object) }
                else if object["target"] as? String == "PUBLISHER" { try await publisher?.candidate(object) }
            case "upsertDescription", "updateDescription":
                probeLog("roster-update")
            default: break
            }
        }
        if value["serverHello"] == nil && value.keys.contains(where: { $0 != "uid" && $0 != "ack" }) {
            try await send("ack", ["status": ["code": "OK"]], uid: uid)
        }
        if value["subscriberSdpOffer"] != nil && !slotsRequested {
            slotsRequested = true
            try await send("setSlots", ["key": 1, "audioSlotsCount": 0, "slots": Array(repeating: ["width": 640, "height": 360], count: 8), "gridConfig": [:], "withSelfView": false])
        }
    }
    func stop() async {
        pingTask?.cancel(); receiveTask?.cancel()
        statisticsTask?.cancel(); statisticsTask = nil
        subscriber?.close(); subscriber = nil
        publisher?.close(); publisher = nil
        let closing = socket
        closing?.cancel(with: .normalClosure, reason: nil); socket = nil
        // Give the close frame time to reach the SFU before invalidating the session
        // or exiting the CLI. Immediate invalidateAndCancel can leave a stale peer.
        for _ in 0..<100 {
            if closing == nil || closing?.state == .completed { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if let closing { probeLog("socket-closed", ["completed": closing.state == .completed, "code": closing.closeCode.rawValue]) }
        session.invalidateAndCancel()
    }
}

@main
struct ProbeMain {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2, let invitation = URL(string: args[1]) else {
            print("Usage: TelemostProbe <invitation> [seconds] [name] [--publish|--share] [--h264] [--expect-media]"); return
        }
        let probe = TelemostProbe()
        var status: Int32 = 0
        do { try await probe.run(invitation: invitation, name: args.count > 3 ? args[3] : "Rock Native QA", duration: min(600, UInt64(args.count > 2 ? args[2] : "20") ?? 20), publish: args.contains("--publish") || args.contains("--share"), sharing: args.contains("--share"), preferH264: args.contains("--h264"), expectMedia: args.contains("--expect-media")) }
        catch { probeLog("failed", ["error": String(describing: error)]); status = 1 }
        await probe.stop()
        if status != 0 { exit(status) }
    }
}
