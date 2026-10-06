import XCTest

final class CalendarPermissionUITests: XCTestCase {
    func testNativeCalendarPermissionIsRequestedOnlyWhenFeatureIsEnabled() {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let monitor = addUIInterruptionMonitor(withDescription: "Calendar access") { alert in
            let allow = alert.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label == %@", "Allow Full Access", "Allow")).firstMatch
            guard allow.exists else { return false }
            allow.tap(); return true
        }
        defer { removeUIInterruptionMonitor(monitor) }
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        app.buttons["Settings"].tap()
        app.buttons["calendar.settings"].tap()
        let enabled = app.switches["calendar.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        if enabled.value as? String == "1" { enabled.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() }
        enabled.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        if springboard.alerts.firstMatch.waitForExistence(timeout: 15) {
            let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label == %@", "Allow Full Access", "Allow")).firstMatch
            XCTAssertTrue(allow.exists)
            allow.tap()
        }
        XCTAssertTrue(app.switches["calendar.automaticJoin"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Allow calendar access"].exists)
        enabled.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        app.terminate()
    }
}
