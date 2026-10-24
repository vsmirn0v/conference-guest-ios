import Combine
import ConferenceCore
import UIKit
import XCTest
@testable import RockNRoll

/// Real installed-identity capture; the independent synthetic peer owns no hardware.
@MainActor final class NativeGuestOutgoingTests: XCTestCase {
    private struct PeerResult: Decodable {
        let sequence: Int
        let pass: Bool
        let rms: Double?
        let videoFrames: Int?
        let width: Int?
        let height: Int?
    }
    func testInstalledCompanionMicrophoneCameraAndReconnect() async throws {
        try await qualify(requireSignal: true)
    }
    /// Transport/lifecycle only: normal AEC can suppress this Mac's own speaker stimulus.
    /// This does not qualify repeated non-silent speech or double-talk.
    func testInstalledCompanionCaptureLifecycle() async throws {
        try await qualify(requireSignal: false)
    }
    private func qualify(requireSignal: Bool) async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_NATIVE_COMPANION_INVITE"],
              let endpoint = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_NATIVE_CAPTURE_ENDPOINT"].flatMap(URL.init(string:)),
              let token = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_NATIVE_CAPTURE_TOKEN"],
              endpoint.scheme == "http", endpoint.host == "127.0.0.1"
        else { throw XCTSkip("Requires authorized Mac capture supervisor") }
        let suite = "NativeCapture-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: NativeGuestPreference.key)
        preferences.set("Installed companion capture check", forKey: "savedDisplayName")
        let model = ConferenceModel(history: RoomHistoryStore(storage: RoomSyncCoordinatorTests.Storage()), preferences: preferences)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow })
        let original = window.rootViewController, host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        model.configure(container: host); model.registerMeetingUnderlay(host.view)
        defer { model.leave(); window.rootViewController = original }
        var commandSequence = 0
        func peer(_ operation: String, phase: String, audio: Bool = false, video: Bool = false, remoteParticipants: Int = 1) async throws -> PeerResult {
            commandSequence += 1
            let command: [String: Any] = ["sequence": commandSequence, "operation": operation, "phase": phase, "audio": audio, "video": video, "remoteParticipants": remoteParticipants, "requireSignal": requireSignal]
            var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = 80
            request.setValue(token, forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: command)
            let (bytes, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let value = try JSONDecoder().decode(PeerResult.self, from: bytes)
            XCTAssertEqual(value.sequence, commandSequence)
            XCTAssertTrue(value.pass, "Independent peer failed phase \(phase)")
            print("NATIVE_CAPTURE_PEER phase=\(phase) pass=\(value.pass) rms=\(value.rms ?? -1) frames=\(value.videoFrames ?? -1)")
            return value
        }
        func join() async throws -> NativeGuestCompanionEngine {
            model.invite = invitation; model.join()
            try await wait(65) { model.isInConference || model.statusIsError }
            XCTAssertTrue(model.isInConference, model.status)
            let engine = try XCTUnwrap(model.desktopEngine as? NativeGuestCompanionEngine)
            try await wait(30) { engine.companionStatusForTesting?.captureDisabledVerified == true }
            engine.enableCaptureDiagnosticsForTesting()
            try await wait(15) { engine.companionStatusForTesting?.captureDiagnostics != nil }
            print("NATIVE_CAPTURE_READY pid=\(engine.companionStatusForTesting?.helperPID ?? 0)")
            fflush(stdout)
            return engine
        }
        let engine = try await join()
        var controls: CallWorkspaceControls?
        let subscription = engine.callWorkspacePublisher.sink { controls = $0 }
        defer { subscription.cancel() }
        let actions = try XCTUnwrap(controls)
        func inputs(audio: Bool, video: Bool) async throws {
            if engine.companionStatusForTesting?.microphoneOn != audio { actions.toggleMicrophone?() }
            if engine.companionStatusForTesting?.cameraOn != video { actions.toggleCamera?() }
            try await wait(120) {
                let state = engine.companionStatusForTesting
                return state?.microphoneOn == audio && state?.cameraOn == video &&
                    state?.captureDiagnostics?.cameraPresent == video
            }
        }
        func diagnostic() throws -> NativeGuestCaptureDiagnostics {
            let status = try XCTUnwrap(engine.companionStatusForTesting)
            XCTAssertTrue(status.isFresh()); XCTAssertNil(status.errorCode)
            XCTAssertEqual(status.microphoneCapturing, status.microphoneOn, "Fresh native input running/enabled/mute evidence must agree with the control")
            let diagnostic = try XCTUnwrap(status.captureDiagnostics)
            let age = ProcessInfo.processInfo.systemUptime - diagnostic.audioSnapshotUptime
            XCTAssertTrue((0...5).contains(age)); XCTAssertEqual(diagnostic.remoteParticipants, 1)
            return diagnostic
        }
        func ready(_ phase: String, audio: Bool, video: Bool, playing: Bool) async throws {
            let began = ProcessInfo.processInfo.systemUptime
            var previous: NativeGuestCaptureDiagnostics?, identityChanges = 0
            func eligible(_ status: NativeGuestStatus, _ value: NativeGuestCaptureDiagnostics) -> Bool {
                let age = ProcessInfo.processInfo.systemUptime - value.audioSnapshotUptime
                return status.isFresh() && status.state == .active && status.errorCode == nil &&
                    status.microphoneOn == audio && status.cameraOn == video && status.outputOn == playing &&
                    status.microphoneCapturing == audio && (0...5).contains(age) && value.remoteParticipants == 1 &&
                    value.microphoneMuted == !audio && value.microphoneMutedRequested == !audio &&
                    value.inputAvailable && value.microphoneOptIn && value.engineRunning &&
                    value.voiceProcessingActive && !value.voiceProcessingBypassed && value.echoCancellationActive &&
                    value.outputAvailable == playing && value.inputSampleRate >= 44_100 && value.outputSampleRate >= 44_100 &&
                    value.publisherStatsFresh && value.cameraPresent == video
            }
            try await wait(25) {
                guard let status = engine.companionStatusForTesting, let value = status.captureDiagnostics,
                      eligible(status, value) else { previous = nil; return false }
                guard let first = previous else { previous = value; return false }
                guard first.connectionCount == value.connectionCount && first.engineSessionID == value.engineSessionID else {
                    identityChanges += 1; previous = value; return false
                }
                guard value.audioSnapshotUptime - first.audioSnapshotUptime >= 0.4 else { return false }
                previous = value
                return value.renderedVideoFrames > first.renderedVideoFrames &&
                    (!playing || value.receivedAudioSamples > first.receivedAudioSamples) &&
                    (!audio || value.audioPacketsSent > first.audioPacketsSent) &&
                    (!video || (value.cameraPTS > first.cameraPTS && value.videoFramesSent > first.videoFramesSent))
            }
            print("NATIVE_CAPTURE_READINESS phase=\(phase) seconds=\(ProcessInfo.processInfo.systemUptime - began) identityChanges=\(identityChanges)")
        }
        func measure(_ phase: String, audio: Bool, video: Bool, playing: Bool = true, stableEngine: Bool = true, settle: Bool = false) async throws {
            if settle { try await ready(phase, audio: audio, video: video, playing: playing) }
            let first = try diagnostic()
            let result = try await peer("measure", phase: phase, audio: audio, video: video)
            let last = try diagnostic()
            let diagnostics = try JSONEncoder().encode(["first": first, "last": last])
            print("NATIVE_CAPTURE_DIAGNOSTICS phase=\(phase) " + String(decoding: diagnostics, as: UTF8.self))
            fflush(stdout)
            XCTAssertEqual(first.connectionCount, last.connectionCount); XCTAssertEqual(first.engineSessionID, last.engineSessionID)
            for state in [first, last] {
                XCTAssertTrue(state.inputAvailable); XCTAssertTrue(state.microphoneOptIn)
                XCTAssertEqual(state.microphoneMuted, !audio); XCTAssertEqual(state.microphoneMutedRequested, !audio)
                XCTAssertTrue(state.voiceProcessingActive); XCTAssertFalse(state.voiceProcessingBypassed); XCTAssertTrue(state.echoCancellationActive)
                XCTAssertTrue(state.engineRunning); XCTAssertEqual(state.outputAvailable, playing)
                XCTAssertGreaterThanOrEqual(state.inputSampleRate, 44_100); XCTAssertGreaterThanOrEqual(state.outputSampleRate, 44_100)
                XCTAssertTrue(state.publisherStatsFresh); XCTAssertEqual(state.cameraPresent, video)
            }
            if audio { XCTAssertGreaterThan(last.audioPacketsSent, first.audioPacketsSent) }
            if video {
                XCTAssertGreaterThan(last.cameraPTS - first.cameraPTS, 20)
                XCTAssertGreaterThan(last.videoFramesSent - first.videoFramesSent, 20)
                // WebRTC may switch simulcast/adaptation size inside a four-second
                // receiver window. Require a valid camera aspect and cap instead
                // of comparing two snapshots taken at different instants.
                let width = try XCTUnwrap(result.width), height = try XCTUnwrap(result.height)
                XCTAssertGreaterThan(width, 0); XCTAssertGreaterThan(height, 0)
                XCTAssertEqual(width * 9, height * 16)
                XCTAssertLessThanOrEqual(height, 720)
            }
            XCTAssertGreaterThan(last.renderedVideoFrames - first.renderedVideoFrames, 20, "Incoming synthetic video must remain live")
            if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_NATIVE_RECEIVE_CADENCE"] == "1" {
                XCTAssertEqual(last.remoteVideoTrackCount, 1)
                XCTAssertTrue(last.subscriberStatsFresh)
                XCTAssertGreaterThanOrEqual(last.statisticsCompletedUptime, last.statisticsStartedUptime)
                XCTAssertGreaterThanOrEqual(last.videoSampleUptime, last.statisticsCompletedUptime)
                let windows = [try XCTUnwrap(last.decodedCadence)] + last.presentationCadence
                XCTAssertEqual(windows.count, 2, "Exactly one decoded source and one presented tile required")
                for value in windows {
                    XCTAssertTrue(value.complete); XCTAssertGreaterThanOrEqual(value.fps, 12)
                    XCTAssertLessThan(value.maximumGap, 1)
                    XCTAssertLessThan(try XCTUnwrap(value.endFrameAge), 0.5)
                }
            }
            if playing {
                let samples = last.receivedAudioSamples - first.receivedAudioSamples
                let energy = last.receivedAudioEnergy - first.receivedAudioEnergy
                XCTAssertGreaterThan(samples, 150_000)
                XCTAssertGreaterThan(energy / Double(max(1, samples)), 0.000001, "Incoming audio must actually resume")
            }
            if stableEngine { XCTAssertEqual(first.engineStarts, last.engineStarts); XCTAssertEqual(first.engineStops, last.engineStops) }
            print("NATIVE_CAPTURE_MEASUREMENT phase=\(phase) connection=\(last.connectionCount) capturePTS=\(last.cameraPTS) normalAEC=\(last.echoCancellationActive && !last.voiceProcessingBypassed) strictAcoustic=\(requireSignal)")
            guard result.pass else { throw NativeGuestStoreError.incompatibleRecord }
        }
        do {
            try await inputs(audio: true, video: true)
            try await measure("initial", audio: true, video: true, settle: true)
            for cycle in 1...3 {
                let before = try diagnostic()
                try await inputs(audio: false, video: true)
                try await measure("microphone-muted-\(cycle)", audio: false, video: true)
                try await inputs(audio: true, video: true)
                try await measure("microphone-resumed-\(cycle)", audio: true, video: true)
                let after = try diagnostic()
                XCTAssertEqual(before.engineStarts, after.engineStarts); XCTAssertEqual(before.engineStops, after.engineStops)
                try await inputs(audio: true, video: false)
                try await measure("camera-muted-\(cycle)", audio: true, video: false)
                try await inputs(audio: true, video: true)
                try await measure("camera-resumed-\(cycle)", audio: true, video: true)
            }
            actions.toggleSpeaker?(); try await wait(15) { engine.companionStatusForTesting?.outputOn == false }
            try await measure("output-disabled", audio: true, video: true, playing: false, settle: true)
            actions.toggleSpeaker?(); try await wait(15) { engine.companionStatusForTesting?.outputOn == true }
            try await measure("output-restored", audio: true, video: true, settle: true)
            _ = try await peer("reconnect", phase: "peer-reconnect")
            try await measure("peer-reconnected", audio: true, video: true, settle: true)
            try await inputs(audio: false, video: false)
            try await measure("both-muted", audio: false, video: false)
            let old = try diagnostic()
            engine.reconnectCompanionForTesting()
            try await wait(75) { (engine.companionStatusForTesting?.captureDiagnostics?.connectionCount ?? 0) > old.connectionCount && engine.companionStatusForTesting?.state == .active }
            try await measure("companion-reconnected-muted", audio: false, video: false, settle: true)
            try await inputs(audio: true, video: true)
            try await measure("companion-reconnected-resumed", audio: true, video: true, settle: true)
            model.leave(); try await wait(40) { !model.desktopMeetingActive }
            XCTAssertTrue(engine.companionProcessTerminatedForTesting)
            _ = try await peer("measure", phase: "after-leave", audio: false, video: false, remoteParticipants: 0)
            let fresh = try await join()
            XCTAssertNotEqual(engine.companionStatusForTesting?.helperPID, fresh.companionStatusForTesting?.helperPID)
            XCTAssertEqual(fresh.companionStatusForTesting?.captureDisabledVerified, true)
            model.leave(); try await wait(40) { !model.desktopMeetingActive }
            _ = try await peer("stop", phase: "finished")
        } catch {
            model.leave(); try? await wait(40) { !model.desktopMeetingActive }
            _ = try? await peer("stop", phase: "failure-cleanup")
            throw error
        }
    }
    private func wait(_ seconds: Double, until condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { XCTFail("Native outgoing acceptance timed out"); throw NativeGuestStoreError.expiredRecord }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
