import XCTest
import AVFoundation
import WebRTC
import Darwin
@testable import RockNRoll

@MainActor final class ApplicationMicrophoneMuteTests: XCTestCase {
    func testMacPlatformCallbackGatesInputBeforeNotification() async throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_INPUT_MUTE"] == "1",
              ProcessInfo.processInfo.isiOSAppOnMac, #available(iOS 17.0, *) else { throw XCTSkip("Opt-in Mac microphone check") }
        guard let bridge = ApplicationMicrophoneMute.macGuest else { throw XCTSkip("Requires rebuilt Mac capture gate") }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw XCTSkip("Mac microphone permission") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers])
        try session.setActive(true)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { _, _ in }
        try engine.start()
        defer { input.removeTap(onBus: 0); engine.stop(); try? session.setActive(false) }
        let owner = UUID(), notified = expectation(description: "Mac mute notification")
        let app = AVAudioApplication.shared
        bridge.begin(owner: owner, muted: true) { muted in
            if !muted { notified.fulfill() }
            return true
        }
        defer { bridge.end(owner: owner) }
        print("MAC_MUTE before platform=\(app.isInputMuted) gate=\(RockMacInputMuteIsMuted())")
        XCTAssertTrue(RockMacInputMuteIsMuted())
        try app.setInputMuted(false) // Same system callback used by the accessory.
        print("MAC_MUTE after platform=\(app.isInputMuted) gate=\(RockMacInputMuteIsMuted())")
        // Unmute is admitted by the current owner through its notification;
        // a stale platform callback must never open microphone capture.
        await fulfillment(of: [notified], timeout: 3)
        XCTAssertFalse(RockMacInputMuteIsMuted())
        bridge.setMuted(true, owner: owner)
        XCTAssertTrue(RockMacInputMuteIsMuted())
    }

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
        XCTAssertNotNil(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "RTCSetApplicationInputMuteIntent"))
        XCTAssertNotNil(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "RTCApplicationInputMuteReconfiguring"))
        XCTAssertNotNil(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "RTCSetApplicationCaptureMuted"))
        XCTAssertNotNil(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "RTCApplicationCaptureMuted"))
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
}


final class GuestConferencePlayoutReservationTests: XCTestCase {
    func testInterruptionRetainsResumeRegistrationWithoutStartingAnUnavailableDevice() {
        var writes: [Bool] = []
        let lease = GuestConferencePlayoutReservation(write: { writes.append($0) })
        lease.update(joined: true, audioAvailable: false)
        XCTAssertTrue(writes.isEmpty, "An initial join cannot start output before iOS permits it")
        lease.update(joined: true, audioAvailable: true)
        lease.update(joined: true, audioAvailable: false, refresh: true)
        XCTAssertEqual(writes, [true], "During a competing call the native ADM pauses; disposing it would lose resume notification")
        lease.update(joined: true, audioAvailable: true, refresh: true)
        lease.update(joined: false, audioAvailable: false)
        XCTAssertEqual(writes, [true, true, false])
    }
    func testAudioActivationCanRetryAStartWithoutLettingRetiredOwnerDisableIt() {
        var writes: [Bool] = []
        let lease = GuestConferencePlayoutReservation(write: { writes.append($0) })
        lease.setReserved(true); lease.setReserved(true)
        lease.setReserved(true, refresh: true)
        XCTAssertEqual(writes, [true, true])
        lease.setReserved(false)
        XCTAssertEqual(writes, [true, true, false])
    }
    func testRetiredOwnerCannotStopReplacementOutputAndLeaveReleasesIt() {
        var writes: [Bool] = []
        let old = GuestConferencePlayoutReservation(write: { writes.append($0) })
        let next = GuestConferencePlayoutReservation(write: { writes.append($0) })
        old.setReserved(true); old.setReserved(true)
        next.setReserved(true); old.setReserved(false)
        XCTAssertEqual(writes, [true, true])
        next.setReserved(false); next.setReserved(false)
        XCTAssertEqual(writes, [true, true, false])
    }
    func testInterruptionReleasesAndResumeReacquiresWithoutCapturingInput() {
        var writes: [Bool] = []
        var lease: GuestConferencePlayoutReservation? = .init(write: { writes.append($0) })
        lease?.setReserved(false); lease?.setReserved(true)
        lease?.setReserved(false); lease?.setReserved(true); lease = nil
        XCTAssertEqual(writes, [true, false, true, false])
    }
}

