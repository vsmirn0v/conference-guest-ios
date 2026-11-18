import XCTest
import AVFoundation
import Darwin
@testable import RockNRoll

@MainActor final class ApplicationMicrophoneMuteTests: XCTestCase {
    func testStalePlatformUnmuteCannotOpenCapture() {
        var systemMuted = true, captureMuted = true, changes = 0
        let bridge = ApplicationMicrophoneMute(read: { systemMuted }, write: { systemMuted = $0 },
            reconcileCapture: { captureMuted = $0 })
        bridge.begin(owner: UUID(), muted: true) { _ in changes += 1; return true }
        captureMuted = false // A delayed callback is followed by a stale notification.
        bridge.received(false)
        XCTAssertTrue(captureMuted)
        XCTAssertEqual(changes, 0)
    }

    func testReentrantReplacementKeepsItsCaptureIntent() {
        var systemMuted = false, captureMuted = false
        let replacement = UUID()
        var replace = false
        var bridge: ApplicationMicrophoneMute!
        bridge = ApplicationMicrophoneMute(read: { systemMuted }, write: { value in
            systemMuted = value
            if replace {
                replace = false
                bridge.begin(owner: replacement, muted: false) { _ in true }
            }
        }, reconcileCapture: { captureMuted = $0 })
        let owner = UUID()
        bridge.begin(owner: owner, muted: false) { _ in true }
        replace = true
        bridge.setMuted(true, owner: owner)
        XCTAssertFalse(captureMuted)
        bridge = nil
    }

    func testNativeResetNotificationDoesNotBecomeAnAccessoryUnmute() {
        var systemMuted = true, reconfiguring = false, intent = false, changes: [Bool] = []
        let bridge = ApplicationMicrophoneMute(read: { systemMuted }, write: { systemMuted = $0 },
            publishIntent: { intent = $0 }, isReconfiguring: { reconfiguring })
        bridge.begin(owner: UUID(), muted: true) { changes.append($0); return true }
        XCTAssertTrue(intent, "Publish app intent even when the platform bit already matches")
        reconfiguring = true
        systemMuted = false; bridge.received(false)
        XCTAssertTrue(intent); XCTAssertTrue(changes.isEmpty)
        systemMuted = intent; bridge.received(true)
        reconfiguring = false
        systemMuted = false; bridge.received(false)
        XCTAssertFalse(intent); XCTAssertEqual(changes, [false], "Real accessory gestures must update native intent too")
    }

    func testNewAppActionAndReplacementOwnerWinDuringNativeRecovery() {
        var systemMuted = true, intent = true, released = false
        let bridge = ApplicationMicrophoneMute(read: { systemMuted }, write: { systemMuted = $0 },
            publishIntent: { intent = $0 }, releaseIntent: { released = true }, isReconfiguring: { true })
        let old = UUID(), replacement = UUID()
        bridge.begin(owner: old, muted: true) { _ in true }
        bridge.setMuted(false, owner: old)
        XCTAssertFalse(intent); XCTAssertFalse(systemMuted)
        bridge.begin(owner: replacement, muted: false) { _ in true }
        bridge.setMuted(true, owner: old); bridge.end(owner: old)
        XCTAssertFalse(intent, "A retired owner cannot change the replacement's native intent")
        bridge.end(owner: replacement)
        XCTAssertTrue(released); XCTAssertTrue(systemMuted)
    }

    func testPrivateCapturePublishesCurrentIntentAcrossNativeRecovery() {
        var systemMuted = true, intent = true, changes: [Bool] = []
        let bridge = ApplicationMicrophoneMute(read: { systemMuted }, write: { systemMuted = $0 },
            publishIntent: { intent = $0 }, isReconfiguring: { true })
        bridge.begin(owner: UUID(), muted: true) { changes.append($0); return true }
        let token = bridge.beginPrivateCapture()
        XCTAssertFalse(intent); XCTAssertFalse(systemMuted)
        bridge.received(false)
        XCTAssertTrue(changes.isEmpty)
        bridge.endPrivateCapture(token)
        XCTAssertTrue(intent); XCTAssertTrue(systemMuted)
    }

