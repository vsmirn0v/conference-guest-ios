import AppKit
import ConferenceCore
import SwiftUI
import XCTest
@testable import MeetingEngine
@testable import RockNativeDesktop

@MainActor private final class RevealFixture: ObservableObject {
    @Published var target: String?
    @Published var advanced = false
    @Published var text = ""
    @Published var enabled = false
    @Published var editing = false
    @Published var disabled = false
    @Published var selection = 2
    @Published var timing = ReminderTiming()
    var acceptsChanges = true
    var buttonPresses = 0
    var switchWrites = 0
    var popupWrites = 0
    var timingWrites = 0
}

private struct RevealFixtureView: View {
    @ObservedObject var fixture: RevealFixture

    var body: some View {
        Form {
            Section("Start") { Text("Start of the page") }
            ForEach(0..<18, id: \.self) { index in Text("Row \(index)") }
            DisclosureGroup("Advanced", isExpanded: $fixture.advanced) {
                TextField("Reveal field", text: $fixture.text)
                    .accessibilityIdentifier("reveal.field")
                    .nativeSettingAnchor("settings.test-field", nativeControlFocus: true, onFocusChange: { fixture.editing = $0 })
                NativeSettingsSwitch(title: "Reveal toggle", isOn: Binding(
                    get: { fixture.enabled }, set: { value in
                        fixture.switchWrites += 1
                        if fixture.acceptsChanges { fixture.enabled = value }
                    }),
                                     id: "settings.test-toggle", fallbackFor: fixture.enabled ? [] : ["settings.test-conditional"],
                                     accessibilityID: "reveal.toggle")
                    .disabled(fixture.disabled)
                if fixture.enabled {
                    TextField("Conditional field", text: $fixture.text)
                        .accessibilityIdentifier("reveal.conditional")
                        .nativeSettingAnchor("settings.test-conditional", nativeControlFocus: true)
                }
                TextField("Next field", text: $fixture.text)
                    .accessibilityIdentifier("reveal.next")
                NativeSettingsButton(title: "Delete fixture", role: .destructive, id: "settings.test-button",
                                     accessibilityID: "reveal.button") { fixture.buttonPresses += 1 }
                    .disabled(fixture.disabled)
                NativeSettingsPopup(title: "Reveal popup", selection: Binding(
                    get: { fixture.selection }, set: { value in
                        fixture.popupWrites += 1
                        if fixture.acceptsChanges { fixture.selection = value }
                    }),
                                    choices: [1, 2, 3], titleForChoice: { $0 == 3 ? "Third" : "Same label" },
                                    id: "settings.test-popup", accessibilityID: "reveal.popup")
                    .disabled(fixture.disabled)
            }
        }
        .formStyle(.grouped)
        .nativeSettingsReveal()
        .environment(\.nativeSettingRevealID, fixture.target)
        .onChange(of: fixture.target) { target in
            if target != nil { fixture.advanced = true }
        }
    }
}

private struct DeviceRevealFixtureView: View {
    @ObservedObject var fixture: RevealFixture
    var body: some View {
        NativeDesktopDeviceSettings(liveTrack: nil, settingsPage: true)
            .environment(\.nativeSettingRevealID, fixture.target)
    }
}

private struct TranscriptionRevealFixtureView: View {
    @ObservedObject var fixture: RevealFixture
    let store: ListenModelStore

    var body: some View {
        NativeDesktopTranscriptionSettings(store: store)
            .environment(\.nativeSettingRevealID, fixture.target)
    }
}

private struct ReminderRevealFixtureView: View {
    @ObservedObject var fixture: RevealFixture

    var body: some View {
        Form {
            NativeDesktopReminderTimingEditor(timing: Binding(get: { fixture.timing }, set: {
                fixture.timingWrites += 1
                fixture.timing = $0
            }))
        }
        .formStyle(.grouped)
        .nativeSettingsReveal()
        .environment(\.nativeSettingRevealID, fixture.target)
    }
}

private struct SituationRevealFixtureView: View {
    @ObservedObject var fixture: RevealFixture
    @ObservedObject var store: AttentionStore

