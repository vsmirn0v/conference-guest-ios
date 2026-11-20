import AppKit
import ApplicationServices
import ConferenceCore
import LiveKitWebRTC
import SwiftUI
import XCTest
@testable import MeetingEngine
@testable import RockNativeDesktop

private final class UpdateAdmissionStorage: RoomHistoryStorage, ReminderStorage, @unchecked Sendable {
    var value: Data?
    func read() -> Data? { value }
    func write(_ data: Data) throws { value = data }
}

private actor UpdateAdmissionCalendarReader: CalendarReading {
    func access() -> CalendarAccess { .notDetermined }
    func requestAccess() -> Bool { false }
    func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) -> CalendarSnapshot {
        .init(calendars: [], meetings: [])
    }
}

private final class UpdateAdmissionNoNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
    override func stopLoading() {}
}

@MainActor private final class UpdateAdmissionNotifications: ReminderNotifying {
    func authorization() async -> ReminderAuthorization { .notDetermined }
    func request(sensitive: Bool) async throws -> Bool { false }
    func pending() async -> [String: String] { [:] }
    func add(_ reminder: ReminderNotification) async throws {}
    func removePending(_ ids: [String]) {}
    func removeDelivered(occurrenceIDs: Set<String>) async {}
    func removeAllDelivered() async {}
}

@MainActor private final class UpdateAdmissionCloud: RoomCloudTransport {
    func connect() async throws -> RoomCloudSession { throw RoomCloudError.noAccount }
    func fetch(session: RoomCloudSession, after token: Data?) async throws -> RoomCloudChanges { .init(records: [], token: nil) }
    func save(_ records: [RoomSyncRecord], session: RoomCloudSession) async throws -> [RoomSyncRecord] { records }
    func clear(session: RoomCloudSession) async throws {}
}

@MainActor private final class UpdateAdmissionContinuation: MeetingContinuationTransport {
    func connect(account: String) async throws {}
    func jams() async throws -> [ActiveJam] { [] }
    func publish(_ jam: ActiveJam) async throws {}
    func withdraw(deviceID: String, sessionID: UUID?) async throws {}
    func claim(_ transfer: JamTransfer) async throws { throw ContinuationError.unavailable }
    func transfer(sourceSession: UUID) async throws -> JamTransfer? { nil }
    func transition(_ transfer: JamTransfer, to phase: JamTransfer.Phase, actor: String) async throws -> JamTransfer {
        throw ContinuationError.unavailable
    }
    func clear() async throws {}
}

@MainActor private final class UpdateAdmissionLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

/// No fixture starts a network connection, capture device or playout track.
@MainActor private final class UpdateAdmissionEngine: NativeDesktopMeetingEngine {
    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    var factory: LKRTCPeerConnectionFactory? { nil }
    var incomingVideo: [NativeDesktopExternalVideo] { [] }
    var snapshot = NativeDesktopExternalSnapshot()
    var connections = 0
    var leaves = 0
    var clean = true
    var leaveLatch: UpdateAdmissionLatch?
    func connect(invitation: URL, name: String, quiet: Bool) async throws {
        connections += 1; setPhase(.connected)
    }
    func reconnect() async throws {}
    func setMicrophone(_ enabled: Bool) async throws { snapshot.microphoneOn = enabled; onState?(snapshot) }
    func setCamera(_ enabled: Bool) async throws {}
    func setPlayout(_ enabled: Bool) async throws { snapshot.playoutOn = enabled; onState?(snapshot) }
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {}
    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?) async throws {}
    func leave() async -> Bool {
        leaves += 1
        await leaveLatch?.wait()
        setPhase(clean ? .left : .failed)
        return clean
    }
    func setPhase(_ phase: NativeDesktopMeetingPhase) { snapshot.phase = phase; onState?(snapshot) }
}

private struct CompactSettingsFixture: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    let library: NativeDesktopLibrary

    var body: some View {
        NativeDesktopSettingsView(library: library, meeting: nil, tab: $workspace.settingsTab,
                                  assistantArea: $workspace.assistantSettingsArea, attention: workspace.attention)
    }
}

@MainActor final class UpdateAdmissionTests: XCTestCase {
    private let invitation = URL(string: "https://example.test/calls/update-admission")!

