import XCTest
import WebRTC
import Darwin
@testable import RockNRoll

@MainActor final class ApplicationMicrophoneMuteTests: XCTestCase {
    func testGestureAndAppMuteStaySynchronizedWithoutCallKit() {
        var systemMuted = false, changes: [Bool] = []
        let bridge = ApplicationMicrophoneMute(read: { systemMuted }, write: { systemMuted = $0 })
        let calls = SystemCallCoordinator(callSnapshot: { [] }, systemCallRegistration: false,
            activateAudioSession: {}, applicationMute: bridge)
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
    func testUnavailableAudioReservationReleaseBalancesNativeSession() async throws {
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
        try await wait { observer.startCount == 1 }
        newPeer = try XCTUnwrap(replacement.peerConnection(with: configuration, constraints: constraints, delegate: nil))
        try await wait { observer.startCount == 2 && observer.stopCount == 1 }
        await fulfillment(of: [started, stopped], timeout: 1)
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
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(10)
        while !predicate(), Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(predicate())
        if !predicate() { throw NSError(domain: "ConferenceOutputReplacement", code: 1) }
    }
    func testRebuiltOutputKeepsTracklessSessionRunningAndReleasesOnLeave() async throws {
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
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    init(started: XCTestExpectation, stopped: XCTestExpectation) { self.started = started; self.stopped = stopped }
    func audioSessionDidStartPlayOrRecord(_ session: RTCAudioSession) {
        lock.lock(); starts += 1; let first = starts == 1; lock.unlock()
        if first { started.fulfill() }
    }
    func audioSessionDidStopPlayOrRecord(_ session: RTCAudioSession) {
        lock.lock(); stops += 1; let first = stops == 1; lock.unlock()
        if first { stopped.fulfill() }
    }
}
