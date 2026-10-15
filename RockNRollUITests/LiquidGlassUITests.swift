import XCTest

final class LiquidGlassUITests: XCTestCase {
    func testNativeAudioControlIsReachableAndOpensPickerWhereSupported() {
        let app = launch()
        defer { app.terminate() }
        let isMac = ProcessInfo.processInfo.isiOSAppOnMac
        let output = app.buttons[isMac ? "Mac audio devices" : "AirPlay"]
        guard output.waitForExistence(timeout: 10) else {
            XCTFail("Native audio control missing: \(app.debugDescription)"); return
        }
        XCTAssertTrue(output.isHittable)
        #if targetEnvironment(simulator)
        // AVRoutePickerView's service does not present routes in Simulator.
        // The actual Mac picker is covered by the mounted integration test;
        // hardware iOS presentation remains a separate qualification step.
        attach("Reachable native audio control in Simulator")
        return
        #endif
        output.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let shown = NSPredicate { _, _ in
            if isMac {
                return app.navigationBars["Audio devices"].exists && app.tables.count > 0
            }
            return app.staticTexts["AirPlay"].exists || springboard.staticTexts["AirPlay"].exists
        }
        let ready = XCTNSPredicateExpectation(predicate: shown, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: 8)
        if result != .completed {
            print("AUDIO PICKER APP: \(app.debugDescription)")
            print("AUDIO PICKER SYSTEM: \(springboard.debugDescription)")
        }
        XCTAssertEqual(result, .completed, "The native route chooser must actually present")
        attach("Native audio picker from glass dock")
    }

    func testSystemBroadcastPickerOpensWithoutStartingPublication() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("ReplayKit system broadcast presentation requires the physical iPhone")
        #else
        guard !ProcessInfo.processInfo.isiOSAppOnMac else {
            throw XCTSkip("Mac uses its native ScreenCaptureKit source chooser")
        }
        let app = launch(nativeSharing: true)
        defer { app.terminate() }
        let share = app.buttons["Share screen"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let shown = NSPredicate { _, _ in
            app.buttons["Start Broadcast"].exists || springboard.buttons["Start Broadcast"].exists
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: shown, object: nil)], timeout: 8)
        if result != .completed {
            print("BROADCAST PICKER APP: \(app.debugDescription)")
            print("BROADCAST PICKER SYSTEM: \(springboard.debugDescription)")
        }
        XCTAssertEqual(result, .completed, "The masked native broadcast button must present its chooser")
        attach("Native broadcast chooser without starting capture")
        #endif
    }

    private func launch(nativeSharing: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_LAYOUT_FIXTURE"] = "rock"
        if nativeSharing { app.launchEnvironment["CONFERENCE_TEST_NATIVE_PICKERS"] = "1" }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
