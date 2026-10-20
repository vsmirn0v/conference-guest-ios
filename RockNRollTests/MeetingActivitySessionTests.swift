import Combine
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class MeetingActivitySessionTests: XCTestCase {
    func testNativeStudioReplacementKeepsBoundActivityCurrent() async {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let driver = ActivityDriverStub()
        let id = UUID()
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore())
        let oldStudio = engine.studioForTesting
        oldStudio.end() // A previous meeting ended before its replacement overlay arrived.
        let session = MeetingActivitySession(changes: Empty().eraseToAnyPublisher(), preferences: preferences,
            driver: driver, foreground: { true }) {
            .init(sessionID: id, title: nil, engine: engine,
                reconnecting: false, systemControls: false, otherCall: false, audioReady: true)
        }
        session.foregrounded(); await session.coordinator.task?.value
        XCTAssertEqual(driver.started.first?.state.microphone, .unknown)
        let replacement = StudioModel(audioControl: .noiseSuppression, preferences: preferences)
        replacement.microphoneActivity.setStatus(.muted)
        engine.studioForTesting = replacement
        session.foregrounded(); await session.coordinator.task?.value
        XCTAssertEqual(driver.updates.last?.state.microphone, .muted)
        oldStudio.microphoneActivity.setStatus(.on)
        session.foregrounded(); await session.coordinator.task?.value
        XCTAssertEqual(driver.updates.last?.state.microphone, .muted)
        replacement.microphoneActivity.setStatus(.on)
        session.foregrounded(); await session.coordinator.task?.value
        XCTAssertEqual(driver.updates.last?.state.microphone, .on)
        XCTAssertEqual(driver.started.count, 1)
        oldStudio.end(); replacement.end()
    }
    func testAllEngineStateUsesConfirmedMicrophoneNotButtonIntentAndHidesTitle() async {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let changes = PassthroughSubject<Void, Never>()
        let engine = ActivityEngineStub(), driver = ActivityDriverStub()
        let context = MeetingActivitySession.Context(sessionID: UUID(), title: "Private calendar title", engine: engine,
            reconnecting: false, systemControls: false, otherCall: false, audioReady: true)
        engine.controls.microphoneOn = true // Requested button state alone is insufficient.
        let session = MeetingActivitySession(changes: changes.eraseToAnyPublisher(), preferences: preferences,
            driver: driver, foreground: { true }, source: { context })
        session.foregrounded(); await session.coordinator.task?.value
        XCTAssertEqual(driver.started.first?.state.microphone, .unknown)
        XCTAssertNil(driver.started.first?.state.title)
        engine.microphone.send(.on); session.foregrounded(); await session.coordinator.task?.value
        XCTAssertEqual(driver.updates.last?.state.microphone, .on)
        preferences.set(true, forKey: MeetingActivityCoordinator.titleKey)
        session.foregrounded(); await session.coordinator.task?.value
        XCTAssertEqual(driver.updates.last?.state.title, "Private calendar title")
        preferences.set(false, forKey: MeetingActivityCoordinator.enabledKey)
        session.foregrounded(); await session.coordinator.task?.value
        XCTAssertEqual(driver.ends, ["activity-1"])
        XCTAssertEqual(engine.mediaCommands, 0)
    }
    func testCallPauseAndRecoveryKeepOneActivityAndTimer() async {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let changes = PassthroughSubject<Void, Never>()
        let engine = ActivityEngineStub(), driver = ActivityDriverStub(), id = UUID()
        var otherCall = false, ready = true, reconnecting = false
        engine.microphone.send(.on)
        let session = MeetingActivitySession(changes: changes.eraseToAnyPublisher(), preferences: preferences,
            driver: driver, foreground: { true }) {
            .init(sessionID: id, title: nil, engine: engine, reconnecting: reconnecting,
                systemControls: false, otherCall: otherCall, audioReady: ready)
        }
        session.foregrounded(); await session.coordinator.task?.value
        let start = driver.started.first?.state.startedAt
        otherCall = true; ready = false
        session.foregrounded(); await session.coordinator.task?.value
        XCTAssertEqual(driver.updates.last?.state.connection, .otherCall)
        XCTAssertEqual(driver.updates.last?.state.microphone, .paused)
        otherCall = false; reconnecting = true
        session.foregrounded(); await session.coordinator.task?.value
        XCTAssertEqual(driver.updates.last?.state.connection, .reconnecting)
        ready = true; reconnecting = false
        session.foregrounded(); await session.coordinator.task?.value
        XCTAssertEqual(driver.updates.last?.state.connection, .connected)
        XCTAssertEqual(driver.updates.last?.state.microphone, .on)
        XCTAssertEqual(driver.updates.last?.state.startedAt, start)
        XCTAssertEqual(driver.started.count, 1)
        XCTAssertEqual(engine.mediaCommands, 0)
    }
    func testEngineSwitchRetiresOldPublishersAndCallKitModeSuppressesActivity() async {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let changes = PassthroughSubject<Void, Never>()
        let first = ActivityEngineStub(), second = ActivityEngineStub(), driver = ActivityDriverStub()
        var engine = first, id = UUID(), systemControls = false, active = true
        let session = MeetingActivitySession(changes: changes.eraseToAnyPublisher(), preferences: preferences,
            driver: driver, foreground: { true }) {
            active ? .init(sessionID: id, title: nil, engine: engine, reconnecting: false,
                systemControls: systemControls, otherCall: false, audioReady: true) : nil
        }
        session.foregrounded(); await session.coordinator.task?.value
        engine = second; id = UUID(); second.microphone.send(.muted)
        session.foregrounded(); await session.coordinator.task?.value
        first.microphone.send(.on)
        session.foregrounded(); await session.coordinator.task?.value
        XCTAssertEqual(driver.started.last?.state.microphone, .muted)
        XCTAssertEqual(driver.started.last?.sessionID, id)
        systemControls = true
        session.foregrounded(); await session.coordinator.task?.value
        XCTAssertFalse(session.coordinator.isRunning)
        XCTAssertEqual(driver.started.count, 2)
        active = false; session.foregrounded(); await session.coordinator.task?.value
        XCTAssertEqual(driver.ends.count, 2)
    }
}

@MainActor
private final class ActivityEngineStub: CallEngine {
    let controls = CallWorkspaceControls()
    let microphone = CurrentValueSubject<PiPMicrophoneStatus, Never>(.unavailable)
    var callWorkspacePublisher: AnyPublisher<CallWorkspaceControls?, Never> { Just(controls).map(Optional.some).eraseToAnyPublisher() }
    var activityMicrophonePublisher: AnyPublisher<PiPMicrophoneStatus, Never> { microphone.eraseToAnyPublisher() }
    var hasJoinStarted = true
    var isSharingScreen = false
    var continuationHostView: UIView? { nil }
    var mediaCommands = 0
    func leave() { mediaCommands += 1 }
    func resumeSystemCallIfPossible() { mediaCommands += 1 }
    func prepareToFloat() { mediaCommands += 1 }
    func restoreFromFloatingVideo() { mediaCommands += 1 }
    func showMediaStatus(_ message: String?) { mediaCommands += 1 }
    func setTransferHeld(_ held: Bool, restoreSending: Bool) async throws { mediaCommands += 1 }
}
