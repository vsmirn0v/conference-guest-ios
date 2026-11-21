import AppKit
import Combine
import ConferenceCore
import SwiftUI

enum MeetingHistoryTab: String, CaseIterable, Identifiable {
    case summary = "Summary", transcript = "Transcript", tasks = "Tasks", notes = "Notes"
    var id: Self { self }
}

@MainActor final class MeetingHistoryNavigation: ObservableObject {
    @Published var selectedSessionID: UUID?
    @Published var tab: MeetingHistoryTab = .summary
    @Published var query = ""
    @Published var indexVisible = false
    @Published var taskID: UUID?
    @Published var source: NativeDesktopWorkspace.Section?
    @Published var eventID: String?
}

struct MeetingHistoryView: View {
    @ObservedObject var attention: AttentionCoordinator
    @ObservedObject private var data: AssistantDataStore
    @ObservedObject private var library: MeetingLibraryController
    @ObservedObject private var journal: MeetingWorkspaceJournal
    @ObservedObject private var preferences: AttentionStore
    @ObservedObject private var navigation: MeetingHistoryNavigation
    @State private var selectedNoteSource: UUID?
    @State private var syncRevision = 0
    @State private var archivedEvents: [SyncedTranscriptEvent] = []
    @State private var loadedArchiveID: UUID?
    private let workspace: NativeDesktopWorkspace?
    @AppStorage("native.meetingHistory.readingMode") private var readingMode = false
    @State private var showingGuidance = false
    @State private var showingContext = false
    @State private var showingTranscriptSources = false
    @State private var reviewedDraft: AttentionCoordinator.HistoryOutcomeDraft?
    @State private var pendingSend: (outcome: UUID, meeting: UUID)?
    @State private var collapsedDays: Set<Day> = []
    @State private var calendar = Calendar.current
    @State private var rename: Rename?
    @State private var exportRequest: ExportRequest?
    @State private var obsidianMessage: String?
    @State private var editingOutcomeTask: OutcomeTaskSheetTarget?
    @Environment(\.locale) private var locale

    private struct OutcomeTaskSheetTarget: Identifiable {
        var id: UUID { task.id }
        let outcome: MeetingOutcome
        let task: MeetingOutcomeTask
    }

    private struct Day: Hashable {
        let date: Date?
    }

    private struct Rename: Identifiable {
        let id: UUID
        var title: String
    }

    private struct ExportRequest: Identifiable {
        let id = UUID()
        var sessionID: UUID?
    }

    init(attention: AttentionCoordinator, workspace: NativeDesktopWorkspace? = nil) {
        self.workspace = workspace
        _navigation = ObservedObject(wrappedValue: attention.historyNavigation)
        _journal = ObservedObject(wrappedValue: attention.store.meetingLibrary.workspaceJournal)
        _preferences = ObservedObject(wrappedValue: attention.store)
        self.attention = attention
        _data = ObservedObject(wrappedValue: attention.store.assistant)
        _library = ObservedObject(wrappedValue: attention.store.meetingLibrary)
    }

