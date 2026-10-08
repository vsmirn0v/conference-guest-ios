import UIKit
import CoreMedia
import XCTest
@testable import RockNRoll

@MainActor
final class MacScreenCaptureTests: XCTestCase {
    private final class Bridge: MacScreenCaptureBridge {
        var starts = 0, stops = 0
        var completion: ((Error?) -> Void)?
        override func present() throws { starts += 1 }
        override func stop(completion: @escaping (Error?) -> Void) {
            stops += 1; self.completion = completion
        }
    }
    func testStopCoalescesAndRejectsLateFramesAndErrors() async throws {
        let bridge = Bridge()
        var frames = 0, ends = 0
        let capture = MacGuestScreenCapture(preview: LocalSharePreview(), onFrame: { _ in frames += 1 },
            onEnd: { _ in ends += 1 }, onError: { _ in XCTFail("Retired capture must not report errors") }, bridge: bridge)
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: try XCTUnwrap(pixels),
            formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: try XCTUnwrap(pixels),
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        let frame = try XCTUnwrap(sample)
        capture.start(); bridge.onFrame?(frame)
        XCTAssertEqual(frames, 1)
        let first = Task { await capture.stop() }
        let second = Task { await capture.stop() }
        for _ in 0..<100 {
            if bridge.completion != nil { break }; await Task.yield()
        }
        XCTAssertEqual(bridge.stops, 1)
        capture.start(); XCTAssertEqual(bridge.starts, 1, "Cannot restart while retiring a capture")
        bridge.onFrame?(frame)
        bridge.onEnd?(NSError(domain: "Late capture", code: 1))
        let complete = try XCTUnwrap(bridge.completion); bridge.completion = nil; complete(nil)
        await first.value; await second.value; await Task.yield()
        XCTAssertEqual(frames, 1); XCTAssertEqual(ends, 0)
        capture.start(); XCTAssertEqual(bridge.starts, 2)
        bridge.onFrame?(frame); XCTAssertEqual(frames, 2)
        let final = Task { await capture.stop() }
        for _ in 0..<100 {
            if bridge.completion != nil { break }; await Task.yield()
        }
        bridge.completion?(nil); await final.value
    }
    func testRoutingKeepsPhoneBroadcastAndCurrentNativeCaptureAndFailsClosed() {
        XCTAssertEqual(GuestCaptureRoute.select(isMac: false, native: false, compatibility: false), .broadcastExtension)
        XCTAssertEqual(GuestCaptureRoute.select(isMac: false, native: true, compatibility: false), .native)
        XCTAssertEqual(GuestCaptureRoute.select(isMac: true, native: true, compatibility: true), .native)
        XCTAssertEqual(GuestCaptureRoute.select(isMac: true, native: false, compatibility: true), .macCompatibility)
        XCTAssertEqual(GuestCaptureRoute.select(isMac: true, native: false, compatibility: false), .unavailable)
        XCTAssertEqual(GuestCaptureRoute.select(isMac: true, native: true, compatibility: true, preferCompatibility: true), .macCompatibility)
        XCTAssertEqual(GuestCaptureRoute.select(isMac: true, native: true, compatibility: false, preferCompatibility: true), .unavailable)
    }
    func testPublicMacCaptureSelectorContractIsAvailableAndPhoneDoesNotLoadIt() {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            XCTAssertTrue(MacScreenCaptureBridge.isSupported())
            XCTAssertNotNil(NSProtocolFromString("SCStreamOutput"))
            XCTAssertNotNil(NSProtocolFromString("SCContentSharingPickerObserver"))
        } else { XCTAssertFalse(MacScreenCaptureBridge.isSupported()) }
    }
    func testRepeatedStopWithoutStartingCompletesAndDoesNotEndAnotherSession() async {
        let bridge = MacScreenCaptureBridge()
        var ends = 0
        bridge.onEnd = { _ in ends += 1 }
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in bridge.stop { _ in continuation.resume() } }
        }
        XCTAssertEqual(ends, 0)
    }
    func testPhoneRejectsMacPickerWithoutCallingScreenCaptureKit() throws {
        guard !ProcessInfo.processInfo.isiOSAppOnMac else { throw XCTSkip("Phone-only capability gate") }
        XCTAssertThrowsError(try MacScreenCaptureBridge().present())
    }
    func testLiveCompatibilityPickerCapturesChangingPixelsAndStopsCleanly() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_COMPAT_LIVE"] == "1" else {
            throw XCTSkip("Opt-in real Mac capture chooser qualification")
        }
        XCTAssertTrue(MacScreenCaptureBridge.isSupported())
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow })
        let host = try XCTUnwrap(window.rootViewController)
        let source = UIViewController()
        source.view.backgroundColor = .systemBlue
        let moving = UIView(frame: CGRect(x: 20, y: 100, width: 140, height: 140))
        moving.backgroundColor = .systemYellow; source.view.addSubview(moving)
        let label = UILabel(frame: CGRect(x: 20, y: 25, width: 600, height: 60))
        label.text = "MAC CAPTURE COMPATIBILITY TEST"; label.textColor = .white
        source.view.addSubview(label)
        source.modalPresentationStyle = .fullScreen
        host.present(source, animated: false)
        let title = window.windowScene?.title; window.windowScene?.title = "Mac capture compatibility test"
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { moving.frame.origin.x = moving.frame.minX > 250 ? 20 : moving.frame.minX + 20 }
        }
        defer { timer.invalidate(); window.windowScene?.title = title; host.dismiss(animated: false) }
        var frames = 0, timestamps = Set<Double>(), fingerprints = Set<UInt64>(), dimensions = CGSize.zero
        var endError: String?
        let capture = MacGuestScreenCapture(preview: LocalSharePreview(), onFrame: { sample in
            frames += 1; timestamps.insert(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            if let pixels = CMSampleBufferGetImageBuffer(sample) {
                dimensions = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
                CVPixelBufferLockBaseAddress(pixels, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(pixels) {
                    let stride = CVPixelBufferGetBytesPerRow(pixels)
                    var fingerprint: UInt64 = 0
                    for y in 0..<12 { for x in 0..<16 {
                        let offset = (y * CVPixelBufferGetHeight(pixels) / 12) * stride + (x * CVPixelBufferGetWidth(pixels) / 16) * 4
                        fingerprint = (fingerprint &* 31) &+ UInt64(base.advanced(by: offset).load(as: UInt32.self))
                    } }
                    fingerprints.insert(fingerprint)
                }
                CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            }
        }, onError: { endError = $0 })
        capture.start()
        for _ in 0..<1800 {
            if frames >= 30 || endError != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await capture.stop()
        let afterStop = frames
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(endError); XCTAssertGreaterThanOrEqual(frames, 30)
        XCTAssertGreaterThan(timestamps.count, 5); XCTAssertGreaterThan(dimensions.width, 0)
        XCTAssertGreaterThan(fingerprints.count, 1, "Capture must contain changing source pixels")
        XCTAssertEqual(frames, afterStop, "Retired capture must stop forwarding")
        print("MAC_COMPAT_CAPTURE frames=\(frames) pts=\(timestamps.count) variants=\(fingerprints.count) pixels=\(dimensions)")
        await capture.stop()
    }
}
