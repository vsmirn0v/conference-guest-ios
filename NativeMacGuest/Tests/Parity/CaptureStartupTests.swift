import AppKit
import AVFoundation
import XCTest
@testable import RockNativeDesktop

@MainActor private final class CanceledPrivateAudioFixture: NativeDesktopPrivateAudioOwner {
    var privateInputLevel: Float? { nil }
    var starts = 0, stops = 0
    var stopSucceeds = true
    func startPrivateCheck() async -> Bool { starts += 1; return true }
    func closePrivateCheck() async -> Bool { stops += 1; return stopSucceeds }
}

@MainActor final class CaptureStartupTests: XCTestCase {
    func testCanceledPrivateCreationCannotReleaseReadinessAfterUnprovenShutdown() async throws {
        for stopSucceeds in [false, true] {
            let audio = CanceledPrivateAudioFixture(); audio.stopSucceeds = stopSucceeds
            var created: CheckedContinuation<Void, Never>?, resumes: [Bool] = [], creations = 0
            let model = NativeDesktopDeviceModel(discoverCameras: { [] }, authorizeAudio: { true }, createAudioOwner: {
                creations += 1; await withCheckedContinuation { created = $0 }; return audio
            }, suspendReadiness: { { resumes.append($0) } })
            model.startAudioCheck(live: false, start: nil, stop: nil, level: nil)
            for _ in 0..<100 { if created != nil { break }; await Task.yield() }
            XCTAssertNotNil(created)
            let stopping = Task { await model.stopAudioCheck() }
            for _ in 0..<100 { if !model.checkingAudio { break }; await Task.yield() }
            created?.resume(); created = nil
            let clean = await stopping.value
            XCTAssertEqual(clean, stopSucceeds)
            XCTAssertEqual(resumes, [stopSucceeds], "An unproven late shutdown must keep the physical exclusion quarantined")
            XCTAssertEqual(audio.starts, 0, "Canceled creation cannot start input capture")
            if !stopSucceeds {
                model.startAudioCheck(live: false, start: nil, stop: nil, level: nil)
                for _ in 0..<3 { await Task.yield() }
                XCTAssertEqual(creations, 1, "A failed private owner cannot be replaced")
            }
            _ = await model.stop()
        }
    }
    func testKnownPermissionStatesDoNotPrompt() async throws {
        var prompts = 0
        for status in [AVAuthorizationStatus.authorized, .denied, .restricted] {
            let allowed = try await GuestCaptureAuthorization.request(status: { status }, prompt: { _ in prompts += 1 })
            XCTAssertEqual(allowed, status == .authorized)
        }
        XCTAssertEqual(prompts, 0)
    }
    func testFirstPermissionDecisionCanOutliveTheOldThirtySecondDeadline() async throws {
        executionTimeAllowance = 40
        var reply: ((Bool) -> Void)?, finished = false
        let pending = Task {
            defer { finished = true }
            return try await GuestCaptureAuthorization.request(status: { .notDetermined }, prompt: { reply = $0 })
        }
        defer { pending.cancel() }
        while reply == nil { await Task.yield() }
        try await Task.sleep(for: .seconds(30.2))
        XCTAssertFalse(finished, "A permission dialog must wait for the person's answer")
        reply?(true)
        let allowed = try await pending.value
        XCTAssertTrue(allowed)
    }
    func testCancellationReleasesPermissionWaitAndLateAllowDoesNotReviveIt() async throws {
        var reply: ((Bool) -> Void)?, resumed = false
        let pending = Task {
            let value = try await GuestCaptureAuthorization.request(status: { .notDetermined }, prompt: { reply = $0 })
            resumed = true; return value
        }
        while reply == nil { await Task.yield() }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Canceled permission wait completed") }
        catch is CancellationError {}
        reply?(true); reply?(false)
        await Task.yield()
        XCTAssertFalse(resumed)
    }
    func testPromptDenialIsReturnedWithoutStartingCapture() async throws {
        var prompts = 0
        let allowed = try await GuestCaptureAuthorization.request(status: { .notDetermined }, prompt: { done in
            prompts += 1; done(false)
        })
        XCTAssertFalse(allowed); XCTAssertEqual(prompts, 1)
    }
    func testAuthorizedDeviceFailureIsNotReportedAsPermissionDenied() {
        for status in [AVAuthorizationStatus.authorized, .notDetermined] {
            if case .setupFailedOrTimedOut = GuestSystemAudioError.microphoneActivationFailure(authorization: status) {} else { XCTFail("Startup failure became permission denial") }
        }
        for status in [AVAuthorizationStatus.denied, .restricted] {
            if case .microphonePermissionRequired = GuestSystemAudioError.microphoneActivationFailure(authorization: status) {} else { XCTFail("Denied permission lost Settings guidance") }
        }
    }
    func testCameraDiscoveryDoesNotBlockTheSettingsMainActor() async throws {
        let started = expectation(description: "Discovery started off main"), gate = DispatchSemaphore(value: 0)
        let model = NativeDesktopDeviceModel(discoverCameras: {
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            return []
        })
        defer { gate.signal(); withExtendedLifetime(model) {} }
        await fulfillment(of: [started], timeout: 2)
        // Reaching here while discovery is blocked proves the UI actor remains available.
        XCTAssertFalse(model.previewing); XCTAssertFalse(model.checkingAudio)
    }
    func testCancelExternalCameraEnableWithdrawsIndependentMediaTaskIntent() async throws {
        let engine = NativeDesktopTelemostEngine()
        engine.snapshot.phase = .connected
        var entered = false
        let worker = Task {
            while !engine.cameraIntent { try? await Task.sleep(for: .milliseconds(5)) }
            entered = true
            while engine.cameraIntent { try? await Task.sleep(for: .milliseconds(5)) }
        }
        engine.mediaTask = worker
        let enable = Task { try await engine.setCamera(true) }
        while !entered { await Task.yield() }
        enable.cancel()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while engine.cameraIntent, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(engine.cameraIntent, "Cancel must cross the independent media-task boundary")
        engine.cameraIntent = false // Ensure a failing fixture cannot strand the runner.
        do { try await enable.value; XCTFail("Canceled enable succeeded") } catch is CancellationError {}
        await worker.value
        engine.mediaTask = nil
    }
}
