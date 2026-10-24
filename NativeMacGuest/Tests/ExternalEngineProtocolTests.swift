import Foundation
import ConferenceCore

@main struct ExternalEngineProtocolTests {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw NSError(domain: "NativeExternalEngineTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        let engine = NativeDesktopTelemostEngine()
        engine.snapshot.phase = .connecting; engine.localID = "self"; engine.name = "Tester"
        let generation = engine.epoch
        try await engine.receiveTelemost("updateDescription", ["description": [
            ["id": "audio-only", "meta": ["name": "Audio only", "sendAudio": true, "sendVideo": false]],
            ["id": "unknown", "meta": ["name": "Unknown media"]],
            ["id": "hidden", "hideFromParticipantsList": true, "meta": ["name": "Hidden"]]
        ]], attempt: generation)
        try expect(engine.snapshot.participants.count == 3, "Roster retains camera-free people and excludes hidden entries")
        try expect(engine.snapshot.participants.first { $0.id == "audio-only" }?.microphoneOn == true, "Known mic state maps from metadata")
        try expect(engine.snapshot.participants.first { $0.id == "unknown" }?.microphoneOn == nil, "Missing mic state remains unknown")
        try expect(engine.incomingVideo.isEmpty, "Roster does not fabricate video tracks")
        try await engine.receiveTelemost("removeDescription", ["descriptionId": ["audio-only"]], attempt: generation)
        try expect(!engine.snapshot.participants.contains { $0.id == "audio-only" }, "Leave removes participant without a video event")
        engine.slotKey = 4
        try await engine.receiveTelemost("slotsConfig", ["key": 3, "slots": [["vad": true, "participant": ["participantId": "unknown"]]]], attempt: generation)
        try expect(engine.speaking.isEmpty, "Old requested slot response is ignored")
        try await engine.receiveTelemost("slotsConfig", ["key": 0, "slots": [["vad": true, "participant": ["participantId": "unknown"]]]], attempt: generation)
        try expect(engine.snapshot.participants.first { $0.id == "unknown" }?.speaking == true, "Autonomous slot update reports real speech")
        let bootstrap = TelemostBootstrap(roomID: "room", participantID: "self", credentials: "fixture", serverURL: URL(string: "wss://example.invalid")!, serviceName: "fixture", iceServers: [], chatAllowed: true)
        let hello = NativeDesktopExternalSession.telemostHello(bootstrap, name: "Tester", quiet: true)
        try expect(hello["sendAudio"] as? Bool == false && hello["sendVideo"] as? Bool == false && hello["sendSharing"] as? Bool == false, "Provider hello is always media-off")
        try expect(hello["disableSubscriberAudio"] as? Bool == true, "Quiet joining preserves output intent")
        let sourceSlots: [[String: Any]] = [
            ["participantScreenSharingByMid": ["participantId": "share", "mid": "v1"]],
            ["participantVideoByMid": ["participantId": "camera", "mid": "v2"]]]
        let focused = NativeDesktopSlotDemand.request(slots: sourceSlots, visible: ["share"], focused: "share")
        let sizes = focused["slots"] as? [[String: Int]]
        try expect(sizes?.first == ["width": 3840, "height": 2160], "Focused screen requests 4K dimensions")
        try expect(sizes?[1] == ["width": 160, "height": 90], "Hidden slot retains identity with bounded dimensions")
        let orderedA = NativeDesktopSlotDemand.request(slots: sourceSlots, visible: Set(["camera", "share"]), focused: nil)
        let orderedB = NativeDesktopSlotDemand.request(slots: sourceSlots, visible: Set(["share", "camera"]), focused: nil)
        let encodedA = try JSONSerialization.data(withJSONObject: orderedA, options: .sortedKeys)
        let encodedB = try JSONSerialization.data(withJSONObject: orderedB, options: .sortedKeys)
        try expect(encodedA == encodedB, "Gallery reorder does not reorder provider slots")
        let audioOnly = NativeDesktopSlotDemand.request(slots: sourceSlots, visible: [], focused: nil)
        try expect(audioOnly["shutdownAllVideo"] as? Bool == true && audioOnly["audioSlotsCount"] as? Int == 0 && audioOnly["disableSubscriberAudio"] == nil,
            "Audio-only suppresses video without changing the established audio subscription")
        try await engine.setVisibleParticipantIDs([], focusedParticipantID: nil)
        try expect(engine.snapshot.playoutOn, "Viewport demand does not mute playout")
        let left = await engine.leave()
        try expect(left && engine.snapshot.phase == .left, "Leave completes without a media owner")
        do {
            try await engine.receiveTelemost("upsertDescription", ["description": [["id": "late"]]], attempt: generation)
            throw NSError(domain: "LateEventAccepted", code: 1)
        } catch is CancellationError { checks += 1 }
        try expect(engine.snapshot.participants.isEmpty, "Old generation cannot repopulate departed roster")
        let failure = NativeDesktopTelemostEngine()
        failure.snapshot.phase = .connecting
        var terminalPhases: [NativeDesktopMeetingPhase] = []
        failure.onState = { terminalPhases.append($0.phase) }
        await failure.fail(TelemostError.removed)
        try expect(failure.snapshot.phase == .failed && !terminalPhases.contains(.left), "Terminal failure is never published as normal departure")

        let tc = NativeDesktopTrueConfEngine()
        tc.snapshot.phase = .connecting; tc.localID = "self"
        // A socket object is sufficient to exercise the event dispatcher; it is
        // never started and no network or physical capture is used by this test.
        tc.trueconf = TrueConfTransport(server: URL(string: "wss://example.invalid")!, session: URLSession(configuration: .ephemeral))
        try await tc.receiveTrueConf(["method": "SendPartsList", "type": 1, "list": [
            ["trueconfId": "remote", "displayname": "Remote", "DeviceStatus": 0, "videoType": 2]
        ]], attempt: tc.epoch)
        let remote = tc.snapshot.participants.first { $0.id == "remote" }
        try expect(remote?.sharing == true && remote?.cameraOn == false, "TrueConf distinguishes content from camera")
        try expect(remote?.speaking == nil, "TrueConf does not invent per-person VAD")
        tc.microphoneIntent = true; tc.snapshot.microphoneOn = true
        try await tc.receiveTrueConf(["method": "setDeviceState", "Type": "microphone", "Mute": true], attempt: tc.epoch)
        try expect(!tc.microphoneIntent && !tc.snapshot.microphoneOn, "Forced mute withdraws user intent")
        try await tc.receiveTrueConf(["method": "DeviceStatus", "UserName": "remote", "DeviceStatus": 262148], attempt: tc.epoch)
        try expect(tc.snapshot.participants.first { $0.id == "remote" }?.microphoneOn == false, "Device update refreshes roster")
        try await tc.receiveTrueConf(["method": "SendPartsList", "type": 3, "list": [["trueconfId": "remote"]]], attempt: tc.epoch)
        try expect(!tc.snapshot.participants.contains { $0.id == "remote" }, "Incremental TrueConf departure is applied")
        let clean = await tc.leave()
        try expect(clean, "Unstarted signaling socket closes cleanly")
        tc.cleanupSucceeded = false
        do {
            try await tc.connect(invitation: URL(string: "https://example.invalid/c/room")!, name: "Tester", quiet: false)
            throw NSError(domain: "UnsafeRejoinAccepted", code: 1)
        } catch NativeDesktopRTCError.cleanupFailed { checks += 1 }
        print("PASS: \(checks) native external-engine protocol and lifecycle assertions; no live network or physical media")
    }
}
