import AppKit
import SwiftUI

struct MeetingWorkspaceReview: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    @ObservedObject var state: MeetingWorkspaceViewState
    @ObservedObject var journal: MeetingWorkspaceJournal
    @ObservedObject private var library: MeetingLibraryController
    @ObservedObject private var guidance: MeetingWorkspaceGuidance

    @State private var meetingQuery = ""
    @State private var showingGuidance = false

    private struct ArchivedMeeting: Identifiable {
        let id: UUID
        let title: String
        let startedAt: Date?
        let endedAt: Date?
        let session: MeetingWorkspaceSession?
    }

    init(workspace: NativeDesktopWorkspace, state: MeetingWorkspaceViewState, journal: MeetingWorkspaceJournal) {
        self.workspace = workspace
        self.state = state
        self.journal = journal
        _library = ObservedObject(wrappedValue: workspace.attention.store.meetingLibrary)
        _guidance = ObservedObject(wrappedValue: workspace.attention.store.workspaceGuidance)
    }

    private var meetings: [ArchivedMeeting] {
        let journalIDs = Set(journal.sessions.map(\.id))
        let liveIDs = Set(workspace.meetings.map(\.sessionID))
        let saved = journal.sessions.filter { $0.endedAt != nil && !liveIDs.contains($0.id) }.map {
            ArchivedMeeting(id: $0.id, title: $0.title, startedAt: $0.startedAt, endedAt: $0.endedAt, session: $0)
        }
        let older = library.cards.filter {
            $0.endedAt != nil && !journalIDs.contains($0.sessionID) && !liveIDs.contains($0.sessionID)
        }.map {
            ArchivedMeeting(id: $0.sessionID, title: $0.title, startedAt: $0.startedAt, endedAt: $0.endedAt, session: nil)
        }
        let search = meetingQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return (saved + older).filter { search.isEmpty || $0.title.localizedStandardContains(search) }
            .sorted { ($0.startedAt ?? $0.endedAt ?? .distantPast) > ($1.startedAt ?? $1.endedAt ?? .distantPast) }
    }

    var body: some View {
        let visible = meetings
        let selected = visible.first { $0.id == state.reviewID } ?? visible.first
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                Text(L("Saved meetings")).font(.headline)
                TextField(L("Search meetings"), text: $meetingQuery).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("meetingWorkspace.findMeeting")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(visible) { item in
                            Button { state.reviewID = item.id } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                                    if let date = item.startedAt ?? item.endedAt {
                                        Text(workspaceDate(date, style: .abbreviated))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(item.id == selected?.id ? .teal.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help(item.title)
                            .accessibilityAddTraits(item.id == selected?.id ? .isSelected : [])
                        }
                    }
                }
                Button { showingGuidance = true } label: {
                    Label(L("Saved guidance"), systemImage: "slider.horizontal.3")
                }.buttonStyle(.borderless)
            }
            .padding(14).frame(width: 185).frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            if let selected {
                if let session = selected.session {
                    WorkspaceSessionReview(session: session, journal: journal, guidance: guidance, library: library)
                        .id(session.id)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(selected.title).font(.title2.bold())
                        Text(L("No saved transcript or assistant reply text is available for this meeting."))
                            .foregroundStyle(.secondary)
                        ParticipationOutcomeActivity(sessionID: selected.id, root: workspace.attention.store.root)
                        Button(L("Open meeting outcome")) {
                            workspace.attention.requestedOutcomeSessionID = selected.id
                            workspace.show(section: .assistant)
                        }
                        Spacer()
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .id(selected.id)
                }
            } else {
                WorkspaceEmptyView(title: L("No saved meetings"), detail: meetingQuery.isEmpty
                    ? L("Conversations captured on this Mac appear here after you leave.")
                    : L("No saved meetings match your search."), symbol: "clock.arrow.circlepath")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.teal)
        .sheet(isPresented: $showingGuidance) { WorkspaceSavedGuidance(guidance: guidance, journal: journal) }
    }
}

private struct WorkspaceSessionReview: View {
    enum Filter: CaseIterable, Hashable {
        case all, assistant, bookmarks

        var title: String {
            switch self {
            case .all: L("Full conversation")
            case .assistant: L("Assistant replies")
            case .bookmarks: L("Bookmarked")
            }
        }

        func includes(_ event: MeetingWorkspaceEvent) -> Bool {
            switch self {
            case .all: true
            case .assistant: event.kind == .assistantReply
            case .bookmarks: event.isBookmarked
            }
        }
    }

    let session: MeetingWorkspaceSession
    @ObservedObject var journal: MeetingWorkspaceJournal
    @ObservedObject var guidance: MeetingWorkspaceGuidance
    let library: MeetingLibraryController

    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var replyID: String?
    @State private var outcome: MeetingOutcome?
    @State private var confirmDelete = false
    @State private var deleteError: String?
    @State private var copied = false

