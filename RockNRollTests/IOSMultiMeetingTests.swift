import AVFoundation
import CallKit
import ConferenceCore
import LiveKitWebRTC
import XCTest
@testable import MeetingEngine
@testable import RockNRoll

@MainActor
final class IOSMultiMeetingTests: XCTestCase {
    private final class MockGuestDetectorProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url!
            let status: Int
            let body: String
            if url.host == "trueconf.example.com" {
                if url.path == "/api/v4/conferences/trueconf-room" {
                    status = 200
                    body = "{\"conference\":{\"id\":\"trueconf-room\",\"web_client_url\":\"/webrtc/trueconf-room\",\"allow_guests\":true}}"
                } else {
                    status = 404
                    body = "{}"
                }
            } else {
                let isMetadata = url.path.hasPrefix("/api/")
                status = isMetadata ? 404 : 200
                body = isMetadata ? "{}" : "{\"fixture\":{\"serverUrl\":\"https://backend.example.test\"}}"
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @MainActor
    private final class MockMultiAdapter: MeetingProviderAdapter {
        let kind: MeetingEngineKind
        let capabilities: MeetingSessionCapabilities
        var connectionIdentity: MeetingConnectionIdentity?
        var snapshot = NativeDesktopExternalSnapshot(phase: .idle)
        var sessionSnapshot = MeetingSessionSnapshot(phase: .idle)
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

        var startInLobby: Bool
        var recordedDemands: [MeetingEngine.MeetingVideoDemand] = []
        var physicalInputPermitted = true
        var lastQuietConnect: Bool?
        var setMicrophoneDelay: Duration?
        var microphoneCallCount = 0
        var concurrentMicrophoneCalls = 0
        var maxConcurrentMicrophoneCalls = 0

        init(kind: MeetingEngineKind, startInLobby: Bool = false, canViewTranscript: Bool = false) {
            self.kind = kind
            self.startInLobby = startInLobby
            switch kind {
            case .guest: capabilities = .guest(canViewChat: true, canSendChat: true, canReact: true,
                                               canViewTranscript: canViewTranscript)
            case .community: capabilities = .rock()
            case .telemost: capabilities = .telemost
            case .trueconf: capabilities = .trueconf
            }
            self.sessionSnapshot = MeetingSessionSnapshot(phase: .idle, capabilities: capabilities)
        }

        func connect(invitation: URL, name: String, quiet: Bool, sessionID: MeetingSessionID) async throws {
            lastQuietConnect = quiet
            connectionIdentity = MeetingConnectionIdentity(sessionID: sessionID, provider: kind, generation: UUID())
            let initialPhase: NativeDesktopMeetingPhase = startInLobby ? .lobby : .connected
            snapshot.phase = initialPhase
            snapshot.playoutOn = !quiet
            snapshot.microphoneOn = false
            snapshot.cameraOn = false
            sessionSnapshot = MeetingSessionSnapshot(
                phase: initialPhase,
                connectionIdentity: connectionIdentity,
                intent: MeetingMediaIntent(microphoneOn: false, cameraOn: false, playoutOn: !quiet),
                effective: MeetingEffectiveMedia(microphoneOn: false, cameraOn: false, playoutOn: !quiet),
                capabilities: capabilities,
                participants: [NativeDesktopParticipant(id: "local-\(sessionID.uuidString)", name: name, isLocal: true)]
            )
            onState?(snapshot)
            onSessionSnapshot?(sessionSnapshot)
        }

        func admitFromLobby() {
            snapshot.phase = .connected
            sessionSnapshot.phase = .connected
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

        func setMicrophone(_ enabled: Bool) async throws {
            microphoneCallCount += 1
            concurrentMicrophoneCalls += 1
            maxConcurrentMicrophoneCalls = max(maxConcurrentMicrophoneCalls, concurrentMicrophoneCalls)
            defer { concurrentMicrophoneCalls -= 1 }
            if let setMicrophoneDelay {
                try await Task.sleep(for: setMicrophoneDelay)
            }
            snapshot.microphoneOn = enabled
            sessionSnapshot.intent.microphoneOn = enabled
            sessionSnapshot.effective.microphoneOn = enabled
            onState?(snapshot)
            onSessionSnapshot?(sessionSnapshot)
        }

        func pushRemoteState(participants: [NativeDesktopParticipant], videos: [NativeDesktopExternalVideo]) {
            incomingVideo = videos
            snapshot.participants = participants
            sessionSnapshot.participants = participants
            onVideo?(videos)
            onState?(snapshot)
            onSessionSnapshot?(sessionSnapshot)
        }

        func setCamera(_ enabled: Bool) async throws {
            snapshot.cameraOn = enabled
            sessionSnapshot.intent.cameraOn = enabled
            sessionSnapshot.effective.cameraOn = enabled
            onState?(snapshot)
            onSessionSnapshot?(sessionSnapshot)
        }

        func setPlayout(_ enabled: Bool) async throws {
            snapshot.playoutOn = enabled
            sessionSnapshot.intent.playoutOn = enabled
            sessionSnapshot.effective.playoutOn = enabled
            onState?(snapshot)
            onSessionSnapshot?(sessionSnapshot)
        }

        func setPlayoutVolume(_ volume: Double) async {}
        func setParticipantVolume(_ volume: Double, participantID: String) async {}
        func configureConcurrentAudio(_ concurrent: Bool) {}
        func setPhysicalInputPermitted(_ permitted: Bool, keepDeviceWarm: Bool) async -> Bool {
            physicalInputPermitted = permitted
            return true
        }
        func prewarmInput() async -> Bool { true }
        func prepareMutedCaptureForAccessories() async throws {}
        func setMicrophoneReadinessForRecovery(_ enabled: Bool) {}
        func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {}

        func setVideoDemand(_ demand: MeetingEngine.MeetingVideoDemand) async throws {
            recordedDemands.append(demand)
        }

        func cameraCaptureDevice() async -> AVCaptureDevice? { nil }
        func startPrivateAudioCheck() async throws {}
        func stopPrivateAudioCheck() async throws {}
        func setLocalAudioSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) {}
        func setTranscriptionAudioHandler(_ handler: (([MeetingAudioSource]) -> Void)?) {}
        func setTranscriptionOutput(_ keep: Bool) async -> Bool { false }
        func setTranscriptionRequested(_ requested: Bool) {}
        func setMicrophoneGate(open: Bool) async -> Bool { true }
        func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool { false }
    }

    private func makeModel(lobbyForGuest: Bool = false) -> (
        model: ConferenceModel,
        adapters: () -> [MockMultiAdapter],
        startActions: () -> [CXStartCallAction],
        endActions: () -> [CXEndCallAction],
        container: UIViewController
    ) {
        let queue = DispatchQueue(label: "test.ios-multi-meeting.\(UUID().uuidString)")
        let worker = AudioSessionWorker(queue: queue, activate: {}, deactivate: {})
        var actions: [CXAction] = []
        let provider = CXProvider(configuration: SystemCallCoordinator.providerConfiguration())
        weak var systemCallRef: SystemCallCoordinator?
        let systemCall = SystemCallCoordinator(
            transactionRequester: { transaction, done in
                actions.append(contentsOf: transaction.actions)
                done(nil)
                if transaction.actions.contains(where: { $0 is CXStartCallAction }) {
                    DispatchQueue.main.async {
                        systemCallRef?.provider(provider, didActivate: .sharedInstance())
                    }
                }
            },
            callUpdateReporter: { _, _ in },
            callSnapshot: { [] },
            systemCallRegistration: true,
            activateAudioSession: {},
            sessionWorker: worker
        )
        systemCallRef = systemCall
        addTeardownBlock {
            provider.invalidate()
        }
        let audio = AudioCoordinator(worker: worker, prepareSession: {})
        let workspaceAudio = IOSWorkspaceAudioCoordinator(
            systemCall: systemCall,
            audio: audio,
            captureGate: .live,
            sharedAudio: nil,
            configureLiveKit: false
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockGuestDetectorProtocol.self]
        let preferences = UserDefaults(suiteName: "MultiMeetingTests-" + UUID().uuidString)!
        preferences.set("Alex", forKey: "savedDisplayName")
        let detector = MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: config))
        let reminders = CalendarReminderCoordinator(
            preferences: preferences,
            storage: CalendarReminderTests.Storage(),
            notifications: CalendarReminderTests.Notifications()
        )
        let calendar = CalendarMeetingStore(
            reader: MeetingSetupUIFixture.Reader(denied: false),
            detector: detector,
            preferences: preferences,
            storage: RoomSyncCoordinatorTests.Storage(),
            reminders: reminders
        )
        let model = ConferenceModel(
            history: RoomHistoryStore(storage: RoomSyncCoordinatorTests.Storage()),
            preferences: preferences,
            engineDetector: detector,
            calendar: calendar,
            workspaceAudio: workspaceAudio
        )
        model.setup.suspendForMeeting()

