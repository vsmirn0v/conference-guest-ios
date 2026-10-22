import ConferenceCore
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class MacMeetingLiveTests: XCTestCase {
    func testFreshProcessIdleMenuSchedulesWhileWindowIsHidden() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              let seconds = Double(ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_SCHEDULE_SECONDS"] ?? ""), seconds >= 5 else {
            throw XCTSkip("Opt-in fresh-process hidden calendar timing qualification")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try XCTUnwrap((scene.delegate as? SceneDelegate)?.window)
        let preferences = UserDefaults(suiteName: "MacScheduleLive-" + UUID().uuidString)!
        preferences.set(true, forKey: "calendarMeetings.enabled"); preferences.set(["work"], forKey: "calendarMeetings.selected")
        let due = Date().addingTimeInterval(seconds)
        let event = CalendarMeeting(id: "native-idle", seriesID: "native-idle", calendarID: "work", calendarTitle: "QA",
            title: "Local calendar timing check", start: due, end: due.addingTimeInterval(60),
            links: [URL(string: "https://jazz.example.test/calls/room")!])
        let reader = CalendarMeetingStoreTests.Reader(events: [event])
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CalendarMeetingStoreTests.Response.self]
        let reminders = CalendarReminderCoordinator(preferences: preferences, storage: CalendarReminderTests.Storage(), notifications: CalendarReminderTests.Notifications())
        let calendar = CalendarMeetingStore(reader: reader, detector: MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: config)),
            preferences: preferences, storage: RoomSyncCoordinatorTests.Storage(), reminders: reminders)
        calendar.setAutomaticJoinMode(.scheduled); calendar.canAutomaticallyJoin = { _ in true }
        let session = MeetingSessionStub(); session.desktopMeetingActive = false; session.isInConference = false; session.desktopCalendar = calendar
        let desktop = MacMeetingCoordinator(model: session, window: window, audioDevices: MacAudioDevices(isMac: false))
        defer { calendar.setEnabled(false); desktop.showForTesting(); desktop.invalidate() }
        desktop.becameActive()
        for _ in 0..<30 where desktop.stateForTesting["bound"] as? Bool != true { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(desktop.stateForTesting["bound"] as? Bool, true)
        XCTAssertEqual(desktop.stateForTesting["schedulingAvailable"] as? Bool, true)
        let joined = expectation(description: "Scheduled boundary executes without foreground activation")
        var joinedAt: Date?
        calendar.onScheduledJoin = { _ in joinedAt = Date(); joined.fulfill() }
        try await MacCalendarSchedulingTests().ready(calendar)
        desktop.closeForTesting(); calendar.backgrounded()
        XCTAssertEqual(desktop.stateForTesting["hidden"] as? Bool, true)
        let frontmost = desktop.stateForTesting["frontmostPID"] as? Int
        print("MAC_IDLE_SCHEDULE_ARMED due=\(due) seconds=\(seconds) frontmost=\(String(describing: frontmost)) pid=\(getpid())")
        await fulfillment(of: [joined], timeout: seconds + 20)
        let elapsed = try XCTUnwrap(joinedAt).timeIntervalSince(due)
        XCTAssertGreaterThanOrEqual(elapsed, 4); XCTAssertLessThan(elapsed, 10)
        XCTAssertEqual(desktop.stateForTesting["hidden"] as? Bool, true)
        XCTAssertEqual(desktop.stateForTesting["frontmostPID"] as? Int, frontmost)
        XCTAssertNotEqual(frontmost, Int(getpid()))
        print("MAC_IDLE_SCHEDULE_VERIFIED lateness_seconds=\(elapsed) state=\(desktop.stateForTesting)")
    }

    func testLiveGuestMediaSurvivesCloseAndRestoreWithoutJoiningAgain() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              let invite = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_BACKGROUND_INVITE"] else {
            throw XCTSkip("Requires Mac UI activation and a disposable room with synthetic media")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let model = try XCTUnwrap((scene.delegate as? SceneDelegate)?.meetingForTesting)
        let desktop = try XCTUnwrap((scene.delegate as? SceneDelegate)?.macMeetingForTesting)
        defer { desktop.showForTesting(); model.leave() }
        // Qualify the actual native Close button and menu with an independent media sender.
        print("MAC_BACKGROUND_WINDOW_READY pid=\(getpid())")
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while desktop.stateForTesting["bound"] as? Bool != true, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(100))
        }
        guard desktop.stateForTesting["bound"] as? Bool == true else {
            XCTFail("Native test window did not bind: \(desktop.stateForTesting)"); return
        }
        model.testDisplayNameOverride = "Mac window QA"
        model.receive(url: try XCTUnwrap(URL(string: invite))); model.join()
        let joinDeadline = ProcessInfo.processInfo.systemUptime + 50
        while !model.isInConference, !model.statusIsError, ProcessInfo.processInfo.systemUptime < joinDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(model.isInConference, model.status)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(desktop.stateForTesting["statusItem"] as? Bool, true)
        let session = model.desktopSessionToken
        var before: [[String: Any]] = []
        func received(_ rows: [[String: Any]], kind: String) -> Int64 {
            rows.filter { $0["type"] as? String == "inbound-rtp" && $0["kind"] as? String == kind }
                .reduce(0) { $0 + (($1["bytesReceived"] as? NSNumber)?.int64Value ?? 0) }
        }
        let mediaDeadline = ProcessInfo.processInfo.systemUptime + 30
        repeat {
            before = await GuestMicrophoneProbe.codecEvidenceForTesting()
            if received(before, kind: "audio") > 0 && received(before, kind: "video") > 0 { break }
            try await Task.sleep(for: .milliseconds(200))
        } while ProcessInfo.processInfo.systemUptime < mediaDeadline
        guard received(before, kind: "audio") > 0, received(before, kind: "video") > 0 else {
            XCTFail("Synthetic audio/video baseline did not arrive: \(before)"); return
        }
        print("MAC_BACKGROUND_MEETING_READY session=\(session)")
        let manualSeconds = Double(ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_BACKGROUND_MANUAL_SECONDS"] ?? "0") ?? 0
        if manualSeconds > 0 { try await Task.sleep(for: .seconds(min(manualSeconds, 300))) }
        XCTAssertTrue(desktop.menuActionForTesting("show"))
        try await Task.sleep(for: .milliseconds(500))
        desktop.closeForTesting()
        try await Task.sleep(for: .seconds(4))
        XCTAssertTrue(model.isInConference)
        XCTAssertEqual(desktop.stateForTesting["hidden"] as? Bool, true)
        XCTAssertEqual(model.desktopSessionToken, session)
        let after = await GuestMicrophoneProbe.codecEvidenceForTesting()
        XCTAssertGreaterThan(received(after, kind: "audio"), received(before, kind: "audio"))
        // Video may deliberately unsubscribe while hidden if there is no PiP.
        // Restoring the window must resume fresh frames, never require a rejoin.
        desktop.showForTesting()
        let resumeDeadline = ProcessInfo.processInfo.systemUptime + 15
        var restored: [[String: Any]] = []
        repeat {
            restored = await GuestMicrophoneProbe.codecEvidenceForTesting()
            if received(restored, kind: "video") > 0 { break }
            try await Task.sleep(for: .milliseconds(200))
        } while ProcessInfo.processInfo.systemUptime < resumeDeadline
        XCTAssertGreaterThan(received(restored, kind: "video"), 0)
        try await Task.sleep(for: .seconds(1))
        let moving = await GuestMicrophoneProbe.codecEvidenceForTesting()
        XCTAssertGreaterThan(received(moving, kind: "video"), received(restored, kind: "video"))
        XCTAssertEqual(model.desktopSessionToken, session)
        // AppKit's normal Close command reaches the delegate backstop too.
        desktop.closeThroughDelegateForTesting()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(desktop.stateForTesting["hidden"] as? Bool, true)
        XCTAssertTrue(model.isInConference)
        XCTAssertTrue(desktop.menuActionForTesting("show"))
        XCTAssertEqual(model.desktopSessionToken, session)
        print("MAC_BACKGROUND_MEDIA_VERIFIED audio_bytes=\(received(after, kind: "audio")) restored_video_bytes=\(received(moving, kind: "video"))")
    }
}
