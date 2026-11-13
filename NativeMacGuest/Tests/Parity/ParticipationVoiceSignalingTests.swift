#if DEBUG
import Foundation
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

@MainActor
final class ParticipationVoiceSignalingTests: XCTestCase {
    private static let audioSID = "test-audio-sid"

    func testTemporaryServerUnmuteAndRestoreRequireFreshVersionsAndKeepUserMute() async throws {
        try await withMutedAudioTrack { engine, track in
            var commands: [Bool] = []
            engine.mediaNotifyForTesting = { payload in
                let muted = try Self.muteValue(in: payload)
                commands.append(muted)
                let version = engine.stateForTesting.version
                try await Self.acknowledge(engine, version: version, muted: muted)
                XCTAssertEqual(engine.stateForTesting.server[Self.audioSID], !muted, "A stale update cannot confirm the request")
                try await Self.acknowledge(engine, version: version + 1, muted: muted)
            }

            try await engine.signalParticipationMuteForTesting(false, sid: Self.audioSID)
            XCTAssertEqual(engine.stateForTesting.version, 2)
            XCTAssertEqual(engine.stateForTesting.server[Self.audioSID], false)
            XCTAssertEqual(engine.stateForTesting.intent[false], true)
            XCTAssertFalse(track.isEnabled, "The server echo does not open the sender")

            try await engine.signalParticipationMuteForTesting(true, sid: Self.audioSID)
            XCTAssertEqual(commands, [false, true])
            XCTAssertEqual(engine.stateForTesting.version, 3)
            XCTAssertEqual(engine.stateForTesting.server[Self.audioSID], true)
            XCTAssertEqual(engine.stateForTesting.intent[false], true)
            XCTAssertFalse(track.isEnabled)
        }
    }

    func testCancelledNotifyWithALateUnmuteEchoStillAllowsCompensatingMute() async throws {
        try await withMutedAudioTrack { engine, track in
            var commands: [Bool] = []
            var suspendedNotify: CheckedContinuation<Void, Never>?
            func finishNotify() {
                let continuation = suspendedNotify
                suspendedNotify = nil
                continuation?.resume()
            }
            defer { finishNotify() }
            engine.mediaNotifyForTesting = { payload in
                let muted = try Self.muteValue(in: payload)
                commands.append(muted)
                if muted {
                    try await Self.acknowledge(engine, version: 3, muted: true)
                } else {
                    await withCheckedContinuation { suspendedNotify = $0 }
                }
            }
            let unmute = Task { try await engine.signalParticipationMuteForTesting(false, sid: Self.audioSID) }
            for _ in 0..<100 where suspendedNotify == nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNotNil(suspendedNotify)
            XCTAssertFalse(track.isEnabled)

            unmute.cancel()
            try await Self.acknowledge(engine, version: 2, muted: false)
            XCTAssertEqual(engine.stateForTesting.server[Self.audioSID], false)
            XCTAssertFalse(track.isEnabled)
            finishNotify()
            do {
                try await unmute.value
                XCTFail("A cancelled request accepted the late unmute echo")
            } catch is CancellationError {}
            XCTAssertEqual(engine.stateForTesting.intent[false], true)
            XCTAssertFalse(track.isEnabled)

            try await engine.signalParticipationMuteForTesting(true, sid: Self.audioSID)
            XCTAssertEqual(commands, [false, true])
            XCTAssertEqual(engine.stateForTesting.version, 3)
            XCTAssertEqual(engine.stateForTesting.server[Self.audioSID], true)
            XCTAssertEqual(engine.stateForTesting.intent[false], true)
            XCTAssertFalse(track.isEnabled)
        }
    }

    private func withMutedAudioTrack(_ run: (NativeGuestEngine, LKRTCAudioTrack) async throws -> Void) async throws {
        let engine = NativeGuestEngine(label: "Participation signaling test")
        do {
            let cid = "muted-audio-fixture"
            let peer = try await engine.prepareJoinForTesting(camera: false)
            let track = try await peer.prepareAudio(cid: cid)
            try await peer.attach(track, codec: "vp8")
            engine.setLocalMuteIntent(true, video: false)
            engine.preparePublicationForTesting(cid: cid, video: false)
            try await engine.processEventForTesting(["event": "media-out", "payload": [
                "method": "rtc:track:published",
                "trackPublishedResponse": ["cid": cid, "track": ["sid": Self.audioSID, "muted": true]],
            ]])
            try await Self.acknowledge(engine, version: 1, muted: true)
            XCTAssertFalse(track.isEnabled)
            try await run(engine, track)
        } catch {
            engine.mediaNotifyForTesting = nil
            _ = await engine.leave(sendLeave: false)
            throw error
        }
        engine.mediaNotifyForTesting = nil
        let clean = await engine.leave(sendLeave: false)
        XCTAssertTrue(clean)
    }

    private static func muteValue(in payload: [String: Any]) throws -> Bool {
        XCTAssertEqual(payload["method"] as? String, "rtc:track:muted")
        let mute = try XCTUnwrap(payload["mute"] as? [String: Any])
        XCTAssertEqual(mute["sid"] as? String, audioSID)
        return try XCTUnwrap(mute["muted"] as? Bool)
    }

    private static func acknowledge(_ engine: NativeGuestEngine, version: Int, muted: Bool) async throws {
        try await engine.processEventForTesting(["event": "media-out", "payload": [
            "method": "rtc:participants:update", "update": ["participants": [[
                "identity": "local", "sid": "participant-local", "version": version,
                "tracks": [["sid": audioSID, "type": "AUDIO", "muted": muted]],
            ]]],
        ]])
    }
}
#endif
