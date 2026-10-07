import XCTest

final class NameEntryUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")

    func testFirstJoinRequestsNameAndRemembersItAfterRestart() {
        app.launchEnvironment["CONFERENCE_TEST_CLEAR_NAME"] = "1"
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        app.launch()
        XCTAssertTrue(app.textFields["name.input"].waitForExistence(timeout: 10))
        join("https://rock.glowsoft.ru/jams/test")
        let field = app.textFields["name.input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Your name")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "First join must focus the inline name field")
        let prompt = XCTAttachment(screenshot: app.screenshot()); prompt.name = "First join requests inline name"; prompt.lifetime = .keepAlways; add(prompt)
        XCTAssertFalse(app.navigationBars["Your name"].exists)
        field.tap()
        field.typeText("Ani First Join")
        XCTAssertFalse(app.buttons["Leave"].exists, "Typing must not publish or connect automatically")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertEqual(app.textFields["name.input"].value as? String, "Ani First Join")
        let keyboardClosed = NSPredicate { _, _ in !self.app.keyboards.firstMatch.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: keyboardClosed, object: nil)], timeout: 5), .completed,
                       "Backgrounding must finish the name edit")
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "CONFERENCE_TEST_CLEAR_NAME")
        app.launch()
        XCTAssertTrue(app.textFields["name.input"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["name.input"].value as? String, "Ani First Join")
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
        let name = app.textFields["name.input"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("Name Before Edit")
        app.buttons["Join jam"].tap()
        assertParticipant("Name Before Edit")
        app.buttons["Close"].tap()
        app.buttons["Leave"].tap()
        XCTAssertTrue(app.buttons["Join jam"].waitForExistence(timeout: 15))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Name Before Edit".count))
        name.typeText("Name After Edit")
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

    func testNativeLinkWithNoNameFocusesInlineNameAndKeepsInvitation() {
        app.launchEnvironment["CONFERENCE_TEST_CLEAR_NAME"] = "1"
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = "jcp://jazz?code=first@meeting.example.test&psw=one"
        app.launch()
        let name = app.textFields["name.input"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Choose the name other musicians will see."].exists)
        XCTAssertTrue((app.textFields["invitation.input"].value as? String ?? "").contains("meeting.example.test"))
        XCTAssertFalse(app.buttons["Leave"].exists)
        name.typeText("Ani Native Link")
        XCTAssertEqual(name.value as? String, "Ani Native Link")
        XCTAssertFalse(app.buttons["Leave"].exists)
    }

    private func join(_ invitation: String) {
        let field = app.textFields["Invitation link"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(invitation)
        XCTAssertEqual(field.value as? String, invitation, "Typing must keep the complete invitation and field focus")
        app.buttons["Join jam"].tap()
    }

    private func assertParticipant(_ name: String) {
        let musicians = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Musicians")).firstMatch
        XCTAssertTrue(musicians.waitForExistence(timeout: 60))
        musicians.tap()
        XCTAssertTrue(app.staticTexts["\(name) (you)"].waitForExistence(timeout: 15))
    }
}
