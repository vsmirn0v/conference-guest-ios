import XCTest

final class ReviewRegressionUITests: XCTestCase {
    func testGuestCommunityGuestSequenceWaitsForEachTeardown() throws {
        guard let first = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_INVITE"],
              let second = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SECOND_INVITE"] else {
            throw XCTSkip("Requires two authorized guest test rooms")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = first
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Lifecycle QA"
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        let destinations = [second, "https://rock.glowsoft.ru/jams/test", first].map { invite -> URL in
            var url = URLComponents(string: "jcp://jazz")!
            url.queryItems = [URLQueryItem(name: "url", value: invite)]
            return url.url!
        }
        app.launchEnvironment["CONFERENCE_TEST_SWITCH_URLS"] = String(data: try JSONEncoder().encode(destinations), encoding: .utf8)
        app.launch()
        let complete = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ AND enabled == true",
            "Switch sequence connected"), object: app.buttons["Join jam"])
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 120), .completed)
        XCTAssertEqual(app.textFields["Invitation link"].value as? String, first)
        XCTAssertFalse(app.buttons["Leave"].exists)
    }
}