@MainActor final class GuestConferenceOutputDeviceTests: XCTestCase {
    private var previousConfiguration: RTCAudioSessionConfiguration?
    private var previousCategory: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    override func setUp() async throws {
        try await super.setUp()
        try requirePhysicalOutputDevice()
        let session = AVAudioSession.sharedInstance()
        previousCategory = (session.category, session.mode, session.categoryOptions)
        // Match the product's preparation before a factory snapshots WebRTC
        // configuration. SoloAmbient combined with Bluetooth HFP is invalid.
        try await AudioCoordinator().prepareForJoin()
        previousConfiguration = RTCAudioSessionConfiguration.webRTC()
        let configuration = RTCAudioSessionConfiguration()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.videoChat.rawValue
        configuration.categoryOptions = [.mixWithOthers, .allowBluetoothHFP]
        RTCAudioSessionConfiguration.setWebRTC(configuration)
    }
    override func tearDown() async throws {
        if let previousConfiguration { RTCAudioSessionConfiguration.setWebRTC(previousConfiguration) }
        if let previousCategory {
            try AVAudioSession.sharedInstance().setCategory(previousCategory.0, mode: previousCategory.1, options: previousCategory.2)
        }
        try await super.tearDown()
    }
    func testUnavailableAudioReservationReleaseBalancesNativeSession() async throws {
        try requirePhysicalOutputDevice()
        guard GuestConferencePlayoutReservation.isSupported else {
            throw XCTSkip("Requires the opt-in rebuilt native audio device")
        }
        let session = RTCAudioSession.sharedInstance()
        let oldManual = session.useManualAudio, oldEnabled = session.isAudioEnabled
        let baseline = conferenceSessionCount(session)
        session.useManualAudio = true; session.isAudioEnabled = false
        let factory = RTCPeerConnectionFactory()
        let configuration = RTCConfiguration(); configuration.sdpSemantics = .unifiedPlan
        let peer = try XCTUnwrap(factory.peerConnection(with: configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil))
        let lease = GuestConferencePlayoutReservation(write: { RTCSetConferenceOutputForTest($0) })
        defer {
            lease.setReserved(false); peer.close()
            session.isAudioEnabled = oldEnabled; session.useManualAudio = oldManual
            withExtendedLifetime(factory) {}
        }
        lease.setReserved(true)
        try await wait { conferenceSessionCount(session) == baseline + 1 }
        lease.setReserved(false)
        try await wait { conferenceSessionCount(session) == baseline }
        session.isAudioEnabled = true
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(conferenceSessionCount(session), baseline, "Late availability cannot resurrect an ended reservation")
        lease.setReserved(true)
        try await wait { session.isActive && conferenceSessionCount(session) == baseline + 1 }
        lease.setReserved(false)
        try await wait { conferenceSessionCount(session) == baseline }
    }
    func testFactoryReplacementRetiresOldOutputEvenIfSDKRetainsOldPeer() async throws {
        try requirePhysicalOutputDevice()
        guard GuestConferencePlayoutReservation.isSupported else {
            throw XCTSkip("Requires the opt-in rebuilt native audio device")
        }
        let session = RTCAudioSession.sharedInstance()
        let oldManual = session.useManualAudio, oldEnabled = session.isAudioEnabled
        session.useManualAudio = true; session.isAudioEnabled = true
        let started = expectation(description: "First output started"), stopped = expectation(description: "Old output retired")
        let observer = ConferenceOutputObserver(started: started, stopped: stopped)
        session.add(observer)
        let first = RTCPeerConnectionFactory(), replacement = RTCPeerConnectionFactory()
        let configuration = RTCConfiguration(); configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let oldPeer = try XCTUnwrap(first.peerConnection(with: configuration, constraints: constraints, delegate: nil))
        let lease = GuestConferencePlayoutReservation(write: { RTCSetConferenceOutputForTest($0) })
        var newPeer: RTCPeerConnection?
        defer {
            lease.setReserved(false); oldPeer.close(); newPeer?.close(); session.remove(observer)
            session.isAudioEnabled = oldEnabled; session.useManualAudio = oldManual
            withExtendedLifetime((first, replacement)) {}
        }
        lease.setReserved(true)
        try await wait("First output session begins") { observer.startCount == 1 }
        newPeer = try XCTUnwrap(replacement.peerConnection(with: configuration, constraints: constraints, delegate: nil))
        try await wait("Replacement output begins and old output retires") { observer.startCount == 2 && observer.stopCount == 1 }
        await fulfillment(of: [started, stopped], timeout: 1)
        // Retained obsolete SDK factories cannot reclaim output by creating
        // another peer after the replacement has begun.
        let stalePeer = try XCTUnwrap(first.peerConnection(with: configuration, constraints: constraints, delegate: nil))
        stalePeer.close()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(observer.startCount, 2)
        XCTAssertEqual(observer.stopCount, 1)
        // The obsolete factory remains strongly retained, as during SDK reconnect.
        lease.setReserved(true, refresh: true)
        oldPeer.close()
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(observer.startCount, 2, "A retired worker must not restart its old output")
        XCTAssertEqual(observer.stopCount, 1)
        lease.setReserved(false)
        try await wait { observer.stopCount == 2 }
        XCTAssertFalse(session.isActive)
        // A temporary release must not permanently retire the current factory.
        lease.setReserved(true)
        try await wait { observer.startCount == 3 }
        lease.setReserved(false)
        try await wait { observer.stopCount == 3 }
        XCTAssertLessThanOrEqual(observer.maxSessionCount, 1, "Replacement cannot overlap native session ownership")
    }
    private func requirePhysicalOutputDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Native RemoteIO lifecycle requires physical iOS hardware; the Simulator uses host CoreAudio")
        #else
        guard !ProcessInfo.processInfo.isiOSAppOnMac else {
            throw XCTSkip("Trackless output reservation is disabled in the production Mac runtime; qualify it on iOS")
        }
        #endif
    }
    private func wait(_ phase: String = "Native output lifecycle", file: StaticString = #filePath, line: UInt = #line,
                      _ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(10)
        while !predicate(), Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(predicate(), "\(phase): active=\(RTCAudioSession.sharedInstance().isActive) audioEnabled=\(RTCAudioSession.sharedInstance().isAudioEnabled)", file: file, line: line)
        if !predicate() { throw NSError(domain: "ConferenceOutputReplacement", code: 1, userInfo: [NSLocalizedDescriptionKey: phase]) }
    }
    func testRebuiltOutputKeepsTracklessSessionRunningAndReleasesOnLeave() async throws {
        try requirePhysicalOutputDevice()
        guard GuestConferencePlayoutReservation.isSupported else {
            throw XCTSkip("Requires the opt-in rebuilt native audio device")
        }
        let session = RTCAudioSession.sharedInstance()
        let oldManual = session.useManualAudio, oldEnabled = session.isAudioEnabled
        let started = expectation(description: "Actual native output unit started")
        let stopped = expectation(description: "Actual native output unit stopped")
        let observer = ConferenceOutputObserver(started: started, stopped: stopped)
        session.add(observer)
        session.useManualAudio = true; session.isAudioEnabled = true
        let lease = GuestConferencePlayoutReservation(write: { RTCSetConferenceOutputForTest($0) })
        let factory = RTCPeerConnectionFactory()
        let configuration = RTCConfiguration(); configuration.sdpSemantics = .unifiedPlan
        let peer = try XCTUnwrap(factory.peerConnection(with: configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil))
        defer {
            lease.setReserved(false); peer.close(); session.remove(observer)
            session.isAudioEnabled = oldEnabled; session.useManualAudio = oldManual
            withExtendedLifetime(factory) {}
        }
        lease.setReserved(true)
        await fulfillment(of: [started], timeout: 10)
        peer.close()
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(observer.stopCount, 0, "No incoming tracks must not shut the conference output down")
        lease.setReserved(false)
        await fulfillment(of: [stopped], timeout: 10)
        XCTAssertFalse(session.isActive, "Leaving must release the session rather than retaining background audio")
    }
}

