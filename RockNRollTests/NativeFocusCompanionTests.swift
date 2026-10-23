import ConferenceCore
import LiveKitWebRTC
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class NativeFocusCompanionTests: XCTestCase {
    private func host() throws -> (UIWindow, RockCallViewController) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let call = RockCallViewController(title: "Meeting", catchUp: CatchUpStore(), chat: ChatStore())
        window.rootViewController = call; window.makeKeyAndVisible()
        return (window, call)
    }
    private func participant(_ id: String, name: String? = nil, shareOn: Bool = true,
                             share: LKRTCVideoTrack?, camera: LKRTCVideoTrack? = nil, speaking: Bool = false) -> CallParticipant {
        var videos: [CallVideoStream] = []
        if let camera { videos.append(.init(id: camera.trackId, source: .camera, track: .native(camera))) }
        if let share { videos.append(.init(id: share.trackId, source: .screenShareVideo, track: .native(share))) }
        return .init(id: id, name: name ?? id, isLocal: false, microphoneOn: true,
            cameraOn: camera != nil, screenShareOn: shareOn, isSpeaking: speaking, videoTracks: videos)
    }
    func testShareSurvivesTrackGapSpeakerChangesSecondShareAndPublicationReplacement() throws {
        let (window, call) = try host()
        defer { window.isHidden = true }
        let factory = try NativeRTCPeer.makeFactory(), source = factory.videoSource()
        let share = factory.videoTrack(with: source, trackId: "share-one")
        let camera = factory.videoTrack(with: source, trackId: "camera-one")
        let second = factory.videoTrack(with: source, trackId: "share-two")
        func render(_ participants: [CallParticipant]) { call.render(snapshot: .init(participants: participants)); call.view.layoutIfNeeded() }
        render([participant("presenter", share: share, camera: camera)])
        let scroll = try XCTUnwrap(descendants(call.view).compactMap { $0 as? UIScrollView }.first { $0.accessibilityIdentifier == share.trackId })
        scroll.setZoomScale(2, animated: false)
        let viewport = scroll.bounds.size
        render([participant("other", share: second, speaking: true), participant("presenter", name: "Renamed", share: nil, camera: camera)])
        XCTAssertEqual(call.primarySourceForTesting, "presenter.screen")
        XCTAssertEqual(call.pictureInPictureSourceForTesting, share.trackId)
        XCTAssertTrue(descendants(call.view).contains { $0 === scroll })
        XCTAssertEqual(scroll.zoomScale, 2, accuracy: 0.01)
        XCTAssertEqual(scroll.bounds.size, viewport)
        let replacement = factory.videoTrack(with: source, trackId: "share-replacement")
        render([participant("other", share: second), participant("presenter", share: replacement, camera: camera)])
        XCTAssertEqual(call.primarySourceForTesting, "presenter.screen")
        XCTAssertEqual(call.pictureInPictureSourceForTesting, replacement.trackId)
        XCTAssertEqual(scroll.accessibilityIdentifier, replacement.trackId)
        XCTAssertTrue(descendants(call.view).contains { $0 === scroll })
        XCTAssertEqual(scroll.zoomScale, 2, accuracy: 0.01)
        render([participant("other", share: second), participant("presenter", shareOn: false, share: nil, camera: camera)])
        XCTAssertEqual(call.primarySourceForTesting, "other.screen")
        XCTAssertFalse(descendants(call.view).contains { $0 === scroll })
    }
    func testSignaledShareWithoutRendererNeverFallsBackToCamera() throws {
        let (window, call) = try host()
        defer { window.isHidden = true }
        let factory = try NativeRTCPeer.makeFactory()
        let camera = factory.videoTrack(with: factory.videoSource(), trackId: "camera")
        call.render(snapshot: .init(participants: [participant("presenter", share: nil, camera: camera)]))
        call.view.layoutIfNeeded()
        XCTAssertEqual(call.primarySourceForTesting, "presenter.screen")
        XCTAssertNil(call.pictureInPictureSourceForTesting)
        XCTAssertTrue(descendants(call.view).contains { $0.accessibilityIdentifier == "presenter.screen" })
        XCTAssertFalse(descendants(call.view).contains { $0.accessibilityIdentifier == camera.trackId })
        let companion = try XCTUnwrap(descendants(call.view).compactMap { $0 as? PresenterCompanionView }.first)
        companion.onFocusCamera?(); call.view.layoutIfNeeded()
        XCTAssertEqual(call.primarySourceForTesting, "presenter.camera")
        XCTAssertNil(call.pictureInPictureSourceForTesting)
        XCTAssertTrue(call.visibleVideoQualities(foreground: false, wantsVideo: true).isEmpty,
            "A share waiting for pixels must not request the foreground camera for PiP")
    }
    func testExplicitSecondShareKeepsPresenterAndPiPAffinityDuringCameraFocus() throws {
        let (window, call) = try host()
        defer { window.isHidden = true }
        let factory = try NativeRTCPeer.makeFactory(), source = factory.videoSource()
        let aShare = factory.videoTrack(with: source, trackId: "a-share")
        let bShare = factory.videoTrack(with: source, trackId: "b-share")
        let bCamera = factory.videoTrack(with: source, trackId: "b-camera")
        call.render(snapshot: .init(participants: [participant("a", share: aShare), participant("b", share: bShare, camera: bCamera)]))
        call.view.layoutIfNeeded()
        XCTAssertEqual(call.primarySourceForTesting, "a.screen")
        let sourceSelector = try XCTUnwrap(descendants(call.view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "Meeting source selector" })
        let bChoice = try XCTUnwrap(sourceSelector.menu?.children.compactMap { $0 as? UIMenu }
            .flatMap(\.children).compactMap { $0 as? UIAction }.first { $0.identifier.rawValue == "b.screen" })
        UIButton(primaryAction: bChoice).sendActions(for: .touchUpInside)
        call.view.layoutIfNeeded()
        XCTAssertEqual(call.primarySourceForTesting, "b.screen")
        let companion = try XCTUnwrap(descendants(call.view).compactMap { $0 as? PresenterCompanionView }.first)
        XCTAssertEqual(descendants(companion).compactMap { $0 as? CallVideoView }.first?.track?.identity, CallVideoSource.native(bCamera).identity)
        companion.onFocusCamera?(); call.view.layoutIfNeeded()
        XCTAssertEqual(call.primarySourceForTesting, "b.camera")
        XCTAssertEqual(call.pictureInPictureSourceForTesting, bShare.trackId)
        call.render(snapshot: .init(participants: [participant("a", share: aShare, speaking: true), participant("b", share: bShare, camera: bCamera)]))
        call.view.layoutIfNeeded()
        XCTAssertEqual(call.primarySourceForTesting, "b.camera")
        XCTAssertEqual(call.pictureInPictureSourceForTesting, bShare.trackId)
        companion.onReturnToShare?(); call.view.layoutIfNeeded()
        XCTAssertEqual(call.primarySourceForTesting, "b.screen")
        XCTAssertEqual(call.pictureInPictureSourceForTesting, bShare.trackId)
    }
    func testCompanionUsesSharerCameraAndExplicitFocusKeepsPiPShareAndZoom() throws {
        let (window, call) = try host()
        defer { window.isHidden = true }
        let factory = try NativeRTCPeer.makeFactory(), source = factory.videoSource()
        let share = factory.videoTrack(with: source, trackId: "share")
        let camera = factory.videoTrack(with: source, trackId: "presenter-camera")
        let speakerCamera = factory.videoTrack(with: source, trackId: "speaker-camera")
        func render(_ camera: LKRTCVideoTrack?) {
            call.render(snapshot: .init(participants: [participant("presenter", share: share, camera: camera),
                participant("speaker", shareOn: false, share: nil, camera: speakerCamera, speaking: true)]))
            call.view.layoutIfNeeded()
        }
        render(camera)
        let companion = try XCTUnwrap(descendants(call.view).compactMap { $0 as? PresenterCompanionView }.first)
        XCTAssertTrue(companion.isPreviewVisible)
        window.isHidden = true
        XCTAssertFalse(companion.isPreviewVisible)
        XCTAssertNil(descendants(companion).compactMap { $0 as? CallVideoView }.first?.track)
        window.makeKeyAndVisible()
        XCTAssertTrue(companion.isPreviewVisible)
        XCTAssertEqual(descendants(companion).compactMap { $0 as? CallVideoView }.first?.track?.identity, CallVideoSource.native(camera).identity)
        var demand = call.visibleVideoQualities(foreground: true, wantsVideo: true)
        XCTAssertEqual(demand[share.trackId], true)
        XCTAssertEqual(demand[camera.trackId], false)
        XCTAssertNil(demand[speakerCamera.trackId])
        let scroll = try XCTUnwrap(descendants(call.view).compactMap { $0 as? UIScrollView }.first { $0.accessibilityIdentifier == share.trackId })
        scroll.setZoomScale(2, animated: false)
        companion.setCollapsed(true); call.view.layoutIfNeeded()
        demand = call.visibleVideoQualities(foreground: true, wantsVideo: true)
        XCTAssertNil(demand[camera.trackId])
        XCTAssertEqual(scroll.zoomScale, 2, accuracy: 0.01)
        companion.setCollapsed(false); call.view.layoutIfNeeded()
        companion.onFocusCamera?(); call.view.layoutIfNeeded()
        XCTAssertEqual(call.primarySourceForTesting, "presenter.camera")
        XCTAssertEqual(call.pictureInPictureSourceForTesting, share.trackId)
        XCTAssertFalse(companion.isPreviewVisible)
        render(nil)
        XCTAssertEqual(call.primarySourceForTesting, "presenter.camera")
        XCTAssertEqual(call.pictureInPictureSourceForTesting, share.trackId)
        companion.onReturnToShare?(); call.view.layoutIfNeeded()
        XCTAssertEqual(call.primarySourceForTesting, "presenter.screen")
        XCTAssertEqual(scroll.zoomScale, 2, accuracy: 0.01)
        render(camera)
        call.setHeld(true); call.view.layoutIfNeeded()
        XCTAssertFalse(companion.isPreviewVisible)
        XCTAssertNil(call.visibleVideoQualities(foreground: true, wantsVideo: false)[camera.trackId])
        call.setHeld(false); call.view.layoutIfNeeded()
        XCTAssertTrue(companion.isPreviewVisible)
        call.setDisplayMode(.audioOnly); call.view.layoutIfNeeded()
        XCTAssertFalse(companion.isPreviewVisible)
        call.setDisplayMode(.all); call.view.layoutIfNeeded()
        XCTAssertTrue(companion.isPreviewVisible)
        _ = call.visibleVideoQualities(foreground: false, wantsVideo: true)
        XCTAssertNil(descendants(companion).compactMap { $0 as? CallVideoView }.first?.track)
    }
    func testFocusedCameraStopsInlineRenderingWhenWindowOrApplicationHidesWhilePiPShareRemains() throws {
        let (window, call) = try host()
        defer { window.isHidden = true }
        let factory = try NativeRTCPeer.makeFactory(), source = factory.videoSource()
        let share = factory.videoTrack(with: source, trackId: "share")
        let camera = factory.videoTrack(with: source, trackId: "presenter-camera")
        call.render(snapshot: .init(participants: [participant("presenter", share: share, camera: camera)]))
        call.view.layoutIfNeeded()
        let companion = try XCTUnwrap(descendants(call.view).compactMap { $0 as? PresenterCompanionView }.first)
        companion.onFocusCamera?(); call.view.layoutIfNeeded()
        let mainCamera = try XCTUnwrap(descendants(call.view).compactMap { $0 as? CallVideoView }
            .first { $0.track?.identity == CallVideoSource.native(camera).identity })
        XCTAssertTrue(mainCamera.isEnabled)
        window.isHidden = true
        XCTAssertFalse(mainCamera.isEnabled)
        XCTAssertEqual(call.visibleVideoQualities(foreground: true, wantsVideo: true), [share.trackId: true])
        window.makeKeyAndVisible()
        XCTAssertTrue(mainCamera.isEnabled)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertFalse(mainCamera.isEnabled)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        call.render(snapshot: .init(participants: [participant("presenter", share: share, camera: camera)]))
        call.view.layoutIfNeeded()
        XCTAssertEqual(call.visibleVideoQualities(foreground: true, wantsVideo: true), [share.trackId: true])
        XCTAssertFalse(mainCamera.isEnabled)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(mainCamera.isEnabled)
        XCTAssertEqual(call.pictureInPictureSourceForTesting, share.trackId)
    }
    private func descendants(_ root: UIView) -> [UIView] { root.subviews.flatMap { [$0] + descendants($0) } }
}
