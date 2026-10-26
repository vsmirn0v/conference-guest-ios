import AVFoundation
import Foundation
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

@MainActor final class ColdMediaLiveTests: XCTestCase {
    func testFirstHardwareActivationAndWarmTogglesKeepReceivingMedia() async throws {
        guard ProcessInfo.processInfo.environment["NATIVE_DESKTOP_COLD_MEDIA"] == "1" else {
            throw XCTSkip("Opt in to physical Mac microphone/camera checks in a disposable meeting")
        }
        executionTimeAllowance = 180
        print("COLD_STAGE permissions"); fflush(stdout)
        for type in [AVMediaType.audio, .video] {
            print("COLD_AUTH \(type.rawValue) status=\(AVCaptureDevice.authorizationStatus(for: type).rawValue)"); fflush(stdout)
            let allowed = try await GuestCaptureAuthorization.request(type)
            guard allowed else { XCTFail("Capture permission was denied for \(type.rawValue)"); throw CancellationError() }
        }
        print("COLD_STAGE disposable"); fflush(stdout)
        let invitation = try await GuestBootstrap.createDisposable(origin: URL(string: "https://salutejazz.ru")!)
        let peer = NativeGuestEngine(label: "Cold startup synthetic peer", verifyReceivedPixels: false)
        let app = NativeDesktopGuestEngine()
        var maxUIInterval = 0.0
        let ticker = Task { @MainActor in
            var last = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
                let now = ProcessInfo.processInfo.systemUptime
                maxUIInterval = max(maxUIInterval, now - last); last = now
            }
        }
        defer { ticker.cancel() }
        do {
            print("COLD_STAGE peer-join"); fflush(stdout)
            try await peer.join(invitation)
            try await peer.publishPattern(codec: "h264", audioMuted: false, videoMuted: false)
            print("COLD_STAGE app-join"); fflush(stdout)
            try await app.connect(invitation: invitation.invitationURL, name: "Cold startup app", quiet: false)
            guard let native = app.currentNativeEngine else { throw CancellationError() }
            try await wait { native.mediaSnapshot.audio.samples > 0 }
            print("COLD_STAGE cancellation"); fflush(stdout)
            let pendingCamera = PendingPermissionCamera()
            native.cameraFactoryForTesting = { _ in pendingCamera }
            var canceledEnableFinished = false
            let pendingEnable = Task {
                defer { canceledEnableFinished = true }
                do { try await app.setCamera(true); XCTFail("Canceled camera enable returned success") }
                catch is CancellationError {} catch { XCTFail("Unexpected canceled-camera error: \(error)") }
            }
            try await wait { pendingCamera.waiting }
            pendingEnable.cancel()
            try await wait { canceledEnableFinished }
            await pendingEnable.value
            XCTAssertFalse(app.snapshot.cameraOn)
            XCTAssertTrue(pendingCamera.canceled)
            native.cameraFactoryForTesting = nil
            print("COLD_STAGE hardware"); fflush(stdout)
            var rows: [[String: Any]] = []
            for cycle in 0..<3 {
                let inputBegan = ProcessInfo.processInfo.systemUptime
                try await app.setMicrophone(true)
                let inputMS = (ProcessInfo.processInfo.systemUptime - inputBegan) * 1000
                XCTAssertTrue(app.snapshot.microphoneOn)
                let before = native.mediaSnapshot.audio.samples
                let decodedBefore = peer.mediaSnapshot.render["advancingFrames"] as? Int ?? 0
                let cameraBegan = ProcessInfo.processInfo.systemUptime
                try await app.setCamera(true)
                let cameraMS = (ProcessInfo.processInfo.systemUptime - cameraBegan) * 1000
                try await wait { (peer.mediaSnapshot.render["advancingFrames"] as? Int ?? 0) > decodedBefore + 5 }
                XCTAssertGreaterThan(native.mediaSnapshot.audio.samples, before, "Incoming audio must continue through capture startup")
                XCTAssertTrue(app.snapshot.cameraOn)
                let evidence = await native.evidence()
                rows.append(["cycle": cycle, "microphoneMilliseconds": inputMS, "cameraMilliseconds": cameraMS,
                    "microphoneStages": app.microphoneStartupMilliseconds,
                    "cameraStages": native.cameraSnapshot?.startupMilliseconds ?? [:],
                    "systemBackgroundActive": native.cameraSnapshot?.systemBackgroundActive ?? false,
                    "physicalAudio": evidence["physicalAudio"] ?? [:], "receivedAudioSamples": native.mediaSnapshot.audio.samples])
                try await app.setCamera(false); try await app.setMicrophone(false)
                XCTAssertFalse(app.snapshot.cameraOn); XCTAssertFalse(app.snapshot.microphoneOn)
                XCTAssertTrue(app.snapshot.playoutOn)
            }
            let evidence: [String: Any] = ["cycles": rows, "maximumMainActorIntervalMilliseconds": maxUIInterval * 1000]
            print("COLD_MEDIA_EVIDENCE " + String(data: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), encoding: .utf8)!)
            XCTAssertLessThan(maxUIInterval, 0.35, "Cold device work must not freeze the UI actor")
            let clean = await app.leave(), peerClean = await peer.leave()
            XCTAssertTrue(clean); XCTAssertTrue(peerClean)
        } catch {
            _ = await app.leave(); _ = await peer.leave(); throw error
        }
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 20
        while !condition(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(30)) }
        guard condition() else { XCTFail("Live media did not arrive"); throw CancellationError() }
    }
}

/// The session waits on its independent control task, just as it does during TCC.
/// Cancel must cross that task boundary and reach this capturer without a reply.
private final class PendingPermissionCamera: GuestCameraCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<GuestCameraInfo, Error>?
    private var stopped = false
    var waiting: Bool { lock.lock(); defer { lock.unlock() }; return continuation != nil }
    var canceled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func start() async throws -> GuestCameraInfo {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if stopped { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation; lock.unlock()
        }
    }
    func cancel() {
        lock.lock(); stopped = true; let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(throwing: CancellationError())
    }
    func stop() async throws { cancel() }
    func performReaction() async -> Bool { false }
    func snapshot() -> GuestCameraSnapshot {
        .init(frames: 0, advancingPTS: 0, dropped: 0, width: 0, height: 0, pixelFormat: nil,
              systemBackgroundSelected: nil, systemBackgroundActive: nil, observedReaction: false)
    }
}