    var body: some View {
        Form {
            Section { AttentionSituationDefaults(store: store) }
                .disabled(!store.enabled)
            TextField("Before reveal", text: $fixture.text)
                .accessibilityIdentifier("reveal.previous")
                .nativeSettingAnchor("settings.test-previous", nativeControlFocus: true)
        }
        .formStyle(.grouped)
        .nativeSettingsReveal()
        .environment(\.nativeSettingRevealID, fixture.target)
    }
}

@MainActor final class NativeSettingsRevealTests: XCTestCase {
    func testRevealOpensDisclosureScrollsAndFocusesTextWithoutEditing() async throws {
        let fixture = RevealFixture()
        let hosting = NSHostingView(rootView: RevealFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 280),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings reveal \(UUID().uuidString)"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { window.close() }
        await settle(hosting)
        window.makeKey()
        XCTAssertTrue(window.isKeyWindow, "The fixture must receive native keyboard events")

        fixture.target = "settings.test-field"
        await settle(hosting)
        XCTAssertTrue(fixture.advanced)
        XCTAssertEqual(fixture.text, "", "Revealing a field must not change its value")
        let field = try XCTUnwrap(element(in: window, id: "reveal.field"))
        XCTAssertEqual(attribute(field, kAXFocusedAttribute) as? Bool, true, "The revealed field must receive keyboard focus")
        XCTAssertTrue(fixture.editing, "Focusing the name field must keep its editing callback")
        let frameObject = try XCTUnwrap(attribute(field, kAXPositionAttribute))
        XCTAssertEqual(CFGetTypeID(frameObject), AXValueGetTypeID())
        let frame = frameObject as! AXValue
        var point = CGPoint.zero
        XCTAssertTrue(AXValueGetValue(frame, .cgPoint, &point))
        let windowFrame = window.frame
        let screenHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let fieldY = screenHeight - point.y
        XCTAssertGreaterThan(fieldY, windowFrame.minY)
        XCTAssertLessThan(fieldY, windowFrame.maxY)
        XCTAssertNotNil(window.firstResponder, "The window must have a keyboard responder")
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        window.sendEvent(key)
        await settle(hosting)
        XCTAssertEqual(fixture.text, "x")
        fixture.target = "settings.test-toggle"
        await settle(hosting)
        XCTAssertFalse(fixture.editing, "Leaving the field must end its editing lifecycle")
        fixture.target = nil
        await settle(hosting)
        fixture.target = "settings.test-field"
        await settle(hosting)
        let refocused = try XCTUnwrap(element(in: window, id: "reveal.field"))
        XCTAssertEqual(attribute(refocused, kAXFocusedAttribute) as? Bool, true, "Repeated reveal must restore focus")
    }

    func testRevealFocusesToggleWithoutToggling() async throws {
        let fixture = RevealFixture()
        let hosting = NSHostingView(rootView: RevealFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 280),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings toggle reveal \(UUID().uuidString)"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { window.close() }
        await settle(hosting)
        window.makeKey()
        XCTAssertTrue(window.isKeyWindow, "The fixture must receive native keyboard events")
        fixture.target = "settings.test-conditional"
        await settle(hosting)
        XCTAssertFalse(fixture.enabled, "Revealing a toggle must not activate it")
        XCTAssertEqual(fixture.switchWrites, 0)
        let toggle = try XCTUnwrap(element(in: window, id: "reveal.toggle"))
        let native = try XCTUnwrap(control(NSSwitch.self, in: hosting, id: "reveal.toggle"))
        XCTAssertEqual(native.accessibilityLabel(), "Reveal toggle")
        XCTAssertTrue(window.firstResponder === native)
        XCTAssertEqual(attribute(toggle, kAXFocusedAttribute) as? Bool, true, "The revealed toggle must receive keyboard focus")
        try postKey(" ", code: 49, in: window)
        await settle(hosting)
        XCTAssertTrue(fixture.enabled, "A focused toggle must be operable with Space")
        XCTAssertEqual(fixture.switchWrites, 1)
        XCTAssertTrue(window.firstResponder === native, "Enabling the prerequisite must preserve the focus the user is using")
    }

