#if DEBUG
import Foundation
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

@MainActor private final class InitialICEFixture {
    final class Wait {
        let delay: UInt64
        private var continuation: CheckedContinuation<Void, Error>?
        init(_ delay: UInt64, _ continuation: CheckedContinuation<Void, Error>) {
            self.delay = delay; self.continuation = continuation
        }
        func release() { let pending = continuation; continuation = nil; pending?.resume() }
    }
    let engine = NativeGuestEngine(label: "Initial subscriber ICE test")
    let peer: GuestPeer
    var clock: TimeInterval = 100
    var waits: [Wait] = []
    var failures = 0, finished = 0
    init(target: GuestPeerTarget) throws {
        let publisher = try engine.prepareJoinForTesting()
        peer = target == .subscriber ? try engine.prepareSubscriberForTesting() : publisher
        peer.iceClockForTesting = { [weak self] in self?.clock ?? 0 }
        peer.iceWaitForTesting = { [weak self] delay in
            try await withCheckedThrowingContinuation { [weak self] done in
                guard let self else { done.resume(throwing: CancellationError()); return }
                self.waits.append(Wait(delay, done))
            }
        }
        let originalFailure = peer.onFailure
        peer.onFailure = { [weak self] error in self?.failures += 1; originalFailure?(error) }
        peer.iceTimerFinishedForTesting = { [weak self] in self?.finished += 1 }
    }
    func signal(_ state: LKRTCIceConnectionState) async {
        await withCheckedContinuation { done in
            peer.iceEventFinishedForTesting = { done.resume() }
            peer.peerConnection(peer.connection, didChange: state)
        }
    }
    func transport(_ state: LKRTCPeerConnectionState) async {
        await withCheckedContinuation { done in
            peer.transportEventFinishedForTesting = { done.resume() }
            peer.peerConnection(peer.connection, didChange: state)
        }
    }
    func receive(_ receiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) async {
        await withCheckedContinuation { done in
            peer.receiverEventFinishedForTesting = { done.resume() }
            peer.peerConnection(peer.connection, didAdd: receiver, streams: streams)
        }
    }
    func until(_ condition: () -> Bool) async throws {
        for _ in 0..<5_000 { if condition() { return }; await Task.yield() }
        XCTFail("Native delegate/timer task did not reach its synchronization point")
        throw CancellationError()
    }
    func update(audioMuted: Bool, videoMuted: Bool = true, version: Int = 1) async throws {
        try await engine.processEventForTesting(["event": "media-out", "payload": [
            "method": "rtc:participants:update", "update": ["participants": [[
                "sid": "PA_remote", "identity": "remote", "version": version, "state": "ACTIVE", "tracks": [
                    ["sid": "TR_audio", "type": "AUDIO", "source": "MICROPHONE", "muted": audioMuted],
                    ["sid": "TR_video", "type": "VIDEO", "source": "CAMERA", "muted": videoMuted]]]]]]])
    }
    func stop() async {
        peer.close(); waits.forEach { $0.release() }
        let clean = await engine.leave(sendLeave: false)
        XCTAssertTrue(clean)
    }
}

final class InitialSubscriberICETests: XCTestCase {
    @MainActor private func exercise(_ target: GuestPeerTarget = .subscriber,
                                    _ body: (InitialICEFixture) async throws -> Void) async throws {
        let fixture = try InitialICEFixture(target: target)
        do { try await body(fixture) }
        catch { await fixture.stop(); throw error }
        await fixture.stop()
    }

    @MainActor func testUnusedInitialFailureCanConnectOnTheSamePeerWithoutStickyEngineError() async throws {
        try await exercise { h in
            h.engine.mediaNotifyForTesting = { _ in }
            try await h.update(audioMuted: true)
            await h.signal(.checking); await h.signal(.failed)
            await h.transport(.failed); await h.transport(.connecting)
            XCTAssertEqual(h.failures, 0); XCTAssertTrue(h.waits.isEmpty); XCTAssertNil(h.engine.failure)
            await h.signal(.connected); await h.transport(.connected)
            h.peer.setActiveIncomingMediaDemand(true)
            XCTAssertTrue(h.peer.transportConnected); XCTAssertTrue(h.waits.isEmpty)
            XCTAssertNil(h.engine.failure)
            await h.signal(.failed)
            XCTAssertEqual(h.failures, 1, "Established ICE failure remains fatal")
            XCTAssertNotNil(h.engine.failure)
            await h.signal(.connected); await h.transport(.connected)
            XCTAssertNotNil(h.engine.failure, "Later connection must never clear a sticky engine error")
        }
    }

    @MainActor func testCheckingFailedAndDemandChurnUseTheOriginalRemainingDeadline() async throws {
        try await exercise { h in
            h.peer.setActiveIncomingMediaDemand(true)
            await h.signal(.checking); try await h.until { h.waits.count == 1 }
            h.clock = 103; await h.signal(.failed); try await h.until { h.waits.count == 2 }
            XCTAssertEqual(h.failures, 0)
            h.clock = 105; h.peer.setActiveIncomingMediaDemand(false)
            await h.signal(.checking)
            h.clock = 106; h.peer.setActiveIncomingMediaDemand(true)
            try await h.until { h.waits.count == 3 }
            XCTAssertEqual(h.waits.map(\.delay), [10_000_000_000, 7_000_000_000, 4_000_000_000])
            await h.signal(.checking)
            XCTAssertEqual(h.waits.count, 3, "Duplicate state cannot renew the timer")
            h.waits[0].release(); h.waits[1].release()
            try await h.until { h.finished == 2 }
            XCTAssertEqual(h.failures, 0, "Cancelled waits cannot fail a newer state")
            h.clock = 110; h.waits[2].release(); try await h.until { h.finished == 3 }
            XCTAssertEqual(h.failures, 1, "The active initial connection expires at the original deadline")
        }
    }

