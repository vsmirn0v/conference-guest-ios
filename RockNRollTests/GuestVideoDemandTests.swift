import UIKit
import AVKit
import JazzSDK
import CoreMedia
import WebRTC
import XCTest
@testable import RockNRoll

@MainActor
final class GuestVideoDemandTests: XCTestCase {
    func testBackgroundShareReplacementAndHoldPrimeFreshFramesWithoutForeground() async throws {
        try XCTSkipUnless(AVPictureInPictureController.isPictureInPictureSupported(), "This runtime cannot create a video-call PiP controller")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        let source = try XCTUnwrap(window.rootViewController?.view)
        var state = UIApplication.State.active, starts = 0
        let floating = GuestVideoPictureInPicture(sourceView: source, floatingEnvironment: .init(
            applicationState: { state }, supported: { true }, possible: { _ in true }, start: { _ in starts += 1 }, stop: { _ in }))
        defer { floating.end(); window.isHidden = true }
        floating.rendersSelectedViewport = false
        let renderer = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        let viewport = makeViewport(renderer)
        // This is the production direct-delivery path, with no inline callback
        // to accidentally prime PiP only because the test UI is visible.
        floating.select(viewport: viewport, name: "Slides", isScreenShare: true)
        renderer.renderFrame(staticFrame(luma: 70))
        let ready = Date().addingTimeInterval(2)
        while !floating.hasPreparedFrameForTesting && Date() < ready { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(floating.hasPreparedFrameForTesting)
        floating.start()
        let lifecycle = floating.lifecycleForTesting, controller = try XCTUnwrap(lifecycle.controllerForTesting)
        lifecycle.pictureInPictureControllerWillStartPictureInPicture(controller)
        lifecycle.pictureInPictureControllerDidStartPictureInPicture(controller)
        state = .background; floating.backgrounded()
        floating.select(viewport: nil, name: "", isScreenShare: false)
        XCTAssertTrue(lifecycle.isPresenting)
        floating.select(viewport: viewport, name: "Slides restarted", isScreenShare: true)
        renderer.renderFrame(staticFrame(luma: 120))
        let replaced = Date().addingTimeInterval(2)
        while !floating.hasPreparedFrameForTesting && Date() < replaced { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(floating.hasPreparedFrameForTesting)
        floating.setSuspended(true)
        lifecycle.pictureInPictureControllerDidStopPictureInPicture(controller)
        floating.setSuspended(false)
        XCTAssertTrue(lifecycle.needsRecoveryFrames)
        // A rebuilt SDK transport can replace the renderer before any new
        // decoded frame arrives. That gap must not discard recovery intent.
        let replacement = RTCEAGLVideoView(frame: renderer.bounds)
        floating.select(viewport: makeViewport(replacement), name: "Slides recovered", isScreenShare: true)
        XCTAssertTrue(lifecycle.needsRecoveryFrames)
        XCTAssertTrue(lifecycle.controllerForTesting === controller)
        let count = floating.convertedFramesForTesting
        replacement.renderFrame(staticFrame(luma: 180))
        let recovered = Date().addingTimeInterval(2)
        while starts < 2 && Date() < recovered { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(floating.convertedFramesForTesting, count)
        XCTAssertEqual(starts, 2, "Fresh background media must rearm the retained PiP")
        XCTAssertTrue(floating.hasPreparedFrameForTesting)
    }
    func testStaticShareReappearsAfterTileSwitchAndRendererReplacementWithoutNewFrames() async throws {
        let streams = GuestStreamViews()
        defer { streams.reset() }
        let renderer = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        let share = try XCTUnwrap(streams.makeView(model: shareModel(), video: renderer) as? StreamViewport)
        let floating = GuestVideoPictureInPicture(sourceView: UIView())
        defer { floating.end() }
        // The sender becomes static before a corrected display sink subscribes.
        renderer.renderFrame(staticFrame(luma: 96))
        try await expectShareFrame(floating, luma: 96) {
            floating.select(viewport: share, name: "Slides", isScreenShare: true)
        }
        let other = makeViewport(RTCEAGLVideoView(frame: renderer.frame))
        floating.select(viewport: other, name: "Camera", isScreenShare: false)
        try await expectShareFrame(floating, luma: 96) {
            floating.select(viewport: share, name: "Slides", isScreenShare: true)
        }
        let replacement = RTCEAGLVideoView(frame: renderer.frame)
        let next = try XCTUnwrap(streams.makeView(model: shareModel(), video: replacement) as? StreamViewport)
        try await expectShareFrame(floating, luma: 96) {
            floating.select(viewport: next, name: "Slides", isScreenShare: true)
        }
        // Replay is event-driven, not a timer that keeps converting static slides.
        let count = floating.convertedFramesForTesting
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(floating.convertedFramesForTesting, count)
    }

    func testShareForegroundAndPiPResumeLatestFrameWithoutPresenterMovement() async throws {
        let streams = GuestStreamViews()
        defer { streams.reset() }
        let renderer = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        let share = try XCTUnwrap(streams.makeView(model: shareModel(), video: renderer) as? StreamViewport)
        let floating = GuestVideoPictureInPicture(sourceView: UIView())
        defer { floating.end() }
        try await expectShareFrame(floating, luma: 96) {
            floating.select(viewport: share, name: "Slides", isScreenShare: true)
            renderer.renderFrame(staticFrame(luma: 96))
        }
        floating.backgrounded()
        let count = floating.convertedFramesForTesting
        // Decode may continue offscreen, but conversion must stay paused.
        renderer.renderFrame(staticFrame(luma: 160))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(floating.convertedFramesForTesting, count)
        try await expectShareFrame(floating, luma: 160) { floating.foregrounded() }
        floating.wantsInlineFrames = false
        let prepared = floating.convertedFramesForTesting
        floating.setFloatingForTesting(true)
        let deadline = Date().addingTimeInterval(1)
        while floating.convertedFramesForTesting == prepared && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(floating.convertedFramesForTesting, prepared)
        floating.setFloatingForTesting(false)
        try await expectShareFrame(floating, luma: 160) { floating.wantsInlineFrames = true }
    }

    func testShareCacheRetiresOnStopDepartureAndSessionReset() {
        for ending in 0..<3 {
            let streams = GuestStreamViews()
            let renderer = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
            let tile = streams.makeView(model: shareModel(), video: renderer)
            var received = 0
            let tap = GuestVideoFrameTap(view: renderer) { _ in received += 1 }
            renderer.renderFrame(staticFrame(luma: 96))
            tap?.replayLatestFrame()
            XCTAssertEqual(received, 2)
            if ending == 0 { streams.updateActiveMedia(sharing: [], cameras: [], participants: ["slides"]) }
            else if ending == 1 { streams.updateActiveMedia(sharing: [], cameras: [], participants: []) }
            else { streams.reset(preservingSelection: true) }
            tap?.replayLatestFrame()
            XCTAssertEqual(received, 2, "Retired shares must not replay across stop or reconnect")
            tap?.invalidate()
            withExtendedLifetime(tile) {}
        }
    }

    func testShareSnapshotIsIsolatedAndSurvivesSDKSurfaceClear() {
        let streams = GuestStreamViews()
        defer { streams.reset() }
        let a = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        let b = RTCEAGLVideoView(frame: a.frame)
        let tiles = [streams.makeView(model: shareModel(), video: a),
                     streams.makeView(model: shareModel(id: "other"), video: b)]
        a.renderFrame(staticFrame(luma: 96))
        var received = 0
        let tap = GuestVideoFrameTap(view: b) { _ in received += 1 }
        tap?.replayLatestFrame()
        XCTAssertEqual(received, 0)
        b.renderFrame(staticFrame(luma: 160))
        tap?.replayLatestFrame()
        XCTAssertEqual(received, 2)
        b.renderFrame(nil)
        tap?.replayLatestFrame()
        XCTAssertEqual(received, 3, "A cleared SDK tile is not an ended share")
        tap?.invalidate()
        withExtendedLifetime(tiles) {}
    }

    func testRestartedShareOnSameSDKRendererCannotReplayPreviousPublication() {
        let streams = GuestStreamViews()
        defer { streams.reset() }
        let renderer = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        let tile = streams.makeView(model: shareModel(), video: renderer)
        renderer.renderFrame(staticFrame(luma: 96))
        streams.updateActiveMedia(sharing: [], cameras: [], participants: ["slides"])
        streams.updateActiveMedia(sharing: ["slides"], cameras: [], participants: ["slides"])
        let restarted = streams.makeView(model: shareModel(), video: renderer)
        var received = 0
        let tap = GuestVideoFrameTap(view: renderer) { _ in received += 1 }
        tap?.replayLatestFrame()
        XCTAssertEqual(received, 0)
        renderer.renderFrame(staticFrame(luma: 160))
        tap?.replayLatestFrame()
        XCTAssertEqual(received, 2, "Reusing a tile must attach a new, empty snapshot owner")
        tap?.invalidate()
        withExtendedLifetime([tile, restarted]) {}
    }

    func testGalleryRestoresStaticShareWhenMadeVisibleAgain() async throws {
        let streams = GuestStreamViews()
        defer { streams.reset() }
        let renderer = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        let tile = streams.makeView(model: shareModel(), video: renderer)
        renderer.renderFrame(staticFrame(luma: 96))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let root = UIViewController(); window.rootViewController = root; window.makeKeyAndVisible()
        let gallery = GuestGalleryView(frame: window.bounds)
        root.view.addSubview(gallery)
        defer { gallery.setActive(false); window.isHidden = true }
        gallery.update([.init(id: .init(participant: "slides", isShare: true), name: "Slides",
            microphoneOn: false, active: true, speaking: false, watermark: nil, renderer: renderer)])
        gallery.layoutIfNeeded()
        for _ in 0..<2 {
            gallery.setActive(true)
            let deadline = Date().addingTimeInterval(1)
            while (gallery.evidenceForTesting.first?["preparedFrames"] as? Int ?? 0) < 1 && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertTrue(gallery.evidenceForTesting.first?["hasFrame"] as? Bool == true)
            gallery.setActive(false)
        }
        XCTAssertEqual(gallery.evidenceForTesting.first?["preparedFrames"] as? Int, 2)
        withExtendedLifetime(tile) {}
    }

    private func shareModel(id: String = "slides") -> JazzParticipantViewModel {
        JazzParticipantViewModel(name: "Slides", isAudioOn: false, isVideoOn: true,
            isPinned: false, isSharingScreen: true, isLocal: false, id: id,
            isDominantSpeaker: false, shouldShowParticipantInfo: true, isZoomable: true,
            watermarkState: .hidden, displayMode: .speaker)
    }

    private func staticFrame(luma: UInt8) -> RTCVideoFrame {
        let buffer = RTCMutableI420Buffer(width: 4, height: 2, strideY: 4, strideU: 2, strideV: 2)
        for index in 0..<8 { buffer.mutableDataY[index] = luma }
        for index in 0..<2 { buffer.mutableDataU[index] = 128; buffer.mutableDataV[index] = 128 }
        return RTCVideoFrame(buffer: buffer, rotation: RTCVideoRotation(rawValue: 0)!,
                            timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
    }

    private func expectShareFrame(_ floating: GuestVideoPictureInPicture, luma: UInt8,
                                  action: () -> Void) async throws {
        let frame = expectation(description: "Static share immediately restores without another source frame")
        floating.onInlineSample = { sample, _ in
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                XCTAssertEqual(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.load(as: UInt8.self), luma)
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            } else { XCTFail("Missing decoded pixels") }
            frame.fulfill()
        }
        action()
        await fulfillment(of: [frame], timeout: 1)
        floating.onInlineSample = nil
    }

    func testActiveFloatingRendererReplacementKeepsCameraEligibilityAnchor() async throws {
        try XCTSkipUnless(AVPictureInPictureController.isPictureInPictureSupported())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        let source = try XCTUnwrap(window.rootViewController?.view)
        let first = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        let second = RTCEAGLVideoView(frame: first.frame)
        var state = UIApplication.State.active
        let floating = GuestVideoPictureInPicture(sourceView: source, floatingEnvironment: .init(
            applicationState: { state }, supported: { true }, possible: { _ in true }, start: { _ in }, stop: { _ in }))
        defer { floating.end(); window.isHidden = true }
        let firstViewport = makeViewport(first), secondViewport = makeViewport(second)
        floating.select(viewport: firstViewport, name: "First", isScreenShare: false)
        try await feed(first)
        XCTAssertTrue(floating.hasSourceForTesting)
        floating.start()
        let controller = try XCTUnwrap(floating.lifecycleForTesting.controllerForTesting)
        floating.lifecycleForTesting.pictureInPictureControllerWillStartPictureInPicture(controller)
        floating.lifecycleForTesting.pictureInPictureControllerDidStartPictureInPicture(controller)
        state = .background; floating.backgrounded()
        floating.select(viewport: secondViewport, name: "Second", isScreenShare: false)
        XCTAssertFalse(floating.hasPreparedFrameForTesting)
        XCTAssertTrue(floating.hasSourceForTesting, "Replacing a renderer must not revoke active video-call PiP")
        let before = floating.convertedFramesForTesting
        try await feed(first)
        XCTAssertEqual(floating.convertedFramesForTesting, before)
        try await feed(second)
        XCTAssertGreaterThan(floating.convertedFramesForTesting, before)
        floating.clear()
        XCTAssertTrue(floating.hasSourceForTesting, "An active PiP retains its anchor between presenters")
        XCTAssertTrue(floating.lifecycleForTesting.waitingForVideoForTesting)
        floating.clear(preservingPresentation: false)
        XCTAssertFalse(floating.hasSourceForTesting, "Audio only explicitly retires the anchor")
    }

    func testFallbackSelfVideoNeverPaintsTheSelectedRemoteStage() async throws {
        let renderer = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        let floating = GuestVideoPictureInPicture(sourceView: UIView())
        defer { floating.end() }
        let viewport = makeViewport(renderer)
        var inline = 0
        floating.onInlineSample = { _, _ in inline += 1 }
        floating.select(viewport: viewport, name: "You", isScreenShare: false, isStageSource: false)
        try await feed(renderer)
        XCTAssertTrue(floating.hasSourceForTesting)
        XCTAssertEqual(inline, 0)
        let primed = floating.convertedFramesForTesting
        try await feed(renderer)
        XCTAssertEqual(floating.convertedFramesForTesting, primed, "A hidden fallback needs just one prepared frame")
        floating.setFloatingForTesting(true)
        try await feed(renderer)
        XCTAssertGreaterThan(floating.convertedFramesForTesting, primed)
        XCTAssertEqual(inline, 0)
        floating.select(viewport: viewport, name: "You", isScreenShare: false)
        try await feed(renderer)
        XCTAssertGreaterThan(inline, 0)
    }

    func testGridPreparesOnceThenPiPAndInlineResumeRealFrameConversion() async throws {
        let renderer = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        let viewport = makeViewport(renderer)
        let floating = GuestVideoPictureInPicture(sourceView: UIView())
        defer { floating.end() }
        floating.wantsInlineFrames = false
        var inline = 0
        floating.onInlineSample = { _, _ in inline += 1 }
        floating.select(viewport: viewport, name: "Remote", isScreenShare: false)
        try await feed(renderer)
        XCTAssertTrue(floating.hasPreparedFrameForTesting)
        XCTAssertEqual(floating.convertedFramesForTesting, 1)
        XCTAssertEqual(inline, 0, "A hidden stage must not receive the gallery's duplicate frame")
        try await feed(renderer)
        XCTAssertEqual(floating.convertedFramesForTesting, 1, "PiP readiness must not keep a second converter running")

        // Uses the same transition as FloatingVideoController.onWillStart,
        // before the system sends its presentation-state notification.
        floating.setFloatingForTesting(true)
        try await feed(renderer)
        XCTAssertGreaterThan(floating.convertedFramesForTesting, 1)
        XCTAssertEqual(inline, 0)
        floating.setFloatingForTesting(false)
        let parked = floating.convertedFramesForTesting
        try await feed(renderer)
        XCTAssertEqual(floating.convertedFramesForTesting, parked)

        floating.wantsInlineFrames = true
        try await feed(renderer)
        XCTAssertGreaterThan(floating.convertedFramesForTesting, parked)
        XCTAssertGreaterThan(inline, 0)
    }

    func testHoldSourceReplacementCameraOffAndEndRetirePreparedFrames() async throws {
        let first = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        let second = RTCEAGLVideoView(frame: first.frame)
        let floating = GuestVideoPictureInPicture(sourceView: UIView())
        floating.wantsInlineFrames = false
        let firstViewport = makeViewport(first), secondViewport = makeViewport(second)
        floating.select(viewport: firstViewport, name: "First", isScreenShare: false)
        try await feed(first)
        XCTAssertTrue(floating.hasPreparedFrameForTesting)
        floating.setSuspended(true)
        XCTAssertFalse(floating.hasPreparedFrameForTesting)
        let held = floating.convertedFramesForTesting
        try await feed(first)
        XCTAssertEqual(floating.convertedFramesForTesting, held)
        floating.setSuspended(false)
        try await feed(first)
        XCTAssertEqual(floating.convertedFramesForTesting, held + 1)

        floating.select(viewport: secondViewport, name: "Second", isScreenShare: false)
        XCTAssertFalse(floating.hasPreparedFrameForTesting)
        let replaced = floating.convertedFramesForTesting
        try await feed(first)
        XCTAssertEqual(floating.convertedFramesForTesting, replaced)
        try await feed(second)
        XCTAssertEqual(floating.convertedFramesForTesting, replaced + 1)

        floating.clear()
        XCTAssertFalse(floating.hasPreparedFrameForTesting)
        let stopped = floating.convertedFramesForTesting
        try await feed(second)
        XCTAssertEqual(floating.convertedFramesForTesting, stopped)
        floating.end()
        floating.wantsInlineFrames = true
        floating.setFloatingForTesting(true)
        floating.select(viewport: firstViewport, name: "Late", isScreenShare: false)
        try await feed(first)
        XCTAssertEqual(floating.convertedFramesForTesting, stopped)
        XCTAssertFalse(floating.hasPreparedFrameForTesting)
    }

    func testSignalingBootstrapsExperimentalBackgroundReceiveBeforeAnyRendererExists() async throws {
        try XCTSkipUnless(AVPictureInPictureController.isPictureInPictureSupported())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let source = UIView(frame: window.bounds)
        var state = UIApplication.State.active, starts = 0
        let floating = GuestVideoPictureInPicture(sourceView: source, floatingEnvironment: .init(
            applicationState: { state }, supported: { true }, possible: { _ in true },
            start: { _ in starts += 1 }, stop: { _ in }, allowsFirstBackgroundStart: { true }))
        defer { floating.end(); window.isHidden = true }
        floating.select(viewport: nil, name: "", isScreenShare: false)
        XCTAssertNil(floating.lifecycleForTesting.controllerForTesting)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(source)
        window.makeKeyAndVisible()
        floating.select(viewport: nil, name: "", isScreenShare: false)
        let controller = try XCTUnwrap(floating.lifecycleForTesting.controllerForTesting)
        XCTAssertFalse(controller.canStartPictureInPictureAutomaticallyFromInline)
        floating.select(viewport: nil, name: "", isScreenShare: false)
        XCTAssertTrue(floating.lifecycleForTesting.controllerForTesting === controller)
        XCTAssertFalse(floating.lifecycleForTesting.needsRecoveryFrames)
        XCTAssertEqual(starts, 0)
        let demand = MeetingVideoDemand(observeLifecycle: false)
        demand.setForeground(false, graceNanoseconds: 1)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(demand.wantsVideo)
        floating.onRecoveryDemandChanged = { demand.setRecovering($0) }
        state = .background; floating.backgrounded()
        floating.selectSignaledSource(.init(participant: "presenter", isShare: true))
        XCTAssertTrue(demand.wantsVideo, "Signaling must request SDK video before a renderer can be created")
        XCTAssertEqual(starts, 0)
        let renderer = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        floating.select(viewport: makeViewport(renderer), name: "Presenter", isScreenShare: true)
        renderer.renderFrame(staticFrame(luma: 128))
        let deadline = Date().addingTimeInterval(2)
        while starts == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(floating.hasPreparedFrameForTesting)
    }

    func testLateAnchorCannotPrepareFirstBackgroundPiPWithoutForegroundOptIn() throws {
        try XCTSkipUnless(AVPictureInPictureController.isPictureInPictureSupported())
        for enabled in [false, true] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            let source = UIView(frame: window.bounds)
            var state = UIApplication.State.active
            let floating = GuestVideoPictureInPicture(sourceView: source, floatingEnvironment: .init(
                applicationState: { state }, supported: { true }, possible: { _ in true },
                start: { _ in XCTFail("A late background anchor must not start PiP") }, stop: { _ in },
                allowsFirstBackgroundStart: { enabled }))
            if enabled { state = .background; floating.backgrounded() }
            window.rootViewController = UIViewController()
            window.rootViewController?.view.addSubview(source)
            window.makeKeyAndVisible()
            floating.select(viewport: nil, name: "", isScreenShare: false)
            XCTAssertNil(floating.lifecycleForTesting.controllerForTesting)
            floating.selectSignaledSource(.init(participant: "presenter", isShare: true))
            XCTAssertFalse(floating.lifecycleForTesting.needsRecoveryFrames)
            floating.end(); window.isHidden = true
        }
    }

    func testForegroundReturnPreparesAnExperimentalAnchorAttachedAfterBackgrounding() throws {
        try XCTSkipUnless(AVPictureInPictureController.isPictureInPictureSupported())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let source = UIView(frame: window.bounds)
        var state = UIApplication.State.active
        let floating = GuestVideoPictureInPicture(sourceView: source, floatingEnvironment: .init(
            applicationState: { state }, supported: { true }, possible: { _ in true },
            start: { _ in XCTFail("Preparing an empty anchor must not explicitly start PiP") }, stop: { _ in },
            allowsFirstBackgroundStart: { true }))
        defer { floating.end(); window.isHidden = true }
        state = .background; floating.backgrounded()
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(source); window.makeKeyAndVisible()
        floating.select(viewport: nil, name: "", isScreenShare: false)
        XCTAssertNil(floating.lifecycleForTesting.controllerForTesting)
        state = .active; floating.foregrounded()
        let controller = try XCTUnwrap(floating.lifecycleForTesting.controllerForTesting)
        XCTAssertFalse(controller.canStartPictureInPictureAutomaticallyFromInline)
        XCTAssertFalse(floating.lifecycleForTesting.needsRecoveryFrames)
    }

    func testExperimentalTimeoutIsNotRearmedByDuplicateMetadataOrLateFrames() async throws {
        try XCTSkipUnless(AVPictureInPictureController.isPictureInPictureSupported())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        let source = try XCTUnwrap(window.rootViewController?.view)
        var state = UIApplication.State.active, starts = 0
        let floating = GuestVideoPictureInPicture(sourceView: source, floatingEnvironment: .init(
            applicationState: { state }, supported: { true }, possible: { _ in true },
            start: { _ in starts += 1 }, stop: { _ in }, recoveryTimeoutNanoseconds: 10_000_000,
            allowsFirstBackgroundStart: { true }))
        defer { floating.end(); window.isHidden = true }
        state = .background; floating.backgrounded()
        let target = GuestStreamViews.PinTarget(participant: "presenter", isShare: true)
        floating.selectSignaledSource(target)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(floating.lifecycleForTesting.needsRecoveryFrames)
        floating.selectSignaledSource(target)
        XCTAssertFalse(floating.lifecycleForTesting.needsRecoveryFrames)
        let renderer = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        floating.select(viewport: makeViewport(renderer), name: "Late", isScreenShare: true)
        renderer.renderFrame(staticFrame(luma: 128))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(floating.convertedFramesForTesting, 0)
    }

    func testDirectPresenterReplacementShowsWaitingAndRejectsOldPixelsInBackground() async throws {
        let floating = GuestVideoPictureInPicture(sourceView: UIView())
        defer { floating.end() }
        let first = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        let second = RTCEAGLVideoView(frame: first.frame)
        floating.select(viewport: makeViewport(first), name: "A", isScreenShare: true)
        try await feed(first)
        floating.setFloatingForTesting(true); floating.backgrounded()
        floating.select(viewport: makeViewport(second), name: "B", isScreenShare: true)
        XCTAssertTrue(floating.lifecycleForTesting.waitingForVideoForTesting)
        XCTAssertFalse(floating.hasPreparedFrameForTesting)
        let count = floating.convertedFramesForTesting
        try await feed(first)
        XCTAssertEqual(floating.convertedFramesForTesting, count)
        XCTAssertTrue(floating.lifecycleForTesting.waitingForVideoForTesting)
        try await feed(second)
        XCTAssertGreaterThan(floating.convertedFramesForTesting, count)
        XCTAssertFalse(floating.lifecycleForTesting.waitingForVideoForTesting)
    }

    func testSamePresenterNewRendererRearmsExpiredRecoveryButRepeatedRendererDoesNot() async throws {
        try XCTSkipUnless(AVPictureInPictureController.isPictureInPictureSupported())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        let source = try XCTUnwrap(window.rootViewController?.view)
        var state = UIApplication.State.active, possible = true
        let floating = GuestVideoPictureInPicture(sourceView: source, floatingEnvironment: .init(
            applicationState: { state }, supported: { true }, possible: { _ in possible },
            start: { _ in }, stop: { _ in }, recoveryTimeoutNanoseconds: 40_000_000))
        defer { floating.end(); window.isHidden = true }
        let target = GuestStreamViews.PinTarget(participant: "presenter", isShare: true)
        let first = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        let original = makeViewport(first)
        floating.selectSignaledSource(target)
        floating.select(viewport: original, name: "Presenter", isScreenShare: true)
        try await feed(first)
        floating.start()
        let lifecycle = floating.lifecycleForTesting
        let controller = try XCTUnwrap(lifecycle.controllerForTesting)
        lifecycle.pictureInPictureControllerWillStartPictureInPicture(controller)
        lifecycle.pictureInPictureControllerDidStartPictureInPicture(controller)
        state = .background; floating.backgrounded()
        floating.setSuspended(true)
        lifecycle.pictureInPictureControllerDidStopPictureInPicture(controller)
        possible = false; floating.setSuspended(false)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(lifecycle.needsRecoveryFrames)
        floating.selectSignaledSource(target)
        floating.select(viewport: original, name: "Renamed presenter", isScreenShare: true)
        XCTAssertFalse(lifecycle.needsRecoveryFrames, "Repeated metadata or renderer callbacks cannot replenish the budget")
        let replacement = RTCEAGLVideoView(frame: first.frame)
        floating.select(viewport: makeViewport(replacement), name: "Presenter", isScreenShare: true)
        XCTAssertTrue(lifecycle.needsRecoveryFrames, "A distinct renderer is a genuine media-change event")
        XCTAssertTrue(lifecycle.controllerForTesting === controller)
        // Losing all sources during an interruption must not erase previously
        // active PiP recovery intent when the coordinator resets its roster.
        floating.setSuspended(true)
        floating.selectSignaledSource(nil)
        floating.setSuspended(false)
        XCTAssertTrue(lifecycle.needsRecoveryFrames)
    }

    private func makeViewport(_ renderer: UIView) -> StreamViewport {
        StreamViewport(video: renderer, state: StreamViewportState(), zoomable: false,
            name: "Remote", showInfo: false, microphoneOn: false, pinned: false, watermark: nil)
    }
    private func feed(_ renderer: RTCEAGLVideoView) async throws {
        let buffer = RTCMutableI420Buffer(width: 4, height: 2, strideY: 4, strideU: 2, strideV: 2)
        for index in 0..<8 { buffer.mutableDataY[index] = 96 }
        for index in 0..<2 { buffer.mutableDataU[index] = 128; buffer.mutableDataV[index] = 128 }
        let frame = RTCVideoFrame(buffer: buffer, rotation: RTCVideoRotation(rawValue: 0)!, timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
        for _ in 0..<3 {
            renderer.renderFrame(frame)
            try await Task.sleep(for: .milliseconds(80))
        }
    }
}
