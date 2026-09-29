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

    func testTilePinOverridesAutomaticShareAndSurvivesDisplayFiltering() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let streams = GuestStreamViews()
        let camera = streams.makeView(model: model("camera", pinned: false, share: false), video: UIView())
        let share = streams.makeView(model: model("share", pinned: false, share: true), video: UIView())
        camera.frame = CGRect(x: 10, y: 100, width: 140, height: 200)
        share.frame = CGRect(x: 160, y: 100, width: 140, height: 200)
        controller.view.addSubview(camera)
        controller.view.addSubview(share)
        controller.view.layoutIfNeeded()

        streams.setPin(.init(participant: "camera", isShare: false))
        await assertSelection(streams, mode: .all, expected: camera)
        camera.isHidden = true
        await assertSelection(streams, mode: .all, expected: camera)
        camera.isHidden = false
        await assertSelection(streams, mode: .screenShares, expected: share)
        await assertSelection(streams, mode: .all, expected: camera)
        streams.setPin(nil)
        await assertSelection(streams, mode: .all, expected: share)
    }

    func testCameraOffHidesRetainedRendererUntilCameraReturns() async {
        let streams = GuestStreamViews()
        let renderer = UIView()
        let camera = streams.makeView(model: model("camera", pinned: false, share: false),
                                      video: renderer)
        XCTAssertFalse(renderer.isHidden)

        streams.updateActiveMedia(sharing: [], cameras: ["camera"], participants: ["camera"])
        streams.updateActiveMedia(sharing: [], cameras: [], participants: ["camera"])
        XCTAssertTrue(renderer.isHidden, "The SDK may retain its last frame after camera-off")
        XCTAssertTrue(camera.subviews.contains {
            guard let label = $0 as? UILabel else { return false }
            return label.text == "camera" && !label.isHidden
        })

        streams.updateActiveMedia(sharing: [], cameras: ["camera"], participants: ["camera"])
        XCTAssertFalse(renderer.isHidden)

        streams.updateActiveMedia(sharing: [], cameras: [], participants: [])
        XCTAssertTrue(renderer.isHidden, "A departed participant must not leave a frozen tile")
    }

    func testLocalBroadcastDoesNotPromoteSDKRedPreview() {
        let streams = GuestStreamViews()
        let localRenderer = UIView()
        let local = streams.makeView(model: model("self", pinned: false, share: true, local: true),
                                     video: localRenderer)
        let remoteRenderer = UIView()
        _ = streams.makeView(model: model("peer", pinned: false, share: true),
                             video: remoteRenderer)
        streams.updateActiveMedia(sharing: ["self", "peer"], cameras: [],
                                  participants: ["self", "peer"])

        XCTAssertTrue(localRenderer.isHidden)
        XCTAssertFalse(remoteRenderer.isHidden)
        XCTAssertFalse(local.subviews.contains {
            guard let label = $0 as? UILabel else { return false }
            return label.text == "Sharing your screen\nOpen another app to show it" && !label.isHidden
        }, "Local sharing confidence belongs in the compact card, not a full-stage reminder")
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

    private func model(_ id: String, pinned: Bool, share: Bool, local: Bool = false) -> JazzParticipantViewModel {
        JazzParticipantViewModel(name: id, isAudioOn: false, isVideoOn: !share, isPinned: pinned,
            isSharingScreen: share, isLocal: local, id: id, isDominantSpeaker: false,
            shouldShowParticipantInfo: true, isZoomable: share, watermarkState: .hidden, displayMode: .speaker)
    }
}
