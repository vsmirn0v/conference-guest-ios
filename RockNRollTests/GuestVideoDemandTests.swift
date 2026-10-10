import UIKit
import WebRTC
import XCTest
@testable import RockNRoll

@MainActor
final class GuestVideoDemandTests: XCTestCase {
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
