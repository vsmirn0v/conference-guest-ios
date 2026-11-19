import ConferenceCore
import SwiftUI

enum IOSMeetingDetailTab: String, CaseIterable, Identifiable {
    case summary
    case notes
    case transcript
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: return L("Summary")
        case .notes: return L("Notes")
        case .transcript: return L("Transcript")
        case .settings: return L("Settings")
        }
    }
}

struct IOSMeetingDetailView: View {
    @ObservedObject var workspace: IOSWorkspaceCoordinator
    @ObservedObject var sync: RoomSyncCoordinator
    let sessionID: UUID

    @State private var tab: IOSMeetingDetailTab = .summary
    @State private var noteText = ""
    @State private var previewNotes = false

    @State private var editingOutcome = false
    @State private var summaryDraft = ""
    @State private var decisionsDraft = ""
    @State private var questionsDraft = ""
    @State private var selectedVersion: SyncedOutcomeVersionSnapshot?

    @State private var showingAddTask = false
    @State private var newTaskText = ""
    @State private var newTaskOwner = ""
    @State private var newTaskDue = ""
    @State private var newTaskHasReminder = false
    @State private var newTaskReminder = Date().addingTimeInterval(3600)

    @State private var transcriptEvents: [SyncedTranscriptEvent] = []
    @State private var transcriptIsLocalOnly = false
    @State private var transcriptSearch = ""

    @State private var transitionChoice: IOSSameRoomTransitionMode?
    @State private var useSeriesScope = false
    @State private var aboutDraft = ""
    @State private var mattersDraft = ""
    @State private var neverDraft = ""
    @State private var peopleDraft = ""
    @State private var newRuleDraft = ""

    private var session: IOSMeetingSessionItem? {
        workspace.sessions.first { $0.id == sessionID }
    }

    private var outcome: IOSMeetingOutcomeItem? {
        workspace.outcomesBySession[sessionID]
    }

    private var note: IOSMeetingNoteItem? {
        workspace.notesBySession[sessionID]
    }

    private var sessionTasks: [IOSMeetingTaskItem] {
        workspace.tasks.filter { $0.sessionID == sessionID }
    }

