import AVFoundation
import JazzSDK
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class GuestStreamSelectionTests: XCTestCase {
    func testBrowsingUsesRosterBeforeOffscreenRendererExists() async throws {
        let streams = GuestStreamViews()
        let cameraRenderer = UIView()
        let camera = streams.makeView(model: model("a", pinned: false, share: false), video: cameraRenderer)
        streams.updateParticipants([
            .init(id: "a", name: "Aram", isLocal: false, microphoneOn: false, cameraOn: true, sharing: false),
            .init(id: "b", name: "Ani", isLocal: false, microphoneOn: true, cameraOn: true, sharing: false)
        ])
        // Neither SDK source is visible; the main stage owns its own viewport.
        var presentation = await stageSnapshot(streams)
        XCTAssertEqual(presentation.count, 2)
        XCTAssertEqual(presentation.target?.participant, "a")
        streams.browse(1)
        presentation = await stageSnapshot(streams)
        XCTAssertEqual(presentation.target?.participant, "b")
        XCTAssertEqual(presentation.name, "Ani")
        XCTAssertTrue(presentation.browsing)
        XCTAssertTrue(presentation.active, "Await the renderer rather than pretending its camera is off")

        let renderer = UIView()
        let pipModel = JazzParticipantViewModel(name: "Ani", isAudioOn: true, isVideoOn: true,
            isPinned: false, isSharingScreen: false, isLocal: false, id: "b",
            isDominantSpeaker: false, shouldShowParticipantInfo: true,
            isZoomable: false, watermarkState: .hidden, displayMode: .pip)
        let offscreen = streams.makeView(model: pipModel, video: renderer)
        offscreen.isHidden = true
        let selected = expectation(description: "Use the offscreen SDK renderer")
        streams.onPreferredVideo = { viewport, _, _ in
            XCTAssertTrue(viewport === offscreen)
            selected.fulfill()
        }
        streams.refreshSelection()
        await fulfillment(of: [selected], timeout: 2)
        streams.onPreferredVideo = nil
        withExtendedLifetime([camera, offscreen, cameraRenderer, renderer]) {}
    }

    func testRosterNavigationSurvivesCameraOffAndParticipantDeparture() async {
        let streams = GuestStreamViews()
        let first = GuestStreamViews.Participant(id: "a", name: "Aram", isLocal: false,
            microphoneOn: false, cameraOn: false, sharing: false)
        let second = GuestStreamViews.Participant(id: "b", name: "Ani", isLocal: false,
            microphoneOn: true, cameraOn: false, sharing: false)
        streams.updateParticipants([first, second])
        var presentation = await stageSnapshot(streams)
        XCTAssertEqual(presentation.count, 2)
        XCTAssertEqual(presentation.name, "Aram")
        streams.browse(1)
        presentation = await stageSnapshot(streams)
        XCTAssertEqual(presentation.name, "Ani")
        XCTAssertFalse(presentation.active)
        XCTAssertTrue(presentation.microphoneOn)
        streams.updateParticipants([first])
        presentation = await stageSnapshot(streams)
        XCTAssertEqual(presentation.count, 1)
        XCTAssertEqual(presentation.name, "Aram")
        XCTAssertFalse(presentation.browsing)
        streams.reset()
        presentation = await stageSnapshot(streams)
        XCTAssertEqual(presentation, .empty)
    }

    func testIdleSelfTileDoesNotReplaceWaitingScreen() async {
        let streams = GuestStreamViews()
        let renderer = UIView()
        let idle = JazzParticipantViewModel(name: "My contact", isAudioOn: false, isVideoOn: false,
            isPinned: false, isSharingScreen: false, isLocal: true, id: "self",
            isDominantSpeaker: false, shouldShowParticipantInfo: true,
            isZoomable: false, watermarkState: .hidden, displayMode: .speaker)
        let tile = streams.makeView(model: idle, video: renderer)
        streams.updateParticipants([.init(id: "self", name: "My contact", isLocal: true,
            microphoneOn: false, cameraOn: false, sharing: false)])
        let presentation = await stageSnapshot(streams)
        XCTAssertEqual(presentation, .empty)
        withExtendedLifetime([tile, renderer]) {}
    }

    func testOneRemoteStillAllowsBrowsingSelfWithoutMakingSelfTheDefault() async {
        let streams = GuestStreamViews()
        let local = GuestStreamViews.Participant(id: "a-self", name: "My contact", isLocal: true,
            microphoneOn: false, cameraOn: false, sharing: false)
        let remote = GuestStreamViews.Participant(id: "b-peer", name: "Aram", isLocal: false,
            microphoneOn: true, cameraOn: false, sharing: false)
        streams.updateParticipants([local, remote])
        var presentation = await stageSnapshot(streams)
        XCTAssertEqual(presentation.count, 2)
        XCTAssertEqual(presentation.name, "Aram", "An idle self tile cannot become the automatic main stage")
        streams.browse(1)
        presentation = await stageSnapshot(streams)
        XCTAssertEqual(presentation.name, "My contact")
        XCTAssertTrue(presentation.browsing)
        streams.useAutomaticView()
        presentation = await stageSnapshot(streams)
        XCTAssertEqual(presentation.name, "Aram")
        streams.updateParticipants([local])
        presentation = await stageSnapshot(streams)
        XCTAssertNil(presentation.name)
    }

    private func stageSnapshot(_ streams: GuestStreamViews) async -> GuestStreamViews.Presentation {
        var value = GuestStreamViews.Presentation.empty
        let delivered = expectation(description: "Stage presentation")
        streams.onStagePresentation = { value = $0; delivered.fulfill() }
        streams.refreshSelection()
        await fulfillment(of: [delivered], timeout: 2)
        // Leave the app-owned stage attached; later refreshes may occur during browsing.
        streams.onStagePresentation = { _ in }
        return value
    }

    func testSpeakerChangesKeepTheSharedScreenViewport() {
        let streams = GuestStreamViews()
        let renderer = UIView()
        let original = streams.makeView(model: model("share", pinned: false, share: true), video: renderer)
        for speaking in [true, false, true, false] {
            let updated = streams.makeView(model: model("share", pinned: false, share: true,
                                                       speaking: speaking), video: renderer)
            XCTAssertTrue(updated === original,
                          "Speaker metadata must not expose a new uncorrected video surface")
        }
    }

    func testMetadataUpdatesKeepCorrectedPixelsAndRefreshPresentation() throws {
        let streams = GuestStreamViews()
        let renderer = UIView()
        let original = try XCTUnwrap(streams.makeView(model: model("share", pinned: false, share: true),
                                                     video: renderer) as? StreamViewport)
        original.showCorrectedVideo(try sample(), rotation: 0)
        let surface = try XCTUnwrap(descendants(original).first { $0 is GuestSampleBufferView })
        let updatedModel = JazzParticipantViewModel(name: "Renamed musician", isAudioOn: true,
            isVideoOn: true, isPinned: true, isSharingScreen: true, isLocal: false,
            id: "share", isDominantSpeaker: true, shouldShowParticipantInfo: true,
            isZoomable: true, watermarkState: .visible("Meeting watermark"), displayMode: .speaker)
        let updated = streams.makeView(model: updatedModel, video: renderer)
        XCTAssertTrue(updated === original)
        XCTAssertTrue(descendants(updated).first { $0 is GuestSampleBufferView } === surface)
        let labels = descendants(updated).compactMap { $0 as? UILabel }
        XCTAssertTrue(labels.contains { $0.text == "  Renamed musician · Pinned  " && !$0.isHidden })
        XCTAssertTrue(labels.contains { $0.text == "Meeting watermark" && !$0.isHidden })
        XCTAssertTrue(updated.accessibilityElementsHidden == false)
        XCTAssertTrue(descendants(updated).compactMap { $0 as? UIButton }.contains {
            $0.accessibilityLabel == "Pin Renamed musician screen share"
        })
    }

    func testReplacingTheDecodedRendererDoesNotReuseItsOldSurface() {
        let streams = GuestStreamViews()
        let original = streams.makeView(model: model("share", pinned: false, share: true), video: UIView())
        let replacement = streams.makeView(model: model("share", pinned: false, share: true), video: UIView())
        XCTAssertFalse(replacement === original)
        XCTAssertFalse(descendants(replacement).contains { $0 is GuestSampleBufferView })
    }

    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func sample() throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA,
                                           nil, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero,
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
            sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

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

    func testBrowsingStaysSelectedAcrossSpeakerUpdatesUntilAutomaticView() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let streams = GuestStreamViews()
        let cameraRenderer = UIView()
        let camera = streams.makeView(model: model("camera", pinned: false, share: false), video: cameraRenderer)
        let share = streams.makeView(model: model("share", pinned: false, share: true), video: UIView())
        for tile in [camera, share] { tile.frame = CGRect(x: 0, y: 100, width: 300, height: 200); controller.view.addSubview(tile) }
        await assertSelection(streams, mode: .all, expected: share)
        streams.browse(1)
        await assertSelection(streams, mode: .all, expected: camera)
        XCTAssertEqual(streams.browsedTarget, .init(participant: "camera", isShare: false))
        for speaking in [true, false, true] {
            _ = streams.makeView(model: model("camera", pinned: false, share: false, speaking: speaking), video: cameraRenderer)
            await assertSelection(streams, mode: .all, expected: camera)
        }
        streams.useAutomaticView()
        await assertSelection(streams, mode: .all, expected: share)
        XCTAssertNil(streams.browsedTarget)
    }

    func testMainStageReceivesWatermarkAndMutedState() async throws {
        let streams = GuestStreamViews()
        let renderer = UIView()
        let model = JazzParticipantViewModel(name: "Ani", isAudioOn: false, isVideoOn: true,
            isPinned: false, isSharingScreen: true, isLocal: false, id: "share",
            isDominantSpeaker: false, shouldShowParticipantInfo: true, isZoomable: true,
            watermarkState: .visible("Meeting watermark"), displayMode: .speaker)
        let tile = streams.makeView(model: model, video: renderer)
        tile.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let delivered = expectation(description: "Stage metadata")
        streams.onStagePresentation = { presentation in
            XCTAssertEqual(presentation.watermark, "Meeting watermark")
            XCTAssertFalse(presentation.microphoneOn)
            XCTAssertEqual(presentation.name, "Ani")
            XCTAssertTrue(presentation.active)
            delivered.fulfill()
        }
        streams.setBackgrounded(true)
        await fulfillment(of: [delivered], timeout: 2)
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

    private func model(_ id: String, pinned: Bool, share: Bool, local: Bool = false,
                       speaking: Bool = false) -> JazzParticipantViewModel {
        JazzParticipantViewModel(name: id, isAudioOn: false, isVideoOn: !share, isPinned: pinned,
            isSharingScreen: share, isLocal: local, id: id, isDominantSpeaker: speaking,
            shouldShowParticipantInfo: true, isZoomable: share, watermarkState: .hidden, displayMode: .speaker)
    }
}
