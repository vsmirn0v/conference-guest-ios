import AVFoundation
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

/// R4 S2: Guest meetings on the shared engine through `GuestMeetingAudio`, on the real
/// physical owner (no microphone access needed: nothing here unmutes successfully).
@MainActor final class SharedGuestMeetingAudioTests: XCTestCase {

    func testTwoGuestMeetingsShareOneOwnerAndOnlyTheTalkMeetingMayUnmute() async throws {
        let engine = SharedAudioEngine.live()
        let daily = try await SharedGuestMeetingAudio.attach(to: engine)
        let infra = try await SharedGuestMeetingAudio.attach(to: engine)
        XCTAssertTrue(daily.factory === infra.factory, "One factory for both meetings")

        ok(await daily.setInputPermitted(true), "The first meeting takes the talk role")
        ok(await infra.setInputPermitted(false))
        XCTAssertEqual(daily.snapshot["talkMeeting"] as? Bool, true)
        XCTAssertEqual(infra.snapshot["talkMeeting"] as? Bool, false)
        XCTAssertEqual(infra.snapshot["inputPermitted"] as? Bool, false)
        XCTAssertEqual(daily.snapshot["microphoneMuted"] as? Bool, true)
        XCTAssertEqual(infra.snapshot["microphoneMuted"] as? Bool, true)
        XCTAssertFalse(infra.canUnmuteMicrophone)
        XCTAssertNil(daily.playoutEpoch, "No per-meeting playout gate: it behaves as a disabled one")
        XCTAssertTrue(daily.openSharedPlayout(expected: nil) && daily.sharedPlayoutIsOpen(expected: nil))

        let dailyTrack = Self.track(daily.factory), infraTrack = Self.track(infra.factory)
        dailyTrack.isEnabled = true; infraTrack.isEnabled = true
        daily.registerMicrophoneTrack(dailyTrack); infra.registerMicrophoneTrack(infraTrack)
        XCTAssertFalse(dailyTrack.isEnabled || infraTrack.isEnabled, "Registered tracks start disabled")
        no(await infra.setMicrophoneMuted(false), "A meeting without the talk role cannot unmute")
        XCTAssertFalse(infraTrack.isEnabled)
        ok(await infra.activateMicrophone(), "Activation without the talk role is deferred, not an error")

        // Moving the talk role: the old talk meeting is muted and its track stays off.
        ok(await infra.setInputPermitted(true))
        XCTAssertEqual(infra.snapshot["talkMeeting"] as? Bool, true)
        XCTAssertEqual(daily.snapshot["talkMeeting"] as? Bool, false)
        XCTAssertFalse(dailyTrack.isEnabled)

        // A finished attempt's tracks are turned off and forgotten; the next attempt registers its own.
        ok(await infra.endAttempt(clean: true))
        XCTAssertFalse(infraTrack.isEnabled)
        ok(await infra.beginAttempt(sound: false))
        let next = Self.track(infra.factory); next.isEnabled = true
        infra.registerMicrophoneTrack(next)
        XCTAssertFalse(next.isEnabled)
        no(await infra.endAttempt(clean: false), "An unclean attempt reports failure")
        XCTAssertFalse(next.isEnabled)

        ok(await daily.shutdown()); ok(await infra.shutdown())
        XCTAssertFalse(engine.cleanupFailed)
        XCTAssertNotNil(GuestAudioOwnerLease(privateCheck: true), "The last meeting out released the owner")
    }

    func testMeetingVolumeIsPerMeetingAndReappliedBySession() async throws {
        let engine = SharedAudioEngine.live()
        let daily = try await SharedGuestMeetingAudio.attach(to: engine)
        let infra = try await SharedGuestMeetingAudio.attach(to: engine)
        var reapplied = 0
        daily.onLevelChange = { reapplied += 1 }
        XCTAssertTrue(daily.setMeetingVolume(0.3))
        XCTAssertEqual(daily.meetingLevel, 0.3, accuracy: 1e-9)
        XCTAssertEqual(infra.meetingLevel, 1, "Another meeting's level is untouched")
        XCTAssertEqual(reapplied, 1)
        XCTAssertTrue(daily.setMeetingVolume(.nan)); XCTAssertEqual(daily.meetingLevel, 1)
        ok(await daily.setPlayoutEnabled(true, expectedEpoch: nil))
        XCTAssertEqual(daily.snapshot["meetingSound"] as? Bool, true)
        XCTAssertEqual(infra.snapshot["meetingSound"] as? Bool, false)
        ok(await daily.setPlayoutEnabled(false, expectedEpoch: nil))
        ok(await daily.shutdown()); ok(await infra.shutdown())
    }

