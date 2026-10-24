import CoreMedia
import CoreVideo
import Foundation
import LiveKitWebRTC

/// Official Web SDK/plugin envelope fixtures. No meeting, physical capture, or
/// external transport is opened; the screen test uses two local SDP peers.
@main @MainActor struct MeetingFeaturesTests {
    static func main() async throws {
        let watchdog = DispatchWorkItem { fatalError("Meeting feature tests exceeded 30 seconds") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        defer { watchdog.cancel() }
        try rosterAndVersions()
        try chatTranscriptAndScope()
        try await advertisedFeaturePayload()
        try await engineFeatureRequests()
        try await historyPermissionRace()
        try await videoViewportDemand()
        try await screenSenderLifecycle()
        try await revokedScreenStart()
        print("PASS: native meeting roster/version/speaking, scoped chat/reaction/transcript fixtures, request correlation, history permission races, independent screen sender and capture privacy")
    }

    static func joined() -> [String: Any] {
        ["event": "joined", "roomId": "room", "payload": [
            "roomId": "room", "participant": ["participantId": "local", "sessionId": "session", "permissions": [
                "canViewParticipants": true, "canViewChat": true, "canSendChatMessage": true, "canSendReaction": true,
                "canViewTranscription": true, "canStartTranscription": true, "canShareScreen": true,
                "canShareCamera": true, "canShareMicrophone": true]],
            "participantGroup": ["groupId": "group", "participants": [
                ["participantId": "local", "name": "Local", "role": "MEMBER"],
                ["participantId": "remote", "name": "Remote", "role": "MEMBER"]]],
            "settings": ["title": "Fixture meeting"]]]
    }
    static func event(_ kind: String, _ payload: [String: Any] = [:]) -> [String: Any] {
        ["event": kind, "roomId": "room", "groupId": "group", "payload": payload]
    }
    static func participant(version: Int, muted: Bool, sid: String = "PA_remote", state: String = "ACTIVE") -> [String: Any] {
        ["sid": sid, "identity": "remote", "version": version, "state": state, "tracks": [
            ["sid": "TR_mic", "type": "AUDIO", "source": "MICROPHONE", "muted": muted],
            ["sid": "TR_camera", "type": "VIDEO", "source": "CAMERA", "muted": muted]]]
    }
    static func message(_ id: String, text: String = "Wire text", at: Any = 1_700_000_000_000) -> [String: Any] {
        ["id": id, "participantId": "remote", "participantName": "Remote at send", "text": text, "createdAt": at]
    }

    static func rosterAndVersions() throws {
        var features = GuestMeetingFeatures(); features.receive(joined())
        precondition(features.snapshot.title == "Fixture meeting" && features.snapshot.participants.count == 2)
        features.updateRTC([participant(version: 2, muted: false)])
        features.updateSpeakers([["sid": "PA_remote", "level": 0.7, "active": true]])
        var remote = features.snapshot.participants.first { $0.id == "remote" }!
        precondition(!remote.microphoneMuted && !remote.cameraMuted && remote.isSpeaking && remote.audioLevel == 0.7)
        features.updateRTC([participant(version: 1, muted: true)])
        precondition(features.snapshot.participants.first { $0.id == "remote" }?.cameraMuted == false)
        features.updateSpeakers([])
        precondition(features.snapshot.participants.allSatisfy { !$0.isSpeaking })
        features.updateRTC([participant(version: 3, muted: true)])
        precondition(features.snapshot.participants.first { $0.id == "remote" }?.cameraMuted == true)
        features.receive(event("participant-name-updated", ["participantId": "remote", "participantName": "Renamed"]))
        features.updateRTC([participant(version: 1, muted: false, sid: "PA_rejoined")])
        features.updateSpeakers([["sid": "PA_remote", "level": 1]])
        remote = features.snapshot.participants.first { $0.id == "remote" }!
        precondition(remote.name == "Renamed" && !remote.isSpeaking, "Retired SID cannot mark replacement speaking")
        features.updateRTC([participant(version: 4, muted: true, state: "DISCONNECTED")])
        precondition(features.snapshot.participants.first { $0.id == "remote" }?.microphoneMuted == false,
                     "Old SID disconnect cannot remove replacement")
        features.setLocalMute(true, video: false)
        features.updateRTC([["sid": "PA_local", "identity": "local", "version": 1, "tracks": [
            ["sid": "TR_local", "source": "MICROPHONE", "muted": false]]]])
        features.updateSpeakers([["sid": "PA_local", "level": 1]])
        precondition(features.snapshot.participants.first { $0.isLocal }?.microphoneMuted == true)
        precondition(features.snapshot.participants.first { $0.isLocal }?.isSpeaking == false)
        features.receive(event("permissions-updated", ["canViewParticipants": false]))
        precondition(features.snapshot.participants.count == 1 && features.snapshot.participants[0].isLocal)
        features.receive(event("participant-left", ["participantId": "remote"]))
        features.receive(event("permissions-updated", ["canViewParticipants": true]))
        precondition(features.snapshot.participants.count == 1)
    }

    static func chatTranscriptAndScope() throws {
        var features = GuestMeetingFeatures(); features.receive(joined())
        let raw = try JSONSerialization.data(withJSONObject: event("chat-message", ["message": message("m1", at: "2026-10-24T12:00:00.000Z")]))
        features.receive(try JSONSerialization.jsonObject(with: raw) as! [String: Any])
        features.receive(event("chat-message", ["message": message("m1", text: "Edited", at: "2026-10-24T12:00:00.000Z")]))
        precondition(features.snapshot.messages.count == 1 && features.snapshot.messages[0].text == "Edited")
        precondition(features.snapshot.messages[0].sentAt != nil)
        var foreign = event("chat-message", ["message": message("foreign")]); foreign["groupId"] = "other"
        features.receive(foreign)
        precondition(features.snapshot.messages.count == 1)
        features.receive(event("reaction", ["participantId": "remote", "reaction": "THUMBS_UP"]))
        features.receive(event("reaction", ["participantId": "remote", "reaction": "CLAP"]))
        features.receive(event("reaction", ["participantId": "remote", "reaction": "FUTURE_UNKNOWN"]))
        precondition(features.snapshot.reactions.map(\.reaction) == [.like, .applause])
        precondition(features.snapshot.transcriptionStatus == .unknown)
        features.receive(event("transcription-started"))
        features.receive(event("transcription-message", ["message": message("t1")]))
        precondition(features.snapshot.transcriptionStatus == .active && features.snapshot.transcript.count == 1)
        let epoch = features.epoch
        try features.acceptHistory(["messages": [message("history", at: 1_600_000_000_000)], "nextPageKey": 25], transcript: false, epoch: epoch)
        precondition(features.snapshot.messages.map(\.id) == ["history", "m1"] && features.snapshot.chatHasMore)
        features.receive(event("permissions-updated", ["canViewChat": false, "canViewTranscription": false]))
        precondition(features.snapshot.messages.isEmpty && features.snapshot.transcript.isEmpty)
        features.receive(event("permissions-updated", ["canViewChat": true, "canViewTranscription": true]))
        try features.acceptHistory(["messages": [message("retired")]], transcript: false, epoch: epoch)
        precondition(features.snapshot.messages.isEmpty, "Retired response restored revoked content")
        features.receive(event("transcription-stopped")); precondition(features.snapshot.transcriptionStatus == .stopped)
        features.receive(event("transcription-error")); precondition(features.snapshot.transcriptionStatus == .failed)
        features.receive(event("participant-role-updated", ["participantId": "local", "role": "MODERATOR"]))
        features.receive(event("permissions-updated", ["canViewTranscription": false, "canStartTranscription": false]))
        precondition(features.snapshot.permissions.canViewTranscript && features.snapshot.permissions.canManageTranscript)
        features.receive(event("participant-role-updated", ["participantId": "local", "role": "MEMBER"]))
        precondition(!features.snapshot.permissions.canViewTranscript && !features.snapshot.permissions.canManageTranscript)
        features.receive(event("chat-message", ["message": message("previous-group")]))
        var otherGroup = joined()
        var payload = otherGroup["payload"] as! [String: Any]
        var group = payload["participantGroup"] as! [String: Any]
        group["groupId"] = "other-group"; payload["participantGroup"] = group; otherGroup["payload"] = payload
        let previousEpoch = features.epoch
        features.receive(otherGroup)
        precondition(features.snapshot.messages.isEmpty && features.epoch != previousEpoch)
        try features.acceptHistory(["messages": [message("wrong-group-history")]], transcript: false, epoch: previousEpoch)
        precondition(features.snapshot.messages.isEmpty)
        features.stop(); features.receive(joined())
        precondition(features.snapshot.participants.isEmpty && features.snapshot.reactions.isEmpty)
    }

    static func engineFeatureRequests() async throws {
        let engine = NativeGuestEngine(label: "Feature fixture")
        _ = try engine.prepareJoinForTesting(); try await engine.processEventForTesting(joined())
        var changes = 0, requests: [String] = [], reactions: [String] = []
        engine.onMeetingChange = { _ in changes += 1 }
        engine.featureRequestForTesting = { kind, payload, id in
            requests.append(kind)
            if kind == "send-chat-message" {
                precondition(payload["messageText"] as? String == "Hello" && id != nil)
                var echo = event("chat-message", ["message": ["id": id!, "participantId": "local", "text": "Hello", "createdAt": 1_700_000_000_000]])
                echo["requestId"] = id
                try await engine.processEventForTesting(echo)
            }
            if kind == "get-chat-messages" {
                precondition(payload["limit"] as? Int == 25 && payload["pageKey"] == nil)
                return event("get-chat-messages-response", ["messages": [message("history")]])
            }
            return event("\(kind)-response")
        }
        engine.featureNotifyForTesting = { kind, payload in reactions.append(kind); precondition(payload["reaction"] as? String == "RED_HEART") }
        let id = try await engine.sendChatMessage(" Hello ")
        precondition(engine.meetingSnapshot.messages.count == 1 && engine.meetingSnapshot.messages[0].id == id)
        precondition(engine.meetingSnapshot.messages[0].delivery == .sent)
        try await engine.loadChatHistory(); try await engine.sendReaction(.heart)
        try await engine.setTranscriptionEnabled(true)
        precondition(engine.meetingSnapshot.transcriptionStatus == .active && changes > 3)
        precondition(requests == ["send-chat-message", "get-chat-messages", "start-transcription"] && reactions == ["send-reaction"])
        try await engine.processEventForTesting(["event": "error", "requestId": "correlated", "payload": ["code": "FORBIDDEN"]])
        precondition(engine.failure == nil)
        try await engine.processEventForTesting(event("permissions-updated", ["canSendReaction": false]))
        do { try await engine.sendReaction(.like); preconditionFailure("Revoked permission sent") }
        catch GuestEngineError.admissionDenied {}
        let stopped = await engine.leave(sendLeave: false); precondition(stopped)
        precondition(engine.meetingSnapshot.messages.isEmpty && !engine.meetingSnapshot.connected)
    }

    static func historyPermissionRace() async throws {
        let engine = NativeGuestEngine(label: "History fixture")
        _ = try engine.prepareJoinForTesting(); try await engine.processEventForTesting(joined())
        engine.featureRequestForTesting = { _, _, _ in
            try await engine.processEventForTesting(event("permissions-updated", ["canViewChat": false]))
            try await engine.processEventForTesting(event("permissions-updated", ["canViewChat": true]))
            return event("get-chat-messages-response", ["messages": [message("must-not-return")]])
        }
        try await engine.loadChatHistory()
        precondition(engine.meetingSnapshot.messages.isEmpty && !engine.meetingSnapshot.chatHistoryLoaded)
        let stopped = await engine.leave(sendLeave: false); precondition(stopped)
    }

    static func advertisedFeaturePayload() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeatureBootstrapProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let invitation = try GuestInvitation.parse("https://fixture.invalid/meeting")
        let prepared = try await GuestBootstrap(session: session).prepare(invitation, participantName: "Fixture",
            supportedFeatures: NativeGuestEngine.supportedFeatures)
        let data = try JSONSerialization.data(withJSONObject: prepared.joinPayload)
        let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let features = request["supportedFeatures"] as? [String: Bool]
        precondition(features == ["transcription": true], "Join omitted transcription or advertised an unsupported feature")
    }

