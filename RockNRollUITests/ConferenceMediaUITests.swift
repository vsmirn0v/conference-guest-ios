import XCTest

final class ConferenceMediaUITests: XCTestCase {
    func testControlsAndConversationFitBothOrientations() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = "https://rock.glowsoft.ru/jams/test"
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Rock QA"
        app.launch()
        defer {
            XCUIDevice.shared.orientation = .portrait
            let leave = app.buttons["Leave"]
            if leave.exists { leave.tap() }
        }
        let leave = app.buttons["Leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 45))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(leave.isHittable)
        XCTAssertTrue(app.buttons["Unmute microphone"].isHittable)
        XCTAssertTrue(app.buttons["Display: All video"].isHittable)
        XCUIDevice.shared.orientation = .portrait
        app.buttons["Catch up"].tap()
        let transcript = app.textViews["Missed jam transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(transcript.frame.height, window.height * 0.4)
        XCTAssertLessThanOrEqual(transcript.frame.maxY, window.maxY - 30)
        let mode = app.segmentedControls["Conversation mode"]
        mode.buttons["Chat"].tap()
        XCTAssertTrue(app.textViews["Jam chat messages"].isHittable)
        XCTAssertTrue(app.textFields["Chat message"].isHittable)
        app.buttons["Close catch up"].tap()
    }

    func testJamChatWithBrowserParticipant() throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_BROWSER_CHAT"] == "1" else {
            throw XCTSkip("Join the public jam in a browser, then enable the chat test.")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = "https://rock.glowsoft.ru/jams/test"
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Phone QA"
        app.launch()
        defer { if app.buttons["Leave"].exists { app.buttons["Leave"].tap() } }
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 45))
        let connected = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "[0-9]+ musicians? in this jam")
        ).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 30))
        let meeting = XCTAttachment(screenshot: app.screenshot())
        meeting.name = "Jam with browser participant"
        meeting.lifetime = .keepAlways
        add(meeting)
        app.buttons["Catch up"].tap()
        app.segmentedControls["Conversation mode"].buttons["Chat"].tap()
        let chat = app.textViews["Jam chat messages"]
        let field = app.textFields["Chat message"]
        field.tap()
        field.typeText("phone-to-browser")
        app.buttons["Send chat message"].tap()
        XCTAssertTrue((chat.value as? String)?.contains("phone-to-browser") == true)
        let incoming = NSPredicate(format: "value CONTAINS %@", "browser-to-phone")
        expectation(for: incoming, evaluatedWith: chat)
        waitForExpectations(timeout: 45)
        app.segmentedControls["Conversation mode"].buttons["Transcript"].tap()
        app.segmentedControls["Conversation mode"].buttons["Chat"].tap()
        let conversation = XCTAttachment(screenshot: app.screenshot())
        conversation.name = "Jam chat"
        conversation.lifetime = .keepAlways
        add(conversation)
    }

    func testWebsiteOpensJamInApp() throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_WEB_HANDOFF"] == "1" else {
            throw XCTSkip("Run the Safari handoff test explicitly on an iPhone.")
        }
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.open(try XCTUnwrap(URL(string: "https://rock.glowsoft.ru/jams/test")))
        let open = safari.buttons["Open iPhone app"]
        XCTAssertTrue(open.waitForExistence(timeout: 25))
        open.tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let confirm = safari.alerts.buttons["Open"]
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        else if system.alerts.buttons["Open"].exists { system.alerts.buttons["Open"].tap() }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        let address = app.textFields["Paste jam invitation link"]
        XCTAssertTrue(address.waitForExistence(timeout: 20))
        XCTAssertEqual(address.value as? String, "https://rock.glowsoft.ru/jams/test")
    }

    func testWebsiteLinkPrefillsInvitation() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        let invitation = "https://rock.glowsoft.ru/jams/test"
        var handoff = URLComponents()
        handoff.scheme = "conferenceguest"
        handoff.host = "join"
        handoff.queryItems = [URLQueryItem(name: "url", value: invitation)]
        app.open(try XCTUnwrap(handoff.url))
        let address = app.textFields["Paste jam invitation link"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        XCTAssertEqual(address.value as? String, invitation)
        XCTAssertTrue(app.buttons["Join with mic and camera off"].isEnabled)
    }

    func testNativeGuestLinkJoinsImmediately() throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_APP_LINK"],
              let url = URL(string: invitation) else {
            throw XCTSkip("Provide a live native guest invitation in the test environment.")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.open(url)
        defer { if app.buttons["Leave"].exists { app.buttons["Leave"].tap() } }
        XCTAssertTrue(app.buttons["Unmute microphone"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["Leave"].exists)
    }

    func testGuestChatAndDisplayModes() throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_CHAT"] == "1" else {
            throw XCTSkip("Join the supplied guest meeting in a browser first.")
        }
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_INVITE"] else {
            throw XCTSkip("Provide a live guest invitation in the test environment.")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invitation
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Phone Guest QA"
        app.launch()
        defer {
            XCUIDevice.shared.orientation = .portrait
            if app.buttons["Leave"].exists { app.buttons["Leave"].tap() }
        }
        let leave = app.buttons["Leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 60))
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: leave)
        waitForExpectations(timeout: 10)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height)
        XCTAssertLessThanOrEqual(leave.frame.maxX, window.maxX)
        XCTAssertTrue(app.buttons["Unmute microphone"].isHittable)
        let display = app.buttons["Display: All video"]
        XCTAssertTrue(display.isHittable)
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "Guest landscape"
        landscape.lifetime = .keepAlways
        add(landscape)
        display.tap()
        XCTAssertFalse(app.buttons["Screen shares unavailable"].isEnabled)
        app.buttons["Audio only"].tap()
        XCTAssertTrue(app.buttons["Display: Audio only"].exists)
        app.buttons["Display: Audio only"].tap()
        app.buttons["All video"].tap()
        XCUIDevice.shared.orientation = .portrait
        let catchUp = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Catch up")).firstMatch
        catchUp.tap()
        let transcript = app.textViews["Missed jam transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(transcript.frame.height, app.windows.firstMatch.frame.height * 0.4)
        app.segmentedControls["Conversation mode"].buttons["Chat"].tap()
        let field = app.textFields["Chat message"]
        XCTAssertTrue(field.isHittable)
        field.tap()
        field.typeText("guest-phone-to-browser")
        app.buttons["Send chat message"].tap()
        let chat = app.textViews["Jam chat messages"]
        XCTAssertTrue((chat.value as? String)?.contains("guest-phone-to-browser") == true)
        expectation(for: NSPredicate(format: "value CONTAINS %@", "guest-browser-to-phone"),
                    evaluatedWith: chat)
        waitForExpectations(timeout: 45)
    }

    func testGuestVideoModeScreenshots() throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_VIDEO"] == "1" else {
            throw XCTSkip("Publish a synthetic camera in the supplied guest meeting first.")
        }
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_INVITE"] else {
            throw XCTSkip("Provide a live guest invitation in the test environment.")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invitation
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Phone Guest QA"
        app.launch()
        defer { if app.buttons["Leave"].exists { app.buttons["Leave"].tap() } }
        let display = app.buttons["Display: All video"]
        XCTAssertTrue(display.waitForExistence(timeout: 60))
        Thread.sleep(forTimeInterval: 8)
        attachScreenshot(of: app, named: "Guest all video")
        display.tap()
        app.buttons["Audio only"].tap()
        Thread.sleep(forTimeInterval: 4)
        attachScreenshot(of: app, named: "Guest audio only")
        app.buttons["Display: Audio only"].tap()
        XCTAssertFalse(app.buttons["Screen shares unavailable"].isEnabled)
        app.buttons["All video"].tap()
        Thread.sleep(forTimeInterval: 4)
        attachScreenshot(of: app, named: "Guest video restored")
    }

    func testRockScreenShareDisplayModes() throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_ROCK_SHARE"] == "1" else {
            throw XCTSkip("Publish a synthetic screen share and camera in the public test jam first.")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = "https://rock.glowsoft.ru/jams/test"
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Phone Share QA"
        app.launch()
        defer { if app.buttons["Leave"].exists { app.buttons["Leave"].tap() } }
        let display = app.buttons["Display: All video"]
        XCTAssertTrue(display.waitForExistence(timeout: 45))
        Thread.sleep(forTimeInterval: 5)
        attachScreenshot(of: app, named: "Rock all video and share")
        display.tap()
        app.buttons["Screen shares"].tap()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(app.buttons["Display: Screen shares"].exists)
        attachScreenshot(of: app, named: "Rock screen share only")
        app.buttons["Display: Screen shares"].tap()
        app.buttons["Audio only"].tap()
        Thread.sleep(forTimeInterval: 2)
        attachScreenshot(of: app, named: "Rock audio only")
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testStoreHomeScreenshot() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launch()
        let name = app.textFields["Your name"]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        name.tap()
        if let current = name.value as? String, !current.isEmpty {
            name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        name.typeText("Musician")
        app.terminate()
        app.launch()
        XCTAssertEqual(app.textFields["Your name"].value as? String, "Musician")
        let star = app.buttons["Star Open rehearsal"]
        if star.exists { star.tap() }
        attachScreenshot(of: app, named: "Rock’n’Roll home")
    }

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
