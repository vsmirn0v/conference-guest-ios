import SwiftUI

struct ParticipationSetupView: View {
    @ObservedObject var participation: ParticipationCoordinator
    @ObservedObject var model: NativeDesktopMeetingModel
    @ObservedObject var store: AttentionStore
    @ObservedObject private var clone = VoiceCloneStore.shared
    @State private var reviewed: ParticipationSetup?
    @State private var objective = ""
    @State private var scopeChanged = false
    @State private var startFailure: ParticipationCoordinator.Reason?
    @State private var noteContext: ParticipationKnowledgeReviewContext?
    @State private var notes: [ParticipationKnowledgeApproval] = []
    @State private var reviewingNotes = false
    @State private var output: ParticipationOutput = .chat
    var back: () -> Void
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: back) { Label(L("Assistant modes"), systemImage: "chevron.left") }
                .buttonStyle(.borderless)
            Text(participation.status == .inactive ? L("Participate in this meeting") : participation.status.title)
                .font(.headline)
            if let reviewed {
                settings(reviewed)
            } else {
                Text(unavailableReason)
                    .foregroundStyle(.secondary)
            }
            if let startFailure {
                Text(startFailure.message).foregroundStyle(.orange)
            } else if scopeChanged {
                Text(L("Review the updated participation settings before continuing."))
                    .foregroundStyle(.orange)
            }
            activity
            HStack {
                Button(L("Close"), action: close)
                Spacer()
                if participation.status == .observing {
                    Button(L("Pause participation")) { participation.pause() }
                } else if scopeChanged {
                    Button(L("Review updated scope")) { captureScope() }
                } else if participation.status == .paused {
                    Button(L("Resume")) {
                        participation.resume()
                        if participation.status == .observing { close() }
                    }
                        .keyboardShortcut(.defaultAction)
                } else if let reviewed {
                    Button(participation.status == .review || participation.status == .unavailable
                        ? L("Restart participation") : L("Start participating")) {
                        if participation.start(reviewed, objective: objective, model: model, store: store,
                                               context: noteContext, notes: notes, output: output) { close() }
                        else {
                            startFailure = participation.startFailure
                            scopeChanged = participation.startFailure != .voiceUnavailable
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(output == .voice && (!model.participationVoiceAvailable
                        || (reviewed.voice.engine == .rapidMLX && !notes.isEmpty)))
                    .accessibilityIdentifier("participation.start")
                }
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 355)
        .onAppear {
            objective = participation.objective
            output = participation.status == .inactive ? store.lastParticipationOutput : participation.output
            captureScope()
        }
        .onChange(of: output) { newOutput in
            startFailure = nil
            if participation.output != newOutput { participation.requireReview(.replyChannelChanged, revokeSources: false) }
            invalidatePreview()
        }
        .onChange(of: participation.rosterEpoch) { _ in
            if participation.status == .observing, notes.isEmpty, !reviewingNotes,
               let current = participation.setup(for: model, store: store), reviewed?.provider == current.provider {
                captureScope()
            } else {
                invalidatePreview()
            }
        }
        .onChange(of: store.provider) { _ in invalidatePreview() }
        .onChange(of: store.voiceConfiguration) { _ in invalidatePreview() }
        .onChange(of: clone.stored?.recordedAt) { _ in invalidatePreview() }
        .onChange(of: model.title) { _ in invalidatePreview() }
        .onChange(of: participation.revokedNoteIDs) { revoked in notes.removeAll { revoked.contains($0.id) } }
        .sheet(isPresented: $reviewingNotes) {
            if let noteContext {
                ParticipationKnowledgeReviewSheet(context: noteContext,
                    currentContext: { currentKnowledgeContext(expiry: noteContext.expiresAt) },
                    approvals: notes, onApprove: { approval in
                        guard noteContext.matches(currentKnowledgeContext(expiry: noteContext.expiresAt)), notes.count < 2,
                              !notes.contains(where: { $0.grant.source == approval.grant.source }) else { return false }
                        if participation.status == .observing || participation.status == .paused {
                            participation.requireReview(.noteAccessChanged, revokeSources: false)
                        }
                        notes.append(approval)
                        return true
                    }, onRevoke: { id in
                        participation.revokeSource(id)
                        notes.removeAll { $0.id == id }
                    })
            }
        }
    }

    private var unavailableReason: String {
        if !store.enabled { return L("Turn on Assistant in Settings to participate.") }
        if model.participationAudience == nil {
            return L("Participation requires a connected Guest meeting with chat and a visible participant list.")
        }
        return L("Choose an available model for Assistant in Settings to participate.")
    }

    private func captureScope() {
        startFailure = nil
        reviewed = participation.setup(for: model, store: store)
        if let active = participation.sourceContext, active.matches(currentKnowledgeContext(expiry: active.expiresAt)) {
            noteContext = active
            notes = participation.approvedNotes
        } else {
            noteContext = currentKnowledgeContext(expiry: Date().addingTimeInterval(8 * 60 * 60))
            notes = []
        }
        scopeChanged = false
    }

    private func invalidatePreview() {
        if let noteContext, !noteContext.matches(currentKnowledgeContext(expiry: noteContext.expiresAt)) {
            notes = []
            self.noteContext = nil
            reviewingNotes = false
        }
        let current = participation.setup(for: model, store: store)
        scopeChanged = reviewed.map { !$0.matches(current, output: output) } ?? (current != nil)
        if !scopeChanged && noteContext == nil {
            noteContext = currentKnowledgeContext(expiry: Date().addingTimeInterval(8 * 60 * 60))
        }
    }

    private func currentKnowledgeContext(expiry: Date) -> ParticipationKnowledgeReviewContext? {
        participation.setup(for: model, store: store)?.knowledgeContext(title: model.title, expiresAt: expiry)
    }

    @ViewBuilder private func settings(_ reviewed: ParticipationSetup) -> some View {
        let provider = reviewed.provider
        VStack(alignment: .leading, spacing: 4) {
            Text(model.title).font(.subheadline.weight(.semibold))
            Text(reviewed.audience.room.displayDetails).foregroundStyle(.secondary)
            let names = reviewed.audience.members.values.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
            DisclosureGroup(L("Current audience (%ld)", names.count)) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                            Text(name).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 100)
            }
        }
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            Picker(L("Reply in this meeting"), selection: $output) {
                ForEach(ParticipationOutput.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("participation.output")
            Text(L("Replies are sent on your behalf. A prefix is added only when your instructions request one."))
            if output == .voice {
                Text(L("Automatic voice · %@", reviewed.voice.title)).font(.callout.weight(.semibold))
                Text(L("Replies use your selected voice and instructions. Your microphone can stay muted. With meeting sound off, replies appear as private text in Chat and Live text."))
                if let host = reviewed.voice.speechHost {
                    Text(L("Speech synthesis · %@ receives reply text", host)).foregroundStyle(.secondary)
                }
                if reviewed.voice.engine == .rapidMLX && !notes.isEmpty {
                    Text(ParticipationCoordinator.Reason.noteVoiceProcessor.message).foregroundStyle(.orange)
                }
                if !model.participationVoiceAvailable {
                    Text(L("Turn on Voice replies in Settings → General and rejoin."))
                        .foregroundStyle(.orange)
                } else if !model.participationVoiceMicrophoneAuthorized {
                    if model.participationVoiceCanRequestMicrophoneAccess {
                        Button(L("Allow microphone access…")) { Task { await model.requestParticipationVoiceMicrophoneAccess() } }
                            .buttonStyle(.borderless)
                        Text(L("Access prepares meeting audio while your microphone stays muted."))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L("Allow microphone access in System Settings to prepare meeting audio while muted."))
                            .foregroundStyle(.orange)
                    }
                } else if !model.participationMeetingSoundOn {
                    Text(L("Meeting sound is off. Replies appear as private text.")).foregroundStyle(.secondary)
                } else if !model.participationVoiceHasTranscript {
                    Text(L("Voice waits for meeting transcription. Replies appear here as private text while it is unavailable."))
                        .foregroundStyle(.orange)
                } else if !model.participationVoiceEligible {
                    Text(L("Voice waits until this meeting holds the talk role and its audio is ready."))
                        .foregroundStyle(.orange)
                }
            }
            Text(model.participationTranscriptSource == .localRoomAudio
                ? L("Sources · Live chat and on-device transcription")
                : L("Sources · Live chat and available meeting transcription"))
            Text(L("Uses meeting info, notes and Assistant instructions. Searches the selected Obsidian vault for relevant answers, including when automatic export is paused."))
                .foregroundStyle(.secondary)
            if noteContext != nil {
                HStack {
                    Button(L("Review notes…")) { reviewingNotes = true }.buttonStyle(.borderless)
                    Text(L("%ld approved notes", notes.count)).foregroundStyle(.secondary)
                }
                Text(L("Replies can use one relevant excerpt from each of up to two approved notes."))
                    .foregroundStyle(.secondary)
            }
            Text(provider.onThisMac
                 ? L("Processor · %@ on this Mac", provider.model)
                 : L("Processor · %@ at %@ receives relevant meeting and Obsidian excerpts and your instructions", provider.model, provider.host))
            Text(notes.isEmpty
                 ? L("Live chat and transcription can be used for replies to everyone who joins this meeting. Earlier discussion is discarded when the audience changes.")
                 : L("Replies using approved notes are limited to the current audience. Review access again if the participant list changes."))
                .foregroundStyle(.secondary)
            Text(L("Participation ends when you leave or restart the app."))
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        if participation.status == .inactive || participation.status == .review || participation.status == .unavailable {
            TextField(L("Meeting objective (optional)"), text: $objective)
                .accessibilityIdentifier("participation.objective")
        }
    }

    @ViewBuilder private var activity: some View {
        if participation.voiceInProgress {
            HStack {
                Text(participation.voiceReplies.last?.status.title ?? L("Assistant speaking"))
                Spacer()
                Button(L("Stop speaking")) { participation.interruptVoice() }
                    .accessibilityIdentifier("participation.voice.stop")
            }
        } else if participation.status == .observing, participation.queuedText == nil {
            Text(decisionMessage ?? (model.participationVoiceHasTranscript
                ? L("Following the discussion") : L("Using meeting chat only")))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("participation.activity.status")
        } else if let reason = participation.reason {
            Text(reason.message)
                .foregroundStyle(participation.status == .review || participation.status == .unavailable
                    ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let queued = participation.queuedText {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L("Ready to add")).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(L("Cancel")) { participation.cancelCandidate() }
                        .accessibilityIdentifier("participation.cancel")
                }
                Text(queued).textSelection(.enabled)
            }
        }
        if let insight = participation.privateInsight {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Only you")).font(.subheadline.weight(.semibold))
                Text(insight).textSelection(.enabled)
            }
        }
        if !participation.receipts.isEmpty {
            DisclosureGroup(L("Assistant activity")) {
                ForEach(Array(participation.receipts.prefix(5))) { receipt in
                    HStack {
                        Text(receipt.title)
                        Spacer()
                        Text(receipt.updatedAt, style: .time)
                    }
                    .font(.caption)
                }
            }
        }
        if participation.receiptWarning {
            Text(L("Some assistant activity could not be saved.")).foregroundStyle(.orange)
        }
    }

    private var decisionMessage: String? {
        switch participation.latestDecision?.reason {
        case .checking:
            L("Checking whether to reply…")
        case .quiet, .invalidEvidence, .assessmentDeclined:
            L("The assistant stayed quiet on the last turn.")
        case .superseded, .someoneSpeaking:
            L("Waiting for a pause in the discussion.")
        case .rateLimited:
            L("The assistant is leaving time for others to respond.")
        case .voiceUnavailable where !model.participationMeetingSoundOn:
            nil
        case .voiceUnavailable, .voiceTooLong, .synthesisFailed, .audioNotStarted:
            L("The assistant could not play its last voice reply.")
        default:
            nil
        }
    }
}
