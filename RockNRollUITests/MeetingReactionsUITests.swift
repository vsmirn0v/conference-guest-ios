import XCTest
import UIKit

final class MeetingReactionsUITests: XCTestCase {
    /// Drives the real SDK while an independent client verifies receipt.
    /// Submission counts alone are not remote-delivery confirmation.
    func testLiveGuestManualReactionsWithReceiver() throws {
        guard let invite = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_REACTIONS_REMOTE_INVITE"] else {
            throw XCTSkip("Opt-in independent-client reaction qualification")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invite
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Reaction sender QA"
        app.launchEnvironment["CONFERENCE_TEST_REACTIONS"] = "1"
        #if targetEnvironment(simulator)
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        #endif
        XCUIDevice.shared.orientation = .portrait
        defer {
            if app.buttons["Leave"].firstMatch.exists { app.buttons["Leave"].firstMatch.tap() }
            app.terminate()
        }
        app.launch()
        let more = app.buttons["call.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        let submitted = app.staticTexts["reactions.test-submitted"]
        for (index, kind) in ["like", "dislike"].enumerated() {
            more.tap()
            assertUnsupportedReactionsAbsent(app)
            let button = app.buttons["reactions.send.\(kind)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5)); XCTAssertTrue(button.isEnabled)
            button.tap()
            XCTAssertEqual(submitted.value as? String, String(index + 1))
            XCTAssertEqual(submitted.label, kind)
            print("Independent receiver check: submitted \(kind)")
            // Keep each transient reaction observable to the external receiver.
            Thread.sleep(forTimeInterval: 8)
        }
    }

    func testLiveIdleGuestReactionsStayInsidePalette() throws {
        guard let invite = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_REACTIONS_INVITE"] else {
            throw XCTSkip("Opt-in live guest overlay qualification")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invite
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Idle overlay QA"
        app.launchEnvironment["CONFERENCE_TEST_REACTIONS"] = "1"
        #if targetEnvironment(simulator)
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        #endif
        XCUIDevice.shared.orientation = .portrait
        defer {
            if app.buttons["Leave"].firstMatch.exists { app.buttons["Leave"].firstMatch.tap() }
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        app.launch()
        let invitation = app.buttons["Invite musicians"].firstMatch
        guard invitation.waitForExistence(timeout: 30) else {
            XCTFail("This check needs an otherwise empty guest room")
            return
        }
        assertEmptyStageEdges(app, invitation: invitation)
        let more = app.buttons["call.more"]
        more.tap()
        assertUnsupportedReactionsAbsent(app)
        for kind in ["like", "dislike"] {
            XCTAssertTrue(app.buttons["reactions.send.\(kind)"].isHittable)
            XCTAssertTrue(app.buttons["reactions.send.\(kind)"].isEnabled)
        }
        app.buttons["reactions.done"].tap()
        assertEmptyStageEdges(app, invitation: invitation)
        more.tap()
        app.buttons["reactions.send.like"].tap()
        XCTAssertEqual(app.staticTexts["reactions.test-submitted"].value as? String, "1")
        assertEmptyStageEdges(app, invitation: invitation)
        XCUIDevice.shared.orientation = .landscapeLeft
        // iOS 17's XCTest idle check can return during the system rotation
        // animation. Pixel assertions must inspect the settled presentation.
        Thread.sleep(forTimeInterval: 1)
        assertEmptyStageEdges(app, invitation: invitation)
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1)
        assertEmptyStageEdges(app, invitation: invitation)
    }

    private func assertEmptyStageEdges(_ app: XCUIApplication, invitation: XCUIElement,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.buttons["reactions.send.like"].exists, file: file, line: line)
        XCTAssertTrue(invitation.isHittable, file: file, line: line)
        var screenshot = XCUIScreen.main.screenshot()
        let deadline = Date().addingTimeInterval(6)
        func matchesWindow(_ image: UIImage) -> Bool {
            let size = app.frame.size
            return abs(image.size.width - size.width) < 1 && abs(image.size.height - size.height) < 1
        }
        // XCTest can report idle while the system is still rotating the
        // presentation. Never crop a portrait screenshot using landscape AX frames.
        while !matchesWindow(screenshot.image) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            screenshot = XCUIScreen.main.screenshot()
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Idle guest stage"; attachment.lifetime = .keepAlways; add(attachment)
        guard matchesWindow(screenshot.image) else {
            XCTFail("Screenshot orientation did not settle to match the window", file: file, line: line)
            return
        }
        let frame = invitation.frame
        let band = CGRect(x: app.frame.minX + 8, y: frame.midY - 22,
                          width: max(0, frame.minX - app.frame.minX - 20), height: 44)
        let right = CGRect(x: frame.maxX + 12, y: band.minY,
                           width: max(0, app.frame.maxX - frame.maxX - 20), height: 44)
        for rect in [band, right] where rect.width > 0 {
            XCTAssertLessThan(coloredPixels(screenshot.image, rect: rect), 8,
                "A reaction picker covers the idle meeting outside its invitation button", file: file, line: line)
        }
    }

    private func coloredPixels(_ image: UIImage, rect: CGRect) -> Int {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        // Older runtimes keep landscape CGImage pixels in portrait orientation.
        let normalized = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let source = normalized.cgImage else { XCTFail("Screenshot has no pixels"); return .max }
        let pixels = CGRect(x: rect.minX * image.scale, y: rect.minY * image.scale,
                            width: rect.width * image.scale, height: rect.height * image.scale).integral
        guard let crop = source.cropping(to: pixels) else { XCTFail("Invalid screenshot crop"); return .max }
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            return true
        }
        guard drawn else { XCTFail("Screenshot conversion failed"); return .max }
        return stride(from: 0, to: bytes.count, by: 4).reduce(0) { count, index in
            let channels = [bytes[index], bytes[index + 1], bytes[index + 2]]
            return count + (Int(channels.max()!) - Int(channels.min()!) > 40 && channels.max()! > 120 ? 1 : 0)
        }
    }

