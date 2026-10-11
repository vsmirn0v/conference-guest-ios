import XCTest

final class PreviewCadenceUITests: XCTestCase {
    func testControlledPreviewMeasurement() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("A physical camera and device power samples are required")
        #else
        let env = ProcessInfo.processInfo.environment
        guard env["ROCK_PREVIEW_MEASURE"] == "1" else { throw XCTSkip("Opt-in physical profiling") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest.previewexperiment")
        app.launchEnvironment["ROCK_PREVIEW_EXPERIMENT"] = "1"
        app.launchEnvironment["ROCK_PREVIEW_SURFACE"] = env["ROCK_PREVIEW_SURFACE"] ?? "native"
        app.launchEnvironment["ROCK_PREVIEW_RATES"] = env["ROCK_PREVIEW_RATES"] ?? "30,60"
        app.launchEnvironment["ROCK_PREVIEW_REVERSE"] = env["ROCK_PREVIEW_REVERSE"] ?? "0"
        app.launchEnvironment["ROCK_PREVIEW_SECONDS"] = env["ROCK_PREVIEW_SECONDS"] ?? "90"
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        defer { app.activate(); if app.buttons["preview.experiment.stop"].exists { app.buttons["preview.experiment.stop"].tap() } }
        let status = app.staticTexts["preview.experiment.status"]
        let ready = expectation(for: NSPredicate(format: "label BEGINSWITH 'Ready'"), evaluatedWith: status)
        wait(for: [ready], timeout: 45)
        print("PREVIEW_MEASURE_READY \(Date().timeIntervalSince1970)")
        sleep(15) // Instruments attaches before either measured phase.
        if env["ROCK_PREVIEW_SURFACE"] == "pip" {
            XCUIDevice.shared.press(.home)
            let pip = XCUIApplication(bundleIdentifier: "com.apple.springboard").windows["PIP-SBInteractionPassThroughView"]
            XCTAssertTrue(pip.waitForExistence(timeout: 10))
        } else { app.buttons["preview.experiment.begin"].tap() }
        let duration = min(110, max(15, Double(env["ROCK_PREVIEW_SECONDS"] ?? "90") ?? 90))
        let phases = (env["ROCK_PREVIEW_RATES"] ?? "30,60").split(separator: ",").count
        sleep(UInt32(Double(phases) * (duration + 12) + 6))
        app.activate()
        XCTAssertEqual(status.label, "Complete", "Do not accept a partial/interrupted measurement")
        print("PREVIEW_MEASURE_COMPLETE \(Date().timeIntervalSince1970)")
        #endif
    }
}