    private var search: String { navigation.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var groups: [(key: Day, value: [MeetingLibraryCard])] {
        let cards = historyCards.filter { card in
            search.isEmpty || card.title.localizedStandardContains(search) ||
                card.notePreview?.localizedStandardContains(search) == true ||
                data.outcomes.first(where: { $0.id == card.outcomeID })?.summary.localizedStandardContains(search) == true ||
                searchedEvent(card.sessionID) != nil
        }
        return Dictionary(grouping: cards) { card in
            Day(date: card.effectiveDate.map { calendar.startOfDay(for: $0.date) })
        }
        .mapValues { cards in
            cards.sorted { left, right in
                let lhs = left.effectiveDate?.date ?? .distantPast
                let rhs = right.effectiveDate?.date ?? .distantPast
                return lhs == rhs ? left.sessionID.uuidString < right.sessionID.uuidString : lhs > rhs
            }
        }
        .sorted { ($0.key.date ?? .distantPast) > ($1.key.date ?? .distantPast) }
    }

    private var sourceCards: [MeetingLibraryCard] {
        let live = Set(attention.meetings().flatMap { [$0.sessionID, $0.workspaceSessionID] + $0.segments.map(\.sessionID) })
        let saved = Set(library.cards.map(\.sessionID))
        let journalOnly = journal.sessions.filter { $0.endedAt != nil && !saved.contains($0.id) }.map { entry in
            MeetingLibraryCard(sessionID: entry.id, title: entry.title, startedAt: entry.startedAt, endedAt: entry.endedAt,
                state: .ended, hasNotes: false, noteID: nil, noteRevision: 0, notePreview: nil,
                outcomeID: nil, outcomeState: .notStarted, updatedAt: entry.endedAt ?? entry.startedAt,
                startProvenance: .recorded, outcomeEndFallback: nil)
        }
        return (library.cards + journalOnly).filter { card in
            !live.contains(card.sessionID) &&
                (workspace?.workspaceSync.canonicalSessionID(card.sessionID) ?? card.sessionID) == card.sessionID
        }
    }

    private var historyCards: [MeetingLibraryCard] {
        _ = syncRevision
        return sourceCards.filter { (workspace?.workspaceSync.historySessionID($0.sessionID) ?? $0.sessionID) == $0.sessionID }
    }

    private func groupedCards(for id: UUID) -> [MeetingLibraryCard] {
        guard let workspace else { return sourceCards.filter { $0.sessionID == id } }
        return sourceCards.filter { workspace.workspaceSync.historySessionID($0.sessionID) == id }
            .sorted { ($0.sessionID != id ? 1 : 0, $0.startedAt) < ($1.sessionID != id ? 1 : 0, $1.startedAt) }
    }

    private func searchedEvent(_ id: UUID) -> MeetingWorkspaceEvent? {
        guard !search.isEmpty else { return nil }
        return conversation(id)?.visibleEvents.first { $0.matches(search) }
    }

    private func conversation(_ id: UUID) -> MeetingWorkspaceSession? {
        workspace?.workspaceSync.historyConversation(for: id, in: journal) ?? journal.session(id: id)
    }

    private var selectedCard: MeetingLibraryCard? {
        if let id = navigation.selectedSessionID {
            let canonical = workspace?.workspaceSync.historySessionID(id) ?? id
            return historyCards.first { $0.sessionID == canonical }
        }
        return nil
    }

    private var mainHistoryLayout: some View {
        GeometryReader { geometry in
            let narrow = readingMode || geometry.size.width < 615
            HStack(spacing: 0) {
                if !narrow || navigation.indexVisible || selectedCard == nil {
                    index.frame(width: narrow ? nil : 228).frame(maxWidth: narrow ? .infinity : nil)
                }
                if !narrow || (!navigation.indexVisible && selectedCard != nil) {
                    if !narrow { Divider() }
                    if let card = selectedCard {
                        selectedMeeting(card, compact: narrow).id(card.sessionID)
                    } else {
                        Text(L("Choose a meeting")).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationTitle(L("Meeting history"))
        .tint(.orange)
        .onReceive(workspace?.workspaceSync.objectWillChange.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in
            syncRevision += 1
        }
        .onChange(of: historyCards.map(\.sessionID)) { ids in
            if navigation.selectedSessionID == nil, !ids.isEmpty { select(groups.first?.value.first) }
        }
        .onChange(of: selectedCard?.sessionID) { _ in showingTranscriptSources = false }
        .onAppear {
            if let requested = attention.requestedOutcomeSessionID {
                navigation.selectedSessionID = requested
                navigation.indexVisible = false
                attention.requestedOutcomeSessionID = nil
            } else if navigation.selectedSessionID == nil { select(groups.first?.value.first) }
        }
        .onChange(of: attention.requestedOutcomeSessionID) { id in
            if let id {
                navigation.selectedSessionID = id
                navigation.query = ""
                navigation.indexVisible = false
                attention.requestedOutcomeSessionID = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            calendar = Calendar.current
        }
        .onDisappear { data.flushOutcomeEdits() }
    }

    private func outcomeTaskDetailSheet(_ target: OutcomeTaskSheetTarget) -> some View {
        let sessionID = target.outcome.meetingID
            ?? library.cards.first(where: { $0.outcomeID == target.outcome.id })?.sessionID
            ?? selectedCard?.sessionID
            ?? target.outcome.id
        let record = WorkspaceTaskRecord(
            id: target.task.id,
            sessionID: sessionID,
            outcomeID: target.outcome.id,
            meetingTitle: target.outcome.meetingTitle,
            meetingDate: target.outcome.endedAt,
            text: target.task.text,
            owner: target.task.owner,
            assigneeID: target.task.assigneeID,
            dueDay: target.task.dueDay,
            dueAt: target.task.dueAt,
            reminderAt: target.task.reminderAt,
            done: target.task.done,
            completedAt: target.task.completedAt,
            isOwnedByCurrentUser: data.taskProfile.owns(target.task),
            extended: target.task.extended
        )
        return TaskDetailAndContextSheet(
            task: record,
            syncController: attention.taskSync,
            onSave: { payload in
                await attention.setOutcomeTaskExtendedDetails(
                    outcomeID: target.outcome.id,
                    sessionID: sessionID,
                    meetingTitle: target.outcome.meetingTitle,
                    taskID: target.task.id,
                    payload: payload
                )
            },
            onDelete: nil,
            onOpenMeeting: nil
        )
    }

    var body: some View {
        mainHistoryLayout
            .sheet(item: $rename) { value in
                RenameMeetingSheet(library: library, sessionID: value.id, currentTitle: value.title)
            }
            .sheet(item: $exportRequest) { value in
                MeetingManualExportView(attention: attention, singleSessionID: value.sessionID)
            }
            .sheet(item: $reviewedDraft) { draft in
                if let selectedCard, selectedCard.sessionID == draft.id {
                    HistoryOutcomeReview(card: selectedCard, draft: draft, attention: attention)
                }
            }
            .sheet(isPresented: $showingGuidance) {
                WorkspaceSavedGuidance(guidance: preferences.workspaceGuidance, journal: journal)
            }
            .sheet(item: $editingOutcomeTask) { target in
                outcomeTaskDetailSheet(target)
            }
            .alert(L("Save in Obsidian"), isPresented: Binding(get: { obsidianMessage != nil },
                set: { shown in if !shown { obsidianMessage = nil } })) {
                Button(L("OK"), role: .cancel) { obsidianMessage = nil }
            } message: {
                Text(obsidianMessage ?? "")
            }
    }

    private var index: some View {
            VStack(spacing: 0) {
                TextField(L("Search meetings"), text: $navigation.query)
                    .textFieldStyle(.roundedBorder).padding(10)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(groups, id: \.key) { day, cards in
                            DisclosureGroup(isExpanded: Binding(get: { !search.isEmpty || !collapsedDays.contains(day) },
                                set: { expanded in
                                    guard search.isEmpty else { return }
                                    if expanded { collapsedDays.remove(day) } else { collapsedDays.insert(day) }
                                })) {
                                ForEach(cards) { card in
                                    Button { select(card) } label: { cardRow(card) }
                                        .buttonStyle(.plain).accessibilityIdentifier("assistant.meeting-card")
                                }
                            } label: {
                                HStack {
                                    Text(day.date?.formatted(.dateTime.day().month(.wide).year().locale(locale)) ?? L("Date unknown"))
                                    Spacer()
                                    Text(cards.count.formatted()).foregroundStyle(.secondary)
                                }.font(.subheadline.weight(.semibold))
                            }.padding(.vertical, 4)
                        }
                    }.padding(8)
                }
                if groups.isEmpty {
                    Text(search.isEmpty ? L("Meeting notes and outcomes appear here.") : L("No matching meetings"))
                        .font(.callout).foregroundStyle(.secondary).padding()
                }
                Divider()
                Menu(L("History options")) {
                    Toggle(L("Reading mode"), isOn: $readingMode)
                    Button(L("Saved guidance")) { showingGuidance = true }
                    Button(L("Export Markdown…")) { exportRequest = ExportRequest() }.disabled(library.cards.isEmpty)
                }.padding(10)
            }.background(Color(nsColor: .controlBackgroundColor))
    }

    private func select(_ card: MeetingLibraryCard?) {
        navigation.selectedSessionID = card?.sessionID
        navigation.indexVisible = false
        navigation.taskID = nil
        navigation.source = nil
        navigation.eventID = card.flatMap { searchedEvent($0.sessionID)?.id }
        navigation.tab = navigation.eventID != nil ? .transcript : .summary
    }

    private func selectedMeeting(_ card: MeetingLibraryCard, compact: Bool) -> some View {
        let sources = groupedCards(for: card.sessionID)
        return VStack(spacing: 0) {
            if compact || navigation.source != nil {
                HStack {
                    Button {
                        if let source = navigation.source {
                            navigation.source = nil
                            workspace?.show(section: source)
                        } else { navigation.indexVisible = true }
                    } label: {
                        Label(L("Back"), systemImage: "chevron.left")
                            .flipsForRightToLeftLayoutDirection(true)
                    }.buttonStyle(.borderless)
                    Spacer()
                }.padding([.top, .horizontal], 12)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title).font(.title2.bold()).lineLimit(2)
                    if let date = card.effectiveDate {
                        Text(date.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        if date.fromEnd {
                            Text(L("By end time")).font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("assistant.date-end-fallback")
                        }
                    } else {
                        Text(L("Date unknown")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if library.cards.contains(where: { $0.sessionID == card.sessionID }) {
                    Button { rename = Rename(id: card.sessionID, title: card.title) } label: {
                        Image(systemName: "pencil")
                    }.buttonStyle(.borderless).help(L("Rename meeting")).accessibilityLabel(L("Rename meeting"))
                    exportButtons(sessionID: card.sessionID)
                }
                if workspace != nil {
                    Button(L("Participation and calendar"), systemImage: "calendar.badge.clock") { showingContext = true }
                        .labelStyle(.iconOnly).help(L("Participation and calendar"))
                }
            }.padding(16)
            NativeSegmentedControl(
                label: L("Meeting history"),
                selection: Binding(get: {
                    navigation.tab == .transcript ? MeetingHistoryTab.transcript : .summary
                }, set: { navigation.tab = $0 }),
                options: [
                    .init(value: .summary, title: L("Summary")),
                    .init(value: .transcript, title: L("Transcript")),
                ]
            ).padding([.horizontal, .bottom], 10)
            Divider()
            switch navigation.tab {
            case .summary, .tasks, .notes: overview(card, sources: sources)
            case .transcript:
                if let session = conversation(card.sessionID), !session.events.isEmpty {
                    WorkspaceSessionReview(session: session, journal: journal, guidance: preferences.workspaceGuidance,
                                           highlightedEventID: navigation.eventID, showsDelete: sources.count <= 1,
                                           onBookmark: { event in
                                               let source = journal.sessions.first {
                                                   (workspace?.workspaceSync.historySessionID($0.id) ?? $0.id) == card.sessionID &&
                                                       $0.events.contains { $0.id == event }
                                               }?.id ?? session.id
                                               journal.toggleBookmark(sessionID: source, eventID: event)
                                           })
                } else if loadedArchiveID == card.sessionID, !archivedEvents.isEmpty {
                    ArchivedHistoryTranscript(events: archivedEvents)
                } else {
                    VStack(spacing: 10) {
                        Text(L("No saved transcript or assistant reply text is available for this meeting."))
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        if let workspace {
                            Button(L("Sync now")) { workspace.workspaceSync.scheduleSync(delayMilliseconds: 0) }
                                .disabled(!workspace.library.sync.enabled || !workspace.library.sync.syncWorkspace)
                            Button(L("Settings")) { workspace.settingsTab = 0; workspace.show(section: .settings) }
                        }
                    }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: card.sessionID) {
            guard let workspace else { return }
            let events = await workspace.workspaceSync.archiveStore.loadTranscript(sessionID: card.sessionID)
            guard !Task.isCancelled else { return }
            archivedEvents = events ?? []
            loadedArchiveID = card.sessionID
        }
        .sheet(isPresented: $showingContext) {
            if let workspace { MeetingHistoryContext(card: card, workspace: workspace) }
        }
    }

    private func overview(_ card: MeetingLibraryCard, sources: [MeetingLibraryCard]) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        if sources.count > 1 {
                            Picker(L("Notes"), selection: Binding(get: {
                                sources.first(where: { $0.sessionID == selectedNoteSource })?.sessionID ?? card.sessionID
                            }, set: { selectedNoteSource = $0 })) {
                                ForEach(sources) { source in
                                    Text(source.title + " · " + workspaceDate(source.startedAt)).tag(source.sessionID)
                                }
                            }
                        }
                        let source = sources.first { $0.sessionID == selectedNoteSource } ?? card
                        meetingNotes(source).id(source.sessionID)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }.padding([.top, .horizontal], 20).id("notes")
                    outcomeContent(card)
                    overviewTasks(sources: sources).padding(.horizontal, 20).id("tasks")
                    if let outcome = data.outcomes.first(where: { $0.id == card.outcomeID }) {
                        seriesHistory(outcome).padding(.horizontal, 20)
                    }
                    AssistantOutcomeHistoryView(store: library.store, sessionID: card.sessionID, updatedAt: card.updatedAt)
                    ParticipationOutcomeActivity(sessionID: card.sessionID, root: attention.store.root)
                }.padding(.bottom, 20)
            }
            .task(id: navigation.taskID) {
                if let id = navigation.taskID { scroll.scrollTo(id, anchor: .center) }
            }
            .task(id: navigation.tab) {
                if navigation.tab == .tasks, navigation.taskID == nil { scroll.scrollTo("tasks", anchor: .top) }
                if navigation.tab == .notes { scroll.scrollTo("notes", anchor: .top) }
            }
        }
    }

    @ViewBuilder private func overviewTasks(sources: [MeetingLibraryCard]) -> some View {
        let outcomes = sources.compactMap { source in data.outcomes.first { $0.id == source.outcomeID } }
        if outcomes.isEmpty {
            GroupBox(L("Tasks")) {
                Text(L("No tasks yet.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ForEach(outcomes) { outcome in
                if outcomes.count > 1 { Text(outcome.meetingTitle).font(.headline) }
                meetingTasks(outcome)
            }
        }
    }

    private func meetingNotes(_ card: MeetingLibraryCard) -> some View {
        MeetingNotesView(sessionID: card.sessionID, notes: attention.store.notes, title: L("My notes"),
            ended: false, openWindow: {
                let main = NSApp.keyWindow
                attention.store.notes.windows.open(sessionID: card.sessionID, title: card.title,
                    date: card.effectiveDate?.date, showInMain: { [weak main] in
                        if let workspace { workspace.openMeetingHistory(card.sessionID, tab: .notes, activate: true) }
                        else { attention.requestedOutcomeSessionID = card.sessionID }
                        if main?.isMiniaturized == true { main?.deminiaturize(nil) }
                        main?.makeKeyAndOrderFront(nil)
                    })
            }, compactWhenEmpty: true)
    }

    @ViewBuilder private func outcomeContent(_ card: MeetingLibraryCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            historyOutcomeActions(card)
            if let id = card.outcomeID, let error = data.outcomeWriteErrors[id] {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Outcome changes could not be saved. %@", error)).font(.callout).foregroundStyle(.red)
                    HStack {
                        Button(L("Retry")) { attention.store.retryOutcomeEdits(id) }
                        Button(L("Discard unsaved changes"), role: .destructive) {
                            attention.store.discardOutcomeEdits(id)
                        }
                    }
                }.padding(16)
            }
            if card.outcomeState == .failed || card.outcomeState == .pending {
                generationDetail(card)
            } else if let outcome = data.outcomes.first(where: { $0.id == card.outcomeID }) {
                detail(outcome)
            } else {
                Text(card.state == .active || card.state == .reconnecting ? L("Meeting in progress") : L("Outcome unavailable"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        }
    }

    @ViewBuilder private func historyOutcomeActions(_ card: MeetingLibraryCard) -> some View {
        if let draft = attention.historyOutcomeDrafts[card.sessionID] {
            Button(L("Review summary draft")) { reviewedDraft = draft }.padding(16)
        } else if let status = attention.outcomeStatus[card.sessionID] {
            ProgressView(status).controlSize(.small).padding(16)
        } else if let session = conversation(card.sessionID) {
            let writer = preferences.effectiveWriter
            let end = session.endedAt ?? card.endedAt ?? card.startedAt
            let window = MeetingOutcomePrompt.historyWindow(title: card.title, events: session.events, endedAt: end,
                onDevice: writer.kind == .apple, contextTokens: preferences.outcomeContextTokens)
            let previous = data.outcomes.first { $0.id == card.outcomeID }
            if !window.lines.isEmpty, previous?.transcriptFingerprint != MeetingOutcomePrompt.fingerprint(window) {
                VStack(alignment: .leading, spacing: 6) {
                    if previous?.transcriptFingerprint != nil {
                        Label(L("The available transcript has changed."), systemImage: "text.badge.plus")
                            .foregroundStyle(.secondary)
                    }
                    Button(previous == nil ? L("Generate summary") : L("Refresh summary")) {
                        attention.prepareHistoryOutcome(sessionID: card.sessionID, title: card.title, endedAt: end, window: window)
                    }
                    if let error = attention.outcomeError[card.sessionID] {
                        Text(error).foregroundStyle(.orange)
                    }
                }.padding(16)
            }
        }
    }

    @ViewBuilder private func cardRow(_ card: MeetingLibraryCard) -> some View {
        let isSelected = selectedCard?.sessionID == card.sessionID
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(card.title).fontWeight(.semibold).lineLimit(1)
                if card.hasNotes {
                    Image(systemName: "note.text").font(.caption).foregroundStyle(.secondary)
                        .help(L("Has notes"))
                }
                Spacer()
            }
            HStack(spacing: 6) {
                if let date = card.effectiveDate {
                    Text(date.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        .help(date.fromEnd ? L("By end time") : L("Start time"))
                    if date.fromEnd {
                        Text(L("By end time")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                switch card.outcomeState {
                case .pending:
                    Text("·").foregroundStyle(.secondary)
                    Text(L("Preparing outcome…")).font(.caption).foregroundStyle(.secondary)
                case .failed:
                    Text("·").foregroundStyle(.secondary)
                    Text(L("Outcome failed")).font(.caption).foregroundStyle(.red)
                case .ready:
                    Text(L("Outcome ready")).font(.caption).foregroundStyle(.secondary)
                case .draft, .notStarted:
                    Text(card.state == .active || card.state == .reconnecting ? L("Meeting in progress") : L("Outcome unavailable"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let outcome = data.outcomes.first(where: { $0.id == card.outcomeID }) {
                    Text("·").foregroundStyle(.secondary)
                    Text(MeetingOutcomePrompt.displayText(outcome.summary)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let status = attention.outcomeStatus[card.sessionID] {
                    Text("·").foregroundStyle(.secondary)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.orange.opacity(0.13) : .clear,
                in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }

    private func generationDetail(_ card: MeetingLibraryCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = attention.outcomeError[card.sessionID] {
                Text(error).foregroundStyle(.red)
            } else if card.outcomeState == .failed {
                let failure = card.outcomeErrorCode.flatMap(MeetingOutcomeFailure.init(rawValue:))
                Text(failure?.localizedDescription ?? L("The outcome could not be generated."))
                    .foregroundStyle(.red)
            } else {
                Text(L("Preparing outcome…")).foregroundStyle(.secondary)
            }
            if card.outcomeState == .failed {
                if card.hasOutcomeInput, let id = card.outcomeID {
                    Button(L("Retry outcome")) { attention.retryOutcome(for: card.sessionID, outcomeID: id) }
                        .accessibilityIdentifier("assistant.retry-outcome")
                        .disabled(attention.outcomeStatus[card.sessionID] != nil)
                } else {
                    Text(L("The original meeting input is unavailable for retry.")).foregroundStyle(.secondary)
                }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exportButtons(sessionID: UUID) -> some View {
        HStack {
            Button(L("Export Markdown…")) { exportRequest = ExportRequest(sessionID: sessionID) }
            Button(L("Save in Obsidian")) {
                Task { @MainActor in
                    guard await attention.store.notes.flush(sessionID: sessionID) else {
                        obsidianMessage = L("The local note could not be saved. Export Markdown to recover the draft.")
                        return
                    }
                    await attention.store.waitForOutcomeWrites()
                    do {
                        try await library.saveInObsidian(sessionID)
                        obsidianMessage = L("The saved meeting was queued for Obsidian.")
                    } catch { obsidianMessage = error.localizedDescription }
                }
            }
        }
    }

    @ViewBuilder private func detail(_ outcome: MeetingOutcome) -> some View {
        let binding = Binding(get: { data.outcomes.first { $0.id == outcome.id } ?? outcome },
            set: { data.updateOutcome($0) })
        let summary = Binding(get: { MeetingOutcomePrompt.displayText(binding.wrappedValue.summary) }, set: { text in
            var edited = binding.wrappedValue
            edited.summary = text
            binding.wrappedValue = edited
        })
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Button(L("Copy as text")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(outcome.shareText, forType: .string)
                }
                Button(L("Send to meeting chat")) {
                    if let target = attention.outcomeChatTarget(outcome) {
                        pendingSend = (outcome.id, target.sessionID)
                    }
                }
                .disabled(attention.outcomeChatTarget(outcome) == nil)
            }
            if pendingSend?.outcome == outcome.id, let meetingID = pendingSend?.meeting,
               let target = attention.meetings().first(where: { $0.sessionID == meetingID && !$0.isClosed }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Send this outcome to the chat of “%@”?", target.title)).font(.headline)
                    if target.sessionID != outcome.meetingID {
                        Text(L("This is the meeting open now. The outcome is from an earlier occurrence."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text(MeetingOutcomePrompt.displayText(outcome.summary)).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                    HStack {
                        Button(L("Confirm")) {
                            pendingSend = nil
                            _ = attention.sendOutcome(outcome, to: meetingID)
                        }.buttonStyle(.borderedProminent).accessibilityIdentifier("assistant.outcome.confirm")
                        Button(L("Cancel"), role: .cancel) { pendingSend = nil }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
            if let error = attention.outcomeError[outcome.id] ?? outcome.meetingID.flatMap({ attention.outcomeError[$0] }) {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            GroupBox(L("Summary")) {
                TextField(L("Summary"), text: summary, axis: .vertical).lineLimit(3...8)
                    .textFieldStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("history.summary")
            }
            if hasDecisionSources(outcome) {
                Toggle(L("Show transcript references"), isOn: $showingTranscriptSources)
                    .toggleStyle(.checkbox).font(.caption)
                    .accessibilityIdentifier("history.show-sources")
            }
            editableLines(L("Decisions"), values: binding.decisions,
                          evidence: outcome.decisionEvidence ?? [:], sessionID: outcome.meetingID)
            editableLines(L("Open questions"), values: binding.openQuestions)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func seriesHistory(_ outcome: MeetingOutcome) -> some View {
        if outcome.seriesID != nil || outcome.invitation != nil {
            GroupBox(L("Series history")) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(data.seriesOutcomes(invitation: outcome.invitation, series: outcome.seriesID)) { item in
                        Button { select(library.cards.first { $0.outcomeID == item.id }) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.knownEndedAt?.formatted(date: .abbreviated, time: .shortened) ?? L("Date unknown")).font(.caption.weight(.semibold))
                                Text(MeetingOutcomePrompt.displayText(item.summary)).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func meetingTasks(_ outcome: MeetingOutcome) -> some View {
        let binding = Binding(get: { data.outcomes.first { $0.id == outcome.id } ?? outcome },
                              set: { data.updateOutcome($0) })
        return VStack(alignment: .leading, spacing: 12) {
            GroupBox(L("Tasks")) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(outcome.tasks.filter(data.isTaskOperational)) { task in
                        let taskBinding = Binding<MeetingOutcomeTask>(
                            get: { binding.wrappedValue.tasks.first { $0.id == task.id } ?? task },
                            set: { updated in
                                var copy = binding.wrappedValue
                                guard let idx = copy.tasks.firstIndex(where: { $0.id == task.id }) else { return }
                                copy.tasks[idx] = updated
                                binding.wrappedValue = copy
                            }
                        )
                        HStack(alignment: .top, spacing: 8) {
                            Toggle(L("Task completed"), isOn: Binding(get: { taskBinding.wrappedValue.done }, set: { done in
                                var current = taskBinding.wrappedValue
                                current.setDone(done)
                                taskBinding.wrappedValue = current
                            })).labelsHidden()
                            VStack(alignment: .leading, spacing: 4) {
                                TextField(L("Task"), text: Binding(get: {
                                    MeetingOutcomePrompt.displayText(taskBinding.wrappedValue.text)
                                }, set: { text in
                                    var current = taskBinding.wrappedValue
                                    current.text = text
                                    taskBinding.wrappedValue = current
                                }), axis: .vertical).textFieldStyle(.plain)
                                HStack {
                                    TextField(L("Owner"), text: Binding(get: {
                                        MeetingOutcomePrompt.displayText(taskBinding.wrappedValue.owner)
                                    }, set: { owner in
                                        var current = taskBinding.wrappedValue
                                        guard current.owner != owner else { return }
                                        current.owner = owner
                                        current.assigneeID = nil
                                        current.reminderAt = nil
                                        taskBinding.wrappedValue = current
                                    })).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                                    if let due = task.dateForDisplay(calendar: calendar) {
                                        Text(L("Due %@", due.formatted(date: .abbreviated, time: task.dueDay == nil ? .shortened : .omitted)))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Button(task.reminderAt == nil ? L("Remind me") : L("Reminder set")) { attention.remind(task, in: outcome) }
                                .disabled(task.reminderAt != nil || task.done || !data.taskProfile.owns(task))
                            Button {
                                editingOutcomeTask = OutcomeTaskSheetTarget(outcome: outcome, task: task)
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                            .buttonStyle(.borderless)
                            .help(L("Task details, reminder rules & discussion meeting"))
                            Button { var copy = binding.wrappedValue; copy.tasks.removeAll { $0.id == task.id }; data.updateOutcome(copy) } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless).help(L("Delete task"))
                        }
                        .padding(6)
                        .background(navigation.taskID == task.id ? Color.orange.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .id(task.id)
                    }
                    Button(L("Add task")) { var copy = binding.wrappedValue; copy.tasks.append(.init(text: L("New task"))); data.updateOutcome(copy) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !outcome.taskReviewCandidates.isEmpty {
                GroupBox(L("Review suggested tasks")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(outcome.taskReviewCandidates) { candidate in
                            HStack {
                                Text(MeetingOutcomePrompt.displayText(candidate.text))
                                Spacer()
                                if !outcome.tasks.isEmpty {
                                    Menu(L("Match existing task")) {
                                        ForEach(outcome.tasks) { existing in
                                            Button(MeetingOutcomePrompt.displayText(existing.text)) {
                                                attention.reviewTaskCandidate(candidate, in: outcome, accept: false, matchedTaskID: existing.id)
                                            }
                                        }
                                    }
                                }
                                Button(L("Add")) { attention.reviewTaskCandidate(candidate, in: outcome, accept: true) }
                                Button(L("Dismiss")) { attention.reviewTaskCandidate(candidate, in: outcome, accept: false) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func hasDecisionSources(_ outcome: MeetingOutcome) -> Bool {
        guard let sessionID = outcome.meetingID, let session = conversation(sessionID) else { return false }
        let evidence = outcome.decisionEvidence ?? [:]
        let ids = Set(outcome.decisions.flatMap { evidence[$0] ?? [] })
        return session.visibleEvents.contains { ids.contains($0.id) }
    }

    @ViewBuilder private func decisionSources(_ ids: [String], sessionID: UUID?) -> some View {
        if let sessionID, let session = conversation(sessionID) {
            let events: [MeetingWorkspaceEvent] = session.visibleEvents.filter { ids.contains($0.id) }
            ForEach(events) { event in
                decisionSource(event)
            }
        }
    }

    private func decisionSource(_ event: MeetingWorkspaceEvent) -> some View {
        let timestamp: String = workspaceDate(event.occurredAt)
        let title: String = timestamp + " · " + event.displayAuthor
        return Button {
            navigation.eventID = event.id
            navigation.tab = .transcript
        } label: {
            Label(title, systemImage: "text.quote")
        }.buttonStyle(.borderless).foregroundStyle(.orange).font(.caption)
            .help(event.displayText)
            .accessibilityIdentifier("history.decision-source")
    }

    private func editableLines(_ title: String, values: Binding<[String]>, evidence: [String: [String]] = [:],
                               sessionID: UUID? = nil) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(values.wrappedValue.enumerated()), id: \.offset) { index, current in
                    let lineBinding = Binding<String>(
                        get: { MeetingOutcomePrompt.displayText(values.wrappedValue.indices.contains(index) ? values.wrappedValue[index] : current) },
                        set: { newValue in
                            guard values.wrappedValue.indices.contains(index) else { return }
                            values.wrappedValue[index] = newValue
                        }
                    )
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(title, text: lineBinding, axis: .vertical).textFieldStyle(.plain)
                            if showingTranscriptSources {
                                decisionSources(evidence[current] ?? [], sessionID: sessionID)
                            }
                        }
                        Button {
                            guard values.wrappedValue.indices.contains(index) else { return }
                            values.wrappedValue.remove(at: index)
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help(L("Delete line"))
                    }
                }
                Button(L("Add line")) { values.wrappedValue.append("") }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AssistantOutcomeHistoryView: View {
    let store: MeetingLibraryStore
    let sessionID: UUID
    let updatedAt: Date
    @State private var history: [MeetingOutcomeVersion] = []

    var body: some View {
        VStack(alignment: .leading) {
            if !history.isEmpty {
                DisclosureGroup(L("Previous outcome versions")) {
                    ForEach(history) { version in
                        VStack(alignment: .leading, spacing: 5) {
                            if let date = version.savedAt {
                                Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                            }
                            Text(version.outcome.shareText).textSelection(.enabled)
                        }.padding(.vertical, 5)
                    }
                }.padding(20)
            }
        }
        .task(id: updatedAt) {
            let versions = try? await store.outcomeVersions(sessionID: sessionID)
            if !Task.isCancelled { history = (versions ?? []).filter { !$0.isCurrent } }
        }
    }
}

private struct RenameMeetingSheet: View {
    let library: MeetingLibraryController
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var error: String?
    @State private var saving = false

    init(library: MeetingLibraryController, sessionID: UUID, currentTitle: String) {
        self.library = library
        self.sessionID = sessionID
        _title = State(initialValue: currentTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Rename meeting")).font(.headline)
            TextField(L("Meeting title"), text: $title).textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save"), action: save).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 360).disabled(saving).interactiveDismissDisabled(saving)
    }

    private func save() {
        guard !saving else { return }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { error = L("Enter a meeting title."); return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await library.renameSession(sessionID, title: value)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// "Last time" on the home screen. Observes assistant data on its own.
struct AssistantLastOutcome: View {
    @ObservedObject var assistant: AssistantDataStore
    var invitation: URL?
    var series: String?
    var before: Date

    var body: some View {
        if let outcome = assistant.latestOutcome(invitation: invitation, series: series, before: before) {
            LastTimeView(outcome: outcome, visibleTasks: outcome.tasks.filter(assistant.isTaskOperational))
        }
    }
}

struct LastTimeView: View {
    let outcome: MeetingOutcome
    let visibleTasks: [MeetingOutcomeTask]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("Last time: %@", MeetingOutcomePrompt.displayText(outcome.summary))).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            let pending = visibleTasks.filter { !$0.done }
            if !pending.isEmpty {
                Text(L("Open tasks: %ld of %ld", pending.count, visibleTasks.count)).font(.caption2).foregroundStyle(.orange)
            }
        }.accessibilityElement(children: .combine)
    }
}
