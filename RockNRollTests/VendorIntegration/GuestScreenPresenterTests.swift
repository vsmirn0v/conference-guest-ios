import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class GuestScreenPresenterTests: XCTestCase {
    func testSDKChildSheetSharesVisibleHostAndRemainsInteractiveAfterScreenReplacement() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), page = UIViewController()
        window.rootViewController = page; window.makeKeyAndVisible()
        defer { page.dismiss(animated: false); window.isHidden = true }
        let home = UIView(), hiddenHome = UIView()
        hiddenHome.accessibilityElementsHidden = true
        page.view.addSubview(home); page.view.addSubview(hiddenHome)
        let presenter = GuestScreenPresenter(container: page), first = UIViewController()
        presenter.beginJoin(); presenter.presentScreen(screen: first)
        try await Task.sleep(for: .milliseconds(100))
        let sdkContainer = presenter.sdkContainer
        XCTAssertTrue(sdkContainer === presenter.hostForTesting)
        XCTAssertTrue(presenter.hostForTesting.parent === page)
        XCTAssertTrue(first.parent === presenter.hostForTesting)
        XCTAssertTrue(home.accessibilityElementsHidden); XCTAssertTrue(hiddenHome.accessibilityElementsHidden)
        let recovery = try XCTUnwrap(presenter.hostForTesting.view.subviews.first as? UIStackView)
        XCTAssertTrue(recovery.isHidden)
        func openSheet() -> (UIViewController, UIButton) {
            // SDK StackScreenController uses this containment path for sheets.
            let sheet = UIViewController(), button = UIButton(type: .system)
            sdkContainer.addChild(sheet)
            sheet.view.frame = sdkContainer.view.bounds
            sheet.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            sdkContainer.view.addSubview(sheet.view); sheet.didMove(toParent: sdkContainer)
            button.frame = CGRect(x: 20, y: 100, width: 180, height: 44)
            button.setTitle("Participant sheet action", for: .normal)
            sheet.view.addSubview(button)
            return (sheet, button)
        }
        func verifyAndCloseSheet() {
            let (sheet, button) = openSheet()
            sdkContainer.view.layoutIfNeeded()
            XCTAssertFalse(sheet.view.accessibilityElementsHidden, "Later SDK panels must remain accessible.")
            let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
            XCTAssertTrue(window.hitTest(point, with: nil) === button)
            var presses = 0
            button.addAction(UIAction { _ in presses += 1 }, for: .touchUpInside)
            button.sendActions(for: .touchUpInside); XCTAssertEqual(presses, 1)
            sheet.willMove(toParent: nil); sheet.view.removeFromSuperview(); sheet.removeFromParent()
            // SDK dismissal resets sibling AX flags; this must stay confined
            // to the SDK container, without exposing the outer home page.
            sdkContainer.view.subviews.forEach { $0.accessibilityElementsHidden = false }
            XCTAssertTrue(home.accessibilityElementsHidden)
            XCTAssertTrue(hiddenHome.accessibilityElementsHidden)
        }
        verifyAndCloseSheet()
        presenter.beginRecovery()
        XCTAssertFalse(recovery.isHidden)
        XCTAssertTrue(home.accessibilityElementsHidden)
        let replacement = UIViewController()
        presenter.presentScreen(screen: replacement); presenter.completeRecovery()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(replacement.parent === presenter.hostForTesting)
        XCTAssertTrue(recovery.isHidden)
        XCTAssertTrue(home.accessibilityElementsHidden)
        verifyAndCloseSheet()
        XCTAssertEqual(presenter.hostForTesting.children, [replacement])
        XCTAssertEqual(page.children, [presenter.hostForTesting])
        presenter.end()
        XCTAssertNil(replacement.parent)
        XCTAssertTrue(sdkContainer.children.isEmpty); XCTAssertTrue(page.children.isEmpty)
        XCTAssertFalse(home.accessibilityElementsHidden); XCTAssertTrue(hiddenHome.accessibilityElementsHidden)
        presenter.beginJoin(); presenter.presentScreen(screen: UIViewController())
        XCTAssertTrue(home.accessibilityElementsHidden)
        presenter.end()
        XCTAssertFalse(home.accessibilityElementsHidden); XCTAssertTrue(hiddenHome.accessibilityElementsHidden)
    }
    func testLocalRecoveryDoesNotPresentTerminalScreenAndOldRemovalCannotRemoveNewScreen() {
        let presenter = GuestScreenPresenter(container: UIViewController())
        let old = UIViewController(), replacement = UIViewController(), terminal = UIViewController()
        presenter.beginJoin(); presenter.presentScreen(screen: old)
        XCTAssertTrue(old.parent === presenter.hostForTesting)
        presenter.beginRecovery()
        XCTAssertNil(old.parent)
        presenter.presentScreen(screen: terminal)
        XCTAssertNil(terminal.parent); XCTAssertNil(presenter.screenForTesting)
        presenter.removeScreen(screen: old)
        presenter.beginJoin(); presenter.presentScreen(screen: replacement)
        XCTAssertNil(replacement.parent, "SDK routing stays hidden until fresh media is ready")
        presenter.completeRecovery()
        presenter.removeScreen(screen: old)
        XCTAssertTrue(presenter.screenForTesting === replacement)
        presenter.removeScreen(screen: replacement)
        XCTAssertTrue(presenter.screenForTesting === replacement, "Only resolved logical departure closes the meeting")
        presenter.end()
        XCTAssertNil(replacement.parent)
        presenter.presentScreen(screen: terminal)
        XCTAssertNil(presenter.screenForTesting)
    }
}
