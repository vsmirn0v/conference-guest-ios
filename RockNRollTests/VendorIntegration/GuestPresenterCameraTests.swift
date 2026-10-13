import AVFoundation
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class GuestPresenterCameraTests: XCTestCase {
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