    func testRealMicrophoneReadinessOpensAdvancedSectionAndFocusesPicker() async throws {
        let fixture = RevealFixture()
        let hosting = NSHostingView(rootView: DeviceRevealFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Device reveal \(UUID().uuidString)"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { window.close() }
        await settle(hosting)
        window.makeKey()
        XCTAssertTrue(window.isKeyWindow, "The fixture must receive native keyboard events")
        fixture.target = "settings.mic-readiness"
        await settle(hosting)
        let picker = try XCTUnwrap(element(in: window, id: "settings.microphoneReadiness.control"), "Advanced audio must expand to show readiness")
        let native = try XCTUnwrap(control(NSPopUpButton.self, in: hosting, id: "settings.microphoneReadiness.control"))
        XCTAssertTrue(window.firstResponder === native)
        XCTAssertEqual(native.accessibilityLabel(), L("Microphone readiness"))
        XCTAssertEqual(native.itemTitles, NativeDesktopMediaReadinessMode.allCases.map(\.title))
        XCTAssertEqual(native.titleOfSelectedItem, NativeDesktopJoinReadinessPolicy.current().microphone.title)
        XCTAssertEqual(attribute(picker, kAXFocusedAttribute) as? Bool, true, "The real readiness picker must receive focus")
        let positionObject = try XCTUnwrap(attribute(picker, kAXPositionAttribute))
        XCTAssertEqual(CFGetTypeID(positionObject), AXValueGetTypeID())
        let position = positionObject as! AXValue
        var point = CGPoint.zero
        XCTAssertTrue(AXValueGetValue(position, .cgPoint, &point))
        let y = (NSScreen.screens.first?.frame.maxY ?? 0) - point.y
        XCTAssertGreaterThan(y, window.frame.minY)
        XCTAssertLessThan(y, window.frame.maxY)
    }

    func testCancelledRevealDoesNotStealFocusOrChangeSettings() async throws {
        let fixture = RevealFixture()
        let hosting = NSHostingView(rootView: RevealFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 280),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Cancelled reveal \(UUID().uuidString)"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { window.close() }
        await settle(hosting)
        window.makeKey()
        XCTAssertTrue(window.isKeyWindow, "The fixture must receive native keyboard events")
        fixture.target = "settings.test-field"
        await settle(hosting)
        let field = try XCTUnwrap(element(in: window, id: "reveal.field"))
        XCTAssertEqual(attribute(field, kAXFocusedAttribute) as? Bool, true)
        fixture.target = "settings.test-toggle"
        fixture.target = nil
        await settle(hosting)
        XCTAssertEqual(attribute(field, kAXFocusedAttribute) as? Bool, true)
        XCTAssertFalse(fixture.enabled)
        XCTAssertEqual(fixture.text, "")
    }

    func testRevealFocusesNativeButtonWithoutPressingIt() async throws {
        let fixture = RevealFixture()
        let (window, hosting) = await host(RevealFixtureView(fixture: fixture))
        fixture.target = "settings.test-button"
        await settle(hosting)
        let native = try XCTUnwrap(control(NSButton.self, in: hosting, id: "reveal.button"))
        let button = try XCTUnwrap(element(in: window, id: "reveal.button"))
        XCTAssertTrue(native.hasDestructiveAction)
        XCTAssertEqual(attribute(button, kAXTitleAttribute) as? String, "Delete fixture")
        XCTAssertEqual(attribute(button, kAXFocusedAttribute) as? Bool, true)
        XCTAssertTrue(window.firstResponder === native)
        XCTAssertEqual(fixture.buttonPresses, 0)
        try postKey(" ", code: 49, in: window)
        await settle(hosting)
        XCTAssertEqual(fixture.buttonPresses, 1)
    }

    func testPopupPreservesDistinctTypedValuesWithEqualLabels() async throws {
        let fixture = RevealFixture()
        let (window, hosting) = await host(RevealFixtureView(fixture: fixture))
        fixture.target = "settings.test-popup"
        await settle(hosting)
        let native = try XCTUnwrap(control(NSPopUpButton.self, in: hosting, id: "reveal.popup"))
        XCTAssertEqual(native.itemTitles, ["Same label", "Same label", "Third"])
        XCTAssertEqual(native.indexOfSelectedItem, 1)
        XCTAssertEqual(fixture.popupWrites, 0)
        XCTAssertTrue(window.firstResponder === native)
        let item = try XCTUnwrap(native.item(at: 0))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        await settle(hosting)
        XCTAssertEqual(native.indexOfSelectedItem, 0)
        XCTAssertEqual(fixture.selection, 1)
        XCTAssertEqual(fixture.popupWrites, 1)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(fixture.popupWrites, 1, "Choosing the current value must not write the binding again")
    }

    func testNativeControlsRestoreRejectedChangesAndReflectLaterModelUpdates() async throws {
        let fixture = RevealFixture()
        fixture.acceptsChanges = false
        let (window, hosting) = await host(RevealFixtureView(fixture: fixture))
        fixture.target = "settings.test-toggle"
        await settle(hosting)
        let toggle = try XCTUnwrap(control(NSSwitch.self, in: hosting, id: "reveal.toggle"))
        try postKey(" ", code: 49, in: window)
        await settle(hosting)
        XCTAssertEqual(fixture.switchWrites, 1)
        XCTAssertFalse(fixture.enabled)
        XCTAssertEqual(toggle.state, .off)

        fixture.target = "settings.test-popup"
        await settle(hosting)
        let popup = try XCTUnwrap(control(NSPopUpButton.self, in: hosting, id: "reveal.popup"))
        let item = try XCTUnwrap(popup.item(at: 2))
        // Model the popup's immediate UI selection before its target action.
        popup.select(item)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        await settle(hosting)
        XCTAssertEqual(fixture.popupWrites, 1)
        XCTAssertEqual(fixture.selection, 2)
        XCTAssertEqual(popup.indexOfSelectedItem, 1)

        fixture.enabled = true
        fixture.selection = 3
        await settle(hosting)
        XCTAssertEqual(toggle.state, .on)
        XCTAssertEqual(popup.indexOfSelectedItem, 2)
        XCTAssertEqual(fixture.switchWrites, 1)
        XCTAssertEqual(fixture.popupWrites, 1)
    }

    func testDisabledControlsAreRevealedWithoutFocusOrActions() async throws {
        let fixture = RevealFixture()
        fixture.disabled = true
        let (window, hosting) = await host(RevealFixtureView(fixture: fixture))
        fixture.target = "settings.test-field"
        await settle(hosting)
        let field = try XCTUnwrap(element(in: window, id: "reveal.field"))
        for suffix in ["toggle", "button", "popup"] {
            fixture.target = "settings.test-\(suffix)"
            await settle(hosting)
            let native = try XCTUnwrap(control(NSControl.self, in: hosting, id: "reveal.\(suffix)"))
            XCTAssertFalse(native.isEnabled)
            XCTAssertFalse(window.firstResponder === native)
            XCTAssertEqual(attribute(field, kAXFocusedAttribute) as? Bool, true)
        }
        XCTAssertEqual(fixture.buttonPresses, 0)
        XCTAssertEqual(fixture.popupWrites, 0)
        XCTAssertEqual(fixture.switchWrites, 0)
    }

    func testTypingCancelsPendingRevealAndKeepsOrdinaryTabBehavior() async throws {
        let fixture = RevealFixture()
        let (window, hosting) = await host(RevealFixtureView(fixture: fixture))
        fixture.target = "settings.test-field"
        await settle(hosting)
        fixture.target = "settings.test-toggle"
        try await Task.sleep(nanoseconds: 50_000_000)
        try postKey("x", code: 7, in: window)
        await settle(hosting)
        XCTAssertEqual(fixture.text, "x")
        let field = try XCTUnwrap(element(in: window, id: "reveal.field"))
        XCTAssertEqual(attribute(field, kAXFocusedAttribute) as? Bool, true)
        XCTAssertEqual(fixture.switchWrites, 0)
        if !NSApp.isFullKeyboardAccessEnabled {
            let toggle = try XCTUnwrap(control(NSSwitch.self, in: hosting, id: "reveal.toggle"))
            XCTAssertFalse(toggle.canBecomeKeyView)
            try postKey("\t", code: 48, in: window)
            await settle(hosting)
            let next = try XCTUnwrap(element(in: window, id: "reveal.next"))
            XCTAssertEqual(attribute(next, kAXFocusedAttribute) as? Bool, true)
        }
    }

    func testTranscriptionPrerequisiteAndDisabledFieldKeepPreferences() async throws {
        let suite = "native-settings-reveal-transcription-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        let store = ListenModelStore(catalog: .init(schemaVersion: 1, runtime: "fixture", models: []),
                                     root: root, defaults: defaults, recognizerUserCount: { 0 })
        let fixture = RevealFixture()
        let (window, hosting) = await host(TranscriptionRevealFixtureView(fixture: fixture, store: store))
        fixture.target = "settings.voice-detector"
        await settle(hosting)
        let prerequisite = try XCTUnwrap(control(NSSwitch.self, in: hosting, id: "transcription.local.enabled"))
        XCTAssertTrue(window.firstResponder === prerequisite)
        XCTAssertEqual(prerequisite.state, .off)
        XCTAssertFalse(store.enabled)
        XCTAssertNil(defaults.object(forKey: ListenModelStore.enabledKey))

        fixture.target = "settings.transcribe-mic"
        await settle(hosting)
        let microphone = try XCTUnwrap(control(NSSwitch.self, in: hosting, id: "transcription.local.microphone"))
        XCTAssertFalse(microphone.isEnabled)
        XCTAssertFalse(window.firstResponder === microphone)
        XCTAssertTrue(store.includesMicrophone)
        XCTAssertNil(defaults.object(forKey: ListenModelStore.microphoneKey))

        fixture.target = "settings.speech-model"
        await settle(hosting)
        XCTAssertNotNil(element(in: window, id: "transcription.speech-model.management"))
        XCTAssertTrue(window.firstResponder === prerequisite, "An empty collection must not focus an unrelated action")
        XCTAssertNil(store.pendingID)
        XCTAssertNil(defaults.object(forKey: ListenModelStore.pendingModelKey))
    }

