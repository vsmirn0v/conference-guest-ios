import ConferenceCore
import UIKit
import ReplayKit
import XCTest
@testable import RockNRoll

@MainActor
final class MeetingActionsTests: XCTestCase {
    func testGroupingPreservesExistingActionsAndDisabledCapabilities() throws {
        var calls = 0
        let active = UIAction(title: "Active", identifier: UIAction.Identifier("qa.active"), state: .on) { _ in calls += 1 }
        let unsupported = UIAction(title: "Unavailable", identifier: UIAction.Identifier("qa.unavailable"), attributes: .disabled) { _ in
            XCTFail("Unavailable capability executed")
        }
        let menu = MeetingActionGroup.make(cameraSound: [active], sharePresenter: [unsupported], view: [], invite: [], meeting: [])
        let groups = try menu.children.map { try XCTUnwrap($0 as? UIMenu) }
        XCTAssertEqual(groups.map(\.identifier), [MeetingActionGroup.cameraSound, .sharePresenter, .view, .invite, .meeting].map(\.identifier))
        let preserved = try XCTUnwrap(groups[0].children.first as? UIAction)
        XCTAssertEqual(preserved.identifier, active.identifier)
        XCTAssertEqual(preserved.state, .on)
        UIButton(primaryAction: preserved).sendActions(for: .touchUpInside)
        XCTAssertEqual(calls, 1, "Grouping replaced the existing transport handler")
        let unavailable = try XCTUnwrap(groups[1].children.first as? UIAction)
        XCTAssertEqual(unavailable.identifier, unsupported.identifier)
        XCTAssertTrue(unavailable.attributes.contains(.disabled))
    }

    func testUnavailableReactionSurfaceCannotSendOrAffectExistingMediaActions() {
        let model = MeetingReactionsModel()
        let generation = model.generation
        let controller = MeetingActionsController(model: model,
            menu: MeetingActionGroup.make(cameraSound: [], sharePresenter: [], view: [], invite: [], meeting: []))
        controller.loadViewIfNeeded()
        XCTAssertFalse(model.canSend)
        XCTAssertFalse(model.send(.like))
        XCTAssertNil(model.submitted)
        XCTAssertEqual(model.generation, generation)
    }
    func testCallActionPresentationUsesVisibleChatAndKeepsOriginalAnchorOtherwise() {
        let call = PresentedHost()
        let callChild = UIViewController()
        call.addChild(callChild); call.view.addSubview(callChild.view)
        let button = UIButton()
        callChild.view.addSubview(button)
        XCTAssertTrue(button.callActionPresenter === call)
        XCTAssertTrue(button.callActionPresentationAnchor === button)
        let chat = PresentedHost()
        call.modal = chat
        XCTAssertTrue(button.callActionPresenter === chat)
        XCTAssertTrue(button.callActionPresentationAnchor === chat.view)
        let composer = UIButton(); chat.view.addSubview(composer)
        XCTAssertTrue(composer.callActionPresentationAnchor === composer)
        call.modal = nil
        XCTAssertTrue(button.callActionPresentationAnchor === button)
    }

    func testGroupedNativeShareUsesSameConsentPathAsDock() throws {
        let call = RockCallViewController(title: "Share routing", catchUp: CatchUpStore(), chat: ChatStore())
        call.loadViewIfNeeded()
        let picker = try XCTUnwrap(descendants(call.view).compactMap { $0 as? RPSystemBroadcastPickerView }.first)
        let consentButton = try XCTUnwrap(picker.subviews.compactMap { $0 as? UIButton }.first)
        consentButton.removeTarget(nil, action: nil, for: .allEvents)
        var requests = 0
        consentButton.addAction(UIAction { _ in requests += 1 }, for: .touchUpInside)
        var direct: [Bool] = []
        call.onShare = { direct.append($0) }
        call.performGroupedShareAction()
        if #available(iOS 27.0, *) {
            XCTAssertEqual(direct, [true]); XCTAssertEqual(requests, 0)
        } else if ProcessInfo.processInfo.isiOSAppOnMac {
            XCTAssertEqual(direct, [true]); XCTAssertEqual(requests, 0)
        } else {
            XCTAssertTrue(direct.isEmpty); XCTAssertEqual(requests, 1)
        }
        direct = []
        call.usesNativeShareControl = true
        call.performGroupedShareAction()
        XCTAssertEqual(direct, [true])
        direct = []
        call.setSharing(true)
        call.performGroupedShareAction()
        XCTAssertEqual(direct, [false])
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private final class PresentedHost: UIViewController {
        var modal: UIViewController?
        override var presentedViewController: UIViewController? { modal }
    }

}
