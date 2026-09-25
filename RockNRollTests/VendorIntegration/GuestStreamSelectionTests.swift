import JazzSDK
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class GuestStreamSelectionTests: XCTestCase {
    func testPinnedVideoRespectsShareOnlyAudioOnlyAndVisibility() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let streams = GuestStreamViews()
        let camera = streams.makeView(model: model("camera", pinned: true, share: false), video: UIView())
        let share = streams.makeView(model: model("share", pinned: false, share: true), video: UIView())
        camera.frame = CGRect(x: 10, y: 100, width: 140, height: 200)
        share.frame = CGRect(x: 160, y: 100, width: 140, height: 200)
        controller.view.addSubview(camera)
        controller.view.addSubview(share)
        controller.view.layoutIfNeeded()

        await assertSelection(streams, mode: .all, expected: camera)
        await assertSelection(streams, mode: .screenShares, expected: share)
        await assertSelection(streams, mode: .audioOnly, expected: nil)
        camera.isHidden = true
        await assertSelection(streams, mode: .all, expected: share)
        share.isHidden = true
        await assertSelection(streams, mode: .all, expected: nil)
    }

    private func assertSelection(_ streams: GuestStreamViews, mode: ConferenceDisplayMode,
                                 expected: UIView?, file: StaticString = #filePath, line: UInt = #line) async {
        let selected = expectation(description: "Visible stream selection")
        streams.onPreferredVideo = { viewport, _, _ in
            XCTAssertTrue(viewport === expected, file: file, line: line)
            selected.fulfill()
        }
        streams.displayMode = mode
        await fulfillment(of: [selected], timeout: 2)
        streams.onPreferredVideo = nil
    }

    private func model(_ id: String, pinned: Bool, share: Bool) -> JazzParticipantViewModel {
        JazzParticipantViewModel(name: id, isAudioOn: false, isVideoOn: !share, isPinned: pinned,
            isSharingScreen: share, isLocal: false, id: id, isDominantSpeaker: false,
            shouldShowParticipantInfo: true, isZoomable: share, watermarkState: .hidden, displayMode: .speaker)
    }
}
