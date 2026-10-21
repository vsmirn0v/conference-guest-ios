#if DEBUG
import AVFoundation
import ConferenceCore
import SwiftUI
import UIKit
import XCTest
@testable import RockNRoll

@MainActor final class PresenterEngineLiveTests: XCTestCase {
    func testMacGuestSyntheticShareRepeatedStartStop() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              let link = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SHARE_LIFECYCLE_INVITE"] else {
            throw XCTSkip("Opt-in Mac guest share lifecycle check; sends generated canvas only")
        }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow })
        let original = window.rootViewController
        let container = UIViewController(); window.rootViewController = container
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(),
            catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        var active = false, ended = false
        engine.onEvent = {
            switch $0 { case .active: active = true; case .left, .failed: ended = true; default: break }
        }
        addTeardownBlock { @MainActor in
            engine.leave()
            let deadline = Date().addingTimeInterval(10)
            while engine.hasJoinStarted && !ended && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            window.rootViewController = original
        }
        let target = try JoinTarget.parse(link), endpoint = try await VendorEndpointResolver.make().resolve(for: target)
        try engine.configure(container: container, networkURL: endpoint, displayName: "Share lifecycle QA")
        try engine.join(target: target, displayName: "Share lifecycle QA")
        try await wait { active && engine.readyForPresenterForTesting && engine.mediaReadyForTesting || ended }
        XCTAssertFalse(ended)
        // Exercise the actual SDK containment path, rather than the capture-free
        // toolbar fixture or a direct StudioModel call alone.
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        for identifier in ["call.more", "call.view"] {
            let button = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }
                .first { $0.accessibilityIdentifier == identifier })
            XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
            let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
            let hit = window.hitTest(point, with: nil)
            XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true)
            button.sendActions(for: .touchUpInside)
            try await wait { container.presentedViewController is MeetingActionsController || ended }
            let panel = try XCTUnwrap(container.presentedViewController as? MeetingActionsController)
            try await wait { !panel.isBeingPresented }
            panel.dismiss(animated: false)
            try await wait { container.presentedViewController == nil }
        }
        let model = engine.studioForTesting.presenter
        model.selectCanvas(); model.includeCamera = false
        engine.studioForTesting.open(.presenter)
        try await wait { model.hasPreview || ended }
        for iteration in 0..<20 {
            await model.start()
            try await wait { model.running || model.error != nil || ended }
            XCTAssertFalse(ended); XCTAssertNil(model.error)
            XCTAssertTrue(model.running)
            try await Task.sleep(for: .milliseconds(iteration.isMultiple(of: 2) ? 120 : 700))
            model.stop()
            try await wait { !model.stopping || ended }
            XCTAssertFalse(ended); XCTAssertFalse(model.running)
            print("SHARE_LIFECYCLE cycle=\(iteration + 1) stopped")
        }
        engine.leave()
        try await wait { ended }
    }

    func testMacGuestOwnedWindowCaptureRepeatedStartStop() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              let link = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_OWNED_CAPTURE_LIFECYCLE_INVITE"] else {
            throw XCTSkip("Opt-in guest stability test; captures only its own generated window")
        }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow })
        let original = window.rootViewController, container = UIViewController()
        window.rootViewController = container
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(),
            catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        var active = false, ended = false
        engine.onEvent = {
            switch $0 { case .active: active = true; case .left, .failed: ended = true; default: break }
        }
        var fixtures: [OwnedWindowCaptureFixture] = []
        addTeardownBlock { @MainActor in
            engine.leave()
            for fixture in fixtures {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    fixture.stop { continuation.resume() }
                }
            }
            let deadline = Date().addingTimeInterval(10)
            while engine.hasJoinStarted && !ended && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            window.rootViewController = original
        }
        let deadline = Date().addingTimeInterval(65)
        func until(cleanup: Bool = false, line: UInt = #line, _ predicate: () -> Bool) async throws {
            let limit = cleanup ? Date().addingTimeInterval(15) : deadline
            while !predicate() && Date() < limit { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertTrue(predicate(), "Owned capture lifecycle exceeded its time budget", line: line)
            if !predicate() { throw NSError(domain: "OwnedCaptureDeadline", code: Int(line)) }
        }
        let target = try JoinTarget.parse(link), endpoint = try await VendorEndpointResolver.make().resolve(for: target)
        try engine.configure(container: container, networkURL: endpoint, displayName: "Owned capture lifecycle QA")
        try engine.join(target: target, displayName: "Owned capture lifecycle QA")
        try await until { active && engine.readyForPresenterForTesting && engine.mediaReadyForTesting || ended }
        XCTAssertFalse(ended)
        let studio = engine.studioForTesting, model = studio.presenter
        model.includeCamera = false; studio.open(.presenter)
        var cancelDuringStart = true, interruptedStarts = 0, delivered = 0
        model.makeScreenSource = { [weak model] frame, _, selected, end in
            let fixture = OwnedWindowCaptureFixture()
            fixtures.append(fixture)
            fixture.onFrame = { sample in MainActor.assumeIsolated { delivered += 1; frame(sample) } }
            fixture.onSelected = { MainActor.assumeIsolated { selected(.selected) } }
            fixture.onEnd = { error in MainActor.assumeIsolated { end(error.localizedDescription) } }
            fixture.onStarting = { [weak fixture, weak model] in
                MainActor.assumeIsolated {
                    if cancelDuringStart && fixture?.starting == true {
                        interruptedStarts += 1; model?.stop()
                    }
                }
            }
            return OwnedWindowScreenSource(fixture)
        }
        // Retire a genuine asynchronous SCStream start before its first frame.
        model.selectScreen()
        try await until { interruptedStarts == 1 || model.error != nil || ended }
        XCTAssertEqual(interruptedStarts, 1); XCTAssertNil(model.error); XCTAssertFalse(ended)
        await model.waitForScreenStop()
        cancelDuringStart = false
        for iteration in 0..<10 {
            guard Date() < deadline else { throw NSError(domain: "OwnedCaptureDeadline", code: iteration) }
            let before = delivered
            model.selectScreen()
            try await until { model.screenSelected && model.hasPreview || model.error != nil || ended }
            XCTAssertNil(model.error); XCTAssertFalse(ended)
            let fixture = try XCTUnwrap(fixtures.last)
            try await until { fixture.changes >= 2 || model.error != nil || ended }
            await model.start()
            try await until { model.running || model.error != nil || ended }
            XCTAssertTrue(model.running); XCTAssertNil(model.error); XCTAssertFalse(ended)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertGreaterThan(delivered, before)
            print("OWNED_CAPTURE_LIFECYCLE cycle=\(iteration + 1) frames=\(fixture.frames) changes=\(fixture.changes)")
            if iteration == 9 {
                engine.leave() // Last cycle exercises Leave with real capture and SDK upload active.
                try await until(cleanup: true) { ended }
            } else {
                model.stop()
                try await until { !model.stopping || ended }
                XCTAssertFalse(ended)
            }
            await model.waitForScreenStop()
            let stopped = fixture.frames
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(fixture.frames, stopped, "Retired capture delivered another frame")
        }
        XCTAssertTrue(ended)
    }

    func testMacGuestScreenPresenterSelectionAndResize() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              let link = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SCREEN_PRESENTER_INVITE"],
              let receiverURL = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SCREEN_RECEIVER"].flatMap(URL.init(string:)) else {
            throw XCTSkip("Opt-in authorized Mac screen Presenter qualification")
        }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        let original = window.rootViewController
        let container = UIViewController(); window.rootViewController = container
        defer { window.rootViewController = original }
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        var active = false, ended = false
        engine.onEvent = { event in
            switch event { case .active: active = true; case .left, .failed: ended = true; default: break }
        }
        let target = try JoinTarget.parse(link), endpoint = try await VendorEndpointResolver.make().resolve(for: target)
        try engine.configure(container: container, networkURL: endpoint, displayName: "Presenter resize QA")
        try engine.join(target: target, displayName: "Presenter resize QA")
        defer { engine.leave() }
        try await wait { active && engine.readyForPresenterForTesting || ended }; XCTAssertFalse(ended)
        let studio = engine.studioForTesting, model = studio.presenter
        XCTAssertNotNil(model.prepareScreenSource)
        let create = try XCTUnwrap(model.makeScreenSource)
        var sizes = Set<String>(), frames = 0, aspects = [String: Double]()
        model.makeScreenSource = { frame, effect, selected, end in
            create({ sample in
                if let pixels = CMSampleBufferGetImageBuffer(sample) {
                    let size = "\(CVPixelBufferGetWidth(pixels))x\(CVPixelBufferGetHeight(pixels))"
                    if sizes.insert(size).inserted { print("MAC_SCREEN_PRESENTER capture=\(size)") }
                    aspects[size] = Double(CVPixelBufferGetWidth(pixels)) / Double(CVPixelBufferGetHeight(pixels))
                    frames += 1
                }
                frame(sample)
            }, effect, selected, end)
        }
        studio.open(.presenter)
        let inspector = UIHostingController(rootView: StudioPanel(model: studio))
        container.present(inspector, animated: false)
        // Select through the actual Source button; a browser receives only the
        // explicitly shared synthetic window, never other desktop content.
        let selectionDeadline = Date().addingTimeInterval(120)
        while !model.screenSelected && model.error == nil && !ended && Date() < selectionDeadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertNil(model.error); XCTAssertTrue(model.screenSelected); XCTAssertFalse(ended)
        try await wait { model.hasPreview || ended }
        XCTAssertFalse(model.running); XCTAssertEqual(model.source, .screen)
        model.appendAnnotation([CGPoint(x: 0.03, y: 0.03), CGPoint(x: 0.03, y: 0.4)])
        _ = try await URLSession.shared.data(from: receiverURL.appendingPathComponent("reset"))
        await model.start(); try await wait { model.running || ended }
        print("MAC_SCREEN_PRESENTER started=\(model.running) error=\(model.error ?? "none")")
        let resizeDeadline = Date().addingTimeInterval(55)
        var received = Set<String>()
        while Date() < resizeDeadline && !ended {
            let (data, _) = try await URLSession.shared.data(from: receiverURL.appendingPathComponent("frames"))
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertTrue(report["error"] is NSNull, "Browser must read actual decoded pixels")
            let values = report["frames"] as? [[String: Any]] ?? []
            for (size, aspect) in aspects {
                let matched = values.filter {
                    guard let width = $0["width"] as? Double, let height = $0["height"] as? Double, height > 0 else { return false }
                    return abs(width / height - aspect) < 0.02
                }
                let pixels = Set(matched.compactMap { ($0["hash"] as? NSNumber)?.uint64Value })
                if pixels.count >= 5 { received.insert(size) }
            }
            if sizes.count >= 3 && received.isSuperset(of: sizes) { break }
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertGreaterThanOrEqual(sizes.count, 3)
        XCTAssertTrue(received.isSuperset(of: sizes), "Every captured aspect must reach a moving receiver: captured=\(sizes), received=\(received)")
        XCTAssertTrue(model.running); XCTAssertNil(model.error); XCTAssertFalse(ended)
        print("MAC_SCREEN_PRESENTER receiverVerified=\(received.sorted())")
        let evidence = await GuestMicrophoneProbe.codecEvidenceForTesting()
        print("MAC_SCREEN_PRESENTER frames=\(frames) sizes=\(sizes.sorted()) outbound=\(evidence.filter { $0["type"] as? String == "outbound-rtp" })")
        XCTAssertTrue(evidence.contains { $0["type"] as? String == "outbound-rtp" && $0["kind"] as? String == "video" && ($0["framesEncoded"] as? NSNumber)?.intValue ?? 0 > 20 })
        model.stop(); try await wait { !model.stopping }; await model.waitForScreenStop()
        let final = frames
        try await Task.sleep(for: .milliseconds(500)); XCTAssertEqual(frames, final)
    }
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
            ready = { selected.readyForPresenterForTesting && selected.mediaReadyForTesting }
            send = { microphone, camera in
                selected.setMicrophoneForTesting(microphone)
                selected.setCameraForTesting(camera)
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
            var camera = await stats()
            let deadline = Date().addingTimeInterval(15)
            while !camera.contains(where: { $0["kind"] as? String == "video" && ($0["framesEncoded"] as? NSNumber)?.intValue ?? 0 > 10 }), Date() < deadline {
                try await Task.sleep(for: .milliseconds(250)); camera = await stats()
            }
            print("PRESENTER_GUEST_CAMERA streams=\(camera)")
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
            }, "The actual SDK sharing transport must preserve its qualified BGRA conversion matrix")
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
    private func wait(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(30)
        while !predicate(), Date() < end { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(predicate(), file: file, line: line)
        if !predicate() { throw NSError(domain: "PresenterQualification", code: Int(line)) }
    }
}

@MainActor
private final class OwnedWindowScreenSource: PresenterScreenSource {
    private let fixture: OwnedWindowCaptureFixture
    init(_ fixture: OwnedWindowCaptureFixture) { self.fixture = fixture }
    func start() { fixture.start() }
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            fixture.stop { continuation.resume() }
        }
    }
}
#endif
