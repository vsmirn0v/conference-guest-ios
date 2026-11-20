import AppKit
import Combine
import ConferenceCore
import LiveKitWebRTC
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class NativeDesktopMeetingModel: ObservableObject {
    /// Layout only; what is received is `display`, shared with iOS.
    enum ViewMode: String, CaseIterable { case automatic = "Automatic", gallery = "Gallery", focused = "Focus" }
    enum Panel: String, CaseIterable { case participants = "Participants", conversation = "Conversation", studio = "Camera & sound", presenter = "Presenter", notes = "Notes" }
    struct ScheduledSegment: Equatable, Sendable {
        var sessionID: UUID
        var calendarEventID: String?
        var seriesID: String?
        var title: String
        var startedAt: Date
        var endedAt: Date?
        var explicitSplitChoice: Bool = false
    }

    struct SameRoomTransitionBanner: Equatable {
        var eventID: String
        var previousTitle: String
        var currentTitle: String
        var seriesID: String?
        var mode: SameRoomMeetingTransitionMode
        var transitionAt: Date
    }

    let invitation: URL
    let kind: MeetingEngineKind
    let displayName: String
    var resolvedEndpoint: URL?
    @Published private(set) var connectedSince: Date?
    let chat = ChatStore()
    let participation = ParticipationCoordinator()
    let catchUp = CatchUpStore()
    let sessionID = UUID()
    private let fallbackRoomTitle: String
    private(set) var scheduledTitle: String?
    private(set) var serverTitle: String?
    private(set) var userOverrodeTitle = false
    @Published var title: String {
        didSet { workspaceJournal?.rename(sessionID: workspaceSessionID, title: title) }
    }
    @Published private(set) var snapshot = NativeDesktopExternalSnapshot()
    @Published private(set) var videos: [NativeDesktopExternalVideo] = []
    @Published private(set) var localCamera: LKRTCVideoTrack?
    @Published private(set) var localShare: LKRTCVideoTrack?
    @Published private(set) var guestFeatures = GuestMeetingSnapshot()
    @Published var panel: Panel?
    /// Durable library and notes drafts, installed by the workspace when the model is created.
    var meetingLibrary: MeetingLibraryController?
    var notes: MeetingNotesController?
    var workspaceJournal: MeetingWorkspaceJournal? { meetingLibrary?.workspaceJournal }
    @Published private(set) var workspaceSessionID: UUID
    @Published private(set) var activeNoteSessionID: UUID
    @Published private(set) var pendingNoteRolloverTitle: String? = nil
    var segments: [ScheduledSegment]
    @Published var sameRoomTransitionBanner: SameRoomTransitionBanner? = nil
    private var workspaceCaptureGap: (id: String, reason: String, start: Date)?
    private var transcriptionDrains: [UUID: Task<Void, Never>] = [:]
    private var archivedLocalAttribution: [UUID: [String: String]] = [:]
    private var pendingWorkspaceObservations: [MeetingWorkspaceEvent] = []
    private var workspaceStartedAt: Date?
    private var workspaceSessionCreated = false
    private var approvedWorkspaceChatID: String?
    private var approvedWorkspaceChatPermits: [String: GuestChatDispatchPermit] = [:]
    private var approvedWorkspaceReactionID: String?
    private var approvedWorkspaceReactionTasks: [String: Task<Void, Never>] = [:]
    private(set) var workspaceSoundRevision = 0
    private var workspaceApprovedVoice: (cancel: () -> Void, drain: () async -> Void)?
    func approvedWorkspaceChatLink(id: String) -> String? {
        guard (engine as? MeetingSession)?.capabilities.supportsApprovedChatCorrelation == true else { return nil }
        return "chat:" + kind.rawValue + ":" + id
    }
    var canSpeakApprovedWorkspaceReply: Bool { supportsVoiceReply }
    var workspaceApprovedVoiceInProgress: Bool { workspaceApprovedVoice != nil }
    @Published var viewMode: ViewMode = .automatic { didSet { updateDemand() } }
    @Published var display: ConferenceDisplayMode = .all {
        didSet {
            if display == .audioOnly { cancelJoinCameraPrime() }
            focusAffinity = nil; updateDemand()
        }
    }
    /// "Screen shares" needs an engine that can subscribe screens without cameras.
    var availableDisplays: [ConferenceDisplayMode] {
        ConferenceDisplayMode.allCases.filter { $0 != .screenShares || engine.supportsScreenOnlyVideo }
    }
    var receivesCameras: Bool { display == .all }
    @Published var pinnedID: String? { didSet { focusAffinity = nil; updateDemand() } }
    @Published private(set) var pinnedSource: NativeDesktopVideoSource?
    @Published var galleryPage = 0 { didSet { updateDemand() } }
    private var errorRevision: UInt64 = 0
    @Published var error: String? {
        didSet {
            errorRevision &+= 1
            if let error, error != oldValue { probeLog("meeting-alert", ["message": error, "phase": String(describing: snapshot.phase)]) }
        }
    }

    /// SwiftUI may dismiss an alert while updating its view graph. Wait until
    /// the update finishes, and never dismiss a later error (even identical text).
    func dismissErrorAfterViewUpdate() {
        guard error != nil else { return }
        let revision = errorRevision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.errorRevision == revision, self.error != nil else { return }
            self.error = nil
        }
    }
    @Published private(set) var sharingPending = false
    @Published var controlsHidden = false
    @Published var floatingReactions: [MeetingReactionEvent] = []
    var presenter: NativeDesktopPresenterSession {
        captureCoordinator.presenter(
            engine: { [weak self] in self?.engine },
            liveCamera: { [weak self] in self?.localCamera },
            isConnected: { [weak self] in self?.connected == true },
            isTransferHeld: { [weak self] in self?.transferHeld == true },
            isClosed: { [weak self] in self?.closed == true },
            isSnapshotSharing: { [weak self] in self?.snapshot.sharing == true },
            localShare: { [weak self] in self?.localShare },
            setLocalShare: { [weak self] track in self?.localShare = track },
            setSharingPending: { [weak self] pending in self?.sharingPending = pending },
            onPresenterChange: { [weak self] in
                self?.objectWillChange.send()
                Task { @MainActor in
                    self?.refreshSystemReactions()
                    self?.noteShareState()
                }
            },
            onError: { [weak self] message in self?.error = message })
    }
    var onConnected: (() -> Void)?
    var onLeave: (() async -> Void)?
    /// Conversation panel tab: 0 Chat, 1 Live text, 2 Catch up.
    @Published var conversationTab = 0
    /// Content first: stage chrome fades until the pointer moves; Esc leaves.
    @Published var immersive = false
    /// When each participant was last heard, for the participant list.
    @Published private(set) var lastSpokeAt: [String: Date] = [:]
    /// When this app saw transcription turn on; the service does not say who started it.
    @Published private(set) var transcriptionSince: Date?
    enum TranscriptionIndicator { case on, local, failed }
    /// A failure is shown only to people who can restart transcription. Local
    /// transcription is shown when this Mac is producing the text the person can read.
    var transcriptionIndicator: TranscriptionIndicator? {
        if serverTranscriptHidden, localTranscriber != nil { return .local }
        switch guestFeatures.transcriptionStatus {
        case .active: return .on
        case .failed where guestFeatures.permissions.canManageTranscript: return .failed
        default: return localTranscriber != nil ? .local : nil
        }
    }
    /// Speech transcribed on this Mac while the meeting service does not transcribe.
    @Published private(set) var localTranscript: [GuestMeetingMessage] = []
    /// This meeting only: the person paused transcription on this Mac.
    @Published var localTranscriptionPaused = false { didSet { updateLocalTranscription() } }
    private var localTranscriber: MeetingTranscriber?
    private var localTranscriptionGeneration = UUID()
    private var participationAudioSources: [String: ParticipationRemoteAudioBinding] = [:]
    private var participationLocalTranscript: [ParticipationLocalTranscriptLine] = []
    let listenStore: ListenModelStore
    var transcribingLocally: Bool {
        #if DEBUG
        if localParticipationTranscribingForTesting { return true }
        #endif
        return localTranscriber != nil
    }
    /// The calendar series this meeting was joined from, for its Attention instructions.
    var calendarSeriesID: String?
    var participationCalendar: CalendarMeeting?
    /// Participant identity per transcribed audio source; nil for a mixed stream.
    private var audioIdentities: [String: String?] = [:]
    /// Who the service reported speaking, for lines from a mixed stream.
    private var speakingTimeline = SpeakingTimeline()
#if DEBUG
    func observeSpeakingForTesting(_ ids: Set<String>, at time: Date) { speakingTimeline.observe(speaking: ids, at: time) }
