import AVFoundation
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class CallSpacebarShortcutTests: XCTestCase {
    func testGuestMicActionsCannotUnmuteWhileHeldOrUnavailable() throws {
        var changes: [Bool] = []
        let controls = CallControls(localPreview: LocalSharePreview(), state: nil, coordinator: nil,
            router: nil, catchUp: CatchUpStore(), chat: ChatStore(), initialDisplayMode: .all,
            invitationURL: nil, roomIdentifier: nil, onDisplayMode: { _ in }, onFloat: {},
            onFloatingPreferenceChanged: {}, onLeave: {}, onScreenShare: { _ in },
            onMicrophoneState: { changes.append($0) }, onCameraState: { _ in })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(controls)
        window.isHidden = false
        defer { controls.removeFromSuperview(); window.isHidden = true }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let microphone = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }
            .first { $0.configuration?.title == L("Mic") })
        controls.setHeld(true)
        controls.workspace.toggleMicrophone?()
        microphone.sendActions(for: .touchUpInside)
        _ = controls.perform(NSSelectorFromString("keyToggleMicrophone"))
        XCTAssertTrue(changes.isEmpty, "Programmatic actions bypass UIButton enabled state")
        controls.setHeld(false)
        microphone.isEnabled = false
        controls.workspace.toggleMicrophone?()
        XCTAssertTrue(changes.isEmpty)
        microphone.isEnabled = true
        controls.workspace.toggleMicrophone?()
        XCTAssertEqual(changes, [true], "Resume retains muted intent until an explicit command")
    }

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
