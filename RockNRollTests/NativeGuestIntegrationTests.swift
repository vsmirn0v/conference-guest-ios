import Combine
import ConferenceCore
import UIKit
import XCTest
@testable import RockNRoll

@MainActor final class NativeGuestIntegrationTests: XCTestCase {
    func testPreferenceIsLocalOffByDefaultAndNeverSelectsIOS() {
        let suite = "NativeGuestPreference-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(NativeGuestPreference.enabled(isMac: true, defaults: defaults))
        defaults.set(true, forKey: NativeGuestPreference.key)
        XCTAssertTrue(NativeGuestPreference.enabled(isMac: true, defaults: defaults))
        XCTAssertFalse(NativeGuestPreference.enabled(isMac: false, defaults: defaults))
        defaults.set(false, forKey: NativeGuestPreference.key)
        XCTAssertFalse(NativeGuestPreference.enabled(isMac: true, defaults: defaults))
    }

    /// Full host -> signed companion -> real service -> decoded Metal/PCM path.
    /// No microphone/camera permission or physical capture is requested by this check.
    func testMacCompanionJoinReceiveControlsLeaveAndRejoin() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              ProcessInfo.processInfo.environment["ROCKNROLL_TEST_NATIVE_COMPANION_CRASH_SUPERVISOR"] == "1",
              let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_NATIVE_COMPANION_INVITE"],
              let url = URL(string: invitation) else { throw XCTSkip("Requires Mac and authorized steady remote media") }
        let suite = "NativeGuestLive-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: NativeGuestPreference.key)
        preferences.set("Native integration check", forKey: "savedDisplayName")
        let history = RoomHistoryStore(storage: RoomSyncCoordinatorTests.Storage())
        let model = ConferenceModel(history: history, preferences: preferences)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow })
        let original = window.rootViewController, host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible(); model.configure(container: host)
        model.registerMeetingUnderlay(host.view)
        XCTAssertFalse(model.standardGuestInitializedForTesting, "Normal scene setup must not initialize the standard SDK for the native preview")
        defer { model.leave(); window.rootViewController = original }
        var pids: [Int32] = []
        do {
        for cycle in 0..<3 {
            preferences.set(true, forKey: NativeGuestPreference.key)
            model.invite = invitation; model.join()
            try await wait(60) { model.isInConference || model.statusIsError }
            XCTAssertTrue(model.isInConference, "Native host failed to connect: \(model.status)")
            let engine = try XCTUnwrap(model.desktopEngine as? NativeGuestCompanionEngine)
            model.backgroundedWithoutFloatingVideo()
            XCTAssertFalse(model.standardGuestInitializedForTesting)
            var reported = ProcessInfo.processInfo.systemUptime
            try await wait(35) {
                if ProcessInfo.processInfo.systemUptime - reported > 5 {
                    reported = ProcessInfo.processInfo.systemUptime
                    let status = engine.companionStatusForTesting
                    print("NATIVE_COMPANION_PROGRESS state=\(status?.state.rawValue ?? "none") frames=\(status?.remoteVideoFrames ?? -1) audioSamples=\(status?.receivedAudioSamples ?? -1) captureDisabled=\(status?.captureDisabledVerified == true) connected=\(status?.receiveConnected == true) decoded=\(status?.decodedVideoFrames ?? -1) playing=\(status?.playoutRunning == true) audioRMS=\(status?.receivedAudioRMS ?? -1)")
                }
                return (engine.companionStatusForTesting?.remoteVideoFrames ?? 0) >= 20 &&
                    (engine.companionStatusForTesting?.receivedAudioSamples ?? 0) > 48_000 &&
                    (engine.companionStatusForTesting?.receivedAudioRMS ?? 0) > 0.001
            }
            let initial = try XCTUnwrap(engine.companionStatusForTesting)
            print("NATIVE_COMPANION_READY cycle=\(cycle) pid=\(initial.helperPID ?? 0) frames=\(initial.remoteVideoFrames) audioSamples=\(initial.receivedAudioSamples)")
            if cycle == 0 { try await Task.sleep(for: .seconds(10)) }
            XCTAssertFalse(initial.microphoneOn); XCTAssertFalse(initial.cameraOn)
            XCTAssertFalse(initial.microphoneCapturing)
            XCTAssertEqual(initial.captureDisabledVerified, true, "Fresh native availability, opt-in and mute state plus absent camera must prove the input gate is disabled")
            XCTAssertNotNil(history.matching(url), "A native active join must enter normal history")
            XCTAssertNil(model.continuationSnapshot(), "Unsupported handoff must not be advertised")
            pids.append(try XCTUnwrap(initial.helperPID))
            preferences.set(false, forKey: NativeGuestPreference.key)
            XCTAssertTrue(model.desktopEngine === engine, "Preference changes apply only to the next join")
            var controls: CallWorkspaceControls?
            let subscription = engine.callWorkspacePublisher.sink { controls = $0 }
            let actions = try XCTUnwrap(controls)
            actions.toggleSpeaker?()
            try await wait(8) { engine.companionStatusForTesting?.outputOn == false }
            actions.toggleSpeaker?()
            try await wait(8) { engine.companionStatusForTesting?.outputOn == true }
            let frames = engine.companionStatusForTesting?.remoteVideoFrames ?? 0
            try await wait(8) { (engine.companionStatusForTesting?.remoteVideoFrames ?? 0) > frames + 10 }
            subscription.cancel()
            print("NATIVE_COMPANION_ACCEPTANCE cycle=\(cycle) frames=\(engine.companionStatusForTesting?.remoteVideoFrames ?? 0) audioSamples=\(engine.companionStatusForTesting?.receivedAudioSamples ?? 0) initialInputGateDisabled=true")
            if cycle == 0 {
                engine.stopOwnerHeartbeatForTesting()
                try await wait(28) { engine.companionProcessTerminatedForTesting }
                await engine.observeTerminatedCompanionForTesting()
                print("NATIVE_COMPANION_OWNER_LOSS recovered=true")
            } else if cycle == 1 {
                // The native supervisor can signal its own exact helper; the iOS host sandbox cannot.
                print("NATIVE_COMPANION_CRASH_REQUEST pid=\(try XCTUnwrap(initial.helperPID))")
                fflush(stdout)
            } else { model.leave() }
            try await wait(30) { !model.desktopMeetingActive }
            XCTAssertFalse(model.isInConference); XCTAssertNil(model.desktopEngine)
        }
        XCTAssertEqual(Set(pids).count, 3, "Normal leave and helper failure must both allow a fresh companion")
        } catch {
            model.leave()
            try? await wait(35) { !model.desktopMeetingActive }
            throw error
        }
    }
    private func wait(_ seconds: Double, until condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for native companion acceptance condition")
                throw NativeGuestStoreError.expiredRecord
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
