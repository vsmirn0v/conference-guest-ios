import JazzSDK
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class GuestGalleryTests: XCTestCase {
    func testReassignedRendererWithdrawsOldParticipantBeforeNewFramesArrive() async {
        let streams = GuestStreamViews()
        defer { streams.reset() }
        streams.updateParticipants(["first", "second"].map {
            .init(id: $0, name: $0, isLocal: false, microphoneOn: false, cameraOn: true, sharing: false)
        })
        let renderer = UIView()
        func model(_ id: String) -> JazzParticipantViewModel {
            .init(name: id, isAudioOn: false, isVideoOn: true, isPinned: false, isSharingScreen: false,
                  isLocal: false, id: id, isDominantSpeaker: false, shouldShowParticipantInfo: true,
                  isZoomable: false, watermarkState: .hidden, displayMode: .speaker)
        }
        let first = streams.makeView(model: model("first"), video: renderer)
        var items = await snapshot(streams)
        XCTAssertTrue(items.first { $0.id.participant == "first" }?.renderer === renderer)
        streams.onGalleryPresentation = { items = $0 }
        let second = streams.makeView(model: model("second"), video: renderer)
        XCTAssertNil(items.first { $0.id.participant == "first" }?.renderer,
                     "The old tile must retire synchronously before reassigned renderer callbacks arrive")
        items = await snapshot(streams)
        XCTAssertNil(items.first { $0.id.participant == "first" }?.renderer)
        XCTAssertTrue(items.first { $0.id.participant == "second" }?.renderer === renderer)
        let originalCamera = UIView()
        let restored = streams.makeView(model: model("first"), video: originalCamera)
        items = await snapshot(streams)
        XCTAssertTrue(items.first { $0.id.participant == "first" }?.renderer === originalCamera)
        XCTAssertTrue(items.first { $0.id.participant == "second" }?.renderer === renderer)
        withExtendedLifetime([first, second, restored]) {}
    }

    func testNewSignaledSharePrecedesRendererAndDoesNotReuseOldCameraPixels() async {
        let streams = GuestStreamViews()
        defer { streams.reset() }
        let camera = streams.makeView(model: JazzParticipantViewModel(name: "Camera", isAudioOn: false,
            isVideoOn: true, isPinned: false, isSharingScreen: false, isLocal: false, id: "camera",
            isDominantSpeaker: false, shouldShowParticipantInfo: false, isZoomable: false,
            watermarkState: .hidden, displayMode: .speaker), video: UIView())
        streams.setBackgrounded(true)
        var signaled: GuestStreamViews.PinTarget?, selected: StreamViewport?
        streams.onFloatingTargetChanged = { signaled = $0 }
        streams.onFloatingVideo = { viewport, _, _, _ in selected = viewport }
        streams.updateParticipants([
            .init(id: "camera", name: "Camera", isLocal: false, microphoneOn: false, cameraOn: true, sharing: false),
            .init(id: "presenter", name: "Presenter", isLocal: false, microphoneOn: false, cameraOn: false, sharing: true)
        ])
        _ = await snapshot(streams)
        XCTAssertEqual(signaled, .init(participant: "presenter", isShare: true))
        XCTAssertNil(selected, "A share startup must not use the previous camera's prepared frame")
        streams.setPin(.init(participant: "camera", isShare: false))
        _ = await snapshot(streams)
        XCTAssertEqual(signaled, .init(participant: "camera", isShare: false))
        XCTAssertTrue(selected === camera, "An explicit pin retains precedence over automatic screen sharing")
        streams.displayMode = .audioOnly
        _ = await snapshot(streams)
        XCTAssertNil(signaled); XCTAssertNil(selected)
    }

    func testMultipleSharesUseTheSameSignaledAndRenderedTargetWhenJoinOrderDiffers() async {
        let streams = GuestStreamViews()
        defer { streams.reset() }
        func participant(_ id: String) -> GuestStreamViews.Participant {
            .init(id: id, name: id, isLocal: false, microphoneOn: false, cameraOn: false, sharing: true)
        }
        streams.updateParticipants([participant("b")])
        _ = await snapshot(streams)
        streams.updateParticipants([participant("b"), participant("a")])
        let tiles = ["a", "b"].map { id in
            streams.makeView(model: JazzParticipantViewModel(name: id, isAudioOn: false, isVideoOn: true,
                isPinned: false, isSharingScreen: true, isLocal: false, id: id, isDominantSpeaker: false,
                shouldShowParticipantInfo: false, isZoomable: false, watermarkState: .hidden,
                displayMode: .speaker), video: UIView())
        }
        streams.setBackgrounded(true)
        var signaled: GuestStreamViews.PinTarget?, selected: StreamViewport?
        streams.onFloatingTargetChanged = { signaled = $0 }
        streams.onFloatingVideo = { viewport, _, _, _ in selected = viewport }
        _ = await snapshot(streams)
        XCTAssertEqual(signaled, .init(participant: "a", isShare: true))
        XCTAssertTrue(selected === tiles[0])
        withExtendedLifetime(tiles) {}
    }

    func testExplicitSelectionResetsBrowsingCursorIncludingSamePinAndUnpin() async {
        let streams = GuestStreamViews()
        streams.updateParticipants((0..<5).map {
            .init(id: "p\($0)", name: "Person \($0)", isLocal: false,
                  microphoneOn: false, cameraOn: false, sharing: false)
        })
        _ = await snapshot(streams)
        streams.setPin(.init(participant: "p1", isShare: false))
        streams.browse(1)
        XCTAssertEqual(streams.pinnedTarget?.participant, "p2")
        streams.setPin(.init(participant: "p3", isShare: false))
        streams.browse(1)
        XCTAssertEqual(streams.pinnedTarget?.participant, "p4")
        streams.setPin(.init(participant: "p4", isShare: false))
        streams.browse(-1)
        XCTAssertEqual(streams.pinnedTarget?.participant, "p3")
        streams.setPin(nil)
        let delivered = expectation(description: "Return to automatic selection")
        streams.onStagePresentation = {
            XCTAssertFalse($0.browsing); XCTAssertTrue($0.automatic)
            XCTAssertEqual($0.target?.participant, "p0"); delivered.fulfill()
        }
        streams.refreshSelection()
        await fulfillment(of: [delivered], timeout: 2)
    }
    func testRosterOrderAndManualCameraOffSelectionSurviveSpeakerChanges() async {
        let streams = GuestStreamViews()
        let first = GuestStreamViews.Participant(id: "a", name: "Anna", isLocal: false, microphoneOn: false, cameraOn: false, sharing: false)
        let second = GuestStreamViews.Participant(id: "b", name: "Boris", isLocal: false, microphoneOn: true, cameraOn: false, sharing: false)
        streams.updateParticipants([first, second])
        let initial = await snapshot(streams)
        streams.setPin(.init(participant: "a", isShare: false))
        streams.updateParticipants([second, first])
        let next = await snapshot(streams)
        XCTAssertEqual(initial.map(\.id), next.map(\.id))
        XCTAssertEqual(streams.pinnedTarget, .init(participant: "a", isShare: false))
        streams.browse(1)
        XCTAssertEqual(streams.pinnedTarget, .init(participant: "b", isShare: false))
        streams.useAutomaticView()
        XCTAssertNil(streams.pinnedTarget)
    }
    func testGalleryIncludesCameraOffPeopleAndUnrenderedStreams() async {
        let streams = GuestStreamViews()
        streams.updateParticipants([
            .init(id: "c", name: "Camera off", isLocal: false, microphoneOn: false, cameraOn: false, sharing: false),
            .init(id: "b", name: "Camera on", isLocal: false, microphoneOn: true, cameraOn: true, sharing: true),
            .init(id: "a", name: "Me", isLocal: true, microphoneOn: false, cameraOn: false, sharing: true)
        ])
        let items = await snapshot(streams)
        XCTAssertEqual(items.map(\.id.participant), ["a", "b", "b", "c"])
        XCTAssertEqual(items.map(\.id.isShare), [false, false, true, false])
        XCTAssertEqual(items.map(\.active), [false, true, true, false])
        XCTAssertTrue(items.allSatisfy { $0.renderer == nil })
        streams.displayMode = .screenShares
        let shares = await snapshot(streams)
        XCTAssertEqual(shares.count, 1)
        XCTAssertEqual(shares.first?.id.participant, "b")
        streams.displayMode = .audioOnly
        let audio = await snapshot(streams)
        XCTAssertTrue(audio.isEmpty)
    }

    func testGalleryNeverReparentsProviderRendererAndKeepsTileIdentity() async {
        let streams = GuestStreamViews()
        let renderer = UIView()
        let model = JazzParticipantViewModel(name: "Remote", isAudioOn: true, isVideoOn: true,
            isPinned: false, isSharingScreen: false, isLocal: false, id: "remote", isDominantSpeaker: false,
            shouldShowParticipantInfo: true, isZoomable: false, watermarkState: .hidden, displayMode: .tile)
        let providerTile = streams.makeView(model: model, video: renderer)
        let originalParent = renderer.superview
        streams.updateParticipants([.init(id: "remote", name: "Remote", isLocal: false,
            microphoneOn: true, cameraOn: true, sharing: false)])
        let items = await snapshot(streams)
        XCTAssertTrue(items.first?.renderer === renderer)
        let gallery = GuestGalleryView()
        gallery.update(items)
        let first = gallery.subviews.first
        gallery.update(items)
        XCTAssertTrue(first === gallery.subviews.first)
        XCTAssertTrue(renderer.superview === originalParent)
        withExtendedLifetime(providerTile) {}
    }

    func testGalleryKeepsVisiblePageThroughMetadataAndGeometryChanges() throws {
        let gallery = GuestGalleryView(frame: CGRect(x: 0, y: 0, width: 390, height: 570))
        let items: [GuestStreamViews.GalleryItem] = (0..<12).map {
            .init(id: .init(participant: "p\($0)", isShare: false), name: "Person \($0)",
                  microphoneOn: false, active: false, speaking: false, watermark: nil, renderer: nil)
        }
        gallery.update(items); gallery.layoutIfNeeded()
        gallery.movePage(1)
        gallery.setSpeaker("p1", available: true)
        gallery.update(items); gallery.layoutIfNeeded()
        XCTAssertEqual(gallery.page, 1)
        let anchor = gallery.page * (try XCTUnwrap(gallery.pagination).capacity)
        gallery.frame.size = CGSize(width: 304, height: 350); gallery.layoutIfNeeded()
        let layout = try XCTUnwrap(gallery.pagination)
        XCTAssertTrue(layout.range(page: gallery.page, count: items.count).contains(anchor))
        XCTAssertEqual(gallery.contentOffset.x, CGFloat(gallery.page) * gallery.bounds.width)
    }

    private func snapshot(_ streams: GuestStreamViews) async -> [GuestStreamViews.GalleryItem] {
        await withCheckedContinuation { continuation in
            streams.onGalleryPresentation = { items in
                streams.onGalleryPresentation = nil
                continuation.resume(returning: items)
            }
            streams.refreshSelection()
        }
    }
}