    func testReminderOffsetRevealUsesPrerequisiteThenFocusesExactStepper() async throws {
        let fixture = RevealFixture()
        let (window, hosting) = await host(ReminderRevealFixtureView(fixture: fixture))
        let beforeID = "settings.reminder-before-time"
        fixture.target = beforeID
        await settle(hosting)
        let prerequisite = try XCTUnwrap(control(NSSwitch.self, in: hosting, id: "settings.reminder-before"))
        XCTAssertTrue(window.firstResponder === prerequisite)
        XCTAssertNil(fixture.timing.before)
        XCTAssertEqual(fixture.timingWrites, 0)

        try postKey(" ", code: 49, in: window)
        await settle(hosting)
        XCTAssertEqual(fixture.timing.before, 120)
        XCTAssertEqual(fixture.timingWrites, 1)

        fixture.target = nil
        await settle(hosting)
        fixture.target = beforeID
        await settle(hosting)
        let stepper = try XCTUnwrap(control(NSStepper.self, in: hosting, id: beforeID))
        XCTAssertTrue(window.firstResponder === stepper)
        XCTAssertEqual(stepper.integerValue, 120)
        XCTAssertEqual(fixture.timingWrites, 1)
        let up = try XCTUnwrap(UnicodeScalar(NSUpArrowFunctionKey))
        try postKey(String(up), code: 126, in: window)
        await settle(hosting)
        XCTAssertEqual(fixture.timing.before, 121)
        XCTAssertEqual(fixture.timing.rememberedBefore, 121)
        XCTAssertEqual(fixture.timingWrites, 2)

        fixture.timing.followUp.mode = .off
        fixture.target = "settings.reminder-follow-up-delay"
        await settle(hosting)
        let followUp = try XCTUnwrap(control(NSPopUpButton.self, in: hosting, id: "settings.reminder-follow-up"))
        XCTAssertTrue(window.firstResponder === followUp)
        XCTAssertEqual(fixture.timing.followUp.mode, .off)
        XCTAssertEqual(fixture.timingWrites, 2)
    }