    func testPrivateMuteGestureSurvivesNativeRecoveryWithoutChangingMeetingMute() {
        var systemMuted = true, intent = true, reconfiguring = false, changes: [Bool] = []
        let bridge = ApplicationMicrophoneMute(read: { systemMuted }, write: { systemMuted = $0 },
            publishIntent: { intent = $0 }, isReconfiguring: { reconfiguring })
        bridge.begin(owner: UUID(), muted: true) { changes.append($0); return true }
        let first = bridge.beginPrivateCapture()
        systemMuted = true; bridge.received(true)
        XCTAssertTrue(intent); XCTAssertTrue(changes.isEmpty)
        let second = bridge.beginPrivateCapture()
        XCTAssertTrue(intent, "An overlapping private capture must not undo a private mute gesture")
        reconfiguring = true; systemMuted = false; bridge.received(false)
        systemMuted = intent; reconfiguring = false
        XCTAssertTrue(systemMuted); XCTAssertTrue(changes.isEmpty)
        bridge.endPrivateCapture(first); XCTAssertTrue(systemMuted)
        bridge.endPrivateCapture(second); XCTAssertTrue(systemMuted)
    }

    func testPrivateInputKeepsItsObserverWhenMeetingEnds() {
        var systemMuted = false, intent: Bool?, handler: ((Bool) -> Void)?
        let bridge = ApplicationMicrophoneMute(read: { systemMuted }, write: { systemMuted = $0 },
            observe: { callback in
                handler = callback
                return NotificationCenter.default.addObserver(forName: Notification.Name("PrivateMuteTest"),
                    object: nil, queue: .main) { _ in }
            }, publishIntent: { intent = $0 }, releaseIntent: { intent = nil })
        let owner = UUID()
        bridge.begin(owner: owner, muted: true) { _ in XCTFail("A private gesture must not change the meeting"); return false }
        let capture = bridge.beginPrivateCapture()
        bridge.end(owner: owner)
        systemMuted = true; handler?(true)
        XCTAssertEqual(intent, true)
        bridge.endPrivateCapture(capture)
        XCTAssertNil(intent)
    }