    /// Telemost/TrueConf: received tracks follow this meeting's sound and volume only.
    func testReceivedTracksFollowTheirMeetingAndRetireWithTheirGeneration() async throws {
        let engine = SharedAudioEngine.live()
        let telemost = try await SharedGuestMeetingAudio.attach(to: engine)
        let trueconf = try await SharedGuestMeetingAudio.attach(to: engine)
        let factory = telemost.factory
        // Volume applies only to received (remote) sources, so record what is written.
        var anna = -1.0, boris = -1.0
        telemost.addReceived(id: "0") { anna = $0 }; trueconf.addReceived(id: "0") { boris = $0 }
        XCTAssertEqual(anna, 0, "Sound starts off"); XCTAssertEqual(boris, 0)
        ok(await telemost.setPlayoutEnabled(true, expectedEpoch: nil))
        XCTAssertEqual(anna, 1); XCTAssertEqual(boris, 0, "Other meeting stays silent")
        XCTAssertTrue(telemost.setMeetingVolume(0.5))
        XCTAssertEqual(anna, 0.5, accuracy: 1e-6)

        let microphone = factory.audioTrack(with: factory.audioSource(with: nil), trackId: "microphone")
        telemost.registerMicrophoneTrack(microphone)
        telemost.retireTracks()
        XCTAssertFalse(microphone.isEnabled)
        XCTAssertTrue(telemost.setMeetingVolume(1))
        XCTAssertEqual(anna, 0.5, accuracy: 1e-6, "A retired generation's track is no longer managed")
        ok(await telemost.shutdown()); ok(await trueconf.shutdown())
    }

    /// Guarantee 10 on the real owner: four meetings, the talk role moving round them; the
    /// module really activates and unmutes (manual rendering: no device is opened).
    func testFourMeetingsShareOneOwnerAndOnlyTheTalkMeetingSends() async throws {
        GuestSystemAudio.microphoneAuthorizationOverrideForTesting = true
        defer { GuestSystemAudio.microphoneAuthorizationOverrideForTesting = nil }
        let engine = SharedAudioEngine.live(manualRenderingForTesting: true)
        var meetings: [SharedGuestMeetingAudio] = [], tracks: [LKRTCAudioTrack] = []
        for _ in 0..<4 {
            let meeting = try await SharedGuestMeetingAudio.attach(to: engine)
            let track = Self.track(meeting.factory); meeting.registerMicrophoneTrack(track)
            meetings.append(meeting); tracks.append(track)
        }
        XCTAssertTrue(meetings.allSatisfy { $0.factory === meetings[0].factory })
        for round in 0..<8 {
            let talk = round % 4
            for (index, meeting) in meetings.enumerated() where index != talk { ok(await meeting.setInputPermitted(false)) }
            ok(await meetings[talk].setInputPermitted(true))
            ok(await meetings[talk].activateMicrophone())
            ok(await meetings[talk].setMicrophoneMuted(false), "round \(round)")
            XCTAssertEqual(tracks.map(\.isEnabled), (0..<4).map { $0 == talk }, "round \(round)")
            XCTAssertEqual(meetings.map { $0.snapshot["microphoneMuted"] as? Bool }, (0..<4).map { $0 != talk }, "round \(round)")
        }
        ok(await meetings[3].setMicrophoneMuted(true))
        XCTAssertFalse(tracks.contains { $0.isEnabled })
        for meeting in meetings { ok(await meeting.shutdown()) }
        XCTAssertFalse(engine.cleanupFailed)
    }

    /// Records which path this test process runs (`R4_SHARED_AUDIO_ENGINE`).
    func testReportsWhetherTheSharedEngineIsOn() {
        print("R4-SHARED-AUDIO-ENGINE=\(SharedAudioEngine.enabledAtLaunch)")
        if let forced = ProcessInfo.processInfo.environment["R4_SHARED_AUDIO_ENGINE"] {
            XCTAssertEqual(SharedAudioEngine.enabledAtLaunch, forced == "1")
        }
    }

    private static func track(_ factory: LKRTCPeerConnectionFactory) -> LKRTCAudioTrack {
        factory.audioTrack(with: factory.audioSource(with: nil), trackId: UUID().uuidString)
    }
    private func ok(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, message, file: file, line: line)
    }
    private func no(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(value, message, file: file, line: line)
    }
}
