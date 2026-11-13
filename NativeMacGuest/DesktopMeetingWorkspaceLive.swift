import AppKit
import ConferenceCore
import SwiftUI

struct WorkspaceLiveMeeting: View {
    enum Style { case card, parallel, focused }

    @ObservedObject var workspace: NativeDesktopWorkspace
    @ObservedObject var state: MeetingWorkspaceViewState
    @ObservedObject var model: NativeDesktopMeetingModel
    @ObservedObject private var attention: AttentionCoordinator
    @ObservedObject private var participation: ParticipationCoordinator
    @ObservedObject private var store: AttentionStore
    @ObservedObject private var chat: ChatStore
    var session: MeetingWorkspaceSession?
    var selected: Bool
    var style: Style

    @State private var showModes = false
    @State private var takeOver = false
    @State private var movingMicrophone = false
    @State private var followLatest = true
    @State private var editing: ParticipationCoordinator.WorkspaceDraft?
    @State private var editText = ""
    @State private var feedback: String?

    init(workspace: NativeDesktopWorkspace, state: MeetingWorkspaceViewState,
         model: NativeDesktopMeetingModel, session: MeetingWorkspaceSession?, selected: Bool, style: Style) {
        self.workspace = workspace
        self.state = state
        self.model = model
        self.session = session
        self.selected = selected
        self.style = style
        _attention = ObservedObject(wrappedValue: workspace.attention)
        _participation = ObservedObject(wrappedValue: model.participation)
        _store = ObservedObject(wrappedValue: workspace.attention.store)
        _chat = ObservedObject(wrappedValue: model.chat)
    }

    private var sessionID: UUID { model.sessionID }
    private var events: [MeetingWorkspaceEvent] { session?.visibleEvents ?? [] }
    private var canControl: Bool { model.connected && !model.isClosed }
    private var soundOn: Bool { model.participationMeetingSoundOn }
    private var followingPause: UUID? { attention.workspaceFollowingPauses[sessionID] }
    private var paused: Bool { participation.status == .paused || (participation.status != .observing && followingPause != nil) }
    private var selectedReplyID: String? { state.liveReplyIDs[sessionID] }

    private var guidance: Binding<String> {
        Binding(get: { state.guidanceDrafts[sessionID, default: ""] },
                set: { state.guidanceDrafts[sessionID] = $0 })
    }
    private var manualText: Binding<String> {
        Binding(get: { state.manualDrafts[sessionID, default: ""] },
                set: { state.manualDrafts[sessionID] = $0 })
    }

    var body: some View {
        Group {
            switch style {
            case .card: card
            case .parallel: parallel
            case .focused: focused
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meetingWorkspace.live.\(sessionID.uuidString)")
        .sheet(item: $editing) { draft in draftEditor(draft) }
    }

    private var stateTitle: String {
        if !model.connected { return L(model.snapshot.phase.rawValue.capitalized) }
        if followingPause != nil && participation.status != .observing { return L("Assistant paused") }
        if !store.enabled { return L("Assistant off") }
        if participation.status != .inactive { return participation.status.title }
        return switch attention.resolvedMode(model).mode {
        case .off: L("Assistant off")
        case .mentions: L("Following mentions")
        case .watch: L("Following conversation")
        }
    }

    private var stateColor: Color {
        if !canControl || [.review, .unavailable].contains(participation.status) || followingWaiting != nil { return .orange }
        if !store.enabled || paused { return .secondary }
        return .teal
    }

    private var stateBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(stateColor).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(stateTitle).lineLimit(1).font(.caption.weight(.semibold)).foregroundStyle(stateColor)
        }
        .help(participation.reason?.message ?? followingWaiting ?? stateTitle)
    }

