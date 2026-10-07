import XCTest

final class MeetingContinuationUITests: XCTestCase {
    func testLiveCloudRoundTrip() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Two real iCloud devices are required. Run explicitly with a generated Handoff QA meeting.")
#else
        guard let marker = ProcessInfo.processInfo.environment["CONFERENCE_LIVE_HANDOFF_MARKER"] else {
            throw XCTSkip("Run explicitly with two devices and a generated test meeting.")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_HANDOFF_CLOUD"] = marker
        if let link = ProcessInfo.processInfo.environment["CONFERENCE_LIVE_HANDOFF_SOURCE"] {
            app.launchEnvironment["CONFERENCE_TEST_HANDOFF_SOURCE_LINK"] = link
            app.launch()
            XCTAssertTrue(app.buttons["Unmute microphone"].waitForExistence(timeout: 30))
            XCTAssertTrue(app.staticTexts["Jam moved to Mac."].waitForExistence(timeout: 180))
            attach(app, "Live move from iPhone to Mac")
            return
        }
        app.launch()
        XCTAssertTrue(app.staticTexts["Jam on Mac"].waitForExistence(timeout: 40))
        let move = app.buttons["Continue on this device"]
        XCTAssertTrue(move.waitForExistence(timeout: 10)); move.tap()
        let status = app.descendants(matching: .any)["continuationStatus"]
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", "Microphone and camera are off."), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 60), .completed)
        XCTAssertTrue(app.buttons["Unmute microphone"].exists)
        XCTAssertTrue(app.buttons["Start video"].exists)
        attach(app, "Live move from Mac to iPhone")
        app.buttons["Leave"].tap()
        XCTAssertTrue(app.staticTexts["Left the jam."].waitForExistence(timeout: 15))
#endif
    }
    private func launch(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_HANDOFF_FIXTURE"] = mode
        app.launchEnvironment["CONFERENCE_TEST_SYNC_FIXTURE"] = "available"
        app.launch(); return app
    }
    func testFreshCardTransfersAndStaleCardDoesNotClaimLiveStatus() {
        let app = launch("ready")
        let move = app.buttons["Continue on this device"]
        XCTAssertTrue(move.waitForExistence(timeout: 10)); XCTAssertTrue(move.isHittable)
        XCTAssertTrue(app.staticTexts["Friday quartet"].exists)
        move.tap()
        let moved = app.staticTexts["Jam moved here. Microphone and camera are off."]
        reveal(moved, app); XCTAssertTrue(moved.waitForExistence(timeout: 10))
        let devices = app.buttons["home.devices"]
        reveal(devices, app); devices.tap()
        let stale = app.buttons["Join here"]
        reveal(stale, app)
        XCTAssertTrue(stale.exists); stale.tap()
        XCTAssertTrue(app.staticTexts["Join here without moving the other device?"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        attach(app, "Continue and recent activity")
    }
    func testSharingChoiceIsExplicitAndCardFitsRotation() {
        let app = launch("sharing")
        let move = app.buttons["Move here and stop sharing"]
        XCTAssertTrue(move.waitForExistence(timeout: 10))
        XCTAssertTrue(move.isHittable)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        reveal(move, app); XCTAssertTrue(move.isHittable)
        XCUIDevice.shared.orientation = .portrait
        reveal(move, app); XCTAssertTrue(move.isHittable)
        attach(app, "Sharing continuation choice")
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<4 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }
    private func attach(_ app: XCUIApplication, _ title: String) {
        let item = XCTAttachment(screenshot: app.screenshot()); item.name = title; item.lifetime = .keepAlways; add(item)
    }
}
