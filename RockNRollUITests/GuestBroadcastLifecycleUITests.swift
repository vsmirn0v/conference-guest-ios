import XCTest

final class GuestBroadcastLifecycleUITests: XCTestCase {
    func testLeaveWhileSharingDoesNotOpenStopPickerOrErrorAlert() throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_BROADCAST"] == "1",
              let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_INVITE"] else {
            throw XCTSkip("Requires an unlocked physical iOS 27 device and a browser receiver.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("System-wide capture requires a physical device.")
        #else
        guard #available(iOS 27.0, *) else { throw XCTSkip("Requires native system capture on iOS 27.") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invitation
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Capture Lifecycle QA"
        app.launch()
        addTeardownBlock { if app.buttons["Leave"].exists { app.buttons["Leave"].tap() } }
        XCTAssertTrue(app.buttons["Share screen"].waitForExistence(timeout: 60))
        func startShare() {
            app.buttons["Share screen"].tap()
            let systemShare = system.buttons["Share Entire Screen"]
            let appShare = app.buttons["Share Entire Screen"]
            if systemShare.waitForExistence(timeout: 5) { systemShare.tap() }
            else if appShare.exists { appShare.tap() }
            else { print("SHARE_LIFECYCLE_PICKER_NEEDS_USER\n\(system.debugDescription)") }
            XCTAssertTrue(app.buttons["Stop sharing screen"].waitForExistence(timeout: 60))
            app.activate() // The system chooser owns foreground focus after selection.
            sleep(5) // Allow the system capture transition to relinquish touches.
        }
        startShare()
        app.buttons["Stop sharing screen"].tap()
        XCTAssertTrue(app.buttons["Share screen"].waitForExistence(timeout: 10))
        startShare()
        XCUIDevice.shared.press(.home)
        print("SHARE_LIFECYCLE_RECEIVER_CHECK")
        sleep(20) // Leave time to verify real Home Screen pixels at the receiver.
        app.activate()
        XCTAssertTrue(app.buttons["Stop sharing screen"].exists)
        XCTAssertTrue(app.staticTexts["Last shared frame · Preview paused"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Local shared screen thumbnail"].isHittable)
        XCTAssertLessThanOrEqual(app.buttons["Local shared screen thumbnail"].frame.height, 85)
        XCTAssertLessThan(app.otherElements["Local sharing preview card"].frame.height, 250)
        let sharing = XCTAttachment(screenshot: app.screenshot())
        sharing.name = "Active guest capture"
        sharing.lifetime = .keepAlways
        add(sharing)
        app.buttons["Enlarge local sharing preview"].tap()
        XCTAssertTrue(app.buttons["Close preview"].waitForExistence(timeout: 5))
        app.buttons["Close preview"].tap()
        app.buttons["Hide local preview"].tap()
        XCTAssertFalse(app.buttons["Local shared screen thumbnail"].exists)
        XCTAssertTrue(app.buttons["Stop local screen sharing"].isHittable)
        app.buttons["Show local preview"].tap()
        XCTAssertTrue(app.buttons["Local shared screen thumbnail"].isHittable)
        app.buttons["Leave"].tap()
        XCTAssertTrue(app.buttons["Join jam"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Local shared screen thumbnail"].exists)
        sleep(15) // Catch the delayed ReplayKit error from the original regression.
        XCTAssertFalse(system.alerts.containing(NSPredicate(format: "label CONTAINS[c] 'Screen'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Share Entire Screen"].exists)
        XCTAssertFalse(system.buttons["Stop Broadcast"].exists)
        let stopped = XCTAttachment(screenshot: system.screenshot())
        stopped.name = "After leave — no broadcast picker or failure alert"
        stopped.lifetime = .keepAlways
        add(stopped)
        #endif
    }
}
