import AVFoundation
import ConferenceCore
import XCTest
@testable import RockNRoll

@MainActor
final class MeetingReactionsTests: XCTestCase {
    func testManualSendingDoesNotRequireCameraAndUnreadyEventsAreDropped() {
        let model = MeetingReactionsModel()
        var sent: [MeetingReaction] = []
        model.sender = { sent.append($0); return true }
        XCTAssertFalse(model.send(.like))
        model.available = true; model.ready = true
        XCTAssertEqual(model.cameraStatus, .off)
        XCTAssertTrue(model.send(.like)); XCTAssertEqual(sent, [.like])
        model.ready = false
        XCTAssertFalse(model.send(.dislike)); model.ready = true
        XCTAssertEqual(sent, [.like], "Recovery replayed an old reaction")
    }
    func testPrivatePreviewOptInCannotSendWithoutPublishedCameraReadiness() {
        var time = 0.0
        let model = MeetingReactionsModel(clock: { time })
        var sent = 0
        model.sender = { _ in sent += 1; return true }; model.available = true; model.ready = true
        XCTAssertFalse(model.shareCameraReactions)
        model.cameraStatus = .ready
        XCTAssertFalse(model.send(.like, source: .camera, effectID: "effect"))
        model.setForwarding(true); model.cameraStatus = .off
        XCTAssertFalse(model.send(.like, source: .camera, effectID: "effect"))
        model.cameraStatus = .ready
        XCTAssertTrue(model.send(.like, source: .camera, effectID: "effect"))
        time = 10
        XCTAssertFalse(model.send(.like, source: .camera, effectID: "effect"))
        XCTAssertEqual(sent, 1)
        model.cameraStatus = .paused
        XCTAssertFalse(model.send(.like, source: .camera, effectID: "new"))
    }
    func testEndRevokesSenderAndNewSessionStartsWithoutQueuedActions() {
        let model = MeetingReactionsModel()
        model.available = true; model.ready = true; model.sender = { _ in XCTFail("Retired sender called"); return true }
        let generation = model.generation
        model.end()
        XCTAssertFalse(model.send(.like)); XCTAssertNotEqual(model.generation, generation)
        model.begin(); XCTAssertNil(model.sender); XCTAssertFalse(model.canSend); XCTAssertNil(model.submitted)
    }
    func testPreferencePersistsLocallyWithoutChangingPublicationState() {
        let name = "reactions-test-\(UUID())"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        let model = MeetingReactionsModel(preferences: preferences)
        model.setForwarding(true)
        XCTAssertFalse(model.ready); XCTAssertFalse(model.canSend)
        XCTAssertTrue(MeetingReactionsModel(preferences: preferences).shareCameraReactions)
    }
    func testOnlyExactSystemReactionMappingsAreForwarded() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Camera reaction metadata needs iOS 17.") }
        XCTAssertEqual(CameraReactionObserver.reaction(.thumbsUp), .like)
        XCTAssertEqual(CameraReactionObserver.reaction(.thumbsDown), .dislike)
        XCTAssertEqual(CameraReactionObserver.reaction(.confetti), .applause)
        XCTAssertEqual(CameraReactionObserver.reaction(.fireworks), .applause)
        XCTAssertEqual(CameraReactionObserver.reaction(.heart), .heart)
        XCTAssertNil(CameraReactionObserver.reaction(AVCaptureReactionType(rawValue: "unmapped-effect")))
    }
    func testNativeMenuActionCanBeExecutedAfterPanelDismissal() {
        var calls = 0
        let action = UIAction(title: "Existing meeting action") { _ in calls += 1 }
        UIButton(primaryAction: action).sendActions(for: .touchUpInside)
        XCTAssertEqual(calls, 1)
    }
    func testEverySDKReactionCanBeSentInSequenceWithoutEndingThePaletteSession() {
        var time = 0.0
        let model = MeetingReactionsModel(clock: { time })
        model.available = true; model.ready = true
        var sent: [MeetingReaction] = []
        model.sender = { sent.append($0); return true }
        let session = model.generation
        for kind in MeetingReaction.allCases {
            XCTAssertTrue(model.send(kind))
            time += 0.5
        }
        XCTAssertEqual(sent, MeetingReaction.allCases)
        XCTAssertEqual(model.generation, session)
        XCTAssertTrue(model.canSend)
    }
    func testLegacyCapabilityRejectsUnsupportedReactionWithoutConsumingSendGate() {
        let model = MeetingReactionsModel(clock: { 0 })
        model.available = true; model.ready = true; model.supportedReactions = GuestReactionCode.legacy
        var sent: [MeetingReaction] = []
        model.sender = { sent.append($0); return true }
        XCTAssertFalse(model.send(.heart))
        XCTAssertTrue(model.send(.like))
        XCTAssertEqual(sent, [.like])
    }
}
