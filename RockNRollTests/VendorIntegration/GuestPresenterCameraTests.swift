import AVFoundation
import UIKit
import XCTest
import WebRTC
@testable import RockNRoll

@MainActor
final class GuestPresenterCameraTests: XCTestCase {
    func testReceiverRequiresExactUnambiguousLiveTrackInCurrentAttempt() {
        let factory = RTCPeerConnectionFactory()
        let track = factory.videoTrack(with: factory.videoSource(), trackId: "camera-sid")
        let suffix = factory.videoTrack(with: factory.videoSource(), trackId: "prefix-camera-sid")
        let scope = GuestPeerRegistry.Scope(generation: UUID(), attempt: UUID())
        func candidate(_ track: RTCVideoTrack, scope value: GuestPeerRegistry.Scope? = nil,
                       closed: Bool = false, stopped: Bool = false,
                       direction: RTCRtpTransceiverDirection? = .recvOnly) -> GuestPresenterCameraReceiver.Candidate {
            .init(scope: value ?? scope, closed: closed, stopped: stopped, direction: direction, track: track)
        }
        func resolve(_ candidates: [GuestPresenterCameraReceiver.Candidate]) -> RTCVideoTrack? {
            GuestPresenterCameraReceiver.resolve(cameraSID: "camera-sid", scope: scope, candidates: candidates)
        }
        XCTAssertTrue(resolve([candidate(track), candidate(suffix)]) === track)
        XCTAssertNil(resolve([candidate(suffix)]), "Track names and SID suffixes never qualify")
        XCTAssertNil(resolve([candidate(track), candidate(track)]), "Two receivers with the exact SID are ambiguous")
        XCTAssertNil(resolve([candidate(track, stopped: true)]))
        XCTAssertNil(resolve([candidate(track, closed: true)]))
        XCTAssertNil(resolve([candidate(track, direction: .inactive)]))
        XCTAssertNil(resolve([candidate(track, direction: .sendOnly)]))
        XCTAssertNil(resolve([candidate(track, direction: nil)]))
        XCTAssertTrue(resolve([candidate(track, direction: .sendRecv)]) === track)
        XCTAssertNil(resolve([candidate(track, scope: .init(generation: UUID(), attempt: scope.attempt))]))
        XCTAssertNil(resolve([candidate(track, scope: .init(generation: scope.generation, attempt: UUID()))]))
        XCTAssertNil(resolve([.init(scope: nil, closed: false, stopped: false, direction: .recvOnly, track: track)]))
        XCTAssertTrue(track.isEnabled)
    }

    func testReceiverReplacementRevocationAndLateAnswerCannotRestoreOldSource() {
        let factory = RTCPeerConnectionFactory(), receiver = GuestPresenterCameraReceiver()
        let scope = GuestPeerRegistry.Scope(generation: UUID(), attempt: UUID())
        let track = factory.videoTrack(with: factory.videoSource(), trackId: "camera-sid")
        let candidates: [GuestPresenterCameraReceiver.Candidate] = [
            .init(scope: scope, closed: false, stopped: false, direction: .recvOnly, track: track)]
        let first = GuestPresenterCameraLease(generation: scope.generation, socketID: UUID(),
            participantID: "presenter", cameraSID: track.trackId, token: UUID())
        let next = GuestPresenterCameraLease(generation: scope.generation, socketID: first.socketID,
            participantID: "presenter", cameraSID: track.trackId, token: UUID())
        var transitions: [UUID?] = []
        receiver.onChange = { transitions.append($0?.leaseToken) }
        receiver.begin(scope)
        receiver.setLease(first, candidates: candidates)
        receiver.setLease(first, candidates: [])
        XCTAssertEqual(receiver.source?.leaseToken, first.token,
            "Repeated UI/audio demand must not re-enumerate receiver metadata")
        receiver.refresh(lease: first, candidates: [])
        XCTAssertNil(receiver.source, "A qualified answer explicitly revalidates receiver metadata")
        receiver.refresh(lease: first, candidates: candidates)
        transitions.removeAll()
        receiver.setLease(next, candidates: candidates)
        XCTAssertEqual(transitions, [nil, next.token])
        receiver.refresh(lease: first, candidates: candidates)
        XCTAssertEqual(receiver.source?.leaseToken, next.token)
        receiver.setLease(nil, candidates: candidates)
        receiver.refresh(lease: next, candidates: candidates)
        XCTAssertNil(receiver.source, "An answer queued before privacy withdrawal must not reacquire the receiver")
        receiver.begin(.init(generation: UUID(), attempt: UUID()))
        receiver.setLease(first, candidates: candidates)
        XCTAssertNil(receiver.source)
        receiver.end()
        receiver.setLease(next, candidates: candidates)
        XCTAssertNil(receiver.source, "A retired engine cannot acquire media")
        XCTAssertTrue(track.isEnabled)
    }

