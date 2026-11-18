import ConferenceCore
import XCTest
@testable import MeetingEngine

@MainActor
final class UniversalMeetingEngineTests: XCTestCase {
    func testConfigurationParsesProviderFilter() {
        let all = UniversalMeetingEngine.Configuration.current(environment: [:])
        XCTAssertEqual(all.enabledProviders, [.guest, .community, .telemost, .trueconf])

        let subset = UniversalMeetingEngine.Configuration.current(environment: [
            "ROCK_UNIVERSAL_PROVIDERS": "guest, trueconf",
        ])
        XCTAssertEqual(subset.enabledProviders, [.guest, .trueconf])
    }

    func testCreatesSessionsForAllFourProviders() throws {
        let engine = UniversalMeetingEngine(sharedAudio: nil)
        let urls = [
            "https://jazz.example.com/room-guest?psw=secret123",
            "https://rock.glowsoft.ru/jams/rock-room",
            "https://telemost.yandex.ru/j/1234567890",
            "https://trueconf.example.com/c/1234567890",
        ]
        let expectedKinds: [MeetingEngineKind] = [.guest, .community, .telemost, .trueconf]
        let kinds = [MeetingEngineKind.guest, .community, .telemost, .trueconf]

        var retained: [MeetingSession] = []
        for ((raw, kind), expected) in zip(zip(urls, kinds), expectedKinds) {
            let destination = try JoinDestination.verified(URL(string: raw)!, engine: kind)
            let session = engine.makeSession(destination: destination)
            XCTAssertEqual(session.kind, expected)
            retained.append(session)
        }
        XCTAssertEqual(engine.activeSessionCount, 4)

        retained.removeAll()
        XCTAssertEqual(engine.activeSessionCount, 0)
    }

    func testLobbySnapshotDefaultsAndPhase() {
        let lobby = GuestLobbyState(inLobby: true, title: "Weekly Sync", moderatorPresent: true)
        XCTAssertTrue(lobby.inLobby)
        XCTAssertEqual(lobby.title, "Weekly Sync")
        XCTAssertEqual(lobby.moderatorPresent, true)

        let snapshot = GuestSessionSnapshot(
            state: .lobby,
            desiredIntent: nil,
            appliedIntent: nil,
            permissions: .init(canShareMicrophone: true, canShareCamera: true),
            recoveryAttempts: 0,
            failure: nil,
            microphoneActivated: false,
            desiredPlayoutEnabled: nil,
            appliedPlayoutEnabled: nil,
            lobbyTitle: lobby.title,
            lobbyModeratorPresent: lobby.moderatorPresent
        )
        XCTAssertEqual(snapshot.state, .lobby)
        XCTAssertEqual(snapshot.lobbyTitle, "Weekly Sync")
        XCTAssertEqual(snapshot.lobbyModeratorPresent, true)

        var external = NativeDesktopExternalSnapshot(phase: .lobby, lobbyModeratorPresent: false)
        XCTAssertEqual(external.phase, .lobby)
        XCTAssertEqual(external.lobbyModeratorPresent, false)
        external.phase = .connected
        XCTAssertEqual(external.phase, .connected)
    }
}
