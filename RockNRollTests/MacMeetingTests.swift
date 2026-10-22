import Combine
import ConferenceCore
import XCTest
import UIKit
@testable import RockNRoll

@MainActor
final class MacMeetingTests: XCTestCase {
    func testWindowProxyPreservesDecisionsAndScalarStructNotificationCallbacks() {
        XCTAssertTrue(RockMacMeetingProxyQualification())
    }

    func testCloseButtonHidesOrForwardsAndRestoresOnlyOwnedTargetAction() {
        XCTAssertTrue(RockMacMeetingCloseButtonQualification())
    }

    func testAsynchronousShowWaitsForActualVisibilityAndRetiresStaleCompletions() {
        XCTAssertTrue(RockMacMeetingVisibilityQualification())
    }

    func testCachedCloseShortcutRefreshesIdleStateBeforeDispatch() async {
        let model = MeetingSessionStub(), presentation = MeetingPresentationStub()
        let coordinator = makeCoordinator(model, presentation)
        coordinator.becameActive(); await settle()
        model.leave()
        coordinator.hideMeeting()
        XCTAssertFalse(presentation.stateAtClose!.active)
        XCTAssertFalse(presentation.hiddenForMeeting)
        coordinator.invalidate()
    }

    func testMicrophoneAvailabilityTracksCallLifecycleAndHold() {
        var state = MacMeetingMenuState(active: true, joined: true, title: "Room", session: "1",
            microphoneOn: false, microphoneAvailable: true, held: false, audio: MacAudioSnapshot())
        XCTAssertTrue(state.canToggleMicrophone)
        state.held = true; XCTAssertFalse(state.canToggleMicrophone)
        state.held = false; state.microphoneAvailable = false; XCTAssertFalse(state.canToggleMicrophone)
        state.microphoneAvailable = true; state.joined = false; XCTAssertFalse(state.canToggleMicrophone)
        state.joined = true; state.active = false; XCTAssertFalse(state.canToggleMicrophone)
    }

    func testMenuCarriesSessionIdentityAndDirectionSpecificDeviceChecks() {
        let snapshot = MacAudioSnapshot(devices: [
            MacAudioDevice(id: 1, name: "Input", directions: [.input]),
            MacAudioDevice(id: 2, name: "Output", directions: [.output])], outputID: 2, inputID: 1)
        let state = MacMeetingMenuState(active: true, joined: true, title: "Room", session: "generation",
            microphoneOn: false, microphoneAvailable: true, held: false, audio: snapshot)
        let menu = state.menu
        XCTAssertEqual(menu[3]["action"] as? String, "generation:mic:on")
        let output = (menu[4]["children"] as? [[String: Any]])?.first
        let input = (menu[5]["children"] as? [[String: Any]])?.first
        XCTAssertEqual(output?["action"] as? String, "generation:output:2")
        XCTAssertEqual(input?["action"] as? String, "generation:input:1")
        XCTAssertEqual(output?["selected"] as? Bool, true)
        XCTAssertEqual(input?["selected"] as? Bool, true)
    }

    func testActualRuntimeNativeWindowIsAvailableOnlyOnMac() async throws {
        for _ in 0..<10 {
            if RockMacMeetingBridgeDiagnostics()["window"] as? String != "nil" { break }
                try? await Task.sleep(for: .milliseconds(100))
        }
        let info = RockMacMeetingBridgeDiagnostics()
        print("MAC_WINDOW_DIAGNOSTIC \(info)")
        XCTAssertEqual(info["mac"] as? Bool, ProcessInfo.processInfo.isiOSAppOnMac)
        if ProcessInfo.processInfo.isiOSAppOnMac, info["window"] as? String == "nil" {
            throw XCTSkip("Native window requires UI activation; covered by the opt-in live meeting test")
        }
    }

