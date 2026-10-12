import XCTest
import UIKit

/// Opt-in destructive media-service test in a disposable, authorized room.
/// Uses the public Settings control; posting a notification is not equivalent.
final class MediaServicesResetUITests: XCTestCase {
    func testGuestVideoAfterActualMediaServicesReset() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let invite = environment["ROCKNROLL_TEST_RESET_INVITE"] else {
            throw XCTSkip("Requires physical iPhone and an authorized moving-video source")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invite
        app.launchEnvironment["CONFERENCE_TEST_MEDIA_TRACE"] = "1"
        app.launchEnvironment["CONFERENCE_TEST_LEGACY_RENDERER"] = environment["ROCKNROLL_TEST_RESET_LEGACY"] ?? "0"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-floatingVideoWhenMultitasking", "YES"]
        app.launch()
        guard app.buttons["Leave"].waitForExistence(timeout: 40) else {
            XCTFail("Meeting did not open: \(app.debugDescription)"); return
        }
        guard movingVideo(app) else {
            XCTFail("Require working moving video before resetting services"); return
        }
        let baseline = XCTAttachment(screenshot: app.screenshot())
        baseline.name = "Before actual media-service reset"; baseline.lifetime = .keepAlways; add(baseline)

        guard resetMediaServices() else { return }
        app.activate()
        guard app.buttons["Leave"].waitForExistence(timeout: 45) else {
            XCTFail("Meeting did not recover: \(app.debugDescription)"); return
        }
        let moving = movingVideo(app)
        let result = XCTAttachment(screenshot: app.screenshot())
        result.name = "After actual media-service reset"; result.lifetime = .keepAlways; add(result)
        let waiting = app.staticTexts["Waiting for video…"]
        XCTAssertFalse(waiting.exists, "Remote moving-video source must render again")
        XCTAssertTrue(moving, "Actual incoming picture must change after reset")
        if environment["ROCKNROLL_TEST_RESET_PIP"] == "1" {
            Thread.sleep(forTimeInterval: 8)
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 12)
            let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let pip = XCTAttachment(screenshot: home.screenshot())
            pip.name = "PiP after genuine reset"; pip.lifetime = .keepAlways; add(pip)
            Thread.sleep(forTimeInterval: 0.3)
            let second = XCTAttachment(screenshot: home.screenshot())
            second.name = "PiP after genuine reset second frame"; second.lifetime = .keepAlways; add(second)
            app.activate()
            XCTAssertTrue(movingVideo(app), "Video must keep moving after PiP")
        }
        // Shell trace inspection corroborates actual decoded/enqueued frames;
        // this UI assertion alone is not a speech or moving-pixel acceptance.
    }

    func testRendererProbeAfterActualReset() throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_RENDERER_RESET_PROBE"] == "1" else {
            throw XCTSkip("Requires an available physical iPhone")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_RENDERER_RESET_PROBE"] = "1"
        app.launchEnvironment["CONFERENCE_TEST_RENDERER_PROBE_MODE"] = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_RENDERER_PROBE_MODE"]
        app.launchEnvironment["CONFERENCE_TEST_RENDERER_PROBE_AUDIO"] = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_RENDERER_PROBE_AUDIO"]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["renderer-probe.summary"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "Renderer probe before reset"; before.lifetime = .keepAlways; add(before)
        guard resetMediaServices() else { return }
        app.activate()
        Thread.sleep(forTimeInterval: 15)
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "Renderer probe after reset"; after.lifetime = .keepAlways; add(after)
        print("Renderer probe post-reset UI: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["renderer-probe.summary"].label.contains("resets=1"),
            "Must observe an actual OS reset; a button tap alone is not sufficient")
        let selected = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_RENDERER_PROBE_MODE"]
        for mode in selected.map({ [$0] }) ?? ["legacy", "renderer", "receiver"] {
            let surface = app.otherElements["renderer-probe.\(mode).video"]
            XCTAssertTrue(surface.exists, "The requested renderer must actually be tested")
            let a = surface.screenshot().image.pngData()
            Thread.sleep(forTimeInterval: 0.3)
            XCTAssertNotEqual(a, surface.screenshot().image.pngData(), "Generated picture must move after reset")
        }
    }

    private func resetMediaServices() -> Bool {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        if settings.sheets.firstMatch.exists {
            let cancel = settings.sheets.buttons["Cancel"]
            guard cancel.exists else { XCTFail("Unexpected Settings sheet"); return false }
            cancel.tap()
        }
        let reset = settings.descendants(matching: .any).matching(NSPredicate(format:
            "label IN %@", ["Reset Media Services", "Сбросить медиаслужбы", "Сброс медиаслужб"])).firstMatch
        if !reset.waitForExistence(timeout: 3) {
            let developer = settings.descendants(matching: .any).matching(NSPredicate(format:
                "label IN %@", ["Developer", "Разработчик"])).firstMatch
            for _ in 0..<10 {
                if developer.exists && developer.isHittable { break }
                settings.swipeUp()
            }
            guard developer.exists && developer.isHittable else {
                XCTFail("Developer settings must be available"); return false
            }
            developer.tap()
        }
        for _ in 0..<6 {
            if reset.exists && reset.isHittable { break }
            settings.swipeUp()
        }
        guard reset.exists && reset.isHittable else { XCTFail("Reset control must be hittable"); return false }
        reset.tap()
        if settings.sheets.firstMatch.waitForExistence(timeout: 2) {
            // iOS 27 lets the tester select which daemon to reset.
            let all = settings.sheets.buttons["Reset All Media Services"]
            guard all.exists else { XCTFail("Unrecognized media-reset chooser"); return false }
            all.tap()
        }
        // Some OS releases show a confirmation. Never choose an unrelated control.
        if settings.alerts.firstMatch.waitForExistence(timeout: 2) {
            let confirm = settings.alerts.buttons.matching(NSPredicate(format:
                "label IN %@", ["Reset", "Reset Media Services", "Сбросить"])).firstMatch
            XCTAssertTrue(confirm.exists); confirm.tap()
        }
        return true
    }

    private func movingVideo(_ app: XCUIApplication) -> Bool {
        let caption = app.staticTexts["Recovery speech source"]
        guard caption.waitForExistence(timeout: 15) else { return false }
        func picture() -> Data? {
            guard let image = app.screenshot().image.cgImage else { return nil }
            let scale = CGFloat(image.width) / app.frame.width, width = app.frame.width
            // Anchor to the source's caption, since local/remote tile order can change.
            let region = CGRect(x: width * 0.25, y: caption.frame.minY - width * 0.4,
                width: width * 0.5, height: width * 0.15)
                .applying(CGAffineTransform(scaleX: scale, y: scale))
            guard let cropped = image.cropping(to: region),
                  let bitmap = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                    bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let pixels = bitmap.data else { return nil }
            bitmap.draw(cropped, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return Data(bytes: pixels, count: 4096)
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            guard let before = picture() else { return false }
            Thread.sleep(forTimeInterval: 0.3)
            if let after = picture(), after != before { return true }
        }
        return false
    }
}
