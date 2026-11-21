import ConferenceCore
import SwiftUI

enum IOSWorkspaceHubTab: String, CaseIterable, Identifiable {
    case ask
    case history
    case tasks
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return L("Ask")
        case .history: return L("Meetings")
        case .tasks: return L("Tasks")
        case .search: return L("Search")
        }
    }
}

struct IOSWorkspaceHubView: View {
    @ObservedObject var workspace: IOSWorkspaceCoordinator
    @ObservedObject var sync: RoomSyncCoordinator
    @ObservedObject var assistant: IOSAssistantCoordinator
    var talk: IOSAssistantTalkController? = nil
    var speech: IOSAssistantSpeechCoordinator? = nil
    let initialTab: IOSWorkspaceHubTab

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var selectedTab: IOSWorkspaceHubTab
    @State private var selectedSessionID: UUID?
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var showingSettings = false
    @State private var renamingSession: IOSMeetingSessionItem?
    @State private var renameDraft = ""
    @State private var searchQuery = ""
    @State private var searchHits: [IOSWorkspaceSearchHit] = []

    init(
        workspace: IOSWorkspaceCoordinator,
        sync: RoomSyncCoordinator,
        assistant: IOSAssistantCoordinator,
        talk: IOSAssistantTalkController? = nil,
        speech: IOSAssistantSpeechCoordinator? = nil,
        initialTab: IOSWorkspaceHubTab = .history
    ) {
        self.workspace = workspace
        self.sync = sync
        self.assistant = assistant
        self.talk = talk
        self.speech = speech
        self.initialTab = initialTab
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            VStack(spacing: 0) {
                tabSelector
                if sizeClass == .regular {
                    historyList
                } else {
                    tabDetailContent
                }
            }
            .navigationTitle(L("Assistant"))
            .toolbar { hubToolbar }
        } detail: {
            if sizeClass == .regular && selectedTab != .history {
                tabDetailContent
                    .navigationTitle(selectedTab.title)
            } else if let selectedID = selectedSessionID ?? workspace.historySessions.first?.id {
                IOSMeetingDetailView(workspace: workspace, sync: sync, sessionID: selectedID)
            } else {
                ContentUnavailableView(
                    L("No Meetings Yet"),
                    systemImage: "note.text",
                    description: Text(L("Recorded meetings, summaries, notes, and tasks synced from your Mac and iPhone appear here."))
                )
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                IOSAssistantSettingsView(workspace: workspace, sync: sync, assistant: assistant)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L("Done")) { showingSettings = false }
                        }
                    }
            }
        }
        .alert(L("Rename Meeting"), isPresented: Binding(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        )) {
            TextField(L("Title"), text: $renameDraft)
            Button(L("Cancel"), role: .cancel) { renamingSession = nil }
            Button(L("Save")) {
                if let session = renamingSession {
                    let title = renameDraft
                    renamingSession = nil
                    Task { await workspace.renameSession(session.id, title: title) }
                }
            }
        }
        .task {
            await workspace.reloadFromStore()
        }
    }

    private var tabSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(IOSWorkspaceHubTab.allCases) { tab in
                    let isSelected = selectedTab == tab
                    let labelText = (tab == .tasks && workspace.openTasksCount > 0)
                        ? "\(tab.title) (\(workspace.openTasksCount))"
                        : tab.title
                    Button {
                        selectedTab = tab
                        if sizeClass == .regular {
                            compactColumn = tab == .history ? .sidebar : .detail
                        }
                    } label: {
                        Text(labelText)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(minHeight: 36)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemFill),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? Color.rockBrandTint : .primary)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("workspace.hub.mode")
    }

    @ViewBuilder
    private var tabDetailContent: some View {
        switch selectedTab {
        case .ask:
            if let talk, let speech {
                IOSAssistantTalkView(talk: talk, speech: speech)
            } else {
                IOSStandaloneAskView(workspace: workspace, assistant: assistant)
            }
        case .history:
            historyList
        case .tasks:
            IOSPersonalTasksView(workspace: workspace) { sessionID in
                openMeeting(sessionID)
            }
        case .search:
            searchView
        }
    }

    @ToolbarContentBuilder
    private var hubToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L("Done")) { dismiss() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                Task { await workspace.synchronizeNow() }
            } label: {
                if workspace.isSyncing {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
            .accessibilityLabel(L("Sync Now"))
            .disabled(!sync.enabled || workspace.isSyncing)

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityIdentifier("workspace.hub.settings")
            .accessibilityLabel(L("Assistant Settings"))
        }
    }

    @ViewBuilder
    private var historyList: some View {
        if workspace.historySessions.isEmpty {
            ContentUnavailableView(
                L("No Meetings Yet"),
                systemImage: "note.text",
                description: Text(L("Start or join a meeting on iPhone or Mac to capture synced notes, summaries, and tasks."))
            )
        } else {
            List(selection: sizeClass == .regular ? $selectedSessionID : .constant(nil)) {
                ForEach(workspace.historySessions) { session in
                    Button {
                        openMeeting(session.id)
                    } label: {
                        meetingRow(session)
                    }
                    .buttonStyle(.plain)
                    .tag(session.id)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await workspace.deleteSession(session.id) }
                        } label: {
                            Label(L("Delete"), systemImage: "trash")
                        }
                        Button {
                            renameDraft = session.title
                            renamingSession = session
                        } label: {
                            Label(L("Rename"), systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable {
                await workspace.synchronizeNow()
            }
        }
    }

    private func meetingRow(_ session: IOSMeetingSessionItem) -> some View {
        let outcome = workspace.outcomesBySession[session.id]
        let note = workspace.notesBySession[session.id]
        let openTasks = workspace.tasks.filter { $0.sessionID == session.id && !$0.done }.count

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                obsidianBadge(for: session.obsidianReceipt)
            }

            HStack(spacing: 8) {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let endedAt = session.endedAt, endedAt > session.startedAt {
                    let minutes = max(1, Int((endedAt.timeIntervalSince(session.startedAt) / 60).rounded()))
                    Text(L("· %ld min", minutes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if openTasks > 0 {
                    Text(L("%ld tasks", openTasks))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                if note?.isEmpty == false {
                    Image(systemName: "note.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let summary = outcome?.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let preview = note?.markdown.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func obsidianBadge(for receipt: ObsidianSyncReceipt?) -> some View {
        if let receipt {
            switch receipt.state {
            case "exported":
                Label(L("Obsidian"), systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            case "conflict":
                Label(L("Conflict"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            default:
                Label(L("Queued"), systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var searchView: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L("Search meetings, notes, summaries, tasks"), text: $searchQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        searchHits = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            .padding(.bottom, 8)
            .onChange(of: searchQuery) { _, newValue in
                Task { searchHits = await workspace.search(query: newValue) }
            }

            if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    L("Search Workspace"),
                    systemImage: "magnifyingglass",
                    description: Text(L("Find any synced meeting title, Markdown note, summary, or task."))
                )
            } else if searchHits.isEmpty {
                ContentUnavailableView(
                    L("No Results"),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(L("No meetings matched “%@”.", searchQuery))
                )
            } else {
                List(searchHits) { hit in
                    Button {
                        openMeeting(hit.sessionID)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hit.title).font(.headline)
                            Text(hit.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !hit.snippet.isEmpty {
                                Text(hit.snippet)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private func openMeeting(_ sessionID: UUID) {
        selectedSessionID = sessionID
        selectedTab = .history
        compactColumn = .detail
    }
}

private struct IOSStandaloneAskView: View {
    @ObservedObject var workspace: IOSWorkspaceCoordinator
    @ObservedObject var assistant: IOSAssistantCoordinator
    @StateObject private var speech: IOSAssistantSpeechCoordinator
    @StateObject private var talk: IOSAssistantTalkController

    init(workspace: IOSWorkspaceCoordinator, assistant: IOSAssistantCoordinator) {
        self.workspace = workspace
        self.assistant = assistant
        let speech = IOSAssistantSpeechCoordinator()
        _speech = StateObject(wrappedValue: speech)
        _talk = StateObject(wrappedValue: IOSAssistantTalkController(workspace: workspace, assistant: assistant, speech: speech))
    }

    var body: some View {
        IOSAssistantTalkView(talk: talk, speech: speech)
    }
}