    func testDirectTapReceivesRealRTCFramesAndRejectsCallbacksAfterRetirementWithoutChangingEnabled() async throws {
        let factory = RTCPeerConnectionFactory(), source = factory.videoSource()
        let track = factory.videoTrack(with: source, trackId: "direct-camera")
        let binding = GuestPresenterCameraReceiverSource(leaseToken: UUID(), participant: "presenter", track: track)
        let received = expectation(description: "Public RTCVideoRenderer receives the source frame")
        received.assertForOverFulfill = false
        let recorder = DirectFrameRecorder()
        let tap = GuestVideoFrameTap(source: binding) { recorder.accept($0); received.fulfill() }
        let capturer = RTCVideoCapturer(delegate: source)
        let frame = RTCVideoFrame(buffer: RTCMutableI420Buffer(width: 16, height: 16), rotation: ._0, timeStampNs: 1)
        source.capturer(capturer, didCapture: frame)
        await fulfillment(of: [received], timeout: 3)
        XCTAssertGreaterThan(recorder.count, 0)
        XCTAssertTrue(tap.matches(binding)); XCTAssertTrue(track.isEnabled)
        tap.invalidate()
        let retiredCount = recorder.count
        tap.receiveDirectFrameForTesting(frame)
        source.capturer(capturer, didCapture: frame)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(recorder.count, retiredCount)
        XCTAssertTrue(track.isEnabled)
        track.isEnabled = false
        let disabled = GuestVideoFrameTap(source: binding) { _ in }
        XCTAssertFalse(track.isEnabled)
        disabled.invalidate(); XCTAssertFalse(track.isEnabled)
    }
    func testUnmountedLiveCameraAndReplacementFeedReachPresenter() async throws {
        let first = CameraCapturePreview(session: AVCaptureSession(), device: nil)
        let second = CameraCapturePreview(session: AVCaptureSession(), device: nil)
        var current: CameraCapturePreview? = first
        var received: [(CVPixelBuffer, Int)] = []
        let camera = GuestPresenterCamera(streams: GuestStreamViews(), cameraPreview: { current }) {
            received.append(($0, $1))
        }
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        XCTAssertTrue(first.frames.hasSinks, "No SDK tile needs to be mounted")
        first.frames.render(pixels, rotation: 90)
        try await wait { received.count == 1 }
        XCTAssertTrue(received[0].0 === pixels); XCTAssertEqual(received[0].1, 90)

        current = second
        NotificationCenter.default.post(name: GuestCaptureDeviceObserver.changed, object: nil)
        XCTAssertFalse(first.frames.hasSinks); XCTAssertTrue(second.frames.hasSinks)
        second.frames.render(pixels, rotation: 0)
        try await wait { received.count == 2 }
        XCTAssertEqual(received[1].1, 0)
        await camera.stop()
        XCTAssertFalse(second.frames.hasSinks)
        first.frames.render(pixels, rotation: 0); second.frames.render(pixels, rotation: 0)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(received.count, 2, "Retired camera cannot deliver into another Presenter session")
    }

    private func wait(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !ready(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(ready())
    }
}

private final class DirectFrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames }
    func accept(_ frame: RTCVideoFrame) { lock.lock(); frames += 1; lock.unlock() }
}