    func testSettingsSidebarRowsRespondToClicksInTrailingBlankArea() async throws {
        let fixture = fixture(), workspace = fixture.workspace
        let host = NSHostingView(rootView: AnyView(CompactSettingsFixture(workspace: workspace, library: fixture.library)))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Settings row hit testing \(UUID().uuidString)"
        window.isReleasedWhenClosed = false
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { window.close() }
        await settleUI(host)

        for (title, expectedTab) in [("Calendars", 1), ("Camera & sound", 3)] {
            let row = try XCTUnwrap(accessibilityButton(in: window, title: L(title)))
            try click(row, in: window, trailingArea: true)
            await settleUI(host)
            XCTAssertEqual(workspace.settingsTab, expectedTab, "Trailing area did not select \(title)")
        }
    }

    func testFavoriteSidebarRowRespondsToClickInTrailingBlankArea() async throws {
        let fixture = fixture(), workspace = fixture.workspace, library = fixture.library
        try library.createFavorite(invitation: "https://meeting.example.test/calls/favorite", title: "Fixture favorite")
        var openCount = 0
        library.onOpenMeeting = { _, _, _, _ in openCount += 1 }
        let host = NSHostingView(rootView: AnyView(NativeDesktopHomeView(workspace: workspace, library: library)))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Favorite row hit testing \(UUID().uuidString)"
        window.isReleasedWhenClosed = false
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { window.close() }
        await settleUI(host)

        let favorite = try XCTUnwrap(accessibilityButton(in: window, title: "Fixture favorite"))
        try click(favorite, in: window, trailingArea: true)
        await settleUI(host)
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(fixture.calls.detections, 0)
    }

    func testActiveMeetingSidebarSwitchesAndControlsMeetingsFromHistory() async throws {
        let workspace = fixture().workspace
        addTeardownBlock { @MainActor in
            let window = NSApp.windows.first { $0.delegate === workspace }
            _ = await workspace.leave()
            window?.close()
        }
        workspace.attention.store.enabled = true
        for index in 1...2 {
            let url = try XCTUnwrap(URL(string: "https://example.test/calls/sidebar-\(index)"))
            workspace.join(url, engine: .guest, title: "Sidebar \(index)", quiet: true)
            try await eventually { workspace.meetings.count == index && workspace.meetings.allSatisfy(\.connected) && !workspace.preparing }
        }
        workspace.openMeetingHistory()
        let window = try XCTUnwrap(NSApp.windows.first { $0.delegate === workspace })
        let host = try XCTUnwrap(window.contentView)
        await settleUI(host)

        let first = workspace.meetings[0], second = workspace.meetings[1]
        func button(_ identifier: String) throws -> AXUIElement {
            try XCTUnwrap(accessibilityNodes(in: nil).first {
                accessibilityValue($0, kAXIdentifierAttribute) as? String == identifier
            }, identifier)
        }
        func press(_ identifier: String) throws {
            _ = AXUIElementPerformAction(try button(identifier), kAXPressAction as CFString)
        }
        let originalTalkID = workspace.talkID
        for meeting in [second, first] {
            try click(button("liveSidebar.meeting.\(meeting.sessionID)"), in: window)
            try await eventually { workspace.selectedMeetingID == meeting.sessionID }
            XCTAssertEqual(workspace.talkID, originalTalkID)
            await settleUI(host)
        }
        workspace.openMeetingHistory()
        await settleUI(host)
        try click(button("liveMeeting.microphone.\(first.sessionID)"), in: window)
        try await eventually { first.snapshot.microphoneOn }
        try press("liveMeeting.microphone.\(first.sessionID)")
        try await eventually { !first.snapshot.microphoneOn }
        let sound = second.snapshot.playoutOn
        try press("liveMeeting.playout.\(second.sessionID)")
        try await eventually { second.snapshot.playoutOn != sound }
        XCTAssertEqual(workspace.sidebarSelection, .section(.history))

        let firstMode = workspace.attention.resolvedMode(first).mode
        let secondMode: AttentionMode = workspace.attention.resolvedMode(second).mode == .watch ? .mentions : .watch
        try press("liveMeeting.assistant.\(second.sessionID)")
        let modeIdentifier = "attention.mode.\(secondMode.rawValue)"
        func modeChoice() -> AXUIElement? {
            accessibilityNodes(in: nil).first { accessibilityValue($0, kAXIdentifierAttribute) as? String == modeIdentifier }
        }
        try await eventually { modeChoice() != nil }
        let choice = try XCTUnwrap(modeChoice())
        _ = AXUIElementPerformAction(choice, kAXPressAction as CFString)
        try await eventually { workspace.attention.resolvedMode(second).mode == secondMode }
        XCTAssertEqual(workspace.attention.resolvedMode(first).mode, firstMode)
        XCTAssertEqual(workspace.sidebarSelection, .section(.history))
    }

