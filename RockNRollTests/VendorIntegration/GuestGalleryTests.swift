import JazzSDK
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class GuestGalleryTests: XCTestCase {
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
