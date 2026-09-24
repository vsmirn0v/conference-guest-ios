import UIKit
import XCTest

final class ConferenceMediaUITests: XCTestCase {
    func testStarredRoomCanBeRenamedByLongPressAndPersists() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "home"
        let marker = String(UUID().uuidString.prefix(8))
        app.launchEnvironment["CONFERENCE_TEST_FIXTURE_ROOM_ID"] = marker
        app.launch()
        let room = app.buttons["Rejoin Open rehearsal \(marker)"]
        XCTAssertTrue(room.waitForExistence(timeout: 15))
        room.press(forDuration: 0.9)
        app.buttons["Rename"].tap()
        let name = app.textFields["New jam name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Friday quartet \(marker)")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Rejoin Friday quartet \(marker)"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Rejoin Friday quartet \(marker)"].waitForExistence(timeout: 10))
    }

    func testHomeIdentityRowOpensNameEditor() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launch()
        let identity = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Edit your name"))
            .firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        identity.tap()
        XCTAssertTrue(app.textFields["Name shown to musicians"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose my contact"].exists)
    }

    func testLandscapeConversationKeepsHistoryAndCallActionsVisible() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "conversation"
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        let composer = app.textViews["Chat message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("I will bring the chords.")
        XCUIDevice.shared.orientation = .landscapeLeft
        let history = app.scrollViews["Jam chat messages"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        XCTAssertTrue(history.isHittable)
        XCTAssertGreaterThan(history.frame.height, 40)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Unmute microphone"))
            .allElementsBoundByIndex.contains { $0.isHittable })
        XCTAssertTrue(app.buttons["Leave"].isHittable)
        XCTAssertTrue(app.buttons["Close conversation"].isHittable)
        attachScreenshot(of: app, named: "Conversation with landscape keyboard")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue((composer.value as? String)?.contains("I will bring the chords.") == true)
    }

    func testChatBadgeOpensChatAndMissedBadgeOpensCatchUp() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_LAYOUT_FIXTURE"] = "rock-unread"
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Chat")).firstMatch.tap()
        XCTAssertTrue(app.segmentedControls["Conversation mode"].buttons["Chat"].isSelected)
        app.buttons["Close conversation"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Catch up")).firstMatch.tap()
        XCTAssertTrue(app.scrollViews["Catch up sections"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls["Conversation mode"].buttons["Catch up"].isSelected)
    }

    func testChatFailureAndUnavailableStateExplainNextAction() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "conversation"
        app.launch()
        let retry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Retry message from"))
            .firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        retry.tap()
        XCTAssertFalse(retry.exists)
        let draft = app.textViews["Chat message"]
        draft.tap()
        draft.typeText("Friday works for me")
        app.buttons["Send chat message"].tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Friday works for me"))
            .firstMatch.waitForExistence(timeout: 5))
        app.terminate()

        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "unavailable"
        app.launch()
        XCTAssertTrue(app.staticTexts["Chat isn't available right now."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Send chat message"].isEnabled)
    }

    func testCatchUpReviewsOneSection() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "conversation"
        app.launch()
        app.segmentedControls["Conversation mode"].buttons["Catch up"].tap()
        let card = app.scrollViews["Catch up sections"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Transcript received"].exists)
        for label in ["Mic off", "Cam off"] {
            let controlLabel = app.staticTexts[label]
            XCTAssertTrue(controlLabel.exists)
            XCTAssertGreaterThan(controlLabel.frame.width, 30, "Narrow \(label) label")
            XCTAssertLessThan(controlLabel.frame.height, 25, "Wrapped \(label) label")
        }
        attachScreenshot(of: app, named: "Catch up on compact screen")
        app.buttons["Mark section reviewed"].tap()
        XCTAssertTrue(app.staticTexts["Reviewed"].exists)
    }

    func testLiveTranscriptKeepsReadingPositionUntilFollowIsTapped() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "transcript"
        app.launch()
        app.segmentedControls["Conversation mode"].buttons["Live text"].tap()
        let transcript = app.textViews["Jam transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        for _ in 0..<4 { transcript.swipeUp() }
        transcript.swipeDown()
        let follow = app.buttons["Jump to latest ↓"]
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        XCTAssertTrue(follow.isHittable)
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@",
            "New line received while reading earlier notes.")).firstMatch.waitForExistence(timeout: 12))
        XCTAssertTrue(follow.isHittable)
        follow.tap()
        XCTAssertFalse(follow.isHittable)
    }

    func testParticipantListReflowsAtAccessibilityTextSize() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "participants"
        app.launchArguments = ["-UIPreferredContentSizeCategoryName",
                               "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let pin = app.buttons["Pin video"]
        XCTAssertTrue(pin.waitForExistence(timeout: 10))
        let list = app.scrollViews.firstMatch
        for _ in 0..<4 where !pin.isHittable { list.swipeUp() }
        XCTAssertTrue(pin.isHittable)
        XCTAssertGreaterThan(pin.frame.width, 150)
        attachScreenshot(of: app, named: "Participants at accessibility text size")
    }

    func testManualGuestScreenSharePinch() throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_SHARE"] == "1",
              let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_INVITE"] else {
            throw XCTSkip("Start a synthetic share in the supplied guest room before running this test.")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invitation
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Guest Zoom QA"
        #if targetEnvironment(simulator)
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        #endif
        app.launch()
        defer {
            XCUIDevice.shared.orientation = .portrait
            if app.buttons["Leave"].exists { app.buttons["Leave"].tap() }
        }
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 45))
        let sharing = app.buttons.matching(NSPredicate(
            format: "value == %@", "A screen is being shared"
        )).firstMatch
        XCTAssertTrue(sharing.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertGreaterThanOrEqual(app.scrollViews.count, 1)
        attachScreenshot(of: app, named: "Guest share before pinch")
        app.windows.firstMatch.pinch(withScale: 2, velocity: 1)
        XCTAssertTrue(app.buttons["Leave"].isHittable)
        attachScreenshot(of: app, named: "Guest share after pinch")
    }
    func testMeetingNoticesStayAboveControlsInBothOrientations() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_LAYOUT_FIXTURE"] = "notice"
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        let notice = app.staticTexts["Meeting transcript is on"]
        let controls = app.buttons["Fixture controls"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertTrue(controls.exists)
        for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 2)
            XCTAssertLessThan(notice.frame.maxY + 10, controls.frame.minY)
            attachScreenshot(of: app, named: "Notice layout \(orientation.rawValue)")
        }
    }

    func testCallLayoutFixtureRotatesInSimulator() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_LAYOUT_FIXTURE"] = "rock"
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft, .portrait,
                                                  .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            assertCallControlsVisible(app, labels: ["Leave", "Unmute microphone", "Start video",
                                                    "Musicians", "More call options", "Chat"])
            let frame = app.windows.firstMatch.frame
            let leave = app.buttons["Leave"].frame
            XCTAssertGreaterThanOrEqual(leave.minX, frame.minX - 1)
            XCTAssertLessThanOrEqual(leave.maxX, frame.maxX + 1)
            attachScreenshot(of: app, named: "Fixture orientation \(orientation.rawValue)")
        }
    }

    func testControlsAndConversationFitBothOrientations() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = "https://rock.glowsoft.ru/jams/test"
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Rock QA"
        #if targetEnvironment(simulator)
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        #endif
        app.launch()
        defer {
            XCUIDevice.shared.orientation = .portrait
            let leave = app.buttons["Leave"]
            if leave.exists { leave.tap() }
        }
        let leave = app.buttons["Leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 45))
        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            assertCallControlsVisible(app, labels: ["Leave", "Unmute microphone", "Start video",
                                                    "Musicians", "More call options", "Chat"])
            Thread.sleep(forTimeInterval: 2)
            attachScreenshot(of: app, named: "Rock settled orientation \(orientation.rawValue)")
        }
        let musicians = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Musicians")).firstMatch
        musicians.tap()
        XCTAssertTrue(app.staticTexts["Rock QA (you)"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Mic off · Video off"].exists)
        app.buttons["Done"].tap()
        app.buttons["Chat"].tap()
        let mode = app.segmentedControls["Conversation mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        mode.buttons["Catch up"].tap()
        XCTAssertTrue(mode.buttons["Catch up"].isSelected)
        let transcript = app.scrollViews["Catch up sections"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(transcript.frame.height, window.height * 0.3)
        XCTAssertLessThanOrEqual(transcript.frame.maxY, window.maxY - 30)
        mode.buttons["Chat"].tap()
        XCTAssertTrue(app.scrollViews["Jam chat messages"].isHittable)
        XCTAssertTrue(app.textViews["Chat message"].isHittable)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Unmute microphone"))
            .allElementsBoundByIndex.contains { $0.isHittable })
        app.buttons["Close conversation"].tap()
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
            NSPredicate(format: "label CONTAINS %@", "musicians")
        ).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 30))
        let meeting = XCTAttachment(screenshot: app.screenshot())
        meeting.name = "Jam with browser participant"
        meeting.lifetime = .keepAlways
        add(meeting)
        app.buttons["Chat"].tap()
        app.segmentedControls["Conversation mode"].buttons["Chat"].tap()
        let chat = app.scrollViews["Jam chat messages"]
        let field = app.textViews["Chat message"]
        field.tap()
        field.typeText("phone-to-browser")
        app.buttons["Send chat message"].tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "phone-to-browser"))
            .firstMatch.waitForExistence(timeout: 10))
        let incoming = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "browser-to-phone"))
            .firstMatch
        expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: incoming)
        waitForExpectations(timeout: 45)
        XCTAssertTrue(chat.exists)
        app.segmentedControls["Conversation mode"].buttons["Live text"].tap()
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
        let address = app.textFields["Invitation link"]
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
        let address = app.textFields["Invitation link"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        XCTAssertEqual(address.value as? String, invitation)
        XCTAssertTrue(app.buttons["Join jam"].isEnabled)
    }

    func testNativeGuestSchemesResolveIntoInvitations() throws {
        let links = [
            ("jcp://jazz?code=schemeprobejcp&psw=fixturepass", "schemeprobejcp"),
            ("jazz://join?id=schemeprobejazz&password=fixturepass", "schemeprobejazz"),
            ("jazz://jazz?code=schemeprobealias&psw=fixturepass", "schemeprobealias")
        ]
        for (raw, roomID) in links {
            let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
            app.open(try XCTUnwrap(URL(string: raw)))
            let address = app.textFields["Invitation link"]
            XCTAssertTrue(address.waitForExistence(timeout: 15))
            let converted = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value CONTAINS %@", "/calls/\(roomID)?psw=fixturepass"),
                object: address)
            XCTAssertEqual(XCTWaiter.wait(for: [converted], timeout: 15), .completed)
            if app.buttons["Leave"].exists { app.buttons["Leave"].tap() }
            app.terminate()
        }
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
        let display = app.buttons["More call options"]
        XCTAssertTrue(display.isHittable)
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "Guest landscape"
        landscape.lifetime = .keepAlways
        add(landscape)
        display.tap()
        if app.buttons["View"].exists { app.buttons["View"].tap() }
        XCTAssertTrue(app.buttons["Screen shares"].isEnabled)
        app.buttons["Audio only"].tap()
        XCTAssertTrue(app.buttons["More call options"].exists)
        app.buttons["More call options"].tap()
        if app.buttons["View"].exists { app.buttons["View"].tap() }
        app.buttons["All video"].tap()
        XCUIDevice.shared.orientation = .portrait
        assertCallControlsVisible(app, labels: ["Leave", "Unmute microphone", "Start video",
                                                "Musicians", "More call options", "Chat"])
        XCUIDevice.shared.orientation = .landscapeRight
        assertCallControlsVisible(app, labels: ["Leave", "Unmute microphone", "Start video",
                                                "Musicians", "More call options", "Chat"])
        XCUIDevice.shared.orientation = .portrait
        let musicians = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Musicians")).firstMatch
        musicians.tap()
        XCTAssertTrue(app.staticTexts["Phone Guest QA (you)"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["More participant controls"].exists)
        app.buttons["Done"].tap()
        let catchUp = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Chat")).firstMatch
        catchUp.tap()
        app.segmentedControls["Conversation mode"].buttons["Catch up"].tap()
        let transcript = app.scrollViews["Catch up sections"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(transcript.frame.height, app.windows.firstMatch.frame.height * 0.3)
        app.segmentedControls["Conversation mode"].buttons["Chat"].tap()
        let field = app.textViews["Chat message"]
        XCTAssertTrue(field.isHittable)
        field.tap()
        field.typeText("guest-phone-to-browser")
        app.buttons["Send chat message"].tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "guest-phone-to-browser"))
            .firstMatch.waitForExistence(timeout: 10))
        let incoming = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "guest-browser-to-phone"))
            .firstMatch
        expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: incoming)
        waitForExpectations(timeout: 45)
    }

    func testGuestScreenShareViewModeFollowsLiveShare() throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_SHARE_TRANSITIONS"] == "1",
              let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_INVITE"] else {
            throw XCTSkip("Start a synthetic share and camera, then stop and restart the share during this test.")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invitation
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Screen View QA"
        #if targetEnvironment(simulator)
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        #endif
        app.launch()
        defer { if app.buttons["Leave"].exists { app.buttons["Leave"].tap() } }
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 60))
        let sharing = app.buttons.matching(NSPredicate(format: "value == %@", "A screen is being shared"))
            .firstMatch
        XCTAssertTrue(sharing.waitForExistence(timeout: 20))
        app.buttons["More call options"].tap()
        if app.buttons["View"].exists { app.buttons["View"].tap() }
        let shares = app.buttons["Screen shares"]
        XCTAssertTrue(shares.isEnabled)
        shares.tap()
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
            "No screen share is live.")).firstMatch.exists)
        attachScreenshot(of: app, named: "Guest shared screen view")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Leave"].isHittable)
        attachScreenshot(of: app, named: "Guest shared screen landscape")
        XCUIDevice.shared.orientation = .portrait

        let empty = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
            "No screen share is live.")).firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 60),
                      "Stop the synthetic browser share while this test waits.")
        attachScreenshot(of: app, named: "Guest waiting for a screen share")
        XCTAssertTrue(app.buttons["Leave"].isHittable)
        app.buttons["More call options"].tap()
        if app.buttons["View"].exists { app.buttons["View"].tap() }
        app.buttons["All video"].tap()
        XCTAssertFalse(empty.exists)
        attachScreenshot(of: app, named: "Guest camera view restored")

        app.buttons["More call options"].tap()
        if app.buttons["View"].exists { app.buttons["View"].tap() }
        app.buttons["Screen shares"].tap()
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertTrue(sharing.waitForExistence(timeout: 60),
                      "Restart the synthetic browser share while this test waits.")
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                               object: empty)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 10), .completed)
        attachScreenshot(of: app, named: "Guest screen share resumed")
    }

    func testGuestScreenShareEmptyStateFitsAfterRotation() throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_INVITE"] else {
            throw XCTSkip("Provide a guest room with a camera participant and no live share.")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invitation
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Screen View QA"
        #if targetEnvironment(simulator)
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        #endif
        app.launch()
        defer {
            XCUIDevice.shared.orientation = .portrait
            if app.buttons["Leave"].exists { app.buttons["Leave"].tap() }
        }
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 60))
        app.buttons["More call options"].tap()
        if app.buttons["View"].exists { app.buttons["View"].tap() }
        app.buttons["Screen shares"].tap()
        let empty = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
            "No screen share is live.")).firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 15))
        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 2)
            assertCallControlsVisible(app, labels: ["Leave", "Unmute microphone", "Start video",
                                                    "Musicians", "More call options", "Chat"])
            XCTAssertTrue(empty.isHittable)
            attachScreenshot(of: app, named: "Guest share-only empty \(orientation.rawValue)")
        }
        app.buttons["More call options"].tap()
        if app.buttons["View"].exists { app.buttons["View"].tap() }
        app.buttons["Audio only"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Audio only"))
            .firstMatch.waitForExistence(timeout: 10))
        app.buttons["More call options"].tap()
        if app.buttons["View"].exists { app.buttons["View"].tap() }
        app.buttons["All video"].tap()
        XCTAssertFalse(empty.exists)
        attachScreenshot(of: app, named: "Guest video after audio-only")
    }

    func testGuestParticipantsList() throws {
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
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 60))
        let musicians = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Musicians")).firstMatch
        musicians.tap()
        XCTAssertTrue(app.buttons["Phone Guest QA (you)"].waitForExistence(timeout: 10))
        let list = app.collectionViews["ParticipantsListView.listContainer"]
        let remote = list.buttons.element(boundBy: 1)
        if remote.exists {
            remote.tap()
            let pin = app.buttons["JazzMenu.pin"]
            XCTAssertTrue(pin.waitForExistence(timeout: 5))
            pin.tap()
        }
    }

    func testGuestControlsSurviveRotationCycles() throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_INVITE"] else {
            throw XCTSkip("Provide a live guest invitation in the test environment.")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invitation
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Phone Guest QA"
        #if targetEnvironment(simulator)
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        #endif
        app.launch()
        defer {
            XCUIDevice.shared.orientation = .portrait
            if app.buttons["Leave"].exists { app.buttons["Leave"].tap() }
        }
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 60))
        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let leave = app.buttons["Leave"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"),
                                                  object: leave)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
            assertCallControlsVisible(app, labels: ["Leave", "Unmute microphone", "Start video",
                                                    "Musicians", "More call options", "Chat"])
            if orientation == .portrait {
                let window = app.windows.firstMatch.frame
                XCTAssertGreaterThan(window.width, 300)
                XCTAssertLessThanOrEqual(leave.frame.maxX, window.maxX + 1)
            }
        }
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Chat")).firstMatch.tap()
        let mode = app.segmentedControls["Conversation mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        mode.buttons["Chat"].tap()
        XCTAssertTrue(app.scrollViews["Jam chat messages"].isHittable)
        mode.buttons["Live text"].tap()
        XCTAssertTrue(app.textViews["Jam transcript"].isHittable)
        mode.buttons["Catch up"].tap()
        XCTAssertTrue(app.scrollViews["Catch up sections"].isHittable)
        app.buttons["Close conversation"].tap()
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
        let display = app.buttons["More call options"]
        XCTAssertTrue(display.waitForExistence(timeout: 60))
        Thread.sleep(forTimeInterval: 8)
        attachScreenshot(of: app, named: "Guest all video")
        display.tap()
        if app.buttons["View"].exists { app.buttons["View"].tap() }
        app.buttons["Audio only"].tap()
        Thread.sleep(forTimeInterval: 4)
        attachScreenshot(of: app, named: "Guest audio only")
        app.buttons["More call options"].tap()
        if app.buttons["View"].exists { app.buttons["View"].tap() }
        XCTAssertTrue(app.buttons["Screen shares"].isEnabled)
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
        let display = app.buttons["More call options"]
        XCTAssertTrue(display.waitForExistence(timeout: 45))
        let zoom = app.scrollViews["Pinch to zoom screen share"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 20))
        let pin = app.buttons["Pin Share QA screen"]
        XCTAssertTrue(pin.exists)
        pin.tap()
        XCTAssertTrue(app.buttons["Unpin Share QA screen"].exists)
        zoom.pinch(withScale: 2, velocity: 1)
        XCTAssertNotEqual(zoom.value as? String, "100%")
        let musicians = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Musicians")).firstMatch
        musicians.tap()
        XCTAssertTrue(app.staticTexts["Share QA"].exists)
        XCTAssertTrue(app.staticTexts["Mic off · Video off · Sharing screen"].exists)
        XCTAssertTrue(app.buttons["Return to automatic view"].exists)
        app.buttons["Return to automatic view"].tap()
        app.buttons["Done"].tap()
        attachScreenshot(of: app, named: "Rock all video and share")
        display.tap()
        if app.buttons["View"].exists { app.buttons["View"].tap() }
        app.buttons["Screen shares"].tap()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(app.buttons["More call options"].exists)
        attachScreenshot(of: app, named: "Rock screen share only")
        app.buttons["More call options"].tap()
        if app.buttons["View"].exists { app.buttons["View"].tap() }
        app.buttons["Audio only"].tap()
        Thread.sleep(forTimeInterval: 2)
        attachScreenshot(of: app, named: "Rock audio only")
    }

    func testRockSpeakingIndicatorWithBrowserTone() throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SPEAKING"] == "1" else {
            throw XCTSkip("Join the test jam as Tone QA in a browser first.")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = "https://rock.glowsoft.ru/jams/test"
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Phone Speaking QA"
        app.launch()
        defer { if app.buttons["Leave"].exists { app.buttons["Leave"].tap() } }
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.staticTexts["2 musicians in this jam"].waitForExistence(timeout: 30))
        let musicians = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Musicians")).firstMatch
        musicians.tap()
        XCTAssertTrue(app.staticTexts["Tone QA"].waitForExistence(timeout: 15))
        print("WAITING FOR SPEAKING TONE")
        XCTAssertTrue(app.staticTexts["● Speaking"].waitForExistence(timeout: 45))
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertCallControlsVisible(_ app: XCUIApplication, labels: [String]) {
        for label in labels {
            let control = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
            XCTAssertTrue(control.waitForExistence(timeout: 10), "Missing \(label)")
            XCTAssertTrue(control.isHittable, "Hidden \(label)")
            XCTAssertGreaterThanOrEqual(control.frame.width, 44, "Narrow \(label)")
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, "Short \(label)")
        }
    }

    func testStoreHomeScreenshot() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launch()
        app.buttons["Profile and settings"].tap()
        let name = app.textFields["Your name"]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        name.tap()
        if let current = name.value as? String, !current.isEmpty {
            name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        name.typeText("Musician")
        app.terminate()
        app.launch()
        app.buttons["Profile and settings"].tap()
        XCTAssertEqual(app.textFields["Your name"].value as? String, "Musician")
        app.buttons["Done"].tap()
        let star = app.buttons["Star Open rehearsal"]
        if star.exists { star.tap() }
        attachScreenshot(of: app, named: "Rock’n’Roll home")
    }

    func testFixtureNameDoesNotReplaceSavedProfile() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launch()
        app.buttons["Profile and settings"].tap()
        let name = app.textFields["Your name"]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        name.tap()
        if let current = name.value as? String, !current.isEmpty {
            name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        name.typeText("Configured Musician")
        app.terminate()

        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = "https://rock.glowsoft.ru/jams/test"
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Rapid Switch QA"
        #if targetEnvironment(simulator)
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        #endif
        app.launch()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 45))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Musicians")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Rapid Switch QA (you)"].waitForExistence(timeout: 10))
        app.terminate()

        app.launchEnvironment.removeValue(forKey: "CONFERENCE_TEST_INVITE")
        app.launchEnvironment.removeValue(forKey: "CONFERENCE_TEST_NAME")
        app.launchEnvironment.removeValue(forKey: "CONFERENCE_TEST_DIRECT_MEDIA")
        app.launch()
        XCTAssertTrue(app.staticTexts["Joining as Configured Musician"].waitForExistence(timeout: 15))
    }

    func testCommunityJamConnectsMuted() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = "https://rock.glowsoft.ru/jams/test"
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "iPhone Jam QA"
        #if targetEnvironment(simulator)
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        #endif
        app.launch()
        defer {
            let leave = app.buttons["Leave"]
            if leave.exists { leave.tap() }
        }

        let connected = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Only you here")
        ).firstMatch
        guard connected.waitForExistence(timeout: 25) else {
            XCTFail("Jam did not connect. UI: \(app.debugDescription)")
            return
        }
        XCTAssertTrue(app.buttons["Unmute microphone"].exists)
        XCTAssertTrue(app.buttons["Start video"].exists)
        XCTAssertTrue(app.buttons["Invite musicians"].isHittable)
        XCTAssertTrue(app.buttons["Copy link"].isHittable)
        app.buttons["Chat"].tap()
        XCTAssertTrue(app.buttons["Close conversation"].waitForExistence(timeout: 10))
        app.buttons["Close conversation"].tap()
        Thread.sleep(forTimeInterval: 15)
    }

    func testCommunityJamTwoWayMedia() throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_REMOTE_MEDIA"] == "1" else {
            throw XCTSkip("Start a browser participant publishing test audio/video first.")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = "https://rock.glowsoft.ru/jams/test"
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "iPhone Media QA"
        #if targetEnvironment(simulator)
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        #endif
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

        XCTAssertTrue(app.buttons["Chat"].waitForExistence(timeout: 35))
        Thread.sleep(forTimeInterval: 11)
        guard app.buttons["Chat"].exists else {
            XCTFail("Jam ended during hold. UI: \(app.debugDescription)")
            return
        }
        app.buttons["Chat"].tap()
        app.segmentedControls["Conversation mode"].buttons["Catch up"].tap()
        XCTAssertTrue(app.scrollViews["Catch up sections"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No transcript received"].exists)
        app.buttons["Close conversation"].tap()
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

        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Catch up,"))
            .firstMatch.waitForExistence(timeout: 60))
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "CONFERENCE_TEST_HOLD_SECONDS")
        app.launchEnvironment.removeValue(forKey: "CONFERENCE_TEST_INVITE")
        app.launch()

        let review = app.buttons["Review missed section"]
        XCTAssertTrue(review.waitForExistence(timeout: 30))
        review.tap()
        XCTAssertTrue(app.staticTexts["No transcript received"].waitForExistence(timeout: 10))
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
            NSPredicate(format: "label BEGINSWITH %@", "Chat")
        ).firstMatch
        XCTAssertTrue(catchUp.waitForExistence(timeout: 60))
        let missed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Catch up,"))
            .firstMatch
        XCTAssertTrue(missed.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 5)
        missed.tap()
        XCTAssertTrue(app.scrollViews["Catch up sections"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No transcript received"].exists)
        app.buttons["Close conversation"].tap()
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
            NSPredicate(format: "label BEGINSWITH %@", "Chat")
        ).firstMatch
        guard catchUp.waitForExistence(timeout: 60) else {
            XCTFail("Guest invitation did not join. UI: \(app.debugDescription)")
            return
        }
        catchUp.tap()
        let close = app.buttons["Close conversation"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        app.segmentedControls["Conversation mode"].buttons["Catch up"].tap()
        XCTAssertTrue(app.scrollViews["Catch up sections"].exists)
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

        app.buttons["Profile and settings"].tap()
        let name = app.textFields["Your name"]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        name.tap()
        name.typeText("Link QA")
        app.buttons["Done"].tap()
        app.buttons["Join jam"].tap()
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
        XCTAssertEqual(app.textFields["Invitation link"].value as? String, second)
        app.buttons["Join jam"].tap()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 60))
    }

    func testThreeRoomNativeLinkSequence() throws {
        guard let first = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_FIRST_APP_LINK"],
              let second = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SECOND_APP_LINK"],
              let firstURL = URL(string: first), let secondURL = URL(string: second),
              firstURL.scheme == "jcp", secondURL.scheme == "jcp",
              let firstID = URLComponents(url: firstURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value,
              let secondID = URLComponents(url: secondURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw XCTSkip("Provide two live native app links in TEST_RUNNER_ROCKNROLL_TEST_*_APP_LINK.")
        }

        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = "https://rock.glowsoft.ru/jams/test"
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Switch QA"
        let encoded = try JSONEncoder().encode([firstURL, secondURL])
        app.launchEnvironment["CONFERENCE_TEST_SWITCH_URLS"] = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        app.launch()

        let join = app.buttons["Join jam"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ AND enabled == true",
                                                                   "Switch sequence connected"),
                                              object: join)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 120), .completed)
        XCTAssertTrue(app.staticTexts[firstID].exists)
        XCTAssertTrue(app.staticTexts[secondID].exists)
        XCTAssertTrue(app.staticTexts["test"].exists)
    }

    func testRapidLinksDuringJoinUseLatestInvitation() throws {
        guard let first = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_FIRST_APP_LINK"],
              let second = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SECOND_APP_LINK"],
              let firstURL = URL(string: first), let secondURL = URL(string: second),
              let secondID = URLComponents(url: secondURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw XCTSkip("Provide two live native app links in TEST_RUNNER_ROCKNROLL_TEST_*_APP_LINK.")
        }

        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = "https://rock.glowsoft.ru/jams/test"
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Rapid Switch QA"
        app.launchEnvironment["CONFERENCE_TEST_SWITCH_MODE"] = "rapid"
        let encoded = try JSONEncoder().encode([firstURL, secondURL])
        app.launchEnvironment["CONFERENCE_TEST_SWITCH_URLS"] = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        app.launch()

        let join = app.buttons["Join jam"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ AND enabled == true",
                                                                   "Switch sequence connected"),
                                              object: join)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 120), .completed)
        let value = app.textFields["Invitation link"].value as? String
        XCTAssertTrue(value?.contains("/calls/\(secondID)") == true)
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

        app.buttons["More call options"].tap()
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
