import AVFoundation
import CallKit
import LiveKitWebRTC
import XCTest
@testable import MeetingEngine
@testable import RockNRoll

@MainActor
final class IOSWorkspaceAudioCoordinatorTests: XCTestCase {
    private final class MockSession: WorkspaceAudioControllableSession {
        let id = UUID()
        var micOn = false
        var playoutOn = true
        var inputPermitted = true
        var events: [String] = []
        var failNextUnmute = false

        var appliedAudioState: (microphoneOn: Bool, playoutOn: Bool) {
            (micOn, playoutOn)
        }

        func setMicrophone(_ enabled: Bool) async throws {
            events.append("mic:\(enabled)")
            if enabled && failNextUnmute {
                failNextUnmute = false
                throw MeetingSessionError.unavailable("Unmute rejected in test")
            }
            micOn = enabled
        }

        func setPlayout(_ enabled: Bool) async throws {
            events.append("playout:\(enabled)")
            playoutOn = enabled
        }

        func setPhysicalInputPermitted(_ permitted: Bool, keepDeviceWarm: Bool) async -> Bool {
            events.append("permit:\(permitted):warm=\(keepDeviceWarm)")
            inputPermitted = permitted
            return true
        }

        func prepareAudioMuteIntent() {
            events.append("prepare-audio-mute")
        }
    }

    @MainActor
    private final class SpyProviderAdapter: MeetingProviderAdapter {
        let kind: MeetingEngineKind = .guest
        let capabilities: MeetingSessionCapabilities = .guest(canViewChat: true, canSendChat: true, canReact: true)
        var connectionIdentity: MeetingConnectionIdentity?
        var snapshot = NativeDesktopExternalSnapshot(phase: .connected)
        var sessionSnapshot = MeetingSessionSnapshot(phase: .connected, capabilities: .guest(canViewChat: true, canSendChat: true, canReact: true))
        var incomingVideo: [NativeDesktopExternalVideo] = []
        var factory: LKRTCPeerConnectionFactory? { nil }
        var privateAudioLevel: Float? { nil }
        var ownershipDiagnostics: [String: Any] { [:] }
        var microphoneTrackProbe: GuestMicrophoneTrackProbe? { nil }
        var microphoneStartupMilliseconds: [String: Double] { [:] }
        var microphoneReadinessPolicy: (() -> Bool)?

        var onState: ((NativeDesktopExternalSnapshot) -> Void)?
        var onSessionSnapshot: ((MeetingSessionSnapshot) -> Void)?
        var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
        var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
        var onTitle: ((String) -> Void)?
        var onFeatures: ((GuestMeetingSnapshot) -> Void)?
        var onCapturedMessages: (([GuestMeetingMessage], Bool) -> Void)?
        var onFeatureError: ((Error) -> Void)?

        var prepareLocalMuteCalls: [(Bool?, Bool?)] = []
        var suppressOutgoingMediaCalls = 0
        var micOn = false

