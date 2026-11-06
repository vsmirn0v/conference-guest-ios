import AVFoundation
import LiveKit
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

/// R4 S4: the app's Rock engine on the shared owner (a real `GuestSystemAudio`, manual
/// rendering so no device is needed) beside another meeting's attachment, against a local
/// `livekit-server --dev --bind 127.0.0.1 --node-ip 127.0.0.1`. Opt in with
/// `R4_ROCK_ENGINE=1` and run alone: installing the factory into LiveKit pins it for the
/// test process. A tone is played through LiveKit's app-audio mixer (no microphone).
@MainActor final class SharedEngineRockEngineTests: XCTestCase {

    func testRockRunsOnTheSharedOwnerAndSendsOnlyWithTheTalkRole() async throws {
        guard ProcessInfo.processInfo.environment["R4_ROCK_ENGINE"] == "1" else {
            throw XCTSkip("Opt-in: R4_ROCK_ENGINE=1 with a local livekit-server --dev")
        }
        guard await SharedEngineRockSpikeTests.serverAnswers() else { throw XCTSkip("No local LiveKit server on 127.0.0.1:7880") }
        GuestSystemAudio.microphoneAuthorizationOverrideForTesting = true
        defer { GuestSystemAudio.microphoneAuthorizationOverrideForTesting = nil }

        let engine = SharedAudioEngine.live(manualRenderingForTesting: true)
        let other = try await engine.attach(meetingID: UUID())   // e.g. a Guest meeting, no talk role
        let roomName = "r4-rock-engine-\(UUID().uuidString.prefix(6))"
        let rock = NativeDesktopRockEngine(sharedAudio: engine)
        rock.admissionForTesting = {
            ("ws://127.0.0.1:7880", SharedEngineRockSpikeTests.token(identity: "rock-talker", room: roomName), "R4")
        }
        try await rock.connect(invitation: URL(string: "https://rock.example.test/jams/r4")!, name: "Talker", quiet: true)
        let attachment = try XCTUnwrap(rock.sharedAttachmentForTesting, "Rock attached to the shared engine")
        XCTAssertTrue(engine.pinnedForProcess, "LiveKit adopted the shared owner's factory")
        XCTAssertEqual(engine.meetingIDs.count, 2)
        XCTAssertEqual(engine.talkMeetingID, attachment.meetingID, "Rock connected first with a permit: it has the talk role")

        let listener = Room(roomOptions: RoomOptions(reportRemoteTrackStatistics: true))
        try await listener.connect(url: "ws://127.0.0.1:7880", token: SharedEngineRockSpikeTests.token(identity: "listener", room: roomName),
                                   connectOptions: ConnectOptions(autoSubscribe: true, enableMicrophone: false))
        defer { Task { await listener.disconnect() } }

        let unmuteStarted = ProcessInfo.processInfo.systemUptime
        try await rock.setMicrophone(true)
        let unmuteSeconds = ProcessInfo.processInfo.systemUptime - unmuteStarted

        XCTAssertTrue(rock.snapshot.microphoneOn)
        XCTAssertTrue(attachment.anySenderEnabled, "Rock's published track is the attachment's sender and is on")
        let track = try await SharedEngineRockSpikeTests.remoteAudio(in: listener)
        try await Task.sleep(for: .seconds(1))
        let silent = try await Self.rate(track, seconds: 1.5)   // no microphone: silence (Opus DTX)

        // The app-audio mixer exists once the input graph is built (after the first publish).
        let tone = MicrophoneMoveTests.tone(seconds: 0.5, frequency: 440, amplitude: 0.3)
        let player = Task { @MainActor in
            while !Task.isCancelled {
                AudioManager.shared.mixer.capture(appAudio: tone)
                try? await Task.sleep(for: .milliseconds(480))
            }
        }
        defer { player.cancel() }
        try await Task.sleep(for: .milliseconds(500))
        let talking = try await Self.rate(track, seconds: 2)

        // Move the talk role to the other meeting: Rock's sender goes off and it unpublishes.
        let moveStarted = ProcessInfo.processInfo.systemUptime
        ok(await rock.setPhysicalInputPermitted(false))
        ok(await other.assumeTalk())
        let moveSeconds = ProcessInfo.processInfo.systemUptime - moveStarted
        XCTAssertFalse(attachment.anySenderEnabled)
        XCTAssertEqual(engine.talkMeetingID, other.meetingID)
        do { try await rock.setMicrophone(true); XCTFail("Rock cannot unmute without the talk role") } catch {}
        let afterMove = try await Self.rate(track, seconds: 1.5)
        let unpublished = listener.remoteParticipants.values.flatMap(\.audioTracks).isEmpty

        // And back.
        ok(await other.relinquishTalk())
        ok(await rock.setPhysicalInputPermitted(true))
        try await rock.setMicrophone(true)
        let back = try await SharedEngineRockSpikeTests.remoteAudio(in: listener)
        try await Task.sleep(for: .milliseconds(500))
        let talkingAgain = try await Self.rate(back, seconds: 2)

        let evidence: [String: Any] = ["silentBytesPerSecond": silent, "talkingBytesPerSecond": talking, "unpublishedAfterMove": unpublished, "afterMoveBytesPerSecond": afterMove,
            "talkingAgainBytesPerSecond": talkingAgain, "unmuteSeconds": unmuteSeconds, "moveSeconds": moveSeconds, "recoveries": engine.recoveries,
            "owner": engine.guestOwner?.snapshot.filter { ["enginesCreated", "engineStarts", "engineStops", "manualRendering"].contains($0.key) } ?? [:]]
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]) {
            print("R4-ROCK-ENGINE \(String(decoding: data, as: UTF8.self))")
        }
        XCTAssertGreaterThan(talking, max(3_000, silent * 2), "The listener hears Rock's tone through the shared owner")
        XCTAssertLessThan(afterMove, talking / 4, "After the move Rock sends nothing")
        XCTAssertTrue(unpublished, "Without the talk role Rock's microphone is unpublished")
        XCTAssertGreaterThan(talkingAgain, max(3_000, silent * 2), "Back with the talk role Rock is heard again")

        // Leaving keeps the pinned owner (LiveKit holds its factory); the other meeting still runs on it.
        ok(await rock.leave())
        XCTAssertNotNil(engine.factory)
        XCTAssertEqual(engine.meetingIDs, [other.meetingID])
        ok(await other.detach())
        XCTAssertNotNil(engine.factory, "The last meeting out idles a pinned owner instead of shutting it down")
        XCTAssertFalse(engine.cleanupFailed)
    }

    /// Bytes a second received on the track; a counter reset (track unpublished) counts as none.
    static func rate(_ track: RemoteAudioTrack, seconds: Double) async throws -> Double {
        func bytes() -> UInt64 { track.statistics?.inboundRtpStream.compactMap(\.bytesReceived).reduce(0, +) ?? 0 }
        let before = bytes(), started = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(seconds))
        let after = bytes()
        return after > before ? Double(after - before) / (ProcessInfo.processInfo.systemUptime - started) : 0
    }

    private func ok(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, message, file: file, line: line)
    }
}
