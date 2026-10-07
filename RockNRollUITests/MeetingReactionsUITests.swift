import XCTest

final class MeetingReactionsUITests: XCTestCase {
    func testWideReactionShortcut() {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
        app.launchEnvironment["CONFERENCE_TEST_GUEST_SCENARIO"] = "reactions"
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        app.launch()
        let shortcut = app.buttons["call.reactions"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 10)); XCTAssertTrue(shortcut.isHittable)
        shortcut.tap()
        XCTAssertTrue(app.buttons["reactions.send.surprise"].waitForExistence(timeout: 5))
        app.buttons["reactions.send.surprise"].tap()
        XCTAssertFalse(app.buttons["reactions.done"].exists)
    }
    func testLiveGuestManualAndCameraReactions() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("System camera reaction effects need physical capture")
        #endif
        guard let invite = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_REACTIONS_INVITE"] else {
            throw XCTSkip("Opt-in live reaction qualification")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invite
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Reaction device QA"
        app.launchEnvironment["CONFERENCE_TEST_REACTIONS"] = "1"
        app.launch()
        defer { app.terminate() }
        let more = app.buttons["call.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 25))
        for kind in ["like", "applause", "smile", "surprise", "dislike"] {
            more.tap()
            let send = app.buttons["reactions.send.\(kind)"]
            XCTAssertTrue(send.waitForExistence(timeout: 5)); XCTAssertTrue(send.isEnabled)
            send.tap()
            Thread.sleep(forTimeInterval: 2)
        }
        let sent = app.staticTexts["reactions.test-submitted"]
        XCTAssertEqual(sent.value as? String, "5")
        for index in 0..<8 {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Incoming reaction \(index)"; shot.lifetime = .keepAlways; add(shot)
            Thread.sleep(forTimeInterval: 1)
        }
        app.buttons["Start video"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 3)
        more.tap()
        let forwarding = app.switches["reactions.camera-sharing"]
        XCTAssertTrue(forwarding.waitForExistence(timeout: 5))
        let wasOn = forwarding.value as? String == "1"
        if !wasOn { forwarding.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let enabled = expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: forwarding)
        wait(for: [enabled], timeout: 5)
        let status = app.staticTexts["reactions.camera-status"]
        let supported = expectation(for: NSPredicate(format: "label == %@ OR label == %@", "Ready", "Enable Reactions in system camera controls"), evaluatedWith: status)
        wait(for: [supported], timeout: 10)
        app.buttons["reactions.done"].tap()
        for (index, title) in ["Test camera reaction: Like", "Test camera reaction: Dislike"].enumerated() {
            more.tap()
            let effect = app.buttons[title].firstMatch
            for _ in 0..<4 { if effect.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(effect.isHittable); effect.tap()
            let forwarded = expectation(for: NSPredicate(format: "value == %@", String(6 + index)), evaluatedWith: sent)
            wait(for: [forwarded], timeout: 10)
            Thread.sleep(forTimeInterval: 4)
        }
        more.tap()
        if !wasOn { app.switches["reactions.camera-sharing"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        app.buttons["reactions.done"].tap()
        app.buttons["Leave"].firstMatch.tap()
    }
    func testPaletteAndExistingActionsSurviveRotation() { checkPalette(language: "en") }
    func testRussianPaletteAndExistingActionsSurviveRotation() { checkPalette(language: "ru") }
    private func checkPalette(language: String) {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(\(language))"]
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
        app.launchEnvironment["CONFERENCE_TEST_GUEST_SCENARIO"] = "reactions"
        XCUIDevice.shared.orientation = .portrait
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        app.launch()
        let more = app.buttons["call.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10)); more.tap()
        for kind in ["like", "applause", "smile", "surprise", "dislike"] {
            let button = app.buttons["reactions.send.\(kind)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5)); XCTAssertTrue(button.isHittable)
        }
        app.buttons["reactions.send.like"].tap()
        XCTAssertFalse(app.buttons["reactions.done"].waitForExistence(timeout: 1))
        more.tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["reactions.send.applause"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["reactions.send.applause"].isHittable)
        app.buttons["reactions.done"].tap()
        XCUIDevice.shared.orientation = .portrait
        more.tap()
        let view = app.descendants(matching: .any)["meeting.menu.call.view-mode"].firstMatch
        for _ in 0..<4 { if view.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(view.isHittable); view.tap()
        let audio = app.buttons[language == "ru" ? "Только звук" : "Audio only"].firstMatch
        XCTAssertTrue(audio.waitForExistence(timeout: 5)); audio.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 5))
    }
}
