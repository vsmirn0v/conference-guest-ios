import XCTest

/// Authorized live invitations are supplied at runtime, never stored in source.
final class EngineSwitchingUITests: XCTestCase {
    func testAllEngineSwitchesReturnToGuestWithoutRestart() throws {
        guard let raw = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_ENGINE_SEQUENCE"],
              let data = raw.data(using: .utf8) else { throw XCTSkip("Opt-in all-engine live sequence") }
        let links = try JSONDecoder().decode([URL].self, from: data)
        XCTAssertEqual(links.count, 5, "Guest → three other engines → guest")
        guard links.count == 5 else { return }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-savedDisplayName", "Engine switch qualification"]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = links[0].absoluteString
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Engine switch qualification"
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        let handoffs = try links.dropFirst().map { invitation -> URL in
            var value = URLComponents()
            value.scheme = "jcp"; value.host = "jazz"
            value.queryItems = [URLQueryItem(name: "url", value: invitation.absoluteString)]
            return try XCTUnwrap(value.url)
        }
        app.launchEnvironment["CONFERENCE_TEST_SWITCH_URLS"] = String(decoding: try JSONEncoder().encode(handoffs), as: UTF8.self)
        app.launch()
        // Native handoffs connect automatically. Query completion atomically;
        // reading a button's value while its screen disappears races navigation.
        let completed = app.buttons.matching(NSPredicate(format: "identifier == %@ AND value == %@",
            "join.start", "Switch sequence connected")).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 210))
        XCTAssertEqual(app.textFields["Invitation link"].value as? String, links.last?.absoluteString)
        XCTAssertFalse(app.buttons["Leave"].exists, "The fixture must leave its final room")
    }
}
