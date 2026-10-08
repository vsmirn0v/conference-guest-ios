import XCTest

final class TelemostUITests: XCTestCase {
    func testPhysicalBackgroundPiPRoutesAndCleanup() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires system PiP and physical audio routes")
        #else
        let app = try physicalApp()
        defer { if app.buttons["Leave"].exists { app.buttons["Leave"].tap() } }
        XCTAssertTrue(app.scrollViews["Pinch to zoom screen share"].firstMatch.waitForExistence(timeout: 35))
        for route in ["Use iPhone receiver", "Use iPhone speaker"] {
            app.buttons["More call options"].tap()
            let menu = app.collectionViews.firstMatch
            for _ in 0..<3 where !app.buttons[route].exists { menu.swipeDown() }
            XCTAssertTrue(app.buttons[route].waitForExistence(timeout: 3))
            app.buttons[route].tap()
            sleep(3)
            XCTAssertTrue(app.buttons["Leave"].exists)
        }
        let available = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Floating video available"), object: app.buttons["More call options"])
        XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 15), .completed)
        app.buttons["More call options"].tap(); app.buttons["Show floating video"].tap()
        XCUIDevice.shared.press(.home)
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let pip = system.windows["PIP-SBInteractionPassThroughView"]
        XCTAssertTrue(pip.waitForExistence(timeout: 8))
        func pixels() -> Data? {
            guard let image = pip.screenshot().image.cgImage else { return nil }
            return image.cropping(to: CGRect(x: CGFloat(image.width) * 0.1, y: CGFloat(image.height) * 0.24,
                width: CGFloat(image.width) * 0.8, height: CGFloat(image.height) * 0.42))?.dataProvider?.data as Data?
        }
        sleep(75)
        XCTAssertTrue(pip.exists)
        let first = pixels(); sleep(2); let second = pixels()
        XCTAssertNotNil(first); XCTAssertNotNil(second); XCTAssertNotEqual(first, second, "Late PiP presentation must keep changing")
        let shot = XCTAttachment(screenshot: pip.screenshot()); shot.name = "Native physical PiP after 75 seconds"; shot.lifetime = .keepAlways; add(shot)
        app.activate()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 8))
        app.buttons["Leave"].tap()
        XCTAssertTrue(app.buttons["Join jam"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home); sleep(4)
        XCTAssertFalse(pip.exists, "Leaving must retire floating video")
        app.activate()
        #endif
    }
    func testPhysicalSystemScreenCaptureStopAndLeave() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the system screen-sharing chooser")
        #else
        let app = try physicalApp()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        defer { if app.buttons["Leave"].exists { app.buttons["Leave"].tap() } }
        XCTAssertTrue(app.buttons["Share screen"].waitForExistence(timeout: 35))
        let available = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["Share screen"])
        XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 20), .completed)
        for leave in [false, true] {
            app.buttons["Share screen"].tap()
            let chooser = system.buttons["Share Entire Screen"]
            if chooser.waitForExistence(timeout: 8) { chooser.tap() }
            else if app.buttons["Share Entire Screen"].exists { app.buttons["Share Entire Screen"].tap() }
            else { XCTFail("No system share action. App: \(app.debugDescription) System: \(system.debugDescription)"); return }
            XCTAssertTrue(app.buttons["Stop sharing screen"].waitForExistence(timeout: 20))
            app.activate(); sleep(3)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Native physical system capture"; shot.lifetime = .keepAlways; add(shot)
            sleep(15)
            if leave { app.buttons["Leave"].tap() }
            else {
                app.buttons["Stop sharing screen"].tap()
                XCTAssertTrue(app.buttons["Share screen"].waitForExistence(timeout: 10))
            }
        }
        XCTAssertTrue(app.buttons["Join jam"].waitForExistence(timeout: 12))
        sleep(15)
        XCTAssertFalse(system.buttons["Stop Broadcast"].exists)
        XCTAssertFalse(system.alerts.containing(NSPredicate(format: "label CONTAINS[c] 'Screen'")).firstMatch.exists)
        #endif
    }
    private func physicalApp() throws -> XCUIApplication {
        guard let link = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TELEMOST_INVITE"] else { throw XCTSkip("Disposable Telemost room required") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = link
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Native Physical QA"
        app.launch()
        return app
    }
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
        XCTAssertTrue(app.buttons["Share screen"].exists)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Chat")).firstMatch.tap()
        let reason = app.staticTexts["Read-only chat. This meeting service requires sign-in to send messages."]
        XCTAssertTrue(reason.waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["Send chat message"].exists && app.buttons["Send chat message"].isHittable)
        app.segmentedControls["Conversation mode"].buttons["Live text"].tap()
        XCTAssertTrue(app.textViews["Jam transcript"].value as? String == "This meeting service does not provide live transcripts to anonymous guests.")
        app.buttons["Close conversation"].tap()
        app.buttons["Leave"].tap()
        XCTAssertTrue(app.buttons["Join jam"].waitForExistence(timeout: 10))
    }
}