    @MainActor func testUnusedFailedStateRetainsExpiredDemandDeadline() async throws {
        try await exercise { h in
            await h.signal(.failed)
            h.peer.setActiveIncomingMediaDemand(true); try await h.until { h.waits.count == 1 }
            h.clock = 103; h.peer.setActiveIncomingMediaDemand(false)
            h.waits[0].release(); try await h.until { h.finished == 1 }
            h.clock = 112
            XCTAssertEqual(h.failures, 0, "Unused state suppresses enforcement")
            h.peer.setActiveIncomingMediaDemand(true)
            XCTAssertEqual(h.failures, 1, "Resumed demand cannot receive a fresh budget")
            XCTAssertEqual(h.waits.count, 1)
            h.peer.setActiveIncomingMediaDemand(false); h.peer.setActiveIncomingMediaDemand(true)
            XCTAssertEqual(h.failures, 1, "Initial deadline expiry reports once")
        }
    }

    @MainActor func testUnmutedPendingSubscriptionStartsBudgetBeforeAcknowledgementOrReceiver() async throws {
        try await exercise { h in
            await h.signal(.failed)
            var release: CheckedContinuation<Void, Never>?, entered = false, released = false
            h.engine.mediaNotifyForTesting = { command in
                guard command["subscription"] != nil else { return }
                entered = true
                if !released { await withCheckedContinuation { release = $0 } }
            }
            let update = Task { try await h.update(audioMuted: false) }
            do {
                try await h.until { entered && h.waits.count == 1 }
                XCTAssertTrue(h.peer.receivedAudioSources.isEmpty)
                XCTAssertEqual(h.waits[0].delay, 10_000_000_000)
                XCTAssertEqual(h.failures, 0)
            } catch { released = true; release?.resume(); _ = try? await update.value; throw error }
            released = true; release?.resume(); try await update.value
            await h.signal(.connected)
            h.clock = 111; h.waits[0].release(); try await h.until { h.finished == 1 }
            XCTAssertEqual(h.failures, 0)
        }
    }

    @MainActor func testUnknownAudioAndVideoReceiverDemandThenAuthoritativeMutedStateBecomesDormant() async throws {
        for audio in [true, false] {
            try await exercise { h in
                h.engine.mediaNotifyForTesting = { _ in }
                await h.signal(.failed)
                let receiver = try XCTUnwrap(h.peer.connection.addTransceiver(of: audio ? .audio : .video)?.receiver)
                let stream = h.peer.factory.mediaStream(withStreamId: audio ? "PA_remote|TR_audio" : "PA_remote|TR_video")
                await h.receive(receiver, streams: [stream])
                try await h.until { h.waits.count == 1 }
                XCTAssertEqual(h.failures, 0)
                h.clock = 102; try await h.update(audioMuted: true)
                h.clock = 111; h.waits[0].release(); try await h.until { h.finished == 1 }
                XCTAssertEqual(h.failures, 0, "Authoritative muted receivers stay dormant past the retained deadline")
                XCTAssertEqual(h.waits.count, 1)
                do { try await h.update(audioMuted: !audio, videoMuted: audio, version: 2) }
                catch GuestPeerError.iceFailed { }
                XCTAssertEqual(h.failures, 1, "Unmuting consumes the already expired initial budget")
            }
        }
    }

    @MainActor func testPublisherEstablishedDisconnectUnexpectedCloseAndCancellationRemainStrict() async throws {
        try await exercise(.publisher) { h in
            await h.signal(.failed)
            XCTAssertEqual(h.failures, 1); XCTAssertTrue(h.waits.isEmpty)
        }
        try await exercise { h in
            await h.transport(.connected)
            await h.signal(.failed)
            XCTAssertEqual(h.failures, 1, "Overall connected also establishes a subscriber")
        }
        try await exercise { h in
            await h.signal(.connected); await h.signal(.disconnected)
            try await h.until { h.waits.count == 1 }
            XCTAssertEqual(h.waits[0].delay, 5_000_000_000)
            h.waits[0].release(); try await h.until { h.finished == 1 }
            XCTAssertEqual(h.failures, 1)
        }
        try await exercise { h in
            await h.signal(.closed)
            XCTAssertEqual(h.failures, 1, "Unexpected native closure is fatal even without demand")
        }
        try await exercise { h in
            await h.signal(.failed); h.peer.setActiveIncomingMediaDemand(true)
            try await h.until { h.waits.count == 1 }
            h.peer.close(); h.clock = 111; h.waits[0].release()
            try await h.until { h.finished == 1 }
            h.peer.setActiveIncomingMediaDemand(false); h.peer.setActiveIncomingMediaDemand(true)
            XCTAssertEqual(h.failures, 0); XCTAssertEqual(h.waits.count, 1)
        }
    }
}
#endif