private func conferenceSessionCount(_ session: RTCAudioSession) -> Int {
    (session.value(forKey: "webRTCSessionCount") as? NSNumber)?.intValue ?? -1
}

private func RTCSetConferenceOutputForTest(_ value: Bool) {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "RTCSetConferencePlayoutReserved") else { return }
    unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Void).self)(value ? 1 : 0)
}

private final class ConferenceOutputObserver: NSObject, RTCAudioSessionDelegate {
    private let lock = NSLock()
    private let started: XCTestExpectation, stopped: XCTestExpectation
    private var starts = 0, stops = 0
    private var maxSessions = 0
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    var maxSessionCount: Int { lock.lock(); defer { lock.unlock() }; return maxSessions }
    init(started: XCTestExpectation, stopped: XCTestExpectation) { self.started = started; self.stopped = stopped }
    func audioSessionDidStartPlayOrRecord(_ session: RTCAudioSession) {
        let sessions = conferenceSessionCount(session)
        lock.lock(); starts += 1; maxSessions = max(maxSessions, sessions); let first = starts == 1; lock.unlock()
        if first { started.fulfill() }
    }
    func audioSessionDidStopPlayOrRecord(_ session: RTCAudioSession) {
        lock.lock(); stops += 1; let first = stops == 1; lock.unlock()
        if first { stopped.fulfill() }
    }
}
