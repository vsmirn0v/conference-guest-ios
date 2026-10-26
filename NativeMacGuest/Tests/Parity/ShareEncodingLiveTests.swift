import AppKit
import ConferenceCore
import CoreImage
import CoreText
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

/// Disposable synthetic content; physical camera capture requires its own opt-in.
@MainActor final class ShareEncodingLiveTests: XCTestCase {
    func testPhysicalCameraRemainsDecodedWithNativeSizeShare() async throws {
        guard ProcessInfo.processInfo.environment["NATIVE_DESKTOP_LIVE_PHYSICAL_CAMERA"] == "1" else {
            throw XCTSkip("Opt in to physical camera capture in a disposable guest meeting.")
        }
        executionTimeAllowance = 300
        let invitation = try await GuestBootstrap.createDisposable(origin: URL(string: "https://salutejazz.ru")!)
        let receiver = NativeGuestEngine(label: "Camera/share independent receiver")
        let adapter = NativeDesktopGuestEngine()
        let model = NativeDesktopMeetingModel(destination: try .verified(invitation.invitationURL, engine: .guest),
            name: "Camera/share sender", title: "Camera/share validation", engine: adapter)
        var probes: [(LKRTCVideoTrack, ShareEncodingFrameCounter)] = []
        do {
            try await receiver.join(invitation); try await model.connect()
            model.toggleCamera()
            try await wait("physical camera on") { model.snapshot.cameraOn && model.localCamera != nil }
            try await wait("remote camera") { receiver.incomingVideo.contains { $0.source == "CAMERA" } }
            let camera = try XCTUnwrap(receiver.incomingVideo.first { $0.source == "CAMERA" })
            let cameraCounter = ShareEncodingFrameCounter()
            camera.track.add(cameraCounter); probes.append((camera.track, cameraCounter))
            try await wait("initial physical camera decoded") { cameraCounter.snapshot.frames >= 8 }
            var pixels: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
            let image = try XCTUnwrap(pixels)
            let context = CIContext(options: [.cacheIntermediates: false])
            let content = try Self.readableShareFixture()
            context.render(content, to: image)
            print("CAMERA_SHARE_WORKLOAD kind=text-grid-moving-highlight source=3840x2160 targetFPS=30 maximumBitrate=18000000")
            var format: CMVideoFormatDescription?, sample: CMSampleBuffer?
            XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format), noErr)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
            let screen = try XCTUnwrap(sample)
            for cycle in 0..<3 {
                var selectedCapture: NativeDesktopShareCapture?
                try await adapter.startScreenShare(profile: .init(width: 3840, height: 2160, fps: 30, maximumBitrate: 18_000_000)) {
                    let capture = NativeDesktopShareCapture(source: $0, screenForTesting: screen)
                    selectedCapture = capture; return capture
                }
                let producer = Task.detached(priority: .userInitiated) { [capture = selectedCapture, sourceFormat = format!, initialTiming = timing] in
                    let highlight = CIImage(color: CIColor(red: 0.1, green: 0.45, blue: 0.95, alpha: 0.3))
                        .cropped(to: CGRect(x: 0, y: 0, width: 240, height: 100))
                    let clock = ContinuousClock(), began = ProcessInfo.processInfo.systemUptime
                    var nextFrame = clock.now, step = 0, produced = 0
                    while !Task.isCancelled {
                        autoreleasepool {
                        var next: CVPixelBuffer?
                        if CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &next) == kCVReturnSuccess, let next {
                            // Document pixels remain stable; pointer-sized motion
                            // exercises live delivery without full-frame entropy.
                            let moving = highlight.transformed(by: .init(translationX: CGFloat(64 + step * 13 % 3456),
                                y: CGFloat(80 + step * 7 % 1820)))
                            context.render(moving.composited(over: content), to: next)
                            var nextSample: CMSampleBuffer?
                            var nextTiming = initialTiming
                            nextTiming.presentationTimeStamp = CMTime(value: Int64(step), timescale: 30)
                            if CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: next,
                                formatDescription: sourceFormat, sampleTiming: &nextTiming, sampleBufferOut: &nextSample) == noErr,
                               let nextSample { capture?.updateSyntheticScreenForTesting(nextSample); produced += 1 }
                        }
                        }
                        step += 1
                        nextFrame = nextFrame.advanced(by: .nanoseconds(1_000_000_000 / 30))
                        if nextFrame < clock.now { nextFrame = clock.now }
                        try? await clock.sleep(until: nextFrame)
                    }
                    return (frames: produced, seconds: ProcessInfo.processInfo.systemUptime - began)
                }
                defer { producer.cancel() }
                try await wait("remote native-size share") { receiver.incomingVideo.contains { $0.source == "SCREEN_SHARE" } }
                let share = try XCTUnwrap(receiver.incomingVideo.first { $0.source == "SCREEN_SHARE" })
                let sharedCounter = ShareEncodingFrameCounter()
                share.track.add(sharedCounter); probes.append((share.track, sharedCounter))
                try await wait("native-size share decodes") { sharedCounter.snapshot.frames >= 8 }
                let sent = await cameraFrames(adapter), decoded = cameraCounter.snapshot.frames
                try await wait("camera RTP after 4K share negotiation") { await self.cameraFrames(adapter) > sent + 15 }
                try await wait("remote physical camera keeps decoding") { cameraCounter.snapshot.frames > decoded + 15 }
                try await Task.sleep(for: .seconds(10))
                let lateDecoded = cameraCounter.snapshot.frames
                try await wait("camera continues under sustained content load") { cameraCounter.snapshot.frames > lateDecoded + 15 }
                try await adapter.stopScreenShare()
                producer.cancel(); let workload = await producer.value
                print("CAMERA_SHARE_LIVE cycle=\(cycle) cameraDecoded=\(cameraCounter.snapshot.frames - decoded) share=\(sharedCounter.snapshot.width)x\(sharedCounter.snapshot.height) shareDecoded=\(sharedCounter.snapshot.frames) workload=text-grid-moving-highlight sourceFrames=\(workload.frames) sourceFPS=\(String(format: "%.1f", Double(workload.frames) / max(workload.seconds, 0.001)))")
                share.track.remove(sharedCounter)
                try await wait("share retires") { !receiver.incomingVideo.contains { $0.source == "SCREEN_SHARE" } }
            }
            model.toggleCamera()
            try await wait("ordinary camera off before Presenter") { !model.snapshot.cameraOn && model.localCamera == nil }
            let workspace = model.presenter
            await workspace.open(); workspace.scene.layout = .card
            await workspace.setIncludeCamera(true)
            try await wait("private camera ready after completed mute handover") { await workspace.privateCameraDevice() != nil }
            let privateDevice = await workspace.privateCameraDevice()
            XCTAssertNotNil(privateDevice)
            try await workspace.startSharing()
            try await wait("Presenter reaches receiver") { receiver.incomingVideo.contains { $0.source == "SCREEN_SHARE" } }
            let presentation = try XCTUnwrap(receiver.incomingVideo.first { $0.source == "SCREEN_SHARE" })
            let presentationCounter = ShareEncodingFrameCounter()
            presentation.track.add(presentationCounter); probes.append((presentation.track, presentationCounter))
            try await wait("Presenter decodes") { presentationCounter.snapshot.frames >= 8 }
            for cycle in 0..<3 {
                model.toggleCamera()
                try await wait("ordinary camera borrows Presenter hardware safely") { model.snapshot.cameraOn && model.localCamera != nil }
                let cameraBaseline = await cameraFrames(adapter), canvasBaseline = presentationCounter.snapshot.frames
                try await wait("ordinary camera publishes after private handover") { await self.cameraFrames(adapter) > cameraBaseline + 8 }
                try await wait("Presenter keeps decoding during camera handover") { presentationCounter.snapshot.frames > canvasBaseline + 8 }
                XCTAssertTrue(workspace.includeCamera); XCTAssertTrue(workspace.isSharing)
                model.toggleCamera()
                try await wait("camera mute returns hardware to private Presenter") { !model.snapshot.cameraOn && model.localCamera == nil }
                try await wait("private Presenter resumes after live-camera mute") { await workspace.privateCameraDevice() != nil }
                XCTAssertNil(model.error)
                print("PRESENTER_CAMERA_HANDOVER cycle=\(cycle) connected=\(model.connected)")
            }
            let presenterClean = await workspace.close()
            XCTAssertTrue(presenterClean)
            for (track, sink) in probes { track.remove(sink) }; probes.removeAll()
            let senderClean = await model.leave(), receiverClean = await receiver.leave()
            XCTAssertTrue(senderClean); XCTAssertTrue(receiverClean)
        } catch {
            if let native = adapter.currentNativeEngine {
                let diagnostics = ["sender": await native.evidence(), "receiver": await receiver.evidence()]
                if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]) {
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                    attachment.name = "Camera and share failure statistics"; attachment.lifetime = .keepAlways; add(attachment)
                }
            }
            for (track, sink) in probes { track.remove(sink) }
            _ = await model.leave(); _ = await receiver.leave(); throw error
        }
    }
    func testGuestEfficientAndVP9ContentReachIndependentReceiver() async throws {
        guard ProcessInfo.processInfo.environment["NATIVE_DESKTOP_LIVE_SHARE_ENCODING"] == "1" else {
            throw XCTSkip("Opt in to disposable live sharing codec validation.")
        }
        executionTimeAllowance = 180
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: ShareEncodingPreference.defaultsKey)
        defer {
            if let previous { defaults.set(previous, forKey: ShareEncodingPreference.defaultsKey) }
            else { defaults.removeObject(forKey: ShareEncodingPreference.defaultsKey) }
        }
        let invitation = try await GuestBootstrap.createDisposable(origin: URL(string: "https://salutejazz.ru")!)
        let receiver = NativeGuestEngine(label: "Share codec independent receiver")
        let adapter = NativeDesktopGuestEngine()
        let model = NativeDesktopMeetingModel(destination: try .verified(invitation.invitationURL, engine: .guest),
            name: "Share codec synthetic sender", title: "Share codec validation", engine: adapter)
        var sinks: [(LKRTCVideoTrack, ShareEncodingFrameCounter)] = []
        do {
            try await receiver.join(invitation)
            try await model.connect()
            XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertFalse(model.snapshot.cameraOn)
            try await wait("VP9 server capability") { model.presenter.supportsVP9 }
            // Synthetic concurrent camera exercises the real separate H264
            // sender without accessing the Mac camera or microphone.
            adapter.currentNativeEngine?.cameraCaptureFactory = { NativeDesktopShareCapture(source: $0, canvasOnly: true) }
            try await adapter.setCamera(true)
            try await wait("actual H264 camera RTP") { await self.cameraFrames(adapter) > 5 }
            for preference in [ShareEncodingPreference.efficient, .textDetail, .efficient] {
                let workspace = model.presenter
                await workspace.open(); await workspace.chooseCanvas()
                workspace.encodingPreference = preference
                try await workspace.startSharing()
                try await wait("remote shared track") { receiver.incomingVideo.contains { $0.source == "SCREEN_SHARE" } }
                var video = try XCTUnwrap(receiver.incomingVideo.first { $0.source == "SCREEN_SHARE" })
                var counter = ShareEncodingFrameCounter(); video.track.add(counter); sinks.append((video.track, counter))
                try await wait("decoded content frames") { counter.snapshot.frames >= 8 }
                try await wait("measured sender codec") { workspace.encodingReport?.codec == preference.codec }
                let measured = try XCTUnwrap(workspace.encodingReport)
                XCTAssertEqual(measured.codec, preference.codec)
                XCTAssertEqual(workspace.activeEncodingPreference, preference)
                if preference == .textDetail {
                    workspace.encodingPreference = .efficient
                    await workspace.chooseCanvas()
                    XCTAssertNotNil(workspace.contentDraft)
                    try await workspace.applyContentChange()
                    XCTAssertEqual(workspace.activeEncodingPreference, .textDetail)
                    try await wait("VP9 after content replacement") { workspace.encodingReport?.codec == "vp9" }
                    let previousTrack = video.track
                    try await wait("replacement remote shared track") {
                        receiver.incomingVideo.contains { $0.source == "SCREEN_SHARE" && $0.track !== previousTrack }
                    }
                    video = try XCTUnwrap(receiver.incomingVideo.first { $0.source == "SCREEN_SHARE" && $0.track !== previousTrack })
                    counter = ShareEncodingFrameCounter(); video.track.add(counter); sinks.append((video.track, counter))
                    try await wait("replacement decoded VP9 frames") { counter.snapshot.frames >= 8 }
                }
                let state = counter.snapshot
                print("SHARE_ENCODING_LIVE codec=\(measured.codec) implementation=\(measured.implementation.rawValue) decoded=\(state.frames) dimensions=\(state.width)x\(state.height)")
                XCTAssertGreaterThan(state.width, 0); XCTAssertGreaterThan(state.height, 0)
                XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertTrue(model.snapshot.cameraOn)
                // Measure after sharing has negotiated and decoded. A baseline
                // from before preparation can pass using frames sent before a stall.
                let cameraBaseline = await cameraFrames(adapter)
                try await wait("advancing actual H264 camera alongside content") { await self.cameraFrames(adapter) > cameraBaseline + 5 }
                let cameraVideo = try XCTUnwrap(receiver.incomingVideo.first { $0.source != "SCREEN_SHARE" })
                let cameraCounter = ShareEncodingFrameCounter()
                cameraVideo.track.add(cameraCounter); sinks.append((cameraVideo.track, cameraCounter))
                try await wait("remote camera decodes while sharing") { cameraCounter.snapshot.frames >= 8 }
                try await workspace.stopSharing()
                XCTAssertNil(workspace.encodingReport)
                for (track, sink) in sinks { track.remove(sink) }; sinks.removeAll()
                try await wait("remote share retirement") { !receiver.incomingVideo.contains { $0.source == "SCREEN_SHARE" } }
            }
            let senderClean = await model.leave(), receiverClean = await receiver.leave()
            XCTAssertTrue(senderClean); XCTAssertTrue(receiverClean)
        } catch {
            for (track, sink) in sinks { track.remove(sink) }
            _ = await model.leave(); _ = await receiver.leave()
            throw error
        }
    }
    private static func readableShareFixture() throws -> CIImage {
        let canvas = try XCTUnwrap(CGContext(data: nil, width: 3840, height: 2160, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(gray: 0.96, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: 3840, height: 2160))
        canvas.setFillColor(CGColor(red: 0.07, green: 0.12, blue: 0.22, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 2020, width: 3840, height: 140))
        func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor) {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
            canvas.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes)), canvas)
        }
        text("Native 4K shared document — camera remains live", x: 64, y: 2070, size: 42, color: CGColor(gray: 1, alpha: 1))
        canvas.setStrokeColor(CGColor(gray: 0.78, alpha: 1)); canvas.setLineWidth(1)
        for column in 0...6 {
            let x = CGFloat(64 + column * 616)
            canvas.move(to: CGPoint(x: x, y: 80)); canvas.addLine(to: CGPoint(x: x, y: 1980))
        }
        for row in 0...40 {
            let y = CGFloat(100 + row * 46)
            canvas.move(to: CGPoint(x: 64, y: y)); canvas.addLine(to: CGPoint(x: 3760, y: y))
        }
        canvas.strokePath()
        for row in 0..<40 { for column in 0..<6 {
            text(String(format: "R%02d C%02d  0123456789  AaBbCc", row + 1, column + 1),
                x: CGFloat(80 + column * 616), y: CGFloat(1948 - row * 46), size: 24, color: CGColor(gray: 0.12, alpha: 1))
        } }
        return CIImage(cgImage: try XCTUnwrap(canvas.makeImage()))
    }

    private func cameraFrames(_ adapter: NativeDesktopGuestEngine) async -> Int64 {
        guard let native = adapter.currentNativeEngine, let mid = native.publicationIdentity["mid"],
              let rows = await native.screenShareStatsForTesting(.publisher),
              let outbound = rows.first(where: { $0["target"] as? String == "PUBLISHER" &&
                  $0["type"] as? String == "outbound-rtp" && $0["mid"] as? String == mid && $0["kind"] as? String == "video" }),
              let codecID = outbound["codecId"] as? String,
              let mime = rows.first(where: { $0["target"] as? String == "PUBLISHER" && $0["id"] as? String == codecID })?["mimeType"] as? String,
              mime.lowercased() == "video/h264" else { return 0 }
        return (outbound["framesEncoded"] as? NSNumber)?.int64Value ?? 0
    }
    private func wait(_ label: String, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Timed out: \(label)")
        throw NSError(domain: "ShareEncodingLive", code: 1)
    }
}

private final class ShareEncodingFrameCounter: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    struct Snapshot { var frames = 0; var width: Int32 = 0; var height: Int32 = 0 }
    private let lock = NSLock()
    private var value = Snapshot()
    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return value }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        lock.lock(); value.frames += 1; value.width = frame.width; value.height = frame.height; lock.unlock()
    }
}