#endif

    /// The service reports transcription, but this participant cannot read that transcript.
    var serverTranscriptHidden: Bool {
        kind == .guest && guestFeatures.transcriptionStatus == .active && !guestFeatures.permissions.canViewTranscript
    }
    /// This meeting only. Declining the download must not start local transcription
    /// if a model arrives later from Settings.
    private var localFallbackDeclined = false
    private var localFallbackDownloadAccepted = false
    private var localModelsReady: Bool { listenStore.recognizerModel() != nil && listenStore.vadURL != nil }
    /// Installed models transcribe immediately. A missing model waits for an explicit download.
    enum LocalTranscriptFallbackPrompt: Equatable {
        case ask(Int64)
        case downloading(Double)
        case failed
    }
    var localTranscriptFallbackPrompt: LocalTranscriptFallbackPrompt? {
        guard serverTranscriptHidden, connected, !closed, !localTranscriptionPaused, !localFallbackDeclined,
              engine.supportsLocalTranscription, localTranscriber == nil, !localModelsReady,
              listenStore.selected != nil else { return nil }
        let relevant = [listenStore.selected, listenStore.catalog.vad].compactMap { $0 }
        if let progress = relevant.compactMap({ model -> Double? in
            if case .downloading(let value) = listenStore.state(model) { return value }
            return nil
        }).min() { return .downloading(progress) }
        if relevant.contains(where: { if case .failed = listenStore.state($0) { return true }; return false }) { return .failed }
        var bytes: Int64 = 0
        if let model = listenStore.selected, !listenStore.state(model).installed { bytes += model.size }
        if let vad = listenStore.catalog.vad, !listenStore.state(vad).installed { bytes += vad.size }
        return .ask(bytes)
    }
    var canRestartLocalTranscriptFallback: Bool {
        serverTranscriptHidden && connected && !closed && localFallbackDeclined && localTranscriber == nil && engine.supportsLocalTranscription
    }
    func acceptLocalTranscriptFallback() {
        localFallbackDeclined = false
        localFallbackDownloadAccepted = true
        guard let model = listenStore.selected else { return }
        listenStore.download(model)
        objectWillChange.send()
    }
    func declineLocalTranscriptFallback() {
        localFallbackDeclined = true
        if localFallbackDownloadAccepted {
            if let model = listenStore.selected, case .downloading = listenStore.state(model) { listenStore.cancel(model) }
            if let vad = listenStore.catalog.vad, case .downloading = listenStore.state(vad) { listenStore.cancel(vad) }
            localFallbackDownloadAccepted = false
        }
        objectWillChange.send()
    }
    func reconsiderLocalTranscriptFallback() {
        localFallbackDeclined = false
        updateLocalTranscription()
        objectWillChange.send()
    }
    /// Runs local transcription for a connected meeting when the model is installed,
    /// this meeting is not paused, and the person cannot read a service transcript.
    /// The Settings switch chooses Guest, Telemost, TrueConf, and Rock when the service
    /// is not transcribing. A hidden guest transcript still uses an installed model.
    var localTranscriptionAllowed: Bool {
        guard engine.supportsLocalTranscription else { return false }
        if serverTranscriptHidden { return localModelsReady && !localFallbackDeclined }
        guard listenStore.ready else { return false }
        switch kind {
        case .guest: return true
        case .community: return listenStore.transcribesRock
        case .telemost, .trueconf: return listenStore.transcribesExternal
        }
    }
    func updateLocalTranscription() {
        engine.setTranscriptionRequested(localTranscriptionAllowed)
        let serviceTranscriptReadable = guestFeatures.transcriptionStatus == .active && guestFeatures.permissions.canViewTranscript
        let wanted = !closed && connected && localTranscriptionAllowed && !localTranscriptionPaused && !serviceTranscriptReadable
        if wanted, localTranscriber == nil, let model = listenStore.recognizerModel(), let vad = listenStore.vadURL {
            LocalSpeechRecognizer.shared.acquire(model)   // loads before the first utterance
            let generation = UUID()
            localTranscriptionGeneration = generation
            let transcriber = MeetingTranscriber(model: model, vadModel: vad, onDropped: { [weak self] start, end in
                guard let self else { return }
                self.workspaceJournal?.recordGap(sessionID: self.workspaceSessionID, reason: "decode", from: start, until: end)
            }) { [weak self] line in
                self?.receiveLocalLine(line, generation: generation)
            }
            localTranscriber = transcriber
            engine.setTranscriptionAudioHandler { [weak self, weak transcriber] sources in
                guard let self, self.localTranscriptionGeneration == generation else { return }
                self.audioIdentities = Dictionary(sources.map { ($0.id, $0.participantIdentity) }, uniquingKeysWith: { first, _ in first })
                self.updateParticipationAudioSources(sources)
                transcriber?.update(sources)
            }
            engine.setLocalAudioSink { [weak transcriber] in transcriber?.feedLocal($0) }
            updateLocalMicrophoneCapture()
            let engine = engine
            Task { _ = await engine.setTranscriptionOutput(true) }
            probeLog("local-transcription-start", ["model": listenStore.selectedID, "soundOn": snapshot.playoutOn,
                "microphone": listenStore.includesMicrophone, "service": kind.rawValue,
                "reason": serverTranscriptHidden ? "serverTranscriptHidden" : "serviceTranscriptOff"])
            observeParticipation()
            objectWillChange.send()
        } else if !wanted, let transcriber = localTranscriber {
            localTranscriber = nil
            let generation = localTranscriptionGeneration
            let names = Dictionary(participants.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            archivedLocalAttribution[generation] = audioIdentities.compactMapValues { $0.flatMap { names[$0] } }
            localTranscriptionGeneration = UUID()
            participationAudioSources.removeAll()
            participationLocalTranscript.removeAll()
            engine.setTranscriptionAudioHandler(nil)
            engine.setLocalAudioSink(nil)
            transcriber.stop(flushing: workspaceJournal != nil)
            let drainID = UUID()
            if workspaceJournal != nil {
                transcriptionDrains[drainID] = Task { [weak self] in
                    await transcriber.waitForDelivery()
                    self?.transcriptionDrains[drainID] = nil
                    self?.archivedLocalAttribution[generation] = nil
                }
            } else {
                archivedLocalAttribution[generation] = nil
            }
            LocalSpeechRecognizer.shared.release()
            let summary = transcriber.currentSummary
            probeLog("local-transcription-stop", ["utterances": summary.utterances, "lines": summary.lines,
                "audioSeconds": summary.audioSeconds.rounded(), "decodeSeconds": summary.decodeSeconds.rounded(),
                "droppedSeconds": summary.droppedSeconds.rounded(), "micUtterances": summary.microphoneUtterances,
                "micSeconds": summary.microphoneSeconds.rounded()])
            if !closed { let engine = engine; Task { _ = await engine.setTranscriptionOutput(false) } }
            if !closed { observeTranscript(); observeParticipation() }
            objectWillChange.send()
        } else if wanted, localTranscriber != nil {
            updateLocalMicrophoneCapture()
        }
        updateWorkspaceCoverage()
    }
    /// Your microphone is transcribed only on confirmed state: the setting is on,
    /// this meeting holds the microphone and the engine confirmed it unmuted.
    var transcribesMicrophone: Bool {
        localTranscriber != nil && listenStore.includesMicrophone && ownsMicrophone && snapshot.microphoneOn && !voiceReplyActive && !assistantCaptureActive
    }
    private func updateLocalMicrophoneCapture() { localTranscriber?.setLocalCapture(transcribesMicrophone) }
    private func updateParticipationAudioSources(_ sources: [MeetingAudioSource]) {
        guard (engine as? MeetingSession)?.participationService != nil else { return }
        let previous = participationAudioSources, now = Date()
        participationAudioSources = Dictionary(grouping: sources, by: \.id).compactMapValues { matches in
            guard matches.count == 1, let source = matches.first else { return nil }
            if let binding = previous[source.id], binding.participantID == source.participantIdentity { return binding }
            return ParticipationRemoteAudioBinding(participantID: source.participantIdentity, since: now)
        }
    }

    private func receiveLocalLine(_ line: MeetingTranscriber.Line, live: Bool = true, archivedAuthor: String? = nil) {
        let observedAt = Date()
        func capture(_ message: GuestMeetingMessage) {
            observeWorkspace([
                .init(id: "transcript:local:" + message.id, kind: .transcript, occurredAt: line.start,
                    observedAt: observedAt, source: "local", author: message.participantName, text: line.text)
            ])
        }
        if line.trackID == MeetingTranscriber.localTrackID {
            let own = participants.first { $0.isLocal }?.id ?? line.trackID
            let message = GuestMeetingMessage(id: line.id, participantID: own, participantName: displayName,
                text: line.text, sentAt: line.start, isOwn: true, receivedAt: line.end)
            capture(message)
            guard live, !closed else { return }
            localTranscript.append(message)
            if localTranscript.count > 1000 { localTranscript.removeFirst(localTranscript.count - 1000) }
            observeTranscript(); return
        }
        // A per-participant track names its speaker; a mixed one is matched to
        // whoever the service said was speaking at the time.
        let identity = live ? audioIdentities[line.trackID].flatMap { $0 } ??
            speakingTimeline.speaker(start: line.start, end: line.end) : nil
        let name = archivedAuthor ?? participants.first { $0.id == identity }?.name ?? L("Participant")
        let message = GuestMeetingMessage(id: line.id, participantID: identity ?? line.trackID, participantName: name,
            text: line.text, sentAt: line.start, isOwn: false, receivedAt: line.end)
        capture(message)
        guard live, !closed else { return }
        localTranscript.append(message)
        if localTranscript.count > 1000 { localTranscript.removeFirst(localTranscript.count - 1000) }
        observeTranscript()
        if participation.status == .observing, participationTranscriptSource == .localRoomAudio {
            guard let projected = ParticipationLocalTranscriptLine(line: line, receiver: participationAudioSources) else {
                probeLog("participation-local-transcript", ["result": "receiver-scope-rejected"])
                return
            }
            participationLocalTranscript.append(projected)
            if participationLocalTranscript.count > 40 { participationLocalTranscript.removeFirst() }
            observeParticipation()
        }
    }

    private func receiveLocalLine(_ line: MeetingTranscriber.Line, generation: UUID) {
        receiveLocalLine(line, live: localTranscriptionGeneration == generation,
                         archivedAuthor: archivedLocalAttribution[generation]?[line.trackID])
    }

    private func captureGuestMessages(_ messages: [GuestMeetingMessage], transcript: Bool) {
        let now = Date()
        let captured = messages.map { message -> MeetingWorkspaceEvent in
            let occurredAt = transcript ? Self.spokenAt(message) : (message.sentAt ?? message.receivedAt)
            let authoredTime = message.sentAt != nil && message.sentAt == occurredAt
            let delivery: MeetingWorkspaceEvent.Status = switch message.delivery {
            case .pending: .sending
            case .sent: message.locallyAcknowledged ? .accepted : .sent
            case .failed: .failed
            }
            return .init(id: (transcript ? "transcript:guest:" : "chat:guest:") + message.id,
                kind: transcript ? .transcript : .chat, occurredAt: occurredAt ?? now, observedAt: now,
                source: transcript ? "service" : "guest", author: message.participantName,
                text: message.text, status: transcript ? nil : delivery, timeIsObserved: !authoredTime)
        }
        observeWorkspace(captured)
        if !transcript {
            for (message, event) in zip(messages, captured) where message.isOwn {
                guard let status = event.status else { continue }
                workspaceJournal?.observeApprovedChat(sessionID: workspaceSessionID, chatID: event.id, status: status)
            }
        }
    }

    private func ensureWorkspaceSession() {
        guard !workspaceSessionCreated, let workspaceJournal, let workspaceStartedAt else { return }
        workspaceJournal.begin(sessionID: workspaceSessionID, title: title, calendarSeriesID: calendarSeriesID,
            roomIdentity: MeetingRoomIdentity(invitation, engine: kind)?.displayDetails,
            roomRuleKey: MeetingWorkspaceGuidance.roomKey(for: self), at: workspaceStartedAt)
        workspaceSessionCreated = workspaceJournal.session(id: workspaceSessionID) != nil
    }

    private func observeWorkspace(_ events: [MeetingWorkspaceEvent]) {
        guard let workspaceJournal else { return }
        ensureWorkspaceSession()
        guard workspaceJournal.session(id: workspaceSessionID) != nil else {
            if !closed { pendingWorkspaceObservations += events }
            return
        }
        let all = pendingWorkspaceObservations + events
        pendingWorkspaceObservations.removeAll()
        workspaceJournal.observe(sessionID: workspaceSessionID, events: all)
    }

    private func updateWorkspaceCoverage(at: Date = .now) {
        guard let workspaceJournal, workspaceJournal.session(id: workspaceSessionID) != nil else { return }
        let reason: String?
        if closed { reason = nil }
        else if !connected { reason = "connection" }
        else if guestFeatures.transcriptionStatus == .active && guestFeatures.permissions.canViewTranscript || transcribingLocally { reason = nil }
        else if guestFeatures.transcriptionStatus == .failed { reason = "transcriptionFailed" }
        else if localTranscriptionPaused { reason = "transcriptionPaused" }
        else { reason = "transcriptionUnavailable" }
        if let existing = workspaceCaptureGap, existing.reason != reason {
            workspaceJournal.recordGap(sessionID: workspaceSessionID, id: existing.id, reason: existing.reason,
                                       from: existing.start, until: at)
            workspaceCaptureGap = nil
        }
        if let reason, workspaceCaptureGap == nil {
            let id = UUID().uuidString
            workspaceCaptureGap = (id, reason, at)
            workspaceJournal.recordGap(sessionID: workspaceSessionID, id: id, reason: reason, from: at)
        }
    }

    func applyScheduledTitle(_ newTitle: String?, seriesID: String?, calendarMeeting: CalendarMeeting?) {
        let clean = newTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        scheduledTitle = clean?.isEmpty == false ? clean : nil
        calendarSeriesID = seriesID
        participationCalendar = calendarMeeting
        if !userOverrodeTitle {
            title = scheduledTitle ?? serverTitle ?? fallbackRoomTitle
        }
    }

    func rolloverWorkspaceSession(to newSessionID: UUID, title newTitle: String, seriesID: String?,
                                  calendarMeeting: CalendarMeeting?, at boundary: Date, protectActiveNote: Bool) {
        if let existing = workspaceCaptureGap {
            workspaceJournal?.recordGap(sessionID: workspaceSessionID, id: existing.id, reason: existing.reason,
                                       from: existing.start, until: boundary)
            workspaceCaptureGap = nil
        }
        observeWorkspace([])
        workspaceJournal?.end(sessionID: workspaceSessionID, at: boundary)
        workspaceSessionID = newSessionID
        workspaceStartedAt = boundary
        workspaceSessionCreated = false
        applyScheduledTitle(newTitle, seriesID: seriesID, calendarMeeting: calendarMeeting)
        ensureWorkspaceSession()
        updateWorkspaceCoverage(at: boundary)
        if protectActiveNote {
            pendingNoteRolloverTitle = newTitle
        } else {
            activeNoteSessionID = newSessionID
            pendingNoteRolloverTitle = nil
        }
    }

    func switchLiveNoteToCurrentSession() {
        activeNoteSessionID = workspaceSessionID
        pendingNoteRolloverTitle = nil
    }

    func mergeWorkspaceSessionBack(into parentSessionID: UUID, title combinedTitle: String,
                                   seriesID: String?, calendarMeeting: CalendarMeeting?, at now: Date) {
        if let existing = workspaceCaptureGap {
            workspaceJournal?.recordGap(sessionID: workspaceSessionID, id: existing.id, reason: existing.reason,
                                       from: existing.start, until: now)
            workspaceCaptureGap = nil
        }
        observeWorkspace([])
        let childID = workspaceSessionID
        workspaceJournal?.mergeAndDelete(from: childID, into: parentSessionID, at: now)
        workspaceSessionID = parentSessionID
        workspaceSessionCreated = workspaceJournal?.session(id: parentSessionID) != nil
        activeNoteSessionID = parentSessionID
        pendingNoteRolloverTitle = nil
        applyScheduledTitle(combinedTitle, seriesID: seriesID, calendarMeeting: calendarMeeting)
        updateWorkspaceCoverage(at: now)
    }

    func noteUserRenamedSession(_ manualTitle: String) {
        let clean = manualTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        userOverrodeTitle = true
        title = clean
    }

    func withApprovedWorkspaceChat<T>(id: String, _ action: () -> T) -> T {
        let chatService = (engine as? MeetingSession)?.chatService
        chatService?.setApprovedWorkspaceChatID(id)
        approvedWorkspaceChatID = id
        defer { approvedWorkspaceChatID = nil; chatService?.setApprovedWorkspaceChatID(nil) }
        return action()
    }

    var canCorrelateApprovedWorkspaceReaction: Bool {
        (engine as? MeetingSession)?.reactionService?.supportsApprovedCorrelation == true
    }

    func withApprovedWorkspaceReaction(id: String, _ action: () -> Void) {
        approvedWorkspaceReactionID = id
        defer { approvedWorkspaceReactionID = nil }
        action()
    }
    /// Service and local text form one timeline for Live text and Catch up.
    private func observeTranscript() {
        catchUp.observe(messages: transcript.map { TranscriptSegment(id: $0.id, speaker: $0.participantName, text: $0.text, spokenAt: Self.spokenAt($0)) },
            canView: guestFeatures.permissions.canViewTranscript || !localTranscript.isEmpty || transcribingLocally,
            enabled: guestFeatures.transcriptionStatus == .active || transcribingLocally)
    }
    private func observeParticipation() {
        if !participationVoiceEligible || participationRemoteSpeaking { participation.interruptVoice() }
        if participationSomeoneSpeaking { participation.cancelPendingDispatch() }
        participation.observe(guestFeatures, transcriptSource: participationTranscriptSource,
                              localTranscript: participationLocalTranscript)
    }
#if DEBUG
    func receiveLocalLineForTesting(_ line: MeetingTranscriber.Line) { receiveLocalLine(line) }
    private var localParticipationTranscribingForTesting = false
    var participationAudienceForTesting: ParticipationAudience?
    var participationVoiceAvailableForTesting: Bool?

    func setParticipationLocalReceiverForTesting(_ receiver: [String: ParticipationRemoteAudioBinding]) -> UUID {
        localTranscriptionGeneration = UUID()
        localParticipationTranscribingForTesting = true
        participationAudioSources = receiver
        return localTranscriptionGeneration
    }

    func receiveParticipationLocalLineForTesting(_ line: MeetingTranscriber.Line, generation: UUID) {
        receiveLocalLine(line, generation: generation)
    }
#endif
    func showLiveText() { conversationTab = 1; panel = .conversation }
    /// The sound-off period offered for catch-up after sound returns.
    @Published private(set) var catchUpOffer: UUID?
    /// The Catch up tab scrolls to this period once.
    @Published var catchUpFocus: UUID?
    /// Sound is off while the service transcribes: what is said is kept for catch-up.
    var soundOffSavingText: Bool { connected && !snapshot.playoutOn && (transcriptionIndicator == .on || transcriptionIndicator == .local) }
    /// When a line of live text was spoken: the provider's time when it agrees with
    /// when the line arrived here (within 10 minutes), else the arrival time.
    nonisolated static func spokenAt(_ message: GuestMeetingMessage) -> Date? {
        guard let received = message.receivedAt else { return message.sentAt }
        guard let sent = message.sentAt, abs(sent.timeIntervalSince(received)) <= 600 else { return received }
        return sent
    }
    enum LiveTextRow: Identifiable {
        case line(GuestMeetingMessage, Date?)
        case reaction(MeetingReactionEvent)
        var id: String { switch self { case .line(let item, _): "line-" + item.id; case .reaction(let item): "reaction-" + item.id } }
    }
    /// Live text in spoken order with reactions placed among the lines. A line
    /// without any time keeps its place after the line before it.
    func liveTextRows(limit: Int = 1000) -> [LiveTextRow] {
        var rows: [(Date, Int, LiveTextRow)] = [], last = Date.distantPast, order = 0
        for line in transcript.suffix(limit) {
            let time = Self.spokenAt(line); last = time ?? last
            rows.append((last, order, .line(line, time))); order += 1
        }
        if let first = rows.first?.0 {
            for event in chat.reactionHistory.events where event.timestamp >= first {
                rows.append((event.timestamp, order, .reaction(event))); order += 1
            }
        } else {
            for event in chat.reactionHistory.events { rows.append((event.timestamp, order, .reaction(event))); order += 1 }
        }
        return rows.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map(\.2)
    }
    func catchUpReactions(_ interval: MissedInterval, now: Date = Date()) -> [MeetingReactionEvent] {
        let end = interval.end ?? now
        return chat.reactionHistory.events.filter { $0.timestamp >= interval.start && $0.timestamp <= end }
    }
    func catchUpInterval(_ id: UUID) -> MissedInterval? { catchUp.timeline.intervals.first { $0.id == id } }
    func catchUpLines(_ id: UUID) -> [TranscriptSegment] {
        catchUpInterval(id).map { catchUp.timeline.transcript(during: $0) } ?? []
    }
    func showCatchUp(_ id: UUID) { conversationTab = 2; panel = .conversation; catchUpFocus = id; catchUpOffer = nil }
    func dismissCatchUpOffer() { catchUpOffer = nil }
    /// Offered when the period that just closed was a sound-off one with live text,
    /// or a long one while transcription was on (so "nothing was said" is known).
    private func offerCatchUpForSoundReturn(now: Date = Date()) {
        guard let interval = catchUp.timeline.intervals.last, interval.reasons.contains(.audioInterruption),
              let end = interval.end, now.timeIntervalSince(end) < 2 else { return }
        let lines = catchUp.timeline.transcript(during: interval, now: now)
        if !lines.isEmpty || (catchUp.transcriptionEnabled && end.timeIntervalSince(interval.start) >= 10) {
            catchUpOffer = interval.id
        }
    }
    private func noteTranscription(from previous: GuestMeetingSnapshot.TranscriptionStatus, to status: GuestMeetingSnapshot.TranscriptionStatus) {
        guard previous != status else { return }
        if status == .active && guestFeatures.permissions.canViewTranscript {
            transcriptionSince = Date()
        } else if previous == .active {
            transcriptionSince = nil
        }
    }
    /// The organizer ended the meeting: the shell leaves it and says so instead of reporting an error.
    var onEndedByOrganizer: (() -> Void)?
    private var endedByOrganizer = false
    /// Click-to-live time of a microphone move between meetings, for diagnostics.
    private var handoverStartedAt: TimeInterval?
    /// Release and assume times of the move into this meeting, from the workspace.
    private var handoverPhases: (from: String?, release: Double?, assume: Double?)?
    func noteHandoverPhases(from: String?, releaseMilliseconds: Double?, assumeMilliseconds: Double?) {
        handoverPhases = (from, releaseMilliseconds, assumeMilliseconds)
    }
    private func logHandover(started: TimeInterval, live: Bool, steps: [String: Double]) {
        let record = TalkHandoverRecord(from: handoverPhases?.from, to: kind.rawValue,
            releaseMilliseconds: handoverPhases?.release, assumeMilliseconds: handoverPhases?.assume,
            totalMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000, steps: steps,
            keptWarm: keepMicrophoneWarm(), live: live)
        lastHandover = record
        probeLog("talk-handover", record.fields)
    }
    private(set) var lastHandover: TalkHandoverRecord?
    static let keepMicrophoneWarmKey = "nativeDesktop.keepMicrophoneWarm"
    /// Experimental: a meeting losing the talk role keeps its device running, muted.
    var keepMicrophoneWarm: () -> Bool = { UserDefaults.standard.bool(forKey: NativeDesktopMeetingModel.keepMicrophoneWarmKey) }
    /// With the warm microphone chosen, a meeting joined without the talk role
    /// starts its device muted once connected, so the first move here is as fast
    /// as later ones. Nothing is sent: unmuting still needs the talk role.
    private func prewarmMicrophoneIfChosen() {
        guard keepMicrophoneWarm(), !ownsMicrophone, !closed, !transferHeld else { return }
        let engine = engine, kind = kind.rawValue
        Task { @MainActor in
            let started = ProcessInfo.processInfo.systemUptime
            let warm = await engine.prewarmInput()
            probeLog("microphone-prewarm", ["meeting": kind, "warm": warm,
                "ms": ((ProcessInfo.processInfo.systemUptime - started) * 10_000).rounded() / 10])
        }
    }

    // MARK: Voice replies

    enum VoiceReplyError: LocalizedError, Equatable {
        case unavailable, notTalkMeeting, gate, microphone, playback, interrupted, mute, playedMute, sample
        var errorDescription: String? {
            switch self {
            case .unavailable: L("Voice replies are not available in this meeting.")
            case .notTalkMeeting: L("Your microphone could not move to this meeting for the reply.")
            case .gate: L("Your microphone could not be held back for the reply. Nothing was sent.")
            case .microphone: L("The meeting did not accept the voice reply.")
            case .playback: L("The voice reply could not be played into the meeting.")
            case .interrupted: L("Speech interrupted")
            case .mute, .playedMute: L("The microphone could not be muted again after the reply. Mute it now.")
            case .sample: L("The system voice could not create the test reply.")
            }
        }
    }
    /// A reply is being played into this meeting; your own microphone is held back.
    @Published private(set) var voiceReplyActive = false
    /// Push-to-talk captures locally while the meeting's send gate is closed.
    @Published private(set) var assistantCaptureActive = false
    /// The mute after a reply was not confirmed, so the gate stays closed until it is.
    private var voiceReplyGateHeld = false
    private var voicePrivacyConnection: MeetingConnectionIdentity?
    /// What you chose with the microphone button during a reply; it wins afterwards.
    private var voiceReplyUserChoice: Bool?
    var supportsVoiceReply: Bool { connected && engine.supportsVoiceReply }

    /// Closes only the meeting send gate; Assistant uses a separate AVAudioEngine tap
    /// whose samples go to LocalSpeechRecognizer and never into the meeting graph.
    func holdMicrophoneForAssistant() async -> Bool {
        await participation.stopVoiceAndWait()
        guard !assistantCaptureActive, !voiceReplyActive, connected, !closed, !transferHeld,
              microphoneRestriction == nil else { return false }
        if !ownsMicrophone {
            guard let arbiter = microphoneArbiter, await arbiter(self), ownsMicrophone else { return false }
        }
        assistantCaptureActive = true; updateLocalMicrophoneCapture()
        guard await engine.setMicrophoneGate(open: false), engine.voiceMicrophoneGateIsClosed else {
            assistantCaptureActive = false; updateLocalMicrophoneCapture()
            if !voiceReplyGateHeld { _ = await engine.setMicrophoneGate(open: true) }
            return false
        }
        return true
    }

    /// Idempotent release for key-up, cancellation, window loss and capture errors.
    func releaseMicrophoneForAssistant() async {
        guard assistantCaptureActive else { return }
        assistantCaptureActive = false; updateLocalMicrophoneCapture()
        if !voiceReplyActive && !voiceReplyGateHeld { _ = await engine.setMicrophoneGate(open: true) }
    }

    /// Plays `buffer` into this meeting with your microphone held back:
    /// the gate closes before anything unmutes, and reopens only once the
    /// meeting is muted again (or was live before the reply).
    func speak(_ buffer: AVAudioPCMBuffer) async throws {
        await participation.stopVoiceAndWait()
        try Task.checkCancellation()
        guard supportsVoiceReply, !voiceReplyActive, !assistantCaptureActive, !closed, !transferHeld,
              participationMeetingSoundOn else { throw VoiceReplyError.unavailable }
        if !ownsMicrophone {
            try Task.checkCancellation()
            guard participationMeetingSoundOn, !closed else { throw VoiceReplyError.unavailable }
            voiceReplyActive = true; voiceReplyUserChoice = nil; updateLocalMicrophoneCapture()
            defer { voiceReplyActive = false; voiceReplyUserChoice = nil; updateLocalMicrophoneCapture() }
            probeLog("voice-reply-start", [
                "service": kind.rawValue,
                "seconds": Double(buffer.frameLength) / buffer.format.sampleRate,
                "wasLive": false,
                "nonTalk": true,
            ])
            participation.beginVoiceEchoWindow()
            let played = await engine.playVoiceReply(buffer)
            participation.endVoiceEchoWindow()
            probeLog("voice-reply-end", ["service": kind.rawValue, "played": played, "nonTalk": true])
            guard played else { throw Task.isCancelled ? VoiceReplyError.interrupted : VoiceReplyError.playback }
            return
        }
        try Task.checkCancellation()
        guard participationMeetingSoundOn, ownsMicrophone, !closed else { throw VoiceReplyError.unavailable }
        voiceReplyActive = true; voiceReplyUserChoice = nil; updateLocalMicrophoneCapture()
        defer { voiceReplyActive = false; voiceReplyUserChoice = nil; updateLocalMicrophoneCapture() }
        let wasLive = snapshot.microphoneOn
        probeLog("voice-reply-start", ["service": kind.rawValue, "seconds": Double(buffer.frameLength) / buffer.format.sampleRate, "wasLive": wasLive])
        guard await engine.setMicrophoneGate(open: false) else {
            if !voiceReplyGateHeld { _ = await engine.setMicrophoneGate(open: true) }
            throw VoiceReplyError.gate
        }
        // The gate's volume ramps down; let it reach silence before anything unmutes.
        do {
            try await Task.sleep(for: .milliseconds(GuestVoiceReplyGraph.gateSettleMilliseconds))
            guard participationMeetingSoundOn, ownsMicrophone, !closed else { throw CancellationError() }
            guard engine.voiceMicrophoneGateIsClosed else { throw VoiceReplyError.gate }
        } catch {
            try await finishVoiceReply(wasLive: wasLive)
            throw error
        }
        if !wasLive {
            setMicrophoneEnabled(true); await microphoneControl?.value
            guard snapshot.microphoneOn else { try await finishVoiceReply(wasLive: false); throw VoiceReplyError.microphone }
        }
        guard !Task.isCancelled, participationMeetingSoundOn, ownsMicrophone, !closed else {
            try await finishVoiceReply(wasLive: wasLive)
            throw CancellationError()
        }
        guard engine.voiceMicrophoneGateIsClosed else {
            try await finishVoiceReply(wasLive: wasLive)
            throw VoiceReplyError.gate
        }
        participation.beginVoiceEchoWindow()
        let played = await engine.playVoiceReply(buffer)
        participation.endVoiceEchoWindow()
        do { try await finishVoiceReply(wasLive: wasLive) }
        catch {
            if played, workspaceApprovedVoice != nil { throw VoiceReplyError.playedMute }
            throw error
        }
        probeLog("voice-reply-end", ["service": kind.rawValue, "played": played])
        guard played else { throw Task.isCancelled ? VoiceReplyError.interrupted : VoiceReplyError.playback }
    }

    func startWorkspaceApprovedVoice<Result: Sendable>(_ action: @escaping @MainActor () async -> Result) -> Task<Result, Never>? {
        guard workspaceApprovedVoice == nil, !closed else { return nil }
        let task = Task { @MainActor [weak self] in
            defer { self?.workspaceApprovedVoice = nil }
            return await action()
        }
        workspaceApprovedVoice = (cancel: { task.cancel() }, drain: { _ = await task.value })
        return task
    }

    func cancelWorkspaceApprovedOutputs() {
        workspaceApprovedVoice?.cancel()
        (engine as? MeetingSession)?.chatService?.cancelApprovedOutputs()
        for task in approvedWorkspaceReactionTasks.values { task.cancel() }
        for (id, permit) in approvedWorkspaceChatPermits {
            permit.cancel()
            if !permit.didDispatch {
                workspaceJournal?.observeApprovedChat(sessionID: workspaceSessionID, chatID: "chat:guest:" + id, status: .cancelled)
            }
        }
    }
    private func finishVoiceReply(wasLive: Bool) async throws {
        if let choice = voiceReplyUserChoice {
            // You pressed the microphone button during the reply: keep that state.
            if !choice && snapshot.microphoneOn {
                setMicrophoneEnabled(false); await microphoneControl?.value
            }
            if choice || !snapshot.microphoneOn { _ = await engine.setMicrophoneGate(open: true) }
            else { voiceReplyGateHeld = true }
            return
        }
        if !wasLive {
            setMicrophoneEnabled(false); await microphoneControl?.value
            guard !snapshot.microphoneOn else { voiceReplyGateHeld = true; throw VoiceReplyError.mute }
        }
        _ = await engine.setMicrophoneGate(open: true)
    }
    /// The workspace installs the same configured synthesizer used by Assistant replies.
    /// Standalone meeting fixtures retain the system voice as their default.
    var synthesizeVoiceReply: (String) async throws -> AVAudioPCMBuffer = { try await VoiceSynthesis.system($0) }
    /// Speaks a short sentence with the selected voice into this meeting.
    func playTestVoiceReply() {
        guard participationMeetingSoundOn, canSpeakApprovedWorkspaceReply else {
            error = VoiceReplyError.unavailable.localizedDescription
            return
        }
        startWorkspaceApprovedVoice { [weak self] in
            guard let self else { return }
            do {
                let buffer = try await synthesizeVoiceReply(L("This is a test voice reply from Rock'N'Roll for Mac."))
                try await speak(buffer)
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
        }
    }
#if DEBUG
    func setMicrophoneForTesting(_ enabled: Bool) async { setMicrophoneEnabled(enabled); await microphoneControl?.value }
#endif
    private(set) var engine: any NativeDesktopMeetingEngine
    private let captureCoordinator: MeetingCaptureCoordinator
    private let usesInjectedSharedMedia: Bool
    private var generation = UUID()
    private var everConnected = false
    private var closed = false
    private var leaveTask: Task<Bool, Never>?
    private var connection: GuestCompletion<Void>?
    private var connectionTask: Task<Void, Error>?
    private let joinTimeout: TimeInterval
    private var subscriptions = Set<AnyCancellable>()
    private var receivedReactions = Set<UUID>()
    private var reactionExpiry: Task<Void, Never>?
    private let reactionObserver = CameraReactionObserver()
    private var reactionDeviceLookup: Task<Void, Never>?
    private var reactionSourceKey: String?
    private let headset = NativeDesktopHeadsetMute()
    private var authorizedMicrophoneRequest: NativeDesktopHeadsetMute.Request?
    private var controlTasks: [UUID: Task<Void, Never>] = [:]
    private var controlTail: Task<Void, Never>?
    private var microphoneControl: Task<Void, Never>?
    private var cameraControl: Task<Void, Never>?
    private var microphoneCommand = UUID()
    private var cameraCommand = UUID()
    private var transferHeld = false
    private var holdConfirmed = false
    private var holdTask: Task<Void, Error>?
    private var focusAffinity: (participant: String, source: NativeDesktopVideoSource)?
    enum MediaPresentation { case meeting, floating, infoCard, hidden }
    @Published private(set) var mediaPresentation: MediaPresentation = .meeting
    private var floatingParticipantID: String?
    /// Floating video follows the active speaker only after the speaker holds
    /// for this long, so a lively discussion does not flicker the PiP between
    /// cameras. A screen share takes over immediately. Injectable for tests.
    var floatingHold: TimeInterval = 2.5
    var floatingSleep: (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    private var floatingSpeakerTask: Task<Void, Never>?
    private var demandKey: String?
    private var demandTask: Task<Void, Never>?
    private var visibleSpeakerTileIDs: Set<String> = []
    private var heldState: (microphone: Bool, camera: Bool, playout: Bool)?
    @Published private var requestedMicrophone: Bool?
    @Published private var requestedCamera: Bool?
    var microphoneStarting: Bool { !closed && !transferHeld && requestedMicrophone == true && !snapshot.microphoneOn }
    var cameraStarting: Bool { !closed && !transferHeld && requestedCamera == true && !snapshot.cameraOn }
    private var requestedPlayout: Bool?
    /// App-only meeting level, remembered per service; the Mac output volume is untouched.
    @Published private(set) var meetingVolume: Double = 1
    var meetingVolumeKey: String { "nativeDesktop.meetingVolume." + kind.rawValue }
    private let quiet: Bool
    private let readinessPolicy: () -> NativeDesktopJoinReadinessPolicy
    private let power: NativeDesktopPowerMonitor
    private var joinReadinessPolicy = NativeDesktopJoinReadinessPolicy()
    private var joinPower = NativeDesktopPowerSnapshot(pluggedIn: false, lowPowerMode: true)
    private var externalMediaSuspension: NativeDesktopSharedMedia<GuestSystemAudio>.Suspension?
    private let sharedMedia: NativeDesktopSharedMedia<GuestSystemAudio>
    /// Simultaneous meetings: only the talk meeting holds the microphone, camera and
    /// headset hook. Others keep listening with their physical input released.
    @Published private(set) var ownsMicrophone = true { didSet { if ownsMicrophone != oldValue { updateLocalMicrophoneCapture() } } }
    private(set) var concurrentAudio = false
    /// Moves the talk role here; true only after any previous talk meeting confirmed release.
    var microphoneArbiter: ((NativeDesktopMeetingModel) async -> Bool)?
    private var mediaClaim: NativeDesktopSharedMedia<GuestSystemAudio>.Suspension?
    var isClosed: Bool { closed }
    private(set) var joinReadinessReport: [String: Any] = [:]

    init(destination: JoinDestination, name: String, title: String?, quiet: Bool = false,
         engine makeEngine: (any NativeDesktopMeetingEngine)? = nil,
         joinReadiness: NativeDesktopJoinReadinessPolicy? = nil,
         joinCameraPrime: NativeDesktopJoinCameraPrime? = nil,
         cameraMetadata: NativeDesktopCameraMetadataPreparation? = nil,
         joinTimeout: TimeInterval = 45,
         power: NativeDesktopPowerMonitor? = nil,
         readinessPolicy: (() -> NativeDesktopJoinReadinessPolicy)? = nil,
         sharedMedia: NativeDesktopSharedMedia<GuestSystemAudio>? = nil,
         listenStore: ListenModelStore? = nil) {
        self.usesInjectedSharedMedia = sharedMedia != nil
        self.sharedMedia = sharedMedia ?? NativeDesktopMediaService.shared
        self.listenStore = listenStore ?? .shared
        invitation = destination.invitationURL; kind = destination.engineKind; displayName = name; self.quiet = quiet
        self.readinessPolicy = readinessPolicy ?? { joinReadiness ?? .current() }
        self.power = power ?? NativeDesktopPowerMonitor()
        self.captureCoordinator = MeetingCaptureCoordinator(joinCameraPrime: joinCameraPrime, cameraMetadata: cameraMetadata)
        precondition(joinTimeout.isFinite && joinTimeout > 0)
        self.joinTimeout = joinTimeout
        let initialSessionID = sessionID
        self.workspaceSessionID = initialSessionID
        self.activeNoteSessionID = initialSessionID
        self.fallbackRoomTitle = destination.roomIdentifier
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveInitial = cleanTitle?.isEmpty == false ? cleanTitle! : destination.roomIdentifier
        self.scheduledTitle = cleanTitle?.isEmpty == false ? cleanTitle : nil
        self.title = effectiveInitial
        self.segments = [ScheduledSegment(sessionID: initialSessionID, calendarEventID: nil, seriesID: nil,
                                          title: effectiveInitial, startedAt: Date(), endedAt: nil)]
        engine = makeEngine ?? UniversalMeetingEngine.shared.makeSession(destination: destination, chat: chat)
        reactionObserver.onReaction = { [weak self] kind, _ in self?.sendReaction(kind) }
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in
            Task { @MainActor in self?.refreshSystemReactions(); self?.refreshReadinessEligibility() }
        }.store(in: &subscriptions)
        chat.reactionHistory.beginMeeting(id: sessionID)
        catchUp.enter(roomKey: invitation.absoluteString)
        catchUp.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        self.listenStore.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.objectWillChange.send()
                self?.updateLocalTranscription()
            }
        }.store(in: &subscriptions)
        chat.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        chat.reactionHistory.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        if let saved = UserDefaults.standard.object(forKey: meetingVolumeKey) as? Double { meetingVolume = Self.clampedVolume(saved) }
        let initialVolume = meetingVolume
        Task { [engine] in await engine.setPlayoutVolume(initialVolume) }
        engine.onState = { [weak self] value in self?.update(value) }
        // Before connecting: a meeting joined with sound off still receives audio to transcribe.
        engine.setTranscriptionRequested(localTranscriptionAllowed)
        engine.onVideo = { [weak self] value in
            guard let self, !closed else { return }; videos = value; updateDemand()
        }
        engine.onLocalCamera = { [weak self] track in self?.setLocalCamera(track) }
        engine.onTitle = { [weak self] raw in
            guard let self, !closed else { return }
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            self.serverTitle = clean
            if !self.userOverrodeTitle && self.scheduledTitle == nil {
                self.title = clean
            }
        }
        if let session = engine as? MeetingSession {
            session.onFeatureError = { [weak self] error in
                guard let self, !closed else { return }; self.error = error.localizedDescription
            }
            session.onFeatures = { [weak self] features in self?.updateFeatures(features) }
            session.onCapturedMessages = { [weak self] messages, transcript in
                self?.captureGuestMessages(messages, transcript: transcript)
            }
            if let chatService = session.chatService {
                chatService.onApprovedChatOutcome = { [weak self] id, status in
                    guard let self, let chatID = approvedWorkspaceChatLink(id: id) else { return }
                    workspaceJournal?.observeApprovedChat(sessionID: workspaceSessionID, chatID: chatID, status: status)
                }
                if !chatService.managesChatStoreSendCallbacks {
                    if chatService.supportsSending {
                        chat.onSend = { [weak self, weak chatService] text in
                            guard let self, let chatService, chatService.isReadyToSend else { return }
                            self.participation.yieldToUser()
                            if self.chat.draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { self.chat.draft = "" }
                            if let id = self.approvedWorkspaceChatID {
                                let permit = GuestChatDispatchPermit(deadline: Date().addingTimeInterval(20))
                                self.approvedWorkspaceChatPermits[id] = permit
                                self.perform { _ in
                                    defer { self.approvedWorkspaceChatPermits[id] = nil }
                                    let chatID = self.approvedWorkspaceChatLink(id: id) ?? ("chat:" + self.kind.rawValue + ":" + id)
                                    do {
                                        let status = try await chatService.send(text, permit: permit, approvedID: id)
                                        self.workspaceJournal?.observeApprovedChat(sessionID: self.workspaceSessionID, chatID: chatID, status: status)
                                    } catch {
                                        let current = self.workspaceJournal?.session(id: self.workspaceSessionID)?.events
                                            .first(where: { $0.linkedChatID == chatID })?.status
                                        let status = chatService.classifyError(error, permit: permit, currentStatus: current)
                                        self.workspaceJournal?.observeApprovedChat(sessionID: self.workspaceSessionID, chatID: chatID, status: status)
                                        throw error
                                    }
                                }
                            } else {
                                self.perform { _ in try await chatService.send(text) }
                            }
                        }
                        chat.onRetry = { [weak self, weak chatService] entry in
                            guard let self, let chatService, chatService.isReadyToSend else { return }
                            self.participation.yieldToUser()
                            self.perform { _ in
                                do { try await chatService.retry(entry: entry) }
                                catch { self.chat.setDelivery(.failed, for: entry.id); throw error }
                            }
                        }
                    } else if !chatService.canRead {
                        chat.unavailableReason = chatService.unavailableReason
                    }
                }
            }
        } else if kind == .trueconf {
            chat.unavailableReason = L("Chat is unavailable for this meeting service.")
        }
        if (engine as? MeetingSession)?.chatService?.observesStoreCaptures ?? true {
            chat.onCapture = { [weak self] entries in
                guard let self, let workspaceJournal = self.workspaceJournal else { return }
                workspaceJournal.observe(sessionID: self.workspaceSessionID, events: entries.map { entry in
                    let status: MeetingWorkspaceEvent.Status = switch entry.delivery {
                    case .pending: .sending
                    case .sent: entry.isOwn ? .submitted : .sent
                    case .failed: .failed
                    }
                    return .init(id: "chat:" + self.kind.rawValue + ":" + entry.id, kind: .chat,
                        occurredAt: entry.sentAt == .distantPast ? .now : entry.sentAt,
                        observedAt: .now, source: self.kind.rawValue, author: entry.sender, text: entry.text,
                        status: status, timeIsObserved: entry.sentAt == .distantPast)
                })
            }
        }
    }
    var connected: Bool { snapshot.phase == .connected }
    var microphoneTrackProbe: GuestMicrophoneTrackProbe? {
        guard !closed, connected else { return nil }
        let generation = generation
        return engine.microphoneTrackProbe?.checking { [weak self] in
            guard let self else { return false }
            return !closed && connected && self.generation == generation
        }
    }
    /// IDs are random session/command generations and never contain room identifiers.
    var ownershipDiagnostics: [String: Any] {
        let recovery: String
        if let session = engine as? MeetingSession {
            recovery = session.sessionSnapshot.recoveryExecutor.rawValue
        } else {
            switch kind {
            case .guest: recovery = "guest-session"
            case .telemost, .trueconf: recovery = "external-session"
            case .community: recovery = "livekit-sdk"
            }
        }
        return ["session": sessionID.uuidString, "generation": generation.uuidString,
                "provider": kind.rawValue, "phase": snapshot.phase.rawValue,
                "configuredRecoveryExecutor": recovery, "cameraLease": captureCoordinator.hasActiveCameraLease,
                "providerState": engine.ownershipDiagnostics,
                "presenter": captureCoordinator.presenterOwnershipDiagnostics,
                "shareGeneration": captureCoordinator.shareGeneration.uuidString, "sharePending": sharingPending,
                "shareRetiring": captureCoordinator.isShareRetiring, "shareCleanupSucceeded": captureCoordinator.shareCleanupSucceeded,
                "sharing": snapshot.sharing, "microphoneOn": snapshot.microphoneOn]
    }
    var participationConnection: MeetingConnectionIdentity? {
#if DEBUG
        if let participationAudienceForTesting { return participationAudienceForTesting.connection }
#endif
        return (engine as? MeetingSession)?.participationService?.connectionIdentity
    }
    var participationSomeoneSpeaking: Bool {
        guestFeatures.participants.contains(where: \.isSpeaking) || snapshot.participants.contains { $0.speaking == true }
    }
    var participationRemoteSpeaking: Bool {
        guestFeatures.participants.contains { !$0.isLocal && $0.isSpeaking }
            || snapshot.participants.contains { !$0.isLocal && $0.speaking == true }
    }
    var participationVoiceAvailable: Bool {
#if DEBUG
        if let participationVoiceAvailableForTesting { return participationVoiceAvailableForTesting }
#endif
        return connected && (engine as? MeetingSession)?.participationService != nil && engine.supportsVoiceReply
    }
    var participationVoiceMicrophoneAuthorized: Bool {
        (engine as? MeetingSession)?.participationService?.voiceMicrophoneAuthorized == true
    }
    var participationVoiceCanRequestMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }
    func requestParticipationVoiceMicrophoneAccess() async {
        guard participationVoiceCanRequestMicrophoneAccess else { return }
        _ = try? await GuestCaptureAuthorization.request(.audio)
        objectWillChange.send()
    }
    var participationTranscriptSource: ParticipationTranscriptSource {
        if guestFeatures.permissions.canViewTranscript && guestFeatures.transcriptionStatus == .active { return .service }
        let supportsRoomAudioParticipation = (engine as? MeetingSession).map { $0.participationService != nil } ?? (kind == .guest)
        if supportsRoomAudioParticipation, transcribingLocally, !localTranscriptionPaused { return .localRoomAudio }
        return .unavailable
    }
    var participationVoiceHasTranscript: Bool { participationTranscriptSource != .unavailable }
    var participationVoiceEligible: Bool {
        participationVoiceAvailable && participationVoiceMicrophoneAuthorized && participationVoiceHasTranscript && ownsMicrophone
            && requestedMicrophone == nil && !closed && !transferHeld
            && !assistantCaptureActive && !voiceReplyGateHeld && participationMeetingSoundOn
    }
    var participationMeetingSoundOn: Bool { snapshot.playoutOn && requestedPlayout != false && meetingVolume > 0 }
    private var participationVoiceLocalGain: Float? {
        guard participationMeetingSoundOn else { return nil }
        let shared = (engine as? MeetingSession)?.participationService?.usesSharedOutput == true
        return shared ? Float(meetingVolume) : 1
    }
    func playParticipationVoice(_ buffer: AVAudioPCMBuffer, audience: ParticipationAudience,
                                permit: GuestAutonomousVoicePlayback, preflight: @MainActor () async -> Bool,
                                canStart: @escaping @MainActor () -> Bool,
                                onStarted: @escaping @MainActor () -> Void) async -> GuestAutonomousVoicePlayback.Outcome {
        guard permit.canStart, participationVoiceEligible, !voiceReplyActive, !participationSomeoneSpeaking,
              participationAudience == audience,
              let service = (engine as? MeetingSession)?.participationService else { return .notStarted }
        let borrowsMutedSender = !snapshot.microphoneOn
        if borrowsMutedSender, !headset.prepareParticipationCapture(permit) {
            probeLog("participation-voice-capture", ["stage": "preparation-refused", "headsetActive": headset.isActive,
                "processMuted": LKRTCApplicationCaptureMuted() != 0])
            return .notStarted
        }
        var restoredMutedSender = true
        voiceReplyActive = true
        updateLocalMicrophoneCapture()
        defer {
            permit.cancel()
            if !closed && (!restoredMutedSender || participationConnection != audience.connection) {
                voicePrivacyConnection = audience.connection
                voiceReplyGateHeld = true
            } else if participationConnection == audience.connection {
                restoreParticipationVoiceGate { _ = service.setVoiceGate(open: true) }
            }
            voiceReplyActive = false; voiceReplyUserChoice = nil; updateLocalMicrophoneCapture()
            recoverParticipationVoiceGateIfSafe()
        }
        if !service.hasVoiceGraph {
            guard borrowsMutedSender, await service.prepareVoiceAudio(permit),
                  service.hasVoiceGraph else { return .notStarted }
        }
        guard service.setVoiceGate(open: false) else { return .notStarted }
        do { try await Task.sleep(for: .milliseconds(GuestVoiceReplyGraph.gateSettleMilliseconds)) }
        catch { return .notStarted }
        guard permit.canStart, await preflight() else { return .notStarted }
        var ready = true
        if borrowsMutedSender { ready = await service.borrowVoiceSender(permit) }
        let outcome = if ready, permit.canStart, await preflight() {
            await service.playVoice(buffer, permit: permit, canStart: {
                self.participationVoiceEligible && self.participationAudience == audience
                    && !self.participationRemoteSpeaking && canStart()
            }, localGain: { self.participationVoiceLocalGain }, onStarted: onStarted)
        } else { GuestAutonomousVoicePlayback.Outcome.notStarted }
        if borrowsMutedSender {
            restoredMutedSender = await Task { @MainActor in await service.restoreVoiceSender(permit) }.value
        }
        return outcome
    }
    private func restoreParticipationVoiceGate(reopen: () -> Void) {
        guard !closed else { return }
        let muteExpected = !snapshot.microphoneOn || requestedMicrophone == false
            || voiceReplyUserChoice == false || !ownsMicrophone || transferHeld
        let physicallyMuted = (engine as? MeetingSession)?.participationService?.senderPhysicallyMuted
            ?? !snapshot.microphoneOn
        if muteExpected && !physicallyMuted {
            voiceReplyGateHeld = true
        } else {
            reopen()
        }
    }

    private var canReleaseHeldVoiceGate: Bool {
        Self.canReleaseVoiceGate(heldFor: voicePrivacyConnection, current: participationConnection, connected: connected)
    }

    static func canReleaseVoiceGate(heldFor previous: MeetingConnectionIdentity?, current: MeetingConnectionIdentity?, connected: Bool) -> Bool {
        guard let previous else { return true }
        return connected && current.map { $0 != previous } == true
    }

    private func recoverParticipationVoiceGateIfSafe() {
        guard voiceReplyGateHeld, !snapshot.microphoneOn, !voiceReplyActive, canReleaseHeldVoiceGate,
              let service = (engine as? MeetingSession)?.participationService, service.senderPhysicallyMuted,
              service.setVoiceGate(open: true) else { return }
        voiceReplyGateHeld = false
        voicePrivacyConnection = nil
    }
