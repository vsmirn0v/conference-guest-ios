import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class CallPresentationTests: XCTestCase {
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

    private var guestRoster: [GuestStreamViews.Participant] {
        ["Anna", "Boris", "Clara"].enumerated().map {
            .init(id: String(UnicodeScalar(97 + $0.offset)!), name: $0.element, isLocal: false,
                  microphoneOn: false, cameraOn: false, sharing: false)
        }
    }
    private func guestLayout() throws -> (UIWindow, CallControls, GuestStreamViews, MeetingLayoutControls) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.isHidden = false
        let controls = CallControls(localPreview: LocalSharePreview(), state: nil, coordinator: nil,
            router: nil, catchUp: CatchUpStore(), chat: ChatStore(), initialDisplayMode: .all,
            invitationURL: nil, roomIdentifier: "fixture", onDisplayMode: { _ in }, onFloat: {},
            onFloatingPreferenceChanged: {}, onLeave: {}, onScreenShare: { _ in },
            onMicrophoneState: { _ in }, onCameraState: { _ in })
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
        for button in header.subviews.compactMap({ $0 as? UIButton }) {
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
        XCTAssertNil(scroll.accessibilityCustomActions)
        focus.hide()
        let restore = focus.restoreAccessibilityAction()
        XCTAssertTrue(try XCTUnwrap(restore.actionHandler)(restore))
        XCTAssertFalse(focus.hidden)
    }
}
