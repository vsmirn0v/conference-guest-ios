import XCTest

final class AudioMixingUITests: XCTestCase {
    func testGuestMixesWithYouTube() throws {
        guard let invite = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_AUDIO_MIXING_INVITE"] else { throw XCTSkip("Live room required") }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        let youtube = XCUIApplication(bundleIdentifier: "com.google.ios.youtube")
        defer { youtube.terminate(); app.terminate() }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["CONFERENCE_TEST_INVITE": invite, "CONFERENCE_TEST_NAME": "Audio mixing QA",
            "CONFERENCE_TEST_MEDIA_TRACE": "1", "CONFERENCE_TEST_RESET_FLOATING_VIDEO": "1"]
        app.launch()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 50))
        Thread.sleep(forTimeInterval: 12)
        app.buttons["Unmute microphone"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 3)
        app.openMeetingMore(.view)
        for _ in 0..<4 where !app.buttons["Audio only"].isHittable { app.swipeUp() }
        app.buttons["Audio only"].tap()
        youtube.terminate()
        youtube.open(URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!)
        Thread.sleep(forTimeInterval: 12)
        let timeline = youtube.otherElements["id.player.scrubber.slider"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        let firstPosition = timeline.value as? String
        print("MIXING_YOUTUBE_STARTED \(Date().timeIntervalSince1970)")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); screenshot.name = "YouTube mixing baseline"; screenshot.lifetime = .keepAlways; add(screenshot)
        Thread.sleep(forTimeInterval: 30)
        XCTAssertNotNil(firstPosition)
        let lastPosition = timeline.value as? String
        XCTAssertNotNil(lastPosition)
        XCTAssertNotEqual(firstPosition, lastPosition, "The other app must actually advance its video")
        print("MIXING_YOUTUBE_FINISHED \(Date().timeIntervalSince1970)")
        app.activate()
        Thread.sleep(forTimeInterval: 8)
        XCTAssertTrue(app.buttons["Leave"].exists)
        for warning in ["Audio interrupted by iOS", "Jam audio paused by iOS", "Restoring jam audio…"] {
            XCTAssertFalse(app.staticTexts[warning].exists, "YouTube must not strand the meeting")
        }
    }
    func testGuestJoinDoesNotPauseExistingPlayback() throws {
        guard let invite = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_AUDIO_MIXING_INVITE"] else { throw XCTSkip("Live room required") }
        let player = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.audio-mixing-harness")
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        defer { player.terminate(); app.terminate() }
        player.launchArguments = ["--play"]; player.launch()
        let playing = player.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Playing")).firstMatch
        XCTAssertTrue(playing.waitForExistence(timeout: 10))
        XCUIApplication(bundleIdentifier: "com.apple.calculator").activate()
        Thread.sleep(forTimeInterval: 3)
        player.activate()
        XCTAssertTrue(playing.waitForExistence(timeout: 5), "Playback must survive backgrounding before the meeting starts")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["CONFERENCE_TEST_INVITE": invite, "CONFERENCE_TEST_NAME": "Audio mixing QA",
            "CONFERENCE_TEST_MEDIA_TRACE": "1", "CONFERENCE_TEST_RESET_FLOATING_VIDEO": "1"]
        app.launch()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 50))
        Thread.sleep(forTimeInterval: 15)
        player.activate()
        XCTAssertTrue(playing.waitForExistence(timeout: 5), "Joining must not pause existing media")
        if player.buttons["Stop test audio"].exists { player.buttons["Stop test audio"].tap() }
    }
    func testGuestMixesWithIndependentPlaybackApp() throws {
        guard let invite = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_AUDIO_MIXING_INVITE"] else {
            throw XCTSkip("Requires a disposable guest room and installed AudioMixingHarness")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        XCUIDevice.shared.orientation = .portrait
        let player = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.audio-mixing-harness")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invite
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Audio mixing QA"
        app.launchEnvironment["CONFERENCE_TEST_MEDIA_TRACE"] = "1"
        app.launchEnvironment["CONFERENCE_TEST_RESET_FLOATING_VIDEO"] = "1"
        app.launch()
        defer {
            player.terminate()
            app.terminate()
        }
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 50))
        Thread.sleep(forTimeInterval: 12)
        print("MIXING_BASELINE \(Date().timeIntervalSince1970)")
        player.launchArguments = ["--play"]
        player.launch()
        let playing = NSPredicate(format: "label BEGINSWITH %@", "Playing")
        guard player.staticTexts.matching(playing).firstMatch.waitForExistence(timeout: 10) else {
            let state = player.staticTexts["playback.status"].label
            XCTFail("Independent player did not start: \(state)"); return
        }
        print("MIXING_OTHER_APP_STARTED \(Date().timeIntervalSince1970)")
        Thread.sleep(forTimeInterval: 25)
        XCTAssertTrue(player.staticTexts.matching(playing).firstMatch.exists)
        app.activate()
        Thread.sleep(forTimeInterval: 8)
        print("MIXING_MEETING_FOREGROUND \(Date().timeIntervalSince1970)")
        XCTAssertTrue(app.buttons["Leave"].exists)
        for warning in ["Audio interrupted by iOS", "Jam audio paused by iOS", "Restoring jam audio…"] {
            XCTAssertFalse(app.staticTexts[warning].exists, "Other media must not strand the meeting: \(warning)")
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Meeting while independent playback remains active"; screenshot.lifetime = .keepAlways; add(screenshot)
        let mic = app.buttons["Unmute microphone"].firstMatch
        XCTAssertTrue(mic.isHittable, "The app must really be foregrounded, not only classified as visible through PiP")
        for _ in 0..<2 {
            mic.tap()
            let mute = app.buttons["Mute microphone"].firstMatch
            XCTAssertTrue(mute.waitForExistence(timeout: 5)); mute.tap()
            XCTAssertTrue(mic.waitForExistence(timeout: 5))
        }
        player.activate()
        XCTAssertTrue(player.staticTexts.matching(playing).firstMatch.waitForExistence(timeout: 5), "Meeting foreground must not pause the other player")
    }
}
