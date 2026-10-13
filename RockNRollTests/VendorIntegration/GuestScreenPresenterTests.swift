import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class GuestScreenPresenterTests: XCTestCase {
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
