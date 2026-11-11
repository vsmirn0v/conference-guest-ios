import SwiftUI

struct ParticipationSetupView: View {
    @ObservedObject var participation: ParticipationCoordinator
    @ObservedObject var model: NativeDesktopMeetingModel
    @ObservedObject var store: AttentionStore
    @State private var reviewed: ParticipationSetup?
    @State private var objective = ""
    @State private var scopeChanged = false
    @State private var noteContext: ParticipationKnowledgeReviewContext?
    @State private var notes: [ParticipationKnowledgeApproval] = []
    @State private var reviewingNotes = false
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
            if scopeChanged {
                Text(L("The meeting audience or processor changed. Review the updated scope before continuing."))
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
                    Button(L("Resume")) { participation.resume(); close() }
                        .keyboardShortcut(.defaultAction)
                } else if let reviewed {
                    Button(L("Start participating")) {
                        if participation.start(reviewed, objective: objective, model: model, store: store,
                                               context: noteContext, notes: notes) { close() }
                        else { scopeChanged = true }
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("participation.start")
                }
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 355)
        .onAppear { objective = participation.objective; captureScope() }
        .onChange(of: participation.rosterEpoch) { _ in invalidatePreview() }
        .onChange(of: store.provider) { _ in invalidatePreview() }
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
                            participation.requireReview(revokeSources: false)
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
        scopeChanged = reviewed != participation.setup(for: model, store: store)
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
            Label(L("Chat · This meeting"), systemImage: "bubble.left")
                .font(.callout.weight(.semibold))
            Text(L("Messages use your meeting connection and begin with “Rock’n’Roll Assistant:”."))
            Text(L("Reactions require a separate assistant identity. Voice participation is unavailable."))
                .foregroundStyle(.secondary)
            Text(L("Sources · Live chat and available meeting transcription"))
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
                 : L("Processor · %@ at %@ receives meeting excerpts and your objective", provider.model, provider.host))
            Text(L("Ends when you leave or restart the app. Audience changes require review."))
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        if participation.status == .inactive || participation.status == .review || participation.status == .unavailable {
            TextField(L("Meeting objective (optional)"), text: $objective)
                .accessibilityIdentifier("participation.objective")
        }
    }

    @ViewBuilder private var activity: some View {
        if participation.status == .observing, participation.queuedText == nil {
            Text(model.guestFeatures.transcriptionStatus == .active && model.guestFeatures.permissions.canViewTranscript
                ? L("Following the discussion") : L("Using meeting chat only")).foregroundStyle(.secondary)
        } else if participation.status == .paused {
            Text(L("Participation paused · Private help continues")).foregroundStyle(.secondary)
        } else if participation.status == .review {
            Text(L("Review the meeting and audience before continuing.")).foregroundStyle(.orange)
        } else if participation.status == .unavailable {
            Text(L("Participation paused · Model or local storage unavailable")).foregroundStyle(.orange)
        }
        if let queued = participation.queuedText {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L("Ready to add")).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(L("Cancel")) { participation.cancelCandidate() }
                        .accessibilityIdentifier("participation.cancel")
                }
                Text(ParticipationCoordinator.attribution + queued).textSelection(.enabled)
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
                        Text(receipt.state.title)
                        Spacer()
                        Text(receipt.updatedAt, style: .time)
                    }
                    .font(.caption)
                }
            }
        }
        if participation.receiptWarning {
            Text(L("Some activity could not be saved. Check meeting chat.")).foregroundStyle(.orange)
        }
    }
}