    func testRegularWidthSituationRevealFocusesExactPickerWithoutChangingModes() async throws {
        let suite = "native-settings-reveal-attention-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let keychain = AttentionKeychain(service: suite)
        let store = AttentionStore(root: root, defaults: defaults, keychain: keychain)
        addTeardownBlock {
            await store.closeLibrarySyncForTeardown()
            keychain.deleteAll()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        await store.waitForMoments()
        store.enabled = true
        let modes = store.situationModes
        let modeKeys = AttentionSituation.allCases.map(AttentionStore.modeKey)
        let initialPreferences = modeKeys.map { defaults.string(forKey: $0) }
        let fixture = RevealFixture()
        let (window, hosting) = await host(SituationRevealFixtureView(fixture: fixture, store: store), width: 760)
        fixture.target = "settings.attention-mode-background"
        await settle(hosting)
        let responder = try XCTUnwrap(window.firstResponder as? NSSegmentedControl, "The regular-width control must receive keyboard focus")
        XCTAssertTrue(responder.isEnabled)
        XCTAssertEqual(responder.accessibilityIdentifier(), "attention.mode.background", "The exact background picker must receive focus")
        XCTAssertEqual(responder.accessibilityLabel(), AttentionSituation.background.title)
        XCTAssertEqual(responder.selectedSegment, AttentionMode.allCases.firstIndex(of: store.mode(for: .background)))
        XCTAssertEqual(store.situationModes, modes)
        XCTAssertEqual(modeKeys.map { defaults.string(forKey: $0) }, initialPreferences)

        store.enabled = false
        fixture.target = "settings.test-previous"
        await settle(hosting)
        fixture.target = "settings.attention-mode-background"
        await settle(hosting)
        let previous = try XCTUnwrap(element(in: window, id: "reveal.previous"))
        XCTAssertEqual(attribute(previous, kAXFocusedAttribute) as? Bool, true)
        XCTAssertEqual(store.situationModes, modes)
        XCTAssertEqual(modeKeys.map { defaults.string(forKey: $0) }, initialPreferences)
    }

    private func host<Content: View>(_ content: Content, width: CGFloat = 640) async -> (NSWindow, NSHostingView<Content>) {
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 280),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Native control reveal \(UUID().uuidString)"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { window.close() }
        await settle(hosting)
        window.makeKey()
        XCTAssertTrue(window.isKeyWindow)
        return (window, hosting)
    }

    private func postKey(_ text: String, code: UInt16, in window: NSWindow) throws {
        for phase in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: phase, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            window.postEvent(event, atStart: false)
        }
    }

    private func control<T: NSControl>(_ type: T.Type, in view: NSView, id: String) -> T? {
        if let view = view as? T, view.accessibilityIdentifier() == id { return view }
        for child in view.subviews {
            if let result = control(type, in: child, id: id) { return result }
        }
        return nil
    }

    private func settle(_ view: NSView) async {
        for _ in 0..<12 {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    private func element(in window: NSWindow, id: String) -> AXUIElement? {
        func children(_ element: AXUIElement) -> [AXUIElement] {
            (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        func all(_ element: AXUIElement) -> [AXUIElement] { [element] + children(element).flatMap(all) }
        let app = AXUIElementCreateApplication(getpid())
        guard let target = children(app).first(where: { attribute($0, kAXTitleAttribute) as? String == window.title }) else { return nil }
        return all(target).first { attribute($0, kAXIdentifierAttribute) as? String == id }
    }

}
