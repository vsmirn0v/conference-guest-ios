import Foundation

// The harness omits WebRTC. This failure identity mirrors GuestPeer's typed ICE
// failure, allowing the production retry classifier to compile without media.
enum GuestPeerError: Error { case iceFailed, closed, malformed }
enum SessionTestError: Error { case assertion(String), denied, evicted, malformed }

@MainActor
private final class Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

@MainActor
private final class FakeEngine: GuestSessionEngine {
    var sessionID: String?
    var onFailure: ((Error) -> Void)?
    var onForcedMute: ((Bool) -> Void)?
    var onPermissionsChange: ((GuestMediaPermissions) -> Void)?
    var mediaPermissions = GuestMediaPermissions(canShareMicrophone: true, canShareCamera: true)
    var microphoneActivations = 0
    var startupEvents: [String] = []
    var playoutChanges: [Bool] = []
    var microphoneActivationGate: Gate?
    var playoutGate: Gate?
    var startupGate: Gate?
    var startupWaits = 0, startupReleases = 0
    var onStartupReady: (() -> Void)?
    func waitForStartupAudio() async throws { startupWaits += 1; await startupGate?.wait(); onStartupReady?() }
    func releaseStartupAudio() -> Bool { startupReleases += 1; return true }
    func activateMicrophone() async throws { startupEvents.append("microphone"); microphoneActivations += 1; await microphoneActivationGate?.wait() }
    func setPlayoutEnabled(_ enabled: Bool) async throws { playoutChanges.append(enabled); await playoutGate?.wait() }
    var assignedSessionID = "server-session"
    var joinError: Error?
    var publishError: Error?
    var muteError: Error?
    var failureDuringJoin: Error?
    var interruptError: Error = GuestTransportError.networkFailure
    var joinGate: Gate?
    var publishGate: Gate?
    var leaveGate: Gate?
    var cleanupResult = true
    var joins: [String?] = []
    var publications: [GuestMediaIntent] = []
    var mutes: [(Bool, Bool)] = []
    var localIntents: [(Bool, Bool)] = []
    var audioMuted = false, videoMuted = false
    var suppressed = false
    var resumedPublication: (Bool, Bool, Bool)?
    var leaves: [Bool] = []
    func join(_ invitation: GuestInvitation, sessionID: String?) async throws {
        startupEvents.append("join")
        joins.append(sessionID)
        self.sessionID = assignedSessionID
        await joinGate?.wait() // Deliberately ignores cancellation, testing stale completion.
        if let failureDuringJoin { onFailure?(failureDuringJoin) }
        if let joinError { throw joinError }
    }
    func publishPattern(codec: String, camera: Bool, audioMuted: Bool, videoMuted: Bool) async throws {
        startupEvents.append("publish")
        publications.append(.init(publish: true, codec: codec, camera: camera, audioMuted: audioMuted, videoMuted: videoMuted))
        await publishGate?.wait()
        resumedPublication = (self.audioMuted, self.videoMuted, suppressed)
        if let publishError { throw publishError }
    }
    func mute(_ muted: Bool, video: Bool) async throws {
        mutes.append((muted, video)); if let muteError { throw muteError }
    }
    func setLocalMuteIntent(_ muted: Bool, video: Bool) {
        localIntents.append((muted, video))
        if video { videoMuted = muted } else { audioMuted = muted }
    }
    func suppressOutgoingMedia() { suppressed = true; audioMuted = true; videoMuted = true }
    func leave(sendLeave: Bool) async -> Bool {
        leaves.append(sendLeave); await leaveGate?.wait(); return cleanupResult
    }
    func interruptTransportForTesting() async { onFailure?(interruptError) }
}

@MainActor
private final class Harness {
    let engines: [FakeEngine]
    var made = 0
    var factoryCalls = 0
    var factoryErrors: [Error] = []
    var delays: [UInt64] = []
    var sleepGate: Gate?
    lazy var session = GuestSession(makeAttempt: { [self] in
        factoryCalls += 1
        if !factoryErrors.isEmpty { throw factoryErrors.removeFirst() }
        guard made < engines.count else { throw SessionTestError.assertion("Unexpected extra attempt") }
        let engine = engines[made]; made += 1; return engine
    }, sleep: { [self] delay in
        delays.append(delay); await sleepGate?.wait(); try Task.checkCancellation()
    })
    init(_ engines: [FakeEngine]) { self.engines = engines }
}

