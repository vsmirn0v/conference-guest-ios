import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class CallPresentationTests: XCTestCase {
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
}
