import XCTest

final class RoomSyncUITests: XCTestCase {
    private func launch(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_SYNC_FIXTURE"] = mode
        app.launch()
        return app
    }
    func testOptionalSyncSettingsAndInitialNameChoice() {
        let app = launch("available")
        app.buttons["Profile and settings"].tap()
        let enabled = app.switches["Sync with iCloud"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 8))
        XCTAssertEqual(enabled.value as? String, "0")
        toggle(enabled)
        let cloudName = app.buttons["Use iCloud name: Ani"]
        reveal(cloudName, in: app)
        XCTAssertTrue(cloudName.waitForExistence(timeout: 10))
        cloudName.tap()
        let name = app.textFields["Your name"]
        reveal(name, in: app, down: true)
        XCTAssertEqual(name.value as? String, "Ani")
        let recent = app.switches["Include recent jams"]
        reveal(recent, in: app)
        XCTAssertEqual(recent.value as? String, "1")
        toggle(recent); XCTAssertEqual(recent.value as? String, "0")
        app.buttons["Sync now"].tap()
        XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 5))
        reveal(enabled, in: app); toggle(enabled); XCTAssertEqual(enabled.value as? String, "0")
        XCTAssertTrue(app.staticTexts["Stored on this device"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Edit your name, currently Ani"].waitForExistence(timeout: 5))
        attach(app, "Optional iCloud sync")
    }
    func testUnavailableCloudDoesNotBlockJoiningAndSettingsFitRotation() {
        let app = launch("unavailable")
        app.buttons["Profile and settings"].tap()
        let enabled = app.switches["Sync with iCloud"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 8)); toggle(enabled)
        XCTAssertTrue(app.staticTexts["iCloud unavailable. Your changes stay on this device."].waitForExistence(timeout: 8))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Done"].isHittable)
        XCUIDevice.shared.orientation = .portrait
        let settled = NSPredicate { _, _ in app.frame.width < app.frame.height && app.buttons["Done"].frame.maxX <= app.frame.width }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 5), .completed)
        app.buttons["Done"].tap()
        let closed = NSPredicate { _, _ in !app.navigationBars["Profile and settings"].exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: closed, object: nil)], timeout: 5), .completed)
        let invite = app.textFields["Invitation link"]
        invite.tap(); invite.typeText("https://rock.glowsoft.ru/jams/test")
        XCTAssertTrue(app.buttons["Join jam"].isEnabled)
        XCTAssertTrue(app.buttons["Edit your name, currently Aram"].exists)
        attach(app, "Joining remains available offline")
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func toggle(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, down: Bool = false) {
        for _ in 0..<4 {
            if element.exists && element.isHittable { return }
            if down { app.swipeDown() } else { app.swipeUp() }
        }
    }
}
