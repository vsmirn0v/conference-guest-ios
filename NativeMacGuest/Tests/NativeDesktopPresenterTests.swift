import AppKit
import Combine
import CoreImage
import Foundation
import ImageIO
import LiveKitWebRTC
import SwiftUI
import UniformTypeIdentifiers

// Standalone harness: the application supplies these UI integration types.
enum NativeDesktopError: Error { case unavailable(String) }
@MainActor final class NativeDesktopDeviceModel { static func stopPrivatePreview() async -> Bool { true } }
@MainActor final class NativeDesktopMeetingModel: ObservableObject {
    let presenter: NativeDesktopPresenterSession
    init(_ presenter: NativeDesktopPresenterSession) { self.presenter = presenter }
}
struct NativeDesktopVideoView: View { let track: LKRTCVideoTrack; var body: some View { Color.black } }

private final class FakeCapture: NativeDesktopPresenterCapture, @unchecked Sendable {
    let gate = GuestCompletion<GuestCameraInfo>()
    var delayed = false, failStart = false, failStop = false
    var delayedStop: GuestCompletion<Void>?
    var starts = 0, stops = 0, cancels = 0
    var scene: PresenterScene?
    var selectionMode: MacScreenCaptureSelectionMode = .automatic
    var onEnd: (@Sendable (Error?) -> Void)?
    var onDimensions: (@Sendable (CGSize) -> Void)?
    var info: GuestCameraInfo {
        .init(deviceName: "fixture", width: 1600, height: 1000, fps: 30,
            requestedWidth: 1600, requestedHeight: 1000, requestedFPS: 30, sessionPreset: "fixture",
            minimumFrameDuration: CMTime(value: 1, timescale: 30), maximumFrameDuration: CMTime(value: 1, timescale: 30),
            pixelFormat: kCVPixelFormatType_32BGRA, mirrored: false, rotationDegrees: 0)
    }
    func start() async throws -> GuestCameraInfo {
        starts += 1
        if failStart { throw NativeDesktopRTCError.invalidResponse }
        if !delayed { return info }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { gate.install($0, timeout: 5) }
        }, onCancel: { self.cancel() })
    }
    func cancel() { cancels += 1; gate.finish(.failure(CancellationError())) }
    func stop() async throws {
        stops += 1
        if let delayedStop { try await withCheckedThrowingContinuation { delayedStop.install($0, timeout: 5) } }
        if failStop { throw NativeDesktopRTCError.cleanupFailed }
    }
    func snapshot() -> GuestCameraSnapshot { .init(frames: 1, advancingPTS: 1, dropped: 0, width: 1600, height: 1000, pixelFormat: kCVPixelFormatType_32BGRA, systemBackgroundSelected: nil, systemBackgroundActive: nil, observedReaction: false) }
    func performReaction() async -> Bool { false }
    func setScene(_ scene: PresenterScene?) { self.scene = scene }
    func setCamera(_ pixels: CVPixelBuffer?) {}
    func setSelectionMode(_ mode: MacScreenCaptureSelectionMode) { selectionMode = mode }
}

