import XCTest

final class MeetingPresentationUITests: XCTestCase {
    func testGuestParticipantStripSwipesOverButtonsAndKeepsTapSelection() {
        let app = launch("ru", scenario: "gallery-many")
        defer { app.terminate() }
        let tile = app.otherElements["gallery.person-1.camera"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10)); tile.tap()
        assertParticipantStripDrags(app)
    }

    func testNativeParticipantStripSwipesOverButtonsAndKeepsTapSelection() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "meeting-gallery"
        app.launchArguments = ["-AppleLanguages", "(en)", "-automaticallyHideMeetingControls", "NO"]
        app.launch()
        defer { app.terminate() }
        let tile = app.otherElements["camera-off.person-1"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10)); tile.tap()
        assertParticipantStripDrags(app)
    }

    private func assertParticipantStripDrags(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let strip = app.scrollViews["Focus participants"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5), file: file, line: line)
        let selected = app.buttons["Focus participant.person-1.camera"]
        XCTAssertTrue(selected.isSelected, file: file, line: line)
        // Begin on the label, top/bottom button edges and microphone, never a gutter.
        for origin in [CGVector(dx: 0.65, dy: 0.5), CGVector(dx: 0.65, dy: 0.1),
                       CGVector(dx: 0.65, dy: 0.9), CGVector(dx: 0.12, dy: 0.5)] {
            let bounds = strip.frame
            guard let button = strip.buttons.allElementsBoundByIndex.first(where: {
                let frame = $0.frame
                let point = CGPoint(x: frame.minX + frame.width * origin.dx, y: frame.minY + frame.height * origin.dy)
                return bounds.insetBy(dx: 8, dy: 0).contains(point) && point.x >= bounds.minX + 160
            }) else { return XCTFail("Need a visible button touch point with room to drag", file: file, line: line) }
            let before = button.frame.minX
            let start = button.coordinate(withNormalizedOffset: origin)
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -140, dy: 0)))
            XCTAssertLessThan(button.frame.minX, before - 50, "The entire button must scroll the strip", file: file, line: line)
            XCTAssertTrue(selected.isSelected, "Dragging must not select or unpin a participant", file: file, line: line)
        }
        guard let target = strip.buttons.allElementsBoundByIndex.first(where: {
            strip.frame.contains($0.frame.insetBy(dx: 1, dy: 1)) && !$0.isSelected
        }) else { return XCTFail("A newly revealed participant must be tappable", file: file, line: line) }
        target.tap()
        XCTAssertTrue(target.isSelected, "A normal tap must still focus that participant", file: file, line: line)
        XCTAssertFalse(selected.isSelected, file: file, line: line)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Participant strip after button drags"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testGuestGalleryTapSelectsExactPersonAndPreservesPage() {
        let app = launch(scenario: "gallery-many")
        defer { app.terminate() }
        let gallery = app.scrollViews["Meeting grid"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 10))
        let tile = app.otherElements["gallery.person-1.camera"]
        XCTAssertTrue(tile.isHittable); tile.tap()
        assertLayout(app, "Focus")
        XCTAssertTrue(app.staticTexts["Полина"].exists)
        XCTAssertTrue(app.scrollViews["Focus participants"].exists)
        app.buttons["Focus participant.person-0.camera"].tap()
        XCTAssertTrue(app.buttons["Unpin Participant 1 video"].waitForExistence(timeout: 5))
        app.segmentedControls["Meeting layout"].buttons["Gallery"].tap()
        assertLayout(app, "Gallery")
        XCTAssertTrue(gallery.isHittable)
        let counter = app.staticTexts["Gallery page"]
        let firstPage = counter.label
        app.buttons["Next participants"].tap()
        XCTAssertNotEqual(counter.label, firstPage, "Next must change the gallery page")
        XCTAssertTrue(counter.label.contains("of 12"))
        let visibleTiles = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'gallery.'")).allElementsBoundByIndex
        guard let next = visibleTiles.first(where: { $0.isHittable }) else { return XCTFail("Next page must contain accessible participant tiles") }
        next.tap()
        assertLayout(app, "Focus")
        app.segmentedControls["Meeting layout"].buttons["Gallery"].tap()
        assertLayout(app, "Gallery")
        XCTAssertTrue(next.isHittable, "Return to the previous page")
        let pageLabel = counter.label
        gallery.swipeRight()
        XCTAssertNotEqual(counter.label, pageLabel, "A swipe over a participant tile must page the gallery")
        XCTAssertTrue(tile.isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Guest name gallery page"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testNativeGallerySelectionAndSpeakerChanges() {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "meeting-gallery"
        app.launchArguments = ["-AppleLanguages", "(en)", "-automaticallyHideMeetingControls", "NO"]
        app.launch()
        defer { app.terminate() }
        let tile = app.otherElements["camera-off.person-1"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10)); XCTAssertTrue(tile.isHittable); tile.tap()
        assertLayout(app, "Focus")
        XCTAssertEqual(app.staticTexts.matching(identifier: "Participant name").firstMatch.label, "Полина")
        app.openMeetingMore(.meeting); app.meetingActionButton("Change speaking participant").tap()
        XCTAssertEqual(app.staticTexts.matching(identifier: "Participant name").firstMatch.label, "Полина")
        app.buttons["Focus participant.person-4.camera"].tap()
        XCTAssertEqual(app.staticTexts.matching(identifier: "Participant name").firstMatch.label, "Олег Никитин")
        app.scrollViews["Meeting content"].swipeLeft()
        XCTAssertEqual(app.staticTexts.matching(identifier: "Participant name").firstMatch.label, "Елена Соколова")
        app.buttons["Focus participant.person-1.camera"].tap()
        app.scrollViews["Meeting content"].swipeLeft()
        XCTAssertEqual(app.staticTexts.matching(identifier: "Participant name").firstMatch.label, "Роман Тюрин")
        app.segmentedControls["Meeting layout"].buttons["Gallery"].tap()
        assertLayout(app, "Gallery")
        XCTAssertTrue(tile.isHittable)
        let counter = app.staticTexts["Gallery page"], initialPage = counter.label
        app.scrollViews["Meeting content"].swipeLeft()
        XCTAssertNotEqual(counter.label, initialPage)
        app.scrollViews["Meeting content"].swipeRight()
        XCTAssertTrue(tile.isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Native name gallery"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testGuestSwipingFromAutomaticFocusCanResumeFollowingSpeaker() {
        let app = launch(scenario: "gallery-many")
        defer { app.terminate() }
        XCTAssertTrue(app.segmentedControls["Meeting layout"].waitForExistence(timeout: 10))
        app.segmentedControls["Meeting layout"].buttons["Focus"].tap()
        app.otherElements["Meeting stage"].swipeLeft()
        let follow = app.buttons["Follow speaker"]
        XCTAssertTrue(follow.isEnabled)
        XCTAssertTrue(app.buttons["Pin Полина video"].waitForExistence(timeout: 5))
        follow.tap()
        XCTAssertTrue(app.buttons["Pin Participant 1 video"].waitForExistence(timeout: 5))
        XCTAssertFalse(follow.isEnabled)
    }
    func testGuestShareShortcutFocusesShareAfterReturningToGallery() {
        let app = launch(scenario: "gallery-share")
        defer { app.terminate() }
        let layout = app.segmentedControls["Meeting layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 10))
        layout.buttons["Gallery"].tap()
        app.otherElements["gallery.camera.camera"].tap()
        assertLayout(app, "Focus")
        layout.buttons["Gallery"].tap()
        let share = app.buttons["View Ani’s arrangement screen share"]
        XCTAssertTrue(share.isHittable)
        share.tap()
        assertLayout(app, "Focus")
        XCTAssertTrue(app.buttons["Unpin Ani’s arrangement screen share"].waitForExistence(timeout: 5))
    }
    private func assertLayout(_ app: XCUIApplication, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"),
            object: app.segmentedControls["Meeting layout"].buttons[label])
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed, file: file, line: line)
    }
    func testGridShowsAllParticipantsAndSwitchesToSpeakerAfterRotation() {
        let app = launch(scenario: "gallery")
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let grid = app.scrollViews["Meeting grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let landscape = orientation == .landscapeLeft
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return (frame.width > frame.height) == landscape &&
                    app.otherElements["gallery.ani.camera"].frame.width > 100
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
            for id in ["ani", "aram", "mariam", "vahan"] {
                let tile = app.otherElements["gallery." + id + ".camera"]
                XCTAssertTrue(tile.exists)
                XCTAssertGreaterThan(tile.frame.width, 100)
                XCTAssertGreaterThan(tile.frame.height, 100)
            }
            let visible = ["ani", "aram", "mariam", "vahan"].filter {
                app.windows.firstMatch.frame.contains(app.otherElements["gallery." + $0 + ".camera"].frame)
            }
            XCTAssertGreaterThanOrEqual(visible.count, 2, "Grid must show multiple participants together")
        }
        app.segmentedControls["Meeting layout"].buttons["Focus"].tap()
        XCTAssertFalse(grid.isHittable)
        XCTAssertTrue(app.scrollViews["Focus participants"].isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Speaker layout after grid rotation"; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func launch(_ language: String = "en", autoHide: Bool = false, largeText: Bool = false,
                        scenario: String? = nil) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", "en_US"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchArguments += ["-automaticallyHideMeetingControls", autoHide ? "YES" : "NO"]
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
        app.launchEnvironment["CONFERENCE_TEST_GUEST_SCENARIO"] = scenario
        app.launch()
        return app
    }

    func testInlinePrivacyNoticeNeverCoversNavigationAndOpensTranscript() {
        defer { XCUIDevice.shared.orientation = .portrait }
        for language in ["en", "ru"] {
            let app = launch(language, scenario: "notices")
            let viewport = app.scrollViews["Shared screen viewport"]
            XCTAssertTrue(viewport.waitForExistence(timeout: 10))
            for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft, .portrait] {
                XCUIDevice.shared.orientation = orientation
                let landscape = orientation == .landscapeLeft
                let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    (app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height) == landscape
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
                XCTAssertFalse(app.otherElements["Top meeting notices"].exists)
                let header = landscape ? app.otherElements["Compact meeting header"] : app.buttons["Meeting status"]
                let next = app.buttons[language == "ru" ? "Следующий поток" : "Next stream"]
                XCTAssertTrue(next.isHittable)
                XCTAssertFalse(header.frame.intersects(viewport.frame))
                if !landscape { XCTAssertFalse(header.frame.intersects(next.frame)) }
                assertControls(app, language: language)
                let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                attachment.name = "Inline privacy \(language) \(orientation.rawValue)"
                attachment.lifetime = .keepAlways; add(attachment)
            }
            app.buttons["Meeting status"].tap()
            let transcript = app.buttons[language == "ru" ? "Посмотреть расшифровку" : "View transcript"]
            XCTAssertTrue(transcript.waitForExistence(timeout: 5))
            transcript.tap()
            XCTAssertTrue(app.segmentedControls["Conversation mode"].waitForExistence(timeout: 5))
            app.buttons[language == "ru" ? "Закрыть беседу" : "Close conversation"].tap()
            app.openMeetingMore(.meeting)
            app.meetingActionButton("Provider action").tap()
            app.buttons["Meeting status"].tap()
            app.buttons["Continue"].tap()
            let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.buttons["Meeting status"].label.contains("Action completed")
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 5), .completed)
            app.terminate()
        }
    }
    func testFocusRoutineNoticeStaysHiddenAndPrivacyUsesOnlyCompactHeader() throws {
        let app = launch(scenario: "notices")
        let viewport = app.scrollViews["Shared screen viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 4)
        app.openMeetingMore(.meeting); app.meetingActionButton("Routine notice in focus").tap()
        app.buttons["Hide controls"].tap()
        Thread.sleep(forTimeInterval: 4)
        XCTAssertFalse(app.buttons["Leave"].exists)
        XCTAssertFalse(app.otherElements["Compact meeting header"].exists)
        viewport.tap()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 5))
        viewport.pinch(withScale: 2, velocity: 1)
        let zoom = try XCTUnwrap(viewport.value as? String)
        app.openMeetingMore(.meeting); app.meetingActionButton("Recording in focus").tap()
        app.buttons["Hide controls"].tap()
        let header = app.otherElements["Compact meeting header"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertEqual(header.frame.height, 44)
        XCTAssertFalse(app.buttons["Leave"].exists)
        XCTAssertFalse(header.frame.intersects(viewport.frame))
        XCTAssertEqual(viewport.value as? String, zoom)
        let expired = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !header.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expired], timeout: 6), .completed)
        XCTAssertEqual(viewport.value as? String, zoom)
    }

    func testCompactSDKLayoutAllowsButtonsAndSwipeNavigation() {
        let app = launch(scenario: "compact")
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["Next stream"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Next stream"].isHittable)
        app.buttons["Next stream"].tap()
        XCTAssertTrue(app.buttons["Pin Aram video"].waitForExistence(timeout: 5))
        app.buttons["Previous stream"].tap()
        let viewport = app.scrollViews["Shared screen viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        viewport.swipeLeft()
        XCTAssertTrue(app.buttons["Pin Aram video"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Next stream"].waitForExistence(timeout: 5))
        app.buttons["Automatic view"].tap()
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["Next stream"].isHittable)
    }

    func testSoloMeetingKeepsInviteShortcutAboveSelfTile() {
        defer { XCUIDevice.shared.orientation = .portrait }
        for language in ["en", "ru"] {
            let app = launch(language, scenario: "solo")
            let invite = app.buttons[language == "ru" ? "Пригласить музыкантов" : "Invite musicians"]
            XCTAssertTrue(invite.waitForExistence(timeout: 10))
            for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft, .portrait] {
                XCUIDevice.shared.orientation = orientation
                let landscape = orientation == .landscapeLeft
                let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    let frame = app.windows.firstMatch.frame
                    return (frame.width > frame.height) == landscape && frame.contains(invite.frame) && invite.isHittable
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
                XCTAssertEqual(app.staticTexts.matching(identifier: "Participant name").count, 0)
                XCTAssertFalse(app.buttons["Next stream"].exists)
            }
            app.buttons[language == "ru" ? "Копировать ссылку" : "Copy link"].tap()
            app.buttons[language == "ru" ? "Чат" : "Chat"].tap()
            XCTAssertTrue(app.segmentedControls["Conversation mode"].buttons[language == "ru" ? "Чат" : "Chat"].isSelected)
            app.buttons[language == "ru" ? "Закрыть беседу" : "Close conversation"].tap()
            XCTAssertTrue(invite.exists)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "Solo meeting invitation \(language)"; attachment.lifetime = .keepAlways; add(attachment)
            app.terminate()
        }
    }
    private func assertControls(_ app: XCUIApplication, language: String) {
        let labels = language == "ru" ? ["Включить микрофон", "Включить видео", "Транслировать экран", "call.reactions", "Выйти"] :
            ["Unmute microphone", "Start video", "Share screen", "call.reactions", "Leave"]
        let window = app.windows.firstMatch.frame
        for label in labels {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5), label)
            XCTAssertTrue(button.isHittable, label)
            XCTAssertTrue(window.contains(button.frame), "\(label): \(button.frame)")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        let name = app.staticTexts.matching(identifier: "Participant name").firstMatch
        XCTAssertTrue(name.exists)
        let toolbar = app.otherElements["Meeting toolbar"]
        XCTAssertFalse(name.frame.intersects(toolbar.frame), "Name must not be under the toolbar")
    }
    func testGuestControlsAndFooterFitEnglishAndRussianRotation() {
        defer { XCUIDevice.shared.orientation = .portrait }
        for language in ["en", "ru"] {
            let app = launch(language)
            XCTAssertTrue(app.scrollViews["Shared screen viewport"].waitForExistence(timeout: 10))
            for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft, .portrait, .landscapeRight, .portrait] {
                XCUIDevice.shared.orientation = orientation
                let landscape = orientation == .landscapeLeft || orientation == .landscapeRight
                let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    let frame = app.windows.firstMatch.frame
                    let leave = app.buttons[language == "ru" ? "Выйти" : "Leave"].frame
                    return (frame.width > frame.height) == landscape && frame.contains(leave)
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
                assertControls(app, language: language)
            }
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "Guest controls \(language)"; attachment.lifetime = .keepAlways; add(attachment)
            app.terminate()
        }
    }
    func testRussianLargestTextKeepsActionsVisible() {
        let app = launch("ru", largeText: true)
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["Выйти"].waitForExistence(timeout: 10))
        for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let landscape = orientation == .landscapeLeft
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return (frame.width > frame.height) == landscape && frame.contains(app.buttons["Выйти"].frame)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
            assertControls(app, language: "ru")
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Largest Russian text"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testAutoHideWaitsForMenuAndRestoresWithoutClickThrough() {
        let app = launch(autoHide: true)
        XCTAssertTrue(app.buttons["call.reactions"].waitForExistence(timeout: 10))
        app.openMeetingMore(.view)
        Thread.sleep(forTimeInterval: 6)
        XCTAssertTrue(app.buttons["All video"].exists, "The tool surface must remain open while auto-hide is deferred")
        app.meetingActionButton("All video").tap()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 2), "Dismissing tools should restore visible controls before auto-hide resumes")
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !app.buttons["Leave"].exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["Show controls, Mic off"].exists)
        app.scrollViews["Shared screen viewport"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Pin Ani’s arrangement screen share"].exists,
            "Restoring controls must not trigger the control underneath the tap")
    }

    func testImmersiveShareEscapesClippedSafeAreaHostAndZoomsEdgeToEdge() throws {
        let app = launch(scenario: "safe-area-host")
        defer { XCUIDevice.shared.orientation = .portrait }
        let viewport = app.scrollViews["Shared screen viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        XCTAssertEqual(viewport.value as? String, "100%")
        app.buttons["Hide controls"].tap()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            let window = app.windows.firstMatch
            let coversWindow = NSPredicate { _, _ in
                let frame = viewport.frame, bounds = window.frame
                return abs(frame.minX - bounds.minX) < 1 && abs(frame.minY - bounds.minY) < 1 &&
                    abs(frame.width - bounds.width) < 1 && abs(frame.height - bounds.height) < 1
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: coversWindow, object: nil)], timeout: 5), .completed)
            XCTAssertEqual(window.frame.width > window.frame.height, orientation != .portrait)
        }
        viewport.pinch(withScale: 3, velocity: 1)
        XCTAssertNotEqual(viewport.value as? String, "100%")
        let pixelsFillWindow = NSPredicate { _, _ in
            guard let image = XCUIScreen.main.screenshot().image.cgImage,
                  let pixel = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            for x in [0.1, 0.5, 0.9] {
                for y in [0.1, 0.5, 0.9] {
                    guard let sample = image.cropping(to: CGRect(x: Double(image.width) * x,
                        y: Double(image.height) * y, width: 1, height: 1)) else { return false }
                    pixel.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    guard let bytes = pixel.data?.assumingMemoryBound(to: UInt8.self),
                          max(bytes[0], bytes[1], bytes[2]) > 8 else { return false }
                }
            }
            return true
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: pixelsFillWindow, object: nil)], timeout: 5), .completed,
            "Zoomed checkerboard pixels must reach both sides of the display after rotation")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Immersive shared screen uses full display after zoom"; shot.lifetime = .keepAlways
        add(shot)
        viewport.swipeLeft()
        XCTAssertFalse(app.buttons["Leave"].exists)
        viewport.tap()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 5))
    }

    func testFocusPreservesZoomAndPinAcrossRotation() throws {
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        let viewport = app.scrollViews["Shared screen viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        app.buttons["Pin Ani’s arrangement screen share"].tap()
        viewport.pinch(withScale: 2, velocity: 1)
        let zoom = try XCTUnwrap(viewport.value as? String)
        XCTAssertNotEqual(zoom, "100%")
        app.buttons["Hide controls"].tap()
        XCTAssertFalse(app.buttons["Leave"].exists)
        XCTAssertFalse(app.buttons["Show controls, Mic off"].exists)
        viewport.swipeLeft()
        XCTAssertFalse(app.buttons["Leave"].exists, "Panning must keep the shared screen unobstructed")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(viewport.value as? String, zoom)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Participant name").count, 0)
        viewport.tap()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 5))
        XCTAssertEqual(viewport.value as? String, zoom)
        XCTAssertTrue(app.buttons["Unpin Ani’s arrangement screen share"].exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Participant name").count, 1)
    }

    func testTapTogglesChromeWhileDoubleTapOnlyZooms() {
        let app = launch()
        let viewport = app.scrollViews["Shared screen viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        viewport.doubleTap()
        XCTAssertEqual(viewport.value as? String, "200%")
        XCTAssertTrue(app.buttons["Leave"].exists, "A double tap must not toggle controls")
        viewport.tap()
        // A single tap waits for the double-tap recognizer to fail before toggling.
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !app.buttons["Leave"].exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed)
        viewport.doubleTap()
        XCTAssertEqual(viewport.value as? String, "100%")
        XCTAssertFalse(app.buttons["Leave"].exists)
        viewport.pinch(withScale: 2, velocity: 1)
        XCTAssertNotEqual(viewport.value as? String, "100%")
        XCTAssertFalse(app.buttons["Leave"].exists, "Pinching must not restore controls")
        viewport.tap()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 5))
    }

    func testFocusHintFadesAndDoesNotReturnDuringMeeting() {
        for language in ["en", "ru"] {
            let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
            app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", "en_US",
                                   "-hasSeenMeetingControlsHint", "NO", "-automaticallyHideMeetingControls", "NO"]
            app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
            app.launch()
            let viewport = app.scrollViews["Shared screen viewport"]
            XCTAssertTrue(viewport.waitForExistence(timeout: 10))
            viewport.tap()
            let hint = app.staticTexts["Meeting controls hint"]
            XCTAssertTrue(hint.waitForExistence(timeout: 1))
            let faded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !hint.exists }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [faded], timeout: 4), .completed)
            XCTAssertFalse(app.buttons["Show controls, Mic off"].exists)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Unobstructed shared screen \(language)"; screenshot.lifetime = .keepAlways; add(screenshot)
            viewport.tap(); viewport.tap()
            XCTAssertFalse(hint.exists, "The teaching hint must not become another persistent overlay")
            app.terminate()
        }
    }

    func testCommunityCanvasRestoresControlsWithoutFloatingButton() {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)", "-automaticallyHideMeetingControls", "NO"]
        app.launchEnvironment["CONFERENCE_TEST_LAYOUT_FIXTURE"] = "rock"
        app.launch()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 10))
        app.openMeetingMore(.view)
        app.meetingActionButton("Hide controls").tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !app.buttons["Leave"].exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["Show controls, Mic off"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 5))
    }
    func testSwipeBrowsesAtFitAndPansWhenZoomed() throws {
        let app = launch()
        let viewport = app.scrollViews["Shared screen viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        viewport.pinch(withScale: 2, velocity: 1)
        viewport.swipeLeft()
        XCTAssertTrue(viewport.exists, "Zoomed drag pans instead of selecting another stream")
        app.openMeetingMore(.view)
        app.meetingActionButton("Fit shared screen").tap()
        expectation(for: NSPredicate(format: "value == '100%'"), evaluatedWith: viewport)
        waitForExpectations(timeout: 5)
        viewport.swipeLeft()
        XCTAssertTrue(app.buttons["Pin Aram video"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Automatic view"].exists)
        app.buttons["Automatic view"].tap()
        XCTAssertTrue(app.buttons["Pin Ani’s arrangement screen share"].waitForExistence(timeout: 5))
    }

    func testLandscapeHeaderKeepsNavigationAndPinOutsideMedia() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        for language in ["en", "ru"] {
            let app = launch(language)
            let viewport = app.scrollViews["Shared screen viewport"]
            XCTAssertTrue(viewport.waitForExistence(timeout: 10))
            XCUIDevice.shared.orientation = .landscapeLeft
            let header = app.otherElements["Compact meeting header"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                header.exists && header.frame.height == 44 && app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            XCTAssertEqual(app.otherElements["Meeting toolbar"].frame.width, 56, accuracy: 1)
            let next = app.buttons[language == "ru" ? "Следующий поток" : "Next stream"]
            XCTAssertTrue(next.isHittable)
            XCTAssertLessThanOrEqual(next.frame.maxY, viewport.frame.minY)
            let pin = app.buttons[language == "ru" ? "Закрепить Ani’s arrangement трансляция экрана" : "Pin Ani’s arrangement screen share"]
            XCTAssertTrue(pin.isHittable)
            XCTAssertLessThanOrEqual(pin.frame.maxY, viewport.frame.minY)
            pin.tap()
            XCTAssertFalse(next.isEnabled)
            app.buttons[language == "ru" ? "Автоматический выбор" : "Automatic view"].tap()
            XCTAssertTrue(next.isEnabled)
            app.buttons["Meeting details"].tap()
            XCTAssertTrue(app.buttons[language == "ru" ? "Копировать ссылку" : "Copy link"].waitForExistence(timeout: 5))
            app.buttons[language == "ru" ? "Копировать ссылку" : "Copy link"].tap()
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "Compact landscape \(language)"; attachment.lifetime = .keepAlways; add(attachment)
            app.buttons["Meeting details"].tap()
            app.buttons[language == "ru" ? "Пригласить музыкантов" : "Invite musicians"].tap()
            let sharing = app.otherElements["Invitation sharing"]
            if !sharing.waitForExistence(timeout: 5) {
                let failure = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                failure.name = "Invitation sharing failure \(language)"; failure.lifetime = .keepAlways; add(failure)
                print(app.debugDescription)
                XCTFail("Invite must present the system share sheet")
            }
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
    }

    func testZoomToolsFadeAndMoreKeepsFitAvailable() throws {
        let app = launch()
        let viewport = app.scrollViews["Shared screen viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        viewport.pinch(withScale: 2, velocity: 1)
        let zoom = try XCTUnwrap(viewport.value as? String)
        XCTAssertNotEqual(zoom, "100%")
        let fit = app.buttons["Fit shared screen at 100%"]
        XCTAssertTrue(fit.isHittable)
        let faded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !fit.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [faded], timeout: 6), .completed)
        XCTAssertEqual(viewport.value as? String, zoom)
        app.openMeetingMore(.view)
        app.meetingActionButton("Fit shared screen").tap()
        expectation(for: NSPredicate(format: "value == '100%'"), evaluatedWith: viewport)
        waitForExpectations(timeout: 5)
    }
}
