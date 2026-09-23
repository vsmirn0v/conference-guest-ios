import XCTest

final class GuestWebsiteTests: XCTestCase {
    func testGuestWebsiteReachesPrejoin() throws {
        guard let invite = Bundle(for: Self.self).object(forInfoDictionaryKey: "JAZZ_TEST_INVITE") as? String,
              invite.hasPrefix("https://") else {
            throw XCTSkip("Pass JAZZ_TEST_INVITE with a live guest invitation.")
        }

        let app = XCUIApplication()
        app.launchEnvironment["JAZZ_GUEST_TEST_URL"] = invite
        app.launch()

        XCTAssertTrue(app.staticTexts["Join"].waitForExistence(timeout: 40),
                      "Mobile browser choice did not appear")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).tap()

        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 40),
                      "Guest name field did not appear")

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Jazz guest page after browser choice"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
