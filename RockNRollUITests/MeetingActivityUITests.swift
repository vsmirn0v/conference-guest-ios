import XCTest

final class MeetingActivityUITests: XCTestCase {
    func testPhysicalNativeReminderIsDeliveredAfterAppTermination() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical notification delivery after termination")
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["CONFERENCE_TEST_UI_FIXTURE": "meeting-activity",
            "CONFERENCE_TEST_ACTIVITY_COEXISTENCE": "1", "CONFERENCE_TEST_ACTIVITY_REMINDER_ID": UUID().uuidString]
        app.launch()
        defer {
            app.launch()
            if app.buttons["activity-fixture.end"].waitForExistence(timeout: 5) { app.buttons["activity-fixture.end"].tap() }
            app.terminate()
        }
        app.buttons["Schedule device reminder"].tap()
        let status = app.staticTexts["activity-fixture.notification"]
        let scheduled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'scheduled'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [scheduled], timeout: 10), .completed)
        app.terminate(); XCUIDevice.shared.press(.home)
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(system.staticTexts["Rock device reminder verification"].firstMatch.waitForExistence(timeout: 30))
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "Native reminder delivered with app terminated"; capture.lifetime = .keepAlways; add(capture)
    }
    func testPhysicalActivityPiPAndNativeReminderCoexist() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical system PiP and notification delivery qualification")
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["CONFERENCE_TEST_UI_FIXTURE": "meeting-activity",
            "CONFERENCE_TEST_ACTIVITY_COEXISTENCE": "1", "CONFERENCE_TEST_RESET_FLOATING_VIDEO": "1"]
        app.launch(); defer {
            app.activate()
            if app.buttons["activity-fixture.end"].exists { app.buttons["activity-fixture.end"].tap() }
            app.terminate()
        }
        let status = app.staticTexts["activity-fixture.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        app.buttons["activity-fixture.start"].tap()
        let active = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '1|muted|connected'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [active], timeout: 10), .completed)
        app.buttons["Schedule device reminder"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let reminder = app.staticTexts["activity-fixture.notification"]
        let scheduled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'scheduled'"), object: reminder)
        XCTAssertEqual(XCTWaiter.wait(for: [scheduled], timeout: 5), .completed)
        app.buttons["energy.start-pip"].tap(); XCUIDevice.shared.press(.home)
        let pip = springboard.windows["PIP-SBInteractionPassThroughView"]
        XCTAssertTrue(pip.waitForExistence(timeout: 10))
        let first = pip.screenshot().pngRepresentation
        Thread.sleep(forTimeInterval: 24)
        XCTAssertTrue(pip.exists)
        XCTAssertNotEqual(first, pip.screenshot().pngRepresentation)
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "Physical Live Activity with moving PiP and native reminder"; capture.lifetime = .keepAlways; add(capture)
        app.activate()
        let delivered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'delivered'"), object: reminder)
        XCTAssertEqual(XCTWaiter.wait(for: [delivered], timeout: 5), .completed, "Background native delivery: \(reminder.label)")
        app.buttons["energy.end-pip"].tap(); app.buttons["activity-fixture.end"].tap()
        XCUIDevice.shared.press(.home); Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(pip.exists)
    }
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
