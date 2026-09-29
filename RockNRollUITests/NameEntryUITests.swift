import XCTest

final class NameEntryUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")

    func testFirstJoinRequestsNameAndRemembersItAfterRestart() {
        app.launchEnvironment["CONFERENCE_TEST_CLEAR_NAME"] = "1"
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Add your name"].waitForExistence(timeout: 10))
        join("https://rock.glowsoft.ru/jams/test")
        let field = app.textFields["Name shown to musicians"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Name shown to musicians")
        let continueButton = app.navigationBars.buttons["Join jam"]
        XCTAssertFalse(continueButton.isEnabled)
        field.tap()
        field.typeText("Ani First Join")
        continueButton.tap()
        assertParticipant("Ani First Join")
        app.navigationBars["Musicians"].buttons["Done"].tap()
        app.buttons["Leave"].tap()
        XCTAssertTrue(app.buttons["Join jam"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "CONFERENCE_TEST_CLEAR_NAME")
        app.launch()
        XCTAssertTrue(app.staticTexts["Joining as Ani First Join"].waitForExistence(timeout: 10))
    }

    func testGuestRejoinUsesEditedNameWithoutRestart() throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_INVITE"] else {
            throw XCTSkip("Provide a live guest invitation in the test runner environment.")
        }
        app.launchEnvironment["CONFERENCE_TEST_CLEAR_NAME"] = "1"
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        var handoff = URLComponents()
        handoff.scheme = "jcp"
        handoff.host = "jazz"
        handoff.queryItems = [URLQueryItem(name: "url", value: invitation)]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = try XCTUnwrap(handoff.url?.absoluteString)
        app.launch()
        let name = app.textFields["Name shown to musicians"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("Name Before Edit")
        app.navigationBars.buttons["Join jam"].tap()
        assertParticipant("Name Before Edit")
        app.buttons["Close"].tap()
        app.buttons["Leave"].tap()
        XCTAssertTrue(app.buttons["Join jam"].waitForExistence(timeout: 15))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Edit your name")).firstMatch.tap()
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Name Before Edit".count))
        name.typeText("Name After Edit")
        app.buttons["Done"].tap()
        app.buttons["Join jam"].tap()
        assertParticipant("Name After Edit")
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Updated guest name without restart"
        evidence.lifetime = .keepAlways
        add(evidence)
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_OBSERVE_NAME"] == "1" {
            Thread.sleep(forTimeInterval: 20)
        }
        app.buttons["Close"].tap()
        app.buttons["Leave"].tap()
    }

    private func join(_ invitation: String) {
        let field = app.textFields["Invitation link"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(invitation)
        app.buttons["Join jam"].tap()
    }

    private func assertParticipant(_ name: String) {
        let musicians = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Musicians")).firstMatch
        XCTAssertTrue(musicians.waitForExistence(timeout: 60))
        musicians.tap()
        XCTAssertTrue(app.staticTexts["\(name) (you)"].waitForExistence(timeout: 15))
    }
}
