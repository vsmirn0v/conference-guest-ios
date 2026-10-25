import AppKit
import Combine
import ConferenceCore
import LiveKitWebRTC
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class NativeDesktopMeetingModel: ObservableObject {
    enum ViewMode: String, CaseIterable { case automatic = "Automatic", gallery = "Gallery", focused = "Focus", audioOnly = "Audio only" }
    enum Panel: String, CaseIterable { case participants = "Participants", conversation = "Conversation", studio = "Camera & sound", presenter = "Presenter" }
    let invitation: URL
    let kind: MeetingEngineKind
    let displayName: String
    let chat = ChatStore()
    let catchUp = CatchUpStore()
    let sessionID = UUID()
    @Published var title: String
    @Published private(set) var snapshot = NativeDesktopExternalSnapshot()
    @Published private(set) var videos: [NativeDesktopExternalVideo] = []
    @Published private(set) var localCamera: LKRTCVideoTrack?
    @Published private(set) var localShare: LKRTCVideoTrack?
    @Published private(set) var guestFeatures = GuestMeetingSnapshot()
    @Published var panel: Panel?
    @Published var viewMode: ViewMode = .automatic { didSet { updateDemand() } }
    @Published var pinnedID: String? { didSet { focusAffinity = nil; updateDemand() } }
    @Published private(set) var pinnedSource: NativeDesktopVideoSource?
    @Published var galleryPage = 0 { didSet { updateDemand() } }
    @Published var error: String?
    @Published private(set) var sharingPending = false
    @Published var controlsHidden = false
    @Published var floatingReactions: [MeetingReactionEvent] = []
    private var presenterStorage: NativeDesktopPresenterSession?
    var presenter: NativeDesktopPresenterSession {
        if let presenterStorage { return presenterStorage }
        let session = NativeDesktopPresenterSession(factory: { [weak self] in self?.engine.factory },
            liveCamera: { [weak self] in self?.localCamera },
            publish: { [weak self] track, profile in
                guard let self, !closed, !transferHeld, connected else { throw CancellationError() }
                guard await retireShare(waitForStartup: true) else { throw NativeDesktopRTCError.cleanupFailed }
                if let guest = engine as? NativeDesktopGuestEngine {
                    let preference = presenterStorage?.activeEncodingPreference ?? .efficient
                    try await guest.startScreenShare(profile: profile, codec: preference.codec) { NativeDesktopRelayCapture(track: track, source: $0) }
                    refreshShareEncodingReport(guest: guest, track: track)
                } else { try await engine.setScreenTrack(track) }
                guard !closed, !transferHeld else { throw CancellationError() }
                localShare = track
            }, unpublish: { [weak self] in
                guard let self else { return }
                if let guest = engine as? NativeDesktopGuestEngine { try await guest.stopScreenShare() }
                else { try await engine.setScreenTrack(nil) }
                localShare = nil
            })
        session.onDimensions = { [weak self] profile in
            guard let self, !closed, let guest = engine as? NativeDesktopGuestEngine else { return }
            do { try guest.currentNativeEngine?.updateScreenShareProfile(profile) }
            catch { self.error = error.localizedDescription }
        }
        session.objectWillChange.sink { [weak self] in self?.objectWillChange.send(); Task { @MainActor in self?.refreshSystemReactions() } }.store(in: &subscriptions)
        session.supportsVP9 = (engine as? NativeDesktopGuestEngine)?.currentNativeEngine?.screenCodecs.contains("video/vp9") == true
        session.vp9UnavailableReason = session.supportsVP9 ? nil : L("VP9 sharing is unavailable in this meeting.")
        presenterStorage = session; return session
    }
    private var shareReportTask: Task<Void, Never>?
    private func refreshShareEncodingReport(guest: NativeDesktopGuestEngine, track: LKRTCVideoTrack) {
        shareReportTask?.cancel()
        shareReportTask = Task { @MainActor [weak self, weak guest] in
            for _ in 0..<4 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, let guest, !closed, !Task.isCancelled,
                      localShare === track, engine === guest else { return }
                if let evidence = await guest.currentNativeEngine?.screenEncodingEvidence(),
                   !Task.isCancelled, localShare === track, engine === guest {
                    presenterStorage?.encodingReport = .measured(codec: evidence.codec, powerEfficient: evidence.powerEfficient, encoder: evidence.encoder)
                    return
                }
            }
        }
    }
    var onConnected: (() -> Void)?
    var onLeave: (() async -> Void)?
    private(set) var engine: any NativeDesktopMeetingEngine
    private var capture: NativeDesktopShareCapture?
    private var sharingTask: Task<Void, Never>?
    private var shareGeneration = UUID()
    private var stoppingShare: Task<Bool, Never>?
    private var shareCleanupSucceeded = true
    private var generation = UUID()
    private var everConnected = false
    private var closed = false
    private var leaveTask: Task<Bool, Never>?
    private var connection: GuestCompletion<Void>?
    private var shareSource: LKRTCVideoSource?
    private var telemostChat: TelemostChat?
    private var subscriptions = Set<AnyCancellable>()
    private var receivedReactions = Set<UUID>()
    private var reactionExpiry: Task<Void, Never>?
    private let reactionObserver = CameraReactionObserver()
    private var reactionDeviceLookup: Task<Void, Never>?
    private var reactionSourceKey: String?
    private let headset = NativeDesktopHeadsetMute()
    private var cameraLease: NativeDesktopCameraLease.Token?
    private var authorizedMicrophoneRequest: NativeDesktopHeadsetMute.Request?
    private var controlTasks: [UUID: Task<Void, Never>] = [:]
    private var controlTail: Task<Void, Never>?
    private var transferHeld = false
    private var holdConfirmed = false
    private var holdTask: Task<Void, Error>?
    private var focusAffinity: (participant: String, source: NativeDesktopVideoSource)?
    enum MediaPresentation { case meeting, floating, hidden }
    @Published private(set) var mediaPresentation: MediaPresentation = .meeting
    private var floatingParticipantID: String?
    private var demandKey: String?
    private var demandTask: Task<Void, Never>?
    private var heldState: (microphone: Bool, camera: Bool, playout: Bool)?
    private var requestedMicrophone: Bool?
    private var requestedCamera: Bool?
    private var requestedPlayout: Bool?
    private let quiet: Bool

    init(destination: JoinDestination, name: String, title: String?, quiet: Bool = false,
         engine makeEngine: (any NativeDesktopMeetingEngine)? = nil) {
        invitation = destination.invitationURL; kind = destination.engineKind; displayName = name; self.quiet = quiet
        self.title = title?.isEmpty == false ? title! : destination.roomIdentifier
        switch destination {
        case .guest: engine = makeEngine ?? NativeDesktopGuestEngine()
        case .telemost: engine = makeEngine ?? NativeDesktopTelemostEngine()
        case .trueconf: engine = makeEngine ?? NativeDesktopTrueConfEngine()
        case .jam: engine = makeEngine ?? NativeDesktopRockEngine(chat: chat)
        }
        reactionObserver.onReaction = { [weak self] kind, _ in self?.sendReaction(kind) }
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in
            Task { @MainActor in self?.refreshSystemReactions() }
        }.store(in: &subscriptions)
        chat.reactionHistory.beginMeeting(id: sessionID)
        catchUp.enter(roomKey: invitation.absoluteString)
        catchUp.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        chat.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        chat.reactionHistory.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        engine.onState = { [weak self] value in self?.update(value) }
        engine.onVideo = { [weak self] value in self?.videos = value; self?.updateDemand() }
        engine.onLocalCamera = { [weak self] track in self?.setLocalCamera(track) }
        engine.onTitle = { [weak self] title in if !title.isEmpty { self?.title = title } }
        if let guest = engine as? NativeDesktopGuestEngine {
            guest.onFeatureError = { [weak self] error in self?.error = error.localizedDescription }
            guest.onFeatures = { [weak self] features in self?.updateFeatures(features) }
            chat.onSend = { [weak self, weak guest] text in
                guard let self, let native = guest?.currentNativeEngine else { return }
                if self.chat.draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { self.chat.draft = "" }
                self.perform { _ in _ = try await native.sendChatMessage(text) }
            }
            chat.onRetry = { [weak self, weak guest] entry in
                guard let self, let native = guest?.currentNativeEngine else { return }
                self.perform { _ in
                    do { _ = try await native.sendChatMessage(entry.text) }
                    catch { self.chat.setDelivery(.failed, for: entry.id); throw error }
                }
            }
        } else if let telemost = engine as? NativeDesktopExternalSession, kind == .telemost {
            let transport = TelemostChat(store: chat); telemostChat = transport
            telemost.onTelemostChatContext = { [weak transport] url, id in transport?.start(invitation: url, roomID: id) }
        } else if kind == .trueconf {
            chat.unavailableReason = L("Chat is unavailable for this meeting service.")
        }
    }
    var connected: Bool { snapshot.phase == .connected }
    var canReact: Bool { connected && guestFeatures.permissions.canSendReaction }
    var transcript: [GuestMeetingMessage] { guestFeatures.transcript }
    var participants: [NativeDesktopParticipant] { snapshot.participants }
    var galleryParticipants: [NativeDesktopParticipant] { Array(participants.dropFirst(galleryPage * 6).prefix(6)) }
    var galleryPages: Int { max(1, Int(ceil(Double(participants.count) / 6))) }
    var focusedParticipantID: String? { focusedVideo?.participantID ?? focusAffinity?.participant ?? pinnedID }
    var focusedVideo: NativeDesktopExternalVideo? {
        if let pinnedID, participants.contains(where: { $0.id == pinnedID && $0.isLocal }) {
            if pinnedSource == .screen, let localShare { return .init(id: "local-screen", participantID: pinnedID, source: .screen, track: localShare) }
            if pinnedSource != .screen, let localCamera { return .init(id: "local-camera", participantID: pinnedID, source: .camera, track: localCamera) }
        }
        if let affinity = focusAffinity,
           let match = videos.first(where: { $0.participantID == affinity.participant && $0.source == affinity.source }) { return match }
        if focusAffinity != nil { return nil }
        if let pinnedID, let pinned = videos.first(where: { $0.id == pinnedID || $0.participantID == pinnedID }) { return pinned }
        return videos.first { $0.source == .screen } ?? videos.first { item in participants.first { $0.id == item.participantID }?.speaking == true } ?? videos.first
    }
    var showsFocus: Bool { viewMode == .focused || (viewMode == .automatic && (participants.contains { $0.sharing == true && !$0.isLocal } || videos.contains { $0.source == .screen } || focusAffinity?.source == .screen)) }
    var floatingVideo: NativeDesktopExternalVideo? {
        if showsFocus { return focusedVideo }
        return videos.first { $0.participantID == floatingParticipantID && $0.source == .screen }
            ?? videos.first { $0.participantID == floatingParticipantID }
    }
    func connect() async throws {
        let completion = GuestCompletion<Void>(); connection = completion
        headset.onError = { [weak self] failure in self?.error = failure.localizedDescription }
        let headsetReady = headset.begin { [weak self] muted in self?.setMicrophoneEnabled(!muted) }
        guard await NativeDesktopDeviceModel.stopPrivatePreview() else { throw NativeDesktopRTCError.cleanupFailed }
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await engine.connect(invitation: invitation, name: displayName, quiet: quiet)
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in completion.install(continuation, timeout: 45) }
        }, onCancel: { completion.finish(.failure(CancellationError())) })
        try Task.checkCancellation()
        if !headsetReady { _ = headset.useEngineOnlyFallback(confirmedMuted: !snapshot.microphoneOn) }
        if UserDefaults.standard.bool(forKey: "nativeDesktop.headsetMuteControls") { try await engine.prepareMutedCaptureForAccessories() }
    }
    private func update(_ value: NativeDesktopExternalSnapshot) {
        guard !closed else { return }
        let previous = snapshot; snapshot = value
        if let presenterStorage {
            presenterStorage.supportsVP9 = (engine as? NativeDesktopGuestEngine)?.currentNativeEngine?.screenCodecs.contains("video/vp9") == true
            presenterStorage.vp9UnavailableReason = presenterStorage.supportsVP9 ? nil : L("VP9 sharing is unavailable in this meeting.")
        }
        if value.phase == .connected { connection?.finish(.success(())) }
        if value.phase == .failed { connection?.finish(.failure(NativeDesktopError.unavailable(value.lastError ?? L("Could not connect to meeting.")))) }
        if !value.microphoneOn { headset.confirm(muted: true) }
        else if value.phase == .connected, let request = authorizedMicrophoneRequest {
            headset.confirm(muted: false, request: request)
        }
        if value.microphoneOn == requestedMicrophone { requestedMicrophone = nil }
        if value.cameraOn == requestedCamera { requestedCamera = nil }
        if value.playoutOn == requestedPlayout { requestedPlayout = nil }
        if value.phase == .connected && !everConnected { everConnected = true; onConnected?() }
        if previous.phase != .reconnecting && value.phase == .reconnecting { chat.reactionHistory.beginGap() }
        if previous.phase == .reconnecting && value.phase == .connected { chat.reactionHistory.endGap() }
        if previous.phase != .reconnecting && value.phase == .reconnecting { catchUp.begin(.connection); demandKey = nil }
        if previous.phase == .reconnecting && value.phase == .connected { catchUp.end(.connection) }
        if previous.playoutOn && !value.playoutOn { catchUp.begin(.audioInterruption) }
        if !previous.playoutOn && value.playoutOn { catchUp.end(.audioInterruption) }
        if value.phase == .connected, !value.participants.isEmpty, let affinity = focusAffinity {
            let participant = value.participants.first { $0.id == affinity.participant }
            if participant == nil || (affinity.source == .screen && participant?.sharing == false) {
                focusAffinity = nil
                if pinnedID == affinity.participant { unpin(); if viewMode == .focused { viewMode = .automatic } }
            }
        }
        updateDemand(); refreshSystemReactions()
        if galleryPage >= galleryPages { galleryPage = max(0, galleryPages - 1) }
        if value.phase == .failed { error = value.lastError ?? L("Meeting connection failed.") }
    }
    private func setLocalCamera(_ track: LKRTCVideoTrack?) {
        localCamera = track
        NativeDesktopCameraLease.shared.setLiveTrack(track, owner: sessionID)
        Task { [weak self] in await self?.presenterStorage?.refreshBorrowedCamera(); self?.refreshSystemReactions() }
    }
    func toggleMicrophone() { setMicrophoneEnabled(!(requestedMicrophone ?? snapshot.microphoneOn)) }
    private func setMicrophoneEnabled(_ enabled: Bool) {
        guard !transferHeld, !closed else { _ = headset.requestIntent(muted: true); return }
        requestedMicrophone = enabled
        if !enabled { authorizedMicrophoneRequest = nil }
        let request = headset.requestIntent(muted: !enabled), token = generation
        perform { engine in
            do {
                try await engine.setMicrophone(enabled)
                guard token == self.generation, !self.closed, !self.transferHeld else { return }
                self.authorizedMicrophoneRequest = enabled && engine.snapshot.microphoneOn ? request : nil
                self.headset.confirm(muted: !engine.snapshot.microphoneOn, request: request)
            } catch {
                if self.requestedMicrophone == enabled { self.requestedMicrophone = nil }
                if token == self.generation, !self.closed {
                    let closedRequest = self.headset.requestIntent(muted: true)
                    try? await engine.setMicrophone(false)
                    self.headset.confirm(muted: true, request: closedRequest)
                }
                throw error
            }
        }
    }
    func toggleCamera() {
        guard !transferHeld, !closed else { return }
        let enabled = !(requestedCamera ?? snapshot.cameraOn); requestedCamera = enabled
        perform { engine in
            do {
                if enabled {
                    self.cameraLease = try await NativeDesktopCameraLease.shared.acquireLive(owner: self.sessionID) { [weak self] in
                        guard let self else { return }; try await self.engine.setCamera(false)
                    }
                    try await self.presenterStorage?.releasePrivateCameraBeforeLiveCapture()
                }
                if enabled, !(await NativeDesktopDeviceModel.stopPrivatePreview()) { throw NativeDesktopRTCError.cleanupFailed }
                try await engine.setCamera(enabled)
                if !enabled, let lease = self.cameraLease { NativeDesktopCameraLease.shared.release(lease); self.cameraLease = nil }
                if enabled { await self.presenterStorage?.finishLiveCameraHandover() }
            } catch {
                if enabled { await self.presenterStorage?.finishLiveCameraHandover() }
                if let lease = self.cameraLease {
                    do { try await engine.setCamera(false); NativeDesktopCameraLease.shared.release(lease); self.cameraLease = nil }
                    catch { NativeDesktopCameraLease.shared.reportFailedStop(lease) }
                }
                if self.requestedCamera == enabled { self.requestedCamera = nil }; throw error
            }
        }
    }
    func togglePlayout() {
        guard !transferHeld, !closed else { return }
        let enabled = !(requestedPlayout ?? snapshot.playoutOn); requestedPlayout = enabled
        perform { engine in
            do { try await engine.setPlayout(enabled) }
            catch { if self.requestedPlayout == enabled { self.requestedPlayout = nil }; throw error }
        }
    }
    func reconnect() {
        authorizedMicrophoneRequest = nil; _ = headset.requestIntent(muted: true)
        perform { engine in
            guard await self.presenterStorage?.close() ?? true, await self.retireShare(waitForStartup: true) else { throw NativeDesktopRTCError.cleanupFailed }
            try await engine.setMicrophone(false)
            try await engine.setCamera(false)
            if let lease = self.cameraLease { NativeDesktopCameraLease.shared.release(lease); self.cameraLease = nil }
            try await engine.reconnect()
        }
    }
    private func perform(_ action: @escaping (any NativeDesktopMeetingEngine) async throws -> Void) {
        guard !closed, !transferHeld else { return }
        let token = generation, id = UUID(), previous = controlTail
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.controlTasks[id] = nil }
            guard token == generation, !closed, !Task.isCancelled else { return }
            do { try await action(engine) }
            catch { if token == generation, !closed, !(error is CancellationError) { self.error = error.localizedDescription } }
        }
        controlTasks[id] = task; controlTail = task
    }
    #if DEBUG
    func waitForMediaActionsForTesting() async { await controlTail?.value }
    #endif
    func setTransferHeld(_ held: Bool, restoreSending: Bool = true) async throws {
        if let holdTask { try await holdTask.value; if held { return } }
        guard !closed else { throw CancellationError() }
        if held {
            if transferHeld && holdConfirmed { return }
            transferHeld = true; holdConfirmed = false; authorizedMicrophoneRequest = nil; _ = headset.requestIntent(muted: true)
            let tasks = Array(controlTasks.values)
            let operation = Task { @MainActor in
                for task in tasks { await task.value }
                try Task.checkCancellation()
                guard !self.closed else { throw CancellationError() }
                if self.heldState == nil { self.heldState = (self.snapshot.microphoneOn, self.snapshot.cameraOn, self.snapshot.playoutOn) }
                try await self.engine.setMicrophone(false); try await self.engine.setCamera(false)
                if let presenter = self.presenterStorage, !(await presenter.close()) { throw NativeDesktopRTCError.cleanupFailed }
                guard await self.stopSharing() else { throw NativeDesktopRTCError.cleanupFailed }
                try await self.engine.setPlayout(false)
                self.holdConfirmed = true
            }
            holdTask = operation
            defer { holdTask = nil }
            try await operation.value
        } else if let state = heldState {
            guard holdConfirmed else { throw NativeDesktopRTCError.cleanupFailed }
            try await engine.setPlayout(state.playout)
            let microphone = restoreSending && state.microphone
            let request = headset.requestIntent(muted: !microphone)
            try await engine.setMicrophone(microphone)
            authorizedMicrophoneRequest = microphone && engine.snapshot.microphoneOn ? request : nil
            headset.confirm(muted: !engine.snapshot.microphoneOn, request: request)
            try await engine.setCamera(restoreSending && state.camera)
            if !(restoreSending && state.camera), let lease = cameraLease { NativeDesktopCameraLease.shared.release(lease); cameraLease = nil }
            heldState = nil; transferHeld = false; holdConfirmed = false
        }
    }
    func toggleSharing() {
        if snapshot.sharing || sharingPending { Task { await stopSharing() } }
        else { panel = .presenter }
    }
    func startSharing(presenter: Bool, canvas: Bool = false) {
        if presenter { panel = .presenter; Task { await self.presenter.open() }; return }
        guard !closed, !transferHeld, connected, !sharingPending, capture == nil, stoppingShare == nil, shareCleanupSucceeded else { return }
        sharingPending = true; let token = generation; shareGeneration = UUID(); let shareToken = shareGeneration
        sharingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if token == generation && shareToken == shareGeneration { sharingPending = false; sharingTask = nil } }
            do {
                if let presenter = presenterStorage, !(await presenter.close()) { throw NativeDesktopRTCError.cleanupFailed }
                let profile = GuestVideoProfile(width: 3840, height: 2160, fps: 30, maximumBitrate: 18_000_000)
                if let guest = engine as? NativeDesktopGuestEngine {
                    try await guest.startScreenShare(profile: profile) { [weak self] source in
                        let capture = NativeDesktopShareCapture(source: source, canvasOnly: canvas)
                        self?.configure(capture, token: token, shareToken: shareToken)
                        return capture
                    }
                    localShare = guest.currentNativeEngine?.localScreenTrack
                } else {
                    guard let factory = engine.factory else { throw NativeDesktopError.unavailable(L("Connect before sharing.")) }
                    let source = factory.videoSource(forScreenCast: true); shareSource = source
                    let capture = NativeDesktopShareCapture(source: source, canvasOnly: canvas)
                    configure(capture, token: token, shareToken: shareToken)
                    _ = try await capture.start()
                    guard token == generation, shareToken == shareGeneration, !closed else { throw CancellationError() }
                    let track = factory.videoTrack(with: source, trackId: UUID().uuidString)
                    try await engine.setScreenTrack(track); localShare = track
                }
                guard token == generation, shareToken == shareGeneration, !closed else { throw CancellationError() }
            } catch {
                let cancelled = Task.isCancelled
                if !cancelled { _ = await retireShare(waitForStartup: false) }
                if token == generation, !cancelled, !closed { self.error = error.localizedDescription }
            }
        }
    }
    private func configure(_ capture: NativeDesktopShareCapture, token: UUID, shareToken: UUID) {
        self.capture = capture
        capture.onDimensions = { [weak self] size in Task { @MainActor in
            guard let self, token == self.generation, shareToken == self.shareGeneration, !self.closed else { return }
            if let guest = self.engine as? NativeDesktopGuestEngine {
                try? guest.currentNativeEngine?.updateScreenShareProfile(.init(width: Int32(size.width), height: Int32(size.height), fps: 30, maximumBitrate: 18_000_000))
            }
        } }
        capture.onEnd = { [weak self] failure in Task { @MainActor in
            guard let self, token == self.generation, shareToken == self.shareGeneration else { return }
            await self.stopSharing(); if let failure { self.error = failure.localizedDescription }
        } }
    }
    @discardableResult func stopSharing() async -> Bool {
        do { try await presenterStorage?.stopSharing() }
        catch { self.error = error.localizedDescription; return false }
        return await retireShare(waitForStartup: true)
    }
    private func retireShare(waitForStartup: Bool) async -> Bool {
        if let stoppingShare { return await stoppingShare.value }
        guard capture != nil || sharingTask != nil || snapshot.sharing else { return shareCleanupSucceeded }
        shareGeneration = UUID()
        let startup = sharingTask; sharingTask = nil
        if waitForStartup { startup?.cancel() }
        let capture = capture; self.capture = nil
        capture?.cancel(); localShare = nil; shareSource = nil
        sharingPending = false
        let cleanup = Task { @MainActor [engine] () -> Bool in
            if waitForStartup { await startup?.value }
            var clean = true
            do {
                if let guest = engine as? NativeDesktopGuestEngine { try await guest.stopScreenShare() }
                else { try await engine.setScreenTrack(nil) }
            } catch { clean = false }
            do { try await capture?.stop() } catch { clean = false }
            return clean
        }
        stoppingShare = cleanup
        let clean = await cleanup.value
        stoppingShare = nil; shareCleanupSucceeded = clean
        if !clean { error = L("Screen capture could not stop cleanly. Leave the meeting before sharing again.") }
        return clean
    }
    private func updateFeatures(_ features: GuestMeetingSnapshot) {
        guard !closed else { return }; guestFeatures = features
        catchUp.observe(messages: features.transcript.map { TranscriptSegment(id: $0.id, speaker: $0.participantName, text: $0.text, spokenAt: $0.sentAt) }, canView: features.permissions.canViewTranscript, enabled: features.transcriptionStatus == .active)
        chat.reactionHistoryAvailable = features.permissions.canSendReaction
        chat.canSend = features.permissions.canSendChat && features.connected
        chat.unavailableReason = features.permissions.canViewChat ? nil : L("Chat is unavailable in this meeting.")
        chat.replace(features.messages.map { message in
            ChatEntry(id: message.id, sender: message.participantName, text: message.text,
                sentAt: message.sentAt ?? Date.distantPast, isOwn: message.isOwn,
                delivery: message.delivery == .pending ? .pending : message.delivery == .failed ? .failed : .sent)
        })
        for event in features.reactions where receivedReactions.insert(event.id).inserted {
            guard event.participantID != features.localParticipantID else { continue }
            if let kind = MeetingReaction.allCases.first(where: { $0.emoji == event.reaction.symbol }),
               let recorded = chat.reactionHistory.receive(kind: kind, participantID: event.participantID,
                    displayName: event.participantName, receivedAt: event.receivedAt) { floatReaction(recorded) }
        }
        if receivedReactions.count > 512 { receivedReactions = Set(features.reactions.map(\.id)) }
    }
    private func refreshSystemReactions() {
        let enabled = UserDefaults.standard.object(forKey: "nativeDesktop.shareCameraReactions") == nil || UserDefaults.standard.bool(forKey: "nativeDesktop.shareCameraReactions")
        let ordinary = snapshot.cameraOn && localCamera != nil
        let presenting = presenterStorage?.isSharing == true && presenterStorage?.includeCamera == true
        guard !closed, connected, enabled, ordinary || presenting else {
            reactionDeviceLookup?.cancel(); reactionSourceKey = nil; reactionObserver.stop(); return
        }
        let source = ordinary ? "camera" : "presenter"
        let key = source + ":" + String(describing: localCamera.map(ObjectIdentifier.init)) + ":" + String(presenterStorage?.cameraPreparing ?? false)
        guard key != reactionSourceKey else { return }
        reactionSourceKey = key; reactionDeviceLookup?.cancel()
        reactionDeviceLookup = Task { [weak self] in
            guard let self else { return }
            let device = ordinary ? await engine.cameraCaptureDevice() : await presenterStorage?.privateCameraDevice()
            guard !Task.isCancelled, !closed, reactionSourceKey == key else { return }
            if let device { reactionObserver.bind(device, sourceID: sessionID.uuidString + ":" + source) }
            else { reactionObserver.stop(); reactionSourceKey = nil }
        }
    }
    func sendReaction(_ kind: MeetingReaction) {
        guard let guest = engine as? NativeDesktopGuestEngine, canReact,
              let wire = GuestMeetingReaction.allCases.first(where: { $0.symbol == kind.emoji }) else { return }
        let id = UUID().uuidString
        if let recorded = chat.reactionHistory.recordLocalSubmission(kind: kind,
            participantID: guestFeatures.localParticipantID ?? "local", displayName: displayName, submissionID: id) { floatReaction(recorded) }
        Task {
            do { try await guest.currentNativeEngine?.sendReaction(wire) }
            catch { chat.reactionHistory.setLocalDelivery(.failed, submissionID: id); self.error = error.localizedDescription }
        }
    }
    private func floatReaction(_ event: MeetingReactionEvent) {
        floatingReactions.append(event); if floatingReactions.count > 4 { floatingReactions.removeFirst() }
        reactionExpiry?.cancel()
        reactionExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            self?.floatingReactions = []
        }
    }
    func loadMoreChat() { perform { if let guest = $0 as? NativeDesktopGuestEngine { try await guest.currentNativeEngine?.loadChatHistory() } } }
    func loadMoreTranscript() { perform { if let guest = $0 as? NativeDesktopGuestEngine { try await guest.currentNativeEngine?.loadTranscriptHistory() } } }
    func setTranscription(_ enabled: Bool) { perform { if let guest = $0 as? NativeDesktopGuestEngine { try await guest.currentNativeEngine?.setTranscriptionEnabled(enabled) } } }
    func focus(participantID: String, source: NativeDesktopVideoSource) {
        pinnedSource = source; pinnedID = participantID; viewMode = .focused
    }
    func unpin() { pinnedSource = nil; pinnedID = nil }
    func setMediaVisible(_ visible: Bool) { setMediaPresentation(visible ? .meeting : .hidden) }
    func setMediaPresentation(_ presentation: MediaPresentation) {
        guard mediaPresentation != presentation else { return }
        mediaPresentation = presentation; updateDemand()
    }
    func updateDemand() {
        guard !closed else { return }
        if let pinnedID {
            if let pinned = videos.first(where: { ($0.id == pinnedID || $0.participantID == pinnedID) && (pinnedSource == nil || $0.source == pinnedSource) }) {
                focusAffinity = (pinned.participantID, pinned.source)
            } else if focusAffinity?.participant != pinnedID { focusAffinity = (pinnedID, pinnedSource ?? .camera) }
        } else if viewMode != .gallery && viewMode != .audioOnly,
                  let screen = participants.first(where: { $0.sharing == true && !$0.isLocal }) { focusAffinity = (screen.id, .screen) }
        else if viewMode == .gallery || viewMode == .audioOnly { focusAffinity = nil }
        else if viewMode == .focused && (focusAffinity == nil || !participants.contains(where: { $0.id == focusAffinity?.participant })) {
            let camera = videos.first(where: { $0.source == .camera })?.participantID
                ?? participants.first(where: { !$0.isLocal && $0.cameraOn == true })?.id
                ?? participants.first(where: { !$0.isLocal })?.id
            focusAffinity = camera.map { ($0, .camera) }
        }
        let receivesVideo = mediaPresentation != .hidden && viewMode != .audioOnly
        let singleVideo = showsFocus || mediaPresentation == .floating
        if mediaPresentation == .floating && !showsFocus {
            // Track lists disappear while unsubscribed. Keep demand anchored to
            // roster identity so restoring the floating window can request it again.
            if !participants.contains(where: { $0.id == floatingParticipantID && !$0.isLocal }) {
                floatingParticipantID = participants.first(where: { !$0.isLocal && $0.sharing == true })?.id
                    ?? participants.first(where: { !$0.isLocal && $0.cameraOn == true })?.id
                    ?? participants.first(where: { !$0.isLocal })?.id
            }
        }
        let focused = receivesVideo && singleVideo ? (showsFocus ? focusedParticipantID : floatingParticipantID) : nil
        let ids = !receivesVideo ? Set<String>() : singleVideo ? Set([focused].compactMap { $0 }) : Set(galleryParticipants.map(\.id))
        let floatingScreen = mediaPresentation == .floating && !showsFocus && participants.contains { $0.id == focused && $0.sharing == true }
        let preferredScreen = receivesVideo && (focusAffinity?.source == .screen || floatingScreen) ? focused : nil
        let key = ids.sorted().joined(separator: "|") + "#" + (focused ?? "") + "#" + (preferredScreen ?? "")
        guard demandKey != key, connected else { return }
        demandKey = key; demandTask?.cancel()
        demandTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let guest = engine as? NativeDesktopGuestEngine {
                    try await guest.currentNativeEngine?.setVisibleParticipantIDs(ids, preferredScreenParticipantID: preferredScreen)
                } else { try await engine.setVisibleParticipantIDs(ids, focusedParticipantID: focused) }
            }
            catch { if !Task.isCancelled { demandKey = nil } }
        }
    }
    func leave() async -> Bool {
        if let leaveTask { return await leaveTask.value }
        closed = true; generation = UUID(); snapshot.phase = .leaving; headset.end()
        connection?.finish(.failure(CancellationError())); connection = nil
        let cleanup = Task { @MainActor in
            let controls = Array(self.controlTasks.values)
            controls.forEach { $0.cancel() }; self.holdTask?.cancel(); self.demandTask?.cancel()
            for task in controls { await task.value }
            _ = try? await self.holdTask?.value; await self.demandTask?.value
            self.reactionDeviceLookup?.cancel(); self.reactionObserver.stop()
            self.reactionExpiry?.cancel()
            let previewsStopped = await NativeDesktopDeviceModel.stopPrivatePreview()
            let presenterStopped = await self.presenterStorage?.close() ?? true
            let shareStopped = await self.stopSharing(); self.telemostChat?.stop()
            self.localCamera = nil; self.videos = []
            let engineStopped = await self.engine.leave(), clean = engineStopped && shareStopped && presenterStopped && previewsStopped
            if let lease = self.cameraLease {
                if engineStopped { NativeDesktopCameraLease.shared.release(lease); self.cameraLease = nil }
                else { NativeDesktopCameraLease.shared.reportFailedStop(lease) }
            }
            await self.catchUp.finishMeeting().value
            if clean { self.snapshot = .init(phase: .left, playoutOn: false) }
            else { self.snapshot.phase = .failed }
            self.engine.onState = nil; self.engine.onVideo = nil; self.engine.onLocalCamera = nil; self.engine.onTitle = nil
            return clean
        }
        leaveTask = cleanup
        return await cleanup.value
    }
}
