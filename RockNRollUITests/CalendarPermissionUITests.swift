import XCTest

final class CalendarPermissionUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }
    override func tearDown() {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }
    private func reveal(_ element: XCUIElement, in form: XCUIElement, down: Bool = false) {
        for _ in 0..<10 where !element.isHittable {
            if down { form.swipeDown() } else { form.swipeUp() }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        XCTAssertTrue(element.isHittable)
    }
    func testNativeCalendarPermissionIsRequestedOnlyWhenFeatureIsEnabled() {
        app.launchEnvironment["CONFERENCE_TEST_SKIP_SETUP"] = "1"
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
        // Bind to the settings Form's stable collection/table index rather
        // than swiping Home behind its sheet or requiring virtualized rows.
        let forms = app.collectionViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex
        guard let form = forms.first(where: { $0.switches["calendar.enabled"].exists }) else {
            return XCTFail("Calendar settings must expose its own scrollable Form")
        }
        if enabled.value as? String == "1" { enabled.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() }
        enabled.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        if springboard.alerts.firstMatch.waitForExistence(timeout: 15) {
            let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label == %@", "Allow Full Access", "Allow")).firstMatch
            XCTAssertTrue(allow.exists)
            allow.tap()
        }
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: springboard.alerts.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertEqual(enabled.value as? String, "1")
        let automatic = app.switches["calendar.automaticJoin"]
        reveal(automatic, in: form)
        XCTAssertFalse(app.buttons["Allow calendar access"].exists)
        reveal(enabled, in: form, down: true)
        enabled.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(enabled.value as? String, "0")
    }
}
