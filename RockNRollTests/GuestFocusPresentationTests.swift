import AVFoundation
import JazzSDK
import UIKit
import XCTest
import WebRTC
@testable import RockNRoll

@MainActor
final class GuestFocusPresentationTests: XCTestCase {
    func testDirectCameraWithoutSDKViewProvidesCompanionAndFocusedCameraThroughShareEnd() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture) { fixture.window.isHidden = true; fixture.streams.reset() } }
        // Reassign the provider's camera wrapper so the presenter has no SDK
        // video source, then bind the one qualified receiver independently.
        let cameraRenderer = try XCTUnwrap(fixture.retainedViews.dropFirst(3).first)
        let reassigned = fixture.streams.makeView(model: model("observer", share: false), video: cameraRenderer)
        let factory = RTCPeerConnectionFactory()
        let track = factory.videoTrack(with: factory.videoSource(), trackId: "presenter-camera")
        fixture.streams.setPresenterCameraSource(.init(leaseToken: UUID(), participant: "presenter", track: track))
        await settle(fixture.window)
        let companion = try companion(in: fixture.window)
        let camera = try XCTUnwrap(descendants(companion).compactMap { $0 as? GuestGalleryTile }.first)
        XCTAssertEqual(camera.evidenceForTesting["directSource"] as? Bool, true)
        XCTAssertTrue(companion.isPreviewVisible)
        fixture.streams.setPin(.init(participant: "presenter", isShare: false))
        await settle(fixture.window)
        XCTAssertTrue(descendants(fixture.window).compactMap { $0 as? GuestGalleryTile }.contains {
            $0.accessibilityIdentifier == "gallery.presenter.camera" && $0.evidenceForTesting["directSource"] as? Bool == true
        })
        fixture.streams.updateParticipants(roster(sharing: false))
        await settle(fixture.window)
        XCTAssertEqual(fixture.streams.selectedTarget, .init(participant: "presenter", isShare: false))
        XCTAssertTrue(descendants(fixture.window).compactMap { $0 as? GuestGalleryTile }.contains {
            $0.accessibilityIdentifier == "gallery.presenter.camera" && !$0.isHidden &&
                $0.evidenceForTesting["directSource"] as? Bool == true
        })
        fixture.streams.setPresenterCameraSource(nil)
        await settle(fixture.window)
        XCTAssertFalse(descendants(fixture.window).compactMap { $0 as? GuestGalleryTile }.contains {
            $0.evidenceForTesting["directSource"] as? Bool == true
        })
        withExtendedLifetime(reassigned) {}
    }

    func testFirstShareFrameMovesCompanionIntoPortraitSpareAreaWithoutAnotherLayoutEvent() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture) { fixture.window.isHidden = true; fixture.streams.reset() } }
        await settle(fixture.window)
        let companion = try companion(in: fixture.window)
        let surface = try XCTUnwrap(companion.superview)
        companion.move(to: .topLeading)
        let availableTop = companion.frame.minY
        companion.move(to: .bottomTrailing)
        let availableBottom = companion.frame.maxY
        let width = 1600, height = 900
        let scale = min(surface.bounds.width / CGFloat(width), surface.bounds.height / CGFloat(height))
        let fitted = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        let shareFrame = CGRect(x: surface.bounds.midX - fitted.width / 2,
            y: surface.bounds.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
        XCTAssertGreaterThanOrEqual(max(shareFrame.minY - 8 - availableTop,
            availableBottom - shareFrame.maxY - 8), companion.bounds.height,
            "The source must leave a complete card-sized spare area inside the reserved content bounds")
        // Simulate the card's position during a drag before dimensions arrive.
        // Only the first-frame callback may snap it into the proven spare area.
        companion.frame.origin.y = shareFrame.midY - companion.bounds.height / 2
        let before = companion.frame
        XCTAssertTrue(before.intersects(shareFrame), "The initial card must exercise a relocation")
        fixture.controls.showStageFrame(try sample(width: width, height: height), rotation: 0)
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        XCTAssertFalse(companion.frame.intersects(shareFrame), "First-frame dimensions must place the card outside shared content")
        XCTAssertNotEqual(companion.frame, before)
        XCTAssertTrue(surface.bounds.contains(companion.frame))
        attach(fixture.window, name: "Guest Focus portrait with presenter companion")

        fixture.window.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        fixture.window.rootViewController?.view.frame = fixture.window.bounds
        fixture.controls.frame = fixture.window.bounds
        await settle(fixture.window)
        XCTAssertTrue(surface.bounds.contains(companion.frame))
        XCTAssertTrue(companion.isPreviewVisible)
        attach(fixture.window, name: "Guest Focus landscape with presenter companion")
    }

    func testShareReconnectAndExplicitCameraRoundTripPreserveViewportAndSourceIdentity() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture) { fixture.window.isHidden = true; fixture.streams.reset() } }
        await settle(fixture.window)
        let companion = try companion(in: fixture.window)
        XCTAssertTrue(companion.isPreviewVisible)
        XCTAssertNotNil(descendants(companion).first { $0.accessibilityIdentifier == "gallery.presenter.camera" })
        XCTAssertNil(descendants(companion).first { $0.accessibilityIdentifier == "gallery.observer.camera" })
        let original = try stageViewport(in: fixture.window)
        let scroll = try XCTUnwrap(original.subviews.compactMap { $0 as? UIScrollView }.first)
        scroll.setZoomScale(2.5, animated: false)
        scroll.contentOffset = CGPoint(x: 100, y: 120)
        let offset = scroll.contentOffset
        companion.move(to: .topLeading)

        // The SDK has reused the share renderer for another camera. The meeting
        // still signals the same share, so the stage must wait for its pixels.
        let reassigned = fixture.streams.makeView(model: model("observer", share: false),
                                                  video: fixture.shareRenderer)
        await settle(fixture.window)
        XCTAssertEqual(fixture.streams.selectedTarget, .init(participant: "presenter", isShare: true))
        XCTAssertTrue(try stageViewport(in: fixture.window) === original)
        XCTAssertEqual(original.zoomScale, 2.5)
        XCTAssertEqual(scroll.contentOffset, offset)
        XCTAssertTrue(descendants(fixture.window).compactMap { $0 as? UILabel }.contains {
            $0.text == L("Reconnecting to shared screen…") && !$0.isHidden
        })
        XCTAssertEqual(companion.corner, .topLeading)

        var selections: [GuestStreamViews.PinTarget] = []
        let streams = fixture.streams
        fixture.controls.onPinParticipant = { target in
            if let target { selections.append(target) }
            streams.setPin(target)
        }
        let menu = try button("presenter.companion.focus", in: companion)
        XCTAssertTrue(menu.showsMenuAsPrimaryAction)
        menu.sendActions(for: .touchUpInside)
        companion.onMenuVisibilityChanged?(true)
        companion.onMenuVisibilityChanged?(false)
        await settle(fixture.window)
        XCTAssertTrue(selections.isEmpty, "Opening or dismissing the preview menu cannot focus a camera")
        XCTAssertEqual(fixture.streams.selectedTarget, .init(participant: "presenter", isShare: true))

        let focus = try XCTUnwrap(companion.menuActions().compactMap { $0 as? UIAction }.first {
            $0.identifier.rawValue == "presenter.companion.focus"
        })
        UIButton(primaryAction: focus).sendActions(for: .touchUpInside)
        await settle(fixture.window)
        XCTAssertEqual(fixture.streams.selectedTarget, .init(participant: "presenter", isShare: false))
        XCTAssertFalse(companion.isPreviewVisible)
        let back = try button("presenter.companion.return", in: companion)
        XCTAssertTrue(isVisible(back))
        back.sendActions(for: .touchUpInside)
        await settle(fixture.window)
        XCTAssertEqual(selections, [.init(participant: "presenter", isShare: false),
                                    .init(participant: "presenter", isShare: true)])
        XCTAssertEqual(fixture.streams.selectedTarget, .init(participant: "presenter", isShare: true))
        let restored = try stageViewport(in: fixture.window)
        XCTAssertEqual(restored.zoomScale, 2.5)
        let restoredScroll = try XCTUnwrap(restored.subviews.compactMap { $0 as? UIScrollView }.first)
        XCTAssertEqual(restoredScroll.contentOffset.x, offset.x, accuracy: 0.1)
        XCTAssertEqual(restoredScroll.contentOffset.y, offset.y, accuracy: 0.1)
        XCTAssertEqual(companion.corner, .topLeading)
        withExtendedLifetime(reassigned) {}
    }

    func testCompanionPreviewDemandStopsWhenCollapsedHiddenOrHeld() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture) { fixture.window.isHidden = true; fixture.streams.reset() } }
        await settle(fixture.window)
        let companion = try companion(in: fixture.window)
        let preview = try XCTUnwrap(descendants(companion).compactMap { $0 as? GuestGalleryTile }.first)
        XCTAssertEqual(preview.evidenceForTesting["visible"] as? Bool, true)
        try button("presenter.companion.hide", in: companion).sendActions(for: .touchUpInside)
        XCTAssertTrue(companion.isCollapsed)
        XCTAssertFalse(companion.isPreviewVisible)
        XCTAssertEqual(preview.evidenceForTesting["visible"] as? Bool, false)
        try button("presenter.companion.show", in: companion).sendActions(for: .touchUpInside)
        XCTAssertTrue(companion.isPreviewVisible)
        XCTAssertEqual(preview.evidenceForTesting["visible"] as? Bool, true)

        fixture.layout.layout.selectedSegmentIndex = 0
        fixture.layout.layout.sendActions(for: .valueChanged)
        await settle(fixture.window)
        XCTAssertTrue(companion.isHidden)
        XCTAssertFalse(companion.isPreviewVisible)
        XCTAssertEqual(preview.evidenceForTesting["visible"] as? Bool, false)
        fixture.layout.layout.selectedSegmentIndex = 1
        fixture.layout.layout.sendActions(for: .valueChanged)
        await settle(fixture.window)
        XCTAssertTrue(companion.isPreviewVisible)

        fixture.controls.setHeld(true)
        await settle(fixture.window)
        XCTAssertTrue(companion.isHidden)
        XCTAssertFalse(companion.isPreviewVisible)
        XCTAssertEqual(preview.evidenceForTesting["visible"] as? Bool, false)
        fixture.controls.setHeld(false)
        await settle(fixture.window)
        XCTAssertTrue(companion.isPreviewVisible)
        XCTAssertEqual(preview.evidenceForTesting["visible"] as? Bool, true)
        XCTAssertNil(fixture.streams.pinnedTarget)
    }

    func testAudioOnlyNeverRequestsPresenterPreviewOrStageFrames() async throws {
        let fixture = try makeFixture(displayMode: .audioOnly)
        defer { withExtendedLifetime(fixture) { fixture.window.isHidden = true; fixture.streams.reset() } }
        await settle(fixture.window)
        let companion = try companion(in: fixture.window)
        XCTAssertTrue(companion.isHidden)
        XCTAssertFalse(companion.isPreviewVisible)
        for preview in descendants(companion).compactMap({ $0 as? GuestGalleryTile }) {
            XCTAssertEqual(preview.evidenceForTesting["visible"] as? Bool, false)
        }
        XCTAssertNil(fixture.controls.makeStageFrameDelivery(mirrored: false))
        XCTAssertNil(fixture.streams.pinnedTarget)
    }

    func testConfirmedShareEndRetiresReturnShortcutDuringCameraFocus() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture) { fixture.window.isHidden = true; fixture.streams.reset() } }
        await settle(fixture.window)
        let companion = try companion(in: fixture.window)
        companion.onFocusCamera?()
        await settle(fixture.window)
        XCTAssertTrue(isVisible(try button("presenter.companion.return", in: companion)))
        let ended = roster(sharing: false)
        fixture.controls.updateParticipantRoster(ended, speaking: nil)
        fixture.streams.updateParticipants(ended)
        await settle(fixture.window)
        XCTAssertTrue(companion.isHidden)
        XCTAssertFalse(companion.isPreviewVisible)
        XCTAssertFalse(descendants(companion).contains {
            $0.accessibilityIdentifier == "presenter.companion.return" && isVisible($0)
        })
    }

    func testPinnedShareEndingKeepsFocusLayout() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture) { fixture.window.isHidden = true; fixture.streams.reset() } }
        await settle(fixture.window)
        fixture.streams.setPin(.init(participant: "presenter", isShare: true))
        await settle(fixture.window)
        XCTAssertEqual(fixture.layout.layout.selectedSegmentIndex, 1)
        let ended = roster(sharing: false)
        fixture.controls.updateParticipantRoster(ended, speaking: nil)
        fixture.streams.updateParticipants(ended)
        await settle(fixture.window)
        XCTAssertNil(fixture.streams.pinnedTarget)
        XCTAssertEqual(fixture.layout.layout.selectedSegmentIndex, 1)
        XCTAssertFalse(descendants(fixture.window).contains { $0 is GuestGalleryView && isVisible($0) })
    }

    func testRecreatedControlsRestoreShareZoomCompanionPreferencesAndCameraReturn() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture) { fixture.window.isHidden = true; fixture.streams.reset() } }
        await settle(fixture.window)
        let originalCompanion = try companion(in: fixture.window)
        let originalViewport = try stageViewport(in: fixture.window)
        let scroll = try XCTUnwrap(originalViewport.subviews.compactMap { $0 as? UIScrollView }.first)
        scroll.setZoomScale(2.5, animated: false)
        scroll.contentOffset = CGPoint(x: 100, y: 120)
        let offset = scroll.contentOffset
        originalCompanion.move(to: .topLeading)
        originalCompanion.setCollapsed(true)
        originalCompanion.onFocusCamera?()
        await settle(fixture.window)
        XCTAssertEqual(fixture.streams.focusState.returnToShare, .init(participant: "presenter", isShare: true))
        fixture.controls.removeFromSuperview()

        let host = try XCTUnwrap(fixture.window.rootViewController)
        let replacement = makeControls(in: host, streams: fixture.streams, displayMode: .all)
        replacement.updateParticipantRoster(roster(sharing: true), speaking: nil)
        replacement.setWaitingForOthers(false)
        await settle(fixture.window)
        let restoredCompanion = try companion(in: fixture.window)
        XCTAssertFalse(restoredCompanion === originalCompanion)
        XCTAssertEqual(restoredCompanion.corner, .topLeading)
        XCTAssertTrue(restoredCompanion.isCollapsed)
        let back = try button("presenter.companion.return", in: restoredCompanion)
        XCTAssertTrue(isVisible(back))
        back.sendActions(for: .touchUpInside)
        await settle(fixture.window)
        XCTAssertEqual(fixture.streams.selectedTarget, .init(participant: "presenter", isShare: true))
        let restoredViewport = try stageViewport(in: fixture.window)
        XCTAssertFalse(restoredViewport === originalViewport)
        XCTAssertEqual(restoredViewport.zoomScale, 2.5)
        let restoredScroll = try XCTUnwrap(restoredViewport.subviews.compactMap { $0 as? UIScrollView }.first)
        XCTAssertEqual(restoredScroll.contentOffset.x, offset.x, accuracy: 0.1)
        XCTAssertEqual(restoredScroll.contentOffset.y, offset.y, accuracy: 0.1)
        XCTAssertTrue(restoredCompanion.isCollapsed)
        XCTAssertEqual(restoredCompanion.corner, .topLeading)
        try button("presenter.companion.show", in: restoredCompanion).sendActions(for: .touchUpInside)
        XCTAssertTrue(restoredCompanion.isPreviewVisible)
        withExtendedLifetime(replacement) {}
    }

    private struct Fixture {
        let window: UIWindow
        let controls: CallControls
        let streams: GuestStreamViews
        let layout: MeetingLayoutControls
        let shareRenderer: UIView
        let retainedViews: [UIView]
    }

    private func makeFixture(displayMode: ConferenceDisplayMode = .all) throws -> Fixture {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let streams = GuestStreamViews()
        let controls = makeControls(in: host, streams: streams, displayMode: displayMode)
        let shareRenderer = UIView()
        let cameraRenderer = UIView()
        let observerRenderer = UIView()
        let share = streams.makeView(model: model("presenter", share: true), video: shareRenderer)
        let camera = streams.makeView(model: model("presenter", share: false), video: cameraRenderer)
        let observer = streams.makeView(model: model("observer", share: false), video: observerRenderer)
        let participants = roster(sharing: true)
        controls.updateParticipantRoster(participants, speaking: nil)
        streams.updateParticipants(participants)
        controls.setWaitingForOthers(false)
        let layout = try XCTUnwrap(descendants(window).compactMap { $0 as? MeetingLayoutControls }.first)
        return Fixture(window: window, controls: controls, streams: streams, layout: layout,
            shareRenderer: shareRenderer, retainedViews: [share, camera, observer, cameraRenderer, observerRenderer])
    }

    private func makeControls(in host: UIViewController, streams: GuestStreamViews,
                              displayMode: ConferenceDisplayMode) -> CallControls {
        let controls = CallControls(localPreview: LocalSharePreview(), state: nil, coordinator: nil,
            router: nil, catchUp: CatchUpStore(), chat: ChatStore(), initialDisplayMode: displayMode,
            invitationURL: nil, roomIdentifier: "focus-fixture", onDisplayMode: { _ in }, onFloat: {},
            onFloatingPreferenceChanged: {}, onLeave: {}, onScreenShare: { _ in },
            onMicrophoneState: { _ in }, onCameraState: { _ in }, usesNativeParticipants: false,
            surfaceContainer: host.view)
        controls.frame = host.view.bounds
        host.view.addSubview(controls)
        controls.onPinParticipant = { streams.setPin($0) }
        controls.onAutomaticView = { streams.useAutomaticView() }
        streams.onStagePresentation = { [weak controls, weak streams] presentation in
            controls?.setStagePresentation(presentation, pinnedParticipant: streams?.pinnedTarget)
        }
        controls.bindStreams(streams)
        return controls
    }

    private func roster(sharing: Bool) -> [GuestStreamViews.Participant] {
        [.init(id: "presenter", name: "Anna", isLocal: false, microphoneOn: false, cameraOn: true, sharing: sharing),
         .init(id: "observer", name: "Boris", isLocal: false, microphoneOn: true, cameraOn: true, sharing: false)]
    }

    private func model(_ id: String, share: Bool) -> JazzParticipantViewModel {
        JazzParticipantViewModel(name: id == "presenter" ? "Anna" : "Boris", isAudioOn: false,
            isVideoOn: !share, isPinned: false, isSharingScreen: share, isLocal: false, id: id,
            isDominantSpeaker: false, shouldShowParticipantInfo: true, isZoomable: share,
            watermarkState: .hidden, displayMode: .speaker)
    }

    private func companion(in view: UIView) throws -> PresenterCompanionView {
        try XCTUnwrap(descendants(view).compactMap { $0 as? PresenterCompanionView }.first)
    }

    private func stageViewport(in view: UIView) throws -> StreamViewport {
        try XCTUnwrap(descendants(view).compactMap { $0 as? StreamViewport }.first { viewport in
            var ancestor = viewport.superview
            while let current = ancestor {
                if current is GuestGalleryTile { return false }
                ancestor = current.superview
            }
            return true
        })
    }

    private func button(_ id: String, in view: UIView) throws -> UIButton {
        try XCTUnwrap(descendants(view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == id })
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    private func isVisible(_ view: UIView) -> Bool {
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha <= 0 { return false }
            ancestor = current.superview
        }
        return view.window != nil
    }

    private func settle(_ window: UIWindow) async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            window.layoutIfNeeded()
        }
    }

    private func attach(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func sample(width: Int, height: Int) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width,
            height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.setFillColor(UIColor.systemIndigo.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(UIColor.systemTeal.cgColor)
        context.fill(CGRect(x: 32, y: 32, width: width - 64, height: max(1, height / 4)))
        context.setFillColor(UIColor.white.withAlphaComponent(0.8).cgColor)
        for row in 0..<3 {
            context.fill(CGRect(x: 48, y: height / 2 + row * 48, width: width * (4 - row) / 5, height: 16))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil,
            imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}