    func testStaleMicrophoneActionsCannotReverseTheirDisplayedIntentOrAffectNextMeeting() async {
        let model = MeetingSessionStub(), presentation = MeetingPresentationStub()
        let coordinator = makeCoordinator(model, presentation)
        coordinator.becameActive()
        await settle()
        let controls = model.engine.controls.value!
        var toggles = 0
        controls.toggleMicrophone = { toggles += 1; controls.microphoneOn.toggle() }
        // Headset unmutes while the old Unmute item is still being tracked.
        controls.microphoneOn = true
        presentation.action?("1:mic:on")
        XCTAssertEqual(toggles, 0)
        presentation.action?("1:mic:off")
        XCTAssertEqual(toggles, 1)
        presentation.action?("1:mic:off")
        XCTAssertEqual(toggles, 1)
        model.desktopSessionToken = "2"
        presentation.action?("1:mic:on")
        XCTAssertEqual(toggles, 1)
        controls.onHold = true
        presentation.action?("2:mic:on")
        XCTAssertEqual(toggles, 1)
        coordinator.invalidate()
    }

    func testReconnectRebindsControlsAndRemovesUnavailableMicrophoneAction() async {
        let model = MeetingSessionStub(), presentation = MeetingPresentationStub()
        let coordinator = makeCoordinator(model, presentation)
        coordinator.becameActive(); await settle()
        let previous = model.engine.controls.value!
        var oldActions = 0, newActions = 0
        previous.toggleMicrophone = { oldActions += 1 }
        let replacement = CallWorkspaceControls()
        replacement.toggleMicrophone = { newActions += 1 }
        model.engine.controls.send(replacement); await settle()
        presentation.action?("1:mic:on")
        XCTAssertEqual(oldActions, 0); XCTAssertEqual(newActions, 1)
        model.engine.controls.send(nil); await settle()
        presentation.action?("1:mic:on")
        XCTAssertEqual(newActions, 1)
        XCTAssertFalse(presentation.states.last!.canToggleMicrophone)
        coordinator.invalidate()
    }

    func testInitialBindingRetryAndOwnershipLossClearMenuAndRejectActions() async {
        let model = MeetingSessionStub(), presentation = MeetingPresentationStub()
        presentation.canBind = false
        let coordinator = makeCoordinator(model, presentation)
        coordinator.becameActive()
        XCTAssertFalse(presentation.states.last!.active)
        presentation.canBind = true
        try? await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(presentation.states.last!.active)
        presentation.canBind = false
        coordinator.becameActive(); await settle()
        XCTAssertFalse(presentation.states.last!.active)
        presentation.action?("1:leave")
        XCTAssertEqual(model.leaves, 0)
        coordinator.invalidate()
        presentation.canBind = true
        try? await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(presentation.states.last!.active)
        XCTAssertTrue(presentation.invalidated)
    }

    func testLeaveRevealsWindowAndTerminalStateRemovesMenu() async {
        let model = MeetingSessionStub(), presentation = MeetingPresentationStub()
        let coordinator = makeCoordinator(model, presentation)
        coordinator.becameActive(); await settle()
        presentation.action?("1:leave"); await settle()
        XCTAssertEqual(presentation.shows, 0, "Leaving must not steal focus")
        XCTAssertEqual(model.leaves, 1)
        XCTAssertFalse(presentation.states.last!.active)
        coordinator.invalidate()
        presentation.action?("1:leave")
        XCTAssertEqual(model.leaves, 1)
    }