    private var contextScopeKey: String {
        if useSeriesScope, let series = session?.calendarSeriesID, !series.isEmpty {
            return "series:" + series
        }
        if let room = session?.invitation?.absoluteString ?? session?.roomIdentity, !room.isEmpty {
            return "room:" + room
        }
        return "session:" + sessionID.uuidString
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L("Meeting Section"), selection: $tab) {
                ForEach(IOSMeetingDetailTab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("workspace.detail.tab")

            switch tab {
            case .summary:
                summaryView
            case .notes:
                notesView
            case .transcript:
                transcriptView
            case .settings:
                settingsView
            }
        }
        .navigationTitle(session?.title ?? L("Meeting"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadInitialState()
        }
        .onChange(of: sessionID) { _, _ in
            loadInitialState()
            Task { await loadTranscript() }
        }
        .task(id: sessionID) {
            await loadTranscript()
        }
        .onDisappear {
            Task { await workspace.flushNotesNow() }
        }
        .sheet(isPresented: $showingAddTask) {
            NavigationStack {
                Form {
                    Section(L("Task")) {
                        TextField(L("What needs to be done?"), text: $newTaskText)
                        TextField(L("Owner"), text: $newTaskOwner)
                        TextField(L("Due day (optional, e.g. 2026-12-01)"), text: $newTaskDue)
                    }
                    Section {
                        Toggle(L("Remind me"), isOn: $newTaskHasReminder)
                        if newTaskHasReminder {
                            DatePicker(L("Reminder"), selection: $newTaskReminder, in: Date()...)
                        }
                    }
                }
                .navigationTitle(L("New Task"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("Cancel")) { showingAddTask = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Add")) {
                            let text = newTaskText
                            let owner = newTaskOwner
                            let due = newTaskDue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newTaskDue
                            let reminder = newTaskHasReminder ? newTaskReminder : nil
                            newTaskText = ""
                            newTaskOwner = ""
                            newTaskDue = ""
                            newTaskHasReminder = false
                            showingAddTask = false
                            Task {
                                await workspace.addTask(
                                    sessionID: sessionID,
                                    text: text,
                                    owner: owner,
                                    dueDay: due,
                                    reminderAt: reminder
                                )
                            }
                        }
                        .disabled(newTaskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .sheet(item: Binding(
            get: { selectedVersion.map { IdentifiableVersion(snapshot: $0) } },
            set: { selectedVersion = $0?.snapshot }
        )) { item in
            NavigationStack {
                List {
                    Section(L("Summary")) {
                        Text(item.snapshot.summary)
                    }
                    if !item.snapshot.decisions.isEmpty {
                        Section(L("Decisions")) {
                            ForEach(Array(item.snapshot.decisions.enumerated()), id: \.offset) { _, decision in
                                Text(decision)
                            }
                        }
                    }
                    if !item.snapshot.openQuestions.isEmpty {
                        Section(L("Open Questions")) {
                            ForEach(Array(item.snapshot.openQuestions.enumerated()), id: \.offset) { _, question in
                                Text(question)
                            }
                        }
                    }
                }
                .navigationTitle(L("Previous Version"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("Close")) { selectedVersion = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Restore")) {
                            let restored = item.snapshot
                            selectedVersion = nil
                            Task {
                                await workspace.saveEditedOutcome(
                                    sessionID: sessionID,
                                    summary: restored.summary,
                                    decisions: restored.decisions,
                                    openQuestions: restored.openQuestions
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Summary Tab

    private var summaryView: some View {
        List {
            if let session {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline)
                            if let endedAt = session.endedAt, endedAt > session.startedAt {
                                let mins = max(1, Int((endedAt.timeIntervalSince(session.startedAt) / 60).rounded()))
                                Text(L("Duration: %ld min", mins))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            Task { await workspace.generateOutcomeNow(sessionID: sessionID) }
                        } label: {
                            if workspace.generatingSessionIDs.contains(sessionID) {
                                ProgressView()
                            } else {
                                Label(
                                    outcome == nil ? L("Generate Summary") : L("Regenerate"),
                                    systemImage: "sparkles"
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(workspace.generatingSessionIDs.contains(sessionID))
                    }

                    if let error = workspace.outcomeErrors[sessionID] {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            if let outcome {
                Section {
                    if editingOutcome {
                        TextEditor(text: $summaryDraft)
                            .frame(minHeight: 110)
                    } else if !outcome.summary.isEmpty {
                        Text(outcome.summary)
                            .font(.body)
                    } else {
                        Text(L("Summary pending…"))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text(L("Summary"))
                        Spacer()
                        Button(editingOutcome ? L("Save") : L("Edit")) {
                            if editingOutcome {
                                let decs = decisionsDraft.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                                let qs = questionsDraft.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                                editingOutcome = false
                                Task {
                                    await workspace.saveEditedOutcome(
                                        sessionID: sessionID,
                                        summary: summaryDraft,
                                        decisions: decs,
                                        openQuestions: qs
                                    )
                                }
                            } else {
                                summaryDraft = outcome.summary
                                decisionsDraft = outcome.decisions.joined(separator: "\n")
                                questionsDraft = outcome.openQuestions.joined(separator: "\n")
                                editingOutcome = true
                            }
                        }
                        .font(.caption)
                    }
                }

                if editingOutcome || !outcome.decisions.isEmpty {
                    Section(L("Decisions")) {
                        if editingOutcome {
                            TextEditor(text: $decisionsDraft)
                                .frame(minHeight: 70)
                        } else {
                            ForEach(Array(outcome.decisions.enumerated()), id: \.offset) { _, decision in
                                Label(decision, systemImage: "checkmark.seal")
                            }
                        }
                    }
                }

                if editingOutcome || !outcome.openQuestions.isEmpty {
                    Section(L("Open Questions")) {
                        if editingOutcome {
                            TextEditor(text: $questionsDraft)
                                .frame(minHeight: 70)
                        } else {
                            ForEach(Array(outcome.openQuestions.enumerated()), id: \.offset) { _, question in
                                Label(question, systemImage: "questionmark.circle")
                            }
                        }
                    }
                }

                if !outcome.reviewCandidates.isEmpty {
                    Section(L("Possible Duplicate Tasks to Review")) {
                        ForEach(outcome.reviewCandidates) { candidate in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(candidate.text).font(.subheadline)
                                if !candidate.owner.isEmpty {
                                    Text(candidate.owner).font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button(L("Add Task")) {
                                        Task { await workspace.acceptReviewCandidate(candidate, sessionID: sessionID) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    Button(L("Dismiss")) {
                                        Task { await workspace.dismissReviewCandidate(candidate.id, sessionID: sessionID) }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !outcome.versions.isEmpty {
                    Section(L("Other Generated Versions")) {
                        ForEach(Array(outcome.versions.enumerated()), id: \.offset) { _, version in
                            Button {
                                selectedVersion = version
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L("Version #%ld", version.revision))
                                        .font(.subheadline.weight(.medium))
                                    Text(version.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }

            Section {
                if sessionTasks.isEmpty {
                    Text(L("No action items yet."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessionTasks) { task in
                        HStack(spacing: 10) {
                            Button {
                                Task { await workspace.toggleTaskDone(task.id) }
                            } label: {
                                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(task.done ? .green : .secondary)
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.text)
                                    .strikethrough(task.done)
                                    .foregroundStyle(task.done ? .secondary : .primary)
                                if !task.owner.isEmpty || task.dueDay != nil {
                                    Text([task.owner, task.dueDay].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text(L("Tasks"))
                    Spacer()
                    Button(L("Add Task")) { showingAddTask = true }
                        .font(.caption)
                }
            }

            Section(L("Obsidian on Mac")) {
                if let receipt = session?.obsidianReceipt {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(obsidianStateLabel(receipt.state), systemImage: obsidianStateIcon(receipt.state))
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(receipt.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let path = receipt.relativePath {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let err = receipt.errorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                } else {
                    Text(L("Not exported to Obsidian yet."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await workspace.requestSaveInObsidian(sessionID: sessionID) }
                } label: {
                    Label(L("Save in Obsidian on Mac"), systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(!sync.enabled)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Notes Tab

    private var notesView: some View {
        VStack(spacing: 10) {
            if note?.hasConflictMarkers == true {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L("Concurrent note edits created conflict markers below. Review and keep the text you want."))
                        .font(.caption)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
            }

            Picker(L("Note View"), selection: $previewNotes) {
                Text(L("Edit Markdown")).tag(false)
                Text(L("Preview")).tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if previewNotes {
                ScrollView {
                    if let attributed = try? AttributedString(markdown: noteText.isEmpty ? L("_No notes yet._") : noteText) {
                        Text(attributed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    } else {
                        Text(noteText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            } else {
                TextEditor(text: $noteText)
                    .font(.body)
                    .padding(10)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.bottom)
                    .onChange(of: noteText) { _, newValue in
                        workspace.updateNoteDraft(newValue, for: sessionID)
                    }
            }
        }
    }

    // MARK: - Transcript Tab

    private var transcriptView: some View {
        let trimmed = transcriptSearch.trimmingCharacters(in: .whitespacesAndNewlines).workspaceFolded
        let filtered = trimmed.isEmpty ? transcriptEvents : transcriptEvents.filter {
            $0.text.workspaceFolded.contains(trimmed) || ($0.speaker?.workspaceFolded.contains(trimmed) ?? false)
        }

        return VStack(spacing: 8) {
            if transcriptIsLocalOnly {
                Label(
                    L("Stored locally or in transcript backup folder (aged out of iCloud sync)"),
                    systemImage: "internaldrive"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            }

            TextField(L("Filter transcript"), text: $transcriptSearch)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            if filtered.isEmpty {
                ContentUnavailableView(
                    L("No Transcript"),
                    systemImage: "text.alignleft",
                    description: Text(L("Speech transcripts and chat messages from Mac and iPhone appear here."))
                )
            } else {
                List(filtered) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text((event.speaker.flatMap { $0.isEmpty ? nil : $0 }) ?? (event.isOwn ? L("You") : L("Speaker")))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(event.isOwn ? Color.accentColor : .secondary)
                            Spacer()
                            Text(event.occurredAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(event.text)
                            .font(.body)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Settings Tab

    private var settingsView: some View {
        let currentRules = workspace.settings(for: contextScopeKey)?.guidanceRules.values
            .map(\.value)
            .filter { !$0.deleted } ?? []

        return Form {
            if let series = session?.calendarSeriesID, !series.isEmpty {
                Section {
                    Toggle(L("Apply to entire calendar series"), isOn: $useSeriesScope)
                        .onChange(of: useSeriesScope) { _, _ in loadContextFields() }
                }
            }

            Section(L("Back-to-back in this meeting")) {
                Picker(L("Same-room transition"), selection: $transitionChoice) {
                    Text(L("Use default")).tag(IOSSameRoomTransitionMode?.none)
                    ForEach(IOSSameRoomTransitionMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(IOSSameRoomTransitionMode?.some(mode))
                    }
                }
            }

            Section(L("Assistant Context")) {
                TextField(L("What this meeting is about"), text: $aboutDraft, axis: .vertical)
                TextField(L("What matters most"), text: $mattersDraft, axis: .vertical)
                TextField(L("Never mention or focus on"), text: $neverDraft, axis: .vertical)
                TextField(L("People to listen for (comma separated)"), text: $peopleDraft)
                Button(L("Save Meeting Settings")) {
                    let people = peopleDraft.split(separator: ",")
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    let kind: SyncedMeetingContextSettings.ScopeKind = useSeriesScope ? .calendarSeries : .room
                    Task {
                        await workspace.saveContextSettings(
                            scopeKey: contextScopeKey,
                            scopeKind: kind,
                            title: session?.title ?? L("Meeting"),
                            sameRoomTransition: transitionChoice?.rawValue,
                            about: aboutDraft,
                            matters: mattersDraft,
                            never: neverDraft,
                            people: people
                        )
                    }
                }
            }

            Section(L("Private Guidance")) {
                HStack {
                    TextField(L("Add private guidance rule…"), text: $newRuleDraft)
                    Button(L("Add")) {
                        let text = newRuleDraft
                        newRuleDraft = ""
                        let kind: SyncedMeetingContextSettings.ScopeKind = useSeriesScope ? .calendarSeries : .room
                        Task {
                            await workspace.addGuidanceRule(
                                text,
                                scopeKey: contextScopeKey,
                                scopeKind: kind,
                                title: session?.title ?? L("Meeting")
                            )
                        }
                    }
                    .disabled(newRuleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(currentRules) { rule in
                    HStack {
                        Text(rule.text)
                        Spacer()
                        Button(role: .destructive) {
                            Task { await workspace.removeGuidanceRule(id: rule.id, scopeKey: contextScopeKey) }
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func loadInitialState() {
        noteText = workspace.noteDraft(for: sessionID)
        useSeriesScope = (session?.calendarSeriesID?.isEmpty == false)
        loadContextFields()
    }

    private func loadContextFields() {
        let settings = workspace.settings(for: contextScopeKey)
        transitionChoice = settings?.sameRoomTransition?.value.flatMap(IOSSameRoomTransitionMode.init(rawValue:))
        aboutDraft = settings?.about?.value ?? ""
        mattersDraft = settings?.matters?.value ?? ""
        neverDraft = settings?.never?.value ?? ""
        peopleDraft = settings?.people?.value.joined(separator: ", ") ?? ""
    }

    private func loadTranscript() async {
        let (events, isLocal) = await workspace.transcriptForDisplay(sessionID: sessionID)
        transcriptEvents = events
        transcriptIsLocalOnly = isLocal
    }

    private func obsidianStateLabel(_ state: String) -> String {
        switch state {
        case "exported": return L("Exported to Obsidian")
        case "conflict": return L("Obsidian conflict — edit protected")
        case "held": return L("Held pending Obsidian policy")
        default: return L("Queued for Mac Obsidian export")
        }
    }

    private func obsidianStateIcon(_ state: String) -> String {
        switch state {
        case "exported": return "checkmark.circle.fill"
        case "conflict": return "exclamationmark.triangle.fill"
        default: return "clock"
        }
    }

    private struct IdentifiableVersion: Identifiable {
        var id: String { "\(snapshot.revision)-\(snapshot.deviceID)" }
        let snapshot: SyncedOutcomeVersionSnapshot
    }
}
