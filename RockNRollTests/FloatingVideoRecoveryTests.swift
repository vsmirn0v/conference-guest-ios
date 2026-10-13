import AVKit
import UIKit
import XCTest
@testable import RockNRoll

@MainActor final class FloatingVideoRecoveryTests: XCTestCase {
    @MainActor private final class Fixture {
        var state = UIApplication.State.active
        var starts = 0, stops = 0
        var possible = true
        var active = false
        var recoveryTimeout: UInt64 = 10_000_000_000
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let source = UIView()
        lazy var floating = FloatingVideoController(contentView: UIView(), environment: .init(
            applicationState: { [unowned self] in state }, supported: { true }, possible: { [unowned self] _ in possible },
            active: { [unowned self] _ in active },
            start: { [unowned self] _ in starts += 1 }, stop: { [unowned self] _ in stops += 1 },
            recoveryTimeoutNanoseconds: recoveryTimeout))
        init() {
            window.rootViewController = UIViewController()
            window.makeKeyAndVisible()
            window.rootViewController?.view.addSubview(source)
            source.frame = window.bounds
        }
        func present() throws -> AVPictureInPictureController {
            try XCTSkipUnless(AVPictureInPictureController.isPictureInPictureSupported(), "This runtime cannot create a video-call PiP controller")
            XCTAssertNotNil(source.window)
            floating.setSourceView(source); floating.start()
            let controller = try XCTUnwrap(floating.controllerForTesting)
            floating.pictureInPictureControllerWillStartPictureInPicture(controller)
            floating.pictureInPictureControllerDidStartPictureInPicture(controller)
            state = .background
            return controller
        }
    }
    func testShareGapRetainsExistingBackgroundWindowAndResumesOnNewSource() throws {
        let fixture = Fixture(), preference = FloatingVideoPreference.enabled
        FloatingVideoPreference.enabled = true
        defer { fixture.floating.end(); FloatingVideoPreference.enabled = preference }
        let controller = try fixture.present(), stopped = fixture.stops
        fixture.floating.setSourceView(nil, preservingPresentation: true)
        XCTAssertTrue(fixture.floating.controllerForTesting === controller)
        XCTAssertTrue(fixture.floating.isPresenting)
        XCTAssertEqual(fixture.stops, stopped)
        var restored = false
        fixture.floating.pictureInPictureController(controller,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { restored = $0 })
        XCTAssertTrue(restored, "Waiting for a replacement share must still allow returning to the meeting")
        fixture.floating.setSourceView(fixture.source)
        XCTAssertTrue(fixture.floating.controllerForTesting === controller)
        XCTAssertEqual(fixture.starts, 1, "A share restart needs no new PiP activation")
    }
    func testCallRecoveryRequestsFreshFramesAndRestartsRetainedControllerInBackground() throws {
        let fixture = Fixture()
        defer { fixture.floating.end() }
        let controller = try fixture.present()
        var demand: [Bool] = []
        fixture.floating.onRecoveryDemandChanged = { demand.append($0) }
        fixture.floating.setSuspended(true)
        fixture.floating.pictureInPictureControllerDidStopPictureInPicture(controller)
        fixture.floating.setSourceView(nil, preservingPresentation: true)
        fixture.floating.setSuspended(false)
        XCTAssertTrue(fixture.floating.needsRecoveryFrames)
        XCTAssertEqual(demand, [true])
        fixture.floating.setSourceView(fixture.source)
        XCTAssertEqual(fixture.starts, 2)
        XCTAssertTrue(fixture.floating.controllerForTesting === controller)
        fixture.floating.pictureInPictureControllerWillStartPictureInPicture(controller)
        fixture.floating.pictureInPictureControllerDidStartPictureInPicture(controller)
        XCTAssertEqual(demand, [true, false])
    }
    func testUserDismissalAndMeetingEndCannotBeReopenedByFramesOrRecovery() throws {
        let fixture = Fixture()
        let controller = try fixture.present()
        fixture.floating.pictureInPictureControllerDidStopPictureInPicture(controller)
        fixture.floating.setSourceView(nil); fixture.floating.setSourceView(fixture.source)
        fixture.floating.setSuspended(true); fixture.floating.setSuspended(false); fixture.floating.start()
        XCTAssertEqual(fixture.starts, 1)
        fixture.floating.end()
        fixture.floating.setSourceView(fixture.source); fixture.floating.setSuspended(false); fixture.floating.start()
        fixture.floating.pictureInPictureControllerDidStartPictureInPicture(controller)
        XCTAssertNil(fixture.floating.controllerForTesting)
        XCTAssertFalse(fixture.floating.needsRecoveryFrames)
        XCTAssertFalse(fixture.floating.hasSourceForTesting)
    }
    func testRecoveryWaitsForAVKitReadinessAndPreferenceOffCancelsIt() throws {
        let fixture = Fixture(), preference = FloatingVideoPreference.enabled
        FloatingVideoPreference.enabled = true
        defer { fixture.floating.end(); FloatingVideoPreference.enabled = preference }
        let controller = try fixture.present()
        fixture.floating.setSuspended(true); fixture.floating.pictureInPictureControllerDidStopPictureInPicture(controller)
        fixture.possible = false; fixture.floating.setSuspended(false)
        XCTAssertEqual(fixture.starts, 1)
        FloatingVideoPreference.enabled = false; fixture.floating.refreshPreference()
        fixture.possible = true; fixture.floating.setSourceView(fixture.source)
        XCTAssertFalse(fixture.floating.needsRecoveryFrames)
        XCTAssertEqual(fixture.starts, 1)
    }
    func testRecoveryDemandSurvivesBackgroundGraceWithoutKeepingVideoOnAfterCancel() async throws {
        let demand = MeetingVideoDemand(observeLifecycle: false)
        demand.setForeground(false, graceNanoseconds: 1)
        demand.setRecovering(true)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(demand.wantsVideo)
        demand.setRecovering(false)
        XCTAssertFalse(demand.wantsVideo)
    }
    func testUnavailableSystemPiPBoundsBackgroundVideoDemand() async throws {
        let fixture = Fixture()
        fixture.recoveryTimeout = 10_000_000
        defer { fixture.floating.end() }
        let controller = try fixture.present()
        fixture.floating.setSuspended(true)
        fixture.floating.pictureInPictureControllerDidStopPictureInPicture(controller)
        fixture.possible = false
        fixture.floating.setSuspended(false)
        XCTAssertTrue(fixture.floating.needsRecoveryFrames)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(fixture.floating.needsRecoveryFrames)
        XCTAssertNil(fixture.floating.controllerForTesting)
        fixture.possible = true
        fixture.floating.setSourceView(fixture.source)
        XCTAssertEqual(fixture.starts, 1)
    }
    func testExplicitlyHidingVideoCancelsPresentationAndRecovery() throws {
        let fixture = Fixture()
        defer { fixture.floating.end() }
        _ = try fixture.present()
        fixture.floating.setSourceView(nil)
        XCTAssertFalse(fixture.floating.isPresenting)
        XCTAssertFalse(fixture.floating.needsRecoveryFrames)
        XCTAssertNil(fixture.floating.controllerForTesting)
    }
    func testCallRecoveryUsesAVKitStateWhenSystemOmitsStopDelegate() throws {
        let fixture = Fixture()
        defer { fixture.floating.end() }
        _ = try fixture.present()
        fixture.floating.setSuspended(true)
        fixture.floating.setSourceView(nil, preservingPresentation: true)
        // The injected start operation does not start a real system window,
        // so AVKit reports inactive, like the missing-callback device case.
        fixture.floating.setSuspended(false)
        fixture.floating.setSourceView(fixture.source)
        XCTAssertEqual(fixture.starts, 2)
        XCTAssertTrue(fixture.floating.needsRecoveryFrames)
    }
    func testRetainedActiveSystemPiPResumesFramesWithoutStoppingOrTimingOut() async throws {
        let fixture = Fixture()
        fixture.recoveryTimeout = 10_000_000
        defer { fixture.floating.end() }
        _ = try fixture.present()
        fixture.active = true
        let stops = fixture.stops
        var resumes = 0
        fixture.floating.onWillStart = { resumes += 1 }
        fixture.floating.setSuspended(true)
        fixture.floating.setSourceView(nil, preservingPresentation: true)
        XCTAssertEqual(fixture.stops, stops)
        fixture.floating.setSuspended(false)
        fixture.floating.setSourceView(fixture.source)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(resumes, 1)
        XCTAssertTrue(fixture.floating.isPresenting)
        XCTAssertFalse(fixture.floating.needsRecoveryFrames)
        XCTAssertEqual(fixture.starts, 1)
        XCTAssertEqual(fixture.stops, stops)
    }
}