    func testIdleResidenceAllowsCloseAndLeavePreservesHiddenWindow() async {
        let model = MeetingSessionStub(), presentation = MeetingPresentationStub()
        let f = MacCalendarSchedulingTests().fixture()
        defer { f.store.setEnabled(false) }
        f.store.setKeepInMenuBar(true); model.desktopCalendar = f.store
        let coordinator = makeCoordinator(model, presentation)
        defer { coordinator.invalidate() }
        coordinator.becameActive(); await settle()
        coordinator.hideMeeting()
        XCTAssertTrue(presentation.hiddenForMeeting)
        presentation.action?("1:leave"); await settle()
        XCTAssertFalse(presentation.states.last!.active)
        XCTAssertTrue(presentation.states.last!.resident)
        XCTAssertTrue(coordinator.canHideMeeting)
        XCTAssertTrue(presentation.hiddenForMeeting)
        XCTAssertEqual(presentation.shows, 0)
        XCTAssertTrue(presentation.states.last!.menu.contains { $0["action"] as? String == "calendar:settings" })
    }

    func testIdleMenuRejectsMovedOccurrenceAndActiveCallDoesNotAcceptJoin() async throws {
        let f = MacCalendarSchedulingTests().fixture(), model = MeetingSessionStub(), presentation = MeetingPresentationStub()
        defer { f.store.setEnabled(false) }
        f.store.setKeepInMenuBar(true); f.store.refresh()
        try await MacCalendarSchedulingTests().ready(f.store)
        model.desktopCalendar = f.store; model.desktopMeetingActive = false; model.isInConference = false
        let coordinator = makeCoordinator(model, presentation)
        defer { coordinator.invalidate() }
        coordinator.becameActive(); await settle()
        let old = try XCTUnwrap(f.store.meetings.first)
        let action = "calendar:join:" + MacMeetingCoordinator.calendarAction(old)
        let moved = MacCalendarSchedulingTests().meeting(clock: f.clock, offset: 180)
        await f.reader.setEvents([moved], delay: .zero); f.store.refresh()
        try await MacCalendarSchedulingTests().ready(f.store)
        presentation.action?(action)
        XCTAssertEqual(model.calendarJoins, 0)
        model.desktopMeetingActive = true
        presentation.action?("calendar:join:" + MacMeetingCoordinator.calendarAction(moved))
        XCTAssertEqual(model.calendarJoins, 0)
    }

    func testDelayedWindowBindingEnablesScheduledAdmissionWithoutAnotherFocusEvent() async throws {
        let f = MacCalendarSchedulingTests().fixture(), model = MeetingSessionStub(), presentation = MeetingPresentationStub()
        defer { f.store.setEnabled(false) }
        model.desktopMeetingActive = false; model.isInConference = false; model.desktopCalendar = f.store
        f.store.setAutomaticJoinMode(.scheduled)
        presentation.canBind = false
        let coordinator = makeCoordinator(model, presentation)
        defer { coordinator.invalidate() }
        coordinator.becameActive()
        presentation.canBind = true
        try await Task.sleep(for: .milliseconds(180))
        try await MacCalendarSchedulingTests().ready(f.store)
        f.clock.now.addTimeInterval(60); f.store.refresh()
        try await MacCalendarSchedulingTests().ready(f.store)
        XCTAssertNotNil(f.store.countdown, "The binding retry must enable scheduling itself")
        XCTAssertTrue(presentation.states.last!.resident)
    }

    func testTerminationDoesNotEnqueueAnotherMenuUpdate() async {
        let model = MeetingSessionStub(), presentation = MeetingPresentationStub()
        let coordinator = makeCoordinator(model, presentation)
        coordinator.becameActive(); await settle()
        let count = presentation.states.count
        presentation.action?("terminate"); await settle()
        XCTAssertEqual(model.leaves, 1)
        XCTAssertEqual(presentation.states.count, count)
        coordinator.invalidate()
        presentation.action?("terminate")
        XCTAssertEqual(model.leaves, 1)
    }

    func testCloseShortcutIsOnlyOfferedForAnActiveMacMeeting() {
        let controller = MeetingContainerViewController()
        controller.canHideMeeting = { true }
        let commands = controller.keyCommands?.filter { $0.input == "w" && $0.modifierFlags == .command } ?? []
        XCTAssertEqual(commands.count, ProcessInfo.processInfo.isiOSAppOnMac ? 1 : 0)
        if let command = commands.first { XCTAssertTrue(command.wantsPriorityOverSystemBehavior) }
        controller.canHideMeeting = { false }
        XCTAssertFalse(controller.keyCommands?.contains { $0.input == "w" && $0.modifierFlags == .command } ?? false)
    }

