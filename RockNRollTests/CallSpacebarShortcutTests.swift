import AVFoundation
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class CallSpacebarShortcutTests: XCTestCase {
    func testOneTogglePerHoldAndFreshPressAfterRelease() {
        let shortcut = CallSpacebarShortcut()
        XCTAssertTrue(shortcut.pressBegan())
        for _ in 0..<20 { XCTAssertFalse(shortcut.pressBegan()) }
        shortcut.reset()
        XCTAssertTrue(shortcut.pressBegan())
    }
    func testLosingFocusDoesNotLeaveShortcutStuck() {
        let shortcut = CallSpacebarShortcut()
        XCTAssertTrue(shortcut.pressBegan())
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertTrue(shortcut.pressBegan())
    }
    func testTypingAndFocusedButtonsKeepTheirSpaceKey() {
        class Field: UITextField { override var isFirstResponder: Bool { true } }
        class Text: UITextView { override var isFirstResponder: Bool { true } }
        class Button: UIButton { override var isFirstResponder: Bool { true } }
        for child in [Field(), Text(), Button()] as [UIView] {
            let root = UIView(), panel = UIView()
            root.addSubview(panel); panel.addSubview(child)
            XCTAssertFalse(CallSpacebarShortcut.allowsShortcut(in: root))
        }
        XCTAssertTrue(CallSpacebarShortcut.allowsShortcut(in: UIView()))
    }
    func testMacPlatformMuteHandlerAvailability() throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac else { throw XCTSkip("Mac runtime probe") }
        if #available(iOS 17.0, *) {
            let app = AVAudioApplication.shared
            print("MAC_MUTE_API class=\(type(of: app)) handler=\(app.responds(to: NSSelectorFromString("setInputMuteStateChangeHandler:error:"))) muted=\(app.isInputMuted)")
        }
    }
}
