import XCTest

final class TrueConfUITests: XCTestCase {
    private func app() throws -> XCUIApplication {
        guard let link = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TRUECONF_INVITE"] else { throw XCTSkip("Authorized TrueConf room required") }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = link
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Rock TrueConf UI QA"
        app.launchEnvironment["CONFERENCE_TEST_RESET_FLOATING_VIDEO"] = "1"
        #if targetEnvironment(simulator)
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        #endif
        app.launch(); return app
    }
    func testPresentationZoomRotationPresenterAndCleanLeave() throws {
        continueAfterFailure = false
        let app = try app()
        defer { XCUIDevice.shared.orientation = .portrait; if app.buttons["Leave"].exists { app.buttons["Leave"].tap() } }
        XCTAssertTrue(app.buttons["Unmute microphone"].waitForExistence(timeout: 35))
        XCTAssertTrue(app.buttons["Start video"].exists)
        let share = app.scrollViews["Pinch to zoom screen share"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 15))
        share.pinch(withScale: 2, velocity: 1)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["Musicians"].exists || app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Musicians,'")).firstMatch.exists)
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = "TrueConf incoming presentation"; before.lifetime = .keepAlways; add(before)
        app.buttons["Share screen"].press(forDuration: 1)
        XCTAssertTrue(app.segmentedControls["studio.panes"].buttons["Presenter"].waitForExistence(timeout: 5))
        let studio = XCTAttachment(screenshot: app.screenshot()); studio.name = "TrueConf Presenter settings"; studio.lifetime = .keepAlways; add(studio)
        app.buttons["studio.done"].tap()
        app.buttons["Leave"].tap()
        XCTAssertTrue(app.buttons["Join jam"].waitForExistence(timeout: 10))
    }
    func testPhysicalLiveMicrophoneAndPiPCleanup() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("System PiP requires physical iPhone")
        #else
        continueAfterFailure = false
        let app = try app()
        defer { app.activate(); if app.buttons["Mute microphone"].exists { app.buttons["Mute microphone"].tap() }; if app.buttons["Leave"].exists { app.buttons["Leave"].tap() } }
        XCTAssertTrue(app.buttons["Unmute microphone"].waitForExistence(timeout: 35))
        app.buttons["Unmute microphone"].tap()
        XCTAssertTrue(app.buttons["Mute microphone"].waitForExistence(timeout: 8))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Floating video available"), object: app.buttons["More call options"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        let main = XCTAttachment(screenshot: app.screenshot()); main.name = "TrueConf live microphone meter"; main.lifetime = .keepAlways; add(main)
        app.buttons["More call options"].tap(); app.buttons["Show floating video"].tap()
        XCUIDevice.shared.press(.home)
        let pip = XCUIApplication(bundleIdentifier: "com.apple.springboard").windows["PIP-SBInteractionPassThroughView"]
        XCTAssertTrue(pip.waitForExistence(timeout: 8))
        sleep(4)
        let floating = XCTAttachment(screenshot: pip.screenshot()); floating.name = "TrueConf system PiP with microphone meter"; floating.lifetime = .keepAlways; add(floating)
        XCTAssertTrue(pip.exists)
        app.activate(); XCTAssertTrue(app.buttons["Mute microphone"].waitForExistence(timeout: 8))
        app.buttons["Mute microphone"].tap(); app.buttons["Leave"].tap()
        XCTAssertTrue(app.buttons["Join jam"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home); sleep(3); XCTAssertFalse(pip.exists)
        app.activate()
        #endif
    }
}