    final class FeatureBootstrapProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let object: [String: Any] = request.url!.path.hasPrefix("/.well-known/")
                ? ["jazz": ["serverUrl": "https://signal.fixture.invalid/api"]]
                : ["connectorUrl": "wss://signal.fixture.invalid/connect"]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    static func screenSenderLifecycle() async throws {
        let engine = NativeGuestEngine(label: "Screen fixture")
        let publisher = try engine.prepareJoinForTesting()
        try await engine.processEventForTesting(joined())
        let camera = publisher.prepareVideo(cid: "camera")
        camera.isEnabled = false; try publisher.attach(camera, codec: "h264")
        let audio = GuestSyntheticAudio()
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: audio)
        let server = try GuestPeer(target: .subscriber, factory: factory)
        let config = server.connection.configuration; config.iceServers = []; config.iceTransportPolicy = .none
        precondition(server.connection.setConfiguration(config))
        var version = 0, source: String?, capture: Capture?
        engine.mediaNotifyForTesting = { payload in
            switch payload["method"] as? String {
            case "rtc:track:add":
                let request = payload["addTrackRequest"] as! [String: Any]
                source = request["source"] as? String
                precondition(request["width"] as? Int32 == 1920 && request["height"] as? Int32 == 1080)
                try await engine.processEventForTesting(["event": "media-out", "payload": ["method": "rtc:track:published", "trackPublishedResponse": [
                    "cid": request["cid"]!, "track": ["sid": "TR_screen", "source": "SCREEN_SHARE", "muted": true]]]])
            case "rtc:offer":
                let answer = try await server.answer(payload["description"] as! [String: Any])
                try await engine.processEventForTesting(["event": "media-out", "payload": ["method": "rtc:answer", "description": answer]])
            case "rtc:track:muted":
                version += 1
                let mute = payload["mute"] as! [String: Any]
                try await engine.processEventForTesting(["event": "media-out", "payload": ["method": "rtc:participants:update", "update": ["participants": [
                    ["sid": "PA_local", "identity": "local", "version": version, "tracks": [
                        ["sid": "TR_screen", "type": "VIDEO", "source": "SCREEN_SHARE", "muted": mute["muted"]!]]]]]]])
            default: break
            }
        }
        let profile = GuestVideoProfile(width: 1920, height: 1080, fps: 15, maximumBitrate: 3_000_000)
        try await engine.startScreenShare(profile: profile) { _ in let value = Capture(); capture = value; return value }
        precondition(engine.screenSharing && source == "SCREEN_SHARE" && engine.localScreenTrack != nil)
        precondition(publisher.localVideoTrack === camera && !camera.isEnabled, "Screen replaced or enabled camera")
        try await engine.processEventForTesting(["event": "media-out", "payload": ["method": "rtc:track:muted", "mute": ["sid": "TR_screen", "muted": true]]])
        precondition(!engine.screenSharing && engine.localScreenTrack == nil && capture?.cancelled == true)
        try await engine.stopScreenShare()
        precondition(capture?.stopped == true && publisher.localVideoTrack === camera)
        precondition(publisher.localScreenVideoTrack == nil)
        let stopped = await engine.leave(sendLeave: false); precondition(stopped)
        server.close(); precondition(audio.terminateDevice())
    }

    static func videoViewportDemand() async throws {
        let engine = NativeGuestEngine(label: "Viewport fixture")
        _ = try engine.prepareJoinForTesting(); try await engine.processEventForTesting(joined())
        var commands: [[String: Any]] = []
        engine.mediaNotifyForTesting = { commands.append($0) }
        let participants = (1...8).map { index -> [String: Any] in
            ["sid": "PA_\(index)", "identity": "remote\(index)", "version": 1, "state": "ACTIVE", "tracks": [
                ["sid": "TR_audio\(index)", "type": "AUDIO", "source": "MICROPHONE", "muted": false],
                ["sid": "TR_video\(index)", "type": "VIDEO", "source": index == 8 ? "SCREEN_SHARE" : "CAMERA", "muted": false]]]
        }
        try await engine.processEventForTesting(["event": "media-out", "payload": ["method": "rtc:participants:update", "update": ["participants": participants]]])
        commands.removeAll()
        try await engine.setVisibleParticipantIDs(["remote7"])
        let changes = commands.compactMap { $0["subscription"] as? [String: Any] }
        let added = changes.filter { $0["subscribe"] as? Bool == true }.flatMap { $0["trackSids"] as? [String] ?? [] }
        let removed = changes.filter { $0["subscribe"] as? Bool == false }.flatMap { $0["trackSids"] as? [String] ?? [] }
        precondition(added == ["TR_video7"] && !removed.isEmpty)
        precondition(removed.allSatisfy { $0.hasPrefix("TR_video") && $0 != "TR_video8" }, "Viewport unsubscribed audio or preferred screen")
        commands.removeAll()
        try await engine.processEventForTesting(event("participant-left", ["participantId": "remote7"]))
        precondition(!engine.connectedRemoteParticipants.contains("PA_7"), "Room departure waits for an RTC disconnect")
        let stopped = await engine.leave(sendLeave: false); precondition(stopped)
    }

    static func revokedScreenStart() async throws {
        let engine = NativeGuestEngine(label: "Screen privacy fixture")
        _ = try engine.prepareJoinForTesting(); try await engine.processEventForTesting(joined())
        var registered = false
        engine.mediaNotifyForTesting = { _ in registered = true }
        let capture = Capture()
        capture.onStart = { try await engine.processEventForTesting(event("permissions-updated", ["canShareScreen": false])) }
        do {
            try await engine.startScreenShare(profile: .camera) { _ in capture }
            preconditionFailure("Revoked capture started publishing")
        } catch GuestEngineError.admissionDenied {}
        precondition(capture.cancelled && capture.stopped && !registered && !engine.screenSharing)
        let stopped = await engine.leave(sendLeave: false); precondition(stopped)
    }

    final class Capture: GuestCameraCapture {
        var cancelled = false, stopped = false
        var onStart: (() async throws -> Void)?
        func start() async throws -> GuestCameraInfo {
            try await onStart?()
            return .init(deviceName: "Fixture", width: 1920, height: 1080, fps: 15, requestedWidth: 1920,
                requestedHeight: 1080, requestedFPS: 15, sessionPreset: "screen", minimumFrameDuration: CMTime(value: 1, timescale: 15),
                maximumFrameDuration: CMTime(value: 1, timescale: 15), pixelFormat: kCVPixelFormatType_32BGRA, mirrored: false, rotationDegrees: 0)
        }
        func cancel() { cancelled = true }
        func stop() async throws { stopped = true }
        func performReaction() async -> Bool { false }
        func snapshot() -> GuestCameraSnapshot {
            .init(frames: 0, advancingPTS: 0, dropped: 0, width: 1920, height: 1080, pixelFormat: kCVPixelFormatType_32BGRA,
                  systemBackgroundSelected: nil, systemBackgroundActive: nil, observedReaction: false)
        }
    }
}
