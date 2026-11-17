import ConferenceCore
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

@MainActor final class UniversalEngineConcurrencyTests: XCTestCase {
    private static let providerURLs: [(kind: MeetingEngineKind, url: URL)] = [
        (.guest, URL(string: "https://custom.example.test/calls/concurrency-guest")!),
        (.community, URL(string: "https://custom.example.test/jams/concurrency-rock")!),
        (.telemost, URL(string: "https://telemost.yandex.ru/j/12345678901234")!),
        (.trueconf, URL(string: "https://custom.example.test/c/concurrency-trueconf?password=secret")!),
    ]

    private static func makeTrack(_ factory: LKRTCPeerConnectionFactory) -> LKRTCAudioTrack {
        factory.audioTrack(with: factory.audioSource(with: nil), trackId: UUID().uuidString)
    }

    private func ok(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, message, file: file, line: line)
    }

    /// Exercises all 16 ordered pairs (12 cross-provider + 4 same-provider) A -> B -> A
    /// talk handovers on one SharedAudioEngine + UniversalMeetingEngine.
    func testAllSixteenProviderPairsHandOverTalkExclusively() async throws {
        GuestSystemAudio.microphoneAuthorizationOverrideForTesting = true
        defer { GuestSystemAudio.microphoneAuthorizationOverrideForTesting = nil }

        let shared = SharedAudioEngine.live(manualRenderingForTesting: true)
        let engine = UniversalMeetingEngine(sharedAudio: shared)

        for firstSpec in Self.providerURLs {
            for secondSpec in Self.providerURLs {
                let firstSession = engine.makeSession(destination: try JoinDestination.verified(firstSpec.url, engine: firstSpec.kind))
                let secondSession = engine.makeSession(destination: try JoinDestination.verified(secondSpec.url, engine: secondSpec.kind))

                let firstAudio = try await SharedGuestMeetingAudio.attach(to: shared, meetingID: firstSession.id)
                let secondAudio = try await SharedGuestMeetingAudio.attach(to: shared, meetingID: secondSession.id)
                XCTAssertTrue(firstAudio.factory === secondAudio.factory, "Pair \(firstSpec.kind)->\(secondSpec.kind) must share one factory")

                let firstTrack = Self.makeTrack(firstAudio.factory)
                let secondTrack = Self.makeTrack(secondAudio.factory)
                firstAudio.registerMicrophoneTrack(firstTrack)
                secondAudio.registerMicrophoneTrack(secondTrack)
                XCTAssertFalse(firstTrack.isEnabled)
                XCTAssertFalse(secondTrack.isEnabled)

                let epoch0 = shared.talkEpoch
                ok(await firstAudio.setInputPermitted(true))
                let epoch1 = shared.talkEpoch
                XCTAssertGreaterThan(epoch1, epoch0)
                ok(await firstAudio.activateMicrophone())
                ok(await firstAudio.setMicrophoneMuted(false))
                XCTAssertTrue(firstTrack.isEnabled, "\(firstSpec.kind) must send when holding talk")
                XCTAssertFalse(secondTrack.isEnabled, "\(secondSpec.kind) must stay silent without talk")

                // Handover A -> B
                ok(await secondAudio.setInputPermitted(true))
                let epoch2 = shared.talkEpoch
                XCTAssertGreaterThan(epoch2, epoch1)
                XCTAssertFalse(firstTrack.isEnabled, "\(firstSpec.kind) must immediately disable sender on talk loss")
                XCTAssertFalse(secondTrack.isEnabled, "\(secondSpec.kind) must arrive muted until explicit unmute")
                ok(await secondAudio.activateMicrophone())
                ok(await secondAudio.setMicrophoneMuted(false))
                XCTAssertFalse(firstTrack.isEnabled)
                XCTAssertTrue(secondTrack.isEnabled, "\(secondSpec.kind) must send after assuming talk + unmute")

                // Handover B -> A
                ok(await firstAudio.setInputPermitted(true))
                let epoch3 = shared.talkEpoch
                XCTAssertGreaterThan(epoch3, epoch2)
                XCTAssertFalse(secondTrack.isEnabled)
                XCTAssertFalse(firstTrack.isEnabled)
                ok(await firstAudio.activateMicrophone())
                ok(await firstAudio.setMicrophoneMuted(false))
                XCTAssertTrue(firstTrack.isEnabled)
                XCTAssertFalse(secondTrack.isEnabled)

                ok(await firstAudio.shutdown())
                ok(await secondAudio.shutdown())
                ok(await firstSession.leave())
                ok(await secondSession.leave())
            }
        }

        XCTAssertEqual(engine.activeSessionCount, 0)
        XCTAssertFalse(engine.busy)
        XCTAssertFalse(shared.busy)
        XCTAssertEqual(shared.ownershipDiagnostics["attachmentCount"] as? Int, 0)
    }

    /// Runs all 4 providers simultaneously and triggers a shared-device stop/start rebuild.
    func testFourSimultaneousProvidersSurviveDeviceRebuildWithTalkPreserved() async throws {
        GuestSystemAudio.microphoneAuthorizationOverrideForTesting = true
        defer { GuestSystemAudio.microphoneAuthorizationOverrideForTesting = nil }

        let shared = SharedAudioEngine.live(manualRenderingForTesting: true)
        let engine = UniversalMeetingEngine(sharedAudio: shared)

        var sessions: [MeetingSession] = []
        var audios: [SharedGuestMeetingAudio] = []
        var tracks: [LKRTCAudioTrack] = []
        for spec in Self.providerURLs {
            let session = engine.makeSession(destination: try JoinDestination.verified(spec.url, engine: spec.kind))
            let audio = try await SharedGuestMeetingAudio.attach(to: shared, meetingID: session.id)
            let track = Self.makeTrack(audio.factory)
            audio.registerMicrophoneTrack(track)
            sessions.append(session)
            audios.append(audio)
            tracks.append(track)
        }

        XCTAssertEqual(engine.activeSessionCount, 4)
        XCTAssertEqual(shared.ownershipDiagnostics["attachmentCount"] as? Int, 4)
        XCTAssertTrue(audios.allSatisfy { $0.factory === audios[0].factory })

        // Assign talk to Rock (.community at index 1) and unmute.
        let talkIndex = 1
        ok(await audios[talkIndex].setInputPermitted(true))
        ok(await audios[talkIndex].activateMicrophone())
        ok(await audios[talkIndex].setMicrophoneMuted(false))
        XCTAssertEqual(tracks.map(\.isEnabled), [false, true, false, false])

        // Device/route rebuild silences all senders until restarted, then restores only talk owner.
        let stopped = await shared.engineChanged(.stopped)?.value
        XCTAssertEqual(stopped, true)
        XCTAssertTrue(shared.rebuilding)
        XCTAssertEqual(tracks.map(\.isEnabled), [false, false, false, false])

        let started = await shared.engineChanged(.started)?.value
        XCTAssertEqual(started, true)
        XCTAssertFalse(shared.rebuilding)
        XCTAssertEqual(shared.recoveries, 1)
        XCTAssertEqual(shared.ownershipDiagnostics["attachmentCount"] as? Int, 4)
        XCTAssertEqual(tracks.map(\.isEnabled), [false, true, false, false])
        XCTAssertEqual(shared.talkMeetingID, sessions[talkIndex].id)

        for audio in audios { ok(await audio.shutdown()) }
        for session in sessions { ok(await session.leave()) }
        XCTAssertEqual(engine.activeSessionCount, 0)
        XCTAssertFalse(engine.busy)
        XCTAssertFalse(shared.busy)
        XCTAssertEqual(shared.ownershipDiagnostics["attachmentCount"] as? Int, 0)
    }

    /// Verifies 20 join/leave cycles per provider (80 total) drain all sessions and attachments to 0.
    func testTwentyJoinLeaveCyclesPerProviderDrainToZero() async throws {
        GuestSystemAudio.microphoneAuthorizationOverrideForTesting = true
        defer { GuestSystemAudio.microphoneAuthorizationOverrideForTesting = nil }

        let shared = SharedAudioEngine.live(manualRenderingForTesting: true)
        let engine = UniversalMeetingEngine(sharedAudio: shared)

        for spec in Self.providerURLs {
            for _ in 0..<20 {
                let session = engine.makeSession(destination: try JoinDestination.verified(spec.url, engine: spec.kind))
                let audio = try await SharedGuestMeetingAudio.attach(to: shared, meetingID: session.id)
                let track = Self.makeTrack(audio.factory)
                audio.registerMicrophoneTrack(track)
                ok(await audio.setInputPermitted(true))
                ok(await audio.activateMicrophone())
                ok(await audio.setMicrophoneMuted(false))
                XCTAssertTrue(track.isEnabled)
                ok(await audio.shutdown())
                XCTAssertFalse(track.isEnabled)
                ok(await session.leave())
            }
        }

        XCTAssertEqual(engine.activeSessionCount, 0)
        XCTAssertFalse(engine.busy)
        XCTAssertFalse(shared.busy)
        XCTAssertEqual(shared.ownershipDiagnostics["attachmentCount"] as? Int, 0)
    }
}
