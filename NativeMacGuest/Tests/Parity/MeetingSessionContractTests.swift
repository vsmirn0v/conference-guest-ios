import AVFoundation
import ConferenceCore
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

@MainActor final class MeetingSessionContractTests: XCTestCase {
    func testCapabilityMatrixSeparatesVoiceReplyFromAutonomousParticipationAndUnavailableFeatures() {
        let guestLocked = MeetingSessionCapabilities.guest()
        XCTAssertFalse(guestLocked.supportsChatRead)
        XCTAssertFalse(guestLocked.supportsChatSend)
        XCTAssertFalse(guestLocked.supportsAutonomousParticipation)
        XCTAssertTrue(guestLocked.supportsVoiceReply)
        XCTAssertTrue(guestLocked.supportsParticipantVolume)
        XCTAssertTrue(guestLocked.supportsScreenOnlyVideo)
        XCTAssertTrue(guestLocked.supportsIndependentCameraAndShare)

        let guestFull = MeetingSessionCapabilities.guest(
            canViewChat: true, canSendChat: true, canReact: true,
            canViewTranscript: true, canManageTranscript: true,
            supportsAutonomousParticipation: true, supportsScreenShareVP9: true
        )
        XCTAssertTrue(guestFull.supportsChatSend)
        XCTAssertTrue(guestFull.supportsAutonomousParticipation)
        XCTAssertTrue(guestFull.supportsScreenShareVP9)

        let telemost = MeetingSessionCapabilities.telemost
        XCTAssertTrue(telemost.supportsChatRead)
        XCTAssertFalse(telemost.supportsChatSend)
        XCTAssertTrue(telemost.supportsVoiceReply)
        XCTAssertFalse(telemost.supportsAutonomousParticipation)
        XCTAssertFalse(telemost.supportsParticipantVolume)
        XCTAssertTrue(telemost.supportsScreenOnlyVideo)
        XCTAssertTrue(telemost.supportsIndependentCameraAndShare)

        let trueconf = MeetingSessionCapabilities.trueconf
        XCTAssertFalse(trueconf.supportsChatRead)
        XCTAssertFalse(trueconf.supportsChatSend)
        XCTAssertTrue(trueconf.supportsVoiceReply)
        XCTAssertFalse(trueconf.supportsAutonomousParticipation)
        XCTAssertFalse(trueconf.supportsParticipantVolume)
        XCTAssertFalse(trueconf.supportsScreenOnlyVideo)
        XCTAssertFalse(trueconf.supportsIndependentCameraAndShare)

        let rock = MeetingSessionCapabilities.rock(supportsMicrophone: true)
        XCTAssertTrue(rock.supportsChatRead)
        XCTAssertTrue(rock.supportsChatSend)
        XCTAssertTrue(rock.supportsApprovedChatCorrelation)
        XCTAssertFalse(rock.supportsReactions)
        XCTAssertTrue(rock.supportsVoiceReply)
        XCTAssertFalse(rock.supportsAutonomousParticipation)
        XCTAssertTrue(rock.supportsParticipantVolume)
        XCTAssertTrue(rock.supportsScreenOnlyVideo)
        XCTAssertFalse(MeetingSessionCapabilities.rock(supportsMicrophone: false).supportsVoiceReply)
    }

    func testConnectionGenerationCommandRevisionAndUnavailableFeatureOutcomes() async throws {
        let initial = ConnectionGeneration()
        let next = initial.next()
        XCTAssertNotEqual(initial.id, next.id)
        XCTAssertEqual(next.epoch, initial.epoch + 1)

        var revision = CommandRevision()
        let first = revision.advance()
        let second = revision.advance()
        XCTAssertLessThan(first, second)

        let sessionID = UUID()
        let idA = MeetingConnectionIdentity(sessionID: sessionID, provider: .guest, generation: initial.id, providerScope: "room-1")
        let idB = MeetingConnectionIdentity(sessionID: sessionID, provider: .guest, generation: next.id, providerScope: "room-1")
        XCTAssertNotEqual(idA, idB)

        let unavailable = UnavailableMeetingFeatureServices(reason: "Service unavailable")
        XCTAssertFalse(unavailable.canRead)
        XCTAssertFalse(unavailable.canSend)
        XCTAssertFalse(unavailable.canSendReactions)
        XCTAssertEqual(unavailable.unavailableReason, "Service unavailable")
        XCTAssertEqual(unavailable.status, .unknown)
        do {
            try await unavailable.send("hello")
            XCTFail("Unavailable chat service must throw")
        } catch {
            XCTAssertEqual(error as? MeetingSessionError, .unavailable("Service unavailable"))
        }
        do {
            try await unavailable.loadTranscriptHistory()
            XCTFail("Unavailable transcript service must throw")
        } catch {
            XCTAssertEqual(error as? MeetingSessionError, .unavailable(L("Transcript history is unavailable in this meeting.")))
        }
        let permit = GuestChatDispatchPermit(deadline: .distantFuture)
        let approved = await unavailable.sendApproved("hi", id: "1", permit: permit)
        XCTAssertEqual(approved, .failed)
    }