    private var events: [MeetingWorkspaceEvent] { session.visibleEvents }
    private var filteredEvents: [MeetingWorkspaceEvent] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return events.filter { filter.includes($0) && $0.matches(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            recap
            ViewThatFits(in: .horizontal) {
                HStack { filterPicker; Spacer(minLength: 7); searchField.frame(width: 170) }
                VStack(alignment: .leading, spacing: 7) { filterPicker; searchField }
            }
            GeometryReader { geometry in
                let inline = geometry.size.width >= 680
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        WorkspaceTimeline(events: filteredEvents,
                            empty: query.isEmpty && filter == .all ? L("No conversation captured") : L("No matching entries"),
                            live: false, followsLatest: false, selectedID: replyID, onSelect: { replyID = $0 },
                            onBookmark: { journal.toggleBookmark(sessionID: session.id, eventID: $0) })
                        if !inline, selectedReply != nil {
                            Button(L("Reflect on this reply"), systemImage: "sidebar.right") { showingReflection = true }
                        }
                        if let endedAt = session.endedAt {
                            Label(L("Last recorded activity · %@", workspaceDate(endedAt)),
                                  systemImage: "archivebox").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(9).modifier(WorkspacePanel())
                    if inline {
                        ScrollView {
                            if let event = selectedReply {
                                WorkspaceReflection(session: session, event: event, guidance: guidance, journal: journal).id(event.id)
                            } else {
                                WorkspaceEmptyView(title: L("Reflect on a reply"), detail: L("Select an assistant reply to see its context and delivery status."),
                                                   symbol: "sparkle.magnifyingglass")
                            }
                        }.frame(width: min(275, geometry.size.width * 0.38)).modifier(WorkspacePanel())
                    }
                }
                .onChange(of: replyID) { _ in if !inline { showingReflection = replyID != nil } }
            }
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: session.id) {
            outcome = await library.outcome(sessionID: session.id)
        }
        .confirmationDialog(L("Delete saved conversation?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Delete saved conversation"), role: .destructive) {
                do { try journal.delete(sessionID: session.id) }
                catch { deleteError = error.localizedDescription }
            }
        } message: {
            Text(L("This removes the captured conversation, reply evidence, and bookmarks from this Mac."))
        }
        .alert(L("Could not delete conversation"), isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button(L("OK")) { deleteError = nil }
        } message: { Text(deleteError ?? "") }
        .sheet(isPresented: $showingReflection) {
            if let event = selectedReply {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView { WorkspaceReflection(session: session, event: event, guidance: guidance, journal: journal) }
                    Divider()
                    HStack { Spacer(); Button(L("Done")) { showingReflection = false }.keyboardShortcut(.defaultAction) }
                        .padding(12)
                }
                .frame(width: 450, height: 510)
            }
        }
    }

    @State private var showingReflection = false
    private var selectedReply: MeetingWorkspaceEvent? { events.first { $0.id == replyID && $0.kind == .assistantReply } }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.title2.weight(.semibold)).lineLimit(2).help(session.title)
                Text(workspaceDate(session.startedAt, style: .long))
                    .font(.caption).foregroundStyle(.secondary)
                Label(session.interrupted ? L("Recording interrupted") : L("Saved on this Mac"),
                      systemImage: session.interrupted ? "exclamationmark.triangle" : "internaldrive")
                    .font(.caption).foregroundStyle(session.interrupted ? .orange : .secondary)
            }
            Spacer(minLength: 7)
            if let outcome, !outcome.summary.isEmpty {
                Button(copied ? L("Copied") : L("Copy recap"), systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(outcome.summary, forType: .string)
                }.lineLimit(1)
            }
            Menu {
                Button(L("Delete saved conversation"), role: .destructive) { confirmDelete = true }
            } label: {
                Label(L("Conversation actions"), systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }.menuIndicator(.hidden).fixedSize()
        }
    }

    @ViewBuilder private var recap: some View {
        if let outcome, !outcome.summary.isEmpty {
            DisclosureGroup(L("Meeting recap")) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(outcome.summary).textSelection(.enabled)
                        ForEach(Array(outcome.decisions.enumerated()), id: \.offset) { _, decision in
                            Label(decision, systemImage: "checkmark.circle").textSelection(.enabled)
                        }
                    }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 120)
            }.padding(9).modifier(WorkspacePanel())
        }
        if session.interrupted || events.contains(where: { $0.kind == .captureGap }) {
            Label(L("This conversation has gaps in speech capture."), systemImage: "waveform.slash")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var filterPicker: some View {
        Picker(L("Conversation filter"), selection: $filter) {
            ForEach(Filter.allCases, id: \.self) { option in Text(option.title).tag(option) }
        }.labelsHidden().pickerStyle(.segmented).accessibilityIdentifier("meetingWorkspace.reviewFilter")
    }

    private var searchField: some View {
        TextField(L("Find in conversation"), text: $query)
            .textFieldStyle(.roundedBorder).accessibilityIdentifier("meetingWorkspace.findConversation")
    }
}

