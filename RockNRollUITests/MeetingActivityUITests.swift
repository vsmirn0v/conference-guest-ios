import XCTest

final class MeetingActivityUITests: XCTestCase {
    func testRealActivityLifecycleAndBackgroundReturn() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "meeting-activity"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); defer { app.terminate() }
        let status = app.staticTexts["activity-fixture.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        if status.label == "unavailable" { throw XCTSkip("ActivityKit unavailable on this runtime") }
        func expect(_ value: String) {
            let e = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value), object: status)
            XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: 20), .completed,
                           "Actual ActivityKit content: \(status.label); requested: \(status.value ?? "none")")
        }
        app.buttons["activity-fixture.start"].tap(); expect("1|muted|connected")
        app.buttons["activity-fixture.microphone"].tap(); expect("1|on|connected")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 5))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Meeting Live Activity outside the app"; attachment.lifetime = .keepAlways; add(attachment)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        // Simulator reports foreground before SpringBoard finishes accepting
        // touches in the activated window. This wait belongs only to the harness.
        Thread.sleep(forTimeInterval: 1)
        app.buttons["activity-fixture.reconnect"].tap(); expect("1|paused|reconnecting")
        app.buttons["activity-fixture.recover"].tap(); expect("1|muted|connected")
        app.buttons["activity-fixture.end"].tap(); expect("0|none|none")
    }
}
