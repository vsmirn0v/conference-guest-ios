import ConferenceCore
import Foundation
import XCTest
@testable import RockNativeDesktop

@MainActor final class UniversalEngineArchitectureGateTests: XCTestCase {
    func testArchitectureBoundaryScriptPasses() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Parity
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // NativeMacGuest
            .deletingLastPathComponent() // repo root
        let script = repoRoot.appendingPathComponent("NativeMacGuest/Tests/verify-universal-architecture.py")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path), "Missing executable verify-universal-architecture.py")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path]
        process.currentDirectoryURL = repoRoot
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "Architecture gate failed:\n\(output)")
    }

    func testUniversalEngineRoutesAllFourProvidersWithoutLegacyFallback() async throws {
        let engine = UniversalMeetingEngine(sharedAudio: nil)
        XCTAssertFalse(engine.busy)
        XCTAssertEqual(engine.activeSessionCount, 0)

        let cases: [(kind: MeetingEngineKind, url: String, executor: RecoveryExecutorKind, exclusiveTalk: Bool)] = [
            (.guest, "https://custom.example.test/calls/gate-guest", .guestSession, true),
            (.community, "https://custom.example.test/jams/gate-rock", .liveKitSDK, false),
            (.telemost, "https://telemost.yandex.ru/j/12345678901234", .nativeAdapterSupervisor, false),
            (.trueconf, "https://custom.example.test/c/gate-trueconf?password=secret", .nativeAdapterSupervisor, false),
        ]

        var sessions: [MeetingSession] = []
        for entry in cases {
            let destination = try JoinDestination.verified(URL(string: entry.url)!, engine: entry.kind)
            let session = engine.makeSession(destination: destination, exclusiveTalk: entry.exclusiveTalk)
            sessions.append(session)
            XCTAssertEqual(session.kind, entry.kind)
            XCTAssertEqual(session.sessionSnapshot.recoveryExecutor, entry.executor)
            XCTAssertEqual(session.exclusiveTalk, entry.exclusiveTalk)
            XCTAssertNotNil(engine.session(id: session.id))
            XCTAssertEqual(session.ownershipDiagnostics["provider"] as? String, entry.kind.rawValue)
            XCTAssertEqual(session.ownershipDiagnostics["exclusiveTalk"] as? Bool, entry.exclusiveTalk)
        }

        XCTAssertEqual(Set(sessions.map(\.id)).count, 4)
        XCTAssertTrue(engine.busy)
        XCTAssertEqual(engine.activeSessionCount, 4)

        let diag = engine.ownershipDiagnostics
        XCTAssertEqual(diag["engine"] as? String, "universal-meeting-engine")
        XCTAssertEqual(diag["activeSessionCount"] as? Int, 4)
        let diagSessions = try XCTUnwrap(diag["sessions"] as? [[String: Any]])
        XCTAssertEqual(diagSessions.count, 4)
        XCTAssertTrue(diagSessions.contains {
            $0["provider"] as? String == "guest" && $0["exclusiveTalk"] as? Bool == true
        })

        for session in sessions {
            let clean = await session.leave()
            XCTAssertTrue(clean)
            XCTAssertNil(engine.session(id: session.id))
        }
        XCTAssertEqual(engine.activeSessionCount, 0)
        XCTAssertFalse(engine.busy)
    }
}
