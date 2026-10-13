import UIKit
import JazzSDK
import CoreMedia
import WebRTC
import XCTest
@testable import RockNRoll

@MainActor
final class GuestVideoDemandTests: XCTestCase {
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
        let first = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        let second = RTCEAGLVideoView(frame: first.frame)
        let floating = GuestVideoPictureInPicture(sourceView: UIView())
        defer { floating.end() }
        let firstViewport = makeViewport(first), secondViewport = makeViewport(second)
        floating.select(viewport: firstViewport, name: "First", isScreenShare: false)
        try await feed(first)
        XCTAssertTrue(floating.hasSourceForTesting)
        floating.setFloatingForTesting(true)
        floating.select(viewport: secondViewport, name: "Second", isScreenShare: false)
        XCTAssertFalse(floating.hasPreparedFrameForTesting)
        XCTAssertTrue(floating.hasSourceForTesting, "Replacing a renderer must not revoke active video-call PiP")
        let before = floating.convertedFramesForTesting
        try await feed(first)
        XCTAssertEqual(floating.convertedFramesForTesting, before)
        try await feed(second)
        XCTAssertGreaterThan(floating.convertedFramesForTesting, before)
        floating.clear()
        XCTAssertFalse(floating.hasSourceForTesting, "Actual stream termination still clears the anchor")
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