    /// Render the actual SwiftUI surfaces using isolated, no-network fixtures.
    /// Screenshots remain in the xcresult for visual review.
    func testRedesignedHomeAndSettingsNavigationAtBothWidths() async throws {
        let fixture = fixture(), workspace = fixture.workspace, library = fixture.library
        let host = NSHostingView(rootView: AnyView(NativeDesktopHomeView(workspace: workspace, library: library)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Home and settings acceptance \(UUID().uuidString)"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        addTeardownBlock { window.close() }
        await settleUI(host)
        XCTAssertNotNil(accessibilityButton(in: window, title: L("Open meeting history")))
        try attachScreenshot(host, name: "home-normal")

        window.setContentSize(NSSize(width: 900, height: 560))
        await settleUI(host)
        XCTAssertNotNil(accessibilityButton(in: window, title: L("Open meeting history")))
        try attachScreenshot(host, name: "home-narrow")

        workspace.selection = .calendar
        await settleUI(host)
        let choose = try XCTUnwrap(accessibilityButton(in: window, title: L("Choose calendars")))
        XCTAssertEqual(AXUIElementPerformAction(choose, kAXPressAction as CFString), .success)
        await settleUI(host)
        XCTAssertEqual(workspace.selection, .settings)
        XCTAssertEqual(workspace.settingsTab, 1)
        try attachScreenshot(host, name: "settings-calendar-narrow")

        window.setContentSize(NSSize(width: 1200, height: 760))
        await settleUI(host)
        let assistant = try XCTUnwrap(accessibilityButton(in: window, title: L("Meeting alerts")))
        XCTAssertEqual(AXUIElementPerformAction(assistant, kAXPressAction as CFString), .success)
        await settleUI(host)
        XCTAssertEqual(workspace.settingsTab, 6)
        XCTAssertEqual(workspace.assistantSettingsArea, .attention)
        try attachScreenshot(host, name: "settings-assistant-normal")
        let voice = try XCTUnwrap(accessibilityButton(in: window, title: L("Voice & speaking")))
        XCTAssertEqual(AXUIElementPerformAction(voice, kAXPressAction as CFString), .success)
        await settleUI(host)
        XCTAssertEqual(workspace.assistantSettingsArea, .voice)
        XCTAssertEqual(fixture.calls.detections, 0)
        XCTAssertEqual(fixture.calls.models, 0)

        // Exercise the compact settings-specific layout independent of the
        // app's outer split-view minimum width.
        workspace.settingsTab = 6; workspace.assistantSettingsArea = .overview
        host.rootView = AnyView(CompactSettingsFixture(workspace: workspace, library: library))
        window.setContentSize(NSSize(width: 560, height: 650))
        await settleUI(host)
        XCTAssertNotNil(accessibilityElement(in: window, identifier: "settings.search"))
        let destination = try XCTUnwrap(accessibilityElement(in: window, identifier: "settings.destination"))
        let originalAppearance = window.appearance
        defer { window.appearance = originalAppearance }
        window.appearance = NSAppearance(named: .darkAqua)
        await settleUI(host)
        try attachScreenshot(host, name: "settings-compact-dark")
        window.appearance = NSAppearance(named: .aqua)
        await settleUI(host)
        try attachScreenshot(host, name: "settings-compact-light")

        // NSMenu uses a nested event loop. Observe the actual opened menu,
        // select the native item, and let it close before checking state.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await settleUI(host)
        let selected = expectation(description: "Selected camera settings from the compact menu")
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                               object: nil, queue: .main) { notification in
            guard let menu = notification.object as? NSMenu,
                  let index = menu.items.firstIndex(where: { $0.title == L("Camera & sound") }) else { return }
            DispatchQueue.main.async {
                menu.performActionForItem(at: index)
                menu.cancelTracking()
                selected.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        DispatchQueue.main.async { AXUIElementPerformAction(destination, kAXPressAction as CFString) }
        await fulfillment(of: [selected], timeout: 5)
        await settleUI(host)
        XCTAssertEqual(workspace.settingsTab, 3)
        try await eventually {
            self.accessibilityElement(in: window, identifier: "settings.microphone-test") != nil
                && self.accessibilityElement(in: window, identifier: "settings.camera-test") != nil
        }
        await settleUI(host)
        try attachScreenshot(host, name: "settings-compact-camera-light")
        window.appearance = NSAppearance(named: .darkAqua)
        await settleUI(host)
        try attachScreenshot(host, name: "settings-compact-camera-dark")

    }

    private func settleUI(_ host: NSView) async {
        for _ in 0..<4 {
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func attachScreenshot(_ host: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func accessibilityValue(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private func accessibilityNodes(in window: NSWindow?) -> [AXUIElement] {
        func children(_ root: AXUIElement) -> [AXUIElement] {
            (accessibilityValue(root, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        func walk(_ root: AXUIElement) -> [AXUIElement] { [root] + children(root).flatMap(walk) }
        let app = AXUIElementCreateApplication(getpid())
        guard let window else { return walk(app) }
        guard let target = children(app).first(where: { accessibilityValue($0, kAXTitleAttribute) as? String == window.title }) else { return [] }
        return walk(target)
    }

    private func accessibilityButton(in window: NSWindow, title: String) -> AXUIElement? {
        accessibilityNodes(in: window).first { element in
            guard accessibilityValue(element, kAXRoleAttribute) as? String == kAXButtonRole else { return false }
            return [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel", "AXAccessibilityLabel"]
                .contains { accessibilityValue(element, $0) as? String == title }
        }
    }

    private func accessibilityElement(in window: NSWindow, identifier: String) -> AXUIElement? {
        accessibilityNodes(in: window).first { accessibilityValue($0, kAXIdentifierAttribute) as? String == identifier }
    }

    private func click(_ element: AXUIElement, in window: NSWindow, trailingArea: Bool = false, bottomInset: CGFloat? = nil) throws {
        let position = try XCTUnwrap(accessibilityValue(element, kAXPositionAttribute)) as! AXValue
        let size = try XCTUnwrap(accessibilityValue(element, kAXSizeAttribute)) as! AXValue
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        XCTAssertTrue(AXValueGetValue(position, .cgPoint, &origin))
        XCTAssertTrue(AXValueGetValue(size, .cgSize, &dimensions))
        if trailingArea { XCTAssertGreaterThan(dimensions.width, 150) }
        let y = origin.y + (bottomInset.map { dimensions.height - $0 } ?? dimensions.height / 2)
        let x = origin.x + (trailingArea ? dimensions.width - 5 : dimensions.width / 2)
        let screenPoint = NSPoint(x: x, y: NSScreen.screens[0].frame.maxY - y)
        let point = window.convertPoint(fromScreen: screenPoint)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: window.windowNumber, context: nil,
                                                          eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }

    func testCalendarAndHistoryLinksOpenTheirExactDestinations() {
        let fixture = fixture(), workspace = fixture.workspace
        workspace.settingsTab = 8
        workspace.selection = .calendar
        workspace.openCalendarSettings()
        XCTAssertEqual(workspace.selection, .settings)
        XCTAssertEqual(workspace.settingsTab, 1)
        workspace.openMeetingHistory()
        XCTAssertEqual(workspace.selection, .history)
        XCTAssertEqual(fixture.calls.detections, 0)
        XCTAssertEqual(fixture.calls.models, 0)
    }

    func testHomeTodayAndRoomSearchKeepTheirActualScopes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12))!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let meeting = CalendarMeeting(id: "later", seriesID: "s", calendarID: "c", calendarTitle: "Work",
                                      title: "Tomorrow", start: tomorrow, end: tomorrow.addingTimeInterval(1800))
        XCTAssertTrue(NativeDesktopHomePresentation.today([meeting], now: now, calendar: calendar).isEmpty)
        let first = RecentRoom(invitationURL: URL(string: "https://one.test/rooms/alpha")!, title: "Weekly", identifier: "alpha", lastJoined: now)
        let second = RecentRoom(invitationURL: URL(string: "https://two.test/rooms/beta")!, title: "Planning", identifier: "beta", lastJoined: now)
        XCTAssertEqual(NativeDesktopHomePresentation.rooms([first, second], matching: " weekly ").map(\.id), [first.id])
        XCTAssertEqual(NativeDesktopHomePresentation.rooms([first, second], matching: "TWO.TEST").map(\.id), [second.id])
        XCTAssertEqual(NativeDesktopHomePresentation.rooms([first, second], matching: "  ").count, 2)
    }

    func testSettingsSearchFindsAssistantDestinations() {
        XCTAssertTrue(NativeDesktopSettingsSearch.assistantAreas(matching: "voice").contains(.voice))
        XCTAssertTrue(NativeDesktopSettingsSearch.assistantAreas(matching: "provider").contains(.models))
        XCTAssertTrue(NativeDesktopSettingsSearch.assistantAreas(matching: "agent").contains(.replies))
        XCTAssertTrue(NativeDesktopSettingsSearch.assistantAreas(matching: "memory").contains(.privacy))
        XCTAssertTrue(NativeDesktopSettingsSearch.assistantAreas(matching: "  ").isEmpty)
    }

    func testSettingsSearchOpensAndFocusesExactResult() async throws {
        let fixture = fixture(), workspace = fixture.workspace, library = fixture.library
        let host = NSHostingView(rootView: AnyView(NativeDesktopSettingsView(library: library, meeting: nil,
            tab: Binding(get: { workspace.settingsTab }, set: { workspace.settingsTab = $0 }),
            assistantArea: Binding(get: { workspace.assistantSettingsArea }, set: { workspace.assistantSettingsArea = $0 }),
            attention: workspace.attention)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Settings search integration \(UUID().uuidString)"
        window.isReleasedWhenClosed = false
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { window.close() }
        workspace.settingsTab = 1
        await settleUI(host)
        let search = try XCTUnwrap(accessibilityElement(in: window, identifier: "settings.search"))
        XCTAssertEqual(AXUIElementSetAttributeValue(search, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
        for (character, code) in [("d", 2), ("i", 34), ("s", 1), ("p", 35), ("l", 37), ("a", 0), ("y", 16), (" ", 49), ("n", 45), ("a", 0), ("m", 46), ("e", 14)] {
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: UInt16(code)))
            window.sendEvent(key)
        }
        await settleUI(host)
        let result = try XCTUnwrap(accessibilityElement(in: window, identifier: "settings.result.settings.display-name"))
        try click(result, in: window, trailingArea: true, bottomInset: 5)
        try await Task.sleep(nanoseconds: 500_000_000)
        await settleUI(host)
        XCTAssertEqual(workspace.settingsTab, 0)
        let field = try XCTUnwrap(accessibilityElement(in: window, identifier: "settings.displayName.control"))
        XCTAssertEqual(accessibilityValue(field, kAXFocusedAttribute) as? Bool, true)
        XCTAssertEqual(library.displayName, "Update admission fixture")
        XCTAssertNotNil(accessibilityElement(in: window, identifier: "settings.search.back"))
        XCTAssertEqual(fixture.calls.detections, 0)
        XCTAssertEqual(fixture.calls.models, 0)
    }

    func testSettingsResultsDescribeAndReadSafeCurrentValues() throws {
        let fixture = fixture(), library = fixture.library, attention = fixture.workspace.attention
        func entry(_ id: String) throws -> NativeSettingsSearchCatalog.Entry {
            try XCTUnwrap(NativeSettingsSearchCatalog.entries.first { $0.id == id })
        }
        let mic = try entry("settings.microphone")
        XCTAssertFalse(NativeSettingsResultPresentation.description(for: mic).isEmpty)
        XCTAssertTrue(NativeSettingsSearchCatalog.search(query: "input level", availableTabs: Set(0...8)).contains { $0.id == "settings.microphone-test" })
        attention.store.enabled = false
        let alerts = try entry("settings.alerts")
        XCTAssertEqual(NativeSettingsResultPresentation.value(for: alerts, library: library, attention: attention, obsidian: nil), L("Off"))
        attention.store.enabled = true
        XCTAssertEqual(NativeSettingsResultPresentation.value(for: alerts, library: library, attention: attention, obsidian: nil), L("On"))
        library.displayName = "private-value-2f7c0c56"
        XCTAssertEqual(NativeSettingsResultPresentation.value(for: try entry("settings.display-name"), library: library, attention: attention, obsidian: nil), L("Open to view"))
        let keyStatus = try XCTUnwrap(NativeSettingsResultPresentation.value(for: try entry("settings.api-key"), library: library, attention: attention, obsidian: nil))
        XCTAssertTrue([L("Configured"), L("Not configured")].contains(keyStatus))
        XCTAssertEqual(NativeSettingsResultPresentation.value(for: mic, library: library, attention: attention, obsidian: nil), L("Open to view"))
        XCTAssertNil(NativeSettingsResultPresentation.value(for: try entry("settings.microphone-test"), library: library, attention: attention, obsidian: nil))
        XCTAssertTrue(NativeSettingsSearchCatalog.search(query: library.displayName, availableTabs: Set(0...8)).isEmpty)
        XCTAssertEqual(fixture.calls.detections, 0)
        XCTAssertEqual(fixture.calls.models, 0)
    }
    private final class Calls { var detections = 0; var models = 0 }
    private struct Fixture {
        let workspace: NativeDesktopWorkspace
        let library: NativeDesktopLibrary
        let engine: UpdateAdmissionEngine
        let calls: Calls
    }

    private func fixture(detectionLatch: UpdateAdmissionLatch? = nil) -> Fixture {
        let domain = "native-update-admission-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        addTeardownBlock { preferences.removePersistentDomain(forName: domain) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateAdmissionNoNetwork.self]
        let reminders = CalendarReminderCoordinator(preferences: preferences, storage: UpdateAdmissionStorage(),
                                                     notifications: UpdateAdmissionNotifications())
        let calendar = CalendarMeetingStore(reader: UpdateAdmissionCalendarReader(),
            detector: MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: configuration)),
            preferences: preferences, storage: UpdateAdmissionStorage(), reminders: reminders, isMac: true)
        let library = NativeDesktopLibrary(preferences: preferences,
            history: RoomHistoryStore(storage: UpdateAdmissionStorage()), syncStorage: UpdateAdmissionStorage(),
            cloudTransport: UpdateAdmissionCloud(), calendar: calendar, continuationTransport: UpdateAdmissionContinuation())
        library.displayName = "Update admission fixture"
        library.setup.suspendForMeeting()
        let engine = UpdateAdmissionEngine(), calls = Calls()
        let workspace = NativeDesktopWorkspace(library: library, detect: { url in
            calls.detections += 1
            // Deliberately finish late even if the discovery owner was cancelled.
            await detectionLatch?.wait()
            return .verified(.guest(endpoint: url))
        }, makeMeeting: { destination, name, title, quiet in
            calls.models += 1
            return NativeDesktopMeetingModel(destination: destination, name: name, title: title, quiet: quiet,
                                             engine: calls.models == 1 ? engine : UpdateAdmissionEngine())
        }, attention: desktopTestAttention())
        return Fixture(workspace: workspace, library: library, engine: engine, calls: calls)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard condition() else {
            XCTFail("The asynchronous fixture did not reach its expected state", file: file, line: line)
            throw CancellationError()
        }
    }

    private func calendarMeeting() -> CalendarMeeting {
        var meeting = CalendarMeeting(id: "scheduled-update-gate", seriesID: "scheduled-update-gate",
            calendarID: "fixture", calendarTitle: "Fixture", title: "Scheduled fixture",
            start: Date(), end: Date().addingTimeInterval(3_600), links: [invitation])
        meeting.invitation = invitation; meeting.engine = .guest
        return meeting
    }

    private func jam() -> ActiveJam {
        ActiveJam(deviceID: "fixture-phone", sessionID: UUID(), invitation: invitation,
            title: "Continuation fixture", name: "Fixture", deviceLabel: "Phone")
    }

    func testClosedUpdateGateRejectsManualInputBeforeDiscoveryOrTransport() {
        let fixture = fixture(), workspace = fixture.workspace
        workspace.mayAdmitMeeting = { false }
        workspace.invitation = invitation.absoluteString
        workspace.joinInput()
        XCTAssertFalse(workspace.preparing)
        XCTAssertFalse(workspace.busyForUpdate)
        XCTAssertNil(workspace.meeting)
        XCTAssertNotNil(workspace.error)
        XCTAssertEqual(fixture.calls.detections, 0)
        XCTAssertEqual(fixture.calls.models, 0)
        XCTAssertEqual(fixture.engine.connections, 0)
        XCTAssertTrue(fixture.library.recent.isEmpty)
    }

    func testClosedUpdateGateDisarmsCalendarAndFinishesExactScheduledRequest() {
        let fixture = fixture(), workspace = fixture.workspace
        let meeting = calendarMeeting()
        XCTAssertTrue(fixture.library.canAutomaticallyJoin())
        XCTAssertTrue(fixture.library.calendar.canAutomaticallyJoin(meeting))
        workspace.mayAdmitMeeting = { false }
        XCTAssertFalse(fixture.library.canAutomaticallyJoin())
        XCTAssertFalse(fixture.library.calendar.canAutomaticallyJoin(meeting))
        var finished = 0
        fixture.library.onScheduledMeeting?(.init(meeting: meeting, admission: { true }, finish: { finished += 1 }))
        XCTAssertEqual(finished, 1)
        XCTAssertFalse(workspace.preparing)
        XCTAssertFalse(workspace.busyForUpdate)
        XCTAssertNil(workspace.meeting)
        XCTAssertEqual(fixture.calls.detections, 0)
        XCTAssertEqual(fixture.calls.models, 0)
        XCTAssertEqual(fixture.engine.connections, 0)
        XCTAssertTrue(fixture.library.recent.isEmpty)
    }

    func testClosedUpdateGateRefusesOrdinaryAndQuietContinuationTargets() {
        let fixture = fixture(), workspace = fixture.workspace
        workspace.mayAdmitMeeting = { false }
        for quiet in [false, true] {
            XCTAssertNil(fixture.library.continuation.onJoinTarget?(jam(), quiet))
        }
        fixture.library.continuation.joinHere(jam())
        XCTAssertFalse(workspace.preparing)
        XCTAssertFalse(workspace.busyForUpdate)
        XCTAssertNil(workspace.meeting)
        XCTAssertEqual(fixture.calls.detections, 0)
        XCTAssertEqual(fixture.calls.models, 0)
        XCTAssertEqual(fixture.engine.connections, 0)
        XCTAssertTrue(fixture.library.recent.isEmpty)
    }

    func testRealUpdateReservationClosesEveryWorkspaceAdmissionPath() throws {
        let fixture = fixture(), workspace = fixture.workspace
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-update-gate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let safety = try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100)
        workspace.mayAdmitMeeting = { safety.mayStartMeeting }
        try safety.prepareUpdate(targetBuild: 101)
        XCTAssertTrue(try safety.reserveInstallation(busy: workspace.busyForUpdate))
        workspace.join(invitation)
        var scheduledFinished = false
        fixture.library.onScheduledMeeting?(.init(meeting: calendarMeeting(), admission: { true }, finish: { scheduledFinished = true }))
        XCTAssertNil(fixture.library.continuation.onJoinTarget?(jam(), false))
        XCTAssertFalse(fixture.library.canAutomaticallyJoin())
        XCTAssertTrue(scheduledFinished)
        XCTAssertNil(workspace.meeting)
        XCTAssertEqual(fixture.calls.detections, 0)
        XCTAssertEqual(fixture.engine.connections, 0)
        XCTAssertTrue(try safety.clearPreparedUpdateIfSafe())
        XCTAssertTrue(fixture.library.canAutomaticallyJoin())
    }

    func testDiscoveryAndCancelledDiscoveryDrainStayBusyUntilOwnerFinishes() async throws {
        let latch = UpdateAdmissionLatch(); defer { latch.open() }
        let fixture = fixture(detectionLatch: latch), workspace = fixture.workspace
        XCTAssertFalse(workspace.busyForUpdate)
        workspace.join(invitation)
        XCTAssertTrue(workspace.busyForUpdate)
        try await eventually { fixture.calls.detections == 1 }
        var leaveFinished = false
        let leaving = Task { let clean = await workspace.leave(); leaveFinished = true; return clean }
        await Task.yield()
        XCTAssertFalse(leaveFinished)
        XCTAssertTrue(workspace.busyForUpdate)
        workspace.join(invitation)
        XCTAssertNil(fixture.library.continuation.onJoinTarget?(jam(), false))
        XCTAssertFalse(fixture.library.canAutomaticallyJoin())
        XCTAssertEqual(fixture.calls.detections, 1)
        XCTAssertEqual(fixture.calls.models, 0)
        latch.open()
        let clean = await leaving.value
        XCTAssertTrue(clean)
        XCTAssertFalse(workspace.busyForUpdate)
        XCTAssertNil(workspace.meeting)
        XCTAssertEqual(fixture.engine.connections, 0)
        XCTAssertTrue(fixture.library.recent.isEmpty)
    }

    func testDeferredAlertDismissalPreservesNewerErrors() async throws {
        let engine = UpdateAdmissionEngine()
        let model = NativeDesktopMeetingModel(destination: .guest(try JoinTarget.parse(invitation.absoluteString)),
                                              name: "Fixture", title: nil, engine: engine)
        func drainMainQueue() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        model.error = "Earlier error"
        model.dismissErrorAfterViewUpdate()
        model.error = "Newer error"
        await drainMainQueue()
        XCTAssertEqual(model.error, "Newer error")

        model.dismissErrorAfterViewUpdate()
        model.error = "Newer error" // A new occurrence can have identical text.
        await drainMainQueue()
        XCTAssertEqual(model.error, "Newer error")

        model.dismissErrorAfterViewUpdate()
        await drainMainQueue()
        XCTAssertNil(model.error)
    }

    func testConnectedRecoveringAndFailedMeetingsRemainBusyUntilSuccessfulLeave() async throws {
        let fixture = fixture(), workspace = fixture.workspace
        workspace.join(invitation)
        try await eventually { workspace.meeting?.connected == true && !workspace.preparing }
        XCTAssertTrue(workspace.busyForUpdate)
        fixture.engine.setPhase(.reconnecting)
        XCTAssertTrue(workspace.busyForUpdate)
        fixture.engine.setPhase(.failed)
        XCTAssertTrue(workspace.busyForUpdate)
        XCTAssertNotNil(workspace.meeting)
        let clean = await workspace.leave()
        XCTAssertTrue(clean)
        XCTAssertFalse(workspace.busyForUpdate)
        XCTAssertNil(workspace.meeting)
    }

    func testMediaCleanupBarrierStaysBusyAndPreventsNewDiscoveryUntilDrained() async throws {
        let fixture = fixture(), workspace = fixture.workspace
        let latch = UpdateAdmissionLatch(); defer { latch.open() }
        fixture.engine.leaveLatch = latch
        workspace.join(invitation)
        try await eventually { workspace.meeting?.connected == true && !workspace.preparing }
        let leaving = Task { await workspace.leave() }
        try await eventually { fixture.engine.leaves == 1 }
        XCTAssertTrue(workspace.busyForUpdate)
        workspace.join(invitation)
        XCTAssertNil(fixture.library.continuation.onJoinTarget?(jam(), false))
        XCTAssertEqual(fixture.calls.detections, 1)
        latch.open()
        let clean = await leaving.value
        XCTAssertTrue(clean)
        XCTAssertFalse(workspace.busyForUpdate)
        XCTAssertNil(workspace.meeting)
        XCTAssertEqual(fixture.engine.leaves, 1)
    }

    func testFailedCleanupRetainsBusyFenceAndRejectsReplacementMeeting() async throws {
        let fixture = fixture(), workspace = fixture.workspace
        workspace.join(invitation)
        try await eventually { workspace.meeting?.connected == true && !workspace.preparing }
        fixture.engine.clean = false
        let clean = await workspace.leave()
        XCTAssertFalse(clean)
        XCTAssertFalse(workspace.preparing)
        XCTAssertTrue(workspace.busyForUpdate)
        XCTAssertNotNil(workspace.meeting)
        XCTAssertNotNil(workspace.error)
        workspace.join(URL(string: "https://example.test/calls/blocked-replacement")!)
        XCTAssertNil(fixture.library.continuation.onJoinTarget?(jam(), false))
        XCTAssertFalse(fixture.library.canAutomaticallyJoin())
        XCTAssertEqual(fixture.calls.detections, 1)
        XCTAssertEqual(fixture.engine.connections, 1)
        let retried = await workspace.leave()
        XCTAssertFalse(retried)
        XCTAssertTrue(workspace.busyForUpdate)
        XCTAssertEqual(fixture.engine.leaves, 1)
    }
}
