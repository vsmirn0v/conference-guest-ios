import XCTest

/// Physical OS discovery and normal-app inspection. No fixture activities are
/// injected; settings and meeting actions require separate explicit gates.
final class HandoffReadOnlyDeviceTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")

    func testReturnToNormalSourceAndCapture() throws {
        try requireOptIn()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        if ProcessInfo.processInfo.environment["ROCK_HANDOFF_EXPECT_SOURCE_ENDED"] == "1" {
            XCTAssertTrue(app.buttons["join.start"].waitForExistence(timeout: 45), "The moved source must return to its normal Home")
            XCTAssertFalse(app.buttons["call.microphone"].exists)
        }
        capture(app, "Current normal iPhone source state")
    }

    func testPrepareObservedNormalApp() throws {
        try requireOptIn()
        guard ProcessInfo.processInfo.environment["ROCK_HANDOFF_ALLOW_OBSERVER_RELAUNCH"] == "1" else {
            throw XCTSkip("Requires an explicitly coordinated idle app before observer relaunch")
        }
        continueAfterFailure = false
        app.terminate()
        app.launchEnvironment = ["CONFERENCE_TEST_MEDIA_TRACE": "1", "ROCKNROLL_RECEIVE_DELAY": "1"]
        app.launch()
        XCTAssertTrue(app.buttons["join.start"].waitForExistence(timeout: 15))
        capture(app, "Normal Production iPhone Home with observer-only media trace")
    }

    func testInspectNormalCloudSettings() throws {
        try requireOptIn()
        continueAfterFailure = false
        app.activate()
        capture(app, "Normal iPhone app before settings")
        try openCloudSettings()
        capture(app, "Normal iPhone cloud and active-jam settings")
        print("NORMAL_HANDOFF_SETTINGS," + app.switches.allElementsBoundByIndex.map {
            "\($0.label)=\(String(describing: $0.value))"
        }.joined(separator: ","))
    }

    func testEnableCloudAndActiveSharingIfOff() throws {
        try requireOptIn()
        guard ProcessInfo.processInfo.environment["ROCK_HANDOFF_ALLOW_CLOUD_SETTINGS"] == "1" else {
            throw XCTSkip("An explicitly authorized normal-app sync/sharing change is required")
        }
        continueAfterFailure = false
        app.activate()
        try openCloudSettings()
        let sync = app.switches.matching(NSPredicate(format: "label == %@ OR label == %@", "Sync with iCloud", "Синхронизация iCloud")).firstMatch
        XCTAssertTrue(sync.waitForExistence(timeout: 10))
        if sync.value as? String == "0" { sync.tap() }
        let sharing = app.switches.matching(NSPredicate(format: "label == %@ OR label == %@", "Show active jams on my devices", "Показывать активные джемы на моих устройствах")).firstMatch
        XCTAssertTrue(sharing.waitForExistence(timeout: 20))
        if sharing.value as? String == "0" { sharing.tap() }
        XCTAssertEqual(sync.value as? String, "1")
        XCTAssertEqual(sharing.value as? String, "1")
        capture(app, "Authorized normal iPhone sync and active sharing enabled")
    }

    func testCaptureActualSystemHandoffDiscovery() throws {
        try requireOptIn()
        openActualSwitcher()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        capture(system, "Actual iOS app switcher Handoff discovery")
        print("SYSTEM_HANDOFF_DISCOVERY_CAPTURED=true")
    }

    func testInspectSystemHandoffSetting() throws {
        try requireOptIn()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate(); settings.launch()
        defer { app.activate() }
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        capture(settings, "Actual system settings before Handoff inspection")
        for _ in 0..<5 {
            if settings.staticTexts["General"].exists || settings.staticTexts["Основные"].exists { break }
            let back = settings.buttons["BackButton"]
            guard back.exists else { break }
            back.tap()
        }
        for labels in [["General", "Основные"], ["AirPlay & Continuity", "AirPlay и Непрерывность"], ["Handoff"]] {
            if settings.switches.matching(NSPredicate(format: "label CONTAINS %@", "Handoff")).firstMatch.exists { break }
            let item = settings.staticTexts.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            for _ in 0..<4 { if item.exists { break }; settings.swipeUp() }
            if item.waitForExistence(timeout: 5) { item.tap() }
            else { break }
            capture(settings, "Actual system Handoff navigation " + labels[0])
        }
        print("SYSTEM_HANDOFF_SETTINGS," + settings.switches.allElementsBoundByIndex.map {
            "\($0.label)=\(String(describing: $0.value))"
        }.joined(separator: ","))
    }

    func testInspectSystemBluetoothSetting() throws {
        try requireOptIn()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate(); settings.launch()
        defer { app.activate() }
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        for _ in 0..<5 {
            if settings.staticTexts["Bluetooth"].exists { break }
            let back = settings.buttons["BackButton"]
            guard back.exists else { break }
            back.tap()
        }
        let bluetooth = settings.staticTexts["Bluetooth"].firstMatch
        for _ in 0..<4 { if bluetooth.exists { break }; settings.swipeDown() }
        XCTAssertTrue(bluetooth.waitForExistence(timeout: 5))
        bluetooth.tap()
        let power = settings.switches["Bluetooth"].firstMatch
        XCTAssertTrue(power.waitForExistence(timeout: 10))
        capture(settings, "Actual iPhone Bluetooth power setting unchanged")
        print("SYSTEM_BLUETOOTH_POWER=" + String(describing: power.value))
    }

    func testTapObservedSystemHandoffItem() throws {
        try requireOptIn()
        let environment = ProcessInfo.processInfo.environment
        guard environment["ROCK_HANDOFF_TAP_SYSTEM_BANNER"] == "1",
              let label = environment["ROCK_HANDOFF_OBSERVED_ITEM_LABEL"], !label.isEmpty else {
            throw XCTSkip("Requires explicit authorization and an exact item label from actual OS discovery")
        }
        continueAfterFailure = false
        openActualSwitcher()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        capture(system, "Actual OS Handoff item before user-equivalent tap")
        let banner = system.otherElements["handoff-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15))
        let item = banner.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15)); XCTAssertTrue(item.isHittable)
        item.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        capture(app, "Normal app opened by actual OS Handoff")
    }

    func testChooseObservedNormalContinuation() throws {
        try requireOptIn()
        let environment = ProcessInfo.processInfo.environment
        guard environment["ROCK_HANDOFF_ALLOW_MEETING_ACTION"] == "1",
              let label = environment["ROCK_HANDOFF_OBSERVED_ACTION_LABEL"], !label.isEmpty else {
            throw XCTSkip("Requires coordinated live source and exact action label from normal app")
        }
        continueAfterFailure = false
        if environment["ROCK_HANDOFF_CAPTURE_BEFORE_MOVE"] == "1" {
            openActualSwitcher()
            capture(XCUIApplication(bundleIdentifier: "com.apple.springboard"), "Second actual OS Handoff discovery before normal move")
        }
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let action = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 20)); action.tap()
        let status = app.staticTexts["continuationStatus"]
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format:
            "exists == true AND (label == %@ OR label == %@)",
            "Jam moved here. Microphone and camera are off.", "Джем перенесён сюда. Микрофон и камера выключены."), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 45), .completed,
            "A normal transfer must acknowledge source departure, not merely connect another device")
        let microphone = app.buttons["call.microphone"]
        XCTAssertTrue(microphone.exists)
        XCTAssertTrue(["Unmute microphone", "Включить микрофон"].contains(microphone.label))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Start video", "Включить видео")).firstMatch.exists)
        for index in 0..<4 {
            Thread.sleep(forTimeInterval: 5)
            capture(app, "Actual continuation progress \(index)")
        }
    }

    private func openActualSwitcher() {
        XCUIDevice.shared.press(.home)
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(system.wait(for: .runningForeground, timeout: 10))
        capture(system, "Actual iOS Home before switcher discovery")
        let start = system.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
        let finish = system.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.43))
        start.press(forDuration: 0.05, thenDragTo: finish, withVelocity: .slow, thenHoldForDuration: 1)
    }

    private func requireOptIn() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real iPhone and OS Handoff discovery required")
        #else
        guard ProcessInfo.processInfo.environment["ROCK_HANDOFF_NORMAL_UI_INSPECTION"] == "1" else {
            throw XCTSkip("Explicit opt-in for physical normal-app UI inspection")
        }
        #endif
    }

    private func openCloudSettings() throws {
        if app.buttons["settings.devices"].exists { app.buttons["settings.devices"].tap(); return }
        if app.switches.matching(NSPredicate(format: "label CONTAINS %@", "iCloud")).firstMatch.exists { return }
        let settings = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Settings", "Настройки")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Normal app must expose Settings without fixture state or a meeting action")
        settings.tap()
        let devices = app.buttons["settings.devices"]
        XCTAssertTrue(devices.waitForExistence(timeout: 10)); devices.tap()
    }

    private func capture(_ application: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: application.debugDescription)
        hierarchy.name = name + " accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
}