@main struct NativeDesktopPresenterTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; LKRTCInitializeSSL()
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory())
        let suite = "PresenterTests.\(UUID())", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw NSError(domain: "PresenterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }; checks += 1
        }
        func until(_ predicate: () -> Bool) async throws {
            for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
            throw NSError(domain: "PresenterTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Fixture did not reach expected state"])
        }
        var publications = 0, retirements = 0, cameraCreations = 0, captures: [FakeCapture] = [], cameras: [FakeCapture] = []
        var liveTrack: LKRTCVideoTrack?
        var publishedProfile: GuestVideoProfile?
        let session = NativeDesktopPresenterSession(factory: { factory }, liveCamera: { liveTrack }, publish: { _, profile in
            publications += 1; publishedProfile = profile
        }, unpublish: { retirements += 1 }, preparePrivateCamera: {}, preferences: preferences,
            makeCapture: { _, _ in let value = FakeCapture(); captures.append(value); return value },
            makeCamera: { _ in cameraCreations += 1; let value = FakeCapture(); cameras.append(value); return value })
        await session.open()
        try expect(session.previewTrack != nil && session.aspectRatio == 1.6 && publications == 0 && cameraCreations == 0,
                   "Opening prepares a real-size private canvas without publishing or starting a camera")
        try expect(session.scene.layout == .cutout && session.scene.cameraMirrored, "Fresh Presenter defaults to mirrored person cutout")
        await session.setIncludeCamera(true)
        try expect(cameraCreations == 1 && cameras[0].starts == 1 && session.includeCamera && publications == 0,
                   "Including a private camera never publishes the ordinary camera or screen")
        try await session.releasePrivateCameraBeforeLiveCapture()
        try expect(cameras[0].stops == 1, "Ordinary camera handover waits for one confirmed private camera stop")
        await session.refreshBorrowedCamera()
        try expect(cameraCreations == 1, "A late refresh cannot reacquire private camera while ordinary camera starts")
        liveTrack = factory.videoTrack(with: factory.videoSource(), trackId: "already-live-camera")
        await session.finishLiveCameraHandover()
        try expect(cameraCreations == 1 && session.includeCamera, "An already live camera is borrowed without another capture")
        await session.setIncludeCamera(false)
        try expect(liveTrack?.isEnabled == true && cameras[0].stops == 1, "Removing borrowed camera never mutes or stops ordinary camera")
        session.edit { $0.placement.x = 2; $0.layout = .instrument; $0.zoom = 2; $0.focus = CGPoint(x: 0.2, y: 0.7) }
        let edited = PresenterCanvasEdit(session.scene)
        try expect(session.scene.placement.x + session.scene.placement.width <= 1, "Geometry is clamped to the exported canvas")
        session.undo(); try expect(session.scene.layout == .cutout && session.scene.zoom == 1, "Undo restores the complete edit geometry")
        session.redo(); try expect(PresenterCanvasEdit(session.scene) == edited, "Redo restores layout, crop and placement together")
        session.appendStroke([CGPoint(x: -3, y: 2), CGPoint(x: 0.5, y: 0.5)])
        try expect(session.scene.strokes.last?.first == CGPoint(x: 0, y: 1), "Annotation coordinates are normalized and bounded")
        session.undo(); try expect(session.scene.strokes.isEmpty && session.scene.draftStroke.isEmpty, "Undo removes a complete stroke without stale draft ink")
        try await session.startSharing()
        try expect(publications == 1 && session.isSharing && publishedProfile?.width == 1600 && publishedProfile?.height == 1000 && publishedProfile?.maximumBitrate == 18_000_000,
                   "Explicit sharing publishes the preview with confirmed native dimensions and detail profile")
        await session.chooseScreen()
        try expect(captures.count == 2 && session.source == .canvas && session.contentDraft?.source == .screen && session.isSharing && publications == 1,
                   "Live source selection prepares a private draft while the original publication continues")
        let liveScene = captures[0].scene
        session.contentDraft?.scene.backdrop = .warm
        try expect(captures[0].scene == liveScene, "Draft edits never leak into the live compositor")
        await session.cancelContentChange()
        try expect(session.contentDraft == nil && captures[1].stops == 1 && captures[0].stops == 0 && session.source == .canvas,
                   "Cancel drains only the draft and preserves the original live source")
        try await session.stopSharing()
        try expect(retirements == 1 && !session.isSharing && session.previewTrack != nil, "Stop retires only publication and preserves private preparation")
        _ = await session.close()
        try expect(captures[0].stops == 1 && session.previewTrack == nil && !session.includeCamera, "Close drains capture once and revokes per-session camera inclusion")
        await session.open()
        try expect(captures.count == 3 && !session.includeCamera && cameraCreations == 1, "Reopening cannot restore old capture consent")
        _ = await session.close()
        await session.chooseWindow()
        try expect(captures.last?.selectionMode == .window && publications == 1,
                   "Explicit window preparation requests the system window picker without publishing")
        await session.chooseScreen()
        try expect(captures.last?.selectionMode == .automatic && publications == 1,
                   "General screen preparation retains both screen and window selection")
        _ = await session.close()

        var replacementCaptures: [FakeCapture] = [], replacementPublications: [LKRTCVideoTrack] = []
        var replacementStops = 0
        let replacement = NativeDesktopPresenterSession(factory: { factory }, liveCamera: { nil },
            publish: { track, _ in replacementPublications.append(track) }, unpublish: { replacementStops += 1 },
            preferences: preferences, makeCapture: { _, _ in let capture = FakeCapture(); replacementCaptures.append(capture); return capture })
        replacement.supportsVP9 = true; replacement.encodingPreference = .textDetail
        await replacement.open(); try await replacement.startSharing()
        replacement.encodingPreference = .efficient
        await replacement.chooseScreen()
        let nextTrack = replacement.contentDraft!.previewTrack!
        try await replacement.applyContentChange()
        try expect(replacement.contentDraft == nil && replacement.source == .screen && replacement.isSharing && replacement.previewTrack === nextTrack,
                   "Confirm adopts the prepared source and republishes its actual track")
        try expect(replacementPublications.count == 2 && replacementPublications.last === nextTrack && replacementStops == 1 && replacementCaptures[0].stops == 1,
                   "Source replacement drains the prior capture after the new publication succeeds")
        try expect(replacement.activeEncodingPreference == .textDetail,
                   "Source replacement preserves the explicitly started session codec despite preference edits")
        await replacement.chooseCanvas()
        let retiredDraft = replacementCaptures.last!
        _ = await replacement.close()
        try expect(retiredDraft.stops == 1 && replacement.contentDraft == nil && !replacement.isSharing,
                   "Leave closes active publication and pending source draft")

        let replacementLease = NativeDesktopCameraLease()
        var replacementCameras: [FakeCapture] = []
        let cameraReplacement = NativeDesktopPresenterSession(factory: { factory }, liveCamera: { nil },
            publish: { _, _ in }, unpublish: {}, preferences: preferences, cameraLease: replacementLease,
            makeCapture: { _, _ in FakeCapture() },
            makeCamera: { _ in let value = FakeCapture(); replacementCameras.append(value); return value })
        await cameraReplacement.open(); try await cameraReplacement.startSharing(); await cameraReplacement.chooseCanvas()
        await cameraReplacement.contentDraft!.setIncludeCamera(true)
        try expect(replacementCameras.count == 1 && replacementCameras[0].starts == 1,
                   "Draft can prepare a private camera while the live share has no camera")
        try await cameraReplacement.applyContentChange()
        try expect(replacementCameras.count == 2 && replacementCameras[0].stops == 1 && replacementCameras[1].starts == 1,
                   "Apply retires the draft camera lease and reacquires capture under the root owner")
        let afterReplacement = try await replacementLease.acquireLive(owner: UUID(), revoke: {})
        try expect(replacementCameras[1].stops == 1,
                   "A later ordinary-camera lease revokes the adopted root camera before granting hardware")
        replacementLease.release(afterReplacement)
        _ = await cameraReplacement.close()

        let applyGate = GuestCompletion<Void>()
        var applyPublications = 0, applyCaptures: [FakeCapture] = []
        let closingApply = NativeDesktopPresenterSession(factory: { factory }, liveCamera: { nil },
            publish: { _, _ in
                applyPublications += 1
                if applyPublications == 2 { try await withCheckedThrowingContinuation { applyGate.install($0, timeout: 5) } }
            }, unpublish: {}, preferences: preferences,
            makeCapture: { _, _ in let value = FakeCapture(); applyCaptures.append(value); return value })
        await closingApply.open(); try await closingApply.startSharing(); await closingApply.chooseCanvas()
        let applyOperation = Task { try await closingApply.applyContentChange() }
        try await until { applyPublications == 2 }
        let closeDuringApply = Task { await closingApply.close() }
        try await until { closingApply.isClosing }
        applyGate.finish(.success(()))
        _ = await applyOperation.result
        let closedDuringApply = await closeDuringApply.value
        try expect(closedDuringApply && !closingApply.isSharing && closingApply.previewTrack == nil && closingApply.contentDraft == nil && applyCaptures.allSatisfy { $0.stops == 1 },
                   "Leave during a delayed replacement drains old and draft captures and rejects late publication")

        var cleanupCaptures: [FakeCapture] = []
        let failingRootCamera = FakeCapture()
        let cleanupReplacement = NativeDesktopPresenterSession(factory: { factory }, liveCamera: { nil },
            publish: { _, _ in }, unpublish: {}, preferences: preferences, cameraLease: NativeDesktopCameraLease(),
            makeCapture: { _, _ in let value = FakeCapture(); cleanupCaptures.append(value); return value },
            makeCamera: { _ in failingRootCamera })
        await cleanupReplacement.open(); await cleanupReplacement.setIncludeCamera(true)
        try await cleanupReplacement.startSharing(); await cleanupReplacement.chooseCanvas()
        await cleanupReplacement.contentDraft!.setIncludeCamera(false)
        failingRootCamera.failStop = true
        do { try await cleanupReplacement.applyContentChange(); try expect(false, "Camera stop failure must be reported") }
        catch { try expect(cleanupCaptures[0].stops == 1, "Camera teardown failure still drains the old content capture") }
        let cameraCleanupConfirmed = await cleanupReplacement.close()
        try expect(!cameraCleanupConfirmed && cleanupCaptures.allSatisfy { $0.stops == 1 },
                   "Unconfirmed camera cleanup remains visible while both content captures are retired")

        var rejectedPublications = 0, rejectedCaptures: [FakeCapture] = []
        let rejectedReplacement = NativeDesktopPresenterSession(factory: { factory }, liveCamera: { nil },
            publish: { _, _ in rejectedPublications += 1; if rejectedPublications == 2 { throw NativeDesktopRTCError.invalidResponse } },
            unpublish: {}, preferences: preferences,
            makeCapture: { _, _ in let value = FakeCapture(); rejectedCaptures.append(value); return value })
        await rejectedReplacement.open(); try await rejectedReplacement.startSharing()
        let preservedTrack = rejectedReplacement.previewTrack!
        await rejectedReplacement.chooseScreen()
        do { try await rejectedReplacement.applyContentChange(); try expect(false, "Rejected new publication must report an error") }
        catch { try expect(rejectedPublications == 3 && rejectedReplacement.isSharing && rejectedReplacement.previewTrack === preservedTrack && rejectedCaptures[0].stops == 0,
                           "Rejected replacement republishes the preserved source and keeps its capture alive") }
        _ = await rejectedReplacement.close()

        let pendingCapture = FakeCapture(); pendingCapture.delayed = true
        let pendingSession = NativeDesktopPresenterSession(factory: { factory }, liveCamera: { nil }, publish: { _, _ in publications += 1 }, unpublish: {},
            preparePrivateCamera: {}, preferences: preferences, makeCapture: { _, _ in pendingCapture })
        let preparing = Task { await pendingSession.chooseScreen() }
        try await until { pendingCapture.starts == 1 }
        preparing.cancel(); await preparing.value
        try expect(pendingCapture.stops == 1 && pendingSession.previewTrack == nil && !pendingSession.isPreparing, "Cancellation of preparation drains a pending picker/capture")
        _ = await pendingSession.close()

        let publishGate = GuestCompletion<Void>(); var beganPublish = false, rollback = 0
        let raceCapture = FakeCapture()
        let race = NativeDesktopPresenterSession(factory: { factory }, liveCamera: { nil }, publish: { _, _ in
            beganPublish = true
            // Simulate a provider acknowledgement arriving after cancellation.
            try await withCheckedThrowingContinuation { publishGate.install($0, timeout: 5) }
        }, unpublish: { rollback += 1 }, preparePrivateCamera: {}, preferences: preferences, makeCapture: { _, _ in raceCapture })
        await race.open(); let priorTrack = race.previewTrack!
        let publishing = Task { try await race.startSharing() }
        try await until { beganPublish }
        let closing = Task { await race.close() }
        try await until { race.isClosing }
        try expect(!priorTrack.isEnabled && raceCapture.cancels > 0, "Close revokes producer and published track before waiting for provider acknowledgement")
        publishGate.finish(.success(())); _ = await publishing.result
        let closed = await closing.value
        try expect(closed && rollback == 1 && !race.isSharing && race.previewTrack == nil && raceCapture.stops == 1,
                   "Late successful publication is rolled back once and cannot resurrect sharing")

        let failingCapture = FakeCapture(); failingCapture.failStop = true
        let failed = NativeDesktopPresenterSession(factory: { factory }, liveCamera: { nil }, publish: { _, _ in }, unpublish: {},
            preparePrivateCamera: {}, preferences: preferences, makeCapture: { _, _ in failingCapture })
        await failed.open(); let cleaned = await failed.close(); await failed.open()
        try expect(!cleaned && failed.previewTrack == nil && failingCapture.starts == 1 && failed.error != nil,
                   "Unconfirmed teardown blocks reuse and exposes failure")

        // Asymmetric exported pixels detect camera-only mirroring and crop errors.
        var camera: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &camera) == kCVReturnSuccess, let camera else { fatalError("pixels") }
        CVPixelBufferLockBaseAddress(camera, [])
        let bytes = CVPixelBufferGetBaseAddress(camera)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(camera)
        for y in 0..<32 { for x in 0..<64 { let at = y * stride + x * 4; bytes[at] = x < 32 ? 0 : 255; bytes[at+1] = 0; bytes[at+2] = x < 32 ? 255 : 0; bytes[at+3] = 255 } }
        CVPixelBufferUnlockBaseAddress(camera, [])
        let compositor = PresenterCompositor(size: CGSize(width: 200, height: 100), software: true)
        var scene = PresenterScene(); scene.layout = .card; scene.placement = PresenterPlacement(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        func rendered(_ scene: PresenterScene) throws -> CVPixelBuffer {
            guard let sample = compositor.render(scene: scene, camera: camera, time: .zero), let pixels = CMSampleBufferGetImageBuffer(sample) else { throw NativeDesktopRTCError.invalidResponse }; return pixels
        }
        func pixel(_ image: CVPixelBuffer, _ x: Int, _ y: Int) -> [UInt8] {
            CVPixelBufferLockBaseAddress(image, .readOnly); defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            let ptr = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self), at = y * CVPixelBufferGetBytesPerRow(image) + x * 4
            return Array(UnsafeBufferPointer(start: ptr + at, count: 4))
        }
        let original = try rendered(scene); scene.cameraMirrored = true; let reflected = try rendered(scene)
        try expect(pixel(original, 50, 50)[2] > 200 && pixel(reflected, 50, 50)[0] > 200 && pixel(original, 5, 5) == pixel(reflected, 5, 5),
                   "Export mirrors only camera pixels, preserving backdrop and canvas geometry")
        let bitmap = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(CIImage(cvPixelBuffer: reflected), from: CGRect(x: 0, y: 0, width: 200, height: 100))!
        let png = NSMutableData(), destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap, nil)
        try expect(CGImageDestinationFinalize(destination) && CGImageSourceCreateWithData(png, nil).map { CGImageSourceGetCount($0) } == 1,
                   "The composed fixture exports as a valid complete PNG")
        let safe = PresenterCompositor(size: CGSize(width: 200, height: 100), software: true, personMask: { _, _ in nil })
        scene.layout = .cutout
        let masked = safe.render(scene: scene, camera: camera, time: .zero).flatMap(CMSampleBufferGetImageBuffer)!
        try expect(pixel(masked, 50, 50)[2] < 100 && pixel(masked, 150, 50)[0] < 100,
                   "Missing segmentation never falls back to revealing the camera room")
        let relayTrack = factory.videoTrack(with: factory.videoSource(), trackId: "relay-fixture")
        let relay = NativeDesktopRelayCapture(track: relayTrack, source: factory.videoSource())
        let relaying = Task { try await relay.start() }
        await Task.yield()
        let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: camera), rotation: ._90, timeStampNs: 1)
        // A source renderer supplies frames independently of the startup caller.
        for _ in 0..<10 { relay.renderFrame(frame); await Task.yield() }
        let info = try await relaying.value
        try expect(info.width == 32 && info.height == 64 && relay.snapshot().frames > 0, "Guest relay completes only after actual frame forwarding and preserves RTC rotation dimensions")
        try await relay.stop(); let stoppedCount = relay.snapshot().frames
        relay.renderFrame(frame); try await relay.stop()
        try expect(relay.snapshot().frames == stoppedCount, "Retired Guest relay cannot forward a late callback")
        let retiredRelay = NativeDesktopRelayCapture(track: relayTrack, source: factory.videoSource())
        retiredRelay.cancel()
        do { _ = try await retiredRelay.start(); throw NativeDesktopRTCError.invalidResponse }
        catch GuestCameraError.alreadyStarted { checks += 1 }
        let lease = NativeDesktopCameraLease(), privateID = UUID(), liveID = UUID(), otherID = UUID()
        let revokeGate = GuestCompletion<Void>(); var revoking = false
        let first = try await lease.acquirePrivate(owner: privateID, revoke: {
            revoking = true
            try await withCheckedThrowingContinuation { revokeGate.install($0, timeout: 5) }
        })
        guard case .owned(let firstToken) = first else { fatalError("private fixture lease") }
        let liveAcquisition = Task { try await lease.acquireLive(owner: liveID, revoke: {}) }
        try await until { revoking }
        let duringHandover = try await lease.acquirePrivate(owner: otherID, revoke: {})
        if case .livePending = duringHandover { checks += 1 } else { fatalError("Private capture bypassed live reservation") }
        lease.release(firstToken) // The retiring owner's cleanup cannot clear the reservation.
        revokeGate.finish(.success(())); let liveToken = try await liveAcquisition.value
        try expect(lease.isCurrent(liveToken), "An old owner's late release cannot revoke a newer live reservation")
        lease.setLiveTrack(relayTrack, owner: liveID)
        let borrowed = try await lease.acquirePrivate(owner: otherID, revoke: {})
        if case .borrowed(let track) = borrowed { try expect(track === relayTrack, "Private settings borrow the exact existing live track") }
        else { fatalError("Private capture preempted a published camera") }
        lease.setLiveTrack(nil, owner: liveID)
        if case .livePending = try await lease.acquirePrivate(owner: otherID, revoke: {}) { checks += 1 }
        else { fatalError("Network recovery released the live hardware reservation") }
        lease.release(liveToken)
        let next = try await lease.acquirePrivate(owner: otherID, revoke: {})
        guard case .owned(let nextToken) = next else { fatalError("private lease after confirmed live stop") }
        lease.reportFailedStop(nextToken)
        do { _ = try await lease.acquireLive(owner: liveID, revoke: {}); throw NativeDesktopRTCError.invalidResponse }
        catch NativeDesktopRTCError.cleanupFailed { checks += 1 }
        let cameraHandover = NativeDesktopCameraLease(), delayedCamera = FakeCapture()
        delayedCamera.delayed = true
        let delayedSession = NativeDesktopPresenterSession(factory: { factory }, liveCamera: { nil }, publish: { _, _ in }, unpublish: {},
            preferences: preferences, cameraLease: cameraHandover, makeCapture: { _, _ in FakeCapture() }, makeCamera: { _ in delayedCamera })
        await delayedSession.open()
        let cameraPreparation = Task { await delayedSession.setIncludeCamera(true) }
        try await until { delayedCamera.starts == 1 }
        let acquiredLive = try await cameraHandover.acquireLive(owner: liveID, revoke: {})
        await cameraPreparation.value
        try expect(delayedCamera.stops == 1 && !delayedSession.cameraPreparing && cameraHandover.isCurrent(acquiredLive),
                   "Live camera acquisition cancels and drains an in-flight Presenter camera before granting hardware")
        _ = await delayedSession.close()
        try expect(cameraHandover.isCurrent(acquiredLive), "Closing a revoked private Presenter does not release the live engine lease")
        cameraHandover.release(acquiredLive)
        var failedSourceCaptures: [FakeCapture] = []
        let privateBeforeFailure = FakeCapture()
        let failedSource = NativeDesktopPresenterSession(factory: { factory }, liveCamera: { nil }, publish: { _, _ in }, unpublish: {},
            preferences: preferences, cameraLease: NativeDesktopCameraLease(), makeCapture: { _, _ in
                let value = FakeCapture(); value.failStart = !failedSourceCaptures.isEmpty; failedSourceCaptures.append(value); return value
            }, makeCamera: { _ in privateBeforeFailure })
        await failedSource.open(); await failedSource.setIncludeCamera(true); await failedSource.chooseScreen()
        try expect(failedSource.previewTrack == nil && !failedSource.includeCamera && privateBeforeFailure.stops == 1,
                   "Failed source replacement retires private camera instead of leaving invisible capture")
        _ = await failedSource.close()

        let retiredSource = FakeCapture(), stopGate = GuestCompletion<Void>()
        var sourceCreations = 0
        let retiringSource = NativeDesktopPresenterSession(factory: { factory }, liveCamera: { nil }, publish: { _, _ in }, unpublish: {},
            preferences: preferences, makeCapture: { _, _ in sourceCreations += 1; return retiredSource })
        await retiringSource.open(); retiredSource.failStop = true; retiredSource.delayedStop = stopGate
        let replacingSource = Task { await retiringSource.chooseScreen() }
        try await until { retiredSource.stops == 1 }
        let closingReplacement = Task { await retiringSource.close() }
        try await until { retiringSource.isClosing }
        stopGate.finish(.success(())); await replacingSource.value
        let replacementClean = await closingReplacement.value
        try expect(!replacementClean && retiringSource.error != nil, "Close preserves a teardown failure discovered by a draining superseded source")
        await retiringSource.open()
        try expect(sourceCreations == 1 && retiringSource.previewTrack == nil, "Failed old-source stop permanently blocks unsafe reuse")

        let priorSource = FakeCapture(), priorStop = GuestCompletion<Void>()
        var replacementCreations = 0, secondRequested = false
        let overlappingSources = NativeDesktopPresenterSession(factory: { factory }, liveCamera: { nil }, publish: { _, _ in }, unpublish: {},
            preferences: preferences, makeCapture: { _, _ in replacementCreations += 1; return priorSource })
        await overlappingSources.open(); priorSource.failStop = true; priorSource.delayedStop = priorStop
        let firstReplacement = Task { await overlappingSources.chooseScreen() }
        try await until { priorSource.stops == 1 }
        let secondReplacement = Task { secondRequested = true; await overlappingSources.chooseCanvas() }
        try await until { secondRequested }; await Task.yield()
        priorStop.finish(.success(())); await firstReplacement.value; await secondReplacement.value
        try expect(replacementCreations == 1 && overlappingSources.previewTrack == nil,
                   "A newer source request cannot bypass an older request's failed teardown")
        _ = await overlappingSources.close()
        let notStarted = GuestCamera(source: factory.videoSource())
        let absentDevice = await notStarted.captureDevice()
        try expect(absentDevice == nil, "Actual camera metadata is absent before explicit capture starts")
        let fakeDevice = await FakeCapture().captureDevice()
        try expect(fakeDevice == nil, "Generated/relay captures never fabricate physical device metadata")
        if #available(macOS 14, *) {
            try expect(CameraReactionObserver.reaction(.heart) == .heart && CameraReactionObserver.reaction(.thumbsUp) == .like &&
                CameraReactionObserver.reaction(.confetti) == .applause && CameraReactionObserver.reaction(.balloons) == nil,
                "Native system metadata maps only supported room reactions")
        }
        var importsCreated = 0
        let importSession = NativeDesktopPresenterSession(factory: { factory }, liveCamera: { nil }, publish: { _, _ in }, unpublish: {},
            preferences: preferences, makeCapture: { _, _ in importsCreated += 1; return FakeCapture() })
        await importSession.open(); await importSession.chooseScreen()
        let imageRequest = importSession.imageImportRevision
        _ = await importSession.close()
        await importSession.loadImage(png as Data, expectedRevision: imageRequest, selectCanvas: true)
        try expect(importsCreated == 2 && importSession.previewTrack == nil, "A late image-panel read cannot reopen a closed screen preparation")
        await importSession.open()
        await importSession.loadImage(png as Data, expectedRevision: imageRequest, selectCanvas: true)
        try expect(importSession.scene.image == nil, "An old image request cannot edit a newer Presenter session")
        try await importSession.startSharing(); await importSession.chooseScreen()
        let cancelledImageRequest = importSession.imageImportRevision
        await importSession.cancelContentChange()
        await importSession.chooseImage(png as Data, expectedRevision: cancelledImageRequest)
        try expect(importSession.contentDraft == nil && importSession.scene.image == nil && importSession.isSharing,
                   "A late image-panel completion cannot recreate a cancelled draft or change live content")
        _ = await importSession.close()
        print("PASS: \(checks) Presenter privacy, ownership, cancellation, publication, geometry, undo/redo and exported-pixel assertions; no system capture or live meeting")
    }
}