    func testFakeProviderAdapterCapturesLifecycleAndSnapshotProjection() async throws {
        let adapter = FakeMeetingProviderAdapter(kind: .telemost, capabilities: .telemost)
        var snapshot = MeetingSessionSnapshot(
            phase: .connected,
            connectionIdentity: MeetingConnectionIdentity(sessionID: UUID(), provider: .telemost, generation: UUID()),
            intent: MeetingMediaIntent(microphoneOn: true, cameraOn: false, playoutOn: true, sharing: false, playoutVolume: 0.75),
            effective: MeetingEffectiveMedia(microphoneOn: false, cameraOn: false, playoutOn: true, sharing: false, microphoneLevel: nil, physicallyMuted: true),
            capabilities: .telemost,
            recoveryExecutor: .nativeAdapterSupervisor
        )
        XCTAssertEqual(snapshot.externalSnapshot.phase, .connected)
        XCTAssertFalse(snapshot.externalSnapshot.microphoneOn, "Effective media stays false until native confirmation")
        snapshot.effective.microphoneOn = true
        XCTAssertTrue(snapshot.externalSnapshot.microphoneOn)

        try await adapter.connect(invitation: XCTUnwrap(URL(string: "https://telemost.yandex.ru/j/123456")),
                                  name: "Tester", quiet: true, sessionID: UUID())
        XCTAssertEqual(adapter.snapshot.phase, .connected)
        XCTAssertFalse(adapter.snapshot.playoutOn)
        let left = await adapter.leave()
        XCTAssertTrue(left)
        XCTAssertEqual(adapter.snapshot.phase, .left)
    }
}

@MainActor private final class FakeMeetingProviderAdapter: MeetingProviderAdapter {
    let kind: MeetingEngineKind
    let recoveryExecutor: RecoveryExecutorKind = .nativeAdapterSupervisor
    let capabilities: MeetingSessionCapabilities
    private(set) var connectionIdentity: MeetingConnectionIdentity?
    private(set) var snapshot = NativeDesktopExternalSnapshot()
    private(set) var sessionSnapshot = MeetingSessionSnapshot()
    let incomingVideo: [NativeDesktopExternalVideo] = []
    let factory: LKRTCPeerConnectionFactory? = nil
    let privateAudioLevel: Float? = nil
    var ownershipDiagnostics: [String: Any] { ["executor": recoveryExecutor.rawValue] }
    let microphoneTrackProbe: GuestMicrophoneTrackProbe? = nil
    let microphoneStartupMilliseconds: [String: Double] = [:]
    var microphoneReadinessPolicy: (() -> Bool)?
    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onSessionSnapshot: ((MeetingSessionSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    var onFeatures: ((GuestMeetingSnapshot) -> Void)?
    var onCapturedMessages: (([GuestMeetingMessage], Bool) -> Void)?
    var onFeatureError: ((Error) -> Void)?

    init(kind: MeetingEngineKind, capabilities: MeetingSessionCapabilities) {
        self.kind = kind
        self.capabilities = capabilities
        sessionSnapshot.capabilities = capabilities
    }

    func connect(invitation: URL, name: String, quiet: Bool, sessionID: MeetingSessionID) async throws {
        _ = (invitation, name)
        connectionIdentity = MeetingConnectionIdentity(sessionID: sessionID, provider: kind, generation: UUID())
        snapshot = NativeDesktopExternalSnapshot(phase: .connected, playoutOn: !quiet)
        sessionSnapshot.phase = .connected
        sessionSnapshot.connectionIdentity = connectionIdentity
        sessionSnapshot.effective.playoutOn = !quiet
        onState?(snapshot)
        onSessionSnapshot?(sessionSnapshot)
    }
    func reconnect() async throws {}
    func leave() async -> Bool {
        snapshot.phase = .left
        sessionSnapshot.phase = .left
        onState?(snapshot)
        onSessionSnapshot?(sessionSnapshot)
        return true
    }
    func setMicrophone(_ enabled: Bool) async throws { _ = enabled }
    func setCamera(_ enabled: Bool) async throws { _ = enabled }
    func setPlayout(_ enabled: Bool) async throws { _ = enabled }
    func setPlayoutVolume(_ volume: Double) async { _ = volume }
    func setParticipantVolume(_ volume: Double, participantID: String) async { _ = (volume, participantID) }
    func configureConcurrentAudio(_ concurrent: Bool) { _ = concurrent }
    func setPhysicalInputPermitted(_ permitted: Bool, keepDeviceWarm: Bool) async -> Bool { _ = (permitted, keepDeviceWarm); return true }
    func prewarmInput() async -> Bool { false }
    func prepareMutedCaptureForAccessories() async throws {}
    func setMicrophoneReadinessForRecovery(_ enabled: Bool) { _ = enabled }
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws { _ = track }
    func setVideoDemand(_ demand: MeetingVideoDemand) async throws { _ = demand }
    func cameraCaptureDevice() async -> AVCaptureDevice? { nil }
    func startPrivateAudioCheck() async throws {}
    func stopPrivateAudioCheck() async throws {}
    func setLocalAudioSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) { _ = sink }
    func setTranscriptionAudioHandler(_ handler: (([MeetingAudioSource]) -> Void)?) { _ = handler }
    func setTranscriptionOutput(_ keep: Bool) async -> Bool { !keep }
    func setTranscriptionRequested(_ requested: Bool) { _ = requested }
    func setMicrophoneGate(open: Bool) async -> Bool { open }
    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool { _ = buffer; return false }
}