    func testNativeIntentBridgeIsEmbeddedInTheGuestFramework() throws {
        XCTAssertNotNil(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "LKRTCSetApplicationInputMuteIntent"))
        XCTAssertNotNil(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "LKRTCApplicationInputMuteReconfiguring"))
        XCTAssertNotNil(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "LKRTCSetApplicationCaptureMuted"))
        XCTAssertNotNil(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "LKRTCApplicationCaptureMuted"))
    }

    func testGestureCallbackCannotOverwriteReplacementOwnersIntent() {
        for accepted in [false, true] {
            var systemMuted = true, intent = true
            var bridge: ApplicationMicrophoneMute!
            bridge = ApplicationMicrophoneMute(read: { systemMuted }, write: { systemMuted = $0 },
                publishIntent: { intent = $0 })
            bridge.begin(owner: UUID(), muted: true) { _ in
                bridge.begin(owner: UUID(), muted: accepted) { _ in true }
                return accepted
            }
            systemMuted = false; bridge.received(false)
            XCTAssertEqual(intent, accepted); XCTAssertEqual(systemMuted, accepted)
        }
    }

    func testLeavingWithdrawsNativeAuthorityBeforeCallKitOwnsTheNextMeeting() {
        var systemMuted = true, intent: Bool?
        let bridge = ApplicationMicrophoneMute(read: { systemMuted }, write: { systemMuted = $0 },
            publishIntent: { intent = $0 }, releaseIntent: { intent = nil })
        let owner = UUID()
        bridge.begin(owner: owner, muted: true) { _ in true }
        XCTAssertEqual(intent, true)
        bridge.end(owner: owner)
        XCTAssertNil(intent, "The next CallKit-owned meeting must not inherit this app owner's mute")
        systemMuted = false  // The next meeting is unmuted by CallKit.
        bridge.setMuted(true, owner: owner)
        XCTAssertNil(intent); XCTAssertFalse(systemMuted)
        let privateCheck = bridge.beginPrivateCapture()
        XCTAssertEqual(intent, false)
        bridge.endPrivateCapture(privateCheck)
        XCTAssertNil(intent, "Private input also releases its native authority when finished")
    }

    func testGestureAndAppMuteStaySynchronizedWithoutCallKit() {
        var systemMuted = false, changes: [Bool] = []
        let bridge = ApplicationMicrophoneMute(read: { systemMuted }, write: { systemMuted = $0 })
        let calls = SystemCallCoordinator(callSnapshot: { [] }, systemCallRegistration: false,
            activateAudioSession: {}, applicationMute: bridge, sessionWorker: AudioSessionWorker(activate: {}, deactivate: {}))
        calls.onMuteChanged = { changes.append($0) }
        calls.start(); calls.markConnected()
        XCTAssertTrue(systemMuted)
        systemMuted = false; bridge.received(false)
        XCTAssertEqual(changes, [false])
        calls.setMuted(true); bridge.received(true)
        XCTAssertTrue(systemMuted); XCTAssertEqual(changes, [false], "App updates must not echo as accessory actions")
        calls.end(); systemMuted = false; bridge.received(false)
        XCTAssertEqual(changes, [false], "A departed meeting cannot receive a late gesture")
    }
    func testPerMeetingBridgeDoesNotLeakIntoNextEngine() {
        var defaultMuted = false, guestMuted = false, changes: [Bool] = []
        let original = ApplicationMicrophoneMute(read: { defaultMuted }, write: { defaultMuted = $0 })
        let guest = ApplicationMicrophoneMute(read: { guestMuted }, write: { guestMuted = $0 })
        let calls = SystemCallCoordinator(callSnapshot: { [] }, systemCallRegistration: false,
            activateAudioSession: {}, applicationMute: original,
            sessionWorker: AudioSessionWorker(activate: {}, deactivate: {}))
        calls.onMuteChanged = { changes.append($0) }
        calls.start(accessoryMute: guest); calls.markConnected()
        XCTAssertTrue(guestMuted); XCTAssertFalse(defaultMuted)
        guestMuted = false; guest.received(false)
        XCTAssertEqual(changes, [false])
        calls.end()
        calls.start(); calls.markConnected()
        XCTAssertTrue(defaultMuted)
        guestMuted = false; guest.received(false)
        XCTAssertEqual(changes, [false], "The old engine no longer owns accessory gestures")
        defaultMuted = false; original.received(false)
        XCTAssertEqual(changes, [false, false])
        calls.end()
    }
    func testPrivateSoundCheckGesturesNeverUnmuteTheMeeting() {
        var systemMuted = false, changes: [Bool] = []
        let bridge = ApplicationMicrophoneMute(read: { systemMuted }, write: { systemMuted = $0 })
        let owner = UUID()
        bridge.begin(owner: owner, muted: true) { changes.append($0); return true }
        let first = bridge.beginPrivateCapture(), second = bridge.beginPrivateCapture()
        XCTAssertFalse(systemMuted)
        systemMuted = true; bridge.received(true)
        systemMuted = false; bridge.received(false)
        XCTAssertTrue(changes.isEmpty)
        bridge.endPrivateCapture(first); XCTAssertFalse(systemMuted)
        bridge.endPrivateCapture(second); XCTAssertTrue(systemMuted)
        bridge.received(false); XCTAssertTrue(changes.isEmpty, "Delayed private-unmute notification is stale")
        bridge.end(owner: owner)
    }
    func testHeldMeetingRejectsAccessoryUnmuteAndOldOwnerCannotChangeReplacement() {
        var systemMuted = false
        let bridge = ApplicationMicrophoneMute(read: { systemMuted }, write: { systemMuted = $0 })
        let old = UUID(), next = UUID()
        bridge.begin(owner: old, muted: true) { _ in false }
        systemMuted = false; bridge.received(false); XCTAssertTrue(systemMuted)
        bridge.begin(owner: next, muted: false) { _ in true }
        bridge.end(owner: old); bridge.setMuted(true, owner: old)
        XCTAssertFalse(systemMuted)
        bridge.end(owner: next); XCTAssertTrue(systemMuted)
    }
    func testSystemAudioResetPreservesMutedAndUnmutedIntentBeforeAcceptingGestures() throws {
        for muted in [true, false] {
            var systemMuted = false, changes: [Bool] = []
            let bridge = ApplicationMicrophoneMute(read: { systemMuted }, write: { systemMuted = $0 })
            let calls = SystemCallCoordinator(callSnapshot: { [] }, systemCallRegistration: false,
                activateAudioSession: { systemMuted = false }, applicationMute: bridge, sessionWorker: AudioSessionWorker(activate: {}, deactivate: {}))
            calls.onMuteChanged = { changes.append($0) }
            calls.start(); calls.markConnected(); calls.setMuted(muted)
            calls.audioServicesChanged(false)
            systemMuted = false; bridge.received(false)
            XCTAssertTrue(changes.isEmpty, "A reset is not an accessory unmute")
            calls.audioServicesChanged(true)
            XCTAssertEqual(systemMuted, muted)
            bridge.received(false)
            XCTAssertTrue(changes.isEmpty, "Stale reset notifications must not alter restored intent")
            systemMuted = !muted; bridge.received(!muted)
            XCTAssertEqual(changes, [!muted], "Real gestures must work after recovery")
            calls.end()
        }
    }

    private final class PlatformMuteProbeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var muted = false
        private var now: TimeInterval = 100
        private var writes: [(value: Bool, onMain: Bool)] = []

        var isMuted: Bool {
            lock.lock(); defer { lock.unlock() }
            return muted
        }

        var currentTime: TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return now
        }

        var recordedWrites: [(value: Bool, onMain: Bool)] {
            lock.lock(); defer { lock.unlock() }
            return writes
        }

        func setMuted(_ value: Bool, delay: TimeInterval = 0, record: Bool = false) {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            lock.lock()
            muted = value
            if record { writes.append((value, Thread.isMainThread)) }
            lock.unlock()
        }

        func advanceTime(by delta: TimeInterval, resetPlatformMuted: Bool? = nil) {
            lock.lock()
            now += delta
            if let resetPlatformMuted { muted = resetPlatformMuted }
            lock.unlock()
        }
    }

    func testLivePlatformInputMuteBoxCoalescesRapidWritesOffMainThread() async throws {
        let queue = DispatchQueue(label: "test.live-mute-coalesce")
        let worker = AudioSessionWorker(queue: queue)
        let probe = PlatformMuteProbeBox()
        let notifications = NotificationCenter()

        let box = LivePlatformInputMuteBox(
            worker: worker,
            readPlatform: { probe.isMuted },
            writePlatform: { probe.setMuted($0, delay: 0.01, record: true) },
            notifications: notifications
        )

        queue.suspend()
        let start = ContinuousClock.now
        for i in 0..<20 {
            box.write(i % 2 == 0)
        }
        let mainElapsed = start.duration(to: .now)
        XCTAssertLessThan(mainElapsed, .milliseconds(100), "Rapid writes must never block the main thread")
        XCTAssertFalse(box.read())
        queue.resume()

        try await worker.perform(lease: AudioSessionLease(), operation: {})
        let recorded = probe.recordedWrites

        XCTAssertFalse(probe.isMuted)
        XCTAssertLessThanOrEqual(recorded.count, 2, "Coalesced worker must collapse rapid intermediate toggles")
        XCTAssertTrue(recorded.allSatisfy { !$0.onMain }, "Platform writes must never execute on main thread")
    }

    func testLivePlatformInputMuteBoxSuppressesSpuriousNotificationDuringRouteResetAndRestoresIntent() async throws {
        let queue = DispatchQueue(label: "test.live-mute-reset")
        let worker = AudioSessionWorker(queue: queue)
        let probe = PlatformMuteProbeBox()
        let notifications = NotificationCenter()

        let box = LivePlatformInputMuteBox(
            worker: worker,
            readPlatform: { probe.isMuted },
            writePlatform: { probe.setMuted($0) },
            uptime: { probe.currentTime },
            notifications: notifications
        )

        var changes: [Bool] = []
        let bridge = ApplicationMicrophoneMute(
            read: { box.read() },
            write: { box.write($0) },
            isReconfiguring: { box.isReconfiguring(nativeReconfiguring: false) }
        )
        bridge.begin(owner: UUID(), muted: true) { changes.append($0); return true }
        try await worker.perform(lease: AudioSessionLease(), operation: {})

        // Advance past write grace window and simulate a route change where VPIO resets platform muted = false.
        probe.advanceTime(by: 1.0, resetPlatformMuted: false)

        notifications.post(name: AVAudioSession.routeChangeNotification, object: nil)
        for _ in 0..<50 where !box.isReconfiguring(nativeReconfiguring: false) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(box.isReconfiguring(nativeReconfiguring: false))

        box.handleNotification(false, nativeReconfiguring: false) { muted in
            bridge.received(muted)
        }
        XCTAssertTrue(changes.isEmpty, "Route reconfiguration reset must not trigger an unmute gesture")
        XCTAssertTrue(box.read())

        try await worker.perform(lease: AudioSessionLease(), operation: {})
        XCTAssertTrue(probe.isMuted, "Worker must restore desired mute state after VPIO reset")

        // Outside the reconfiguration window, genuine accessory unmute must still work.
        probe.advanceTime(by: 1.0, resetPlatformMuted: false)
        box.handleNotification(false, nativeReconfiguring: false) { muted in
            bridge.received(muted)
        }
        XCTAssertEqual(changes, [false])
    }
}
