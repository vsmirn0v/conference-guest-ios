import JazzSDK
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class GuestGalleryTests: XCTestCase {
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