@main
struct SessionTests {
    @MainActor static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw SessionTestError.assertion(message) }
    }
    @MainActor static func spin(_ predicate: () -> Bool) async throws {
        for _ in 0..<20_000 { if predicate() { return }; await Task.yield() }
        throw SessionTestError.assertion("Operation did not reach its deterministic gate")
    }
    @MainActor static func connect(_ session: GuestSession, publish: Bool = true,
                                  audioMuted: Bool = false, videoMuted: Bool = false) async throws {
        try await session.connect(GuestInvitation.parse("https://example.test/calls/test"), publish: publish,
            codec: "h264", camera: true, initialAudioMuted: audioMuted, initialVideoMuted: videoMuted)
    }
    @MainActor static func expectConnectFailure(_ session: GuestSession) async throws {
        do { try await connect(session); throw SessionTestError.assertion("Connect unexpectedly succeeded") }
        catch SessionTestError.assertion(let message) { throw SessionTestError.assertion(message) }
        catch {}
    }

    @MainActor static func policy() throws {
        let recoverable: [Error] = [GuestTransportError.networkFailure, GuestTransportError.closed,
            GuestTransportError.timedOut, GuestPeerError.iceFailed,
            URLError(.timedOut), URLError(.cannotFindHost), URLError(.cannotConnectToHost),
            URLError(.dnsLookupFailed), URLError(.networkConnectionLost), URLError(.notConnectedToInternet)]
        for error in recoverable {
            var policy = GuestRecoveryPolicy()
            try expect(policy.nextDelay(after: error) == 500_000_000, "First bounded retry")
            try expect(policy.nextDelay(after: error) == 1_000_000_000, "Second bounded retry")
            try expect(policy.nextDelay(after: error) == 2_000_000_000, "Third bounded retry")
            try expect(policy.nextDelay(after: error) == nil && policy.retries == 3, "Retry budget exhausted")
        }
        let terminal: [Error] = [GuestTransportError.invalidURL, GuestTransportError.notConnected,
            GuestTransportError.alreadyConnecting, GuestTransportError.invalidEnvelope,
            GuestTransportError.queueOverflow, GuestTransportError.frameTooLarge,
            GuestTransportError.server(code: "DENIED"), GuestPeerError.closed, GuestPeerError.malformed,
            GuestBootstrapError.invalidInvitation, SessionTestError.denied, SessionTestError.evicted,
            SessionTestError.malformed, CancellationError(), URLError(.cancelled), URLError(.secureConnectionFailed),
            URLError(.serverCertificateUntrusted), URLError(.userAuthenticationRequired),
            URLError(.internationalRoamingOff), URLError(.dataNotAllowed)]
        for error in terminal {
            var policy = GuestRecoveryPolicy()
            try expect(policy.nextDelay(after: error) == nil && policy.retries == 0, "Terminal failures never retry")
        }
    }

    @MainActor static func normalAndIdempotentLeave() async throws {
        let engine = FakeEngine()
        let session = GuestSession(makeAttempt: { engine })
        try await connect(session, publish: false)
        try expect(engine.joins.count == 1 && engine.joins[0] == nil, "First join has no previous session")
        try expect(engine.publications.isEmpty && session.state == .connected, "Receiver does not publish")
        let first = await session.leave(), second = await session.leave()
        try expect(first && second && engine.leaves == [true], "One acknowledged user leave")
    }

    @MainActor static func recoveryPreservesSessionAndInitialMute() async throws {
        let first = FakeEngine(), second = FakeEngine()
        first.assignedSessionID = "original-server-session"; second.assignedSessionID = "replacement-server-session"
        let harness = Harness([first, second]), session = harness.session
        try await connect(session, audioMuted: true, videoMuted: true)
        try await session.reconnectForTesting()
        try expect(harness.made == 2 && harness.delays == [500_000_000], "Fresh engine after socket failure")
        try expect(first.leaves == [false], "Recovery must not send server leave")
        try expect(second.joins[0] == first.assignedSessionID, "Rejoin uses server-issued participant session")
        try expect(session.sessionID == second.assignedSessionID, "Replacement server session is remembered")
        try expect(second.publications.first?.audioMuted == true && second.publications.first?.videoMuted == true,
                   "New publications begin muted without an unmuted window")
        try expect(second.mutes.isEmpty, "Initial mute is not repaired after publication")
        _ = await session.leave(); try expect(second.leaves == [true], "Final engine sends user leave")
    }

    @MainActor static func closeHandshakeSendRace() async throws {
        let transport = GuestTransport(url: URL(string: "wss://fixture.invalid/socket")!, roomID: "fixture")
        do {
            try await transport.notify("media-in")
            throw SessionTestError.assertion("Idle transport accepted a send")
        } catch GuestTransportError.notConnected {
            try expect(!GuestRecoveryPolicy.isRecoverable(GuestTransportError.notConnected),
                       "Programming errors before connection remain terminal")
        }
        await transport.openWithoutSocketForTesting()
        let closing = Task { await transport.close() }
        var reachedClosing = false
        for _ in 0..<20_000 {
            if await transport.isClosingForTesting { reachedClosing = true; break }
            await Task.yield()
        }
        try expect(reachedClosing, "Actual close() reached its handshake suspension")
        // These are real public transport calls queued concurrently during the
        // handshake, without creating a socket or weakening TLS/network policy.
        let sends = (0..<3).map { operation in
            Task { () -> GuestTransportError? in
                do {
                    switch operation {
                    case 0: try await transport.notify("media-in", payload: ["method": "rtc:ping"])
                    case 1: try await transport.notify("media-in", payload: ["method": "rtc:ice"])
                    default: _ = try await transport.request("leave")
                    }
                } catch let error as GuestTransportError { return error }
                catch { return nil }
                return nil
            }
        }
        var observedError: GuestTransportError?
        for send in sends {
            let error = await send.value
            guard case .closed? = error else {
                await transport.finishCloseForTesting(); await closing.value
                throw SessionTestError.assertion("Send during close reported a terminal notConnected error")
            }
            observedError = error
        }
        let first = FakeEngine(), second = FakeEngine()
        first.interruptError = observedError!
        let harness = Harness([first, second]), session = harness.session
        try await connect(session, audioMuted: true, videoMuted: true)
        try await session.reconnectForTesting()
        try expect(session.state == .connected && session.connectionCount == 2 && session.recoveryAttempts == 1,
                   "A send rejected by the closing transport enters the existing bounded recovery")
        try expect(first.leaves == [false] && second.publications.first?.audioMuted == true &&
                   second.publications.first?.videoMuted == true,
                   "Recovery retires once and retains muted publication intent")
        await transport.finishCloseForTesting(); await closing.value
        let staleFailure = second.onFailure
        _ = await session.leave()
        staleFailure?(GuestTransportError.closed)
        try expect(session.state == .left && harness.made == 2 && second.leaves == [true],
                   "An intentional leave ignores later closed callbacks and cannot reconnect")
    }

    @MainActor static func latestMuteDuringBackoff() async throws {
        let first = FakeEngine(), second = FakeEngine()
        let harness = Harness([first, second]), gate = Gate()
        harness.sleepGate = gate
        let session = harness.session
        try await connect(session, audioMuted: true)
        first.onFailure?(GuestTransportError.networkFailure)
        try await spin { harness.delays.count == 1 }
        let change = Task { try await session.mute(false) }
        try await spin { session.desiredIntent?.audioMuted == false }
        try expect(harness.made == 1, "Backoff prevents a concurrent replacement")
        gate.release(); try await change.value
        try expect(second.publications.first?.audioMuted == false, "Newest mute intent wins during recovery")
        try expect(first.mutes.isEmpty, "Retired sender gets no new commands")
        _ = await session.leave()
    }

    @MainActor static func muteWhilePublishing() async throws {
        let engine = FakeEngine(), gate = Gate()
        engine.publishGate = gate
        let h = Harness([engine]), session = h.session
        let connection = Task { try await connect(session) }
        try await spin { engine.publications.count == 1 }
        let change = Task { try await session.mute(true) }
        try await spin { session.desiredIntent?.audioMuted == true }
        try expect(engine.audioMuted && engine.publications.count == 1,
                   "Local mute is synchronous while publication remains suspended")
        gate.release(); try await connection.value; try await change.value
        try expect(h.made == 1 && engine.mutes.count == 1 && engine.mutes[0].0 && !engine.mutes[0].1,
                   "Startup reconciles a newer mute on the same control job")
        try expect(session.connectionCount == 1, "Mute reconciliation is not another connection")
        _ = await session.leave()
    }

    @MainActor static func staleCallbacksAndForcedMute() async throws {
        let first = FakeEngine(), second = FakeEngine()
        let harness = Harness([first, second]), session = harness.session
        try await connect(session)
        let staleFailure = first.onFailure, staleMute = first.onForcedMute
        first.onForcedMute?(false); first.onForcedMute?(true)
        try await spin { first.mutes.count == 2 }
        try await session.reconnectForTesting()
        try expect(second.publications.first?.audioMuted == true && second.publications.first?.videoMuted == true,
                   "Server-forced mute remains desired across reconnect")
        try await session.mute(false); try await session.mute(false, video: true)
        staleFailure?(SessionTestError.evicted); staleMute?(false); staleMute?(true)
        try expect(session.state == .connected && session.failure == nil && harness.made == 2,
                   "Old callbacks cannot fail a replacement attempt")
        try expect(session.desiredIntent?.audioMuted == false && session.desiredIntent?.videoMuted == false,
                   "Old forced mute cannot change new intent")
        _ = await session.leave()
    }

    @MainActor static func terminalFailuresNeverRetry() async throws {
        for error in [SessionTestError.denied, .evicted, .malformed] {
            let engine = FakeEngine(); engine.joinError = error
            let h = Harness([engine]), session = h.session
            try await expectConnectFailure(session)
            try expect(h.made == 1 && h.delays.isEmpty && session.state == .failed,
                       "Admission/eviction/protocol failure is terminal")
            try expect(engine.publications.isEmpty && engine.leaves == [true], "Terminal attempt sends server leave")
            _ = await session.leave()
        }
    }

    @MainActor static func exhaustedRetriesAndCleanupFailure() async throws {
        let engines = (0..<4).map { _ in FakeEngine() }
        for engine in engines { engine.joinError = GuestTransportError.networkFailure }
        let h = Harness(engines), session = h.session
        try await expectConnectFailure(session)
        try expect(h.made == 4 && session.recoveryAttempts == 3 && h.delays == [500_000_000, 1_000_000_000, 2_000_000_000],
                   "Initial attempt plus exactly three automatic retries")
        try expect(engines.prefix(3).allSatisfy { $0.leaves == [false] } && engines.last?.leaves == [true],
                   "Only scheduled retries omit server leave; exhausted attempt leaves")
        _ = await session.leave()

        let broken = FakeEngine(); broken.joinError = GuestTransportError.networkFailure; broken.cleanupResult = false
        let unsafe = Harness([broken]), stopped = unsafe.session
        try await expectConnectFailure(stopped)
        try expect(unsafe.made == 1 && unsafe.delays.isEmpty && stopped.failure is GuestSessionError,
                   "Unproven cleanup blocks a second media owner")
        let stoppedCleanly = await stopped.leave()
        try expect(!stoppedCleanly, "Cleanup failure reaches final leave result")
    }

    @MainActor static func leaveDuringJoin() async throws {
        let engine = FakeEngine(), gate = Gate(); engine.joinGate = gate
        let h = Harness([engine]), session = h.session
        let connection = Task { try await connect(session) }
        try await spin { engine.joins.count == 1 }
        let leave = Task { await session.leave() }
        try await spin { session.state == .left }
        gate.release()
        do { try await connection.value; throw SessionTestError.assertion("Stale join connected") }
        catch is CancellationError {}
        let stopped = await leave.value
        try expect(stopped, "Leave waits for stale join cleanup")
        try expect(engine.publications.isEmpty && engine.leaves == [true], "Stale join cannot start publication")
    }

    @MainActor static func leaveDuringFactoryAndBackoff() async throws {
        let engine = FakeEngine(), factoryGate = Gate()
        var factoryStarted = false
        let session = GuestSession(makeAttempt: { factoryStarted = true; await factoryGate.wait(); return engine })
        let connection = Task { try await connect(session) }
        try await spin { factoryStarted }
        let leave = Task { await session.leave() }
        try await spin { session.state == .left }
        factoryGate.release()
        do { try await connection.value; throw SessionTestError.assertion("Stale factory connected") }
        catch is CancellationError {}
        let stopped = await leave.value
        try expect(stopped, "Leave drains a late factory result")
        try expect(engine.joins.isEmpty && engine.leaves == [false], "Late factory engine never joins")

        let first = FakeEngine(); first.joinError = GuestTransportError.networkFailure
        let h = Harness([first, FakeEngine()]), gate = Gate(); h.sleepGate = gate
        let recovery = h.session, connectTask = Task { try await connect(h.session) }
        try await spin { h.delays.count == 1 }
        let leaving = Task { await recovery.leave() }
        try await spin { recovery.state == .left }
        gate.release()
        do { try await connectTask.value; throw SessionTestError.assertion("Backoff revived") }
        catch is CancellationError {}
        let recoveredStopped = await leaving.value
        try expect(recoveredStopped, "Leave joins canceled backoff")
        try expect(h.made == 1 && first.leaves == [false], "Canceled retry never acquires another engine")
    }

    @MainActor static func concurrentLeaveAndJoinFailureCallback() async throws {
        let engine = FakeEngine(), gate = Gate(); engine.leaveGate = gate
        let h = Harness([engine]), session = h.session
        try await connect(session)
        let first = Task { await session.leave() }
        try await spin { engine.leaves.count == 1 }
        let second = Task { await session.leave() }
        await Task.yield(); gate.release()
        let firstStopped = await first.value, secondStopped = await second.value
        try expect(firstStopped && secondStopped, "Concurrent leave callers share cleanup")
        try expect(engine.leaves == [true], "Concurrent leave invokes engine once")

        let failing = FakeEngine(), replacement = FakeEngine(); failing.failureDuringJoin = GuestTransportError.networkFailure
        let retry = Harness([failing, replacement]), resumed = retry.session
        try await connect(resumed)
        try expect(failing.publications.isEmpty && failing.leaves == [false], "Failure callback wins over late successful join")
        try expect(replacement.joins.first! == failing.assignedSessionID, "Session identity survives a failed joined attempt")
        _ = await resumed.leave()
    }

    @MainActor static func leaveDuringPublishAndCallerCancellation() async throws {
        let engine = FakeEngine(), gate = Gate(); engine.publishGate = gate
        let h = Harness([engine]), session = h.session
        let connection = Task { try await connect(session) }
        try await spin { engine.publications.count == 1 }
        let leaving = Task { await session.leave() }
        try await spin { session.state == .left }
        try expect(engine.suppressed && engine.audioMuted && engine.videoMuted && engine.leaves.isEmpty,
                   "Leave suppresses outgoing media before awaiting suspended publication")
        gate.release()
        do { try await connection.value; throw SessionTestError.assertion("Canceled publication connected") }
        catch is CancellationError {}
        let stopped = await leaving.value
        try expect(stopped && engine.leaves == [true] && engine.mutes.isEmpty,
                   "Leave drains publication and prevents later intent reconciliation")
        try expect(engine.resumedPublication?.2 == true, "Late publication cannot undo leave suppression")

        let pending = FakeEngine(), joinGate = Gate(); pending.joinGate = joinGate
        let pendingHarness = Harness([pending]), canceled = pendingHarness.session
        let connecting = Task { try await connect(canceled) }
        try await spin { pending.joins.count == 1 }
        connecting.cancel()
        try await spin { canceled.state == .left }
        joinGate.release()
        do { try await connecting.value; throw SessionTestError.assertion("Canceled caller connected") }
        catch is CancellationError {}
        let canceledStopped = await canceled.leave()
        try expect(canceledStopped && pending.leaves == [true] && pending.publications.isEmpty,
                   "Canceling the connecting caller drains its attempt")
    }

    @MainActor static func successfulRejoinDoesNotRefillBudget() async throws {
        let engines = (0..<4).map { _ in FakeEngine() }
        let harness = Harness(engines), session = harness.session
        try await connect(session)
        for _ in 0..<3 { try await session.reconnectForTesting() }
        do { try await session.reconnectForTesting(); throw SessionTestError.assertion("Recovery budget refilled") }
        catch GuestTransportError.networkFailure {}
        try expect(harness.made == 4 && session.recoveryAttempts == 3 && session.state == .failed,
                   "Signaling readiness does not refill automatic recovery budget")
        _ = await session.leave()
    }

    @MainActor static func muteFailureRestoresLatestIntent() async throws {
        let first = FakeEngine(), second = FakeEngine()
        first.muteError = GuestTransportError.networkFailure
        let harness = Harness([first, second]), session = harness.session
        try await connect(session)
        try await session.mute(true, video: true)
        try expect(first.leaves == [false] && second.publications.first?.videoMuted == true,
                   "A failed mute recovers using the desired muted publication")
        try expect(session.connectionCount == 2, "Mute-triggered recovery creates one replacement")
        _ = await session.leave()
    }

    @MainActor static func forcedMuteDuringPublication() async throws {
        let first = FakeEngine(), second = FakeEngine(), gate = Gate(); first.publishGate = gate
        let harness = Harness([first, second]), session = harness.session
        let connecting = Task { try await connect(session) }
        try await spin { first.publications.count == 1 }
        first.onForcedMute?(false); first.onForcedMute?(true)
        gate.release(); try await connecting.value
        try expect(first.mutes.count == 2 && first.mutes.allSatisfy { $0.0 },
                   "Forced mute during startup wins over initial publication intent")
        try await session.reconnectForTesting()
        try expect(second.publications.first?.audioMuted == true && second.publications.first?.videoMuted == true,
                   "Forced startup mute is restored on replacement publication")
        _ = await session.leave()
    }

    @MainActor static func explicitConnectStartsFreshAfterLeave() async throws {
        let first = FakeEngine(), second = FakeEngine()
        let harness = Harness([first, second]), session = harness.session
        try await connect(session, audioMuted: true)
        _ = await session.leave()
        try await connect(session, publish: false)
        try expect(second.joins.count == 1 && second.joins[0] == nil,
                   "Explicit new connection does not reuse a left participant session")
        try expect(second.publications.isEmpty && session.recoveryAttempts == 0,
                   "New receiver intent and retry budget replace the old session")
        _ = await session.leave()
    }

    @MainActor static func bootstrapNetworkFailures() async throws {
        let engine = FakeEngine(), factory = Harness([FakeEngine()])
        let created = Harness([engine]); created.factoryErrors = [URLError(.notConnectedToInternet)]
        try await connect(created.session)
        try expect(created.factoryCalls == 2 && created.made == 1 && created.delays == [500_000_000],
                   "Offline bootstrap factory failure retries with fresh construction")
        _ = await created.session.leave()
        let first = FakeEngine(), replacement = FakeEngine(); first.joinError = URLError(.dnsLookupFailed)
        let joining = Harness([first, replacement])
        try await connect(joining.session)
        try expect(joining.made == 2 && first.leaves == [false] && joining.delays == [500_000_000],
                   "URLSession bootstrap failure inside join recovers")
        _ = await joining.session.leave()
        let exhausted = Harness([])
        exhausted.factoryErrors = (0..<4).map { _ in URLError(.networkConnectionLost) }
        try await expectConnectFailure(exhausted.session)
        try expect(exhausted.factoryCalls == 4 && exhausted.made == 0 && exhausted.session.recoveryAttempts == 3,
                   "Bootstrap URL errors share the finite three-retry budget")
        _ = await exhausted.session.leave()
        factory.factoryErrors = [URLError(.secureConnectionFailed)]
        try await expectConnectFailure(factory.session)
        try expect(factory.factoryCalls == 1 && factory.delays.isEmpty, "TLS bootstrap failure is terminal")
        _ = await factory.session.leave()
    }

    @MainActor static func synchronousUnmuteIntentDuringPublication() async throws {
        let engine = FakeEngine(), gate = Gate(); engine.publishGate = gate
        let harness = Harness([engine]), session = harness.session
        let connecting = Task { try await connect(session, audioMuted: true) }
        try await spin { engine.publications.count == 1 }
        let unmuting = Task { try await session.mute(false) }
        try await spin { session.desiredIntent?.audioMuted == false }
        try expect(!engine.audioMuted && engine.localIntents.last?.0 == false && engine.localIntents.last?.1 == false,
                   "Unmute intent reaches the engine synchronously during suspended publish")
        gate.release(); try await connecting.value; try await unmuting.value
        try expect(engine.resumedPublication?.0 == false, "Publisher resumes with the latest local intent")
        try await session.mute(true)
        try expect(session.connectionCount == 1, "Connected mute operations do not increment connections")
        _ = await session.leave()
    }

    @MainActor static func deviceIntentAndSnapshots() async throws {
        let first = FakeEngine(), replacement = FakeEngine(), harness = Harness([first, replacement])
        let session = harness.session
        var snapshots: [GuestSessionSnapshot] = []
        session.onStateChange = { snapshots.append($0) }
        try expect(snapshots.last?.state == .idle, "Observer immediately receives current state")
        try await connect(session, audioMuted: true, videoMuted: true)
        try expect(first.microphoneActivations == 0 && first.playoutChanges.isEmpty,
                   "Muted join does not implicitly activate microphone or change diagnostics output")
        try expect(session.snapshot.appliedIntent?.audioMuted == true && session.snapshot.permissions.canShareCamera,
                   "Snapshot exposes applied mute and room media permissions")
        let stalePermissions = first.onPermissionsChange
        try await session.activateMicrophone()
        try expect(first.microphoneActivations == 1 && first.audioMuted && session.snapshot.microphoneActivated,
                   "Explicit authorized activation leaves microphone muted")
        try await session.setPlayoutEnabled(false)
        try await session.reconnectForTesting()
        try expect(replacement.microphoneActivations == 1 && replacement.playoutChanges == [false],
                   "Microphone activation and owner output intent survive replacement")
        try expect(session.snapshot.desiredPlayoutEnabled == false && session.snapshot.appliedPlayoutEnabled == false,
                   "Snapshot separates desired and applied playout")
        let count = snapshots.count
        stalePermissions?(.init())
        try expect(snapshots.count == count, "Retired permission callback cannot update current UI")
        replacement.mediaPermissions.canShareCamera = false
        replacement.onPermissionsChange?(replacement.mediaPermissions)
        try expect(!session.snapshot.permissions.canShareCamera && snapshots.count == count + 1,
                   "Current room permission callback refreshes UI")
        try await session.mute(false)
        try expect(session.snapshot.desiredIntent?.audioMuted == false && session.snapshot.appliedIntent?.audioMuted == false,
                   "Snapshot distinguishes desired and confirmed media state")
        try await session.setPlayoutEnabled(true)
        try expect(replacement.playoutChanges == [false, true], "Explicit Sound action enables output")
        _ = await session.leave()
        try expect(snapshots.last?.state == .left && snapshots.last?.appliedIntent == nil &&
                   snapshots.last?.microphoneActivated == false, "Leave clears retired engine UI state")
    }

    @MainActor static func initialPreparationPrecedesTransportAndPublication() async throws {
        for prepared in [false, true] {
            let engine = FakeEngine(), session = GuestSession(makeAttempt: { engine })
            try await session.connect(GuestInvitation.parse("https://example.test/calls/test"), publish: true,
                codec: "h264", camera: true, initialAudioMuted: true, initialVideoMuted: true,
                initialMicrophonePreparation: prepared)
            try expect(engine.startupEvents == (prepared ? ["microphone", "join", "publish"] : ["join", "publish"]),
                "Initial muted preparation finishes before transport and publication start")
            try expect(engine.audioMuted && engine.videoMuted && session.snapshot.microphoneActivated == prepared,
                "Prejoin preparation never unmutes either publication")
            _ = await session.leave()
        }
    }

    @MainActor static func powerWithdrawalDuringInitialOwnerCreationSkipsPreparation() async throws {
        let engine = FakeEngine(), gate = Gate()
        var making = false, allowed = true
        var session: GuestSession!
        session = GuestSession(makeAttempt: {
            making = true; await gate.wait()
            session.setMicrophonePreparationRequested(allowed)
            return engine
        })
        let connecting = Task {
            try await session.connect(GuestInvitation.parse("https://example.test/calls/test"), publish: true,
                codec: "h264", camera: true, initialAudioMuted: true, initialVideoMuted: true,
                initialMicrophonePreparation: true)
        }
        try await spin { making }
        allowed = false; session.setMicrophonePreparationRequested(false); gate.release()
        try await connecting.value
        try expect(engine.startupEvents == ["join", "publish"] && !session.snapshot.microphoneActivated,
            "Actual policy after owner creation overrides stale initial eligibility before activation")
        _ = await session.leave()
    }

    @MainActor static func preparationOptInDuringJoinWaitsForNextAttempt() async throws {
        let first = FakeEngine(), replacement = FakeEngine(), gate = Gate()
        first.joinGate = gate
        let harness = Harness([first, replacement]), session = harness.session
        let connecting = Task {
            try await session.connect(GuestInvitation.parse("https://example.test/calls/test"), publish: true,
                codec: "h264", camera: true, initialAudioMuted: true, initialVideoMuted: true)
        }
        try await spin { first.joins.count == 1 }
        session.setMicrophonePreparationRequested(true)
        gate.release(); try await connecting.value
        try expect(first.microphoneActivations == 0 && !session.snapshot.microphoneActivated,
            "Power becoming eligible during join cannot activate input after the prejoin decision")
        try await session.reconnectForTesting()
        try expect(replacement.startupEvents == ["microphone", "join", "publish"],
            "A policy opt-in applies before transport on the next attempt")
        _ = await session.leave()
    }

    @MainActor static func leaveDrainsInitialPreparationBeforeAnyTransportJoin() async throws {
        let engine = FakeEngine(), gate = Gate(), session = GuestSession(makeAttempt: { engine })
        engine.microphoneActivationGate = gate
        let connecting = Task {
            try await session.connect(GuestInvitation.parse("https://example.test/calls/test"), publish: true,
                codec: "h264", camera: true, initialAudioMuted: true, initialVideoMuted: true,
                initialMicrophonePreparation: true)
        }
        try await spin { engine.microphoneActivations == 1 }
        session.setMicrophonePreparationRequested(false)
        try expect(engine.leaves.isEmpty && engine.joins.isEmpty,
            "Power withdrawal does not tear down an in-flight activation")
        let leaving = Task { await session.leave() }
        try await spin { session.state == .left }
        try expect(engine.leaves.isEmpty, "Leave waits for independent activation to return")
        gate.release()
        let stopped = await leaving.value
        try expect(stopped && engine.joins.isEmpty && engine.publications.isEmpty && engine.leaves.count == 1,
            "Canceled prejoin activation drains without opening transport or publishing")
        do { try await connecting.value; throw SessionTestError.assertion("Canceled prejoin startup succeeded") }
        catch is CancellationError {}
    }

    @MainActor static func connectingWaitsForStartupAndLatestSoundIntent() async throws {
        let engine = FakeEngine(), gate = Gate(), session = GuestSession(makeAttempt: { engine })
        engine.startupGate = gate
        var connectedAfterRelease = false
        session.onStateChange = { if $0.state == .connected { connectedAfterRelease = engine.startupReleases == 1 } }
        let connecting = Task { try await connect(session, audioMuted: true, videoMuted: true) }
        try await spin { engine.startupWaits == 1 }
        try expect(session.state == .connecting && engine.publications.count == 1 && engine.startupReleases == 0,
            "Normal media demand starts while Connecting and gain stays gated")
        let sound = Task { try await session.setPlayoutEnabled(false) }
        try await spin { session.snapshot.desiredPlayoutEnabled == false }
        gate.release(); try await connecting.value; try await sound.value
        try expect(engine.playoutChanges == [false] && connectedAfterRelease,
            "Latest Sound intent reconciles before synchronous gain-release/Connected notification")
        _ = await session.leave()
    }

    @MainActor static func staleStartupReadinessCannotReleaseGain() async throws {
        let engine = FakeEngine(), gate = Gate(), session = GuestSession(makeAttempt: { engine })
        engine.startupGate = gate
        let connecting = Task { try await connect(session, audioMuted: true, videoMuted: true) }
        try await spin { engine.startupWaits == 1 }
        engine.onStartupReady = { engine.onFailure?(SessionTestError.evicted) }
        gate.release()
        do { try await connecting.value; throw SessionTestError.assertion("Failed startup became connected") }
        catch SessionTestError.evicted {}
        try expect(engine.startupReleases == 0 && engine.leaves.count == 1,
            "A failure between graph readiness and release retires without opening gain")
        _ = await session.leave()
    }

    @MainActor static func preparedMediaButtonsKeepAudioAndPublication() async throws {
        let engine = FakeEngine(), session = GuestSession(makeAttempt: { engine })
        try await connect(session, audioMuted: true, videoMuted: true)
        try await session.prepareMicrophone()
        for _ in 0..<3 {
            try await session.activateMicrophone()
            try await session.mute(false)
            try await session.mute(true)
            try await session.mute(false, video: true)
            try await session.mute(true, video: true)
        }
        try expect(engine.microphoneActivations == 1 && session.snapshot.microphoneActivated,
            "Ordinary mic and camera buttons retain ready capture without repeated availability changes")
        try expect(engine.publications.count == 1 && engine.publications.first?.codec == "h264" &&
            engine.playoutChanges.isEmpty && engine.leaves.isEmpty && session.connectionCount == 1,
            "Media buttons do not republish codecs, change output, or replace the audio/transport owner")
        try expect(engine.mutes.count == 12 && engine.audioMuted && engine.videoMuted,
            "Each button reconciles only its publication mute intent")
        _ = await session.leave()
    }

    @MainActor static func preparationRecoveryPreservesExplicitActivation() async throws {
        for prepared in [false, true] {
            for explicitlyActivated in [false, true] {
                for recoveryAllowed in [false, true] {
                    let first = FakeEngine(), replacement = FakeEngine(), harness = Harness([first, replacement])
                    let session = harness.session
                    try await connect(session, audioMuted: true, videoMuted: true)
                    if prepared { try await session.prepareMicrophone() }
                    if explicitlyActivated { try await session.activateMicrophone() }
                    let previousActivations = first.microphoneActivations
                    session.setMicrophonePreparationRequested(false)
                    try expect(first.microphoneActivations == previousActivations &&
                        session.snapshot.microphoneActivated == (prepared || explicitlyActivated),
                        "Withdrawing readiness never tears down or rebuilds the current microphone")
                    session.onStateChange = { [weak session] state in
                        if state.state == .recovering { session?.setMicrophonePreparationRequested(recoveryAllowed) }
                    }
                    try await session.reconnectForTesting()
                    try expect(replacement.microphoneActivations == (recoveryAllowed || explicitlyActivated ? 1 : 0),
                        "Replacement obeys the current preparation policy and preserves actual user activation")
                    try expect(replacement.audioMuted && session.desiredIntent?.audioMuted == true,
                        "Preparation policy never unmutes on recovery")
                    _ = await session.leave()
                }
            }
        }
    }

    @MainActor static func mediaIntentDuringDeviceReconciliation() async throws {
        for video in [false, true] {
            let engine = FakeEngine(), gate = Gate(), session = GuestSession(makeAttempt: { engine })
            try await connect(session, audioMuted: false, videoMuted: true)
            if video { engine.playoutGate = gate } else { engine.microphoneActivationGate = gate }
            let device = Task {
                if video { try await session.setPlayoutEnabled(false) }
                else { try await session.activateMicrophone() }
            }
            try await spin { video ? !engine.playoutChanges.isEmpty : engine.microphoneActivations == 1 }
            let muted = !video
            session.setLocalMuteIntent(muted, video: video)
            try expect((video ? engine.videoMuted : engine.audioMuted) == muted,
                       "Synchronous owner intent reaches the engine during suspended activation/output work")
            try expect((video ? session.appliedIntent?.videoMuted : session.appliedIntent?.audioMuted) != muted,
                       "Fixture changes media intent after the first media reconciliation")
            gate.release(); try await device.value
            try expect((video ? session.appliedIntent?.videoMuted : session.appliedIntent?.audioMuted) == muted,
                       "A late media intent is reconciled before the device control job completes")
            try expect(engine.mutes.last?.0 == muted && engine.mutes.last?.1 == video,
                       "The newer intent reaches authoritative engine mute reconciliation")
            _ = await session.leave()
        }
    }

    @MainActor static func main() async {
        do {
            try policy()
            try await normalAndIdempotentLeave()
            try await recoveryPreservesSessionAndInitialMute()
            try await closeHandshakeSendRace()
            try await latestMuteDuringBackoff()
            try await muteWhilePublishing()
            try await staleCallbacksAndForcedMute()
            try await terminalFailuresNeverRetry()
            try await exhaustedRetriesAndCleanupFailure()
            try await leaveDuringJoin()
            try await leaveDuringFactoryAndBackoff()
            try await concurrentLeaveAndJoinFailureCallback()
            try await leaveDuringPublishAndCallerCancellation()
            try await successfulRejoinDoesNotRefillBudget()
            try await muteFailureRestoresLatestIntent()
            try await forcedMuteDuringPublication()
            try await explicitConnectStartsFreshAfterLeave()
            try await bootstrapNetworkFailures()
            try await synchronousUnmuteIntentDuringPublication()
            try await deviceIntentAndSnapshots()
            try await initialPreparationPrecedesTransportAndPublication()
            try await powerWithdrawalDuringInitialOwnerCreationSkipsPreparation()
            try await preparationOptInDuringJoinWaitsForNextAttempt()
            try await connectingWaitsForStartupAndLatestSoundIntent()
            try await staleStartupReadinessCannotReleaseGain()
            try await leaveDrainsInitialPreparationBeforeAnyTransportJoin()
            try await preparedMediaButtonsKeepAudioAndPublication()
            try await preparationRecoveryPreservesExplicitActivation()
            try await mediaIntentDuringDeviceReconciliation()
            print("GuestSession: 29 deterministic policy/lifecycle scenarios passed (including startup gating and 8 preparation recovery combinations)")
        } catch {
            print("GuestSession failed: \(error)")
            exit(1)
        }
    }
}
