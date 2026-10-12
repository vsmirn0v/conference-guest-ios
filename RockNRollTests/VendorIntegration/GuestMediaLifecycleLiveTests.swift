import AVFoundation
import ConferenceCore
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class GuestMediaLifecycleLiveTests: XCTestCase {
    func testMicrophoneTogglesAcrossRooms() async throws {
        #if targetEnvironment(simulator)
        try await exercise(camera: false)
        #else
        throw XCTSkip("The real-camera case also covers microphone; initialize the SDK only once per process")
        #endif
    }
    func testCameraAndMicrophoneTogglesAcrossRooms() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a real camera")
        #else
        try await exercise(camera: true)
        #endif
    }
    private func exercise(camera: Bool) async throws {
        guard let first = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_LIFECYCLE_INVITE"],
              let second = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SECOND_INVITE"] else {
            throw XCTSkip("Requires two authorized guest test rooms")
        }
        for media: AVMediaType in camera ? [.audio, .video] : [.audio] {
            if AVCaptureDevice.authorizationStatus(for: media) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: media)
            }
            guard AVCaptureDevice.authorizationStatus(for: media) == .authorized else {
                throw XCTSkip("Live capture requires \(media.rawValue) permission for this development build")
            }
        }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow })
        let original = window.rootViewController, container = UIViewController()
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        window.rootViewController = container; window.makeKeyAndVisible()
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore())
        var active = false, left = false, failed = false
        engine.onEvent = { event in
            if event == .active { active = true }
            if event == .left { left = true }
            if [.failed, .canceled, .evicted].contains(event) { failed = true }
        }
        defer {
            engine.leave(); window.rootViewController = original
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(45)
            while !condition(), !failed, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            guard !failed, condition() else {
                XCTFail("Timed out: \(label); failed=\(failed)")
                throw NSError(domain: "GuestMediaLifecycle", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out: \(label); failed=\(failed)"])
            }
        }
        func press(_ label: String) throws {
            let button = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == L(label) && isVisible($0) && $0.isEnabled }, label)
            button.sendActions(for: .touchUpInside)
        }
        // Leave before the asynchronous audio preparation creates a call owner.
        let pending = try JoinTarget.parse(first)
        try engine.configure(container: container, networkURL: await VendorEndpointResolver.make().resolve(for: pending), displayName: "Lifecycle QA")
        try engine.join(target: pending, displayName: "Lifecycle QA")
        engine.leave()
        try await wait("pending join retired") { left && !engine.hasJoinStarted }
        // Keep the SDK initialized, as it is when the user follows multiple links.
        for (index, invite) in [first, second, first, second].enumerated() {
            active = false; left = false
            let target = try JoinTarget.parse(invite)
            try engine.configure(container: container,
                networkURL: await VendorEndpointResolver.make().resolve(for: target), displayName: "Lifecycle QA")
            try engine.join(target: target, displayName: "Lifecycle QA")
            try await wait("room \(index) connected") { active && engine.studioForTesting.enableMicrophone != nil }
            let studio = engine.studioForTesting
            print("GUEST_MEDIA_PERMISSION video=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue) audio=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) state=\(UIApplication.shared.applicationState.rawValue)")
            var previousPreview: CameraCapturePreview?
            var previousGeneration: UUID?
            XCTAssertFalse(studio.microphoneOn); XCTAssertFalse(studio.cameraOn)
            for cycle in 0..<6 {
                try press("Unmute microphone")
                if camera { try press("Start video") }
                try await wait("media enabled") { studio.microphoneOn && (!camera || studio.cameraOn) }
                if camera {
                    try await wait("capture running") { GuestCaptureDeviceObserver.currentSource() != nil }
                    let source = try XCTUnwrap(GuestCaptureDeviceObserver.currentSource())
                    let preview = try XCTUnwrap(GuestCaptureDeviceObserver.cameraPreview())
                    XCTAssertTrue(preview.session.isRunning)
                    XCTAssertNotEqual(source.generation, previousGeneration)
                    XCTAssertFalse(preview === previousPreview, "A restarted capture needs a fresh frame feed")
                    previousPreview = preview; previousGeneration = source.generation
                    print("GUEST_MEDIA_CYCLE room=\(index) cycle=\(cycle) source=\(source.generation)")
                }
                try await Task.sleep(for: .milliseconds(400))
                try press("Mute microphone")
                if camera { try press("Stop video") }
                try await wait("media disabled") { !studio.microphoneOn && !studio.cameraOn }
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertFalse(left); XCTAssertFalse(failed)
            }
            // Also exercise leaving with capture still live, before the next join.
            if camera {
                try press("Start video")
                try await wait("camera enabled before Leave") { studio.cameraOn }
            }
            engine.leave()
            try await wait("room \(index) left") { left }
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertNil(GuestCaptureDeviceObserver.currentSource())
            print("GUEST_MEDIA_ROOM_LEFT room=\(index) camera=\(camera)")
        }
    }
    private func isVisible(_ view: UIView) -> Bool {
        var node: UIView? = view
        while let current = node {
            if current.isHidden || current.alpha <= 0.01 { return false }
            node = current.superview
        }
        return view.window != nil
    }
    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
