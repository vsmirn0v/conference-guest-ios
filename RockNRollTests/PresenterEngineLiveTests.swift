#if DEBUG
import AVFoundation
import ConferenceCore
import UIKit
import XCTest
@testable import RockNRoll

@MainActor final class PresenterEngineLiveTests: XCTestCase {
    func testMacNativeOrdinaryCameraGeometry() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              let name = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_CAMERA_ENGINE"],
              let link = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_CAMERA_INVITE"] else {
            throw XCTSkip("Opt-in authorized Mac native-camera check")
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw XCTSkip("Existing camera permission required") }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        let original = window.rootViewController, idle = UIApplication.shared.isIdleTimerDisabled
        let container = UIViewController(); window.rootViewController = container; UIApplication.shared.isIdleTimerDisabled = true
        defer { window.rootViewController = original; UIApplication.shared.isIdleTimerDisabled = idle }
        let call = SystemCallCoordinator(), catchUp = CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var active = false, ended = false
        let events: (CallEvent) -> Void = { event in
            switch event { case .active: active = true; case .connecting: active = false; case .left, .failed: ended = true; default: break }
        }
        let engine: any CallEngine, studio: StudioModel, stats: () async -> [[String: Any]]
        switch name {
        case "telemost":
            let selected = TelemostCallEngine(systemCall: call, catchUp: catchUp, chat: ChatStore())
            selected.onEvent = events; engine = selected; studio = selected.studioForTesting
            stats = { await selected.codecEvidenceForTesting() }
            try selected.join(target: TelemostTarget.parse(link), name: "Camera geometry QA", container: container, quiet: false)
        case "trueconf":
            let selected = TrueConfCallEngine(systemCall: call, catchUp: catchUp, chat: ChatStore())
            selected.onEvent = events; engine = selected; studio = selected.studioForTesting
            stats = { await selected.codecEvidenceForTesting() }
            try selected.join(target: TrueConfTarget.parse(link), name: "Camera geometry QA", container: container, quiet: false)
        default: throw XCTSkip("Select a native engine")
        }
        defer { engine.leave() }
        try await wait { active || ended }; XCTAssertFalse(ended)
        studio.open(.camera)
        try await wait { studio.previewRunning || ended }; XCTAssertFalse(ended)
        XCTAssertFalse(studio.cameraOn); XCTAssertFalse(studio.microphoneOn)
        let first = try XCTUnwrap(studio.selectedCameraDevice)
        print("MAC_NATIVE_CAMERA engine=\(name) stage=private automaticFraming=\(AVCaptureDevice.isCenterStageEnabled) centerStageActive=\(first.isCenterStageActive)")
        if studio.canFlipCamera {
            studio.flipCamera()
            try await wait { !studio.switchingCamera && studio.previewRunning && studio.selectedCameraDevice?.uniqueID != first.uniqueID || ended }
            XCTAssertFalse(studio.cameraOn)
        } else { print("MAC_NATIVE_CAMERA engine=\(name) switchSkipped=single-camera") }
        let selected = try XCTUnwrap(studio.selectedCameraDevice)
        let started = await studio.startVideo(); XCTAssertTrue(started)
        try await wait { studio.cameraOn && studio.liveCaptureDevice?()?.uniqueID == selected.uniqueID || ended }
        XCTAssertFalse(ended); XCTAssertFalse(studio.microphoneOn)
        try await Task.sleep(for: .seconds(3))
        let firstStats = await stats()
        print("MAC_NATIVE_CAMERA engine=\(name) stage=published streams=\(firstStats.filter { $0["type"] as? String == "outbound-rtp" })")
        if studio.canFlipCamera {
            studio.open(.camera); studio.flipCamera()
            try await wait { !studio.switchingCamera && studio.liveCaptureDevice?()?.uniqueID != selected.uniqueID || ended }
            XCTAssertNotNil(studio.previewView); studio.close()
        }
        let seconds = min(90, max(10, Int(ProcessInfo.processInfo.environment["ROCKNROLL_TEST_CAMERA_OBSERVE_SECONDS"] ?? "20") ?? 20))
        try await Task.sleep(for: .seconds(seconds))
        let final = await stats()
        let previous = firstStats.reduce(into: [String: Int]()) { counts, row in counts[row["id"] as? String ?? ""] = (row["framesEncoded"] as? NSNumber)?.intValue ?? 0 }
        XCTAssertTrue(final.contains { row in row["type"] as? String == "outbound-rtp" && row["kind"] as? String == "video" &&
            (row["framesEncoded"] as? NSNumber)?.intValue ?? 0 > previous[row["id"] as? String ?? "", default: 0] + 20 })
        XCTAssertFalse(ended); XCTAssertFalse(studio.microphoneOn)
        print("MAC_NATIVE_CAMERA engine=\(name) stage=final streams=\(final.filter { $0["type"] as? String == "outbound-rtp" })")
    }
    func testNativePresenterCameraSurvivesAudioChangesAndHold() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical camera and microphone required")
        #endif
        guard let name = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PRESENTER_ENGINE"],
              let link = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PRESENTER_INVITE"] else { throw XCTSkip("Authorized room required") }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw XCTSkip("Capture permissions required") }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        let original = window.rootViewController, idle = UIApplication.shared.isIdleTimerDisabled
        let originalProfile = UserDefaults.standard.object(forKey: "studio.audio-profile")
        let originalLayout = UserDefaults.standard.object(forKey: "presenter.layout.v1")
        let container = UIViewController(); window.rootViewController = container; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            window.rootViewController = original; UIApplication.shared.isIdleTimerDisabled = idle
            UserDefaults.standard.set(originalProfile, forKey: "studio.audio-profile")
            UserDefaults.standard.set(originalLayout, forKey: "presenter.layout.v1")
        }
        let call = SystemCallCoordinator(), catchUp = CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var active = false, ended = false
        let events: (CallEvent) -> Void = { event in
            switch event { case .active: active = true; case .connecting: active = false; case .left, .failed: ended = true; default: break }
        }
        let engine: any CallEngine, studio: StudioModel
        let send: (Bool, Bool) -> Void, stats: () async -> [[String: Any]], ready: () -> Bool
        switch name {
        case "telemost":
            let selected = TelemostCallEngine(systemCall: call, catchUp: catchUp, chat: ChatStore())
            selected.onEvent = events; engine = selected; studio = selected.studioForTesting
            ready = { selected.readyForPresenterForTesting }
            send = { selected.setSendingForTesting(microphone: $0, camera: $1) }; stats = { await selected.codecEvidenceForTesting() }
            try selected.join(target: TelemostTarget.parse(link), name: "Presenter qualification", container: container, quiet: false)
        case "trueconf":
            let selected = TrueConfCallEngine(systemCall: call, catchUp: catchUp, chat: ChatStore())
            selected.onEvent = events; engine = selected; studio = selected.studioForTesting
            ready = { selected.readyForPresenterForTesting }
            send = { selected.setSendingForTesting(microphone: $0, camera: $1) }; stats = { await selected.codecEvidenceForTesting() }
            try selected.join(target: TrueConfTarget.parse(link), name: "Presenter qualification", container: container, quiet: false)
        case "guest":
            let selected = NativeConferenceEngine(systemCall: call, catchUp: catchUp)
            selected.onEvent = events; engine = selected; studio = selected.studioForTesting
            ready = { selected.readyForPresenterForTesting }
            send = { microphone, camera in
                for (enabled, on, off) in [(microphone, L("Mute microphone"), L("Unmute microphone")), (camera, L("Stop video"), L("Start video"))] {
                    let label = enabled ? off : on
                    self.descendants(container.view).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == label }?.sendActions(for: .touchUpInside)
                }
            }
            stats = { await GuestMicrophoneProbe.codecEvidenceForTesting() }
            let target = try JoinTarget.parse(link), endpoint = try await VendorEndpointResolver.make().resolve(for: target)
            let displayName = UserDefaults.standard.string(forKey: "savedDisplayName") ?? "Presenter qualification"
            try selected.configure(container: container, networkURL: endpoint, displayName: displayName)
            try selected.join(target: target, displayName: displayName)
        default: throw XCTSkip("Community supports ordinary sharing, not Presenter composition")
        }
        defer { engine.leave() }
        try await wait { active && ready() || ended }; XCTAssertFalse(ended)
        if name == "guest" {
            // Establish the SDK's ordinary publisher before its separate share transport.
            send(false, true)
            try await wait { studio.cameraOn || ended }
            try await Task.sleep(for: .seconds(3))
            let camera = await stats()
            XCTAssertTrue(camera.contains { $0["mimeType"] as? String == "video/H264" &&
                ($0["framesEncoded"] as? NSNumber)?.intValue ?? 0 > 10 }, "Actual guest camera must use hardware H264")
            send(false, false)
            try await wait { !studio.cameraOn || ended }
        }
        studio.presenter.selectCanvas(); studio.open(.presenter); studio.presenter.includeCamera = true
        try await wait { studio.presenter.hasCameraFrames && studio.presenter.hasPreview || ended }
        XCTAssertFalse(ended)
        await studio.presenter.start(); try await wait { studio.presenter.running || ended }
        XCTAssertFalse(ended)
        await studio.presenter.stop()
        try await wait { !studio.presenter.stopping || ended }
        // Transition from the app's private capture to the engine's live track.
        send(false, true)
        try await wait { studio.cameraOn && studio.presenter.hasCameraFrames && studio.presenter.hasPreview && !studio.presenter.stopping || ended }
        XCTAssertFalse(ended)
        await studio.presenter.start(); try await wait { studio.presenter.running || ended }
        for profile in [StudioAudioProfile.music, .conversation] {
            studio.select(profile)
            try await wait { !studio.applying && studio.profile == profile || ended }
            XCTAssertNil(studio.error); XCTAssertFalse(ended)
            send(true, true)
            try await wait { studio.microphoneOn || ended }
            try await assertAdvancing(studio.presenter, stats: stats)
            let audio = await stats()
            XCTAssertTrue(audio.contains { $0["type"] as? String == "outbound-rtp" && $0["kind"] as? String == "audio" &&
                (($0["mimeType"] as? String)?.lowercased() == "audio/opus") && ($0["bytesSent"] as? NSNumber)?.intValue ?? 0 > 0 }, "Presenter must retain active Opus audio publishing")
            send(false, true)
            try await wait { !studio.microphoneOn || ended }
            try await assertAdvancing(studio.presenter, stats: stats)
        }
        let sending = await stats()
        XCTAssertGreaterThan(shareFrames(sending).values.reduce(0, +), 20)
        if name == "guest" {
            let colors = GuestH264ColorEncoder.evidenceForTesting()
            print("PRESENTER_GUEST_COLOR \(colors)")
            XCTAssertTrue(colors.contains { row in
                (row["inputFormat"] as? NSNumber)?.uint32Value == kCVPixelFormatType_32BGRA &&
                (row["inputWidth"] as? NSNumber)?.intValue == 1280 && (row["inputHeight"] as? NSNumber)?.intValue == 720 &&
                (row["knownInputs"] as? Int ?? 0) > 10 && (row["taggedKeyframes"] as? Int ?? 0) > 0
            }, "The actual SDK sharing transport must preserve the qualified Presenter color contract")
        }
        print("PRESENTER_ENGINE name=\(name) stage=audio-changes streams=\(sending)")
        try await engine.setTransferHeld(true, restoreSending: true)
        try await wait { !studio.presenter.running }
        try await engine.setTransferHeld(false, restoreSending: true)
        try await wait { !studio.held && ready() || ended }
        // Hold intentionally dismisses Studio; reopen before requesting a camera tap.
        studio.open(.presenter)
        print("PRESENTER_RESUME name=\(name) active=\(studio.active) presented=\(studio.presented) camera=\(studio.cameraOn) held=\(studio.held) source=\(studio.presenter.source)")
        defer { print("PRESENTER_FINAL name=\(name) active=\(studio.active) presented=\(studio.presented) camera=\(studio.cameraOn) held=\(studio.held) frames=\(studio.presenter.hasCameraFrames)") }
        for _ in 0..<10 {
            if studio.cameraOn && studio.presenter.hasCameraFrames || ended { break }
            print("PRESENTER_CAMERA \(studio.presenter.cameraEvidenceForTesting) streams=\(await stats())")
            try await Task.sleep(for: .seconds(1))
        }
        try await wait { studio.cameraOn && studio.presenter.hasCameraFrames && studio.presenter.hasPreview && !studio.presenter.stopping || ended }
        XCTAssertFalse(ended)
        // CallKit resume and transport replacement may finish in different turns.
        let resumeDeadline = Date().addingTimeInterval(30)
        while !studio.presenter.running && !ended && Date() < resumeDeadline {
            if ready() && studio.presenter.hasPreview && !studio.presenter.stopping { await studio.presenter.start() }
            if !studio.presenter.running { try await Task.sleep(for: .milliseconds(200)) }
        }
        XCTAssertTrue(studio.presenter.running, "Presenter must restart once transport and preview are ready")
        XCTAssertNil(studio.presenter.error); XCTAssertFalse(ended)
        try await assertAdvancing(studio.presenter, stats: stats)
        let recovered = await stats()
        XCTAssertGreaterThan(shareFrames(recovered).values.reduce(0, +), 20)
        print("PRESENTER_ENGINE name=\(name) stage=hold-recovery streams=\(recovered)")
        await studio.presenter.stop(); studio.presenter.includeCamera = false
        send(false, false); studio.close()
        try await wait { !studio.cameraOn && !studio.microphoneOn || ended }
        XCTAssertFalse(ended)
    }

    private func assertAdvancing(_ model: PresenterModel, stats: () async -> [[String: Any]]) async throws {
        let before = model.compositionCount
        let sent = shareFrames(await stats())
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(model.hasCameraFrames)
        XCTAssertGreaterThan(model.compositionCount, before, "Audio renegotiation must not freeze the live Presenter camera")
        XCTAssertTrue(model.running)
        let after = shareFrames(await stats())
        XCTAssertTrue(after.contains { $0.value >= sent[$0.key, default: 0] + 10 }, "The Presenter track must encode fresh frames, independently of ordinary camera counters")
    }
    private func shareFrames(_ rows: [[String: Any]]) -> [String: Int] {
        let sharing = rows.filter { $0["type"] as? String == "outbound-rtp" && $0["kind"] as? String == "video" &&
            ($0["frameWidth"] as? NSNumber)?.intValue == 1280 && ($0["frameHeight"] as? NSNumber)?.intValue == 720 &&
            ($0["track"] as? String).map { $0 == "screen" } != false && $0["rawCamera"] as? Bool != true }
        return Dictionary(sharing.map { row in
            (row["id"] as? String ?? row["mid"] as? String ?? "share", (row["framesEncoded"] as? NSNumber)?.intValue ?? 0)
        }, uniquingKeysWith: max)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(30)
        while !predicate(), Date() < end { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(predicate()); if !predicate() { throw NSError(domain: "PresenterQualification", code: 1) }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
#endif
