import JazzSDK
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class ParticipantMediaBadgeTests: XCTestCase {
    func testMutedNativeParticipantCannotRetainSpeakingBorder() throws {
        let call = RockCallViewController(title: "Review", catchUp: CatchUpStore(), chat: ChatStore())
        call.loadViewIfNeeded()
        let participant = CallParticipant(id: "remote", name: "Remote", isLocal: false,
            microphoneOn: false, cameraOn: false, screenShareOn: false, isSpeaking: true, videoTracks: [])
        call.render(snapshot: .init(participants: [participant]))
        func tile(in view: UIView) -> UIView? {
            if view.accessibilityIdentifier == "camera-off.remote" { return view }
            return view.subviews.lazy.compactMap { tile(in: $0) }.first
        }
        let rendered = try XCTUnwrap(tile(in: call.view))
        XCTAssertEqual(rendered.layer.borderWidth, 1, "Muted participants must not be highlighted as speaking")
    }

    func testHeldNativeParticipantClearsSpeakingBorder() throws {
        let call = RockCallViewController(title: "Review", catchUp: CatchUpStore(), chat: ChatStore())
        call.loadViewIfNeeded()
        let participant = CallParticipant(id: "remote", name: "Remote", isLocal: false,
            microphoneOn: true, cameraOn: false, screenShareOn: false, isSpeaking: true, videoTracks: [])
        call.render(snapshot: .init(participants: [participant]))
        call.setHeld(true)
        func tile(in view: UIView) -> UIView? {
            if view.accessibilityIdentifier == "camera-off.remote" { return view }
            return view.subviews.lazy.compactMap { tile(in: $0) }.first
        }
        let rendered = try XCTUnwrap(tile(in: call.view))
        XCTAssertEqual(rendered.layer.borderWidth, 1, "An interrupted meeting must not retain a stale speaking highlight")
    }

    func testMutedGuestGalleryParticipantCannotRemainSpeaking() throws {
        let gallery = GuestGalleryView()
        gallery.update([.init(id: .init(participant: "remote", isShare: false), name: "Remote",
            microphoneOn: false, active: false, speaking: true, watermark: nil, renderer: nil)])
        let tile = try XCTUnwrap(gallery.subviews.first)
        XCTAssertEqual(tile.layer.borderWidth, 1)
        XCTAssertNil(tile.accessibilityValue, "Gallery must not announce Speaking while its badge announces Microphone off")
    }

    func testGuestGalleryUsesSameSpeakerAndAvailabilityAsStage() throws {
        let gallery = GuestGalleryView()
        gallery.update([.init(id: .init(participant: "remote", isShare: false), name: "Remote",
            microphoneOn: true, active: false, speaking: false, watermark: nil, renderer: nil)])
        let tile = try XCTUnwrap(gallery.subviews.first)
        gallery.setSpeaker("remote", available: true)
        XCTAssertEqual(tile.layer.borderWidth, 3)
        gallery.setSpeaker("remote", available: false)
        XCTAssertEqual(tile.layer.borderWidth, 1)
        XCTAssertNil(tile.accessibilityValue)
        gallery.setSpeaker("remote", available: true)
        XCTAssertEqual(tile.layer.borderWidth, 3)
        XCTAssertTrue(gallery.subviews.first === tile)
    }

    func testLocalBadgeTracksActualSendingAndUnavailableStatusWithoutRosterRefresh() throws {
        let call = RockCallViewController(title: "Review", catchUp: CatchUpStore(), chat: ChatStore())
        call.loadViewIfNeeded(); call.setMicrophone(true)
        let local = CallParticipant(id: "local", name: "Local", isLocal: true,
            microphoneOn: true, cameraOn: false, screenShareOn: false, isSpeaking: true, videoTracks: [])
        let remote = CallParticipant(id: "remote", name: "Remote", isLocal: false,
            microphoneOn: false, cameraOn: false, screenShareOn: false, isSpeaking: false, videoTracks: [])
        call.render(snapshot: .init(participants: [local, remote]))
        func caption(in view: UIView) -> ParticipantMediaBadge? {
            if let badge = view as? ParticipantMediaBadge, badge.accessibilityLabel == "Local" { return badge }
            return view.subviews.lazy.compactMap { caption(in: $0) }.first
        }
        let badge = try XCTUnwrap(caption(in: call.view))
        for (status, expected) in [(PiPMicrophoneStatus.on, L("Speaking")), (.muted, L("Microphone off")),
                                   (.on, L("Speaking")), (.unavailable, L("Microphone off"))] {
            call.setFloatingMicrophoneStatus(status)
            XCTAssertEqual(badge.accessibilityValue, expected)
        }
    }

    func testMutedStatusWinsOverStaleSpeakingAndFullNameRemainsAccessible() {
        let badge = ParticipantMediaBadge()
        let name = "Николай Александрович — акустическая гитара"
        for (on, speaking, status) in [(false, true, L("Microphone off")),
                                       (true, false, L("Microphone on")),
                                       (true, true, L("Speaking"))] {
            badge.update(name: name, microphoneOn: on, speaking: speaking)
            XCTAssertEqual(badge.accessibilityLabel, name)
            XCTAssertEqual(badge.accessibilityValue, status)
            XCTAssertFalse(badge.isUserInteractionEnabled)
        }
    }

    func testIconKeepsItsSpaceAcrossNamesStatesSizesAndTextDirections() throws {
        let badge = ParticipantMediaBadge()
        let icon = try XCTUnwrap(badge.subviews.compactMap { $0 as? UIImageView }.first)
        let label = try XCTUnwrap(badge.subviews.compactMap { $0 as? UILabel }.first)
        for direction in [UISemanticContentAttribute.forceLeftToRight, .forceRightToLeft] {
            badge.semanticContentAttribute = direction
            for width: CGFloat in [64, 96, 140, 280] {
                for name in ["Alexander Smirnov — acoustic guitar", "Николай Александрович — акустическая гитара"] {
                    for (on, speaking) in [(false, false), (true, false), (true, true)] {
                        badge.update(name: name, microphoneOn: on, speaking: speaking)
                        badge.frame = CGRect(x: 0, y: 0, width: width, height: badge.intrinsicContentSize.height)
                        badge.layoutIfNeeded()
                        XCTAssertEqual(icon.frame.width, 20)
                        XCTAssertTrue(badge.bounds.contains(icon.frame))
                        XCTAssertTrue(badge.bounds.contains(label.frame))
                        XCTAssertFalse(icon.frame.intersects(label.frame))
                    }
                }
            }
        }
    }

    func testSpeakingChangesDoNotResizeCaptionOrReplaceName() {
        let badge = ParticipantMediaBadge()
        badge.update(name: "Alexander Smirnov", microphoneOn: false, speaking: false)
        let size = badge.intrinsicContentSize
        for (on, speaking) in [(true, false), (true, true), (false, true)] {
            badge.updateMicrophone(on: on, speaking: speaking)
            XCTAssertEqual(badge.intrinsicContentSize, size)
            XCTAssertEqual(badge.accessibilityLabel, "Alexander Smirnov")
        }
    }

    func testCaptionFitsSystemAccessibilityFontMetricsWithoutCoveringIcon() async throws {
        let parent = UIViewController(), child = UIViewController()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = parent; window.isHidden = false
        defer { window.isHidden = true }
        parent.addChild(child); parent.view.addSubview(child.view); child.didMove(toParent: parent)
        let badge = ParticipantMediaBadge()
        child.view.addSubview(badge)
        badge.update(name: "Николай Александрович", microphoneOn: false, speaking: false)
        func setTextSize(_ category: UIContentSizeCategory) {
            if #available(iOS 17.0, *) {
                badge.traitOverrides.preferredContentSizeCategory = category
                badge.updateTraitsIfNeeded()
            }
            else { parent.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: child) }
        }
        setTextSize(.large)
        await Task.yield()
        let regularHeight = badge.intrinsicContentSize.height
        setTextSize(.accessibilityExtraExtraExtraLarge)
        await Task.yield()
        XCTAssertEqual(badge.traitCollection.preferredContentSizeCategory, .accessibilityExtraExtraExtraLarge)
        badge.frame = CGRect(x: 0, y: 0, width: 104, height: badge.intrinsicContentSize.height)
        badge.layoutIfNeeded()
        let required = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: badge.traitCollection).lineHeight
        XCTAssertGreaterThanOrEqual(badge.bounds.height, ceil(required) + 8)
        // UIKit's Mac runtime supplies fixed font metrics even with this trait.
        // Actual font growth is qualified on iPhone Simulator.
        if !ProcessInfo.processInfo.isiOSAppOnMac { XCTAssertGreaterThan(badge.bounds.height, regularHeight) }
        let icon = try XCTUnwrap(badge.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertTrue(badge.bounds.contains(icon.frame))
    }

    func testGuestMetadataUpdatesBadgeWithoutReplacingVideoOrLosingZoom() throws {
        let streams = GuestStreamViews(), renderer = UIView()
        func model(microphone: Bool, speaking: Bool) -> JazzParticipantViewModel {
            .init(name: "Николай Александрович — акустическая гитара", isAudioOn: microphone,
                isVideoOn: true, isPinned: false, isSharingScreen: true, isLocal: false,
                id: "remote", isDominantSpeaker: speaking, shouldShowParticipantInfo: true,
                isZoomable: true, watermarkState: .hidden, displayMode: .speaker)
        }
        let viewport = try XCTUnwrap(streams.makeView(model: model(microphone: true, speaking: false), video: renderer) as? StreamViewport)
        viewport.frame = CGRect(x: 0, y: 0, width: 180, height: 120); viewport.layoutIfNeeded()
        let scroll = try XCTUnwrap(viewport.subviews.compactMap { $0 as? UIScrollView }.first)
        scroll.setZoomScale(2, animated: false)
        let badge = try XCTUnwrap(viewport.subviews.compactMap { $0 as? ParticipantMediaBadge }.first)
        for (on, speaking, status) in [(true, true, L("Speaking")), (false, true, L("Microphone off"))] {
            XCTAssertTrue(streams.makeView(model: model(microphone: on, speaking: speaking), video: renderer) === viewport)
            XCTAssertEqual(badge.accessibilityValue, status)
            XCTAssertEqual(scroll.zoomScale, 2)
            XCTAssertTrue(viewport.containsRenderer(renderer))
        }
        viewport.controlsHidden = true
        XCTAssertEqual(badge.alpha, 0)
        viewport.controlsHidden = false
        XCTAssertEqual(badge.alpha, 1)
    }

    func testGuestGalleryUpdatesActualMicrophoneAndSpeakingState() throws {
        let gallery = GuestGalleryView()
        func item(on: Bool, speaking: Bool) -> GuestStreamViews.GalleryItem {
            .init(id: .init(participant: "remote", isShare: false), name: "Alexander Smirnov",
                microphoneOn: on, active: false, speaking: speaking, watermark: nil, renderer: nil)
        }
        gallery.update([item(on: false, speaking: false)])
        let tile = try XCTUnwrap(gallery.subviews.first)
        let viewport = try XCTUnwrap(tile.subviews.compactMap { $0 as? StreamViewport }.first)
        let badge = try XCTUnwrap(viewport.subviews.compactMap { $0 as? ParticipantMediaBadge }.first)
        gallery.update([item(on: true, speaking: true)])
        XCTAssertEqual(badge.accessibilityValue, L("Speaking"))
        gallery.update([item(on: false, speaking: true)])
        XCTAssertEqual(badge.accessibilityValue, L("Microphone off"))
        XCTAssertTrue(gallery.subviews.first === tile)
    }

    func testSharedEngineVideoAndAudioTilesReceiveStateChangesAndClearSpeechOnHold() throws {
        let factory = try NativeRTCPeer.makeFactory()
        let track = factory.videoTrack(with: factory.videoSource(), trackId: "camera")
        let call = RockCallViewController(title: "Rehearsal", catchUp: CatchUpStore(), chat: ChatStore())
        call.loadViewIfNeeded()
        var participant = CallParticipant(id: "remote", name: "Alexander Smirnov — acoustic guitar",
            isLocal: false, microphoneOn: false, cameraOn: true, screenShareOn: false,
            isSpeaking: false, videoTracks: [.init(id: "camera", source: .camera, track: .native(track))])
        func captions(in view: UIView) -> [ParticipantMediaBadge] {
            (view as? ParticipantMediaBadge).map { [$0] } ?? view.subviews.flatMap { captions(in: $0) }
        }
        call.render(snapshot: .init(participants: [participant]))
        XCTAssertEqual(captions(in: call.view).first?.accessibilityValue, L("Microphone off"))
        participant.microphoneOn = true; participant.isSpeaking = true
        call.render(snapshot: .init(participants: [participant]))
        call.refreshSpeaking(snapshot: .init(participants: [participant]))
        XCTAssertEqual(captions(in: call.view).first?.accessibilityValue, L("Speaking"))
        call.setHeld(true)
        XCTAssertEqual(captions(in: call.view).first?.accessibilityValue, L("Microphone on"))
        call.setHeld(false)
        participant.cameraOn = false; participant.videoTracks = []; participant.isSpeaking = false
        call.render(snapshot: .init(participants: [participant]))
        XCTAssertEqual(captions(in: call.view).first?.accessibilityValue, L("Microphone on"))
    }

    func testGuestMainStageTracksRosterMicrophoneAndSpeakerChanges() throws {
        let controls = CallControls(localPreview: LocalSharePreview(), state: nil, coordinator: nil,
            router: nil, catchUp: CatchUpStore(), chat: ChatStore(), initialDisplayMode: .all,
            invitationURL: nil, roomIdentifier: "fixture", onDisplayMode: { _ in }, onFloat: {},
            onFloatingPreferenceChanged: {}, onLeave: {}, onScreenShare: { _ in },
            onMicrophoneState: { _ in }, onCameraState: { _ in })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true }
        controls.frame = host.view.bounds; host.view.addSubview(controls)
        controls.setStagePresentation(.init(target: .init(participant: "remote", isShare: true),
            name: "Alexander Smirnov — acoustic guitar", microphoneOn: false, watermark: nil,
            active: true, automatic: true, count: 1, browsing: false))
        func captions(in view: UIView) -> [ParticipantMediaBadge] {
            (view as? ParticipantMediaBadge).map { [$0] } ?? view.subviews.flatMap { captions(in: $0) }
        }
        let badge = try XCTUnwrap(captions(in: window).first)
        for (on, speaker, expected) in [(true, "remote", L("Speaking")),
                                        (true, "another", L("Microphone on")),
                                        (false, "remote", L("Microphone off"))] {
            controls.updateParticipantRoster([.init(id: "remote", name: "Alexander Smirnov",
                isLocal: false, microphoneOn: on, cameraOn: true, sharing: true)], speaking: speaker)
            XCTAssertEqual(badge.accessibilityValue, expected)
        }
        controls.updateParticipantRoster([.init(id: "remote", name: "Alexander Smirnov", isLocal: false,
            microphoneOn: true, cameraOn: true, sharing: true)], speaking: "remote")
        XCTAssertEqual(badge.accessibilityValue, L("Speaking"))
        controls.setHeld(true)
        XCTAssertEqual(badge.accessibilityValue, L("Microphone on"))
        controls.setHeld(false)
        XCTAssertEqual(badge.accessibilityValue, L("Speaking"))
    }

    func testZoomActionsRemainAccessibleAndControlsStayAboveCaptionAtLargeTextSizes() async throws {
        let viewport = StreamViewport(video: UIView(), state: StreamViewportState(), zoomable: true,
            name: "Николай Александрович — акустическая гитара", showInfo: true,
            microphoneOn: false, pinned: false, watermark: nil, onPin: {})
        let badge = try XCTUnwrap(viewport.subviews.compactMap { $0 as? ParticipantMediaBadge }.first)
        if #available(iOS 17.0, *) {
            badge.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            badge.updateTraitsIfNeeded()
        }
        viewport.frame = CGRect(x: 0, y: 0, width: 180, height: 220)
        viewport.layoutIfNeeded()
        // The old three-button zoom row was removed when Fit/Fill moved to
        // the compact header. Native pinch and accessible zoom actions remain;
        // the remaining per-tile controls must still leave the caption clear.
        let scroll = try XCTUnwrap(viewport.subviews.compactMap { $0 as? UIScrollView }.first)
        let zoomIn = try XCTUnwrap(scroll.accessibilityCustomActions?.first { $0.name == L("Zoom in") })
        XCTAssertNotNil(scroll.accessibilityCustomActions?.first { $0.name == L("Zoom out") })
        XCTAssertNotNil(scroll.accessibilityCustomActions?.first { $0.name == L("Fit whole share") })
        XCTAssertTrue(zoomIn.actionHandler?(zoomIn) == true)
        let deadline = Date().addingTimeInterval(2)
        while viewport.zoomScale <= 1.01, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(viewport.zoomScale, 1.01, "The accessible zoom action must actually zoom the share")
        viewport.layoutIfNeeded()
        let controls = viewport.subviews.compactMap { $0 as? UIButton }.filter { !$0.isHidden }
        XCTAssertFalse(controls.isEmpty)
        for control in controls {
            let rect = control.convert(control.bounds, to: viewport)
            XCTAssertLessThanOrEqual(rect.maxY + 8, badge.frame.minY)
            XCTAssertGreaterThanOrEqual(rect.width, 44); XCTAssertGreaterThanOrEqual(rect.height, 44)
        }
        XCTAssertTrue(viewport.bounds.contains(badge.frame))
    }
}