#if DEBUG
    func restoreParticipationVoiceGateForTesting(_ reopen: () -> Void) { restoreParticipationVoiceGate(reopen: reopen) }
    var participationVoiceGateHeldForTesting: Bool { voiceReplyGateHeld }
#endif
    var participationAudience: ParticipationAudience? {
#if DEBUG
        if let participationAudienceForTesting { return participationAudienceForTesting }
#endif
        guard !closed, connected, guestFeatures.connected, guestFeatures.permissions.canViewParticipants,
              guestFeatures.permissions.canViewChat, guestFeatures.permissions.canSendChat,
              let room = MeetingRoomIdentity(invitation, engine: kind),
              let service = (engine as? MeetingSession)?.participationService,
              let provider = service.roomScope,
              let connection = service.connectionIdentity,
              let local = guestFeatures.localParticipantID,
              guestFeatures.participants.contains(where: { $0.id == local && $0.isLocal }) else { return nil }
        let participants = guestFeatures.participants
        let members = Dictionary(participants.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        guard members.count == participants.count else { return nil }
        return .init(sessionID: sessionID, room: room, providerRoom: provider.room, providerGroup: provider.group,
                     localParticipant: local, members: members, connection: connection)
    }
    func sendParticipationChat(_ text: String, id: String, audience: ParticipationAudience,
                               permit: GuestChatDispatchPermit) async throws {
        guard participationMeetingSoundOn, participationAudience == audience,
              let service = (engine as? MeetingSession)?.participationService else {
            throw MeetingSessionError.unavailable(L("Chat is unavailable before connecting."))
        }
        try await service.sendAttributedChat(text, id: id, permit: permit)
    }
    var canReact: Bool { connected && guestFeatures.permissions.canSendReaction }
    var transcript: [GuestMeetingMessage] {
        guard !localTranscript.isEmpty else { return guestFeatures.transcript }
        return (guestFeatures.transcript + localTranscript).sorted { (Self.spokenAt($0) ?? .distantPast) < (Self.spokenAt($1) ?? .distantPast) }
    }
    var participants: [NativeDesktopParticipant] { snapshot.participants }
    /// Participants whose video the display mode receives. Tiles, speaking state
    /// and layouts always cover every participant; only media is reduced.
    var videoParticipants: [NativeDesktopParticipant] {
        switch display {
        case .all: participants
        case .screenShares: participants.filter { $0.sharing == true && !$0.isLocal }
        case .audioOnly: []
        }
    }
    /// Received video permitted by the display mode, even if an engine still delivers more.
    var visibleVideos: [NativeDesktopExternalVideo] {
        switch display {
        case .all: videos
        case .screenShares: videos.filter { $0.source == .screen }
        case .audioOnly: []
        }
    }
    var galleryParticipants: [NativeDesktopParticipant] { Array(participants.dropFirst(galleryPage * 6).prefix(6)) }
    var galleryPages: Int { max(1, Int(ceil(Double(participants.count) / 6))) }
    var focusedParticipantID: String? { focusedVideo?.participantID ?? focusAffinity?.participant ?? pinnedID }
    var focusedVideo: NativeDesktopExternalVideo? {
        if let pinnedID, participants.contains(where: { $0.id == pinnedID && $0.isLocal }) {
            if pinnedSource == .screen, let localShare { return .init(id: "local-screen", participantID: pinnedID, source: .screen, track: localShare) }
            if pinnedSource != .screen, let localCamera { return .init(id: "local-camera", participantID: pinnedID, source: .camera, track: localCamera) }
        }
        let videos = visibleVideos
        if let affinity = focusAffinity {
            if let match = videos.first(where: { $0.participantID == affinity.participant && $0.source == affinity.source }) { return match }
            // A focused camera that is off shows the same person's live screen instead.
            if affinity.source == .camera, participants.first(where: { $0.id == affinity.participant })?.cameraOn != true,
               let screen = videos.first(where: { $0.participantID == affinity.participant && $0.source == .screen }) { return screen }
            return nil
        }
        if let pinnedID, let pinned = videos.first(where: { $0.id == pinnedID || $0.participantID == pinnedID }) { return pinned }
        return videos.first { $0.source == .screen } ?? videos.first { item in participants.first { $0.id == item.participantID }?.speaking == true } ?? videos.first
    }
    /// Whether the focused person has video this mode should be receiving; when
    /// not, the stage shows their tile instead of waiting for a stream.
    var focusedVideoExpected: Bool {
        guard display != .audioOnly, let id = focusedParticipantID,
              let person = participants.first(where: { $0.id == id }) else { return false }
        if focusAffinity?.participant == id, focusAffinity?.source == .screen { return person.sharing == true }
        return display == .all && (person.cameraOn == true || person.sharing == true)
    }
    /// The person whose voice is live: a remote speaker first, else this Mac.
    var activeSpeaker: NativeDesktopParticipant? {
        participants.first { $0.speaking == true && !$0.isLocal } ?? participants.first { $0.speaking == true }
    }
    var orderedParticipants: [NativeDesktopParticipant] {
        participants.sorted {
            if $0.isLocal != $1.isLocal { return $0.isLocal }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
    /// The tile follows the share on stage, including while its stream reconnects.
    var focusedSharePresenter: NativeDesktopParticipant? {
        guard showsFocus, display != .audioOnly, let id = focusedParticipantID,
              let person = participants.first(where: { $0.id == id }), person.sharing != false else { return nil }
        if focusedVideo?.source == .screen ||
            (focusAffinity?.source == .screen && person.sharing == true) { return person }
        return nil
    }
    var railParticipants: [NativeDesktopParticipant] {
        let presenterID = focusedSharePresenter?.id
        return orderedParticipants.filter { $0.id != presenterID }
    }
    /// Automatic focuses a share only when it is received; Focus works in every mode.
    var showsFocus: Bool {
        viewMode == .focused || (viewMode == .automatic && display != .audioOnly &&
            (participants.contains { $0.sharing == true && !$0.isLocal } ||
             visibleVideos.contains { $0.source == .screen } || focusAffinity?.source == .screen))
    }
    var floatingVideo: NativeDesktopExternalVideo? {
        if showsFocus { return focusedVideo }
        let videos = visibleVideos
        return videos.first { $0.participantID == floatingParticipantID && $0.source == .screen }
            ?? videos.first { $0.participantID == floatingParticipantID }
    }
    func connect() async throws {
        guard !closed, connectionTask == nil else { throw CancellationError() }
        let token = generation, deadline = ProcessInfo.processInfo.systemUptime + joinTimeout
        let startup = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await connectAttempt()
        }
        connectionTask = startup
        do {
            try await guestAwait(timeout: joinTimeout) { done in
                Task { @MainActor in
                    do { try await startup.value; done(.success(())) }
                    catch { done(.failure(error)) }
                }
            }
            try Task.checkCancellation()
            guard token == generation, !closed else { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw GuestTransportError.timedOut }
            connectionTask = nil
        } catch {
            if token == generation, !closed {
                self.error = error.localizedDescription
                _ = beginLeave()
                snapshot.phase = .failed; snapshot.lastError = error.localizedDescription
            }
            throw error
        }
    }
    private func connectAttempt() async throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let token = generation
        joinReadinessPolicy = readinessPolicy(); joinPower = power.snapshot
        power.start { [weak self] in self?.refreshReadinessEligibility() }
        let completion = GuestCompletion<Void>(); connection = completion
        // A failed system input-mute write fails closed (the capture gate stays shut) and is
        // retried on the next mute change, so it is not a meeting failure. macOS returns it
        // while its audio session service restarts, e.g. after AirPods drop (-50).
        headset.onError = { [weak self] failure in
            probeLog("headset-mute-platform-error", ["error": failure.localizedDescription,
                "phase": String(describing: self?.snapshot.phase)])
        }
        headset.onDisable = { reason in probeLog("headset-mute-disabled", ["reason": reason]) }
        let headsetReady = ownsMicrophone ? headset.begin { [weak self] muted in self?.setMicrophoneEnabled(!muted) } : true
        guard await NativeDesktopDeviceModel.stopPrivatePreview() else { throw NativeDesktopRTCError.cleanupFailed }
        try Task.checkCancellation()
        if usesInjectedSharedMedia || !SharedAudioEngine.enabledAtLaunch {
            if concurrentAudio {
                mediaClaim = try await sharedMedia.suspendAlongside()
                try Task.checkCancellation()
            } else if kind != .guest {
                externalMediaSuspension = try await sharedMedia.suspend()
                try Task.checkCancellation()
            }
        }
        if !ownsMicrophone, !(await engine.setPhysicalInputPermitted(false)) { throw NativeDesktopRTCError.cleanupFailed }
        if supportsPreJoinReadiness {
            engine.microphoneReadinessPolicy = { [weak self] in self?.microphonePreparationEligible ?? false }
            updateMicrophoneRecoveryReadiness()
        }
        try await withTaskCancellationHandler(operation: {
            try await prepareJoinCameraMetadata()
            try Task.checkCancellation()
            guard token == generation, !closed, !transferHeld else { throw CancellationError() }
            try await engine.connect(invitation: invitation, name: displayName, quiet: quiet)
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in completion.install(continuation, timeout: 45) }
        }, onCancel: { completion.finish(.failure(CancellationError())) })
        try Task.checkCancellation()
        if ownsMicrophone, !headsetReady { useEngineOnlyHeadsetFallback() }
        if !supportsPreJoinReadiness, !quiet, ownsMicrophone, !concurrentAudio, joinReadinessPolicy.microphoneExplicit,
           joinReadinessPolicy.microphone.allows(joinPower), joinReadinessPolicy.microphone.allows(power.snapshot) {
            try await engine.prepareMutedCaptureForAccessories()
        }
        beginJoinReadiness()
    }
    private var supportsPreJoinReadiness: Bool {
        (engine as? MeetingSession)?.capabilities.supportsPreJoinReadiness ?? (kind == .guest)
    }
    private var cameraMetadataEligible: Bool {
        supportsPreJoinReadiness && !quiet && !closed && !transferHeld && display != .audioOnly && ownsMicrophone && !concurrentAudio &&
            joinReadinessPolicy.camera.allows(joinPower) && readinessPolicy().camera.allows(power.snapshot)
    }
    private func prepareJoinCameraMetadata() async throws {
        try await captureCoordinator.prepareJoinCameraMetadata { [weak self] in self?.cameraMetadataEligible == true }
    }
    private func beginJoinReadiness() {
        guard supportsPreJoinReadiness, !quiet, !closed, !transferHeld, snapshot.phase == .connected else {
            joinReadinessReport = ["state": "skipped", "reason": "meetingPolicy"]; return
        }
        guard ownsMicrophone, !concurrentAudio else {
            joinReadinessReport = ["state": "skipped", "reason": "concurrentMeeting"]; return
        }
        let token = generation, cameraCommand = cameraCommand
        joinReadinessReport = ["state": "scheduled", "joinedUptime": ProcessInfo.processInfo.systemUptime,
            "microphonePolicy": joinReadinessPolicy.microphone.rawValue, "cameraPolicy": joinReadinessPolicy.camera.rawValue,
            "microphoneRequested": joinReadinessPolicy.microphone.allows(joinPower),
            "cameraRequested": joinReadinessPolicy.camera.allows(joinPower)]
        joinReadinessReport["cameraMetadata"] = captureCoordinator.cameraMetadataReport
        if let session = engine as? MeetingSession {
            joinReadinessReport["microphoneActivated"] = session.microphoneReadinessApplied
            joinReadinessReport["microphonePreparationTiming"] = "beforeTransportJoin"
            joinReadinessReport["startupAudio"] = session.startupAudioReport
        }
        guard joinReadinessPolicy.camera.allows(joinPower) else { return }
        guard captureCoordinator.cameraMetadata.isPrepared(deviceID: UserDefaults.standard.string(forKey: "nativeDesktop.cameraID")) else {
            joinReadinessReport["camera"] = ["state": "skipped", "reason": "metadataUnavailable"]; return
        }
        guard display != .audioOnly else {
            joinReadinessReport["camera"] = ["state": "skipped", "reason": "audioOnly"]; return
        }
        captureCoordinator.scheduleJoinCameraPrime(
            isEligible: { [weak self] in
                guard let self else { return false }
                return token == generation && !closed && !transferHeld &&
                    display != .audioOnly &&
                    readinessPolicy().camera.allows(power.snapshot) &&
                    captureCoordinator.cameraMetadata.isPrepared(deviceID: UserDefaults.standard.string(forKey: "nativeDesktop.cameraID")) &&
                    snapshot.phase == .connected && cameraCommand == self.cameraCommand &&
                    !snapshot.cameraOn && requestedCamera != true
            },
            videoSource: { [weak self] in self?.engine.factory?.videoSource() },
            onReport: { [weak self] report in self?.joinReadinessReport["camera"] = report },
            onCleanupError: { [weak self] message in self?.error = message })
    }
    private func cancelJoinCameraPrime() { captureCoordinator.cancelJoinCameraPrime() }
    private func refreshReadinessEligibility() {
        if !readinessPolicy().camera.allows(power.snapshot) { cancelJoinCameraPrime() }
        // Backoff may outlive a power transition. Only replacement preparation
        // intent changes here; explicit activation and the current graph stay intact.
        if snapshot.phase == .connecting || snapshot.phase == .reconnecting { updateMicrophoneRecoveryReadiness() }
    }
    private var microphonePreparationEligible: Bool {
        !quiet && !closed && !transferHeld && ownsMicrophone && !concurrentAudio &&
            readinessPolicy().microphone.allows(power.snapshot)
    }
    private func updateMicrophoneRecoveryReadiness() {
        guard supportsPreJoinReadiness else { return }
        engine.setMicrophoneReadinessForRecovery(microphonePreparationEligible)
    }
    private func update(_ value: NativeDesktopExternalSnapshot) {
        guard !closed else { return }
        let previous = snapshot; snapshot = value
        if value.phase == .connected && !everConnected {
            let now = Date()
            if connectedSince == nil { connectedSince = now }
            workspaceStartedAt = now
            observeWorkspace([])
        }
        participation.updateAudience(participationAudience)
        if !participationVoiceEligible || participationRemoteSpeaking { participation.interruptVoice() }
        if previous.playoutOn && !value.playoutOn { workspaceSoundTurnedOff() }
        if previous.playoutOn != value.playoutOn, value.phase == .connected {
            workspaceJournal?.recordAction(sessionID: workspaceSessionID,
                text: value.playoutOn ? L("Meeting sound on") : L("Meeting sound off"),
                source: value.playoutOn ? "soundOn" : "soundOff")
        }
        if participationSomeoneSpeaking { participation.cancelPendingDispatch() }
        if previous.phase != value.phase { updateLocalTranscription() }
        if previous.phase != .connected, value.phase == .connected { prewarmMicrophoneIfChosen() }
        else if previous.microphoneOn != value.microphoneOn { updateLocalMicrophoneCapture() }
        let now = Date()
        speakingTimeline.observe(speaking: Set(value.participants.filter { !$0.isLocal && $0.speaking == true }.map(\.id)), at: now)
        for person in value.participants where person.speaking == true {
            if lastSpokeAt[person.id].map({ now.timeIntervalSince($0) > 5 }) ?? true { lastSpokeAt[person.id] = now }
        }
        noteShareState()
        if value.phase == .reconnecting || value.phase == .failed { cancelJoinCameraPrime() }
        if previous.phase != .reconnecting, value.phase == .reconnecting { updateMicrophoneRecoveryReadiness() }
        captureCoordinator.updateVP9Support(engine: engine)
        if value.phase == .connected { connection?.finish(.success(())) }
        if value.phase == .failed { connection?.finish(.failure(NativeDesktopError.unavailable(value.lastError ?? L("Could not connect to meeting.")))) }
        // A reply held the gate closed because the mute after it was not confirmed:
        // once the microphone is confirmed off, reopening is safe.
        if (engine as? MeetingSession)?.participationService != nil {
            recoverParticipationVoiceGateIfSafe()
        } else if voiceReplyGateHeld, !value.microphoneOn, !voiceReplyActive {
            voiceReplyGateHeld = false
            voicePrivacyConnection = nil
            let engine = engine; Task { _ = await engine.setMicrophoneGate(open: true) }
        }
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
        if previous.playoutOn && !value.playoutOn { catchUp.begin(.audioInterruption); catchUpOffer = nil }
        if !previous.playoutOn && value.playoutOn { catchUp.end(.audioInterruption); offerCatchUpForSoundReturn() }
        if value.phase == .connected, !value.participants.isEmpty, let affinity = focusAffinity {
            let participant = value.participants.first { $0.id == affinity.participant }
            if participant == nil || (affinity.source == .screen && participant?.sharing == false) {
                focusAffinity = nil
                if pinnedID == affinity.participant { unpin(); if viewMode == .focused { viewMode = .automatic } }
            }
        }
        updateFloatingAnchor(); updateDemand(); refreshSystemReactions()
        if galleryPage >= galleryPages { galleryPage = max(0, galleryPages - 1) }
        if value.phase == .failed && value.endedByOrganizer {
            guard !endedByOrganizer else { return }
            endedByOrganizer = true; onEndedByOrganizer?()
            Task { [weak self] in await self?.onLeave?() }
        } else if value.phase == .failed { error = value.lastError ?? L("Meeting connection failed.") }
    }
    private func setLocalCamera(_ track: LKRTCVideoTrack?) {
        guard !closed else { return }
        localCamera = track
        NativeDesktopCameraLease.shared.setLiveTrack(track, owner: sessionID)
        Task { [weak self] in await self?.captureCoordinator.refreshBorrowedCamera(); self?.refreshSystemReactions() }
    }
    var microphoneRestriction: String? { (engine as? MeetingSession)?.microphoneRestriction }
    func toggleMicrophone() {
        let enabled = !(requestedMicrophone ?? snapshot.microphoneOn)
        guard !assistantCaptureActive || !enabled else { return }
        if enabled, let microphoneRestriction { error = microphoneRestriction; return }
        if voiceReplyActive { voiceReplyUserChoice = enabled }
        else if enabled, voiceReplyGateHeld, canReleaseHeldVoiceGate {
            voiceReplyGateHeld = false
            voicePrivacyConnection = nil
            let engine = engine; Task { _ = await engine.setMicrophoneGate(open: true) }
        }
        guard enabled, !ownsMicrophone else { setMicrophoneEnabled(enabled); return }
        claimTalkRole(microphone: true) { [weak self] in self?.setMicrophoneEnabled(true) }
    }
    /// Effective microphone output state for Assistant read tools: the requested
    /// state when a toggle is in flight, otherwise the engine's state.
    var assistantMicrophoneOn: Bool { requestedMicrophone ?? snapshot.microphoneOn }

    /// Explicitly mutes this meeting's microphone without ever toggling it on during a voice reply.
    @discardableResult func muteMicrophone() -> Bool {
        participation.interruptVoice()
        let wasActive = (requestedMicrophone ?? snapshot.microphoneOn) || voiceReplyActive
        if voiceReplyActive { voiceReplyUserChoice = false }
        if requestedMicrophone == true || snapshot.microphoneOn { setMicrophoneEnabled(false) }
        return wasActive
    }
    /// Call before connect() for a meeting joined while another meeting is live.
    func configureForConcurrentJoin(ownsMicrophone owns: Bool) {
        guard connectionTask == nil, !closed else { return }
        concurrentAudio = true; ownsMicrophone = owns
        engine.configureConcurrentAudio(true)
    }
    /// Unmuting or starting the camera in a listening meeting first moves the talk
    /// role here. Nothing is enabled unless the previous meeting confirmed its release.
    private func claimTalkRole(microphone: Bool, then action: @escaping @MainActor () -> Void) {
        guard !closed, !transferHeld, let arbiter = microphoneArbiter else { return }
        if microphone { requestedMicrophone = true; handoverStartedAt = ProcessInfo.processInfo.systemUptime } else { requestedCamera = true }
        let token = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            let claimed = await arbiter(self)
            // A second click while the move was pending cancels it.
            let wanted = microphone ? requestedMicrophone == true : requestedCamera == true
            if microphone { if requestedMicrophone == true { requestedMicrophone = nil } }
            else if requestedCamera == true { requestedCamera = nil }
            guard claimed, wanted, token == generation, !closed, ownsMicrophone else {
                if microphone { handoverStartedAt = nil; handoverPhases = nil }
                return
            }
            action()
        }
    }
    /// Privacy first: mute and stop the camera, drop the headset hook, then release
    /// physical input. A failed release keeps this meeting the (muted) talk meeting.
    func relinquishMicrophone() async -> Bool {
        guard ownsMicrophone else { return true }
        participation.interruptVoice()
        let approvedVoice = workspaceApprovedVoice
        approvedVoice?.cancel()
        if voiceReplyActive { await approvedVoice?.drain() }
        ownsMicrophone = false
        await participation.stopVoiceAndWait()
        if requestedMicrophone == true || snapshot.microphoneOn { setMicrophoneEnabled(false) }
        if requestedCamera == true || snapshot.cameraOn { setCameraEnabled(false) }
        await controlTail?.value
        headset.end(); authorizedMicrophoneRequest = nil
        // A leaving meeting may still send until its engine stops: wait for that.
        guard !closed else { return await leave() }
        engine.setMicrophoneReadinessForRecovery(false)
        guard await engine.setPhysicalInputPermitted(false, keepDeviceWarm: keepMicrophoneWarm()) else {
            // Stay the (muted) talk meeting and keep the ability to unmute here.
            _ = await engine.setPhysicalInputPermitted(true)
            ownsMicrophone = true; registerHeadset(); return false
        }
        return true
    }
    /// Granting the permit starts no input; the next unmute activates it explicitly.
    func assumeMicrophone() async {
        guard !closed, !ownsMicrophone else { return }
        ownsMicrophone = true
        _ = await engine.setPhysicalInputPermitted(true)
        guard !closed, ownsMicrophone else { return }
        registerHeadset(); updateMicrophoneRecoveryReadiness()
    }
    private func registerHeadset() {
        if !headset.begin(onRequestedMute: { [weak self] muted in self?.setMicrophoneEnabled(!muted) }) {
            useEngineOnlyHeadsetFallback()
        }
    }
    private func useEngineOnlyHeadsetFallback() {
        let physicalMute = (engine as? MeetingSession)?.participationService?.senderPhysicallyMuted ?? true
        _ = headset.useEngineOnlyFallback(confirmedMuted: ownsMicrophone && !snapshot.microphoneOn && physicalMute)
    }
    private func setMicrophoneEnabled(_ enabled: Bool) {
        guard !transferHeld, !closed, !enabled || ownsMicrophone else { _ = headset.requestIntent(muted: true); return }
        participation.interruptVoice()
        requestedMicrophone = enabled
        let command = UUID(); microphoneCommand = command
        microphoneControl?.cancel()
        if !enabled, requestedCamera == true, !snapshot.cameraOn {
            cameraControl?.cancel(); cameraCommand = UUID(); requestedCamera = nil
        }
        if !enabled { authorizedMicrophoneRequest = nil }
        let request = headset.requestIntent(muted: !enabled), token = generation
        microphoneControl = perform(priorityOff: !enabled) { engine in
            do {
                await self.participation.stopVoiceAndWait()
                try Task.checkCancellation()
                try await engine.setMicrophone(enabled)
                if let started = self.handoverStartedAt {
                    self.handoverStartedAt = nil
                    if enabled { self.logHandover(started: started, live: engine.snapshot.microphoneOn, steps: engine.microphoneStartupMilliseconds) }
                    self.handoverPhases = nil
                }
                guard token == self.generation, command == self.microphoneCommand, !self.closed, !self.transferHeld else { return }
                self.authorizedMicrophoneRequest = enabled && engine.snapshot.microphoneOn ? request : nil
                self.headset.confirm(muted: !engine.snapshot.microphoneOn, request: request)
            } catch {
                self.handoverStartedAt = nil; self.handoverPhases = nil
                if command == self.microphoneCommand { self.requestedMicrophone = nil }
                if token == self.generation, !self.closed {
                    try? await Task { @MainActor in try await engine.setMicrophone(false) }.value
                    if command == self.microphoneCommand {
                        let closedRequest = self.headset.requestIntent(muted: true)
                        self.headset.confirm(muted: true, request: closedRequest)
                    }
                }
                throw error
            }
        }
    }
    func toggleCamera() {
        let enabled = !(requestedCamera ?? snapshot.cameraOn)
        guard enabled, !ownsMicrophone else { setCameraEnabled(enabled); return }
        claimTalkRole(microphone: false) { [weak self] in self?.setCameraEnabled(true) }
    }
    private func setCameraEnabled(_ enabled: Bool) {
        guard !transferHeld, !closed, !enabled || ownsMicrophone else { return }
        cancelJoinCameraPrime()
        requestedCamera = enabled
        let command = UUID(); cameraCommand = command
        cameraControl?.cancel()
        if !enabled, requestedMicrophone == true, !snapshot.microphoneOn {
            microphoneControl?.cancel(); microphoneCommand = UUID(); requestedMicrophone = nil
            authorizedMicrophoneRequest = nil; _ = headset.requestIntent(muted: true)
        }
        cameraControl = perform(priorityOff: !enabled) { engine in
            do {
                try await self.captureCoordinator.applyCameraEnabled(
                    enabled, sessionID: self.sessionID,
                    isValid: { !enabled || (command == self.cameraCommand && !self.closed && !self.transferHeld) },
                    setCamera: { value in try await engine.setCamera(value) })
            } catch {
                if command == self.cameraCommand { self.requestedCamera = nil }
                throw error
            }
        }
    }
    func togglePlayout() {
        guard !transferHeld, !closed else { return }
        let enabled = !(requestedPlayout ?? snapshot.playoutOn); requestedPlayout = enabled
        if !enabled { workspaceSoundTurnedOff() }
        perform { engine in
            do { try await engine.setPlayout(enabled) }
            catch { if self.requestedPlayout == enabled { self.requestedPlayout = nil }; throw error }
        }
    }
    static func clampedVolume(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 1 }
    /// Listener-only speaker levels for this meeting (0...2). Others hear no change.
    @Published private(set) var participantVolumes: [String: Double] = [:]
    var supportsParticipantVolume: Bool { engine.supportsParticipantVolume }
    func participantVolume(_ participantID: String) -> Double { participantVolumes[participantID] ?? 1 }
    func setParticipantVolume(_ value: Double, participantID: String) {
        guard !closed, supportsParticipantVolume,
              participants.contains(where: { $0.id == participantID && !$0.isLocal }) else { return }
        let volume = value.isFinite ? min(2, max(0, value)) : 1
        guard volume != participantVolume(participantID) else { return }
        participantVolumes[participantID] = volume == 1 ? nil : volume
        Task { [engine] in await engine.setParticipantVolume(volume, participantID: participantID) }
    }
    /// Slider drags pass persist: false and save once on release.
    func setMeetingVolume(_ value: Double, persist: Bool = true) {
        guard !closed else { return }
        let volume = Self.clampedVolume(value)
        if volume != meetingVolume {
            meetingVolume = volume
            if let gain = participationVoiceLocalGain { participation.setVoiceLocalGain(gain) }
            else if volume == 0 { workspaceSoundTurnedOff() }
            else { participation.interruptVoice() }
            Task { [engine] in await engine.setPlayoutVolume(volume) }
        }
        if persist { UserDefaults.standard.set(volume, forKey: meetingVolumeKey) }
    }
    private func workspaceSoundTurnedOff() {
        workspaceSoundRevision += 1
        cancelWorkspaceApprovedOutputs()
        participation.workspaceSoundTurnedOff()
    }
    func reconnect() {
        participation.requireReview(.connectionChanged)
        cancelJoinCameraPrime()
        updateMicrophoneRecoveryReadiness()
        authorizedMicrophoneRequest = nil; _ = headset.requestIntent(muted: true)
        perform { engine in
            guard await self.captureCoordinator.closePresenter(), await self.retireShare(waitForStartup: true) else { throw NativeDesktopRTCError.cleanupFailed }
            // Failed guest attempts have already retired their media owner.
            // Their retry path resets both publication intents before rejoining.
            if self.kind != .guest || self.snapshot.phase != .failed {
                try await engine.setMicrophone(false)
                try await engine.setCamera(false)
            }
            self.captureCoordinator.releaseCameraLease()
            try await engine.reconnect()
        }
    }
    private static func isNotConnected(_ error: Error) -> Bool {
        (error as? NativeDesktopGuestError) == .notConnected
            || (error as? NativeDesktopRockError) == .notConnected
            || (error as? MeetingSessionError) == .notConnected
            || (error as? NativeDesktopRTCError) == .closed
    }
    @discardableResult private func perform(priorityOff: Bool = false, _ action: @escaping (any NativeDesktopMeetingEngine) async throws -> Void) -> Task<Void, Never>? {
        guard !closed, !transferHeld else { return nil }
        let token = generation, id = UUID(), previous = controlTail
        let task = Task { @MainActor [weak self] in
            if !priorityOff { await previous?.value }
            guard let self else { return }
            defer { self.controlTasks[id] = nil }
            guard token == generation, !closed, !Task.isCancelled else { return }
            do { try await action(engine) }
            catch {
                // A media change that raced joining or leaving (a headset or device event,
                // or a click while connecting) is not the user's mistake. The meeting can
                // connect while the action unwinds, so the error decides, not the phase.
                if Self.isNotConnected(error) {
                    probeLog("media-action-not-connected", ["phase": String(describing: snapshot.phase)]); return
                }
                if token == generation, !closed, !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
        controlTasks[id] = task
        if priorityOff {
            // Privacy actions may suppress an independent sender immediately.
            // A subsequent enable still waits for every older cleanup to drain.
            controlTail = Task { await previous?.value; await task.value }
        } else { controlTail = task }
        return task
    }
    #if DEBUG
    func waitForMediaActionsForTesting() async { await controlTail?.value }
#if DEBUG
    func receiveFeaturesForTesting(_ features: GuestMeetingSnapshot) { updateFeatures(features) }
#endif
    func waitForJoinReadinessForTesting() async {
        await captureCoordinator.waitForJoinReadinessForTesting()
    }
    #endif
    func setTransferHeld(_ held: Bool, restoreSending: Bool = true) async throws {
        if let holdTask { try await holdTask.value; if held { return } }
        guard !closed else { throw CancellationError() }
        if held {
            cancelJoinCameraPrime()
            if transferHeld && holdConfirmed { return }
            participation.interruptVoice()
            transferHeld = true; holdConfirmed = false; authorizedMicrophoneRequest = nil; _ = headset.requestIntent(muted: true)
            requestedMicrophone = nil; requestedCamera = nil
            let tasks = Array(controlTasks.values)
            tasks.forEach { $0.cancel() }
            let operation = Task { @MainActor in
                for task in tasks { await task.value }
                try await self.captureCoordinator.drainJoinPrimeForTransferHold()
                try Task.checkCancellation()
                guard !self.closed else { throw CancellationError() }
                if self.heldState == nil { self.heldState = (self.snapshot.microphoneOn, self.snapshot.cameraOn, self.snapshot.playoutOn) }
                try await self.engine.setMicrophone(false); try await self.engine.setCamera(false)
                if !(await self.captureCoordinator.closePresenter()) { throw NativeDesktopRTCError.cleanupFailed }
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
            let microphone = restoreSending && state.microphone && ownsMicrophone
            let request = headset.requestIntent(muted: !microphone)
            try await engine.setMicrophone(microphone)
            authorizedMicrophoneRequest = microphone && engine.snapshot.microphoneOn ? request : nil
            headset.confirm(muted: !engine.snapshot.microphoneOn, request: request)
            try await engine.setCamera(restoreSending && state.camera && ownsMicrophone)
            if !(restoreSending && state.camera && ownsMicrophone) { captureCoordinator.releaseCameraLease() }
            heldState = nil; transferHeld = false; holdConfirmed = false
        }
    }
    /// Live means visible to the meeting, not a private Presenter preview.
    var isSharingLive: Bool { captureCoordinator.isSharingLive(snapshotSharing: snapshot.sharing) }
    var presenterSharing: Bool { captureCoordinator.isPresenterSharing }
    @Published private(set) var shareStartedAt: Date?
    @Published private(set) var quickSharePending = false
    private func noteShareState() {
        let live = !closed && isSharingLive
        if live, shareStartedAt == nil { shareStartedAt = Date() } else if !live, shareStartedAt != nil { shareStartedAt = nil }
    }
    var shareSourceTitle: String { captureCoordinator.shareSourceTitle }
    var shareIncludesCamera: Bool {
        get { UserDefaults.standard.bool(forKey: "nativeDesktop.shareIncludesCamera") }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "nativeDesktop.shareIncludesCamera") }
    }
    /// Share popover path: the macOS picker (or an image file) is the only extra
    /// step. Cancelling the picker shares nothing; a live share switches content.
    func quickShare(image: Data? = nil) {
        guard connected, !closed, !transferHeld, !quickSharePending, !sharingPending, !captureCoordinator.hasActiveCapture else { return }
        let session = presenter, includeCamera = shareIncludesCamera, live = session.isSharing
        quickSharePending = true
        Task { @MainActor [weak self] in
            defer { self?.quickSharePending = false }
            if let image {
                if !live { await session.open() }
                await session.chooseImage(image)
            } else { await session.chooseScreen() }
            guard let self, !closed, !transferHeld else { return }
            if live {
                guard session.contentDraft?.previewTrack != nil else { return }
                do { try await session.applyContentChange() }
                catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
                return
            }
            guard session.previewTrack != nil, !session.isSharing else {
                if panel != .presenter, !session.isSharing { _ = await session.close() }
                return
            }
            if includeCamera, !session.includeCamera { await session.setIncludeCamera(true) }
            do { try await session.startSharing() }
            catch {
                if !(error is CancellationError) { self.error = error.localizedDescription }
                if panel != .presenter { _ = await session.close() }
            }
        }
    }
    /// Stop from the control bar or banner; a Presenter not open in the panel is released.
    func endShare() async {
        guard await stopSharing() else { return }
        if panel != .presenter, !captureCoordinator.isPresenterSharing { _ = await captureCoordinator.closePresenter() }
    }
    var soundSymbol: String {
        guard snapshot.playoutOn else { return "speaker.slash" }
        return meetingVolume == 0 ? "speaker.fill" : meetingVolume < 0.34 ? "speaker.wave.1.fill" : meetingVolume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
    func toggleSharing() {
        if snapshot.sharing || sharingPending { Task { await stopSharing() } }
        else { panel = .presenter }
    }
    func startSharing(presenter: Bool, canvas: Bool = false) {
        if presenter { panel = .presenter; Task { await self.presenter.open() }; return }
        guard !closed, !transferHeld, connected, !sharingPending else { return }
        let token = generation
        captureCoordinator.startSharing(
            canvas: canvas,
            isValidGeneration: { [weak self] in self?.generation == token },
            isClosed: { [weak self] in self?.closed == true },
            isSnapshotSharing: { [weak self] in self?.snapshot.sharing == true },
            engine: { [weak self] in self?.engine },
            setSharingPending: { [weak self] pending in self?.sharingPending = pending },
            setLocalShare: { [weak self] track in self?.localShare = track },
            onError: { [weak self] message in self?.error = message })
    }
    @discardableResult func stopSharing() async -> Bool {
        await captureCoordinator.stopSharing(
            engine: engine,
            isSnapshotSharing: snapshot.sharing,
            setSharingPending: { [weak self] pending in self?.sharingPending = pending },
            setLocalShare: { [weak self] track in self?.localShare = track },
            onError: { [weak self] message in self?.error = message })
    }
    private func retireShare(waitForStartup: Bool) async -> Bool {
        await captureCoordinator.retireShare(
            waitForStartup: waitForStartup,
            engine: engine,
            isSnapshotSharing: snapshot.sharing,
            setSharingPending: { [weak self] pending in self?.sharingPending = pending },
            setLocalShare: { [weak self] track in self?.localShare = track },
            onError: { [weak self] message in self?.error = message })
    }
    private func updateFeatures(_ features: GuestMeetingSnapshot) {
        guard !closed else { return }
        let previousTranscription = guestFeatures.transcriptionStatus
        guestFeatures = features
        if features.transcriptionStatus != .active || features.permissions.canViewTranscript { localFallbackDeclined = false }
        if features.transcriptionStatus == .active && !features.permissions.canViewTranscript {
            transcriptionSince = nil
        }
        participation.updateAudience(participationAudience)
        noteTranscription(from: previousTranscription, to: features.transcriptionStatus)
        updateLocalTranscription()
        observeParticipation()
        observeTranscript()
        chat.reactionHistoryAvailable = features.permissions.canSendReaction
        chat.canSend = features.permissions.canSendChat && features.connected
        chat.unavailableReason = features.permissions.canViewChat ? nil : L("Chat is unavailable in this meeting.")
        chat.replace(features.messages.map { message in
            ChatEntry(id: message.id, sender: message.participantName, text: message.text,
                sentAt: message.sentAt ?? message.receivedAt ?? Date.distantPast, isOwn: message.isOwn,
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
        let presenting = captureCoordinator.isPresenterSharingWithCamera
        guard !closed, connected, enabled, ordinary || presenting else {
            reactionDeviceLookup?.cancel(); reactionSourceKey = nil; reactionObserver.stop(); return
        }
        let source = ordinary ? "camera" : "presenter"
        let key = source + ":" + String(describing: localCamera.map(ObjectIdentifier.init)) + ":" + String(captureCoordinator.presenterCameraPreparing)
        guard key != reactionSourceKey else { return }
        reactionSourceKey = key; reactionDeviceLookup?.cancel()
        reactionDeviceLookup = Task { [weak self] in
            guard let self else { return }
            let device = ordinary ? await engine.cameraCaptureDevice() : await captureCoordinator.privatePresenterCameraDevice()
            guard !Task.isCancelled, !closed, reactionSourceKey == key else { return }
            if let device { reactionObserver.bind(device, sourceID: sessionID.uuidString + ":" + source) }
            else { reactionObserver.stop(); reactionSourceKey = nil }
        }
    }
    func sendReaction(_ kind: MeetingReaction) {
        guard let reactionService = (engine as? MeetingSession)?.reactionService,
              canReact, reactionService.canSendReactions else { return }
        let approvedID = approvedWorkspaceReactionID
        let id = approvedID ?? UUID().uuidString
        if let recorded = chat.reactionHistory.recordLocalSubmission(kind: kind,
            participantID: guestFeatures.localParticipantID ?? "local", displayName: displayName, submissionID: id) { floatReaction(recorded) }
        let task = Task {
            defer { if let approvedID { approvedWorkspaceReactionTasks[approvedID] = nil } }
            if let approvedID {
                guard !Task.isCancelled, !closed else {
                    workspaceJournal?.updateActionStatus(sessionID: workspaceSessionID, id: approvedID, status: .cancelled)
                    return
                }
                guard workspaceJournal?.updateActionStatus(sessionID: workspaceSessionID, id: approvedID, status: .sending) != false else { return }
            }
            do {
                try await reactionService.sendReaction(kind, approvedID: approvedID)
                if let approvedID { workspaceJournal?.updateActionStatus(sessionID: workspaceSessionID, id: approvedID, status: .submitted) }
            } catch let sessionError as MeetingSessionError {
                if let approvedID {
                    let status: MeetingWorkspaceEvent.Status = switch sessionError {
                    case .cancelled: .cancelled
                    case .unavailable, .notConnected, .permissionDenied, .cleanupFailed, .staleCommand: .failed
                    }
                    workspaceJournal?.updateActionStatus(sessionID: workspaceSessionID, id: approvedID, status: status)
                }
                chat.reactionHistory.setLocalDelivery(.failed, submissionID: id)
                self.error = sessionError.localizedDescription
            } catch {
                if let approvedID { workspaceJournal?.updateActionStatus(sessionID: workspaceSessionID, id: approvedID, status: .unknown) }
                chat.reactionHistory.setLocalDelivery(.failed, submissionID: id)
                self.error = error.localizedDescription
            }
        }
        if let approvedID { approvedWorkspaceReactionTasks[approvedID] = task }
    }
    private func floatReaction(_ event: MeetingReactionEvent) {
        floatingReactions.append(event); if floatingReactions.count > 4 { floatingReactions.removeFirst() }
        reactionExpiry?.cancel()
        reactionExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            self?.floatingReactions = []
        }
    }
    func loadMoreChat() { perform { if let session = $0 as? MeetingSession {
        try await session.chatService?.loadChatHistory() } } }
    func loadMoreTranscript() { perform { if let session = $0 as? MeetingSession {
        try await session.transcriptService?.loadTranscriptHistory() } } }
    func retryInitialTranscript() { (engine as? MeetingSession)?.transcriptService?.retryInitialTranscriptHistory() }
    func setTranscription(_ enabled: Bool) { perform { if let session = $0 as? MeetingSession { try await session.transcriptService?.setEnabled(enabled) } } }
    func focus(participantID: String, source: NativeDesktopVideoSource) {
        pinnedSource = display == .screenShares ? .screen : source; pinnedID = participantID; viewMode = .focused
    }
    func unpin() { pinnedSource = nil; pinnedID = nil }
    func setMediaVisible(_ visible: Bool) { setMediaPresentation(visible ? .meeting : .hidden) }
    func setMediaPresentation(_ presentation: MediaPresentation) {
        guard mediaPresentation != presentation else { return }
        mediaPresentation = presentation; updateDemand()
    }
    func setVisibleSpeakerTileIDs(_ ids: Set<String>) {
        guard visibleSpeakerTileIDs != ids else { return }
        visibleSpeakerTileIDs = ids
        updateDemand()
    }
    /// Move the floating anchor toward whatever deserves the PiP: a live screen
    /// share immediately, otherwise the active speaker after `floatingHold`.
    /// The restore fallback in `updateDemand` re-anchors when the anchored
    /// person vanishes; this governs only voluntary following.
    private func updateFloatingAnchor() {
        guard mediaPresentation == .floating || mediaPresentation == .infoCard else { return }
        let remote = videoParticipants.filter { !$0.isLocal }
        if let sharer = remote.first(where: { $0.sharing == true }) {
            floatingSpeakerTask?.cancel(); floatingSpeakerTask = nil
            if floatingParticipantID != sharer.id { floatingParticipantID = sharer.id }
            return
        }
        guard let speaker = activeSpeaker, !speaker.isLocal else { return }
        guard speaker.id != floatingParticipantID, floatingSpeakerTask == nil else { return }
        let id = speaker.id
        floatingSpeakerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.floatingSleep(self.floatingHold)
            self.floatingSpeakerTask = nil
            guard !Task.isCancelled, !self.closed, self.activeSpeaker?.id == id,
                  self.mediaPresentation == .floating || self.mediaPresentation == .infoCard else { return }
            if self.floatingParticipantID != id { self.floatingParticipantID = id; self.updateDemand() }
        }
    }
    func updateDemand() {
        guard !closed else { return }
        if let pinnedID {
            if let pinned = videos.first(where: { ($0.id == pinnedID || $0.participantID == pinnedID) && (pinnedSource == nil || $0.source == pinnedSource) }) {
                focusAffinity = (pinned.participantID, pinned.source)
            } else if focusAffinity?.participant != pinnedID { focusAffinity = (pinnedID, pinnedSource ?? .camera) }
        } else if viewMode != .gallery && display != .audioOnly,
                  let screen = participants.first(where: { $0.sharing == true && !$0.isLocal }) {
            if focusAffinity?.source != .screen ||
                !participants.contains(where: { $0.id == focusAffinity?.participant && $0.sharing == true }) {
                focusAffinity = (screen.id, .screen)
            }
        } else if viewMode == .gallery || (viewMode == .automatic && display == .audioOnly) { focusAffinity = nil }
        else if viewMode == .focused && display == .screenShares && !videoParticipants.isEmpty {
            if focusAffinity?.source != .screen || !videoParticipants.contains(where: { $0.id == focusAffinity?.participant }) {
                focusAffinity = videoParticipants.first.map { ($0.id, .screen) }
            }
        }
        else if viewMode == .focused && (focusAffinity == nil || !participants.contains(where: { $0.id == focusAffinity?.participant })) {
            let camera = videos.first(where: { $0.source == .camera })?.participantID
                ?? participants.first(where: { !$0.isLocal && $0.cameraOn == true })?.id
                ?? participants.first(where: { !$0.isLocal })?.id
            focusAffinity = camera.map { ($0, .camera) }
        }
        let receivesVideo = (mediaPresentation == .meeting || mediaPresentation == .floating) && display != .audioOnly
        let singleVideo = showsFocus || mediaPresentation == .floating
        if mediaPresentation == .floating && !showsFocus {
            // Track lists disappear while unsubscribed. Keep demand anchored to
            // roster identity so restoring the floating window can request it again.
            if !videoParticipants.contains(where: { $0.id == floatingParticipantID && !$0.isLocal }) {
                let remote = videoParticipants.filter { !$0.isLocal }
                floatingParticipantID = remote.first(where: { $0.sharing == true })?.id
                    ?? remote.first(where: { $0.cameraOn == true })?.id
                    ?? remote.first?.id
            }
        }
        let focused = receivesVideo && singleVideo ? (showsFocus ? focusedParticipantID : floatingParticipantID) : nil
        let presenter = focusedSharePresenter
        let prioritizesPresenterCamera = receivesVideo && receivesCameras && mediaPresentation == .meeting
            && presenter?.isLocal == false
        var shown = singleVideo ? [focused].compactMap { $0 } : galleryParticipants.map(\.id)
        if let focused, mediaPresentation == .meeting, receivesCameras,
           focusAffinity?.source == .screen || focusedVideo?.source == .screen {
            // The focused participant already requests both tracks. Leave room
            // for their screen and camera in the Guest subscriber's six slots.
            let cameraSlots = prioritizesPresenterCamera && presenter?.cameraOn != false ? 4 : 5
            let cameraTiles = railParticipants.filter {
                $0.id != focused && !$0.isLocal && $0.cameraOn != false && visibleSpeakerTileIDs.contains($0.id)
            }
            shown += cameraTiles.prefix(cameraSlots).map(\.id)
        }
        // Visible tiles stay; video is requested only for the ones this mode receives.
        let receivable = Set(videoParticipants.map(\.id))
        let ids = !receivesVideo ? Set<String>() : Set(shown.filter { display == .all || receivable.contains($0) })
        let floatingScreen = mediaPresentation == .floating && !showsFocus && participants.contains { $0.id == focused && $0.sharing == true }
        let preferredScreen = receivesVideo && (focusAffinity?.source == .screen || focusedVideo?.source == .screen || floatingScreen)
            ? focused : nil
        let cameras = receivesCameras
        let key = [ids.sorted().joined(separator: "|"), focused ?? "", preferredScreen ?? "",
                   cameras ? "cameras" : "screens", String(prioritizesPresenterCamera)].joined(separator: "#")
        guard demandKey != key, connected else { return }
        let previous = demandTask
        previous?.cancel()
        demandKey = key
        demandTask = Task { [weak self] in
            // A subscription request already sent to the provider can finish
            // after cancellation. Apply the newest viewport after it settles.
            await previous?.value
            guard let self, !Task.isCancelled, connected, !closed else { return }
            do {
                if let session = engine as? MeetingSession {
                    try await session.setVideoDemand(.init(visibleParticipantIDs: ids, focusedParticipantID: focused,
                                                           preferredScreenParticipantID: preferredScreen, receivesCameras: cameras,
                                                           prioritizesPresenterCamera: prioritizesPresenterCamera))
                } else { try await engine.setVisibleParticipantIDs(ids, focusedParticipantID: focused, cameras: cameras) }
            }
            catch { if !Task.isCancelled { demandKey = nil } }
        }
    }
    func leave() async -> Bool {
        await beginLeave().value
    }
    private func beginLeave() -> Task<Bool, Never> {
        if let leaveTask { return leaveTask }
        let leftAt = Date()
        cancelWorkspaceApprovedOutputs()
        participation.stop(.meetingEnded)
        captureCoordinator.beginLeave(sessionID: sessionID); power.stop()
        closed = true; generation = UUID(); snapshot.phase = .leaving; headset.end()
        updateLocalTranscription()
        let startup = connectionTask; connectionTask = nil; startup?.cancel()
        (engine as? MeetingSession)?.abortPendingStartup()
        requestedMicrophone = nil; requestedCamera = nil; requestedPlayout = nil; authorizedMicrophoneRequest = nil
        snapshot.microphoneOn = false; snapshot.cameraOn = false; snapshot.sharing = false; snapshot.playoutOn = false
        localCamera = nil; videos = []
        engine.onState = nil; engine.onVideo = nil; engine.onLocalCamera = nil; engine.onTitle = nil
        if let session = engine as? MeetingSession {
            session.onFeatures = nil; session.onFeatureError = nil; session.onCapturedMessages = nil
        }
        connection?.finish(.failure(CancellationError())); connection = nil
        let cleanup = Task { @MainActor in
            // Leave can unblock a suspended native/session connect. Its result
            // is retained while startup drains; a timeout never releases ownership.
            let initialEngineStop: Task<Bool, Never>? = startup == nil ? nil : Task { @MainActor in await self.engine.leave() }
            let controls = Array(self.controlTasks.values)
            controls.forEach { $0.cancel() }; self.holdTask?.cancel(); self.demandTask?.cancel()
            for task in controls { await task.value }
            await self.captureCoordinator.awaitJoinPrimeAndMetadata()
            _ = try? await self.holdTask?.value; await self.demandTask?.value
            self.reactionDeviceLookup?.cancel(); self.reactionObserver.stop()
            self.reactionExpiry?.cancel()
            let previewsStopped = await NativeDesktopDeviceModel.stopPrivatePreview()
            let presenterStopped = await self.captureCoordinator.closePresenter()
            let shareStopped = await self.stopSharing()
            self.localCamera = nil; self.videos = []
            _ = try? await startup?.value
            let initiallyStopped = await initialEngineStop?.value ?? true
            let finallyStopped = await self.engine.leave()
            let engineStopped = initiallyStopped && finallyStopped
            let clean = engineStopped && shareStopped && presenterStopped && previewsStopped && self.captureCoordinator.joinCameraPrimeCleanupSucceeded
            if let token = self.externalMediaSuspension {
                self.sharedMedia.resume(token, clean: clean)
                self.externalMediaSuspension = nil
            }
            if let claim = self.mediaClaim { self.sharedMedia.resume(claim, clean: clean); self.mediaClaim = nil }
            self.captureCoordinator.finishLeaveLease(engineStopped: engineStopped)
            await self.catchUp.finishMeeting().value
            await self.finalizeWorkspaceCapture(leftAt: leftAt)
            if clean { self.snapshot = .init(phase: .left, playoutOn: false) }
            else { self.snapshot.phase = .failed }
            self.engine.onState = nil; self.engine.onVideo = nil; self.engine.onLocalCamera = nil; self.engine.onTitle = nil
            return clean
        }
        leaveTask = cleanup
        return cleanup
    }

    private func finalizeWorkspaceCapture(leftAt: Date) async {
        guard let workspaceJournal else { return }
        let transcription = Array(transcriptionDrains.values)
        let approvedVoice = workspaceApprovedVoice?.drain
        let (results, output) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingOldest(1))
        Task { @MainActor [participation] in
            await participation.waitForWorkspaceOutbound()
            await approvedVoice?()
            for drain in transcription { await drain.value }
            output.yield(true)
        }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            output.yield(false)
        }
        var iterator = results.makeAsyncIterator()
        if await iterator.next() == false, !transcriptionDrains.isEmpty {
            workspaceJournal.recordGap(sessionID: workspaceSessionID, reason: "finalization", from: leftAt, until: .now)
        }
        timeout.cancel()
        output.finish()
        observeWorkspace([])
        workspaceJournal.end(sessionID: workspaceSessionID, at: leftAt)
    }
}
