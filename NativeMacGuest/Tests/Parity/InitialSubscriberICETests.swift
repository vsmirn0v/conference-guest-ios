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
    init(target: GuestPeerTarget) async throws {
        let publisher = try await engine.prepareJoinForTesting()
        peer = target == .subscriber ? try await engine.prepareSubscriberForTesting() : publisher
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
    func gather(_ state: LKRTCIceGatheringState) async {
        await withCheckedContinuation { done in
            peer.iceDiagnosticForTesting = { [weak peer] event, fields in
                guard event == "ice-gathering-state", fields["state"] as? Int == state.rawValue else { return }
                peer?.iceDiagnosticForTesting = nil
                done.resume()
            }
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
        let fixture = try await InitialICEFixture(target: target)
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

    /// A receive path that never connects reports a stall to the engine (relay fallback)
    /// and logs bounded diagnostics once, without addresses.
    @MainActor func testInitialStallReportsToTheEngineAndLogsDiagnosticsOnce() async throws {
        try await exercise { h in
            var stalls = 0, diagnostics: [[String: Any]] = []
            h.engine.onSubscriberStall = { stalls += 1 }
            h.peer.iceDiagnosticForTesting = { event, fields in if event == "ice-failure-diagnostics" { diagnostics.append(fields) } }
            h.peer.setActiveIncomingMediaDemand(true)
            await h.signal(.checking); try await h.until { h.waits.count == 1 }
            h.clock = 111; h.waits[0].release(); try await h.until { h.finished == 1 }
            XCTAssertEqual(h.failures, 1); XCTAssertEqual(stalls, 1)
            XCTAssertEqual(diagnostics.count, 1)
            XCTAssertEqual(diagnostics.first?["reason"] as? String, "deadline")
            XCTAssertNotNil(diagnostics.first?["remoteDescriptionCandidates"])
            h.peer.logStallDiagnostics(reason: "startup-audio")
            XCTAssertEqual(diagnostics.count, 1, "Stall diagnostics are logged once per peer")
        }
    }

    func testSubscriberRelayPolicyUsesTheAdvertisedRelayOnlyForTheSubscriber() throws {
        let stun: [String: Any] = ["urls": ["stun:stun.example.test:3478"]]
        let tcp: [String: Any] = ["urls": ["turn:turn.example.test:443?transport=tcp"], "username": "u", "credential": "c"]
        let udp: [String: Any] = ["urls": ["turn:turn.example.test:3478?transport=udp"], "username": "u", "credential": "c"]
        let policy = GuestICEPolicy.subscriberRelay
        XCTAssertEqual(policy.forTarget(.publisher), .automatic, "The publisher path stays direct")
        XCTAssertEqual(policy.forTarget(.subscriber), .subscriberRelay)
        let both = try policy.servers([stun, tcp, udp])
        XCTAssertEqual(both.count, 1); XCTAssertEqual(both.first?["urls"] as? [String], ["turn:turn.example.test:3478?transport=udp"])
        XCTAssertEqual(try policy.servers([stun, tcp]).first?["urls"] as? [String], ["turn:turn.example.test:443?transport=tcp"])
        XCTAssertTrue(policy.relayOnly([stun, tcp]))
        // Without an advertised relay nothing changes (never an empty candidate set).
        XCTAssertEqual(try policy.servers([stun]).count, 1)
        XCTAssertFalse(policy.relayOnly([stun]))
        XCTAssertFalse(GuestICEPolicy.automatic.relayOnly([stun, udp]))
        XCTAssertTrue(GuestICEPolicy.tcpRelay.relayOnly([tcp]), "Diagnostic relay modes keep their meaning")
        XCTAssertEqual(GuestICEPolicy.serverKinds([stun, tcp, udp, ["urls": "turns:turn.example.test:5349?transport=tcp"]]),
                       ["stun": 1, "turn-tcp": 1, "turn-udp": 1, "turns-tcp": 1])
    }

    func testRemoteDescriptionCandidateKindsCarryNoAddresses() {
        let sdp = """
        v=0\r
        a=candidate:1 1 udp 2130706431 10.0.0.5 50000 typ host\r
        a=candidate:2 1 udp 1694498815 203.0.113.9 50001 typ srflx raddr 10.0.0.5 rport 50000\r
        a=candidate:3 1 tcp 1518280447 10.0.0.5 9 typ host tcptype passive\r
        a=candidate:4 1 udp 41885439 198.51.100.1 3478 typ relay raddr 0.0.0.0 rport 0\r
        """
        let kinds = GuestPeer.candidateKinds(sdp)
        XCTAssertEqual(kinds, ["host/udp": 1, "srflx/udp": 1, "host/tcp": 1, "relay/udp": 1])
        XCTAssertFalse(kinds.keys.contains { $0.contains(".") }, "No address leaves the summary")
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

    @MainActor func testTerminalICEFailureAndInitialCancellationRemainStrict() async throws {
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

    @MainActor func testEstablishedSubscriberUsesOneDeadlineAcrossICEAndDemandChanges() async throws {
        try await exercise { h in
            await h.signal(.connected)
            await h.gather(.gathering); await h.gather(.complete)
            XCTAssertTrue(h.waits.isEmpty, "Candidate gathering cannot start recovery on a healthy connection")
            await h.signal(.disconnected); try await h.until { h.waits.count == 1 }
            XCTAssertEqual(h.waits[0].delay, 10_000_000_000)

            h.clock = 106; await h.signal(.checking)
            await h.transport(.connected)
            h.peer.setActiveIncomingMediaDemand(true)
            h.peer.setActiveIncomingMediaDemand(false)
            await h.signal(.new); await h.signal(.disconnected); await h.signal(.disconnected)
            XCTAssertEqual(h.waits.count, 1)
            XCTAssertEqual(h.failures, 0)

            h.clock = 110; h.waits[0].release(); try await h.until { h.finished == 1 }
            XCTAssertEqual(h.failures, 1)
            await h.signal(.failed); await h.signal(.closed)
            XCTAssertEqual(h.failures, 1, "Terminal callbacks after expiry cannot report another failure")
        }
    }

    @MainActor func testEstablishedPublisherRecoveryCancelsOldWaitAndNativeFailureIsImmediate() async throws {
        try await exercise(.publisher) { h in
            await h.signal(.connected); await h.signal(.disconnected)
            try await h.until { h.waits.count == 1 }
            h.clock = 106; await h.signal(.completed)
            XCTAssertEqual(h.failures, 0, "A six-second handover should retain the same peer")

            h.clock = 107; await h.signal(.checking)
            try await h.until { h.waits.count == 2 }
            XCTAssertEqual(h.waits[1].delay, 10_000_000_000)
            h.clock = 110; h.waits[0].release(); try await h.until { h.finished == 1 }
            XCTAssertEqual(h.failures, 0, "The old wait cannot fail the next outage")

            await h.signal(.failed)
            XCTAssertEqual(h.failures, 1)
            await h.signal(.connected); await h.signal(.disconnected); await h.signal(.closed)
            h.clock = 117; h.waits[1].release(); try await h.until { h.finished == 2 }
            XCTAssertEqual(h.failures, 1)
            XCTAssertEqual(h.waits.count, 2, "A failed peer cannot arm another outage")
        }
    }

    @MainActor func testUDPFailureSchedulesFallbackOnlyAfterAnUnrecoveredOutage() async throws {
        try await exercise(.publisher) { h in
            try await h.peer.configure(["iceServers": [["urls": ["turn:relay.example.test:443?transport=tcp"],
                                                        "username": "fixture", "credential": "fixture"]]])
            h.peer.observeSelectedRoute(.udp)
            var fallbacks = 0
            h.peer.onICEPathFailure = { fallbacks += 1 }
            await h.signal(.connected)
            await h.signal(.disconnected)
            try await h.until { h.waits.count == 1 }
            h.clock = 106
            await h.signal(.connected)
            h.waits[0].release()
            try await h.until { h.finished == 1 }
            XCTAssertEqual(fallbacks, 0)
            await h.signal(.failed)
            await h.signal(.closed)
            XCTAssertEqual(fallbacks, 1)
            XCTAssertEqual(h.failures, 1)
        }
        try await exercise(.publisher) { h in
            h.peer.observeSelectedRoute(.udp)
            var fallbacks = 0
            h.peer.onICEPathFailure = { fallbacks += 1 }
            await h.signal(.connected); await h.signal(.failed)
            XCTAssertEqual(fallbacks, 0, "Without a server-advertised endpoint retain ordinary recovery")
            XCTAssertEqual(h.failures, 1)
        }
    }

    @MainActor func testManualTCPPeerKeepsServersOnPartialConfigAndRejectsWithdrawal() async throws {
        let engine = NativeGuestEngine(label: "Manual relay configuration", icePolicy: .tcpRelay)
        let peer = try await engine.prepareJoinForTesting()
        do {
            try await peer.configure(["iceServers": [["urls": ["turn:relay.example.test:443?transport=tcp"],
                                                       "username": "fixture", "credential": "fixture"]]])
            try await peer.configure([:])
            let config = try await peer.currentConfiguration()
            XCTAssertEqual(config.iceServers.flatMap(\.urlStrings), ["turn:relay.example.test:443?transport=tcp"])
            do {
                try await peer.configure(["iceServers": [] as [[String: Any]]])
                XCTFail("Manual TCP may not use ordinary candidates when its relay is withdrawn")
            } catch GuestICEPolicyError.noTCPRelay { }
        } catch {
            _ = await engine.leave(sendLeave: false)
            throw error
        }
        let clean = await engine.leave(sendLeave: false)
        XCTAssertTrue(clean)
    }

    @MainActor func testReadOnlyGuestDoesNotWaitForAPublisherThatNeverOffered() async throws {
        try await exercise { h in
            h.engine.tcpRelayTargets = [.publisher]
            try await h.engine.waitForTransportRecovery()
        }
    }

    @MainActor func testClosingEstablishedPeerCancelsOutage() async throws {
        try await exercise { h in
            await h.signal(.connected); await h.signal(.disconnected)
            try await h.until { h.waits.count == 1 }
            h.peer.close()
            h.clock = 110; h.waits[0].release(); try await h.until { h.finished == 1 }
            XCTAssertEqual(h.failures, 0)
        }
    }
}
#endif
