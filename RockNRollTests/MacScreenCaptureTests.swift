import UIKit
import CoreMedia
import XCTest
@testable import RockNRoll

@MainActor
final class MacScreenCaptureTests: XCTestCase {
    private final class Configuration: NSObject {
        @objc var width: UInt = 1280
        @objc var height: UInt = 720
        @objc var minimumFrameInterval = CMTime.zero
        @objc var queueDepth = 0
    }
    private final class ResizableStream: NSObject {
        var requests = [CGSize]()
        var completions = [(NSError?) -> Void]()
        @objc func updateConfiguration(_ configuration: Configuration, completionHandler: @escaping (NSError?) -> Void) {
            requests.append(CGSize(width: Double(configuration.width), height: Double(configuration.height)))
            completions.append(completionHandler)
        }
    }
    func testCaptureTimingUsesBoundedDepthAndDoesNotAlterResolution() {
        let config = Configuration()
        MacScreenCaptureBridge.configureTiming(config, fps: 30, queueDepth: 3)
        XCTAssertEqual(config.minimumFrameInterval, CMTime(value: 1, timescale: 30))
        XCTAssertEqual(config.queueDepth, 3)
        XCTAssertEqual(config.width, 1280); XCTAssertEqual(config.height, 720)
        MacScreenCaptureBridge.configureTiming(config, fps: 0, queueDepth: 0)
        XCTAssertEqual(config.minimumFrameInterval, CMTime(value: 1, timescale: 1))
        XCTAssertEqual(config.queueDepth, 3)
    }
    func testWindowDimensionsPreserveAspectBoundPixelsAndDoNotUpscale() {
        XCTAssertEqual(MacScreenCaptureBridge.outputSize(for: CGSize(width: 640, height: 480)), CGSize(width: 640, height: 480))
        XCTAssertEqual(MacScreenCaptureBridge.outputSize(for: CGSize(width: 3840, height: 2160)), CGSize(width: 3840, height: 2160))
        XCTAssertEqual(MacScreenCaptureBridge.outputSize(for: CGSize(width: 2560, height: 1600)), CGSize(width: 2560, height: 1600))
        XCTAssertEqual(MacScreenCaptureBridge.outputSize(for: CGSize(width: 1600, height: 2400)), CGSize(width: 1600, height: 2400))
        XCTAssertEqual(MacScreenCaptureBridge.outputSize(for: CGSize(width: 1201, height: 701)), CGSize(width: 1200, height: 700))
        for value in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 100), CGSize(width: 10, height: CGFloat.nan)] {
            XCTAssertEqual(MacScreenCaptureBridge.outputSize(for: value), .zero)
        }
    }
    func testScreenDetailBudgetHandlesLargeSquarePortraitAndExtremeSources() {
        for input in [CGSize(width: 5120, height: 2880), CGSize(width: 2880, height: 5120),
                      CGSize(width: 4000, height: 4000), CGSize(width: 10000, height: 500),
                      CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)] {
            let output = MacScreenCaptureBridge.outputSize(for: input)
            XCTAssertLessThanOrEqual(output.width, 3840); XCTAssertLessThanOrEqual(output.height, 3840)
            XCTAssertLessThanOrEqual(output.width * output.height, 3840 * 2160)
            XCTAssertEqual(output.width.truncatingRemainder(dividingBy: 2), 0)
            XCTAssertEqual(output.height.truncatingRemainder(dividingBy: 2), 0)
            XCTAssertEqual(output.width / output.height, input.width / input.height, accuracy: 0.1)
        }
    }
    func testWindowResizeCoalescesSerializesAndKeepsLatestAspect() async throws {
        let bridge = MacScreenCaptureBridge(), stream = ResizableStream(), configuration = Configuration()
        bridge.prepareWindowResize(forStream: stream, configuration: configuration)
        // Surface points * backing scale / content scale = native source pixels.
        for width in [300.0, 400.0, 450.0] {
            bridge.observeWindowContentRect(CGRect(x: 0, y: 0, width: width, height: 300), scaleFactor: 2, contentScale: 1)
        }
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(stream.requests, [CGSize(width: 900, height: 600)])
        bridge.observeWindowContentRect(CGRect(x: 0, y: 0, width: 300, height: 450), scaleFactor: 1, contentScale: 0.5)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(stream.requests.count, 1, "No overlapping configuration updates")
        stream.completions.removeFirst()(nil)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(stream.requests.last, CGSize(width: 600, height: 900))
        stream.completions.removeFirst()(nil)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(stream.requests.count, 2, "Stable frames do not reallocate surfaces")
        bridge.invalidateWindowResize()
    }
    func testNativeDetailIsExplicitAndRetainedWhenWindowResizes() async throws {
        let bridge = MacScreenCaptureBridge(), stream = ResizableStream()
        let pixels = CGSize(width: 3840, height: 2160)
        XCTAssertEqual(bridge.captureSize(for: pixels), CGSize(width: 1920, height: 1080),
                       "Unqualified transports retain their previous capture budget")
        bridge.preserveDetail = true
        XCTAssertEqual(bridge.captureSize(for: pixels), pixels)
        bridge.prepareWindowResize(forStream: stream, configuration: Configuration())
        bridge.observeWindowContentRect(CGRect(x: 0, y: 0, width: 1920, height: 1080), scaleFactor: 2, contentScale: 1)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(stream.requests, [pixels])
        stream.completions.removeFirst()(nil)
        bridge.invalidateWindowResize()
    }
    func testWindowResizeRejectsInvalidGeometryAndRetiredCompletion() async throws {
        let bridge = MacScreenCaptureBridge(), first = ResizableStream(), second = ResizableStream()
        bridge.prepareWindowResize(forStream: first, configuration: Configuration())
        bridge.observeWindowContentRect(.zero, scaleFactor: 2, contentScale: 1)
        bridge.observeWindowContentRect(CGRect(x: 0, y: 0, width: 600, height: 400), scaleFactor: 2, contentScale: 0)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(first.requests.isEmpty)
        bridge.observeWindowContentRect(CGRect(x: 0, y: 0, width: 600, height: 400), scaleFactor: 1, contentScale: 1)
        try await Task.sleep(nanoseconds: 450_000_000)
        bridge.prepareWindowResize(forStream: second, configuration: Configuration())
        first.completions.removeFirst()(nil)
        bridge.observeWindowContentRect(CGRect(x: 0, y: 0, width: 400, height: 600), scaleFactor: 1, contentScale: 1)
        bridge.invalidateWindowResize()
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(second.requests.isEmpty, "Stop rejects a queued resize from the old selection")
    }
    private final class Filter: NSObject {
        @objc var style = 1
        @objc var contentRect = CGRect(x: 0, y: 0, width: 640, height: 480)
        @objc var pointPixelScale: Float = 1
    }
    func testReentrantStopFromEffectOrSelectionCannotStartAnotherCapture() {
        for duringSelection in [false, true] {
            let bridge = MacScreenCaptureBridge()
            bridge.setValue(true, forKey: "picking")
            var stops = 0, selections = 0
            if duringSelection {
                bridge.onSelection = { _ in selections += 1; bridge.stop { _ in stops += 1 } }
            } else { bridge.onEffect = { _ in bridge.stop { _ in stops += 1 } } }
            bridge.perform(NSSelectorFromString("selectFilter:"), with: Filter())
            XCTAssertEqual(stops, 1)
            XCTAssertEqual(selections, duringSelection ? 1 : 0)
            XCTAssertNil(bridge.value(forKey: "stream"), "A callback may retire capture synchronously")
            bridge.onSelection = nil; bridge.onEffect = nil
        }
    }
    private final class RetiringStream: NSObject {
        var starts = 0, stops = 0, removals = 0
        var startCompletion: ((NSError?) -> Void)?
        var stopCompletion: ((NSError?) -> Void)?
        @objc(startCaptureWithCompletionHandler:) func start(_ completion: @escaping (NSError?) -> Void) {
            starts += 1; startCompletion = completion
        }
        @objc(stopCaptureWithCompletionHandler:) func stop(_ completion: @escaping (NSError?) -> Void) {
            stops += 1; stopCompletion = completion
        }
        @objc(removeStreamOutput:type:error:) func remove(_ output: NSObject, type: Int, error: NSErrorPointer) -> Bool { removals += 1; return true }
    }
    private func settle() async { for _ in 0..<10 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(20)) }
    func testStopDuringReplacementDrainsOldStreamAndRejectsLateEffects() async {
        let bridge = MacScreenCaptureBridge(), old = RetiringStream()
        bridge.setValue(old, forKey: "stream"); bridge.setValue(true, forKey: "picking")
        var effects = 0, completions = 0
        bridge.onEffect = { _ in effects += 1 }
        bridge.perform(NSSelectorFromString("selectFilter:"), with: NSObject())
        XCTAssertEqual(old.stops, 1)
        bridge.stop { _ in completions += 1 }; bridge.stop { _ in completions += 1 }
        XCTAssertEqual(completions, 0, "Stop must include the stream detached for replacement")
        old.stopCompletion?(nil); await settle()
        XCTAssertEqual(completions, 2); XCTAssertEqual(old.removals, 1); XCTAssertEqual(old.stops, 1)
        XCTAssertEqual(effects, 0, "Retired replacement must not reset the new session's overlay")
    }
    func testRetiredFailureCannotEndAReplacementStartedByStopCompletion() async {
        let bridge = MacScreenCaptureBridge(), old = RetiringStream()
        bridge.setValue(old, forKey: "stream")
        var ends = 0
        bridge.onEnd = { _ in ends += 1 }
        bridge.stop { _ in
            // A caller may start the next session from its completed Stop callback.
            let generation = (bridge.value(forKey: "generation") as? NSNumber)?.uintValue ?? 0
            bridge.setValue(generation + 1, forKey: "generation")
        }
        bridge.perform(NSSelectorFromString("fail:"), with: NSError(domain: "retired capture", code: 1))
        old.stopCompletion?(nil); await settle()
        XCTAssertEqual(ends, 0)
    }
    func testStopWaitsForAnInFlightStartAndCoalescesRetirement() async {
        let lifecycle = ScreenCaptureLifecycle(), stream = RetiringStream(), output = NSObject()
        var starts = 0, stopped = 0, drained = false
        lifecycle.startStream(stream, output: output) { _ in starts += 1 }
        lifecycle.retireStream(stream, output: output) { _ in stopped += 1 }
        lifecycle.retireStream(stream, output: output) { _ in stopped += 1 }
        lifecycle.drain { drained = true }
        XCTAssertEqual(stream.stops, 0); XCTAssertFalse(drained)
        stream.startCompletion?(nil); await settle()
        XCTAssertEqual(starts, 1); XCTAssertEqual(stream.stops, 1); XCTAssertFalse(drained)
        stream.stopCompletion?(NSError(domain: "test", code: 1)); await settle()
        XCTAssertEqual(stopped, 2); XCTAssertTrue(drained); XCTAssertEqual(stream.removals, 1)
    }
    private final class Picker: NSObject {
        @objc(isActive) var active = false
        var additions = 0, removals = 0, presentations = 0
        var onRemove: (() -> Void)?
        @objc func setActive(_ value: Bool) { active = value }
        @objc func addObserver(_ observer: NSObject) { additions += 1 }
        @objc func removeObserver(_ observer: NSObject) { removals += 1; if removals == 1 { onRemove?() } }
        @objc func present() { presentations += 1 }
        @objc func presentPicker(for stream: NSObject) { presentations += 1 }
    }
    func testStopReenteredDuringPickerRemovalRemovesObserverOnce() throws {
        let bridge = MacScreenCaptureBridge(), picker = Picker()
        let coordinator = ScreenCapturePickerCoordinator(picker: picker)
        let session = ScreenCapturePickerSession(coordinator: coordinator)
        try session.present()
        bridge.setValue(session, forKey: "pickerSession"); bridge.setValue(true, forKey: "picking")
        var completions = 0
        picker.onRemove = { bridge.stop { _ in completions += 1 } }
        bridge.stop { _ in completions += 1 }
        XCTAssertEqual(picker.removals, 1); XCTAssertEqual(completions, 2); XCTAssertFalse(picker.active)
    }
    func testPrivateSelectionAndCancelLeaveTheLiveShareOwnedAndUntouched() async throws {
        let picker = Picker(), liveStream = NSObject(), privateStream = NSObject(), filter = NSObject()
        let coordinator = ScreenCapturePickerCoordinator(picker: picker)
        let live = ScreenCapturePickerSession(coordinator: coordinator), preview = ScreenCapturePickerSession(coordinator: coordinator)
        var liveSelections = 0, privateSelections = 0, cancellations = 0
        live.onFilter = { _ in liveSelections += 1; live.stream = liveStream }
        preview.onFilter = { _ in privateSelections += 1; preview.stream = privateStream }
        preview.onCancel = { cancellations += 1; preview.invalidate() }
        try live.present(); coordinator.contentSharingPicker(picker, didUpdateWithFilter: filter, forStream: nil); await settle()
        try preview.present(); coordinator.contentSharingPicker(picker, didCancelForStream: nil); await settle()
        XCTAssertEqual(cancellations, 1); XCTAssertEqual(liveSelections, 1); XCTAssertEqual(privateSelections, 0)
        XCTAssertTrue(picker.active); XCTAssertEqual(picker.removals, 0); XCTAssertTrue(live.stream === liveStream)
        try preview.present(); coordinator.contentSharingPicker(picker, didUpdateWithFilter: filter, forStream: nil); await settle()
        XCTAssertEqual(liveSelections, 1); XCTAssertEqual(privateSelections, 1)
        // Control Center targets the associated stream, never both captures.
        coordinator.contentSharingPicker(picker, didUpdateWithFilter: filter, forStream: liveStream); await settle()
        XCTAssertEqual(liveSelections, 2); XCTAssertEqual(privateSelections, 1)
        preview.invalidate(); XCTAssertTrue(picker.active)
        live.invalidate(); XCTAssertFalse(picker.active); XCTAssertEqual(picker.removals, 1)
    }
    func testPickerCallbackDoesNotSynchronouslyWaitForMainThread() async throws {
        let picker = Picker(), coordinator = ScreenCapturePickerCoordinator(picker: picker)
        let session = ScreenCapturePickerSession(coordinator: coordinator)
        var selections = 0; session.onFilter = { _ in selections += 1 }
        try session.present()
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            coordinator.contentSharingPicker(picker, didUpdateWithFilter: NSObject(), forStream: nil)
            completed.signal()
        }
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success,
                       "A framework callback must return even while main is occupied")
        XCTAssertEqual(selections, 0); await settle(); XCTAssertEqual(selections, 1)
        session.invalidate()
    }
    func testRetiredPickerSelectionIsIgnoredAndConcurrentChooserIsRejected() async throws {
        let picker = Picker(), coordinator = ScreenCapturePickerCoordinator(picker: picker)
        let first = ScreenCapturePickerSession(coordinator: coordinator), next = ScreenCapturePickerSession(coordinator: coordinator)
        var selections = 0
        first.onFilter = { _ in selections += 1 }
        try first.present(); XCTAssertThrowsError(try next.present())
        coordinator.contentSharingPicker(picker, didUpdateWithFilter: NSObject(), forStream: nil)
        first.invalidate()
        next.onFilter = { _ in XCTFail("Retired selection must not reach the next chooser") }
        try next.present(); await settle()
        XCTAssertEqual(selections, 0); XCTAssertTrue(picker.active)
        next.invalidate(); XCTAssertFalse(picker.active)
    }

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
