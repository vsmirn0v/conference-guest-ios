import Combine
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class ActiveSpeakerTests: XCTestCase {
    private let aram = CallSpeaker(id: "aram", name: "Aram", isLocal: false)
    private let ani = CallSpeaker(id: "ani", name: "Ani", isLocal: false)

    func testDuplicatesDoNotPostponeSpeakerAndShortCandidatesDoNotFlash() async throws {
        let store = ActiveSpeakerStore(delay: 50_000_000)
        var changes: [CallSpeaker?] = []
        let subscription = store.$current.sink { changes.append($0) }
        defer { subscription.cancel() }
        store.update(aram)
        try await Task.sleep(nanoseconds: 25_000_000)
        store.update(aram)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(store.current, aram)
        store.update(ani); store.update(aram)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(changes, [nil, aram])
        store.update(ani)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(store.current, ani)
        store.update(nil)
        XCTAssertNil(store.current)
    }

    func testHoldAndRetirementCancelPendingNamesAndRequireFreshInput() async throws {
        let store = ActiveSpeakerStore(delay: 30_000_000)
        store.update(aram); store.setAvailable(false)
        store.update(ani)
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertNil(store.current)
        store.setAvailable(true)
        XCTAssertNil(store.current)
        store.update(ani)
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(store.current, ani)
        store.end(); store.setAvailable(true); store.update(aram)
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertNil(store.current)
        store.reset(); store.setAvailable(true); store.update(aram)
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(store.current, aram)
    }

    func testLocalNameAndRenameKeepIdentityAndUpdateWithoutWaiting() async throws {
        let store = ActiveSpeakerStore(delay: 20_000_000)
        store.update(aram)
        try await Task.sleep(nanoseconds: 60_000_000)
        let renamed = CallSpeaker(id: aram.id, name: "Арam — acoustic guitar", isLocal: false)
        store.update(renamed)
        XCTAssertEqual(store.current, renamed)
        XCTAssertEqual(CallSpeaker(id: "self", name: "Private configured name", isLocal: true).title, L("You"))
    }

    func testHeaderSpeakerChangesKeepAllGeometryAndDetailsAccessible() throws {
        let header = CompactCallHeader(frame: CGRect(x: 0, y: 0, width: 520, height: 44))
        header.update(name: "Ani · Screen", navigation: true, browsing: false, pinned: true,
            pinLabel: "Unpin", participantsLabel: "4", chatValue: "2", chatCount: 2, missedCount: 1,
            status: nil, focusAvailable: true)
        header.layoutIfNeeded()
        let frames = header.subviews.map(\.frame)
        for person in [aram, ani, CallSpeaker(id: "long", name: String(repeating: "Николай Александрович ", count: 8), isLocal: false)] {
            header.setSpeaker(person); header.layoutIfNeeded()
            XCTAssertEqual(header.subviews.map(\.frame), frames)
            XCTAssertEqual(header.frame.height, 44)
            XCTAssertEqual(header.details.accessibilityValue, person.accessibilityLabel)
            let indicator = try XCTUnwrap(header.details.subviews.first { $0 is ActiveSpeakerIndicator })
            XCTAssertFalse(indicator.isHidden)
            XCTAssertTrue(header.details.bounds.contains(indicator.frame))
        }
        header.setSpeaker(nil); header.layoutIfNeeded()
        XCTAssertEqual(header.subviews.map(\.frame), frames)
        XCTAssertEqual(header.details.configuration?.title, "Ani · Screen")
        header.update(name: "Reconnecting", navigation: true, browsing: false, pinned: true,
            pinLabel: "Unpin", participantsLabel: "4", chatValue: nil, status: "Reconnecting",
            speaking: aram, focusAvailable: true)
        header.setSpeaker(ani)
        XCTAssertEqual(header.details.configuration?.title, "Reconnecting")
        XCTAssertEqual(header.details.accessibilityValue, "Reconnecting")
    }

    func testPiPSpeakerUpdatesKeepStaticVideoAndZoomAndDoNotOverlapMic() throws {
        let state = StreamViewportState()
        state.scale = 2
        let video = StreamViewport(video: UIView(), state: state, zoomable: true,
            name: "Static share", showInfo: false, microphoneOn: true, pinned: true, watermark: nil)
        let surface = FloatingVideoContentView(videoContent: video)
        surface.setMicrophoneStatus(.muted)
        let speaker = try XCTUnwrap(surface.subviews.first { $0.accessibilityIdentifier == "Floating active speaker" })
        let mic = try XCTUnwrap(surface.subviews.first { $0.accessibilityIdentifier == "Floating microphone status" })
        for size in [CGSize(width: 320, height: 180), CGSize(width: 144, height: 81), CGSize(width: 144, height: 256)] {
            surface.frame = CGRect(origin: .zero, size: size)
            surface.setNeedsLayout(); surface.layoutIfNeeded()
            for person in [aram, ani, CallSpeaker(id: "long", name: String(repeating: "Николай ", count: 8), isLocal: false)] {
                surface.setSpeaker(person); surface.layoutIfNeeded()
                XCTAssertEqual(speaker.accessibilityLabel, person.accessibilityLabel)
                XCTAssertTrue(surface.bounds.contains(speaker.frame))
                XCTAssertTrue(surface.bounds.contains(mic.frame))
                XCTAssertFalse(speaker.frame.intersects(mic.frame))
                XCTAssertGreaterThan(speaker.frame.width, 33)
                XCTAssertEqual(video.frame, surface.bounds)
                XCTAssertEqual(video.zoomScale, 2)
                XCTAssertTrue(video.superview === surface)
                XCTAssertFalse(speaker.isUserInteractionEnabled)
                XCTAssertFalse(speaker.accessibilityTraits.contains(.button))
            }
            surface.setSpeaker(nil); surface.layoutIfNeeded()
            XCTAssertTrue(speaker.isHidden)
            XCTAssertEqual(video.frame, surface.bounds)
        }
    }
}
