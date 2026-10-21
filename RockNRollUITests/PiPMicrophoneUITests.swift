import XCTest
import Vision

final class PiPMicrophoneUITests: XCTestCase {
    func testMicrophoneLevelActuallyRedrawsInBackgroundPiP() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("System video-call PiP requires a physical iPhone")
        #endif
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["CONFERENCE_TEST_UI_FIXTURE": "pip-microphone",
            "CONFERENCE_TEST_RESET_FLOATING_VIDEO": "1", "CONFERENCE_TEST_PIP_LEVELS": "1"]
        app.launch(); defer { app.terminate() }
        app.buttons["Test microphone in PiP"].tap()
        XCUIDevice.shared.press(.home)
        let pip = XCUIApplication(bundleIdentifier: "com.apple.springboard").windows["PIP-SBInteractionPassThroughView"]
        XCTAssertTrue(pip.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        var captures: [Data] = []
        for index in 0..<6 {
            if let pixels = badgePixels(in: pip) { captures.append(pixels) }
            let attachment = XCTAttachment(screenshot: pip.screenshot())
            attachment.name = "PiP input level phase \(index)"; attachment.lifetime = .keepAlways; add(attachment)
            Thread.sleep(forTimeInterval: 2)
        }
        XCTAssertEqual(captures.count, 6)
        XCTAssertGreaterThan(Set(captures).count, 1, "Changing microphone samples must change the visible PiP badge while backgrounded")
    }
    func testRoomTrackPiPStartsMovesAndNeverReturnsAfterLeave() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("AVKit video-call PiP requires a physical iPhone")
        #endif
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "room-pip-energy"
        app.launchEnvironment["CONFERENCE_TEST_RESET_FLOATING_VIDEO"] = "1"
        app.launch(); defer { app.terminate() }
        let start = app.buttons["energy.start-pip"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2); start.tap()
        XCUIDevice.shared.press(.home)
        let pip = XCUIApplication(bundleIdentifier: "com.apple.springboard").windows["PIP-SBInteractionPassThroughView"]
        XCTAssertTrue(pip.waitForExistence(timeout: 10))
        let first = pip.screenshot().pngRepresentation
        Thread.sleep(forTimeInterval: 3)
        XCTAssertNotEqual(first, pip.screenshot().pngRepresentation, "The room-track PiP must continue receiving motion")
        app.activate()
        let end = app.buttons["energy.end-pip"]
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: end); waitForExpectations(timeout: 10)
        end.tap()
        XCUIDevice.shared.press(.home); Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(pip.exists, "Late frames must never revive PiP after Leave")
    }

    func testEndedVideoDoesNotReturnAfterLateSourceUpdatesOrBackgrounding() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("System video-call PiP requires a physical iPhone.")
        #endif
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "pip-microphone"
        app.launchEnvironment["CONFERENCE_TEST_RESET_FLOATING_VIDEO"] = "1"
        app.launch()
        defer { app.terminate() }
        let pip = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .windows["PIP-SBInteractionPassThroughView"]
        app.buttons["Test microphone in PiP"].tap()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(pip.waitForExistence(timeout: 5), "The baseline must have working PiP")
        app.activate()
        let end = app.buttons["End test video"]
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: end); waitForExpectations(timeout: 10)
        end.tap()
        for manual in [false, true] {
            if manual { app.buttons["Test microphone in PiP"].tap() }
            XCUIDevice.shared.press(.home)
            let unwanted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: pip)
            unwanted.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [unwanted], timeout: 3), .completed)
            app.activate()
        }
        // Ending one meeting must not disable PiP in a new session.
        app.terminate()
        app.launch()
        app.buttons["Test microphone in PiP"].tap()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(pip.waitForExistence(timeout: 5))
        app.activate()

        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: end); waitForExpectations(timeout: 10)
        end.tap()
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Ended video stays closed after scene/source updates"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testStatusRedrawsInSystemPiPWithoutVideoFrames() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("System video-call PiP requires a physical iPhone.")
        #endif
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "pip-microphone"
        app.launchEnvironment["CONFERENCE_TEST_RESET_FLOATING_VIDEO"] = "1"
        app.launch()
        defer { app.terminate() }
        app.buttons["Test microphone in PiP"].tap()
        XCUIDevice.shared.press(.home)
        let pip = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .windows["PIP-SBInteractionPassThroughView"]
        XCTAssertTrue(pip.waitForExistence(timeout: 5))
        assertStatus("Aram", in: pip)
        assertStatus("You", in: pip)
        let mutedBadge = badgePixels(in: pip)
        let mutedGray = grayBadgePixels(in: pip)
        XCTAssertGreaterThanOrEqual(mutedGray, 0)
        let badgeSize = pip.frame.size
        let calculator = XCUIApplication(bundleIdentifier: "com.apple.calculator")
        calculator.activate()
        assertStatus("Ani", in: pip)
        assertStatus("You", in: pip)
        XCTAssertNotEqual(mutedBadge, badgePixels(in: pip), "The compact microphone icon did not update")
        XCTAssertTrue(pip.exists)
        XCTAssertEqual(calculator.state, .runningForeground)
        XCTAssertEqual(pip.frame.size, badgeSize)
        // Small PiP deliberately retains only "You" beside the mic glyph.
        // Verify the visible orange/on icon changes to disabled gray without
        // requiring the full status phrase to fit in the compact badge.
        XCTAssertGreaterThan(orangeBadgePixels(in: pip), 10)
        let disabled = expectation(for: NSPredicate { _, _ in
            pip.exists && pip.frame.size == badgeSize && self.orangeBadgePixels(in: pip) == 0
                && self.grayBadgePixels(in: pip) > max(20, mutedGray * 2)
        }, evaluatedWith: pip)
        wait(for: [disabled], timeout: 15)
        assertStatus("You", in: pip)
        XCTAssertTrue(pip.exists)
    }

    private func orangeBadgePixels(in pip: XCUIElement) -> Int {
        badgeGlyphPixels(in: pip) { r, g, b in r > 160 && r * 4 > g * 5 && g * 5 > b * 6 }
    }
    private func grayBadgePixels(in pip: XCUIElement) -> Int {
        badgeGlyphPixels(in: pip) { r, g, b in (190...220).contains(r) && max(r, g, b) - min(r, g, b) < 8 }
    }
    private func badgeGlyphPixels(in pip: XCUIElement, matching color: (Int, Int, Int) -> Bool) -> Int {
        guard let full = pip.screenshot().image.cgImage else { return -1 }
        // This fixed 16:9 fixture uses the compact "You" badge. Exclude its
        // text and the speaker badge: a missing glyph must not pass the check.
        let w = CGFloat(full.width), h = CGFloat(full.height)
        guard let image = full.cropping(to: CGRect(x: w * 0.72, y: h * 0.76, width: w * 0.08, height: h * 0.14)) else { return -1 }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &pixels, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return -1 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 0, to: pixels.count, by: 4).filter {
            color(Int(pixels[$0]), Int(pixels[$0 + 1]), Int(pixels[$0 + 2]))
        }.count
    }

    private func badgePixels(in pip: XCUIElement) -> Data? {
        guard let image = pip.screenshot().image.cgImage else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        return image.cropping(to: CGRect(x: width * 0.53, y: height * 0.77,
                                        width: width * 0.43, height: height * 0.17))
            .map { UIImage(cgImage: $0).pngData() } ?? nil
    }

    private func assertStatus(_ text: String, in pip: XCUIElement) {
        let visible = expectation(for: NSPredicate { _, _ in
            guard let image = pip.screenshot().image.cgImage else { return false }
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["en-US"]
            request.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: image).perform([request])
            return request.results?.contains {
                $0.topCandidates(1).first?.string.contains(text) == true
            } == true
        }, evaluatedWith: pip)
        wait(for: [visible], timeout: 15)
        let attachment = XCTAttachment(screenshot: pip.screenshot())
        attachment.name = "Physical PiP · \(text)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
