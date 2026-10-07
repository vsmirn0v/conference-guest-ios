import XCTest
import UIKit

final class MicrophoneActivityUITests: XCTestCase {
    func testGuestPrivateCheckPortraitLandscapeAndBackground() { check(guest: true, russian: false) }
    func testJamPrivateCheckPortraitLandscapeAndBackground() { check(guest: false, russian: false) }
    func testRussianPrivateCheck() { check(guest: true, russian: true) }
    func testGuestMainMicFillVisibleInPortraitAndLandscape() { checkMainMeter(guest: true) }
    func testJamMainMicFillVisibleInPortraitAndLandscape() { checkMainMeter(guest: false) }
    private func checkMainMeter(guest: Bool) {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_MIC_ACTIVITY"] = "1"
        if guest {
            app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
            app.launchEnvironment["CONFERENCE_TEST_GUEST_SCENARIO"] = "studio"
        } else {
            app.launchEnvironment["CONFERENCE_TEST_LAYOUT_FIXTURE"] = "rock"
            app.launchEnvironment["CONFERENCE_TEST_STUDIO"] = "1"
        }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        let unmute = app.buttons["Unmute microphone"].firstMatch
        XCTAssertTrue(unmute.waitForExistence(timeout: 10)); unmute.tap()
        let mic = app.buttons["call.microphone"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let more = app.buttons["More call options"].firstMatch
            let visible = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: more)
            wait(for: [visible], timeout: 5)
            more.tap(); app.buttons["Fixture mic quiet"].tap()
            let ready = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: mic)
            wait(for: [ready], timeout: 5)
            XCTAssertTrue(mic.isHittable)
            let quiet = mic.screenshot()
            let before = mic.frame
            more.tap(); app.buttons["Fixture mic loud"].tap()
            let loud = mic.screenshot()
            XCTAssertNotEqual(quiet.pngRepresentation, loud.pngRepresentation,
                "Mic icon must show changing input in the actual meeting controls")
            XCTAssertEqual(mic.frame, before, "Meter activity must not move the toolbar")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Main mic fill · \(guest ? "guest" : "jam") · \(orientation.rawValue)"
            shot.lifetime = .keepAlways; add(shot)
            let icon = XCTAttachment(screenshot: loud); icon.name = "Mic fill detail"; icon.lifetime = .keepAlways; add(icon)
        }
    }
    private func check(guest: Bool, russian: Bool) {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments += ["-AppleLanguages", russian ? "(ru)" : "(en)", "-AppleLocale", russian ? "ru_RU" : "en_US"]
        if guest {
            app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
            app.launchEnvironment["CONFERENCE_TEST_GUEST_SCENARIO"] = "studio"
        } else {
            app.launchEnvironment["CONFERENCE_TEST_LAYOUT_FIXTURE"] = "rock"
            app.launchEnvironment["CONFERENCE_TEST_STUDIO"] = "1"
        }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        let mic = app.buttons[russian ? "Включить микрофон" : "Unmute microphone"].firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 10)); mic.press(forDuration: 0.7)
        let test = app.buttons["studio.test-microphone"]
        XCTAssertTrue(test.waitForExistence(timeout: 5)); test.tap()
        XCTAssertTrue(app.buttons["studio.record-sample"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["studio.sound-check-status"].firstMatch.exists)
        XCTAssertTrue(app.buttons["studio.unmute"].exists)
        attach("Private microphone check portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let stop = app.buttons["studio.stop-sound-check"]
        let visible = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: stop)
        wait(for: [visible], timeout: 5)
        XCTAssertTrue(stop.isHittable)
        attach("Private microphone check landscape")
        stop.tap()
        XCTAssertTrue(test.waitForExistence(timeout: 5))
        test.tap()
        XCTAssertTrue(app.buttons["studio.record-sample"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["studio.record-sample"].exists)
    }
    func testLiveGuestMicrophoneLevelAndPrivateCheck() throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_STUDIO_INVITE"] else { throw XCTSkip("Opt-in live input test") }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invitation
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Microphone feedback QA"
        app.launch()
        defer {
            if app.buttons["studio.done"].exists { app.buttons["studio.done"].tap() }
            if app.buttons["Leave"].firstMatch.exists { app.buttons["Leave"].firstMatch.tap() }
            app.terminate()
        }
        let mic = app.buttons["Unmute microphone"].firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 20)); mic.tap()
        let mute = app.buttons["Mute microphone"].firstMatch
        XCTAssertTrue(mute.waitForExistence(timeout: 8)); mute.press(forDuration: 0.7)
        let meter = app.descendants(matching: .any)["studio.microphone-meter"].firstMatch
        XCTAssertTrue(meter.waitForExistence(timeout: 5))
        let input = expectation(for: NSPredicate(format: "value == %@ OR value == %@", "Input detected", "Quiet"), evaluatedWith: meter)
        wait(for: [input], timeout: 8)
        attach("Real guest input level")
        app.buttons["studio.test-microphone"].tap()
        XCTAssertTrue(app.buttons["studio.record-sample"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["studio.unmute"].exists)
        let privateMeter = app.descendants(matching: .any)["studio.microphone-meter"].firstMatch
        let captured = expectation(for: NSPredicate(format: "value == %@ OR value == %@", "Input detected", "Quiet"), evaluatedWith: privateMeter)
        wait(for: [captured], timeout: 5)
        app.buttons["studio.record-sample"].tap()
        XCTAssertTrue(app.buttons["studio.play-sample"].waitForExistence(timeout: 8))
        app.buttons["studio.play-sample"].tap()
        XCTAssertTrue(app.buttons["studio.play-sample"].waitForExistence(timeout: 8))
        app.buttons["studio.done"].tap()
        XCTAssertTrue(mic.waitForExistence(timeout: 5), "Private check must not unmute after closing")
    }
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