    private var followingWaiting: String? {
        guard participation.status == .inactive, attention.resolvedMode(model).mode != .off else { return nil }
        return attention.waitingReason(model)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(action: focus) {
                Text(model.title).font(.headline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).help(model.title)
            HStack {
                stateBadge
                if followingWaiting != nil {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(followingWaiting ?? "")
                }
                Spacer(minLength: 4)
                Image(systemName: soundOn ? "speaker.wave.2" : "speaker.slash").foregroundStyle(.secondary)
                    .accessibilityLabel(soundOn ? L("Meeting sound on") : L("Meeting sound off"))
            }
            Divider()
            previewLine(events.last { $0.kind == .transcript || $0.kind == .chat }, empty: L("Waiting for conversation"))
            previewLine(events.last { $0.kind == .assistantReply }, empty: L("No assistant reply yet"), assistant: true)
        }
        .padding(11).frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .topLeading)
        .modifier(WorkspacePanel(selected: selected))
        .contextMenu { pauseButton; Button(L("Open meeting")) { workspace.showMeeting(model) } }
    }

    @ViewBuilder private func previewLine(_ event: MeetingWorkspaceEvent?, empty: String, assistant: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let event {
                Text(assistant ? event.displayStatus : event.displayAuthor)
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Text(event.displayText).font(.caption).lineLimit(1)
            } else {
                Text(empty).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 23, alignment: .leading)
    }

    private var parallel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: focus) {
                Label(model.title, systemImage: "arrow.up.right")
                    .font(.headline).lineLimit(1)
            }.buttonStyle(.plain).help(L("Open focused conversation"))
            HStack { stateBadge; Spacer(minLength: 0); pauseButton }
            HStack { soundButton(compact: true); Spacer(); modesButton(compact: true) }
            captureStatus
            Divider()
            WorkspaceTimeline(events: events, empty: L("Waiting for conversation"), live: true, followsLatest: followLatest,
                selectedID: selectedReplyID, onSelect: { id in state.liveReplyIDs[sessionID] = id; focus() },
                onBookmark: toggleBookmark)
                .frame(minHeight: 44)
            if let draft = participation.workspaceQueuedDraft {
                VStack(alignment: .leading, spacing: 5) {
                    Text(draft.text).lineLimit(2).font(.caption)
                    Button(L("Hold this reply")) {
                        if participation.holdWorkspaceDraft(id: draft.id) { feedback = L("Reply held") }
                    }
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            }
            guidanceComposer(compact: true)
            if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12).frame(maxHeight: .infinity, alignment: .topLeading)
        .modifier(WorkspacePanel())
    }

    private var focused: some View {
        GeometryReader { geometry in
            let inspectorInline = geometry.size.width >= 805
            let scrollControls = geometry.size.height < 345 || takeOver
            HStack(alignment: .top, spacing: 12) {
                let conversation = VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.title).font(.title3.weight(.semibold)).lineLimit(1).help(model.title)
                        Spacer(minLength: 4)
                        Button(L("I’ll answer"), systemImage: "hand.raised", action: beginTakeover)
                            .disabled(!canControl)
                            .accessibilityIdentifier("meetingWorkspace.takeOver")
                    }
                    HStack {
                        stateBadge
                        Text(L("%ld participants", model.participants.count)).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        pauseButton
                        modesButton()
                    }
                    HStack {
                        soundButton()
                        Button(L("Open meeting"), systemImage: "video") { workspace.showMeeting(model) }
                            .buttonStyle(.borderless)
                        Spacer(minLength: 4)
                        Toggle(L("Follow latest"), isOn: $followLatest).toggleStyle(.checkbox).font(.caption)
                    }
                    captureStatus
                    Divider()
                    WorkspaceTimeline(events: events, empty: L("Waiting for conversation"), live: true,
                        followsLatest: followLatest, selectedID: selectedReplyID, onSelect: { state.liveReplyIDs[sessionID] = $0 },
                        onBookmark: toggleBookmark)
                        .frame(minHeight: 36)
                        .frame(height: scrollControls ? max(95, geometry.size.height * 0.35) : nil)
                    if !inspectorInline {
                        DisclosureGroup(selectedReplyID == nil ? L("Working context") : L("Why this reply")) {
                            ScrollView { inspectorContent.padding(.top, 8) }.frame(maxHeight: 160)
                        }
                    }
                    if participation.workspaceQueuedDraft != nil || participation.workspaceHeldDraft != nil { draftControls }
                    if takeOver { manualComposer }
                    if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    guidanceComposer(compact: false)
                }
                if scrollControls {
                    ScrollView { conversation.padding(12) }.modifier(WorkspacePanel())
                } else {
                    conversation.padding(12).modifier(WorkspacePanel())
                }
                if inspectorInline {
                    ScrollView { inspectorContent.padding(13) }
                        .frame(width: min(265, geometry.size.width * 0.31), alignment: .topLeading)
                        .modifier(WorkspacePanel())
                }
            }
        }
    }

    private var captureStatus: some View {
        let key: String
        let symbol: String
        switch model.transcriptionIndicator {
        case .on: key = "Service transcript"; symbol = "waveform"
        case .local: key = "Transcribing on this Mac"; symbol = "waveform"
        case .failed: key = "Transcription failed"; symbol = "exclamationmark.triangle"
        case nil: key = "Speech transcript unavailable"; symbol = "waveform.slash"
        }
        return Label(L(key), systemImage: symbol).font(.caption).foregroundStyle(.secondary)
    }

    private var pauseButton: some View {
        Button(paused ? L("Resume") : L("Pause")) {
            state.restorePauses[sessionID] = nil
            if paused {
                resumeAssistant()
            } else if state.pause(model, attention: attention) != nil {
                recordAction(L("Assistant paused"), source: "pause")
            }
        }
        .buttonStyle(.borderless).font(.caption)
        .disabled(!canControl || (!paused && (!store.enabled || attention.resolvedMode(model).mode == .off)))
    }

    private func resumeAssistant() {
        let wasParticipating = participation.status == .paused
        let wasFollowing = followingPause != nil
        participation.resume()
        if let token = followingPause { attention.resumeWorkspaceFollowing(model, pause: token) }
        takeOver = false
        feedback = nil
        if (wasParticipating && participation.status == .observing) || (wasFollowing && followingPause == nil) {
            recordAction(L("Assistant resumed"), source: "resume")
        }
    }

    private func soundButton(compact: Bool = false) -> some View {
        Button {
            if model.snapshot.playoutOn && model.meetingVolume == 0 {
                model.setMeetingVolume(0.5)
            } else {
                model.togglePlayout()
            }
        } label: {
            if compact {
                Label(soundOn ? L("Meeting sound on") : L("Meeting sound off"),
                      systemImage: soundOn ? "speaker.wave.2" : "speaker.slash")
                    .labelStyle(.iconOnly)
            } else {
                Label(soundOn ? L("Meeting sound on") : L("Sound off · private replies"),
                      systemImage: soundOn ? "speaker.wave.2" : "speaker.slash")
            }
        }
        .disabled(!canControl)
        .help(soundOn ? L("Turn off meeting sound") : L("Turn on meeting sound"))
        .accessibilityIdentifier("meetingWorkspace.sound")
    }

    private func modesButton(compact: Bool = false) -> some View {
        Button { showModes.toggle() } label: {
            if compact {
                Label(L("Assistant modes"), systemImage: "slider.horizontal.3").labelStyle(.iconOnly)
            } else {
                Label(L("Assistant modes"), systemImage: "slider.horizontal.3")
            }
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $showModes) {
            AttentionModePicker(attention: attention, model: model) { showModes = false }
        }
    }

    private func guidanceComposer(compact: Bool) -> some View {
        WorkspaceComposer(title: L("Private guidance"), placeholder: L("Give your assistant direction for this meeting…"),
            actionTitle: compact ? L("Apply") : L("Apply guidance"),
            text: guidance, canSubmit: canControl && store.enabled,
            maximum: MeetingWorkspaceGuidance.maximumLength, symbol: "lock", perform: {
                guard attention.applyWorkspaceGuidance(guidance.wrappedValue, for: model) else {
                    feedback = L("Guidance could not be applied.")
                    return
                }
                guidance.wrappedValue = ""
                feedback = L("Guidance applied to this meeting")
            })
    }

    private func beginTakeover() {
        guard canControl else { return }
        _ = state.pause(model, attention: attention)
        participation.yieldToUser()
        state.restorePauses[sessionID] = nil
        takeOver = true
        recordAction(L("You took over"), source: "takeover")
    }

    private var manualComposer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(L("You’re answering in %@", model.title)).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                Button(L("Done")) { takeOver = false }.buttonStyle(.borderless)
            }
            Button(action: controlMicrophone) {
                Label(micAction, systemImage: model.assistantMicrophoneOn ? "mic.fill" : "mic.slash")
            }.disabled(movingMicrophone || !canControl || model.microphoneRestriction != nil)
            if let restriction = model.microphoneRestriction {
                Text(restriction).font(.caption).foregroundStyle(.secondary)
            }
            WorkspaceComposer(title: L("Your message to this meeting"), placeholder: L("Write a chat message…"),
                actionTitle: L("Send to meeting chat"), text: manualText, canSubmit: canControl && chat.canSend,
                symbol: "bubble.left", perform: {
                    let text = manualText.wrappedValue
                    guard chat.send(text) else {
                        feedback = L("The meeting did not accept the message. Open the meeting to answer.")
                        return
                    }
                    manualText.wrappedValue = ""
                    feedback = nil
                })
            if !chat.canSend {
                Text(chat.unavailableReason ?? L("Meeting chat unavailable")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(9).background(.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var micAction: String {
        if !model.ownsMicrophone { return L("Move microphone here · keep muted") }
        return model.assistantMicrophoneOn ? L("Mute microphone") : L("Unmute in this meeting")
    }

    private func controlMicrophone() {
        guard !movingMicrophone, canControl, model.microphoneRestriction == nil else { return }
        if model.ownsMicrophone {
            model.toggleMicrophone()
        } else {
            movingMicrophone = true
            Task {
                let moved = await workspace.claimTalk(for: model)
                movingMicrophone = false
                if !moved { feedback = L("The microphone could not be moved.") }
            }
        }
    }

    @ViewBuilder private var draftControls: some View {
        if let draft = participation.workspaceQueuedDraft {
            HStack {
                Label(L("Reply waiting · draft"), systemImage: "hourglass").font(.caption.weight(.semibold))
                Text(draft.text).lineLimit(1).font(.caption)
                Spacer(minLength: 4)
                Button(L("Hold this reply")) {
                    if participation.holdWorkspaceDraft(id: draft.id) { feedback = L("Reply held") }
                }
                Button(L("Edit draft")) {
                    if participation.holdWorkspaceDraft(id: draft.id) { startEditing(draft) }
                }
            }
            .padding(8).background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        } else if let held = participation.workspaceHeldDraft {
            HStack {
                Label(L("Reply held"), systemImage: "pause").font(.caption.weight(.semibold))
                Text(held.text).lineLimit(1).font(.caption)
                Spacer(minLength: 4)
                Button(L("Edit draft")) { startEditing(held) }
            }
            .padding(8).background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func startEditing(_ draft: ParticipationCoordinator.WorkspaceDraft) {
        editText = draft.text
        feedback = nil
        editing = draft
    }

    private func draftEditor(_ draft: ParticipationCoordinator.WorkspaceDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Reply held while you edit")).font(.headline)
            Text(model.title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $editText).font(.body).frame(height: 76)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                .accessibilityLabel(L("Edit draft"))
            Text(L("A revised reply is checked against the current conversation before delivery."))
                .font(.caption).foregroundStyle(.secondary)
            if let feedback { Text(feedback).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(L("Cancel")) { editing = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Save and keep held")) {
                    if participation.saveWorkspaceDraft(id: draft.id, text: editText) { editing = nil }
                    else { feedback = L("The draft could not be saved.") }
                }
                Button(L("Queue revised reply")) {
                    if participation.requeueWorkspaceDraft(id: draft.id, text: editText) {
                        feedback = L("Checking the revised reply")
                        editing = nil
                    } else { feedback = L("The draft can no longer be queued.") }
                }
                .disabled(!participation.canRequeueWorkspaceDraft(id: draft.id))
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 465)
    }

    @ViewBuilder private var inspectorContent: some View {
        if let reply = events.first(where: { $0.id == selectedReplyID && $0.kind == .assistantReply }) {
            VStack(alignment: .leading, spacing: 9) {
                Button { state.liveReplyIDs[sessionID] = nil } label: { Label(L("Working context"), systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                WorkspaceReplyEvidence(event: reply, title: L("Why this reply"))
            }
        } else {
            VStack(alignment: .leading, spacing: 11) {
                Text(L("Working context")).font(.headline)
                if let reason = participation.reason?.message ?? followingWaiting {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                let preset = store.preset(room: model.invitation, series: model.calendarSeriesID)
                let direction = [participation.objective, preset?.matters ?? "", preset?.never ?? ""].filter { !$0.isEmpty }
                    + store.workspaceGuidance.instructions(for: model) + participation.workspaceGuidance
                if !direction.isEmpty {
                    Text(L("Your direction")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(direction.enumerated()), id: \.offset) { _, instruction in
                        Text(instruction).font(.callout).textSelection(.enabled)
                    }
                }
                let sources = participation.approvedNotes
                if !sources.isEmpty || preset?.about.isEmpty == false {
                    Divider()
                    Text(L("Available knowledge")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let about = preset?.about, !about.isEmpty {
                        DisclosureGroup(L("Meeting information")) { Text(about).textSelection(.enabled) }
                    }
                    ForEach(sources) { approval in
                        DisclosureGroup(approval.grant.source.title) {
                            Text(approval.grant.source.markdown).textSelection(.enabled).lineLimit(12)
                        }
                    }
                }
                Divider()
                Text(L("Reply settings")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if participation.status == .inactive {
                    Text(L("Participation is off")).font(.callout)
                } else if !soundOn {
                    Label(L("Sound off · private replies"), systemImage: "lock").font(.callout)
                } else if participation.output == .voice {
                    Label(store.voiceConfiguration.title, systemImage: "waveform").font(.callout)
                    if let restriction = model.microphoneRestriction {
                        Text(restriction).font(.caption).foregroundStyle(.secondary)
                    } else if !model.ownsMicrophone {
                        Text(L("Voice stays private here until you move the microphone assignment to this meeting."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !model.participationVoiceEligible {
                        Text(L("Assistant speech is currently unavailable in this meeting."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Label(L("Meeting chat"), systemImage: "bubble.left").font(.callout)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func focus() {
        state.focusedID = sessionID
        state.parallel = false
    }

    private func toggleBookmark(_ id: String) {
        model.workspaceJournal?.toggleBookmark(sessionID: sessionID, eventID: id)
    }

    private func recordAction(_ text: String, source: String) {
        model.workspaceJournal?.recordAction(sessionID: sessionID, text: text, source: source)
    }
}

struct WorkspaceComposer: View {
    let title: String
    let placeholder: String
    let actionTitle: String
    @Binding var text: String
    let canSubmit: Bool
    var maximum: Int?
    let symbol: String
    let perform: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold))
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3).accessibilityLabel(title)
                    .accessibilityIdentifier(symbol == "lock" ? "meetingWorkspace.privateGuidance" : "meetingWorkspace.manualMessage")
                Button(actionTitle, action: perform).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(symbol == "lock" ? "meetingWorkspace.applyGuidance" : "meetingWorkspace.sendManualMessage")
                    .disabled(!canSubmit || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || maximum.map { text.count > $0 } == true)
            }
            if let maximum, text.count > maximum {
                Text(L("Use up to %ld characters per instruction.", maximum)).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
