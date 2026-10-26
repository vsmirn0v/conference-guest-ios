import JazzSDK
import AVFoundation
import UIKit
import WebRTC
import XCTest
@testable import RockNRoll

@MainActor
final class GuestGalleryTests: XCTestCase {
    func testQualifiedCameraHasVideoSourceWithoutSDKViewAndOnlyVisibleTileAttaches() async throws {
        let factory = RTCPeerConnectionFactory(), source = factory.videoSource()
        let track = factory.videoTrack(with: source, trackId: "direct-camera")
        let binding = GuestPresenterCameraReceiverSource(leaseToken: UUID(), participant: "presenter", track: track)
        let streams = GuestStreamViews()
        streams.updateParticipants([
            .init(id: "presenter", name: "Presenter", isLocal: false, microphoneOn: false, cameraOn: true, sharing: true),
            .init(id: "other", name: "Other", isLocal: false, microphoneOn: false, cameraOn: true, sharing: false)])
        streams.setPresenterCameraSource(binding)
        let items = await snapshot(streams)
        var item = try XCTUnwrap(items.first { $0.id.participant == "presenter" && !$0.id.isShare })
        XCTAssertNil(item.renderer); XCTAssertTrue(item.hasVideoSource)
        XCTAssertTrue(item.receiverSource?.track === track)
        XCTAssertTrue(items.filter { $0.id.isShare || $0.id.participant != "presenter" }.allSatisfy { $0.receiverSource == nil })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let root = UIViewController(); window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true; streams.reset() }
        let tile = GuestGalleryTile(item: item, pin: {})
        tile.frame = window.bounds; root.view.addSubview(tile)
        let capturer = RTCVideoCapturer(delegate: source)
        func produce() { source.capturer(capturer, didCapture: frame(luma: 96)) }
        produce(); try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(tile.evidenceForTesting["tapFrames"] as? Int, 0, "Invisible tiles must not attach a renderer")
        tile.setVisible(true)
        let delivery = try XCTUnwrap(sampleView(in: tile)?.existingFrameDelivery())
        let first = expectation(description: "Direct camera reaches displayed tile")
        first.assertForOverFulfill = false
        delivery.onEnqueuedForTesting = { _, accepted in if accepted { first.fulfill() } }
        produce(); await fulfillment(of: [first], timeout: 3)
        XCTAssertGreaterThan(tile.evidenceForTesting["tapFrames"] as? Int ?? 0, 0)
        item.receiverSource = .init(leaseToken: UUID(), participant: "presenter", track: track)
        tile.update(item, pin: {})
        XCTAssertFalse(delivery.isCurrent, "A new lease must retire prepared pixels even when the RTC track is reused")
        let replacement = try XCTUnwrap(sampleView(in: tile)?.existingFrameDelivery())
        tile.setVisible(false)
        XCTAssertFalse(replacement.isCurrent)
        let prepared = tile.evidenceForTesting["preparedFrames"] as? Int
        produce(); try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(tile.evidenceForTesting["preparedFrames"] as? Int, prepared)
        tile.setVisible(true)
        let resumed = try XCTUnwrap(sampleView(in: tile)?.existingFrameDelivery())
        item.receiverSource = nil; tile.update(item, pin: {})
        XCTAssertFalse(item.hasVideoSource); XCTAssertFalse(resumed.isCurrent)
        XCTAssertEqual(tile.evidenceForTesting["hasFrame"] as? Bool, false)
        produce(); try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(tile.evidenceForTesting["tapFrames"] as? Int, 0)
        XCTAssertTrue(track.isEnabled)
    }

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
        streams.setPin(.init(participant: "first", isShare: false))
        var floating: StreamViewport?
        streams.onFloatingVideo = { viewport, _, _, _ in floating = viewport }
        var items = await snapshot(streams)
        XCTAssertTrue(items.first { $0.id.participant == "first" }?.renderer === renderer)
        XCTAssertTrue(floating === first)
        streams.onGalleryPresentation = { items = $0 }
        let second = streams.makeView(model: model("second"), video: renderer)
        XCTAssertNil(items.first { $0.id.participant == "first" }?.renderer,
                     "The old tile must retire synchronously before reassigned renderer callbacks arrive")
        XCTAssertNil(floating, "Pinned stage/PiP must not display the new owner's frames")
        XCTAssertEqual(streams.pinnedTarget, .init(participant: "first", isShare: false))
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

    func testNestedRendererReassignmentRetiresAliasesButKeepsAnIndependentCamera() async {
        let streams = GuestStreamViews()
        defer { streams.reset() }
        streams.updateParticipants(["first", "second"].map {
            .init(id: $0, name: $0, isLocal: false, microphoneOn: false, cameraOn: true, sharing: false)
        })
        let renderer = RTCEAGLVideoView(frame: .zero), other = RTCEAGLVideoView(frame: .zero)
        let wrapper = UIView(); wrapper.addSubview(renderer)
        let speaker = streams.makeView(model: model("first"), video: wrapper)
        let alias = streams.makeView(model: model("first", mode: .thumbnail), video: wrapper)
        let independent = streams.makeView(model: model("first", mode: .tile), video: other)
        var items = await snapshot(streams)
        XCTAssertTrue(items.first?.renderer === renderer, "Same-owner display-mode aliases are valid")
        let nextWrapper = UIView(); nextWrapper.addSubview(renderer)
        let second = streams.makeView(model: model("second"), video: nextWrapper)
        items = await snapshot(streams)
        XCTAssertTrue(items.first { $0.id.participant == "first" }?.renderer === other)
        XCTAssertTrue(items.first { $0.id.participant == "second" }?.renderer === renderer)
        XCTAssertTrue(renderer.superview === nextWrapper, "Ownership tracking must not reparent the SDK's nested renderer")
        withExtendedLifetime([speaker, alias, independent, second]) {}
    }

    func testReassignedRendererClearsDisplayedPixelsAndRejectsRetiredFrameDelivery() async throws {
        let streams = GuestStreamViews()
        defer { streams.reset() }
        streams.updateParticipants(["first", "second"].map {
            .init(id: $0, name: $0, isLocal: false, microphoneOn: false, cameraOn: true, sharing: false)
        })
        let renderer = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        let first = streams.makeView(model: model("first"), video: renderer)
        let initial = await snapshot(streams)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let root = UIViewController(); window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let tiles = Dictionary(uniqueKeysWithValues: initial.map { item in
            (item.id, GuestGalleryTile(item: item, pin: {}))
        })
        for (index, tile) in tiles.values.enumerated() {
            tile.frame = CGRect(x: 0, y: index * 250, width: 390, height: 250)
            root.view.addSubview(tile); tile.setVisible(true); tile.layoutIfNeeded()
        }
        let firstTile = try XCTUnwrap(tiles[.init(participant: "first", isShare: false)])
        let secondTile = try XCTUnwrap(tiles[.init(participant: "second", isShare: false)])
        let firstDelivery = try XCTUnwrap(sampleView(in: firstTile)?.existingFrameDelivery())
        let firstFrame = expectation(description: "First participant pixels")
        firstFrame.assertForOverFulfill = false
        firstDelivery.onEnqueuedForTesting = { sample, accepted in
            guard accepted else { return }
            Self.assertLuma(sample, 48); firstFrame.fulfill()
        }
        // Initial mounting also clears the sink asynchronously. A camera keeps
        // producing while that flush finishes, just as during reassignment.
        for _ in 0..<3 {
            renderer.renderFrame(frame(luma: 48))
            try await Task.sleep(for: .milliseconds(80))
        }
        await fulfillment(of: [firstFrame], timeout: 2)
        // Geometry notifications run on main after background frame delivery.
        for _ in 0..<100 where firstTile.evidenceForTesting["hasFrame"] as? Bool != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(firstTile.evidenceForTesting["hasFrame"] as? Bool, true)
        let firstPrepared = firstTile.evidenceForTesting["preparedFrames"] as? Int
        streams.onGalleryPresentation = { items in
            for item in items { tiles[item.id]?.update(item, pin: {}) }
        }
        let second = streams.makeView(model: model("second", speaking: true), video: renderer)
        XCTAssertFalse(firstDelivery.isCurrent, "Already prepared old-owner frames must be rejected")
        XCTAssertEqual(firstTile.evidenceForTesting["hasFrame"] as? Bool, false)
        let next = await snapshot(streams)
        for item in next { tiles[item.id]?.update(item, pin: {}) }
        let nextDelivery = try XCTUnwrap(sampleView(in: secondTile)?.existingFrameDelivery())
        let nextFrame = expectation(description: "Second participant pixels")
        nextFrame.assertForOverFulfill = false
        nextDelivery.onEnqueuedForTesting = { sample, accepted in
            guard accepted else { return }
            Self.assertLuma(sample, 180); nextFrame.fulfill()
        }
        // A camera keeps producing while AVFoundation completes the sink's
        // asynchronous flush. Exercise that stream, not a one-shot share replay.
        for _ in 0..<3 {
            renderer.renderFrame(frame(luma: 180))
            try await Task.sleep(for: .milliseconds(80))
        }
        await fulfillment(of: [nextFrame], timeout: 2)
        XCTAssertEqual(firstTile.evidenceForTesting["hasFrame"] as? Bool, false)
        XCTAssertEqual(firstTile.evidenceForTesting["preparedFrames"] as? Int, firstPrepared,
            "The previous owner must not prepare any replacement-owner frames")
        withExtendedLifetime([first, second]) {}
    }

    func testReassignedShareCannotContaminatePreviousParticipantsSnapshot() {
        let streams = GuestStreamViews()
        defer { streams.reset() }
        let renderer = RTCEAGLVideoView(frame: .zero)
        let first = streams.makeView(model: model("first", share: true), video: renderer)
        renderer.renderFrame(frame(luma: 48))
        let second = streams.makeView(model: model("second", share: true), video: renderer)
        var received: [UInt8] = []
        let secondTap = GuestVideoFrameTap(view: renderer) { received.append($0.buffer.toI420().dataY[0]) }
        secondTap?.replayLatestFrame()
        XCTAssertTrue(received.isEmpty, "The new participant must not replay the previous participant's pixels")
        renderer.renderFrame(frame(luma: 180))
        XCTAssertEqual(received, [180])
        let restoredRenderer = RTCEAGLVideoView(frame: .zero)
        let restored = streams.makeView(model: model("first", share: true), video: restoredRenderer)
        var original: [UInt8] = []
        let firstTap = GuestVideoFrameTap(view: restoredRenderer) { original.append($0.buffer.toI420().dataY[0]) }
        firstTap?.replayLatestFrame()
        XCTAssertEqual(original, [48], "A static share may retain only its own last frame across renderer replacement")
        firstTap?.invalidate(); secondTap?.invalidate()
        withExtendedLifetime([first, second, restored]) {}
    }

    func testCameraAndShareForSameParticipantCannotOwnTheSameRenderer() async {
        let streams = GuestStreamViews()
        defer { streams.reset() }
        streams.updateParticipants([
            .init(id: "first", name: "First", isLocal: false, microphoneOn: false, cameraOn: true, sharing: true)
        ])
        let renderer = RTCEAGLVideoView(frame: .zero)
        let camera = streams.makeView(model: model("first"), video: renderer)
        let share = streams.makeView(model: model("first", share: true), video: renderer)
        let items = await snapshot(streams)
        XCTAssertNil(items.first { !$0.id.isShare }?.renderer)
        XCTAssertTrue(items.first { $0.id.isShare }?.renderer === renderer)
        withExtendedLifetime([camera, share]) {}
    }

    func testNestedRendererReplacementUpdatesSourceEvenWhenModelAndWrapperAreUnchanged() async {
        let streams = GuestStreamViews()
        defer { streams.reset() }
        streams.updateParticipants([
            .init(id: "first", name: "First", isLocal: false, microphoneOn: false, cameraOn: true, sharing: false)
        ])
        let wrapper = UIView(), firstRenderer = RTCEAGLVideoView(frame: .zero)
        wrapper.addSubview(firstRenderer)
        let first = streams.makeView(model: model("first"), video: wrapper)
        let initial = await snapshot(streams)
        XCTAssertTrue(initial.first?.renderer === firstRenderer)
        firstRenderer.removeFromSuperview()
        let secondRenderer = RTCEAGLVideoView(frame: .zero); wrapper.addSubview(secondRenderer)
        let second = streams.makeView(model: model("first"), video: wrapper)
        let items = await snapshot(streams)
        XCTAssertTrue(items.first?.renderer === secondRenderer)
        withExtendedLifetime([first, second]) {}
    }

    private func model(_ id: String, share: Bool = false, speaking: Bool = false,
                       mode: JazzParticipantViewModel.DisplayMode = .speaker) -> JazzParticipantViewModel {
        .init(name: id, isAudioOn: speaking, isVideoOn: true, isPinned: false, isSharingScreen: share,
              isLocal: false, id: id, isDominantSpeaker: speaking, shouldShowParticipantInfo: true,
              isZoomable: share, watermarkState: .hidden, displayMode: mode)
    }

    private func frame(luma: UInt8) -> RTCVideoFrame {
        let pixels = RTCMutableI420Buffer(width: 4, height: 2, strideY: 4, strideU: 2, strideV: 2)
        for index in 0..<8 { pixels.mutableDataY[index] = luma }
        for index in 0..<2 { pixels.mutableDataU[index] = 128; pixels.mutableDataV[index] = 128 }
        return RTCVideoFrame(buffer: pixels, rotation: RTCVideoRotation(rawValue: 0)!,
                            timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
    }

    private func sampleView(in view: UIView) -> GuestSampleBufferView? {
        if let sample = view as? GuestSampleBufferView { return sample }
        return view.subviews.lazy.compactMap { self.sampleView(in: $0) }.first
    }

    nonisolated private static func assertLuma(_ sample: CMSampleBuffer, _ expected: UInt8) {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return XCTFail("Missing pixels") }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        XCTAssertEqual(CVPixelBufferGetBaseAddressOfPlane(pixels, 0)?.load(as: UInt8.self), expected)
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
        // Foreground camera focus is explicit, but stable Focus sharing keeps
        // PiP on the remembered share (focus-share-companion-2026-10-23).
        XCTAssertEqual(streams.selectedTarget, .init(participant: "camera", isShare: false))
        XCTAssertEqual(streams.pinnedTarget, .init(participant: "camera", isShare: false))
        XCTAssertEqual(signaled, .init(participant: "presenter", isShare: true))
        XCTAssertNil(selected, "The missing shared renderer must never borrow the foreground camera's pixels")
        withExtendedLifetime(camera) {}
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
        // Preserve the first active share across arrival of additional shares;
        // alphabetical renderer arrival must not replace established affinity.
        XCTAssertEqual(streams.selectedTarget, .init(participant: "b", isShare: true))
        XCTAssertEqual(signaled, .init(participant: "b", isShare: true))
        XCTAssertTrue(selected === tiles[1])
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

    func testVisibleTargetsFollowActualPageAndWithdrawWhenInactiveOrDetached() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 570))
        let host = UIViewController(); window.rootViewController = host; window.isHidden = false
        let gallery = GuestGalleryView(frame: window.bounds)
        host.view.addSubview(gallery)
        defer { window.isHidden = true }
        let items: [GuestStreamViews.GalleryItem] = (0..<12).map {
            .init(id: .init(participant: "p\($0)", isShare: false), name: "Person",
                microphoneOn: false, active: true, speaking: false, watermark: nil, renderer: nil)
        }
        var changes = 0
        gallery.onVisibleTargetsChanged = { changes += 1 }
        gallery.update(items); gallery.setActive(true); gallery.layoutIfNeeded()
        let first = Set(gallery.visibleTargets)
        XCTAssertFalse(first.isEmpty)
        XCTAssertLessThan(first.count, items.count)
        gallery.movePage(1)
        XCTAssertFalse(gallery.visibleTargets.isEmpty)
        XCTAssertTrue(first.isDisjoint(with: gallery.visibleTargets))
        XCTAssertGreaterThan(changes, 1)
        gallery.setActive(false)
        XCTAssertTrue(gallery.visibleTargets.isEmpty)
        gallery.setActive(true)
        XCTAssertFalse(gallery.visibleTargets.isEmpty)
        gallery.removeFromSuperview()
        XCTAssertTrue(gallery.visibleTargets.isEmpty)
    }
}
