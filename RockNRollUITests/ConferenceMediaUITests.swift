import XCTest

final class ConferenceMediaUITests: XCTestCase {
    func testCommunityJamConnectsMuted() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = "https://rock.glowsoft.ru/jams/test"
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "iPhone Jam QA"
        app.launch()
        defer {
            let leave = app.buttons["Leave"]
            if leave.exists { leave.tap() }
        }

        let connected = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "[0-9]+ musicians? in this jam")
        ).firstMatch
        guard connected.waitForExistence(timeout: 25) else {
            XCTFail("Jam did not connect. UI: \(app.debugDescription)")
            return
        }
        XCTAssertTrue(app.buttons["Unmute microphone"].exists)
        XCTAssertTrue(app.buttons["Start video"].exists)
        app.buttons["Catch up"].tap()
        XCTAssertTrue(app.buttons["Close catch up"].waitForExistence(timeout: 10))
        app.buttons["Close catch up"].tap()
        Thread.sleep(forTimeInterval: 15)
    }

    func testCommunityJamTwoWayMedia() throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_REMOTE_MEDIA"] == "1" else {
            throw XCTSkip("Start a browser participant publishing test audio/video first.")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = "https://rock.glowsoft.ru/jams/test"
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "iPhone Media QA"
        app.launch()
        defer {
            let leave = app.buttons["Leave"]
            if leave.exists { leave.tap() }
        }

        XCTAssertTrue(app.staticTexts["Synthetic Media QA"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.staticTexts["Mic on · Camera on"].waitForExistence(timeout: 30))
        let microphone = app.buttons["Unmute microphone"]
        let camera = app.buttons["Start video"]
        XCTAssertTrue(microphone.exists)
        XCTAssertTrue(camera.exists)
        microphone.tap()
        allowSystemPermissionIfNeeded()
        XCTAssertTrue(app.buttons["Mute microphone"].waitForExistence(timeout: 20))
        camera.tap()
        allowSystemPermissionIfNeeded()
        XCTAssertTrue(app.buttons["Stop video"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Flip camera"].isEnabled)
        app.buttons["Flip camera"].tap()
        Thread.sleep(forTimeInterval: 15)
        app.buttons["Mute microphone"].tap()
        app.buttons["Stop video"].tap()
        XCTAssertTrue(microphone.waitForExistence(timeout: 10))
        XCTAssertTrue(camera.exists)
    }

    func testCommunityJamHoldMarksMissedTime() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = "https://rock.glowsoft.ru/jams/test"
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "iPhone Hold QA"
        app.launchEnvironment["CONFERENCE_TEST_HOLD_SECONDS"] = "4"
        app.launch()
        defer {
            let leave = app.buttons["Leave"]
            if leave.exists { leave.tap() }
        }

        XCTAssertTrue(app.buttons["Catch up"].waitForExistence(timeout: 35))
        Thread.sleep(forTimeInterval: 11)
        guard app.buttons["Catch up"].exists else {
            XCTFail("Jam ended during hold. UI: \(app.debugDescription)")
            return
        }
        app.buttons["Catch up"].tap()
        let transcript = app.textViews["Missed jam transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        let content = try XCTUnwrap(transcript.value as? String)
        XCTAssertTrue(content.contains("Possibly missed:"), content)
        XCTAssertTrue(content.contains("No timestamped transcript recovered"), content)
        app.buttons["Close catch up"].tap()
    }

    func testCatchUpHistorySurvivesAppRestart() throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_INVITE"],
              !invitation.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_ROCKNROLL_TEST_INVITE to a live guest invitation.")
        }

        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invitation
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Rock’n’Roll Restart QA"
        app.launchEnvironment["CONFERENCE_TEST_HOLD_SECONDS"] = "4"
        app.launch()
        defer {
            let leave = app.buttons["Leave"]
            if leave.exists { leave.tap() }
        }

        XCTAssertTrue(app.buttons["Catch up, 1 missed section"].waitForExistence(timeout: 60))
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "CONFERENCE_TEST_HOLD_SECONDS")
        app.launchEnvironment.removeValue(forKey: "CONFERENCE_TEST_INVITE")
        app.launch()

        let review = app.buttons["Review missed section"]
        XCTAssertTrue(review.waitForExistence(timeout: 30))
        review.tap()
        let missing = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Possibly missed:")
        ).firstMatch
        XCTAssertTrue(missing.waitForExistence(timeout: 10))
        app.buttons["Delete local history"].tap()
        XCTAssertFalse(review.exists)
    }

    func testCatchUpMarksCallKitHold() throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_INVITE"],
              !invitation.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_ROCKNROLL_TEST_INVITE to a live guest invitation.")
        }

        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invitation
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Rock’n’Roll Hold QA"
        app.launchEnvironment["CONFERENCE_TEST_HOLD_SECONDS"] = "4"
        app.launch()
        defer {
            let leave = app.buttons["Leave"]
            if leave.exists { leave.tap() }
        }

        let catchUp = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Catch up")
        ).firstMatch
        XCTAssertTrue(catchUp.waitForExistence(timeout: 60))
        let missed = app.buttons["Catch up, 1 missed section"]
        XCTAssertTrue(missed.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 5)
        missed.tap()
        let transcript = app.textViews["Missed jam transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        let content = try XCTUnwrap(transcript.value as? String)
        XCTAssertTrue(content.contains("Possibly missed:"))
        XCTAssertTrue(content.contains("No timestamped transcript recovered"))
        app.buttons["Close catch up"].tap()
    }

    func testCatchUpPanelOpensDuringMeeting() throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_INVITE"],
              !invitation.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_ROCKNROLL_TEST_INVITE to a live guest invitation.")
        }

        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invitation
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Rock’n’Roll Catch Up QA"
        app.launch()
        defer {
            let leave = app.buttons["Leave"]
            if leave.exists { leave.tap() }
        }

        let catchUp = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Catch up")
        ).firstMatch
        guard catchUp.waitForExistence(timeout: 60) else {
            XCTFail("Guest invitation did not join. UI: \(app.debugDescription)")
            return
        }
        catchUp.tap()
        let close = app.buttons["Close catch up"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews["Missed jam transcript"].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.lifetime = .keepAlways
        add(image)
        close.tap()
    }

    func testWarmLinkReplacesMeetingAfterLeave() throws {
        guard let first = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_FIRST_INVITE"],
              let second = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SECOND_INVITE"],
              !first.isEmpty, !second.isEmpty else {
            throw XCTSkip("Set both TEST_RUNNER_ROCKNROLL_TEST_*_INVITE variables.")
        }

        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.open(try handoffURL(for: first))
        defer {
            let leave = app.buttons["Leave"]
            if leave.exists { leave.tap() }
        }

        let name = app.textFields["Your name"]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        name.tap()
        name.typeText("Link QA")
        app.buttons["Join with mic and camera off"].tap()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 60))

        // Deliver the second link from outside XCTest with devicectl while this
        // test waits. XCUIApplication.open(_:) cold-launches the app here.
        let replace = app.buttons["Leave current jam"]
        guard replace.waitForExistence(timeout: 60) else {
            XCTFail("The warm link did not reach the running call")
            return
        }
        replace.tap()

        let ready = app.staticTexts["Jam ready. Join with your microphone and camera off."]
        XCTAssertTrue(ready.waitForExistence(timeout: 30))
        XCTAssertEqual(app.textFields["Paste jam invitation link"].value as? String, second)
        app.buttons["Join with mic and camera off"].tap()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 60))
    }

    func testExplicitMicrophoneAndCameraPublishing() throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_INVITE"],
              !invitation.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_ROCKNROLL_TEST_INVITE to a live guest invitation.")
        }

        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invitation
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Rock’n’Roll Media QA"
        app.launch()
        defer {
            let leave = app.buttons["Leave"]
            if leave.exists { leave.tap() }
        }

        let microphoneOff = app.buttons["Unmute microphone"]
        let cameraOff = app.buttons["Start video"]
        XCTAssertTrue(microphoneOff.waitForExistence(timeout: 60))
        XCTAssertTrue(cameraOff.exists)

        microphoneOff.tap()
        continueProviderPermissionIfNeeded(in: app)
        allowSystemPermissionIfNeeded()
        guard app.buttons["Mute microphone"].waitForExistence(timeout: 20) else {
            XCTFail("Microphone did not turn on")
            return
        }

        cameraOff.tap()
        continueProviderPermissionIfNeeded(in: app)
        allowSystemPermissionIfNeeded()
        guard app.buttons["Stop video"].waitForExistence(timeout: 40) else {
            XCTFail("Camera did not turn on")
            return
        }

        let flipCamera = app.buttons["Flip camera"]
        XCTAssertTrue(flipCamera.exists)
        flipCamera.tap()
        guard app.buttons["Stop video"].waitForExistence(timeout: 30) else {
            XCTFail("Camera did not recover after switching")
            return
        }

        // Leave enough time for a second endpoint to inspect the published streams.
        Thread.sleep(forTimeInterval: 20)

        app.buttons["Mute microphone"].tap()
        app.buttons["Stop video"].tap()
        XCTAssertTrue(microphoneOff.waitForExistence(timeout: 10))
        XCTAssertTrue(cameraOff.waitForExistence(timeout: 10))
    }

    private func allowSystemPermissionIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    private func continueProviderPermissionIfNeeded(in app: XCUIApplication) {
        let continueButton = app.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 3) { continueButton.tap() }
    }

    private func handoffURL(for invitation: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "conferenceguest"
        components.host = "join"
        components.queryItems = [URLQueryItem(name: "url", value: invitation)]
        return try XCTUnwrap(components.url)
    }
}
