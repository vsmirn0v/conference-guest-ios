import AVFoundation
import CoreImage
import UIKit
import XCTest
import VisionKit
@testable import RockNRoll

@MainActor final class SharedTextTests: XCTestCase {
    func testSnapshotHasOwnedPixelsAndOrientedFullResolution() throws {
        let pixels = try makePixels(width: 320, height: 180)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 255, CVPixelBufferGetBytesPerRow(pixels) * 180)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let image = try XCTUnwrap(SharedTextImage.oriented(pixels, rotation: 90))
        let captured = try XCTUnwrap(SharedTextImage.materialize(image))
        XCTAssertEqual(captured.width, 180); XCTAssertEqual(captured.height, 320)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 0, CVPixelBufferGetBytesPerRow(pixels) * 180)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let data = try XCTUnwrap(captured.dataProvider?.data)
        XCTAssertEqual(CFDataGetBytePtr(data)?[0], 255, "A frozen capture must not change when the producer reuses its buffer")
        XCTAssertNil(SharedTextImage.oriented(pixels, rotation: 45))
    }
    func testCaptureMetadataAndRecognitionIdentitySurviveEndedOrReplacedShare() throws {
        let image = try XCTUnwrap(SharedTextImage.materialize(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))))
        let snapshot = SharedTextSnapshot(image: image, sourceID: "old", sourceName: "Alex")
        XCTAssertEqual(SharedTextLiveState.resolve(capturedSource: snapshot.sourceID, currentSource: nil), .ended)
        XCTAssertEqual(SharedTextLiveState.resolve(capturedSource: snapshot.sourceID, currentSource: "new"), .changed)
        XCTAssertEqual(snapshot.sourceName, "Alex")
        let meeting = UUID(), identity = SharedTextAnalysisIdentity(meeting: meeting, snapshot: snapshot.id)
        XCTAssertNotEqual(identity, .init(meeting: UUID(), snapshot: snapshot.id))
        XCTAssertNotEqual(identity, .init(meeting: meeting, snapshot: UUID()))
    }
    func testDirectGuestDeliveryCapturesSampleAndRotationBeforeGeometryCallback() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Direct background delivery requires iOS 17") }
        let view = GuestSampleBufferView()
        let delivery = view.makeFrameDelivery { _, _ in }
        delivery.setActive(true)
        let pixels = try makePixels(width: 96, height: 48)
        let sample = try XCTUnwrap(PresenterCompositor.sample(pixels, time: .zero))
        delivery.deliver(sample, rotation: 270)
        let captured = try XCTUnwrap(view.snapshotFrame())
        XCTAssertEqual(captured.1, 270)
        XCTAssertTrue(CFEqual(CMSampleBufferGetImageBuffer(captured.0), pixels))
        view.clear(); XCTAssertNil(view.snapshotFrame()); XCTAssertNil(delivery.snapshotFrame())
    }
    func testClosingBeforeCaptureCompletesRejectsLateSnapshot() async throws {
        var continuation: CheckedContinuation<SharedTextSnapshot?, Never>?
        let overlay = SharedTextOverlay(sourceID: "one", sourceName: "Alex") {
            await withCheckedContinuation { continuation = $0 }
        }
        for _ in 0..<20 where continuation == nil { await Task.yield() }
        XCTAssertNotNil(continuation)
        overlay.finish()
        let image = try XCTUnwrap(SharedTextImage.materialize(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))))
        continuation?.resume(returning: .init(image: image, sourceID: "one", sourceName: "Alex"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(overlay.snapshot)
    }
    func testCaptureFailureStatusSurvivesParentLayoutUpdates() async throws {
        let overlay = SharedTextOverlay(sourceID: "one", sourceName: "Alex") { nil }
        for _ in 0..<20 { await Task.yield() }
        func labels(_ view: UIView) -> [UILabel] { (view as? UILabel).map { [$0] } ?? view.subviews.flatMap(labels) }
        let status = try XCTUnwrap(labels(overlay).first { $0.accessibilityIdentifier == "Captured share status" })
        let before = try XCTUnwrap(status.text)
        overlay.updateSource(id: "one", name: "Alex")
        XCTAssertEqual(status.text, before, "A layout/source refresh must retain capture/analysis errors")
        overlay.finish()
    }
    func testProcessAdmissionRemainsSingleFlightUntilMatchingRelease() throws {
        let gate = SharedTextWorkAdmission(), first = try XCTUnwrap(gate.acquire())
        XCTAssertNil(gate.acquire())
        gate.release(UUID()); XCTAssertNil(gate.acquire())
        gate.release(first); XCTAssertNotNil(gate.acquire())
    }
    func testCancelBeforeWorkerStartsDoesNotCapture() async throws {
        var captures = 0, recognitions = 0
        let job = try XCTUnwrap(SharedTextJob.start(timeout: .seconds(1), capture: { captures += 1; return nil },
            recognize: { _ in recognitions += 1; return .transcript("unexpected") }, onCapture: { _ in }, onResult: { _ in },
            onFailure: { _ in }, onTimeout: {}, onFinished: {}))
        job.cancelUI()
        try await wait { !SharedTextWorkAdmission.shared.isOccupied }
        XCTAssertEqual(captures, 0); XCTAssertEqual(recognitions, 0)
    }
    func testCancelReentrantlyDuringCaptureDoesNotBeginRecognition() async throws {
        let image = try XCTUnwrap(SharedTextImage.materialize(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))))
        let captured = SharedTextSnapshot(image: image, sourceID: "one", sourceName: "Alex")
        var job: SharedTextJob?, recognitions = 0
        job = SharedTextJob.start(timeout: .seconds(1), capture: { captured }, recognize: { _ in
            recognitions += 1; return .transcript("unexpected")
        }, onCapture: { _ in job?.cancelUI() }, onResult: { _ in XCTFail("Canceled result was delivered") },
            onFailure: { _ in }, onTimeout: {}, onFinished: {})
        XCTAssertNotNil(job)
        try await wait { !SharedTextWorkAdmission.shared.isOccupied }
        XCTAssertEqual(recognitions, 0); job = nil
    }
    func testRecognitionDeadlineRetainsImageAndRejectsLateResultAfterExit() async throws {
        let image = try XCTUnwrap(SharedTextImage.materialize(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))))
        let captured = SharedTextSnapshot(image: image, sourceID: "one", sourceName: "Alex")
        var pending: CheckedContinuation<SharedTextRecognitionResult, Never>?
        var overlay: SharedTextOverlay? = SharedTextOverlay(sourceID: "one", sourceName: "Alex", timeout: .milliseconds(40), recognition: { _ in
            await withCheckedContinuation { pending = $0 }
        }, capture: { captured })
        try await wait { pending != nil }
        try await wait { overlay?.busy == false }
        XCTAssertEqual(overlay?.snapshot?.id, captured.id)
        XCTAssertTrue(SharedTextWorkAdmission.shared.isOccupied)
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let capturedOverlay = try XCTUnwrap(overlay)
        let refresh = try XCTUnwrap(descendants(capturedOverlay).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "Capture current shared frame" })
        let status = try XCTUnwrap(descendants(capturedOverlay).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "Captured share status" })
        XCTAssertFalse(refresh.isEnabled)
        let timeoutStatus = status.text
        capturedOverlay.updateSource(id: "two", name: "Sam")
        XCTAssertTrue(status.text?.contains(L("Text recognition is taking too long. Return to Live and try again later.")) == true)
        capturedOverlay.finish(); overlay = nil
        var reopened: SharedTextOverlay? = SharedTextOverlay(sourceID: "two", sourceName: "Sam", recognition: { _ in .transcript("fresh") }, capture: { captured })
        XCTAssertFalse(reopened?.busy ?? true); XCTAssertNil(reopened?.snapshot)
        XCTAssertTrue(SharedTextWorkAdmission.shared.isOccupied)
        pending?.resume(returning: .transcript("late stale text")); pending = nil
        try await wait { !SharedTextWorkAdmission.shared.isOccupied }
        XCTAssertNil(reopened?.snapshot, "Finishing old OCR must not automatically capture or replace a reopened preview")
        XCTAssertNotNil(timeoutStatus)
        reopened?.finish(); reopened = nil
    }
    func testHangingRecognitionDoesNotRetainClosedOverlay() async throws {
        let image = try XCTUnwrap(SharedTextImage.materialize(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))))
        let captured = SharedTextSnapshot(image: image, sourceID: "one", sourceName: "Alex")
        var pending: CheckedContinuation<SharedTextRecognitionResult, Never>?
        var overlay: SharedTextOverlay? = SharedTextOverlay(sourceID: "one", sourceName: "Alex", recognition: { _ in
            await withCheckedContinuation { pending = $0 }
        }, capture: { captured })
        weak var owner = overlay
        try await wait { pending != nil }
        overlay?.finish(); overlay = nil
        // UIKit can keep a removed view until its next layout/autorelease turn.
        // Recognition remains suspended while we prove UI ownership is released.
        try await wait { owner == nil }
        XCTAssertNil(owner)
        XCTAssertTrue(SharedTextWorkAdmission.shared.isOccupied)
        pending?.resume(returning: .transcript("late")); pending = nil
        try await wait { !SharedTextWorkAdmission.shared.isOccupied }
    }
    func testZoomedCanvasSurvivesBothRotationDirectionsAndTransientZeroSize() async throws {
        let image = try XCTUnwrap(SharedTextImage.materialize(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 900))))
        let captured = SharedTextSnapshot(image: image, sourceID: "screen", sourceName: "White document")
        var captures = 0, recognitions = 0
        let overlay = SharedTextOverlay(sourceID: "screen", sourceName: "White document", recognition: { _ in
            recognitions += 1; return .transcript("")
        }, capture: { captures += 1; return captured })
        defer { overlay.finish() }
        overlay.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        overlay.layoutIfNeeded()
        try await wait { overlay.snapshot != nil && !overlay.busy }
        let scroll = try XCTUnwrap(descendants(overlay).compactMap { $0 as? UIScrollView }.first {
            $0.accessibilityIdentifier == "Captured image viewport"
        })
        let displayed = try XCTUnwrap(descendants(scroll).compactMap { $0 as? UIImageView }.first { $0.image != nil })
        XCTAssertTrue(displayed.image?.cgImage === image)
        for zoom: CGFloat in [1, 2, 8] {
            scroll.setZoomScale(zoom, animated: false)
            if zoom > 1 {
                scroll.setContentOffset(CGPoint(x: max(0, scroll.contentSize.width * 0.60 - scroll.bounds.width / 2),
                    y: max(-scroll.contentInset.top, scroll.contentSize.height * 0.60 - scroll.bounds.height / 2)), animated: false)
            }
            let originalX = normalizedCenter(scroll).x
            let originalY = normalizedCenter(scroll).y
            for size in [CGSize(width: 844, height: 390), .zero, CGSize(width: 390, height: 844),
                         CGSize(width: 844, height: 390), CGSize(width: 390, height: 844)] {
                overlay.frame.size = size; overlay.setNeedsLayout(); overlay.layoutIfNeeded()
                guard size != .zero else { continue }
                XCTAssertEqual(scroll.bounds.size, size, "The frozen canvas must occupy the same full bounds after rotation")
                XCTAssertEqual(scroll.zoomScale, zoom, accuracy: 0.001)
                XCTAssertGreaterThan(displayed.bounds.width, 0); XCTAssertGreaterThan(displayed.bounds.height, 0)
                XCTAssertTrue(displayed.image?.cgImage === image, "Rotation must retain the owned image")
                XCTAssertEqual(overlay.snapshot?.id, captured.id)
                XCTAssertGreaterThan(centerBrightness(scroll), 200, "A rotated white frame must render as white, not a black canvas")
                XCTAssertLessThanOrEqual(scroll.contentOffset.x, max(-scroll.contentInset.left, scroll.contentSize.width - size.width + scroll.contentInset.right) + 1)
            }
            if zoom > 1 {
                XCTAssertEqual(normalizedCenter(scroll).x, originalX, accuracy: 0.015, "Return to portrait must preserve the reading location")
                if scroll.contentSize.height > scroll.bounds.height {
                    XCTAssertEqual(normalizedCenter(scroll).y, originalY, accuracy: 0.015)
                }
            }
        }
        XCTAssertEqual(captures, 1); XCTAssertEqual(recognitions, 1, "Rotation must not restart expensive OCR")
    }

    func testOpeningFromZoomedLiveCanvasMapsLetterboxCenterIntoImageCoordinates() async throws {
        let image = try XCTUnwrap(SharedTextImage.materialize(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 900))))
        let captured = SharedTextSnapshot(image: image, sourceID: "screen", sourceName: "Alex")
        let canvasSize = CGSize(width: 390, height: 844), liveCenter = CGPoint(x: 0.56, y: 0.53)
        let overlay = SharedTextOverlay(sourceID: "screen", sourceName: "Alex", recognition: { _ in .transcript("") },
            initialScale: 8, initialCenter: liveCenter, initialViewportSize: canvasSize, capture: { captured })
        defer { overlay.finish() }
        overlay.frame = CGRect(origin: .zero, size: canvasSize); overlay.layoutIfNeeded()
        try await wait { overlay.snapshot != nil && !overlay.busy }
        let scroll = try XCTUnwrap(descendants(overlay).compactMap { $0 as? UIScrollView }.first {
            $0.accessibilityIdentifier == "Captured image viewport"
        })
        let fit = AVMakeRect(aspectRatio: CGSize(width: image.width, height: image.height), insideRect: CGRect(origin: .zero, size: canvasSize))
        let expected = CGPoint(x: (liveCenter.x * canvasSize.width - fit.minX) / fit.width,
            y: (liveCenter.y * canvasSize.height - fit.minY) / fit.height)
        XCTAssertEqual(scroll.zoomScale, 8, accuracy: 0.001)
        XCTAssertEqual(normalizedCenter(scroll).x, expected.x, accuracy: 0.01)
        XCTAssertEqual(normalizedCenter(scroll).y, expected.y, accuracy: 0.01,
            "The frozen image must open on the same text; normalizing against the letterboxed canvas moves the reading location")
        XCTAssertGreaterThan(centerBrightness(scroll), 200)
    }

    func testNearEdgeReadingPositionReturnsAfterTemporaryClampAndLetterboxing() async throws {
        let image = try XCTUnwrap(SharedTextImage.materialize(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 900))))
        let captured = SharedTextSnapshot(image: image, sourceID: "screen", sourceName: "Alex")
        let overlay = SharedTextOverlay(sourceID: "screen", sourceName: "Alex", recognition: { _ in .transcript("") }, capture: { captured })
        defer { overlay.finish() }
        overlay.frame = CGRect(x: 0, y: 0, width: 390, height: 844); overlay.layoutIfNeeded()
        try await wait { overlay.snapshot != nil && !overlay.busy }
        let scroll = try XCTUnwrap(descendants(overlay).compactMap { $0 as? UIScrollView }.first {
            $0.accessibilityIdentifier == "Captured image viewport"
        })
        scroll.setZoomScale(2, animated: false)
        // Right edge is a legal portrait reading location but is clamped in landscape.
        scroll.contentOffset.x = scroll.contentSize.width - scroll.bounds.width
        let portraitCenter = normalizedCenter(scroll).x
        overlay.frame.size = CGSize(width: 844, height: 390); overlay.setNeedsLayout(); overlay.layoutIfNeeded()
        XCTAssertLessThan(normalizedCenter(scroll).x, portraitCenter - 0.01)
        overlay.frame.size = CGSize(width: 390, height: 844); overlay.setNeedsLayout(); overlay.layoutIfNeeded()
        XCTAssertEqual(normalizedCenter(scroll).x, portraitCenter, accuracy: 0.01,
            "A temporary legal clamp must not overwrite the desired reading location")
        scroll.setZoomScale(8, animated: false)
        scroll.contentOffset = CGPoint(x: scroll.contentSize.width * 0.82 - scroll.bounds.width / 2,
            y: scroll.contentSize.height * 0.70 - scroll.bounds.height / 2)
        let original = normalizedCenter(scroll)
        // A very narrow/tall resizable canvas temporarily letterboxes the Y axis.
        overlay.frame.size = CGSize(width: 220, height: 2000); overlay.setNeedsLayout(); overlay.layoutIfNeeded()
        XCTAssertLessThan(scroll.contentSize.height, scroll.bounds.height)
        XCTAssertEqual(normalizedCenter(scroll).y, 0.5, accuracy: 0.01)
        overlay.frame.size = CGSize(width: 390, height: 844); overlay.setNeedsLayout(); overlay.layoutIfNeeded()
        XCTAssertEqual(normalizedCenter(scroll).x, original.x, accuracy: 0.01)
        XCTAssertEqual(normalizedCenter(scroll).y, original.y, accuracy: 0.01,
            "Temporary letterboxing must preserve the user's vertical reading location")
        XCTAssertGreaterThan(centerBrightness(scroll), 200)
    }

    func testEndedShareAndFailedRefreshRetainOwnedImageAndSelectionCanvas() async throws {
        let image = try XCTUnwrap(SharedTextImage.materialize(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600))))
        let captured = SharedTextSnapshot(image: image, sourceID: "first", sourceName: "Alex")
        var captures = 0
        let overlay = SharedTextOverlay(sourceID: "first", sourceName: "Alex", recognition: { _ in .transcript("") }, capture: {
            captures += 1; return captures == 1 ? captured : nil
        })
        defer { overlay.finish() }
        overlay.frame = CGRect(x: 0, y: 0, width: 390, height: 844); overlay.layoutIfNeeded()
        try await wait { overlay.snapshot != nil && !overlay.busy }
        let refresh = try XCTUnwrap(descendants(overlay).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "Capture current shared frame" })
        overlay.updateSource(id: nil, name: nil)
        XCTAssertFalse(refresh.isEnabled); XCTAssertEqual(overlay.snapshot?.id, captured.id)
        overlay.updateSource(id: "replacement", name: "Sam")
        XCTAssertTrue(refresh.isEnabled)
        refresh.sendActions(for: .touchUpInside)
        try await wait { captures == 2 && !overlay.busy }
        XCTAssertEqual(overlay.snapshot?.id, captured.id, "A failed refresh must not destroy the frame the user was selecting")
        let displayed = try XCTUnwrap(descendants(overlay).compactMap { $0 as? UIImageView }.first { $0.image != nil })
        XCTAssertTrue(displayed.image?.cgImage === image)
        let ownedToolIDs: Set<String> = ["Return to live share", "Capture current shared frame", "Fit captured image", "Captured share more"]
        let tools = descendants(overlay).compactMap { $0 as? UIButton }.filter { ownedToolIDs.contains($0.accessibilityIdentifier ?? "") }
        XCTAssertEqual(tools.count, 4)
        for button in tools {
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, button.accessibilityIdentifier ?? "capture tool")
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
    }

    func testNativeTextAnalysisAndSelectedRangeAreRetainedAcrossZoomedResize() async throws {
        guard #available(iOS 17, *), ImageAnalyzer.isSupported else {
            throw XCTSkip("This host does not support native Live Text; geometry/pixel rotation remains tested independently")
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
            ("Screen text selection survives rotation" as NSString).draw(at: CGPoint(x: 80, y: 300),
                withAttributes: [.font: UIFont.systemFont(ofSize: 42), .foregroundColor: UIColor.black])
        }.cgImage)
        let analyzer = ImageAnalyzer()
        let analysis = try await analyzer.analyze(image, orientation: .up, configuration: .init([.text]))
        XCTAssertTrue(analysis.hasResults(for: .text))
        let captured = SharedTextSnapshot(image: image, sourceID: "screen", sourceName: "Alex")
        let overlay = SharedTextOverlay(sourceID: "screen", sourceName: "Alex", recognition: { _ in .native(analysis) }, capture: { captured })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.isHidden = false; host.view.addSubview(overlay)
        defer { overlay.finish(); window.isHidden = true }
        overlay.frame = CGRect(x: 0, y: 0, width: 390, height: 844); overlay.layoutIfNeeded()
        try await wait { !overlay.busy && overlay.snapshot != nil }
        let displayed = try XCTUnwrap(descendants(overlay).compactMap { $0 as? UIImageView }.first { $0.image != nil })
        let interaction = try XCTUnwrap(displayed.interactions.compactMap { $0 as? ImageAnalysisInteraction }.first)
        try await wait { interaction.analysis === analysis }
        let text = interaction.text
        XCTAssertFalse(text.isEmpty)
        interaction.selectedRanges = [text.startIndex..<text.endIndex]
        let selected = interaction.selectedText
        XCTAssertFalse(selected.isEmpty)
        let scroll = try XCTUnwrap(displayed.superview as? UIScrollView)
        scroll.setZoomScale(2, animated: false)
        for size in [CGSize(width: 844, height: 390), CGSize(width: 390, height: 844)] {
            overlay.frame.size = size; overlay.setNeedsLayout(); overlay.layoutIfNeeded()
            XCTAssertTrue(interaction.analysis === analysis)
            XCTAssertEqual(interaction.selectedText, selected)
            XCTAssertEqual(overlay.snapshot?.id, captured.id)
        }
    }

    func testGuestCapturedCanvasKeepsPrimaryDockAndContextToolsReachableAcrossResize() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        var microphoneChanges = 0
        let controls = CallControls(localPreview: LocalSharePreview(), state: nil, coordinator: nil,
            router: nil, catchUp: CatchUpStore(), chat: ChatStore(), initialDisplayMode: .all,
            invitationURL: nil, roomIdentifier: "ocr-fixture", onDisplayMode: { _ in }, onFloat: {},
            onFloatingPreferenceChanged: {}, onLeave: {}, onScreenShare: { _ in },
            onMicrophoneState: { _ in microphoneChanges += 1 }, onCameraState: { _ in }, surfaceContainer: host.view)
        host.view.addSubview(controls); controls.frame = host.view.bounds
        controls.setStagePresentation(.init(target: .init(participant: "presenter", isShare: true),
            name: "White share", microphoneOn: false, watermark: nil,
            active: true, automatic: true, count: 2, browsing: false))
        defer { window.isHidden = true; previous?.makeKey() }
        window.layoutIfNeeded(); controls.layoutIfNeeded()
        let entry = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "Select shared text" })
        let access = try XCTUnwrap(descendants(window).compactMap { $0 as? MeetingAccessControls }.first)
        XCTAssertFalse(entry.isHidden)
        XCTAssertEqual(entry.convert(entry.bounds, to: window).midY, access.convert(access.bounds, to: window).midY, accuracy: 0.5)
        entry.sendActions(for: .touchUpInside)
        try await wait { descendants(window).contains { $0 is SharedTextOverlay } }
        let overlay = try XCTUnwrap(descendants(window).compactMap { $0 as? SharedTextOverlay }.first)
        defer { overlay.finish() }
        try await wait { !overlay.busy }
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390), CGSize(width: 1024, height: 768), CGSize(width: 390, height: 844)] {
            window.frame.size = size; host.view.frame = window.bounds; controls.frame = host.view.bounds
            window.setNeedsLayout(); host.view.setNeedsLayout(); controls.setNeedsLayout()
            window.layoutIfNeeded(); host.view.layoutIfNeeded(); controls.layoutIfNeeded(); overlay.layoutIfNeeded()
            let surface = try XCTUnwrap(overlay.superview)
            XCTAssertEqual(overlay.frame, surface.bounds, "Selection must replace the full live canvas")
            let buttons = descendants(window).compactMap { $0 as? UIButton }.filter {
                ["Return to live share", "Capture current shared frame", "Fit captured image", "Captured share more"].contains($0.accessibilityIdentifier ?? "") ||
                    [L("Mute microphone"), L("Unmute microphone")].contains($0.accessibilityLabel ?? "")
            }
            XCTAssertEqual(buttons.count, 5)
            for button in buttons where button.isEnabled {
                let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
                let hit = window.hitTest(point, with: nil)
                XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
                    "Captured canvas must not intercept \(button.accessibilityIdentifier ?? "tool") after resize; hit=\(String(describing: hit))")
            }
        }
        let escape = try XCTUnwrap(controls.keyCommands?.first { $0.input == UIKeyCommand.inputEscape })
        let action = try XCTUnwrap(escape.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: controls, from: escape, for: nil))
        XCTAssertNil(overlay.superview, "The meeting's real Escape shortcut must return from captured text to Live")
        XCTAssertEqual(microphoneChanges, 0, "Leaving text selection via Escape must not toggle the meeting microphone")
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func normalizedCenter(_ scroll: UIScrollView) -> CGPoint {
        CGPoint(x: (scroll.contentOffset.x + scroll.bounds.width / 2) / max(1, scroll.contentSize.width),
                y: (scroll.contentOffset.y + scroll.bounds.height / 2) / max(1, scroll.contentSize.height))
    }
    private func centerBrightness(_ view: UIView) -> Int {
        var pixels = [UInt8](repeating: 0, count: 4)
        return pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
            context.translateBy(x: -view.bounds.midX, y: -view.bounds.midY)
            view.layer.render(in: context)
            let values = raw.bindMemory(to: UInt8.self)
            return (Int(values[0]) + Int(values[1]) + Int(values[2])) / 3
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
    private func makePixels(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        return try XCTUnwrap(pixels)
    }
}