        func connect(invitation: URL, name: String, quiet: Bool, sessionID: MeetingSessionID) async throws {}
        func reconnect() async throws {}
        func leave() async -> Bool { true }
        func setMicrophone(_ enabled: Bool) async throws {
            micOn = enabled
            sessionSnapshot.effective.microphoneOn = enabled
        }
        func setCamera(_ enabled: Bool) async throws {}
        func setPlayout(_ enabled: Bool) async throws {}
        func setPlayoutVolume(_ volume: Double) async {}
        func setParticipantVolume(_ volume: Double, participantID: String) async {}
        func configureConcurrentAudio(_ concurrent: Bool) {}
        func setPhysicalInputPermitted(_ permitted: Bool, keepDeviceWarm: Bool) async -> Bool { true }
        func prewarmInput() async -> Bool { true }
        func prepareMutedCaptureForAccessories() async throws {}
        func setMicrophoneReadinessForRecovery(_ enabled: Bool) {}
        func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {}
        func setVideoDemand(_ demand: MeetingEngine.MeetingVideoDemand) async throws {}
        func cameraCaptureDevice() async -> AVCaptureDevice? { nil }
        func startPrivateAudioCheck() async throws {}
        func stopPrivateAudioCheck() async throws {}
        func setLocalAudioSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) {}
        func setTranscriptionAudioHandler(_ handler: (([MeetingAudioSource]) -> Void)?) {}
        func setTranscriptionOutput(_ keep: Bool) async -> Bool { false }
        func setTranscriptionRequested(_ requested: Bool) {}
        func setMicrophoneGate(open: Bool) async -> Bool { true }
        func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool { false }
        func prepareLocalMuteIntent(audioMuted: Bool?, videoMuted: Bool?) {
            prepareLocalMuteCalls.append((audioMuted, videoMuted))
        }
        func suppressOutgoingMedia() {
            suppressOutgoingMediaCalls += 1
        }
    }

    private final class FakeMuteAction: CXSetMutedCallAction {
        var fulfilled = false
        override func fulfill() { fulfilled = true }
    }

    private final class FakeHoldAction: CXSetHeldCallAction {
        var fulfilled = false
        override func fulfill() { fulfilled = true }
    }

    private func makeHarness(startFailure: Error? = nil) -> (
        coordinator: IOSWorkspaceAudioCoordinator,
        provider: CXProvider,
        startActions: () -> [CXStartCallAction],
        endActions: () -> [CXEndCallAction],
        muteActions: () -> [CXSetMutedCallAction],
        titleUpdates: () -> [(UUID, String?)],
        setObservedCalls: ([SystemCallCoordinator.ObservedCall]) -> Void
    ) {
        let queue = DispatchQueue(label: "test.ios-workspace-audio.\(UUID().uuidString)")
        let worker = AudioSessionWorker(queue: queue, activate: {}, deactivate: {})
        var actions: [CXAction] = []
        var updates: [(UUID, String?)] = []
        var snapshot: [SystemCallCoordinator.ObservedCall] = []

        let systemCall = SystemCallCoordinator(
            transactionRequester: { transaction, done in
                actions.append(contentsOf: transaction.actions)
                if let startFailure, transaction.actions.contains(where: { $0 is CXStartCallAction }) {
                    done(startFailure)
                } else {
                    done(nil)
                }
            },
            callUpdateReporter: { callID, update in
                updates.append((callID, update.localizedCallerName))
            },
            callSnapshot: { snapshot },
            systemCallRegistration: true,
            activateAudioSession: {},
            sessionWorker: worker
        )
        let audio = AudioCoordinator(worker: worker, prepareSession: {})
        let coordinator = IOSWorkspaceAudioCoordinator(
            systemCall: systemCall,
            audio: audio,
            captureGate: .live,
            sharedAudio: nil,
            configureLiveKit: false
        )
        let provider = CXProvider(configuration: SystemCallCoordinator.providerConfiguration())
        return (
            coordinator,
            provider,
            { actions.compactMap { $0 as? CXStartCallAction } },
            { actions.compactMap { $0 as? CXEndCallAction } },
            { actions.compactMap { $0 as? CXSetMutedCallAction } },
            { updates },
            { snapshot = $0 }
        )
    }

    override func tearDown() {
        LKRTCSetApplicationCaptureMuted(0)
        super.tearDown()
    }

    func testAggregateLeaseLivesThroughZeroOneToFourAndEndsAtZero() async throws {
        let h = makeHarness()
        defer { h.provider.invalidate(); h.coordinator.systemCall.markEnded(reason: .remoteEnded) }

        let s1 = MockSession(), s2 = MockSession(), s3 = MockSession(), s4 = MockSession(), s5 = MockSession()
        h.coordinator.registerSession(s1, title: "Standup")
        await h.coordinator.waitForAggregateLeaseForTesting()

        let callID = try XCTUnwrap(h.coordinator.systemCall.callID)
        XCTAssertEqual(h.startActions().count, 1)
        XCTAssertEqual(h.endActions().count, 0)
        XCTAssertEqual(h.coordinator.talkSessionID, s1.id)
        XCTAssertEqual(h.coordinator.activeSessionCount, 1)
        XCTAssertEqual(h.titleUpdates().last?.1, "Standup")

        h.coordinator.markSessionConnected(id: s1.id)
        h.setObservedCalls([.init(id: callID, connected: true, held: false)])

        h.coordinator.registerSession(s2, title: "Design")
        h.coordinator.registerSession(s3, title: "Sync")
        h.coordinator.registerSession(s4, title: "Planning")
        h.coordinator.registerSession(s5, title: "Overflow")
        await Task.yield()

        XCTAssertEqual(h.coordinator.activeSessionCount, 4)
        XCTAssertEqual(h.startActions().count, 1, "Adding meetings 2..4 must reuse the one aggregate CallKit call")
        XCTAssertEqual(h.endActions().count, 0)
        XCTAssertEqual(h.coordinator.systemCall.callID, callID)
        XCTAssertEqual(h.coordinator.talkSessionID, s1.id)
        XCTAssertEqual(h.titleUpdates().last?.1, "Standup (+3)")
        XCTAssertFalse(s2.inputPermitted)
        XCTAssertFalse(s3.inputPermitted)
        XCTAssertFalse(s4.inputPermitted)

        h.coordinator.unregisterSession(id: s2.id)
        h.coordinator.unregisterSession(id: s3.id)
        h.coordinator.unregisterSession(id: s4.id)
        XCTAssertEqual(h.coordinator.activeSessionCount, 1)
        XCTAssertEqual(h.endActions().count, 0, "Removing non-talk meetings down to 1 keeps aggregate call alive")
        XCTAssertEqual(h.coordinator.talkSessionID, s1.id)

        h.coordinator.unregisterSession(id: s1.id)
        XCTAssertEqual(h.coordinator.activeSessionCount, 0)
        XCTAssertNil(h.coordinator.talkSessionID)
        XCTAssertEqual(h.endActions().count, 1, "Unregistering final session (1 -> 0) ends CallKit call")
    }

    func testTalkHandoverAndCallKitMuteRouteStrictlyToTalkSessionAndToggleCaptureGate() async throws {
        let h = makeHarness()
        defer { h.provider.invalidate(); h.coordinator.systemCall.markEnded(reason: .remoteEnded) }

        let s1 = MockSession(), s2 = MockSession()
        h.coordinator.registerSession(s1, title: "Room A")
        await h.coordinator.waitForAggregateLeaseForTesting()
        let callID = try XCTUnwrap(h.coordinator.systemCall.callID)
        h.coordinator.markSessionConnected(id: s1.id)
        h.setObservedCalls([.init(id: callID, connected: true, held: false)])

        h.coordinator.registerSession(s2, title: "Room B")
        await Task.yield()

        XCTAssertNotEqual(LKRTCApplicationCaptureMuted(), 0, "Fresh workspace starts capture-muted")

        // Unmute via CallKit -> routes to s1 (current talk session).
        let unmute1 = FakeMuteAction(call: callID, muted: false)
        h.coordinator.systemCall.provider(h.provider, perform: unmute1)
        XCTAssertTrue(unmute1.fulfilled)
        for _ in 0..<20 where h.coordinator.isMuted { await Task.yield() }

        XCTAssertFalse(h.coordinator.isMuted)
        XCTAssertTrue(s1.micOn)
        XCTAssertFalse(s2.micOn)
        XCTAssertEqual(LKRTCApplicationCaptureMuted(), 0)

        // One-tap Talk Handover to s2 mutes s1, revokes s1 permit, grants s2 permit, stays muted cleanly.
        await h.coordinator.switchTalk(to: s2.id)
        XCTAssertEqual(h.coordinator.talkSessionID, s2.id)
        XCTAssertTrue(h.coordinator.isMuted)
        XCTAssertNotEqual(LKRTCApplicationCaptureMuted(), 0)
        XCTAssertFalse(s1.micOn)
        XCTAssertFalse(s1.inputPermitted)
        XCTAssertTrue(s2.inputPermitted)
        XCTAssertEqual(h.titleUpdates().last?.1, "Room B (+1)")

        // Now CallKit unmute routes to s2 instead of s1.
        let unmute2 = FakeMuteAction(call: callID, muted: false)
        h.coordinator.systemCall.provider(h.provider, perform: unmute2)
        for _ in 0..<20 where h.coordinator.isMuted { await Task.yield() }
        XCTAssertFalse(h.coordinator.isMuted)
        XCTAssertTrue(s2.micOn)
        XCTAssertFalse(s1.micOn)
        XCTAssertEqual(LKRTCApplicationCaptureMuted(), 0)

        // Synchronous CallKit mute closes capture gate immediately before async session mute completes.
        let muteAction = FakeMuteAction(call: callID, muted: true)
        h.coordinator.systemCall.provider(h.provider, perform: muteAction)
        XCTAssertNotEqual(LKRTCApplicationCaptureMuted(), 0)
        XCTAssertTrue(h.coordinator.isMuted)
        await Task.yield()
        XCTAssertFalse(s2.micOn)
    }

    func testHoldPausesAllSessionsAndUnholdRestoresPlayoutKeepingMicMuted() async throws {
        let h = makeHarness()
        defer { h.provider.invalidate(); h.coordinator.systemCall.markEnded(reason: .remoteEnded) }

        let s1 = MockSession(), s2 = MockSession()
        s2.playoutOn = false // Explicitly muted audio output on room 2 should remain off after hold.
        h.coordinator.registerSession(s1, title: "Talk Room")
        await h.coordinator.waitForAggregateLeaseForTesting()
        let callID = try XCTUnwrap(h.coordinator.systemCall.callID)
        h.coordinator.markSessionConnected(id: s1.id)
        h.setObservedCalls([.init(id: callID, connected: true, held: false)])

        h.coordinator.registerSession(s2, title: "Listen Room")
        try await h.coordinator.setTalkMicrophone(true)
        XCTAssertTrue(s1.micOn)
        XCTAssertEqual(LKRTCApplicationCaptureMuted(), 0)

        h.setObservedCalls([.init(id: callID, connected: true, held: true)])
        let holdAction = FakeHoldAction(call: callID, onHold: true)
        h.coordinator.systemCall.provider(h.provider, perform: holdAction)
        h.coordinator.systemCall.provider(h.provider, didDeactivate: .sharedInstance())
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(h.coordinator.isHeld)
        XCTAssertTrue(h.coordinator.isMuted)
        XCTAssertNotEqual(LKRTCApplicationCaptureMuted(), 0)
        XCTAssertFalse(s1.micOn)
        XCTAssertFalse(s1.playoutOn)
        XCTAssertFalse(s2.playoutOn)

        h.setObservedCalls([.init(id: callID, connected: true, held: false)])
        let unholdAction = FakeHoldAction(call: callID, onHold: false)
        h.coordinator.systemCall.provider(h.provider, perform: unholdAction)
        h.coordinator.systemCall.provider(h.provider, didActivate: .sharedInstance())
        for _ in 0..<20 where !s1.playoutOn { await Task.yield() }

        XCTAssertFalse(h.coordinator.isHeld)
        XCTAssertTrue(s1.playoutOn, "Unhold restores playout on active session")
        XCTAssertFalse(s2.playoutOn, "Unhold respects session that had playout off before hold")
        XCTAssertFalse(s1.micOn, "Microphones remain safely muted after hold/interruption")
        XCTAssertTrue(h.coordinator.isMuted)
    }

    func testSessionJoinWaitsForCallKitAudioActivationReusesActiveLeaseAndPropagatesStartFailure() async throws {
        let h = makeHarness()
        defer { h.provider.invalidate(); h.coordinator.systemCall.markEnded(reason: .remoteEnded) }

        let s1 = MockSession(), s2 = MockSession()
        h.coordinator.registerSession(s1, title: "Gated Room 1")
        var s1Ready = false
        let waitTask = Task {
            try await h.coordinator.waitUntilAudioReady(for: s1.id)
            s1Ready = true
        }
        await h.coordinator.waitForAggregateLeaseForTesting()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(s1Ready, "Session join must wait until CallKit activates AVAudioSession")
        XCTAssertEqual(h.startActions().count, 1)

        h.coordinator.systemCall.provider(h.provider, didActivate: .sharedInstance())
        try await waitTask.value
        XCTAssertTrue(s1Ready)

        // Second session reuses the already active aggregate lease without waiting or starting a second call.
        h.coordinator.registerSession(s2, title: "Gated Room 2")
        try await h.coordinator.waitUntilAudioReady(for: s2.id)
        XCTAssertEqual(h.startActions().count, 1)

        // Failing CallKit start rejects waitUntilAudioReady rather than hanging.
        let expectedError = NSError(domain: "TestCallKit", code: 42)
        let failing = makeHarness(startFailure: expectedError)
        defer { failing.provider.invalidate(); failing.coordinator.systemCall.markEnded(reason: .remoteEnded) }
        let s3 = MockSession()
        failing.coordinator.registerSession(s3, title: "Failing Room")
        do {
            try await failing.coordinator.waitUntilAudioReady(for: s3.id)
            XCTFail("Expected CallKit start failure to propagate")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, expectedError.domain)
            XCTAssertEqual(error.code, expectedError.code)
        }
    }

    func testMuteUsesPrepareLocalAudioMuteIntentInsteadOfSuppressOutgoingMedia() async throws {
        let h = makeHarness()
        defer { h.provider.invalidate(); h.coordinator.systemCall.markEnded(reason: .remoteEnded) }

        let spy = SpyProviderAdapter()
        let session = MeetingSession(kind: .guest, adapter: spy)
        h.coordinator.registerSession(session, title: "Guest Room")
        await h.coordinator.waitForAggregateLeaseForTesting()
        let callID = try XCTUnwrap(h.coordinator.systemCall.callID)
        h.coordinator.markSessionConnected(id: session.id)
        h.setObservedCalls([.init(id: callID, connected: true, held: false)])

        try await h.coordinator.setTalkMicrophone(true, for: session.id)
        XCTAssertTrue(spy.micOn)
        XCTAssertFalse(h.coordinator.isMuted)

        h.coordinator.suppressMicrophoneImmediately(for: session.id)
        XCTAssertTrue(h.coordinator.isMuted)
        XCTAssertNotEqual(LKRTCApplicationCaptureMuted(), 0)
        XCTAssertEqual(spy.prepareLocalMuteCalls.count, 1)
        XCTAssertEqual(spy.prepareLocalMuteCalls.first?.0, true)
        XCTAssertNil(spy.prepareLocalMuteCalls.first?.1)
        XCTAssertEqual(spy.suppressOutgoingMediaCalls, 0, "Mute must never call terminal suppressOutgoingMedia()")

        try await h.coordinator.setTalkMicrophone(false, for: session.id)
        XCTAssertFalse(spy.micOn)
        XCTAssertEqual(spy.suppressOutgoingMediaCalls, 0)

        try await h.coordinator.setTalkMicrophone(true, for: session.id)
        XCTAssertTrue(spy.micOn, "Unmute after mute must succeed cleanly without terminal suppression")
        XCTAssertFalse(h.coordinator.isMuted)
        XCTAssertEqual(spy.suppressOutgoingMediaCalls, 0)
    }
}
