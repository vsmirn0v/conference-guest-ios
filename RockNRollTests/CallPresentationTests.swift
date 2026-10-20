import AVFoundation
import ConferenceCore
import LiveKit
import LiveKitWebRTC
import SwiftUI
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class CallPresentationTests: XCTestCase {
    func testLiveGuestPortraitControlsBeforeFirstRotation() async throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_CONTROLS_INVITE"] else {
            throw XCTSkip("Opt-in SDK hierarchy check")
        }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow })
        let original = window.rootViewController, host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore())
        var active = false, ended = false
        engine.onEvent = { event in
            if event == .active { active = true }
            if [.left, .failed, .canceled, .evicted].contains(event) { ended = true }
        }
        defer { engine.leave(); window.rootViewController = original }
        let target = try JoinTarget.parse(invitation)
        try engine.configure(container: host, networkURL: await VendorEndpointResolver.make().resolve(for: target),
                             displayName: "Portrait controls QA")
        try engine.join(target: target, displayName: "Portrait controls QA")
        let deadline = Date().addingTimeInterval(45)
        while !active && !ended && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(active); XCTAssertFalse(ended)
        guard active, !ended else { return }
        try await Task.sleep(for: .seconds(2))
        let buttons = visibleMeetingButtons(in: window)
        XCTAssertEqual(buttons.count, 2)
        for button in buttons {
            let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
            let hit = window.hitTest(point, with: nil)
            var parent: UIView? = button
            while let view = parent {
                print("CONTROL_ANCESTOR \(button.accessibilityLabel ?? "") type=\(type(of: view)) frame=\(view.frame) bounds=\(view.bounds) interactive=\(view.isUserInteractionEnabled) hidden=\(view.isHidden) pointInside=\(view.point(inside: view.convert(point, from: window), with: nil))")
                parent = view.superview
            }
            XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
                "Initial portrait control must receive touches: \(button.accessibilityLabel ?? "") hit=\(String(describing: hit))")
        }
    }
    func testImmersiveStageUsesEveryPixelWhilePrivacyHeaderStaysSafe() {
        let portrait = CGRect(x: 0, y: 0, width: 440, height: 956)
        let landscape = CGRect(x: 0, y: 0, width: 956, height: 440)
        for (bounds, insets) in [(portrait, UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)),
                                 (landscape, UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62))] {
            let hidden = CallPresentationGeometry(bounds: bounds, insets: insets, headerHeight: 80, hidden: true)
            XCTAssertEqual(hidden.stage, bounds)
            XCTAssertEqual(hidden.header, .zero)
            XCTAssertEqual(hidden.toolbar, .zero)
            let privacy = CallPresentationGeometry(bounds: bounds, insets: insets, headerHeight: 80,
                hidden: true, statusOnly: true)
            XCTAssertEqual(privacy.stage.minX, bounds.minX)
            XCTAssertEqual(privacy.stage.maxX, bounds.maxX)
            XCTAssertEqual(privacy.stage.maxY, bounds.maxY)
            XCTAssertTrue(bounds.inset(by: insets).contains(privacy.header))
            XCTAssertFalse(privacy.stage.intersects(privacy.header))
        }
    }
    func testFloatingFitRemainsStableWhenControlsHide() {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 440, height: 956), CGSize(width: 956, height: 440), CGSize(width: 1200, height: 800)] {
            let bounds = CGRect(origin: .zero, size: size)
            let visible = CallPresentationGeometry(bounds: bounds, insets: .init(top: 44, left: 0, bottom: 34, right: 0), headerHeight: 80, hidden: false, floating: true)
            let hidden = CallPresentationGeometry(bounds: bounds, insets: .init(top: 44, left: 0, bottom: 34, right: 0), headerHeight: 80, hidden: true, floating: true)
            XCTAssertEqual(visible.stage, hidden.stage)
            XCTAssertFalse(visible.stage.intersects(visible.header))
            XCTAssertFalse(visible.stage.intersects(visible.toolbar))
        }
    }
    func testFullCanvasZoomKeepsImageAndOffsetWhenChromeChanges() throws {
        let renderer = UIView()
        let viewport = StreamViewport(video: renderer, state: StreamViewportState(), zoomable: true,
            name: "Share", showInfo: false, microphoneOn: false, pinned: false, watermark: nil)
        viewport.frame = CGRect(x: 0, y: 0, width: 956, height: 440)
        viewport.fittedContentRect = CGRect(x: 62, y: 48, width: 780, height: 340)
        viewport.layoutIfNeeded()
        let scroll = try XCTUnwrap(viewport.subviews.compactMap { $0 as? UIScrollView }.first)
        XCTAssertEqual(scroll.frame, viewport.bounds)
        XCTAssertEqual(renderer.frame, viewport.fittedContentRect)
        scroll.setZoomScale(2, animated: false)
        scroll.contentOffset = CGPoint(x: 340, y: 140)
        let frame = renderer.frame, offset = scroll.contentOffset
        for _ in 0..<10 {
            viewport.controlsHidden.toggle(); viewport.setNeedsLayout(); viewport.layoutIfNeeded()
            XCTAssertEqual(scroll.zoomScale, 2)
            XCTAssertEqual(scroll.contentOffset, offset)
            XCTAssertEqual(renderer.frame, frame)
        }
    }
    func testShareUsesFullCanvasWithoutFloatingZoomToolsAndKeepsAccessibleZoom() throws {
        let viewport = StreamViewport(video: UIView(), state: StreamViewportState(), zoomable: true,
            name: "Share", showInfo: false, microphoneOn: false, pinned: false, watermark: nil)
        viewport.frame = CGRect(x: 0, y: 0, width: 956, height: 440)
        viewport.layoutIfNeeded()
        XCTAssertTrue(viewport.subviews.compactMap { $0 as? UIStackView }.isEmpty)
        let scroll = try XCTUnwrap(viewport.subviews.compactMap { $0 as? UIScrollView }.first)
        XCTAssertEqual(scroll.frame, viewport.bounds)
        XCTAssertTrue(scroll.accessibilityCustomActions?.contains { $0.name == L("Zoom in") } == true)
        XCTAssertTrue(scroll.accessibilityCustomActions?.contains { $0.name == L("Fit whole share") } == true)
    }
    func testOffscreenStageRecordDoesNotAccumulateCaptionInsets() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), owner = UUID()
        let viewport = StreamViewport(video: UIView(), state: StreamViewportState(), zoomable: true,
            name: "Presenter", showInfo: true, microphoneOn: true, pinned: false, watermark: nil)
        viewport.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        window.addSubview(viewport)
        viewport.layoutIfNeeded()
        let caption = try XCTUnwrap(viewport.subviews.compactMap { $0 as? ParticipantMediaBadge }.first)
        XCTAssertFalse(caption.isHidden)
        let expected = caption.frame
        CallStageLayout.update(window: window, owner: owner,
            rect: CGRect(x: 400, y: 400, width: 320, height: 240), hidden: false, toggle: {})
        defer { CallStageLayout.remove(window: window, owner: owner) }
        for _ in 0..<10 {
            viewport.setNeedsLayout(); viewport.layoutIfNeeded()
            XCTAssertEqual(caption.frame, expected, "An offscreen SDK tile must not accumulate caption offsets")
        }
    }
    func testFilmstripUnmountsOffscreenAndHiddenPreviews() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let strip = MeetingParticipantStrip(frame: CGRect(x: 0, y: 0, width: 240, height: 92))
        window.addSubview(strip); window.isHidden = false
        defer { window.isHidden = true }
        strip.previewProvider = { _ in UIView() }
        strip.update((0..<20).map { .init(id: String($0), name: String($0), isShare: false,
            audio: .init(microphoneOn: false, speaking: false)) }, selected: nil)
        strip.layoutIfNeeded()
        XCTAssertEqual(strip.visiblePreviewIDs, Set(["0", "1", "2"]))
        strip.contentOffset.x = 1120
        XCTAssertEqual(strip.visiblePreviewIDs, Set(["10", "11", "12"]))
        strip.isHidden = true
        XCTAssertTrue(strip.visiblePreviewIDs.isEmpty)
        strip.isHidden = false
        XCTAssertEqual(strip.visiblePreviewIDs, Set(["10", "11", "12"]))
        strip.removeFromSuperview()
        XCTAssertTrue(strip.visiblePreviewIDs.isEmpty)
    }
    func testParticipantStripUpdatesOnlyChangedChipsAndKeepsActionsAndSelection() throws {
        let strip = MeetingParticipantStrip(frame: CGRect(x: 0, y: 0, width: 390, height: 46))
        var items = (0..<100).map { index in
            MeetingStripItem(id: String(index), name: "Participant \(index)", isShare: false,
                audio: .init(microphoneOn: true, speaking: false))
        }
        strip.update(items, selected: "0")
        strip.layoutIfNeeded()
        let original = Dictionary(uniqueKeysWithValues: strip.subviews.compactMap { view -> (String, UIButton)? in
            guard let button = view as? UIButton, let id = button.accessibilityIdentifier else { return nil }
            return (id, button)
        })
        let first = try XCTUnwrap(original["Focus participant.0"])
        let second = try XCTUnwrap(original["Focus participant.1"])
        let originalFrame = second.frame
        XCTAssertEqual(strip.buttonUpdateCount, 100)
        strip.update(items, selected: "0")
        XCTAssertEqual(strip.buttonUpdateCount, 100)
        items[1] = .init(id: "1", name: "Participant 1", isShare: false,
            audio: .init(microphoneOn: true, speaking: true))
        strip.update(items, selected: "0")
        XCTAssertEqual(strip.buttonUpdateCount, 101, "One speaker update must not rewrite the other 99 chips")
        XCTAssertEqual(second.configuration?.baseForegroundColor, .systemGreen)
        XCTAssertEqual(second.frame, originalFrame)
        strip.update(items, selected: "1")
        XCTAssertEqual(strip.buttonUpdateCount, 103, "Only the old and new selection need to change")
        XCTAssertFalse(first.accessibilityTraits.contains(.selected))
        XCTAssertTrue(second.accessibilityTraits.contains(.selected))
        XCTAssertEqual(second.accessibilityLabel, L("Focus %@", "Participant 1"))
        var selected: String?
        strip.onSelect = { selected = $0 }
        second.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, "1")
        items.swapAt(0, 1)
        strip.update(items, selected: "1"); strip.layoutIfNeeded()
        XCTAssertEqual(strip.buttonUpdateCount, 103, "Reordering retains the controls and their content")
        XCTAssertEqual(second.frame.minX, 0)
        XCTAssertEqual(first.frame.minX, 112)
        for button in strip.subviews.compactMap({ $0 as? UIButton }) {
            XCTAssertTrue(original[button.accessibilityIdentifier ?? ""] === button)
        }
        items.removeLast()
        strip.update(items, selected: "1")
        XCTAssertNil(original["Focus participant.99"]?.superview)
        XCTAssertEqual(strip.buttonUpdateCount, 103)
    }

    func testNativeThumbnailRetiresStoppedCameraAndRebindsNewSource() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let call = RockCallViewController(title: "Meeting", catchUp: CatchUpStore(), chat: ChatStore())
        window.rootViewController = call; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let factory = try NativeRTCPeer.makeFactory()
        let first = factory.videoTrack(with: factory.videoSource(), trackId: "first")
        let replacement = factory.videoTrack(with: factory.videoSource(), trackId: "replacement")
        func render(_ track: LKRTCVideoTrack?) {
            call.render(snapshot: .init(participants: [
                .init(id: "focus", name: "Focus", isLocal: false, microphoneOn: false, cameraOn: false, screenShareOn: false, isSpeaking: false, videoTracks: []),
                .init(id: "other", name: "Other", isLocal: false, microphoneOn: false, cameraOn: track != nil, screenShareOn: false, isSpeaking: false,
                    videoTracks: track.map { [.init(id: $0.trackId, source: .camera, track: .native($0))] } ?? [])]))
            call.view.layoutIfNeeded()
        }
        render(first)
        let strip = try XCTUnwrap(descendants(call.view).compactMap { $0 as? MeetingParticipantStrip }.first)
        strip.onSelect?("focus.camera"); call.view.layoutIfNeeded(); strip.layoutIfNeeded()
        await settleUI()
        let old = try XCTUnwrap(descendants(strip).compactMap { $0 as? CallVideoView }.first)
        XCTAssertEqual(old.track?.identity, CallVideoSource.native(first).identity)
        render(nil); await settleUI()
        XCTAssertNil(old.track)
        XCTAssertNil(old.window)
        render(replacement); strip.layoutIfNeeded(); await settleUI()
        let next = try XCTUnwrap(descendants(strip).compactMap { $0 as? CallVideoView }.first)
        XCTAssertEqual(next.track?.identity, CallVideoSource.native(replacement).identity)
    }
    func testNativeSwipesStartAtCameraOffSelectionAndResetAfterStripSelection() throws {
        let call = RockCallViewController(title: "Meeting", catchUp: CatchUpStore(), chat: ChatStore())
        call.loadViewIfNeeded()
        call.render(snapshot: .init(participants: (0..<6).map {
            .init(id: "p\($0)", name: "Person \($0)", isLocal: false, microphoneOn: false,
                  cameraOn: false, screenShareOn: false, isSpeaking: false, videoTracks: [])
        }))
        let strip = try XCTUnwrap(descendants(call.view).compactMap { $0 as? MeetingParticipantStrip }.first)
        strip.onSelect?("p3.camera")
        XCTAssertEqual(focusedName(call.view), "Person 3")
        let swipe = UISwipeGestureRecognizer(); swipe.direction = .left
        call.perform(NSSelectorFromString("swipedStage:"), with: swipe)
        XCTAssertEqual(focusedName(call.view), "Person 4")
        strip.onSelect?("p1.camera")
        call.perform(NSSelectorFromString("swipedStage:"), with: swipe)
        XCTAssertEqual(focusedName(call.view), "Person 2")
        let layout = try XCTUnwrap(descendants(call.view).compactMap { $0 as? MeetingLayoutControls }.first)
        layout.onAutomatic?()
        XCTAssertEqual(focusedName(call.view), "Person 0", "Following speaker must clear the browsing cursor")
    }

    func testNativeScreenOnlyDiscardsCameraSelectionAndShowsAvailableShare() throws {
        let factory = try NativeRTCPeer.makeFactory()
        let source = factory.videoSource()
        let camera = factory.videoTrack(with: source, trackId: "camera")
        let share = factory.videoTrack(with: source, trackId: "share")
        let call = RockCallViewController(title: "Meeting", catchUp: CatchUpStore(), chat: ChatStore())
        call.loadViewIfNeeded()
        call.render(snapshot: .init(participants: [
            .init(id: "camera", name: "Camera owner", isLocal: false, microphoneOn: false,
                  cameraOn: true, screenShareOn: false, isSpeaking: false,
                  videoTracks: [.init(id: "camera-stream", source: .camera, track: .native(camera))]),
            .init(id: "presenter", name: "Presenter", isLocal: false, microphoneOn: true,
                  cameraOn: false, screenShareOn: true, isSpeaking: false,
                  videoTracks: [.init(id: "share-stream", source: .screenShareVideo, track: .native(share))])
        ]))
        let strip = try XCTUnwrap(descendants(call.view).compactMap { $0 as? MeetingParticipantStrip }.first)
        strip.onSelect?("camera.camera")
        call.setDisplayMode(.screenShares)
        XCTAssertTrue(descendants(call.view).contains { $0.accessibilityIdentifier == "share-stream" })
        XCTAssertFalse(descendants(call.view).contains { $0.accessibilityIdentifier == "camera-stream" })
        let layout = try XCTUnwrap(descendants(call.view).compactMap { $0 as? MeetingLayoutControls }.first)
        call.view.layoutIfNeeded()
        XCTAssertFalse(layout.automatic.isEnabled, "An excluded camera must not remain a manual selection")
        strip.onSelect?("presenter.screen")
        call.setDisplayMode(.screenShares)
        XCTAssertTrue(descendants(call.view).contains { $0.accessibilityIdentifier == "share-stream" })
    }

    func testGuestBrowsingEnablesFollowSpeakerAndRestoresAutomaticSelection() async throws {
        let (window, controls, streams, layout) = try guestLayout()
        defer { window.isHidden = true; streams.reset() }
        controls.updateParticipantRoster(guestRoster, speaking: nil)
        streams.updateParticipants(guestRoster)
        await settleUI()
        layout.layout.selectedSegmentIndex = 1; layout.layout.sendActions(for: .valueChanged)
        streams.browse(1)
        await settleUI()
        XCTAssertTrue(layout.automatic.isEnabled)
        XCTAssertEqual(layout.automatic.configuration?.title, L("Follow speaker"))
        XCTAssertEqual(focusedName(window), "Boris")
        layout.automatic.sendActions(for: .touchUpInside)
        await settleUI()
        XCTAssertFalse(layout.automatic.isEnabled)
        XCTAssertEqual(focusedName(window), "Anna")
    }

    func testGuestViewShareEntersFocusFromExplicitGalleryAndLatePinCannotUndoGallery() async throws {
        let (window, controls, streams, layout) = try guestLayout()
        defer { window.isHidden = true; streams.reset() }
        let roster = guestRoster.map {
            GuestStreamViews.Participant(id: $0.id, name: $0.name, isLocal: $0.isLocal,
                microphoneOn: $0.microphoneOn, cameraOn: $0.cameraOn, sharing: $0.id == "b")
        }
        controls.updateParticipantRoster(roster, speaking: nil)
        streams.updateParticipants(roster)
        await settleUI()
        let strip = try XCTUnwrap(descendants(window).compactMap { $0 as? MeetingParticipantStrip }.first)
        strip.onSelect?("a.camera")
        await settleUI()
        layout.layout.selectedSegmentIndex = 0; layout.layout.sendActions(for: .valueChanged)
        controls.setShareOffer(name: "Boris")
        controls.onViewShare = { streams.setPin(.init(participant: "b", isShare: true)) }
        let viewShare = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }.first {
            $0.accessibilityLabel == L("View %@ screen share", "Boris")
        })
        var ancestor: UIView? = viewShare
        while let view = ancestor { XCTAssertFalse(view.isHidden, "The share shortcut must be reachable in Gallery"); ancestor = view.superview }
        window.layoutIfNeeded()
        let point = viewShare.convert(CGPoint(x: viewShare.bounds.midX, y: viewShare.bounds.midY), to: window)
        var hit = window.hitTest(point, with: nil)
        while hit != nil && hit !== viewShare { hit = hit?.superview }
        XCTAssertTrue(hit === viewShare, "Gallery cards must not cover the share shortcut")
        viewShare.sendActions(for: .touchUpInside)
        XCTAssertEqual(layout.layout.selectedSegmentIndex, 1, "View share must enter Focus before async publication")
        await settleUI()
        XCTAssertEqual(streams.pinnedTarget, .init(participant: "b", isShare: true))
        XCTAssertEqual(layout.layout.selectedSegmentIndex, 1)

        strip.onSelect?("a.camera")
        layout.layout.selectedSegmentIndex = 0; layout.layout.sendActions(for: .valueChanged)
        await settleUI()
        XCTAssertEqual(layout.layout.selectedSegmentIndex, 0, "A late pin result must preserve the newer Gallery choice")
    }

    func testGuestGalleryKeepsLayoutAndPaginationWhileShareRemainsSelected() async throws {
        let (window, controls, streams, layout) = try guestLayout()
        defer { window.isHidden = true; streams.reset() }
        let roster = (0..<20).map {
            GuestStreamViews.Participant(id: "person-\($0)", name: "Participant \($0)", isLocal: false,
                microphoneOn: false, cameraOn: false, sharing: $0 == 0)
        }
        controls.updateParticipantRoster(roster, speaking: nil)
        streams.updateParticipants(roster)
        await settleUI()
        window.layoutIfNeeded()
        let share = GuestStreamViews.PinTarget(participant: "person-0", isShare: true)
        let gallery = try XCTUnwrap(descendants(window).compactMap { $0 as? GuestGalleryView }.first)
        let picker = try XCTUnwrap(descendants(layout).compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "Meeting view picker"
        })
        let source = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "Shared stream selector"
        })
        XCTAssertEqual(streams.selectedTarget, share)
        XCTAssertTrue(layout.isHidden)
        XCTAssertTrue(source.isHidden, "One share does not need a duplicate source selector")

        layout.layout.selectedSegmentIndex = 0; layout.layout.sendActions(for: .valueChanged)
        window.layoutIfNeeded(); gallery.layoutIfNeeded(); layout.layoutIfNeeded()
        XCTAssertFalse(gallery.isHidden)
        let header = try XCTUnwrap(descendants(window).compactMap { $0 as? CompactCallHeader }.first)
        XCTAssertEqual(header.focus.accessibilityLabel, L("Hide controls"), "Gallery must never scale its hidden stage")
        XCTAssertFalse(layout.isHidden, "An available share must not hide explicit Gallery controls")
        XCTAssertFalse(picker.isHidden)
        XCTAssertFalse(layout.nextPage.isHidden)
        XCTAssertTrue(layout.nextPage.isEnabled)
        XCTAssertTrue(source.isHidden, "Gallery must show the layout picker instead of the share source selector")
        for button in [picker, layout.nextPage] {
            let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
            var hit = window.hitTest(point, with: nil)
            while hit != nil && hit !== button { hit = hit?.superview }
            XCTAssertTrue(hit === button, "Gallery picker and pagination must be reachable")
        }
        let page = gallery.page
        layout.nextPage.sendActions(for: .touchUpInside)
        XCTAssertEqual(gallery.page, page + 1)

        layout.layout.selectedSegmentIndex = 1; layout.layout.sendActions(for: .valueChanged)
        window.layoutIfNeeded()
        XCTAssertTrue(gallery.isHidden)
        XCTAssertTrue(layout.isHidden, "Share Focus uses one source selector")
        XCTAssertTrue(source.isHidden, "One share does not need a duplicate source selector")
        XCTAssertEqual(streams.selectedTarget, share)
    }

    private var guestRoster: [GuestStreamViews.Participant] {
        ["Anna", "Boris", "Clara"].enumerated().map {
            .init(id: String(UnicodeScalar(97 + $0.offset)!), name: $0.element, isLocal: false,
                  microphoneOn: false, cameraOn: false, sharing: false)
        }
    }

    func testGuestControlsStayHittableAfterSDKHostFinishesPortraitLayout() async throws {
        let (window, controls, streams, _) = try guestLayout()
        defer { window.isHidden = true; streams.reset() }
        let root = try XCTUnwrap(window.rootViewController?.view)
        let sdkHost = UIView(frame: root.bounds)
        root.addSubview(sdkHost)
        controls.removeFromSuperview()
        controls.frame = .zero
        sdkHost.addSubview(controls)
        window.layoutIfNeeded()
        // SDK overlay hosts can first fill the window, then settle inside its
        // safe area without changing the zero-sized custom controls view.
        sdkHost.frame = root.bounds.inset(by: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0))
        sdkHost.clipsToBounds = true
        window.layoutIfNeeded()
        await settleUI()
        let buttons = visibleMeetingButtons(in: window)
        XCTAssertEqual(buttons.count, 2)
        for button in buttons {
            let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
            let hit = window.hitTest(point, with: nil)
            XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
                "\(button.accessibilityLabel ?? "control") must receive touches before the first rotation; hit=\(String(describing: hit))")
        }
    }

    func testOwnedGuestSurfaceEscapesSwiftUIHitTestingAndUnmountsWithOverlay() async throws {
        let (window, controls, streams, _) = try guestLayout(ownedSurface: true)
        defer { window.isHidden = true; streams.reset() }
        let root = try XCTUnwrap(window.rootViewController)
        controls.removeFromSuperview()
        let sdk = UIHostingController(rootView: GuestOverlayForTesting(controls: controls))
        root.addChild(sdk); sdk.view.frame = root.view.bounds
        root.view.addSubview(sdk.view); sdk.didMove(toParent: root)
        window.layoutIfNeeded(); await settleUI()
        let surface = try XCTUnwrap(descendants(window).compactMap { $0 as? CallChromeSurface }.first)
        XCTAssertTrue(surface.superview === root.view, "The SDK hosting view must not own our interactive surface")
        let buttons = visibleMeetingButtons(in: window)
        XCTAssertEqual(buttons.count, 2)
        for button in buttons {
            let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
            let hit = window.hitTest(point, with: nil)
            XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true)
        }
        sdk.willMove(toParent: nil); sdk.view.removeFromSuperview(); sdk.removeFromParent()
        XCTAssertNil(surface.superview, "A detached SDK overlay must not leave controls blocking the home page")
    }

    private struct GuestOverlayForTesting: UIViewRepresentable {
        let controls: CallControls
        func makeUIView(context: Context) -> CallControls { controls }
        func updateUIView(_ uiView: CallControls, context: Context) {}
    }

    private func guestLayout(ownedSurface: Bool = false) throws -> (UIWindow, CallControls, GuestStreamViews, MeetingLayoutControls) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.isHidden = false
        let controls = CallControls(localPreview: LocalSharePreview(), state: nil, coordinator: nil,
            router: nil, catchUp: CatchUpStore(), chat: ChatStore(), initialDisplayMode: .all,
            invitationURL: nil, roomIdentifier: "fixture", onDisplayMode: { _ in }, onFloat: {},
            onFloatingPreferenceChanged: {}, onLeave: {}, onScreenShare: { _ in },
            onMicrophoneState: { _ in }, onCameraState: { _ in }, surfaceContainer: ownedSurface ? host.view : nil)
        controls.frame = host.view.bounds; host.view.addSubview(controls)
        let streams = GuestStreamViews()
        controls.onPinParticipant = { streams.setPin($0) }
        controls.onAutomaticView = { streams.useAutomaticView() }
        streams.onStagePresentation = { [weak controls, weak streams] presentation in
            controls?.setStagePresentation(presentation, pinnedParticipant: streams?.pinnedTarget)
        }
        controls.bindStreams(streams)
        let layout = try XCTUnwrap(descendants(window).compactMap { $0 as? MeetingLayoutControls }.first)
        return (window, controls, streams, layout)
    }
    private func settleUI() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func visibleMeetingButtons(in view: UIView) -> [UIButton] {
        descendants(view).compactMap { $0 as? UIButton }.filter { button in
            guard button.accessibilityLabel?.hasPrefix(L("Musicians")) == true || button.accessibilityLabel == L("Leave") else { return false }
            var ancestor: UIView? = button
            while let current = ancestor {
                if current.isHidden || current.alpha < 0.01 { return false }
                ancestor = current.superview
            }
            return true
        }
    }
    private func focusedName(_ view: UIView) -> String? {
        descendants(view).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "Participant name" }?.text
    }

    func testFocusHintWrapsAtAStableBoundedWidthAfterResize() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        let focus = CallFocusController()
        focus.installHint(in: view)
        let hint = try XCTUnwrap(view.subviews.first as? UIStackView)
        let label = try XCTUnwrap(hint.arrangedSubviews.first as? UILabel)
        label.adjustsFontForContentSizeCategory = false
        label.font = .preferredFont(forTextStyle: .callout,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        for size in [CGSize(width: 375, height: 667), CGSize(width: 667, height: 375), CGSize(width: 375, height: 667)] {
            view.frame.size = size; view.layoutIfNeeded()
            XCTAssertEqual(hint.bounds.width, min(420, size.width - 32), accuracy: 1)
            XCTAssertLessThanOrEqual(label.frame.maxX, hint.bounds.width)
            XCTAssertGreaterThan(hint.bounds.height, 20)
            XCTAssertLessThanOrEqual(label.frame.maxY, hint.bounds.height)
        }
    }
    func testStageNeverIntersectsChromeAcrossCompactAndLargeWindows() {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667),
                     CGSize(width: 667, height: 375), CGSize(width: 812, height: 375),
                     CGSize(width: 744, height: 1133), CGSize(width: 1280, height: 800)] {
            for large in [false, true] {
                let bounds = CGRect(origin: .zero, size: size)
                let geometry = CallPresentationGeometry(bounds: bounds, insets: .init(top: 20, left: 0, bottom: 0, right: 0),
                    headerHeight: large ? 106 : 80, toolbarHeight: large ? 148 : 68, hidden: false, largeText: large)
                XCTAssertFalse(geometry.stage.intersects(geometry.header))
                XCTAssertFalse(geometry.stage.intersects(geometry.toolbar))
                XCTAssertTrue(bounds.contains(geometry.stage))
                XCTAssertTrue(bounds.contains(geometry.toolbar))
                XCTAssertGreaterThan(geometry.stage.height, 40)
            }
        }
    }
    func testLandscapeRailAndFocusExpandTheSameStage() {
        let bounds = CGRect(x: 0, y: 0, width: 667, height: 375)
        let visible = CallPresentationGeometry(bounds: bounds, insets: .zero, headerHeight: 80, hidden: false)
        let hidden = CallPresentationGeometry(bounds: bounds, insets: .zero, headerHeight: 80, hidden: true)
        XCTAssertTrue(visible.rail)
        XCTAssertTrue(hidden.header.isEmpty)
        XCTAssertTrue(hidden.toolbar.isEmpty)
        XCTAssertTrue(hidden.stage.contains(visible.stage))
    }
    func testToolbarTargetsStayAtLeast44PointsWithLargeTextAndRail() {
        let buttons = (0..<6).map { _ in AlignedCallButton(frame: .zero) }
        let toolbar = CallToolbar(items: buttons)
        for (size, rail, large) in [(CGSize(width: 304, height: 68), false, false),
                                    (CGSize(width: 56, height: 347), true, false),
                                    (CGSize(width: 304, height: 148), false, true)] {
            toolbar.frame = CGRect(origin: .zero, size: size)
            toolbar.arrange(rail: rail, largeText: large)
            toolbar.layoutIfNeeded()
            for button in buttons {
                XCTAssertGreaterThanOrEqual(button.bounds.width, 44)
                XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
                XCTAssertTrue(toolbar.bounds.contains(button.frame))
                XCTAssertEqual(button.showsCaption, !rail || large)
            }
        }
    }
    func testSmallWindowLargestTextChromeKeepsMediaAndSingleLineCaptions() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Per-view text trait overrides require iOS 17") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let titles = ["Mic", "Video", "Share", "Audio", "Reactions", "Leave"]
        let buttons = titles.map { title in
            let button = AlignedCallButton(frame: .zero)
            button.configuration = .plain(); button.configuration?.title = title
            button.configuration?.image = UIImage(systemName: "circle")
            button.accessibilityLabel = title
            return button
        }
        let toolbar = CallToolbar(items: buttons)
        host.view.addSubview(toolbar)
        window.layoutIfNeeded()
        XCTAssertEqual(toolbar.traitCollection.preferredContentSizeCategory, .accessibilityExtraExtraExtraLarge)
        toolbar.arrange(rail: false, largeText: true)
        XCTAssertLessThanOrEqual(toolbar.preferredHeight, 214)
        toolbar.frame = CGRect(x: 0, y: 0, width: 359, height: toolbar.preferredHeight)
        toolbar.layoutIfNeeded()
        for (button, title) in zip(buttons, titles) {
            XCTAssertEqual(button.traitCollection.preferredContentSizeCategory, .accessibilityExtraExtraExtraLarge)
            button.setNeedsLayout(); button.layoutIfNeeded()
            let caption = try XCTUnwrap(button.subviews.compactMap { $0 as? UILabel }.first { !$0.isHidden && $0.text == title })
            XCTAssertEqual(caption.numberOfLines, 1)
            if ProcessInfo.processInfo.isiOSAppOnMac {
                // Designed for iPad on Mac can keep UIFontMetrics at its base size.
                XCTAssertGreaterThanOrEqual(caption.font.pointSize, 12)
            } else {
                XCTAssertGreaterThan(caption.font.pointSize, 12)
            }
            XCTAssertLessThanOrEqual(caption.font.pointSize, 18)
            XCTAssertLessThanOrEqual(caption.bounds.height, 24)
            XCTAssertTrue(button.bounds.contains(caption.frame))
            XCTAssertGreaterThanOrEqual(button.bounds.width, 44)
            XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
            XCTAssertEqual(button.accessibilityLabel, title)
        }
        let bounds = CGRect(x: 0, y: 0, width: 375, height: 667)
        let visible = CallPresentationGeometry(bounds: bounds, insets: .init(top: 20, left: 0, bottom: 0, right: 0),
            headerHeight: 240, toolbarHeight: toolbar.preferredHeight, hidden: false, largeText: true, floating: true)
        let hidden = CallPresentationGeometry(bounds: bounds, insets: .init(top: 20, left: 0, bottom: 0, right: 0),
            headerHeight: 240, toolbarHeight: toolbar.preferredHeight, hidden: true, largeText: true, floating: true)
        XCTAssertTrue(visible.compactHeader)
        XCTAssertEqual(visible.header.height, 44)
        XCTAssertGreaterThan(visible.stage.height, 300)
        XCTAssertEqual(visible.stage, hidden.stage)
        XCTAssertFalse(visible.header.intersects(visible.toolbar))
        window.traitOverrides.preferredContentSizeCategory = .large
        window.layoutIfNeeded()
        toolbar.arrange(rail: false, largeText: false)
        toolbar.frame.size = CGSize(width: 359, height: toolbar.preferredHeight)
        toolbar.layoutIfNeeded(); buttons[4].layoutIfNeeded()
        let caption = try XCTUnwrap(buttons[4].subviews.compactMap { $0 as? UILabel }.first { !$0.isHidden && $0.text == "Reactions" })
        XCTAssertTrue(caption.adjustsFontSizeToFitWidth)
        let wordWidth = ("Reactions" as NSString).size(withAttributes: [.font: caption.font!]).width
        XCTAssertLessThanOrEqual(wordWidth * caption.minimumScaleFactor, caption.bounds.width)
    }
    func testLargestTextSourceSymbolsAndHeaderStayInsideCompactRows() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Per-view text trait overrides require iOS 17") }
        let (window, controls, _, _) = try guestLayout()
        defer { window.isHidden = true }
        window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        controls.setStagePresentation(.init(target: .init(participant: "presenter", isShare: true),
            name: "Shared source with full identity", microphoneOn: true, watermark: nil,
            active: true, automatic: true, count: 2, browsing: false))
        window.layoutIfNeeded(); controls.layoutIfNeeded()
        let guest = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "Shared stream selector" })
        let scene = try XCTUnwrap(window.windowScene)
        let nativeWindow = UIWindow(windowScene: scene)
        nativeWindow.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        let call = RockCallViewController(title: "Full meeting identity", catchUp: CatchUpStore(), chat: ChatStore())
        nativeWindow.rootViewController = call; nativeWindow.isHidden = false
        defer { nativeWindow.isHidden = true }
        let factory = try NativeRTCPeer.makeFactory()
        let track = factory.videoTrack(with: factory.videoSource(), trackId: "share")
        call.render(snapshot: .init(participants: [.init(id: "presenter", name: "Shared source with full identity", isLocal: false,
            microphoneOn: true, cameraOn: false, screenShareOn: true, isSpeaking: false,
            videoTracks: [.init(id: "share", source: .screenShareVideo, track: .native(track))])]))
        nativeWindow.layoutIfNeeded(); call.view.layoutIfNeeded()
        let native = try XCTUnwrap(descendants(call.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "Meeting source selector" })
        for selector in [guest, native] {
            selector.layoutIfNeeded()
            let image = try XCTUnwrap(selector.imageView)
            XCTAssertEqual(selector.bounds.height, 44)
            XCTAssertLessThanOrEqual(image.bounds.width, 32)
            XCTAssertLessThanOrEqual(image.bounds.height, 32)
            XCTAssertTrue(selector.bounds.contains(image.frame))
        }
        let header = CompactCallHeader(frame: CGRect(x: 0, y: 0, width: 359, height: 44))
        header.update(name: "Complete source identity", navigation: false, browsing: false, pinned: false,
            pinLabel: nil, participantsLabel: "Musicians", chatValue: nil, status: "Full connection status",
            focusAvailable: true, meetingName: "Full meeting identity")
        header.layoutIfNeeded()
        XCTAssertTrue(header.details.accessibilityLabel?.contains("Complete source identity") == true)
        XCTAssertTrue(header.details.accessibilityLabel?.contains("Full meeting identity") == true)
        XCTAssertTrue(header.details.accessibilityValue?.contains("Full connection status") == true)
    }
    func testLandscapeHeaderHeightIsStableAcrossStatusChanges() {
        let bounds = CGRect(x: 0, y: 0, width: 812, height: 375)
        for height: CGFloat in [58, 80, 106, 140] {
            let geometry = CallPresentationGeometry(bounds: bounds, insets: .zero, headerHeight: height, hidden: false)
            XCTAssertTrue(geometry.compactHeader)
            XCTAssertEqual(geometry.header.height, 44)
            XCTAssertEqual(geometry.toolbar.width, 56)
            XCTAssertEqual(geometry.stage.minY, 54)
        }
        let accessible = CallPresentationGeometry(bounds: bounds, insets: .zero, headerHeight: 140, hidden: false, largeText: true)
        XCTAssertFalse(accessible.compactHeader)
        XCTAssertEqual(accessible.header.height, 140)
    }
    func testCompactHeaderTargetsAndPinState() {
        let header = CompactCallHeader(frame: CGRect(x: 0, y: 0, width: 500, height: 44))
        header.update(name: "Long presenter name", navigation: true, browsing: false, pinned: true,
            pinLabel: "Unpin presenter screen share", participantsLabel: "4 musicians", chatValue: "2 unread",
            chatCount: 2, missedCount: 1, status: nil, focusAvailable: true)
        header.layoutIfNeeded()
        for button in header.subviews.compactMap({ $0 as? UIButton }).filter({ !$0.isHidden }) {
            XCTAssertGreaterThanOrEqual(button.bounds.width, 44)
            XCTAssertEqual(button.bounds.height, 44)
            XCTAssertTrue(header.bounds.contains(button.frame))
        }
        XCTAssertFalse(header.previous.isEnabled)
        XCTAssertFalse(header.nextStream.isEnabled)
        XCTAssertTrue(header.automatic.isEnabled)
        XCTAssertEqual(header.pin.accessibilityLabel, "Unpin presenter screen share")
        XCTAssertEqual(header.conversation.accessibilityValue, "2 unread")
    }
    func testCompactHeaderOverflowKeepsTitleAndTargetsAtSmallWidths() {
        for width: CGFloat in [304, 375, 500, 1024] {
            let header = CompactCallHeader(frame: CGRect(x: 0, y: 0, width: width, height: 44))
            header.update(name: "Meeting", navigation: true, browsing: true, pinned: true,
                pinLabel: "Unpin", participantsLabel: "People", chatValue: "Unread", chatCount: 2,
                missedCount: 5, status: nil, focusAvailable: true)
            header.layoutIfNeeded()
            XCTAssertGreaterThanOrEqual(header.details.bounds.width, 100)
            for button in header.subviews.compactMap({ $0 as? UIButton }).filter({ !$0.isHidden }) {
                XCTAssertTrue(header.bounds.contains(button.frame))
                XCTAssertGreaterThanOrEqual(button.frame.width, 44)
                if button.isEnabled { XCTAssertNotNil(header.hitTest(button.center, with: nil), button.accessibilityLabel ?? "button") }
            }
            if width == 1024 { XCTAssertNil(header.hitTest(CGPoint(x: 300, y: 22), with: nil)) }
        }
    }
    func testZoomControlsExpireWithoutLayoutRefreshesExtendingTheirLifetime() async throws {
        let view = UIView()
        let controls = TransientCallControls(view: view, delay: 0.05)
        controls.setAvailable(true)
        XCTAssertTrue(view.isUserInteractionEnabled)
        controls.setAvailable(true); controls.setSuppressed(false)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(view.isUserInteractionEnabled)
        XCTAssertTrue(view.accessibilityElementsHidden)
        controls.beginInteraction()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(view.isUserInteractionEnabled)
        controls.endInteraction()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(view.isUserInteractionEnabled)
        controls.activity(); controls.setSuppressed(true)
        XCTAssertFalse(view.isUserInteractionEnabled)
        controls.setSuppressed(false)
        XCTAssertTrue(view.isUserInteractionEnabled)
        controls.setAvailable(false)
        XCTAssertFalse(view.isUserInteractionEnabled)
    }
    func testViewportRetainsScaleAndNormalizedCenterAfterResize() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let state = StreamViewportState()
        let viewport = StreamViewport(video: UIView(), state: state, zoomable: true,
            name: "Presenter", showInfo: true, microphoneOn: true, pinned: false, watermark: nil)
        window.addSubview(viewport)
        viewport.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        viewport.layoutIfNeeded()
        let scroll = try XCTUnwrap(viewport.subviews.first { $0 is UIScrollView } as? UIScrollView)
        scroll.setZoomScale(2, animated: false)
        scroll.contentOffset = CGPoint(x: 100, y: 110)
        let center = state.center
        viewport.frame.size = CGSize(width: 640, height: 300)
        viewport.layoutIfNeeded()
        XCTAssertEqual(scroll.zoomScale, 2)
        XCTAssertEqual((scroll.contentOffset.x + scroll.bounds.width / 2) / scroll.contentSize.width, center.x, accuracy: 0.001)
        XCTAssertEqual((scroll.contentOffset.y + scroll.bounds.height / 2) / scroll.contentSize.height, center.y, accuracy: 0.001)
        viewport.frame.size = CGSize(width: 320, height: 240)
        viewport.layoutIfNeeded()
        XCTAssertEqual(scroll.zoomScale, 2)
        XCTAssertEqual(scroll.contentOffset.x, 100, accuracy: 0.1)
        XCTAssertEqual(scroll.contentOffset.y, 110, accuracy: 0.1)
    }
    func testMenuDismissalTapDoesNotHideControlsButExplicitActionDoes() {
        let focus = CallFocusController()
        focus.menuVisible = true
        focus.toggle()
        focus.menuVisible = false
        XCTAssertFalse(focus.hidden)
        focus.menuVisible = true
        focus.hide()
        XCTAssertFalse(focus.hidden)
        focus.menuVisible = false
        XCTAssertTrue(focus.hidden)
    }
    func testFocusRespectsCriticalStateAndRestoresOnKeyboard() async {
        let focus = CallFocusController()
        focus.canHide = { false }; focus.hide(); XCTAssertFalse(focus.hidden)
        focus.canHide = { true }; focus.hide(); XCTAssertTrue(focus.hidden)
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        await Task.yield()
        XCTAssertFalse(focus.hidden)
        focus.hide(); XCTAssertFalse(focus.hidden)
    }
    func testOldStageCannotRemoveNewMeetingGeometry() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let old = UUID(), current = UUID()
        let rect = CGRect(x: 0, y: 80, width: 320, height: 400)
        CallStageLayout.update(window: window, owner: old, rect: rect, hidden: false, toggle: {})
        CallStageLayout.update(window: window, owner: current, rect: rect, hidden: false, toggle: {})
        CallStageLayout.remove(window: window, owner: old)
        XCTAssertEqual(CallStageLayout.record(for: window)?.owner, current)
        CallStageLayout.remove(window: window, owner: current)
        XCTAssertNil(CallStageLayout.record(for: window))
    }
    func testFocusHintExpiresAndStaysDismissedAfterRestart() async throws {
        let suite = "focus-hint-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        let focus = CallFocusController(defaults: defaults)
        focus.installHint(in: view)
        focus.hide()
        XCTAssertTrue(focus.hidden)
        XCTAssertTrue(defaults.bool(forKey: CallFocusController.hintPreferenceKey))
        let hint = try XCTUnwrap(view.subviews.first)
        XCTAssertFalse(hint.isHidden)
        XCTAssertFalse(hint.isUserInteractionEnabled)
        try await Task.sleep(nanoseconds: 2_300_000_000)
        XCTAssertEqual(hint.alpha, 0)
        focus.toggle(); focus.toggle()
        XCTAssertTrue(hint.isHidden)
        let restarted = CallFocusController(defaults: defaults)
        let nextView = UIView()
        restarted.installHint(in: nextView); restarted.hide()
        XCTAssertTrue(try XCTUnwrap(nextView.subviews.first).isHidden)
    }
    func testAccessibilityRestoresFocusedViewportAndKeepsZoom() throws {
        let focus = CallFocusController()
        let viewport = StreamViewport(video: UIView(), state: StreamViewportState(), zoomable: true,
            name: "Presenter", showInfo: true, microphoneOn: false, pinned: false, watermark: nil)
        focus.onChange = { [weak viewport] in viewport?.controlsHidden = $0 }
        viewport.onToggleControls = { [weak focus] in focus?.toggle() }
        let scroll = try XCTUnwrap(viewport.subviews.first { $0 is UIScrollView } as? UIScrollView)
        scroll.setZoomScale(2, animated: false)
        focus.hide()
        let action = try XCTUnwrap(scroll.accessibilityCustomActions?.first)
        XCTAssertEqual(action.name, L("Show controls"))
        XCTAssertTrue(try XCTUnwrap(action.actionHandler)(action))
        XCTAssertFalse(focus.hidden)
        XCTAssertEqual(scroll.zoomScale, 2)
        XCTAssertTrue(scroll.accessibilityCustomActions?.contains { $0.name == L("Zoom in") } == true)
        XCTAssertFalse(scroll.accessibilityCustomActions?.contains { $0.name == L("Show controls") } == true)
        focus.hide()
        let restore = focus.restoreAccessibilityAction()
        XCTAssertTrue(try XCTUnwrap(restore.actionHandler)(restore))
        XCTAssertFalse(focus.hidden)
    }
    func testFillUsesActualAspectAndSupportsUltraWideSources() throws {
        XCTAssertEqual(try XCTUnwrap(SharedScreenScale.fill(content: CGSize(width: 1920, height: 1080),
            viewport: CGSize(width: 440, height: 956))), (956.0 / 1080) / (440.0 / 1920), accuracy: 0.0001)
        XCTAssertEqual(SharedScreenScale.fill(content: CGSize(width: 1600, height: 900), viewport: CGSize(width: 800, height: 450)), 1)
        XCTAssertNil(SharedScreenScale.fill(content: .zero, viewport: CGSize(width: 800, height: 450)))
        let video = GuestSampleBufferView()
        let viewport = StreamViewport(video: video, state: StreamViewportState(), zoomable: true,
            name: "Ultra-wide screen", showInfo: false, microphoneOn: false, pinned: false, watermark: nil)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        viewport.frame = CGRect(x: 0, y: 0, width: 320, height: 900)
        window.addSubview(viewport); viewport.layoutIfNeeded()
        let sample = try shareSample(width: 640, height: 90)
        video.enqueue(sample, rotation: 0)
        let expected = try XCTUnwrap(viewport.fillScale)
        XCTAssertGreaterThan(expected, 5)
        viewport.toggleScale()
        let scroll = try XCTUnwrap(viewport.subviews.compactMap { $0 as? UIScrollView }.first)
        scroll.setZoomScale(expected, animated: false)
        let renderer = viewport.rendererView
        viewport.frame.size = CGSize(width: 900, height: 320)
        viewport.updatePresentation(name: "Renamed", showInfo: false, microphoneOn: true, watermark: nil, zoomable: true)
        viewport.setNeedsLayout(); viewport.layoutIfNeeded()
        XCTAssertEqual(viewport.zoomScale, expected, accuracy: 0.001)
        XCTAssertTrue(viewport.rendererView === renderer)
        XCTAssertEqual(video.displaySize, CGSize(width: 640, height: 90))
        video.enqueue(sample, rotation: 90)
        XCTAssertEqual(video.displaySize, CGSize(width: 90, height: 640))
    }
    private func shareSample(width: Int, height: Int) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
    func testGuestShareFitAndZoomSurviveMetadataAndChromeWithoutDuplicateSingleSource() throws {
        let (window, controls, _, _) = try guestLayout(ownedSurface: true)
        defer { window.isHidden = true }
        func update(_ name: String, microphone: Bool) {
            controls.setStagePresentation(.init(target: .init(participant: "presenter", isShare: true), name: name,
                microphoneOn: microphone, watermark: nil, active: true, automatic: true, count: 2, browsing: false))
            window.layoutIfNeeded(); controls.layoutIfNeeded()
        }
        update("First source", microphone: false)
        let viewport = try XCTUnwrap(descendants(window).compactMap { $0 as? StreamViewport }.first)
        viewport.layoutIfNeeded()
        XCTAssertEqual(viewport.fittedContentRect, viewport.bounds)
        let renderer = viewport.rendererView
        let scroll = try XCTUnwrap(viewport.subviews.compactMap { $0 as? UIScrollView }.first)
        scroll.setZoomScale(2.5, animated: false); scroll.contentOffset = CGPoint(x: 100, y: 120)
        let center = scroll.contentOffset
        let source = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "Shared stream selector" })
        XCTAssertTrue(source.isHidden)
        for n in 0..<10 {
            update("Source \(n)", microphone: n.isMultiple(of: 2))
            viewport.controlsHidden.toggle(); viewport.layoutIfNeeded()
            XCTAssertTrue(viewport.rendererView === renderer)
            XCTAssertEqual(viewport.zoomScale, 2.5)
            XCTAssertEqual(scroll.contentOffset, center)
        }
    }
    func testPrivacySlotAndCountBadgesKeepOpticalPaddingAcrossSpeakerStates() throws {
        let header = CompactCallHeader(frame: CGRect(x: 0, y: 0, width: 600, height: 44))
        var iconFrame: CGRect?
        for speaker in [nil, CallSpeaker(id: "speaker", name: "Очень длинное имя участника", isLocal: false), nil] {
            header.update(name: "Shared presentation", navigation: false, browsing: false, pinned: false,
                pinLabel: nil, participantsLabel: "Musicians", chatValue: "99+", chatCount: 140,
                missedCount: 140, status: nil, speaking: speaker, focusAvailable: true,
                privacySymbol: "doc.text", privacyDescription: "Transcription is on")
            header.layoutIfNeeded(); header.details.layoutIfNeeded()
            let icon = try XCTUnwrap(header.details.subviews.compactMap { $0 as? UIImageView }.first { !$0.isHidden && $0.frame.width == 18 })
            XCTAssertEqual(icon.frame.minX, 14); XCTAssertEqual(icon.frame.midY, 22)
            if let iconFrame { XCTAssertEqual(icon.frame, iconFrame) }
            iconFrame = icon.frame
            for button in [header.conversation, header.missed] {
                let badge = try XCTUnwrap(button.subviews.compactMap { $0 as? UILabel }.first { $0.text == "99+" })
                XCTAssertGreaterThanOrEqual(badge.frame.minY, 6)
                XCTAssertLessThanOrEqual(badge.frame.maxX, 39)
            }
        }
    }

    func testMultipleSharesRetainSourceSelector() async throws {
        let (window, controls, streams, _) = try guestLayout()
        defer { window.isHidden = true; streams.reset() }
        let roster = guestRoster.map { GuestStreamViews.Participant(id: $0.id, name: $0.name, isLocal: false,
            microphoneOn: false, cameraOn: false, sharing: $0.id != "c") }
        controls.updateParticipantRoster(roster, speaking: nil); streams.updateParticipants(roster)
        await settleUI(); window.layoutIfNeeded(); controls.layoutIfNeeded()
        let selector = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "Shared stream selector" })
        XCTAssertFalse(selector.isHidden)
        XCTAssertGreaterThanOrEqual(selector.menu?.children.count ?? 0, 2)
    }

    func testNativeGalleryAccessibilityZoomTargetsTheSelectedShare() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let call = RockCallViewController(title: "Two shares", catchUp: CatchUpStore(), chat: ChatStore())
        window.rootViewController = call; window.isHidden = false
        defer { window.isHidden = true }
        let factory = try NativeRTCPeer.makeFactory()
        let participants = (0..<2).map { n in CallParticipant(id: "person-\(n)", name: "Person \(n)", isLocal: false,
            microphoneOn: false, cameraOn: false, screenShareOn: true, isSpeaking: false,
            videoTracks: [.init(id: "share-\(n)", source: .screenShareVideo,
                track: .native(factory.videoTrack(with: factory.videoSource(), trackId: "share-\(n)")))]) }
        call.render(snapshot: .init(participants: participants)); window.layoutIfNeeded(); call.view.layoutIfNeeded()
        let layout = try XCTUnwrap(descendants(call.view).compactMap { $0 as? MeetingLayoutControls }.first)
        layout.layout.selectedSegmentIndex = 0; layout.layout.sendActions(for: .valueChanged)
        window.layoutIfNeeded(); call.view.layoutIfNeeded()
        let scrolls = descendants(call.view).compactMap { $0 as? UIScrollView }.filter { $0.maximumZoomScale > 1 }
        let primary = try XCTUnwrap(scrolls.first { $0.accessibilityIdentifier == "share-0" })
        let secondary = try XCTUnwrap(scrolls.first { $0.accessibilityIdentifier == "share-1" })
        let action = try XCTUnwrap(secondary.accessibilityCustomActions?.first { $0.name == L("Zoom in") })
        XCTAssertTrue(try XCTUnwrap(action.actionHandler)(action))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertGreaterThan(secondary.zoomScale, 1)
        XCTAssertEqual(primary.zoomScale, 1)
        let header = try XCTUnwrap(descendants(call.view).compactMap { $0 as? CompactCallHeader }.first)
        XCTAssertEqual(header.focus.accessibilityLabel, L("Hide controls"))
    }
    func testNativeFallbackRetainsRealDimensionsForFillAndResize() async throws {
        let track = await LocalVideoTrack.createBufferTrack(name: "Fallback geometry", source: .camera,
            options: BufferCaptureOptions(dimensions: .h720_169, fps: 30))
        try await track.capturer.startCapture()
        let view = CallVideoView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene); window.addSubview(view); window.isHidden = false
        defer { view.track = nil; window.isHidden = true }
        view.track = .room(track)
        var notifications = 0
        view.onDisplaySizeChanged = { notifications += 1 }
        let capture = try XCTUnwrap(track.capturer as? BufferCapturer)
        for size in [CGSize(width: 640, height: 360), CGSize(width: 320, height: 240)] {
            let sample = try shareSample(width: Int(size.width), height: Int(size.height))
            let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            for _ in 0..<15 { capture.capture(pixels); try await Task.sleep(for: .milliseconds(34)) }
            XCTAssertEqual(view.displaySize, size)
            XCTAssertNotNil(SharedScreenScale.fill(content: view.displaySize, viewport: CGSize(width: 440, height: 956)))
        }
        XCTAssertGreaterThanOrEqual(notifications, 2)
        try await track.capturer.stopCapture()
    }

}