    func testIOSBridgeCannotCreateMenuHideWindowOrDispatchActions() throws {
        guard !ProcessInfo.processInfo.isiOSAppOnMac else { throw XCTSkip("iOS-specific no-op gate") }
        var actions = 0
        let bridge = RockMacMeetingWindowBridge(window: nil) { _ in actions += 1 }
        XCTAssertFalse(bridge.bindMainWindow())
        bridge.updateActive(true, title: "Room", microphoneOn: false, menu: [])
        XCTAssertFalse(bridge.hideMeeting())
        bridge.showMeeting(); bridge.closeMeetingWindow(); bridge.invalidate()
        XCTAssertEqual(actions, 0)
        XCTAssertFalse(bridge.hiddenForMeeting)
    }

    private func makeCoordinator(_ model: MeetingSessionStub, _ presentation: MeetingPresentationStub) -> MacMeetingCoordinator {
        MacMeetingCoordinator(model: model, audioDevices: MacAudioDevices(isMac: false)) { action in
            presentation.action = action; return presentation
        }
    }
    private func settle() async { try? await Task.sleep(for: .milliseconds(20)) }
}

@MainActor
final class MeetingSessionStub: MacMeetingSession {
    let changes = PassthroughSubject<Void, Never>()
    let engine = MeetingEngineStub()
    var desktopChanges: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
    var desktopMeetingActive = true
    var desktopSessionToken = "1"
    var desktopMeetingTitle = "Room"
    var desktopEngine: (any CallEngine)? { desktopMeetingActive ? engine : nil }
    var isInConference = true
    var leaves = 0
    var restores = 0
    var desktopCalendar: CalendarMeetingStore?
    var calendarJoins = 0
    func desktopJoinCalendarMeeting(_ meeting: CalendarMeeting) { calendarJoins += 1 }
    func leave() { leaves += 1; desktopMeetingActive = false; isInConference = false; changes.send() }
    func prepareToFloat() {}
    func backgroundedWithoutFloatingVideo() {}
    func restoreFromFloatingVideo() { restores += 1 }
}

@MainActor
final class MeetingEngineStub: CallEngine {
    let controls = CurrentValueSubject<CallWorkspaceControls?, Never>(CallWorkspaceControls())
    var callWorkspacePublisher: AnyPublisher<CallWorkspaceControls?, Never> { controls.eraseToAnyPublisher() }
    var hasJoinStarted = true
    var isSharingScreen = false
    var continuationHostView: UIView? { nil }
    func leave() {}
    func resumeSystemCallIfPossible() {}
    func prepareToFloat() {}
    func restoreFromFloatingVideo() {}
    func showMediaStatus(_ message: String?) {}
    func setTransferHeld(_ held: Bool, restoreSending: Bool) async throws {}
}

@MainActor
private final class MeetingPresentationStub: MacMeetingPresentation {
    var hiddenForMeeting = false
    var action: ((String) -> Void)?
    var canBind = true
    var states: [MacMeetingMenuState] = []
    var stateAtClose: MacMeetingMenuState?
    var shows = 0, invalidated = false
    func bindMainWindow() -> Bool { canBind && !invalidated }
    func markVisible() {}
    func update(_ state: MacMeetingMenuState) { states.append(state) }
    func showMeeting() { shows += 1 }
    func closeMeetingWindow() { stateAtClose = states.last; hiddenForMeeting = states.last?.active == true || states.last?.resident == true }
    func hideMeeting() -> Bool { hiddenForMeeting = true; return true }
    func invalidate() { invalidated = true }
}