private struct WorkspaceReflection: View {
    let session: MeetingWorkspaceSession
    let event: MeetingWorkspaceEvent
    @ObservedObject var guidance: MeetingWorkspaceGuidance
    let journal: MeetingWorkspaceJournal

    @State private var text = ""
    @State private var scope: MeetingWorkspaceGuidance.Scope?
    @State private var message: String?

    private var suggestedScope: MeetingWorkspaceGuidance.Scope? {
        matchingScopes.first
    }

    private var matchingScopes: [MeetingWorkspaceGuidance.Scope] {
        [session.calendarSeriesID.map(MeetingWorkspaceGuidance.Scope.calendarSeries),
         session.roomRuleKey.map(MeetingWorkspaceGuidance.Scope.room)].compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            WorkspaceReplyEvidence(event: event, title: L("Reflect on this reply"))
            Divider()
            Text(L("What would you change?")).font(.headline)
            Menu(L("Reflection prompts")) {
                Button(L("Too generic")) { text = L("Use the meeting context to answer specifically. Ask one focused question when important information is missing.") }
                Button(L("Timing")) { text = L("Answer direct questions promptly. Wait for a pause before adding unsolicited context.") }
                Button(L("My wording")) { text = L("Keep my replies short and conversational.") }
            }
            TextEditor(text: $text).font(.callout).frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                .accessibilityLabel(L("Guidance for next time"))
            Picker(L("Apply to"), selection: $scope) {
                Text(L("Choose a scope")).tag(nil as MeetingWorkspaceGuidance.Scope?)
                ForEach(matchingScopes, id: \.self) { scope in
                    Text(scope.title).tag(Optional(scope))
                }
                Text(L("All my meetings")).tag(Optional(MeetingWorkspaceGuidance.Scope.allMeetings))
            }
            Button(L("Save guidance"), action: save).buttonStyle(.borderedProminent)
                .disabled(scope == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("meetingWorkspace.saveReflection")
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if scope == nil { scope = suggestedScope } }
    }

    private func save() {
        guard let scope else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if try guidance.append(clean, to: scope) {
                let snapshot = MeetingWorkspaceEvent.SourceSnapshot(id: event.id, title: L("Reply under review"),
                    text: event.text, revision: nil, capturedAt: event.occurredAt)
                journal.recordGuidance(sessionID: session.id, text: clean, source: scope.eventSource, sourceSnapshots: [snapshot])
            }
            text = ""
            message = L("Guidance saved for future replies.")
        } catch { message = error.localizedDescription }
    }
}

private struct WorkspaceSavedGuidance: View {
    @ObservedObject var guidance: MeetingWorkspaceGuidance
    let journal: MeetingWorkspaceJournal
    @Environment(\.dismiss) private var dismiss
    @State private var editing: MeetingWorkspaceGuidance.Rule?
    @State private var text = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Saved guidance")).font(.title2.bold())
            if guidance.rules.isEmpty {
                WorkspaceEmptyView(title: L("No saved guidance"), detail: L("Reflect on an assistant reply to add guidance for future meetings."),
                                   symbol: "text.bubble")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(guidance.rules, id: \.self) { rule in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(rule.scope.label(in: journal.sessions)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                if editing == rule {
                                    TextEditor(text: $text).font(.body).frame(height: 65)
                                    HStack {
                                        Button(L("Cancel")) { editing = nil; message = nil }
                                        Button(L("Save")) { update(rule) }.buttonStyle(.borderedProminent)
                                    }
                                } else {
                                    Text(rule.text).textSelection(.enabled)
                                    HStack {
                                        Button(L("Edit")) { editing = rule; text = rule.text; message = nil }
                                        Button(L("Remove"), role: .destructive) { remove(rule) }
                                    }.buttonStyle(.borderless)
                                }
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading).modifier(WorkspacePanel())
                        }
                    }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            HStack { Spacer(); Button(L("Done")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16).frame(width: 485, height: 385)
    }

    private func update(_ rule: MeetingWorkspaceGuidance.Rule) {
        do { try guidance.replace(rule, text: text); editing = nil; message = nil }
        catch { message = error.localizedDescription }
    }

    private func remove(_ rule: MeetingWorkspaceGuidance.Rule) {
        do { try guidance.remove(rule); message = nil }
        catch { message = error.localizedDescription }
    }
}
