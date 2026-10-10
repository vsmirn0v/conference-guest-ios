import AVFoundation
import JazzSDK
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class CameraPreviewPresentationTests: XCTestCase {
    func testSelfPreviewMirrorsFrontAndUnspecifiedMacCamerasButNotRearCamera() {
        XCTAssertTrue(CameraPreviewPresentation.isMirrored(position: .front))
        XCTAssertTrue(CameraPreviewPresentation.isMirrored(position: .unspecified))
        XCTAssertTrue(CameraPreviewPresentation.isMirrored(device: nil))
        XCTAssertFalse(CameraPreviewPresentation.isMirrored(position: .back))
    }

    func testReflectionIsHorizontalAfterEveryFrameRotation() {
        for rotation in [0, 90, 180, 270] {
            let original = CameraPreviewPresentation.transform(rotation: rotation, mirrored: false)
            let mirror = CameraPreviewPresentation.transform(rotation: rotation, mirrored: true)
            for point in [CGPoint(x: 17, y: 4), CGPoint(x: -3, y: 11)] {
                let upright = point.applying(original), reflected = point.applying(mirror)
                XCTAssertEqual(reflected.x, -upright.x, accuracy: 0.00001)
                XCTAssertEqual(reflected.y, upright.y, accuracy: 0.00001)
            }
        }
    }

    func testDisplayReflectionDoesNotMirrorLabelsOrChangeVideoGeometry() {
        let video = GuestSampleBufferView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        video.layoutIfNeeded()
        let layer = video.layer.sublayers!.first!
        let size = layer.bounds.size
        video.mirrored = true
        XCTAssertEqual(layer.affineTransform(), CameraPreviewPresentation.transform(rotation: 0, mirrored: true))
        XCTAssertEqual(layer.bounds.size, size)
        XCTAssertEqual(video.transform, .identity, "Only the image layer is reflected")
        video.mirrored = false
        XCTAssertEqual(layer.affineTransform(), .identity)
    }

    func testGuestSelfMirrorPropagatesToStageGalleryAndPiPAndUpdatesOnCameraFlip() async throws {
        let streams = GuestStreamViews()
        defer { streams.reset() }
        var mirrored = true
        streams.localCameraMirrored = { mirrored }
        func model(_ id: String, local: Bool, share: Bool) -> JazzParticipantViewModel {
            .init(name: id, isAudioOn: false, isVideoOn: true, isPinned: false,
                isSharingScreen: share, isLocal: local, id: id, isDominantSpeaker: false,
                shouldShowParticipantInfo: true, isZoomable: share, watermarkState: .hidden, displayMode: .tile)
        }
        let local = streams.makeView(model: model("me", local: true, share: false), video: UIView()) as! StreamViewport
        let remote = streams.makeView(model: model("other", local: false, share: false), video: UIView()) as! StreamViewport
        let share = streams.makeView(model: model("share", local: false, share: true), video: UIView()) as! StreamViewport
        streams.updateParticipants([
            .init(id: "me", name: "Me", isLocal: true, microphoneOn: false, cameraOn: true, sharing: false),
            .init(id: "other", name: "Other", isLocal: false, microphoneOn: false, cameraOn: true, sharing: false)
        ])
        var gallery: [GuestStreamViews.GalleryItem] = []
        streams.onGalleryPresentation = { gallery = $0 }
        streams.refreshSelection()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(local.isCameraMirrored)
        XCTAssertFalse(remote.isCameraMirrored)
        XCTAssertFalse(share.isCameraMirrored)
        XCTAssertTrue(gallery.first { $0.id.participant == "me" }?.mirrored == true)
        let floating = GuestVideoPictureInPicture(sourceView: UIView())
        floating.select(viewport: local, name: "Me", isScreenShare: false)
        XCTAssertTrue(floating.isMirrored)
        mirrored = false
        NotificationCenter.default.post(name: GuestCaptureDeviceObserver.changed, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(local.isCameraMirrored)
        XCTAssertFalse(floating.isMirrored)
        XCTAssertTrue(gallery.allSatisfy { !$0.mirrored })
        floating.end()
    }
}