    func testWideReactionShortcut() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
        app.launchEnvironment["CONFERENCE_TEST_GUEST_SCENARIO"] = "reactions"
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        app.launch()
        guard app.frame.width >= 700 else { throw XCTSkip("Direct shortcut requires a wide layout; compact screens use More") }
        let shortcut = app.buttons["call.reactions"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 10)); XCTAssertTrue(shortcut.isHittable)
        shortcut.tap()
        XCTAssertTrue(app.buttons["reactions.send.dislike"].waitForExistence(timeout: 5))
        app.buttons["reactions.send.dislike"].tap()
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
        for kind in ["like", "dislike"] {
            more.tap()
            let send = app.buttons["reactions.send.\(kind)"]
            XCTAssertTrue(send.waitForExistence(timeout: 5)); XCTAssertTrue(send.isEnabled)
            send.tap()
            Thread.sleep(forTimeInterval: 2)
        }
        let sent = app.staticTexts["reactions.test-submitted"]
        XCTAssertEqual(sent.value as? String, "2")
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
            let forwarded = expectation(for: NSPredicate(format: "value == %@", String(3 + index)), evaluatedWith: sent)
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
    private func assertUnsupportedReactionsAbsent(_ app: XCUIApplication,
                                                    file: StaticString = #filePath, line: UInt = #line) {
        for kind in ["applause", "smile", "surprise"] {
            XCTAssertFalse(app.buttons["reactions.send.\(kind)"].exists,
                           "Unqualified reaction is offered in the palette", file: file, line: line)
        }
    }
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
        assertUnsupportedReactionsAbsent(app)
        for kind in ["like", "dislike"] {
            let button = app.buttons["reactions.send.\(kind)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5)); XCTAssertTrue(button.isHittable)
        }
        app.buttons["reactions.send.like"].tap()
        XCTAssertFalse(app.buttons["reactions.done"].waitForExistence(timeout: 1))
        more.tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["reactions.send.dislike"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["reactions.send.dislike"].isHittable)
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