        var createdAdapters: [MockMultiAdapter] = []
        model.makeProviderAdapterForTesting = { destination, _ in
            let adapter = MockMultiAdapter(
                kind: destination.engineKind,
                startInLobby: lobbyForGuest && destination.engineKind == .guest
            )
            createdAdapters.append(adapter)
            return adapter
        }

        let container = UIViewController()
        model.configure(container: container)

        return (
            model,
            { createdAdapters },
            { actions.compactMap { $0 as? CXStartCallAction } },
            { actions.compactMap { $0 as? CXEndCallAction } },
            container
        )
    }

    override func tearDown() {
        LKRTCSetApplicationCaptureMuted(0)
        super.tearDown()
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testCatchUpTracksConnectionLossOnlyAfterAdmissionAndClosesItOnRecovery() throws {
        let destination = try JoinDestination.parse("https://meeting.example.test/calls/room-guest?psw=secret123")
        let adapter = MockMultiAdapter(kind: .guest)
        let catchUp = CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let workspaceAudio = IOSWorkspaceAudioCoordinator(sharedAudio: nil, configureLiveKit: false)
        let controller = IOSMeetingSessionController(
            destination: destination,
            session: MeetingSession(kind: .guest, adapter: adapter),
            chat: ChatStore(),
            catchUp: catchUp,
            workspaceAudio: workspaceAudio,
            initialTitle: nil
        )

        adapter.onSessionSnapshot?(MeetingSessionSnapshot(phase: .connecting))
        adapter.onSessionSnapshot?(MeetingSessionSnapshot(phase: .reconnecting))
        XCTAssertTrue(catchUp.timeline.intervals.isEmpty)
        adapter.onSessionSnapshot?(MeetingSessionSnapshot(phase: .connected))
        XCTAssertEqual(controller.phase, .connected)

        let interruptionStarted = Date()
        adapter.onSessionSnapshot?(MeetingSessionSnapshot(phase: .reconnecting))
        let interval = try XCTUnwrap(catchUp.timeline.intervals.last)
        XCTAssertGreaterThanOrEqual(interval.start, interruptionStarted)
        XCTAssertNil(interval.end)
        adapter.onSessionSnapshot?(MeetingSessionSnapshot(phase: .connecting))
        adapter.onSessionSnapshot?(MeetingSessionSnapshot(phase: .connected))
        XCTAssertEqual(catchUp.timeline.intervals.map(\.id), [interval.id])
        XCTAssertNotNil(catchUp.timeline.intervals.last?.end)
    }

    func testGuestTranscriptCaptureStaysOutOfChatAndWorkspaceChatEvents() throws {
        let destination = try JoinDestination.parse("https://meeting.example.test/calls/room-guest?psw=secret123")
        let adapter = MockMultiAdapter(kind: .guest, canViewTranscript: true)
        let workspaceAudio = IOSWorkspaceAudioCoordinator(sharedAudio: nil, configureLiveKit: false)
        let controller = IOSMeetingSessionController(
            destination: destination,
            session: MeetingSession(kind: .guest, adapter: adapter),
            chat: ChatStore(),
            catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            workspaceAudio: workspaceAudio,
            initialTitle: nil
        )
        var archivedEvents: [SyncedTranscriptEvent] = []
        controller.onWorkspaceEventsChanged = { _, events, _, _ in archivedEvents.append(contentsOf: events) }
        let time = Date()
        let chatMessage = GuestMeetingMessage(id: "chat", participantID: "ani", participantName: "Ani",
                                              text: "Typed message", sentAt: time, isOwn: false)
        let liveLine = GuestMeetingMessage(id: "live", participantID: "ani", participantName: "Ani",
                                           text: "Live speech", sentAt: time.addingTimeInterval(1), isOwn: false)
        let historyLine = GuestMeetingMessage(id: "history", participantID: "ani", participantName: "Ani",
                                              text: "Earlier speech", sentAt: time.addingTimeInterval(-1), isOwn: false)
        let ownLine = GuestMeetingMessage(id: "own", participantID: "my-id", participantName: "Ani",
                                          text: "My reply", sentAt: time.addingTimeInterval(2), isOwn: true)

        adapter.onCapturedMessages?([chatMessage], false)
        XCTAssertEqual(controller.chat.items.map(\.id), [chatMessage.id])
        let unreadCount = controller.chat.unreadCount

        adapter.onCapturedMessages?([liveLine], true)
        adapter.onCapturedMessages?([historyLine, liveLine], true)
        XCTAssertEqual(controller.chat.items.map(\.id), [chatMessage.id])
        XCTAssertEqual(controller.chat.unreadCount, unreadCount)
        XCTAssertFalse(controller.chat.unreadCoverageIsLimited)

        adapter.onFeatures?(GuestMeetingSnapshot(
            permissions: GuestMeetingPermissions(canViewChat: true, canViewTranscript: true),
            messages: [chatMessage],
            transcript: [historyLine, liveLine, ownLine],
            transcriptionStatus: .active
        ))
        XCTAssertEqual(controller.catchUp.timeline.segments.map(\.id), [historyLine.id, liveLine.id, ownLine.id])
        XCTAssertEqual(Set(archivedEvents.filter { $0.kind == "chat" }.map(\.providerMessageID)), [chatMessage.id])
        XCTAssertEqual(Set(archivedEvents.filter { $0.kind == "transcript" }.map(\.providerMessageID)),
                       [historyLine.id, liveLine.id, ownLine.id])
        XCTAssertEqual(Set(archivedEvents.filter(\.isOwn).map(\.id)), [ownLine.id])
    }

    func testFourSimultaneousSessionsAcrossAllProvidersAndFifthRoomPromptReplacement() async throws {
        let h = makeModel()
        defer {
            h.model.workspaceAudio.systemCall.markEnded(reason: .remoteEnded)
            withExtendedLifetime(h.container) {}
        }

        let urls = [
            URL(string: "https://meeting.example.test/calls/room-guest?psw=secret123")!,
            URL(string: "https://rock.glowsoft.ru/jams/test")!,
            URL(string: "https://telemost.yandex.ru/j/1234567890")!,
            URL(string: "https://trueconf.example.com/c/trueconf-room")!,
        ]

        // 1. Join first room directly.
        h.model.receive(url: urls[0])
        h.model.join()
        try await waitUntil { h.model.isInConference && !h.model.sessions.isEmpty }
        XCTAssertEqual(h.model.sessions.count, 1)
        let firstSession = try XCTUnwrap(h.model.sessions.first)
        XCTAssertEqual(firstSession.kind, .guest)
        XCTAssertEqual(firstSession.phase, .connected)
        await h.model.workspaceAudio.waitForAggregateLeaseForTesting()
        XCTAssertEqual(h.startActions().count, 1)

        // Fresh join defaults: mic OFF, camera OFF, playout ON.
        let firstAdapter = try XCTUnwrap(h.adapters().first)
        XCTAssertEqual(firstAdapter.lastQuietConnect, false)
        XCTAssertFalse(firstAdapter.snapshot.microphoneOn)
        XCTAssertFalse(firstAdapter.snapshot.cameraOn)
        XCTAssertTrue(firstAdapter.snapshot.playoutOn)

        // 2..4. Minimize & Join Alongside for .community, .telemost, .trueconf.
        for (index, url) in urls.dropFirst().enumerated() {
            h.model.minimizeActiveCall()
            XCTAssertTrue(h.model.isCallMinimized)
            h.model.receive(url: url)
            XCTAssertTrue(h.model.showSwitchConfirmation)
            XCTAssertTrue(h.model.canJoinAlongsidePending)
            h.model.joinAlongsidePending()
            XCTAssertFalse(h.model.showSwitchConfirmation)
            try await waitUntil { h.model.sessions.count >= index + 2 && h.model.sessions.last?.phase == .connected }
        }

        XCTAssertEqual(h.model.sessions.count, 4)
        XCTAssertEqual(Set(h.model.sessions.map(\.kind)), [.guest, .community, .telemost, .trueconf])
        XCTAssertEqual(h.startActions().count, 1, "All 4 sessions share one CallKit lease")
        XCTAssertEqual(h.endActions().count, 0)

        // 5th URL cannot join alongside and replaces current foreground room when accepted.
        let fifthURL = URL(string: "https://meeting.example.test/calls/room-5?psw=secret123")!
        h.model.receive(url: fifthURL)
        XCTAssertTrue(h.model.showSwitchConfirmation)
        XCTAssertFalse(h.model.canJoinAlongsidePending)
        let replacedID = try XCTUnwrap(h.model.foregroundSession?.id)
        h.model.replaceWithPending()
        XCTAssertFalse(h.model.showSwitchConfirmation)

        try await waitUntil {
            !h.model.sessions.contains(where: { $0.id == replacedID }) &&
                h.model.sessions.count == 4 &&
                h.model.sessions.last?.phase == .connected
        }
        XCTAssertEqual(h.model.sessions.count, 4)
        XCTAssertFalse(h.model.sessions.contains(where: { $0.id == replacedID }))
        XCTAssertEqual(h.model.foregroundSession?.invitationURL, fifthURL)
        XCTAssertEqual(h.endActions().count, 0)

        // Leave down 4 -> 1 keeps CallKit alive; leaving final 1 -> 0 ends CallKit.
        for remainingCount in stride(from: 3, through: 1, by: -1) {
            let victim = try XCTUnwrap(h.model.sessions.first)
            h.model.leaveSession(id: victim.id)
            try await waitUntil { h.model.sessions.count <= remainingCount }
            XCTAssertEqual(h.model.sessions.count, remainingCount)
            XCTAssertEqual(h.endActions().count, 0)
        }
        let last = try XCTUnwrap(h.model.sessions.first)
        h.model.leaveSession(id: last.id)
        try await waitUntil { h.model.sessions.isEmpty }
        XCTAssertTrue(h.model.sessions.isEmpty)
        XCTAssertEqual(h.endActions().count, 1)
    }

    func testLobbyAdmissionSameRoomRestoreVideoDemandAndTalkHandover() async throws {
        let h = makeModel(lobbyForGuest: true)
        defer {
            h.model.workspaceAudio.systemCall.markEnded(reason: .remoteEnded)
            withExtendedLifetime(h.container) {}
        }

        let guestURL = URL(string: "https://meeting.example.test/calls/lobby-room?psw=secret")!
        h.model.receive(url: guestURL)
        h.model.join()
        try await waitUntil { h.model.sessions.first?.phase == .lobby }
        XCTAssertEqual(h.model.sessions.count, 1)
        let roomA = try XCTUnwrap(h.model.sessions.first)
        XCTAssertEqual(roomA.phase, .lobby)
        XCTAssertTrue(h.model.isJoining)
        XCTAssertFalse(h.model.isInConference)

        let guestAdapter = try XCTUnwrap(h.adapters().first)
        guestAdapter.admitFromLobby()
        try await waitUntil { h.model.isInConference }
        XCTAssertEqual(roomA.phase, .connected)
        XCTAssertTrue(h.model.isInConference)

        // Minimize drops remote camera video demand to false.
        h.model.minimizeActiveCall()
        try await waitUntil { roomA.lastDemand?.receivesCameras == false }
        XCTAssertTrue(h.model.isCallMinimized)
        XCTAssertEqual(roomA.lastDemand?.receivesCameras, false)

        // Opening same room URL restores without prompt and re-enables foreground video demand.
        h.model.receive(url: guestURL)
        XCTAssertFalse(h.model.showSwitchConfirmation)
        XCTAssertEqual(h.model.sessions.count, 1)
        XCTAssertFalse(h.model.isCallMinimized)
        try await waitUntil { roomA.lastDemand?.receivesCameras == true }
        XCTAssertEqual(roomA.lastDemand?.receivesCameras, true)

        // Join Room B alongside Room A: Room A moves out of foreground (receivesCameras == false).
        let telemostURL = URL(string: "https://telemost.yandex.ru/j/9876543210")!
        h.model.receive(url: telemostURL)
        XCTAssertTrue(h.model.showSwitchConfirmation)
        h.model.joinAlongsidePending()
        try await waitUntil { h.model.sessions.count == 2 && h.model.sessions.last?.phase == .connected }
        let roomB = try XCTUnwrap(h.model.sessions.last)
        try await waitUntil { roomA.lastDemand?.receivesCameras == false }
        XCTAssertEqual(roomA.lastDemand?.receivesCameras, false)
        XCTAssertEqual(roomB.lastDemand?.receivesCameras, true)

        // One-tap Talk handover switches talkSessionID to Room B keeping mic safely muted.
        XCTAssertEqual(h.model.workspaceAudio.talkSessionID, roomA.id)
        h.model.switchTalk(to: roomB.id)
        try await waitUntil { h.model.workspaceAudio.talkSessionID == roomB.id }
        XCTAssertEqual(h.model.workspaceAudio.talkSessionID, roomB.id)
        XCTAssertTrue(h.model.workspaceAudio.isMuted)
        XCTAssertTrue(roomB.isTalkRoom)
        XCTAssertFalse(roomA.isTalkRoom)
    }

    func testProductionSessionsDisableExclusiveTalkAndAttachFourConcurrentRoomsToSharedAudioEngine() async throws {
        // 1. Verify ConferenceModel builds production sessions with exclusiveTalk == false (no mock adapter).
        let queue = DispatchQueue(label: "test.ios-multi-production.\(UUID().uuidString)")
        let worker = AudioSessionWorker(queue: queue, activate: {}, deactivate: {})
        let systemCall = SystemCallCoordinator(
            transactionRequester: { _, done in done(nil) }, // Keeps session gated on CallKit activation while we inspect it.
            callUpdateReporter: { _, _ in },
            callSnapshot: { [] },
            systemCallRegistration: true,
            activateAudioSession: {},
            sessionWorker: worker
        )
        let workspaceAudio = IOSWorkspaceAudioCoordinator(
            systemCall: systemCall,
            audio: AudioCoordinator(worker: worker, prepareSession: {}),
            captureGate: .live,
            sharedAudio: nil,
            configureLiveKit: false
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockGuestDetectorProtocol.self]
        let preferences = UserDefaults(suiteName: "ProductionSessionTests-" + UUID().uuidString)!
        preferences.set("Alex", forKey: "savedDisplayName")
        let detector = MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: config))
        let reminders = CalendarReminderCoordinator(
            preferences: preferences,
            storage: CalendarReminderTests.Storage(),
            notifications: CalendarReminderTests.Notifications()
        )
        let calendar = CalendarMeetingStore(
            reader: MeetingSetupUIFixture.Reader(denied: false),
            detector: detector,
            preferences: preferences,
            storage: RoomSyncCoordinatorTests.Storage(),
            reminders: reminders
        )
        let model = ConferenceModel(
            history: RoomHistoryStore(storage: RoomSyncCoordinatorTests.Storage()),
            preferences: preferences,
            engineDetector: detector,
            calendar: calendar,
            workspaceAudio: workspaceAudio
        )
        model.setup.suspendForMeeting()
        let container = UIViewController()
        model.configure(container: container)
        defer {
            model.leave()
            workspaceAudio.systemCall.markEnded(reason: .remoteEnded)
            withExtendedLifetime(container) {}
        }

        let guestInvite = URL(string: "https://meeting.example.test/calls/prod-room?psw=secret123")!
        model.receive(url: guestInvite)
        model.join()
        try await waitUntil { !model.sessions.isEmpty }
        let prodController = try XCTUnwrap(model.sessions.first)
        XCTAssertFalse(prodController.session.exclusiveTalk, "iOS sessions must keep exclusiveTalk false so 4-room joining works alongside .guest")
        XCTAssertEqual(prodController.session.ownershipDiagnostics["exclusiveTalk"] as? Bool, false)
        model.leaveSession(id: prodController.id)
        try await waitUntil { model.sessions.isEmpty }

        // 2. Verify SharedAudioEngine attaches all 4 providers (including .guest first and .guest non-first) when exclusiveTalk == false.
        GuestSystemAudio.microphoneAuthorizationOverrideForTesting = true
        defer { GuestSystemAudio.microphoneAuthorizationOverrideForTesting = nil }

        let orderings: [[(MeetingEngineKind, URL)]] = [
            [
                (.guest, URL(string: "https://custom.example.test/calls/multi-guest")!),
                (.community, URL(string: "https://custom.example.test/jams/multi-rock")!),
                (.telemost, URL(string: "https://telemost.yandex.ru/j/12345678901234")!),
                (.trueconf, URL(string: "https://custom.example.test/c/multi-trueconf?password=secret")!),
            ],
            [
                (.community, URL(string: "https://custom.example.test/jams/multi-rock-2")!),
                (.guest, URL(string: "https://custom.example.test/calls/multi-guest-2")!),
                (.telemost, URL(string: "https://telemost.yandex.ru/j/22345678901234")!),
                (.trueconf, URL(string: "https://custom.example.test/c/multi-trueconf-2?password=secret")!),
            ],
        ]

        for ordering in orderings {
            let shared = SharedAudioEngine.live(manualRenderingForTesting: true)
            let engine = UniversalMeetingEngine(sharedAudio: shared)
            var sessions: [MeetingSession] = []
            var audios: [SharedGuestMeetingAudio] = []

            for (kind, url) in ordering {
                let destination = try JoinDestination.verified(url, engine: kind)
                let session = engine.makeSession(destination: destination, exclusiveTalk: false)
                XCTAssertFalse(session.exclusiveTalk)
                let audio = try await SharedGuestMeetingAudio.attach(to: shared, meetingID: session.id)
                sessions.append(session)
                audios.append(audio)
            }

            XCTAssertEqual(engine.activeSessionCount, 4)
            XCTAssertEqual(shared.ownershipDiagnostics["attachmentCount"] as? Int, 4)
            let granted0 = await audios[0].setInputPermitted(true)
            XCTAssertTrue(granted0)
            XCTAssertEqual(shared.talkMeetingID, sessions[0].id)
            let granted1 = await audios[1].setInputPermitted(true)
            XCTAssertTrue(granted1)
            XCTAssertEqual(shared.talkMeetingID, sessions[1].id)
            XCTAssertTrue(shared.moduleMuted)

            for audio in audios { _ = await audio.shutdown() }
            for session in sessions { _ = await session.leave() }
            XCTAssertEqual(shared.ownershipDiagnostics["attachmentCount"] as? Int, 0)
        }
    }

    func testEmptyGuestMeetingRunsOutputUntilLastListeningRoomLeaves() async throws {
        let shared = SharedAudioEngine.live()
        let guest = try await SharedGuestMeetingAudio.attach(to: shared)
        let other = try await SharedGuestMeetingAudio.attach(to: shared)
        let owner = try XCTUnwrap(shared.guestOwner)
        let module = owner.factory.audioDeviceModule
        shared.pinForProcess() // Production keeps this factory when the last room leaves.
        addTeardownBlock {
            _ = await guest.shutdown()
            _ = await other.shutdown()
            _ = await owner.shutdown()
        }

        let quiet = await other.beginAttempt(sound: false)
        XCTAssertTrue(quiet)
        XCTAssertFalse(module.isPlaying)
        let listening = await guest.beginAttempt(sound: true)
        XCTAssertTrue(listening)
        XCTAssertTrue(module.isEngineRunning)
        XCTAssertFalse(module.isRecording)
        func buffers() -> Int { owner.playoutMeterEvidence["buffers"] as? Int ?? 0 }
        try await waitUntil { buffers() > 0 }
        XCTAssertGreaterThan(buffers(), 0, "An empty room should already be pulling conference output")

        // WebRTC withdraws its own playout request when the last receive stream ends.
        let stopped = await Task.detached { module.stopPlayout() }.value
        XCTAssertEqual(stopped, 0)
        let atStop = buffers()
        try await waitUntil { module.isPlaying && buffers() > atStop }
        XCTAssertTrue(module.isPlaying)
        XCTAssertGreaterThan(buffers(), atStop)
        XCTAssertFalse(module.isRecording)

        let otherListening = await other.setPlayoutEnabled(true)
        XCTAssertTrue(otherListening)
        let left = await guest.shutdown()
        XCTAssertTrue(left)
        XCTAssertTrue(module.isPlaying)
        let silenced = await other.setPlayoutEnabled(false)
        XCTAssertTrue(silenced)
        XCTAssertFalse(module.isEngineRunning)
        let resumed = await other.setPlayoutEnabled(true)
        XCTAssertTrue(resumed)
        XCTAssertTrue(module.isPlaying)
        let lastLeft = await other.shutdown()
        XCTAssertTrue(lastLeft)
        XCTAssertFalse(module.isPlaying)
        XCTAssertFalse(module.isEngineRunning)
    }

    func testMutedGuestSendsVoiceReplyToRemoteDecoder() async throws {
        let shared = SharedAudioEngine.live()
        let audio = try await SharedGuestMeetingAudio.attach(to: shared)
        let guest = NativeGuestEngine(label: "Voice publisher", systemAudio: audio)
        let listener = NativeGuestEngine(label: "Voice listener")
        addTeardownBlock {
            _ = await guest.leave(sendLeave: false)
            _ = await listener.leave(sendLeave: false)
            _ = await audio.shutdown()
        }
        let listening = await audio.beginAttempt(sound: true)
        XCTAssertTrue(listening)
        let publisher = try await guest.prepareJoinForTesting(camera: false)
        let subscriber = try await listener.prepareSubscriberForTesting()
        for peer in [publisher, subscriber] {
            let config = peer.connection.configuration
            config.iceTransportPolicy = .all
            XCTAssertTrue(peer.connection.setConfiguration(config))
        }
        publisher.sendCandidate = { [weak subscriber] candidate in
            try await subscriber?.addCandidates([candidate.merging(["target": "SUBSCRIBER"]) { _, new in new }])
        }
        subscriber.sendCandidate = { [weak publisher] candidate in
            try await publisher?.addCandidates([candidate.merging(["target": "PUBLISHER"]) { _, new in new }])
        }
        let mic = try await publisher.prepareAudio(cid: "mic")
        try await publisher.attach(mic, codec: "opus")
        guest.setLocalMuteIntent(true, video: false)
        guest.preparePublicationForTesting(cid: "mic", video: false)
        try await guest.processEventForTesting(["event": "media-out", "payload": [
            "method": "rtc:track:published", "trackPublishedResponse": ["cid": "mic", "track": ["sid": "audio", "muted": true]]
        ]])
        let offer = try await publisher.makeOffer()
        let answer = try await subscriber.answer(offer)
        try await publisher.acceptAnswer(answer)
        try await subscriber.didSendDescription()
        try await publisher.didSendDescription()
        try await waitUntil { publisher.transportConnected && subscriber.transportConnected }
        XCTAssertTrue(publisher.transportConnected && subscriber.transportConnected)
        var commands: [Bool] = []
        guest.mediaNotifyForTesting = { payload in
            let muted = try XCTUnwrap((payload["mute"] as? [String: Any])?["muted"] as? Bool)
            commands.append(muted)
            if !muted {
                // Model a service that advertises a cold publisher only after receiving RTP.
                func hasAudioPacket() async -> Bool {
                    let rows = await subscriber.stats() ?? []
                    return rows.contains {
                        $0["type"] as? String == "inbound-rtp" && (($0["packetsReceived"] as? NSNumber)?.intValue ?? 0) > 0
                    }
                }
                for _ in 0..<30 {
                    if await hasAudioPacket() { break }
                    try await Task.sleep(for: .milliseconds(30))
                }
                guard await hasAudioPacket() else { return }
            }
            try await guest.processEventForTesting(["event": "media-out", "payload": [
                "method": "rtc:participants:update", "update": ["participants": [[
                    "identity": "local", "sid": "local", "version": commands.count,
                    "tracks": [["sid": "audio", "type": "AUDIO", "muted": muted]]
                ]]]
            ]])
        }
        defer { guest.mediaNotifyForTesting = nil }
        let reply: AVAudioPCMBuffer
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SYSTEM_VOICE_REPLY"] == "1" {
            reply = try await IOSVoiceSynthesis.system("Проверка звука. Меня слышно?", language: "ru-RU")
        } else {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            reply = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            reply.frameLength = reply.frameCapacity
            for i in 0..<Int(reply.frameLength) { reply.floatChannelData![0][i] = 0.25 * sin(Float(i) * 0.07) }
        }
        let before = subscriber.pcmMeter.snapshot.nonSilentCallbacks
        let played = await guest.playNonTalkVoiceReply(reply, localGain: nil)
        XCTAssertTrue(played)
        try await waitUntil { subscriber.pcmMeter.snapshot.nonSilentCallbacks > before + 5 }
        XCTAssertGreaterThan(subscriber.pcmMeter.snapshot.nonSilentCallbacks, before + 5)
        XCTAssertGreaterThan(subscriber.pcmMeter.snapshot.rms, 0.02, "Remote decoder received audible reply audio")
        XCTAssertEqual(commands, [false, true])
        XCTAssertFalse(mic.isEnabled)
        XCTAssertFalse(audio.factory.audioDeviceModule.isRecording)
    }

    func testLateGuestPublisherReachesListeningOutputWithVideoOff() async throws {
        let shared = SharedAudioEngine.live()
        let audio = try await SharedGuestMeetingAudio.attach(to: shared)
        let listener = NativeGuestEngine(label: "Listener", systemAudio: audio)
        let lateGuest = NativeGuestEngine(label: "Late publisher") // Uses a synthetic microphone.
        addTeardownBlock {
            _ = await lateGuest.leave(sendLeave: false)
            _ = await listener.leave(sendLeave: false)
        }

        let listening = await audio.beginAttempt(sound: true)
        XCTAssertTrue(listening)
        _ = audio.setMeetingVolume(0.02)
        listener.configureStartupPlayback(sound: true)
        let subscriber = try await listener.prepareSubscriberForTesting()
        _ = try await listener.prepareJoinForTesting(microphone: false, camera: false)
        listener.startTransportObservationForTesting()
        try await listener.setVisibleParticipantIDs([], cameras: false)
        try await listener.waitForStartupAudio()
        XCTAssertTrue(listener.releaseStartupAudio())
        XCTAssertEqual(listener.startupAudioReport["decision"] as? String, "noDemand")

        let backgroundRun = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_BACKGROUND_LATE_GUEST"] == "1"
        if backgroundRun {
            print("BACKGROUND_LATE_GUEST_READY")
            try await waitUntil(timeout: 30) { UIApplication.shared.applicationState == .background }
            XCTAssertEqual(UIApplication.shared.applicationState, .background)
            let initialBuffers = audio.playoutMeterEvidence["buffers"] as? Int ?? 0
            try await Task.sleep(for: .seconds(35))
            XCTAssertGreaterThan(audio.playoutMeterEvidence["buffers"] as? Int ?? 0, initialBuffers)
        }

        let publisher = try await lateGuest.prepareJoinForTesting()
        for peer in [publisher, subscriber] {
            let config = peer.connection.configuration
            config.iceTransportPolicy = .all // Local peers only. The fixtures have no ICE servers.
            XCTAssertTrue(peer.connection.setConfiguration(config))
        }
        publisher.sendCandidate = { [weak subscriber] candidate in
            try await subscriber?.addCandidates([candidate.merging(["target": GuestPeerTarget.subscriber.rawValue]) { _, new in new }])
        }
        subscriber.sendCandidate = { [weak publisher] candidate in
            try await publisher?.addCandidates([candidate.merging(["target": GuestPeerTarget.publisher.rawValue]) { _, new in new }])
        }
        let track = try await publisher.prepareAudio(cid: "late-audio")
        try await publisher.attach(track, codec: "opus")
        let offer = try await publisher.makeOffer()
        let answer = try await subscriber.answer(offer)
        try await publisher.acceptAnswer(answer)
        try await subscriber.didSendDescription()
        try await publisher.didSendDescription()
        let beforeUnmute = audio.playoutMeterEvidence["nonSilentCallbacks"] as? Int ?? 0
        try await publisher.setMuted(false, video: false)
        try await waitUntil(timeout: 10) { (audio.playoutMeterEvidence["nonSilentCallbacks"] as? Int ?? 0) > beforeUnmute }
        XCTAssertGreaterThan(audio.playoutMeterEvidence["nonSilentCallbacks"] as? Int ?? 0, beforeUnmute)
        XCTAssertEqual(listener.startupAudioReport["decision"] as? String, "active")
        XCTAssertFalse(audio.factory.audioDeviceModule.isRecording)
        if backgroundRun { XCTAssertEqual(UIApplication.shared.applicationState, .background) }

        // The same subscriber observer runs in Release. Check its own sample survives the iOS export.
        let remoteTrack = try XCTUnwrap(subscriber.receivedAudioSources.first?.trackID)
        listener.mediaNotifyForTesting = { _ in }
        try await listener.processEventForTesting(["event": "media-out", "payload": [
            "method": "rtc:participants:update", "update": ["participants": [[
                "sid": "PA_late", "identity": "late-publisher", "state": "ACTIVE",
                "tracks": [["sid": remoteTrack, "type": "AUDIO", "source": "MICROPHONE", "muted": false]]
            ]]]
        ]])
        func isReceptionSample(_ line: String) -> Bool {
            line.contains("\"event\":\"guest-audio-reception\"") && line.contains(subscriber.diagnosticID)
                && line.contains("\"packetsReceived\":") && line.contains("\"decodedNonSilentCallbacks\":")
        }
        try await waitUntil(timeout: 10) { probeLogHistory().contains(where: isReceptionSample) }
        let archive = try AppDiagnostics.makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let saved = try NativeDiagnosticsLog.shared.files.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertTrue(saved.contains { $0.components(separatedBy: "\n").contains(where: isReceptionSample) })
        XCTAssertNotNil(try Data(contentsOf: archive).range(of: Data("audio-reception.log".utf8)))
        let attachment = XCTAttachment(contentsOfFile: archive)
        attachment.name = "Guest audio diagnostics.zip"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testReplacementGuestConnectionKeepsAudioOnlyDemand() async throws {
        let adapter = GuestAdapter()
        let original = NativeGuestEngine(label: "Original")
        adapter.bindHistoryForTesting(original)
        try await adapter.setVideoDemand(MeetingEngine.MeetingVideoDemand(visibleParticipantIDs: [], receivesCameras: false))

        let replacement = NativeGuestEngine(label: "Replacement")
        var subscriptions: [[String]] = []
        replacement.mediaNotifyForTesting = { payload in
            guard let subscription = payload["subscription"] as? [String: Any],
                  subscription["subscribe"] as? Bool == true,
                  let tracks = subscription["trackSids"] as? [String] else { return }
            subscriptions.append(tracks)
        }
        adapter.bindHistoryForTesting(replacement)
        defer { adapter.unbindHistoryForTesting() }

        _ = try await replacement.prepareJoinForTesting()
        try await replacement.processEventForTesting([
            "event": "media-out",
            "payload": [
                "method": "rtc:participants:update",
                "update": ["participants": [[
                    "sid": "remote", "identity": "presenter", "state": "ACTIVE",
                    "tracks": [
                        ["sid": "audio", "type": "AUDIO", "source": "MICROPHONE", "muted": false],
                        ["sid": "screen", "type": "VIDEO", "source": "SCREEN_SHARE", "muted": false]
                    ]
                ]]]
            ]
        ])
        XCTAssertEqual(subscriptions, [["audio"]])
        try await adapter.setVideoDemand(MeetingEngine.MeetingVideoDemand())
        XCTAssertEqual(subscriptions, [["audio"], ["screen"]])
        _ = await replacement.leave(sendLeave: false)
        _ = await original.leave(sendLeave: false)
    }

    func testForegroundVideoDemandPermitsCameraAndScreenShareDiscoveryAndRendersArbitraryTrackIDs() async throws {
        let h = makeModel()
        defer {
            h.model.workspaceAudio.systemCall.markEnded(reason: .remoteEnded)
            withExtendedLifetime(h.container) {}
        }

        let guestURL = URL(string: "https://meeting.example.test/calls/video-discovery?psw=secret")!
        h.model.receive(url: guestURL)
        h.model.join()
        try await waitUntil { h.model.isInConference && !h.model.sessions.isEmpty }

        let controller = try XCTUnwrap(h.model.sessions.first)
        let adapter = try XCTUnwrap(h.adapters().first)
        let callView = controller.prepareCallView()

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = callView
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        callView.view.layoutIfNeeded()
        controller.setForegroundVisible(true)
        controller.updateVideoDemand(appActive: true)
        await Task.yield()

        // Empty stage while foregrounded must pass nil (discovery enabled), NEVER []!
        XCTAssertEqual(controller.lastDemand, MeetingEngine.MeetingVideoDemand(
            visibleParticipantIDs: nil,
            focusedParticipantID: nil,
            preferredScreenParticipantID: nil,
            receivesCameras: true
        ))

        let factory = LKRTCPeerConnectionFactory()
        let videoSource = factory.videoSource()
        let remoteCam1 = factory.videoTrack(with: videoSource, trackId: "TR_VC_abc")
        let remoteCam2 = factory.videoTrack(with: videoSource, trackId: "TR_VC_def")
        let remoteShare1 = factory.videoTrack(with: videoSource, trackId: "TR_VS_xyz")

        // Remote camera arrives with cameraOn == nil + a second orphan camera before roster entry exists.
        adapter.pushRemoteState(
            participants: [
                NativeDesktopParticipant(id: "local", name: "Alex", isLocal: true),
                NativeDesktopParticipant(id: "remote-1", name: "Peer 1", isLocal: false, microphoneOn: true, cameraOn: nil, sharing: false),
            ],
            videos: [
                NativeDesktopExternalVideo(id: "PA_1|TR_VC_abc", participantID: "remote-1", source: .camera, track: remoteCam1),
                NativeDesktopExternalVideo(id: "PA_2|TR_VC_def", participantID: "remote-2", source: .camera, track: remoteCam2),
            ]
        )
        callView.view.layoutIfNeeded()
        await Task.yield()

        let snapshot1 = try XCTUnwrap(callView.snapshotForTesting)
        let peer1 = try XCTUnwrap(snapshot1.participants.first { $0.id == "remote-1" })
        let peer2 = try XCTUnwrap(snapshot1.participants.first { $0.id == "remote-2" })
        XCTAssertTrue(peer1.cameraOn)
        XCTAssertEqual(peer1.videoTracks.map(\.id), ["PA_1|TR_VC_abc"])
        XCTAssertTrue(peer2.cameraOn)
        XCTAssertEqual(peer2.videoTracks.map(\.id), ["PA_2|TR_VC_def"])
        // <= 6 participants must keep visibleParticipantIDs == nil so track SIDs never filter out participants!
        XCTAssertNil(controller.lastDemand?.visibleParticipantIDs)
        XCTAssertEqual(controller.lastDemand?.receivesCameras, true)
        XCTAssertTrue(Self.findScrollView(id: "PA_1|TR_VC_abc", in: callView.view) != nil)
        XCTAssertTrue(Self.findScrollView(id: "PA_2|TR_VC_def", in: callView.view) != nil)

        // Screen share arrives mid-meeting -> rendered and selected cleanly.
        adapter.pushRemoteState(
            participants: [
                NativeDesktopParticipant(id: "local", name: "Alex", isLocal: true),
                NativeDesktopParticipant(id: "remote-1", name: "Peer 1", isLocal: false, microphoneOn: true, cameraOn: true, sharing: true),
            ],
            videos: [
                NativeDesktopExternalVideo(id: "PA_1|TR_VC_abc", participantID: "remote-1", source: .camera, track: remoteCam1),
                NativeDesktopExternalVideo(id: "PA_1|TR_VS_xyz", participantID: "remote-1", source: .screen, track: remoteShare1),
            ]
        )
        callView.view.layoutIfNeeded()
        await Task.yield()
        XCTAssertTrue(Self.findScrollView(id: "PA_1|TR_VS_xyz", in: callView.view) != nil)
        XCTAssertNil(controller.lastDemand?.visibleParticipantIDs)
        XCTAssertEqual(controller.lastDemand?.preferredScreenParticipantID, "remote-1")

        // .screenShares mode stops camera demand while keeping visibleParticipantIDs == nil so new shares subscribe.
        callView.setDisplayMode(.screenShares)
        controller.updateVideoDemand(appActive: true)
        XCTAssertEqual(controller.lastDemand?.receivesCameras, false)
        XCTAssertNil(controller.lastDemand?.visibleParticipantIDs)

        // .audioOnly mode retires all video subscriptions cleanly.
        callView.setDisplayMode(.audioOnly)
        controller.updateVideoDemand(appActive: true)
        XCTAssertEqual(controller.lastDemand?.receivesCameras, false)
        XCTAssertEqual(controller.lastDemand?.visibleParticipantIDs, [])

        // >6 remote participants in .grid mode maps visible tiles to participant IDs (never track SIDs).
        callView.setDisplayMode(.all)
        let eightRemotes = (1...8).map { idx in
            NativeDesktopParticipant(id: "remote-\(idx)", name: "Peer \(idx)", isLocal: false, microphoneOn: true, cameraOn: idx == 1)
        }
        adapter.pushRemoteState(
            participants: [NativeDesktopParticipant(id: "local", name: "Alex", isLocal: true)] + eightRemotes,
            videos: [
                NativeDesktopExternalVideo(id: "PA_1|TR_VC_abc", participantID: "remote-1", source: .camera, track: remoteCam1),
            ]
        )
        callView.view.layoutIfNeeded()
        controller.updateVideoDemand(appActive: true)
        let visibleSet = try XCTUnwrap(controller.lastDemand?.visibleParticipantIDs)
        XCTAssertFalse(visibleSet.isEmpty)
        XCTAssertFalse(visibleSet.contains("PA_1|TR_VC_abc"), "visibleParticipantIDs must contain participant IDs, not track IDs")
        XCTAssertTrue(visibleSet.contains("remote-1"))
    }

    func testRapidMicrophoneTogglesCoalesceWithoutConcurrentAdapterCalls() async throws {
        let h = makeModel()
        defer {
            h.model.workspaceAudio.systemCall.markEnded(reason: .remoteEnded)
            withExtendedLifetime(h.container) {}
        }

        let url = URL(string: "https://meeting.example.test/calls/rapid-mute?psw=secret")!
        h.model.receive(url: url)
        h.model.join()
        try await waitUntil { h.model.isInConference && !h.model.sessions.isEmpty }

        let controller = try XCTUnwrap(h.model.sessions.first)
        let adapter = try XCTUnwrap(h.adapters().first)
        adapter.setMicrophoneDelay = .milliseconds(30)

        // 10 rapid flips starting from false -> final state must be false, serialized (maxConcurrency == 1).
        for _ in 0..<10 {
            controller.toggleMicrophone()
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(adapter.maxConcurrentMicrophoneCalls, 1)
        XCTAssertFalse(controller.isMicrophoneOn)
        XCTAssertTrue(h.model.workspaceAudio.isMuted)

        let baselineCalls = adapter.microphoneCallCount
        // 9 rapid flips starting from false -> final state must be true without multiplying adapter calls.
        for _ in 0..<9 {
            controller.toggleMicrophone()
        }
        try await waitUntil { controller.isMicrophoneOn && adapter.snapshot.microphoneOn }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(adapter.maxConcurrentMicrophoneCalls, 1)
        XCTAssertLessThanOrEqual(adapter.microphoneCallCount - baselineCalls, 4)
        XCTAssertTrue(controller.isMicrophoneOn)
        XCTAssertFalse(h.model.workspaceAudio.isMuted)
    }

    func testHandoverJoinFromContinuationAlongsideActiveMeeting() async throws {
        let h = makeModel()
        defer {
            h.model.workspaceAudio.systemCall.markEnded(reason: .remoteEnded)
            withExtendedLifetime(h.container) {}
        }

        let firstURL = URL(string: "https://meeting.example.test/calls/first-room")!
        h.model.receive(url: firstURL)
        h.model.join()
        try await waitUntil { h.model.isInConference && h.model.sessions.count == 1 }

        // Ensure beginJoiningAnotherMeeting minimizes the foreground call and requests focus
        let triggerBefore = h.model.focusJoinLinkTrigger
        h.model.beginJoiningAnotherMeeting()
        XCTAssertTrue(h.model.isCallMinimized)
        XCTAssertNotEqual(h.model.focusJoinLinkTrigger, triggerBefore)

        // Joining a second meeting via continuation handover succeeds alongside the first meeting
        let secondJam = ActiveJam(
            deviceID: "mac-1",
            invitation: URL(string: "https://rock.glowsoft.ru/jams/test")!,
            title: "Second Handover Room",
            name: "Vi",
            deviceLabel: "MacBook Pro"
        )
        let joinedID = h.model.joinFromContinuation(secondJam, quiet: false)
        XCTAssertNotNil(joinedID)
        try await waitUntil { h.model.sessions.count == 2 && h.model.sessions.last?.phase == .connected }
        XCTAssertEqual(h.model.sessions.count, 2)
    }

    private static func findScrollView(id: String, in root: UIView) -> UIScrollView? {
        if let scroll = root as? UIScrollView, scroll.accessibilityIdentifier == id {
            return scroll
        }
        for subview in root.subviews {
            if let match = findScrollView(id: id, in: subview) {
                return match
            }
        }
        return nil
    }
}
