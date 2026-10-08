import XCTest

final class TelemostUITests: XCTestCase {
    func testSwitchFromTelemostToJamAndBackWithoutRestart() throws {
        guard let link = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TELEMOST_INVITE"] else { throw XCTSkip("Provide a disposable Telemost invitation.") }
        try checkSwitch(first: link, destinations: ["https://rock.glowsoft.ru/jams/test", link])
    }
    func testJamToTelemostWithoutRestart() throws {
        guard let link = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TELEMOST_INVITE"] else { throw XCTSkip("Provide a disposable Telemost invitation.") }
        try checkSwitch(first: "https://rock.glowsoft.ru/jams/test", destinations: [link])
    }
    private func checkSwitch(first: String, destinations: [String]) throws {
        func handoff(_ invitation: String) throws -> URL {
            var components = URLComponents(string: "jcp://jazz")!
            components.queryItems = [.init(name: "url", value: invitation)]
            return try XCTUnwrap(components.url)
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-savedDisplayName", "Telemost Switch QA"]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = first
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Telemost Switch QA"
        app.launchEnvironment["CONFERENCE_TEST_SWITCH_URLS"] = String(decoding: try JSONEncoder().encode(destinations.map(handoff)), as: UTF8.self)
        #if targetEnvironment(simulator)
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        #endif
        app.launch()
        defer { if app.buttons["Leave"].exists { app.buttons["Leave"].tap() } }
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ AND enabled == true", "Switch sequence connected"), object: app.buttons["Join jam"])
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 60), .completed)
    }
    func testNativeShareControlsRotationAndCleanLeave() throws {
        guard let link = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TELEMOST_INVITE"] else {
            throw XCTSkip("Provide a disposable Telemost room with a synthetic screen-share source.")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = link
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Telemost App QA"
        #if targetEnvironment(simulator)
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        #endif
        app.launch()
        defer {
            XCUIDevice.shared.orientation = .portrait
            if app.buttons["Leave"].exists { app.buttons["Leave"].tap() }
        }
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 35))
        XCTAssertTrue(app.buttons["Unmute microphone"].exists)
        XCTAssertTrue(app.buttons["Start video"].exists)
        let share = app.scrollViews["Pinch to zoom screen share"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 20))
        guard share.exists else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Native Telemost screen share"; attachment.lifetime = .keepAlways; add(attachment)
        share.pinch(withScale: 2, velocity: 1)
        XCTAssertNotEqual(share.value as? String, "100%")
        let zoom = share.value as? String
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["Leave"])
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 3), .completed)
            XCTAssertEqual(share.value as? String, zoom)
        }
        let people = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Musicians")).firstMatch
        people.tap()
        XCTAssertTrue(app.staticTexts["Telemost Screen QA"].exists)
        app.buttons["Done"].tap()
        for mode in ["Screen shares", "Audio only", "All video"] {
            app.buttons["More call options"].tap()
            if app.buttons["View"].exists { app.buttons["View"].tap() }
            app.buttons[mode].tap()
            if mode == "Audio only" { XCTAssertFalse(share.exists) }
            else { XCTAssertTrue(share.waitForExistence(timeout: 10)) }
        }
        app.buttons["Leave"].tap()
        XCTAssertTrue(app.buttons["Join jam"].waitForExistence(timeout: 10))
    }
}
