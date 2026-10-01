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
                                    (CGSize(width: 68, height: 347), true, false),
                                    (CGSize(width: 304, height: 148), false, true)] {
            toolbar.frame = CGRect(origin: .zero, size: size)
            toolbar.arrange(rail: rail, largeText: large)
            toolbar.layoutIfNeeded()
            for button in buttons {
                XCTAssertGreaterThanOrEqual(button.bounds.width, 44)
                XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
                XCTAssertTrue(toolbar.bounds.contains(button.frame))
            }
        }
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
