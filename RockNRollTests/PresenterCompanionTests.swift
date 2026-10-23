import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class PresenterCompanionTests: XCTestCase {
    private func host() throws -> (UIWindow, UIViewController, PresenterCompanionView) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller; window.makeKeyAndVisible()
        let companion = PresenterCompanionView()
        controller.view.addSubview(companion)
        companion.place(in: CGRect(x: 8, y: 60, width: 374, height: 650), fittedShareFrame: .zero)
        return (window, controller, companion)
    }
    func testPreviewLifecycleKeepsIdentityAndRetiresCollapsedDemand() throws {
        let (window, controller, companion) = try host()
        defer { window.isHidden = true }
        let preview = UIView()
        var visibility: [Bool] = []
        companion.onVisibilityChanged = { visibility.append($0) }
        companion.configure(name: "Alex", preview: preview)
        XCTAssertTrue(companion.isPreviewVisible)
        let owner = try XCTUnwrap(preview.superview)
        companion.move(to: .topLeading)
        companion.configure(name: "Alex renamed", preview: preview)
        XCTAssertTrue(preview.superview === owner)
        XCTAssertEqual(companion.corner, .topLeading)
        companion.setCollapsed(true)
        XCTAssertNil(preview.superview)
        XCTAssertFalse(companion.isPreviewVisible)
        XCTAssertTrue(descendants(companion).contains { $0.accessibilityIdentifier == "presenter.companion.show" && !$0.isHidden })
        companion.configure(name: "Alex", preview: preview)
        XCTAssertTrue(companion.isCollapsed)
        companion.setCollapsed(false)
        XCTAssertTrue(preview.superview === owner)
        controller.view.isHidden = true; companion.refreshVisibility()
        XCTAssertFalse(companion.isPreviewVisible)
        controller.view.isHidden = false; companion.refreshVisibility()
        XCTAssertTrue(companion.isPreviewVisible)
        companion.configure(name: "Alex", preview: nil)
        XCTAssertTrue(companion.isHidden)
        XCTAssertNil(preview.superview)
        XCTAssertEqual(visibility, [true, false, true, false, true, false])
    }
    func testPreviewTapRequiresExplicitCameraFocusAndReturnSurvivesCameraLoss() throws {
        let (window, _, companion) = try host()
        defer { window.isHidden = true }
        var focuses = 0, returns = 0
        companion.onFocusCamera = { focuses += 1 }
        companion.onReturnToShare = { returns += 1 }
        companion.configure(name: "Alex", preview: UIView())
        let previewButton = try XCTUnwrap(descendants(companion).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "presenter.companion.focus" })
        XCTAssertTrue(previewButton.showsMenuAsPrimaryAction)
        previewButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(focuses, 0)
        let focus = try XCTUnwrap(companion.menuActions().compactMap { $0 as? UIAction }
            .first { $0.identifier.rawValue == "presenter.companion.focus" })
        UIButton(primaryAction: focus).sendActions(for: .touchUpInside)
        XCTAssertEqual(focuses, 1)
        companion.configure(name: "Alex", preview: nil, cameraFocused: true)
        XCTAssertFalse(companion.isHidden)
        XCTAssertFalse(companion.isPreviewVisible)
        let back = try XCTUnwrap(descendants(companion).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "presenter.companion.return" })
        back.sendActions(for: .touchUpInside)
        XCTAssertEqual(returns, 1)
    }
    func testMountedPreviewDemandFollowsWindowAndApplicationVisibility() throws {
        let (window, _, companion) = try host()
        defer { window.isHidden = true }
        var visibility: [Bool] = []
        companion.onVisibilityChanged = { visibility.append($0) }
        companion.configure(name: "Alex", preview: UIView())
        XCTAssertTrue(companion.isPreviewVisible)
        window.isHidden = true
        XCTAssertFalse(companion.isPreviewVisible)
        window.makeKeyAndVisible()
        XCTAssertTrue(companion.isPreviewVisible)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertFalse(companion.isPreviewVisible)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        companion.configure(name: "Alex renamed", preview: UIView())
        XCTAssertFalse(companion.isPreviewVisible)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(companion.isPreviewVisible)
        XCTAssertEqual(visibility, [true, false, true, false, true])
    }
    func testPortraitUsesSpareAreaAndLandscapeMovesToEveryCornerWithoutChangingShare() throws {
        let (window, _, companion) = try host()
        defer { window.isHidden = true }
        let preview = UIView()
        companion.configure(name: "Alex", preview: preview)
        let portrait = CGRect(x: 8, y: 60, width: 374, height: 650)
        let share = CGRect(x: 8, y: 250, width: 374, height: 210)
        companion.place(in: portrait, fittedShareFrame: share)
        XCTAssertFalse(companion.frame.intersects(share))
        XCTAssertTrue(portrait.contains(companion.frame))
        let landscape = CGRect(x: 40, y: 50, width: 740, height: 250)
        var frames: [CGRect] = []
        for corner in PresenterCompanionView.Corner.allCases {
            companion.move(to: corner)
            companion.place(in: landscape, fittedShareFrame: landscape)
            XCTAssertTrue(landscape.contains(companion.frame))
            XCTAssertEqual(companion.frame.minX < landscape.midX, corner.leading)
            XCTAssertEqual(companion.frame.midY < landscape.midY, corner.top)
            frames.append(companion.frame)
        }
        XCTAssertEqual(Set(frames.map { NSCoder.string(for: $0) }).count, 4)
        let blocked = frames[3]
        companion.place(in: landscape, fittedShareFrame: landscape, avoiding: [blocked])
        XCTAssertFalse(companion.frame.intersects(blocked))
        XCTAssertEqual(share, CGRect(x: 8, y: 250, width: 374, height: 210))
    }
    private func descendants(_ root: UIView) -> [UIView] {
        root.subviews.flatMap { [$0] + descendants($0) }
    }
}
