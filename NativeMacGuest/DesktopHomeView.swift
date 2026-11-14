import AppKit
import ConferenceCore
import SwiftUI

enum NativeDesktopHomePresentation {
    static func today(_ meetings: [CalendarMeeting], now: Date, calendar: Calendar = .current) -> [CalendarMeeting] {
        meetings.filter { calendar.isDate($0.start, inSameDayAs: now) }
    }

    static func rooms(_ rooms: [RecentRoom], matching search: String) -> [RecentRoom] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return rooms.filter { query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query) || $0.joinURL.host?.localizedCaseInsensitiveContains(query) == true }
    }
}

enum NativeDesktopSettingsSearch {
    /// Search navigates to the owning Assistant page without claiming to index
    /// every individual control inside that page.
    static func assistantAreas(matching search: String) -> [NativeDesktopAssistantSettingsArea] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let entries: [(NativeDesktopAssistantSettingsArea, [String])] = [
            (.attention, ["Attention", "Meeting instructions"]),
            (.voice, ["Voice", "Hold ⌥Space to talk to Assistant"]),
            (.models, ["Models", "Provider", "API key"]),
            (.replies, ["Replies", "Agent", "Meeting sends"]),
            (.privacy, ["Memory", "Privacy", "What leaves this Mac"])
        ]
        return entries.compactMap { area, terms in
            let candidates = [area.title] + terms + terms.map { L($0) }
            return candidates.contains { $0.localizedCaseInsensitiveContains(query) } ? area : nil
        }
    }
}

struct NativeDesktopHomeView: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    @ObservedObject var library: NativeDesktopLibrary
    @State private var favoritesSearch = ""
    @State private var recentSearch = ""
    @State private var favoriteURL = ""
    @State private var favoriteTitle = ""
    @State private var addingFavorite = false
    @State private var editRoom: RecentRoom?
    @State private var renamed = ""
    @State private var homeSnapshot = HomeMeetingSnapshot()
    @State private var hoveringHomeMeetings = false
    @State private var detailWidth: CGFloat = 0
    /// Below this width the transcription announcement leaves the toolbar for a strip.
    private static let inlineAnnouncementWidth: CGFloat = 1050
    private var embeddedMeeting: NativeDesktopMeetingModel? {
        workspace.selectedMeeting.flatMap { workspace.isDetached($0) ? nil : $0 }
    }
    @State private var bindingLink = ""
    @State private var bindingSeries = true
    @FocusState private var editingName: Bool
    private var blocksScheduledJoining: Bool {
        editingName || addingFavorite || editRoom != nil || library.calendar.choosingMeeting != nil ||
        library.calendar.reminders.editing != nil || library.setup.isPresented
    }
    /// Discoveries apply immediately; only rows under the pointer or behind an
    /// open editor are held, so a card cannot move as it is clicked.
    private var acceptsHomeChanges: Bool { !hoveringHomeMeetings && !blocksScheduledJoining }
    private var showsFirstLibraryGuidance: Bool {
        library.history.rooms.isEmpty && library.calendar.meetings.isEmpty &&
        library.continuation.candidates.isEmpty && homeSnapshot.items.isEmpty &&
        workspace.meeting == nil && !workspace.preparing && workspace.error == nil &&
        library.persistenceWarning == nil && library.continuation.status == nil &&
        !library.continuation.moving && !library.calendar.loading &&
        !library.sync.enabled && !library.sync.busy && !library.sync.needsFreshAccount &&
        library.sync.nameChoice == nil
    }
    @ViewBuilder private var settingsView: some View {
        #if NATIVE_DIRECT_UPDATES
        NativeDesktopSettingsView(library: library, meeting: workspace.meeting, tab: $workspace.settingsTab, assistantArea: $workspace.assistantSettingsArea, attention: workspace.attention, updates: workspace.updates, mcpService: workspace.mcpService, obsidian: workspace.obsidian)
        #else
        NativeDesktopSettingsView(library: library, meeting: workspace.meeting, tab: $workspace.settingsTab, assistantArea: $workspace.assistantSettingsArea, attention: workspace.attention, mcpService: workspace.mcpService, obsidian: workspace.obsidian)
        #endif
    }
    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { workspace.sidebarSelection }, set: { workspace.sidebarSelection = $0 })) {
                // Live meetings come first: each one is a destination in this window.
                if !workspace.meetings.isEmpty {
                    Section(workspace.meetings.count > 1 ? L("Meetings") : L("In meeting")) {
                        ForEach(workspace.meetings, id: \.sessionID) { model in
                            NativeDesktopSidebarMeetingRow(workspace: workspace, model: model)
                                .tag(NativeDesktopSidebarItem.meeting(model.sessionID))
                        }
                    }
                }
                Section {
                    ForEach(NativeDesktopWorkspace.Section.allCases) { item in
                        HStack {
                            Label(item == .recent ? L("Recent rooms") : L(item.rawValue), systemImage: item.symbol)
                            if item == .assistant { AssistantUnreadBadge(store: workspace.attention.store) }
                        }.tag(NativeDesktopSidebarItem.section(item))
                    }
                }
                if !library.favorites.isEmpty {
                    Section(L("Favorites")) {
                        ForEach(library.favorites) { room in
                            Button { library.open(room) } label: {
                                Label(room.displayTitle, systemImage: "star.fill").lineLimit(1)
                            }.buttonStyle(.plain).contextMenu { roomMenu(room) }
                        }.onMove { library.moveFavorites(from: $0, to: $1) }
                    }
                }
            }
            .listStyle(.sidebar).navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Image(systemName: library.sync.enabled ? "icloud" : "internaldrive")
                    Text(library.sync.status).font(.caption).lineLimit(2)
                    Spacer()
                }.foregroundStyle(.secondary).padding(12)
            }
        } detail: {
            ZStack {
                if workspace.selectedMeeting == nil {
                    Group {
                        switch workspace.selection {
                        case .settings: settingsView
                        case .favorites: roomList(library.favorites, title: L("Favorites"), search: $favoritesSearch, reorder: true)
                        case .recent: roomList(library.recent, title: L("Recent rooms"), search: $recentSearch)
                        case .calendar: agenda
                        case .workspace: NativeDesktopMeetingWorkspaceView(workspace: workspace)
                        case .assistant: AttentionMomentsView(attention: workspace.attention, store: workspace.attention.store)
                        case .tasks:
                            PersonalTasksView(attention: workspace.attention) { sessionID in
                                workspace.attention.requestedOutcomeSessionID = sessionID
                                workspace.selection = .assistant
                            }.navigationTitle(L("My Tasks"))
                        case .home: home
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    #if NATIVE_DIRECT_UPDATES
                    .safeAreaInset(edge: .top) {
                        if let updates = workspace.updates { NativeDesktopUpdateBanner(updates: updates) }
                    }
                    #endif
                }
                // Every embedded meeting stays mounted so switching keeps its panels,
                // zoom and Presenter draft; only the selected one renders media.
                ForEach(workspace.embeddedMeetings, id: \.sessionID) { model in
                    let shown = workspace.selectedMeetingID == model.sessionID
                    NativeDesktopMeetingView(model: model, onMini: { workspace.showMini(model) }, continuation: library.continuation,
                                             workspace: workspace, onWindowToggle: { workspace.toggleWindow(model) }, embedded: true,
                                             presentsErrors: shown && workspace.error == nil && workspace.notice == nil)
                        .opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
                }
                if let selected = workspace.selectedMeeting {
                    if workspace.isDetached(selected) { detachedMeeting(selected) }
                    Color.clear.allowsHitTesting(false)
                        .navigationTitle(selected.title)
                        .navigationSubtitle(meetingSubtitle(selected))
                }
                AttentionCardStack(attention: workspace.attention, openAssistant: { workspace.show(section: .assistant) })
            }
            .sheet(item: Binding(get: { workspace.attention.inspecting }, set: { workspace.attention.inspecting = $0 })) { card in
                AttentionInspector(attention: workspace.attention, card: card)
            }
            .sheet(item: Binding(get: { workspace.attention.editingPreset }, set: { workspace.attention.editingPreset = $0 })) { target in
                MeetingPresetEditor(store: workspace.attention.store, target: target)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let meeting = embeddedMeeting, detailWidth < Self.inlineAnnouncementWidth { NativeDesktopTranscriptionStrip(model: meeting) }
            }
            .background(GeometryReader { proxy in
                Color.clear.onAppear { detailWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { detailWidth = $0 }
            })
        }
        .tint(.orange)
        .onAppear { refreshHome(); library.calendar.setScheduledUIBlocked(blocksScheduledJoining) }
        .onChange(of: blocksScheduledJoining) { library.calendar.setScheduledUIBlocked($0); refreshHome() }
        .onChange(of: homeSnapshot.items.isEmpty) { if $0 { hoveringHomeMeetings = false } }
        .onDisappear { library.calendar.setScheduledUIBlocked(false); if editingName { library.sync.endNameEditing() } }
        .onReceive(library.objectWillChange) { _ in Task { @MainActor in refreshHome() } }
        .onChange(of: editingName) { value in
            if value { library.sync.beginNameEditing() } else { library.sync.endNameEditing() }
        }
        .sheet(item: Binding(get: { library.calendar.choosingMeeting }, set: { library.calendar.choosingMeeting = $0 })) { meeting in
            VStack(alignment: .leading, spacing: 16) {
                Text(L("Choose room")).font(.title2.bold()); Text(meeting.title)
                Toggle(L("Remember for this series"), isOn: $bindingSeries)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(meeting.links.compactMap(library.calendar.invitationNormalizer), id: \.absoluteString) { url in
                            Button(roomDetail(url, engine: meeting.engine)) { library.calendar.bind(meeting, to: url, series: bindingSeries) }
                        }
                        ForEach(library.history.rooms) { room in
                            Button(room.displayTitle) { library.calendar.bind(meeting, to: room.joinURL, series: bindingSeries) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 240)
                TextField(L("Invitation link"), text: $bindingLink).textFieldStyle(.roundedBorder)
                HStack {
                    Button(L("Cancel")) { library.calendar.choosingMeeting = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(L("Use this room")) {
                        if let destination = try? library.normalizedDestination(bindingLink) { library.calendar.bind(meeting, to: destination.invitationURL, series: bindingSeries) }
                    }.disabled((try? library.normalizedDestination(bindingLink)) == nil)
                }
            }.padding(24).frame(width: 460)
        }
        .onChange(of: workspace.selection) { value in library.calendar.showingMacSettings = value == .settings }
        .toolbar { mainToolbar }
        .sheet(isPresented: $addingFavorite) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("Add favorite")).font(.title2.bold())
                TextField(L("Meeting name"), text: $favoriteTitle)
                TextField(L("Invitation link"), text: $favoriteURL)
                HStack {
                    Button(L("Cancel")) { addingFavorite = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(L("Save")) {
                        do { _ = try library.createFavorite(invitation: favoriteURL, title: favoriteTitle); addingFavorite = false; favoriteURL = ""; favoriteTitle = "" }
                        catch { workspace.error = error.localizedDescription }
                    }.keyboardShortcut(.defaultAction).disabled(favoriteURL.isEmpty)
                }
            }.textFieldStyle(.roundedBorder).padding(24).frame(width: 450)
        }
        .sheet(item: Binding(get: { library.calendar.reminders.editing }, set: { library.calendar.reminders.editing = $0 })) { occurrence in
            NativeDesktopOccurrenceReminderView(occurrence: occurrence, reminders: library.calendar.reminders)
        }
        .sheet(item: $editRoom) { room in
            VStack(alignment: .leading, spacing: 16) {
                Text(L("Meeting name")).font(.title2.bold()); TextField(L("Meeting name"), text: $renamed)
                HStack {
                    Button(L("Cancel")) { editRoom = nil }.keyboardShortcut(.cancelAction)
                    Spacer(); Button(L("Save")) { library.rename(room, to: renamed); editRoom = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 400)
        }
        .sheet(isPresented: Binding(get: { library.setup.isPresented }, set: { if !$0 { library.setup.finishLater() } }), onDismiss: { library.setup.presentationDidDismiss() }) {
            NativeDesktopSetupView(library: library)
        }
        .alert(alertTitle, isPresented: alertShown) {
            Button(L("OK")) { dismissAlert() }
        } message: { Text(alertMessage) }
    }
    /// A meeting shown here puts its status and tools in the window toolbar, beside its title.
    @ToolbarContentBuilder private var mainToolbar: some ToolbarContent {
        if let meeting = embeddedMeeting, meeting.transcriptionIndicator != nil {
            // Its own glass group. Sharing the button group's capsule clips this pill.
            ToolbarItem(placement: .primaryAction) {
                NativeDesktopTranscriptionPill(model: meeting, compact: true, announcesInline: detailWidth >= Self.inlineAnnouncementWidth)
            }
        }
        // The chip sits in its own toolbar item: sharing the button group's
        // capsule clips the chip's outline. Shown on every home screen (not only
        // the Assistant) so the status is always one tap away.
        if workspace.selectedMeeting == nil {
            ToolbarItem(placement: .primaryAction) {
                LocalModelStatusIndicator(models: workspace.attention.localModels,
                    onOpenTranscription: { workspace.settingsTab = 5; workspace.selection = .settings },
                    onOpenVoice: { workspace.assistantSettingsArea = .voice; workspace.settingsTab = 6; workspace.selection = .settings })
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let meeting = embeddedMeeting {
                NativeDesktopMeetingsButton(workspace: workspace, current: meeting)
                Button { meeting.panel = meeting.panel == .participants ? nil : .participants } label: { Label(L("Participants"), systemImage: "person.2") }
                    .help(L("Participants"))
                Button { meeting.panel = meeting.panel == .conversation ? nil : .conversation } label: { Label(L("Conversation"), systemImage: "bubble.left") }
                    .help(L("Conversation"))
                Button { meeting.panel = meeting.panel == .notes ? nil : .notes } label: { Label(L("Notes"), systemImage: "note.text") }
                    .help(L("Notes"))
                    .accessibilityIdentifier("meeting.notes")
                Button { workspace.showMini(meeting) } label: { Label(L("Mini meeting"), systemImage: "pip.enter") }
                    .help(L("Mini meeting"))
                Button { workspace.toggleWindow(meeting) } label: { Label(L("Open in New Window"), systemImage: "macwindow.on.rectangle") }
                    .help(L("Open in New Window"))
            } else if workspace.selectedMeeting == nil {
                Button { addingFavorite = true } label: { Label(L("Add favorite"), systemImage: "plus") }
                    .help(L("Save a meeting invitation"))
            }
        }
    }
    private func meetingSubtitle(_ model: NativeDesktopMeetingModel) -> String {
        guard model.connected else { return L(model.snapshot.phase.rawValue.capitalized) }
        // The toolbar's transcription pill carries the status.
        return L("%ld participants", model.participants.count)
    }
    /// One window alert: an error first, else a notice such as an ended meeting.
    private var alertTitle: String {
        if workspace.error != nil { return L("Could not complete the action") }
        return workspace.notice?.title ?? ""
    }
    private var alertMessage: String { workspace.error ?? workspace.notice?.message ?? "" }
    private var alertShown: Binding<Bool> {
        Binding(get: { workspace.error != nil || workspace.notice != nil }, set: { if !$0 { dismissAlert() } })
    }
    private func dismissAlert() {
        if workspace.error != nil { workspace.error = nil }
        if workspace.notice != nil { workspace.notice = nil }
    }
    private func detachedMeeting(_ model: NativeDesktopMeetingModel) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "macwindow.on.rectangle").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(L("This meeting is open in its own window.")).font(.title3)
            HStack(spacing: 12) {
                Button(L("Show Window")) { workspace.showMeeting(model) }.buttonStyle(.borderedProminent)
                Button(L("Move to Main Window")) { workspace.toggleWindow(model) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
    }
    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !homeSnapshot.items.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(homeSnapshot.items.prefix(2)) { item in
                            HStack(spacing: 16) {
                                Image(systemName: item.handoff == nil ? "calendar" : "laptopcomputer.and.iphone").font(.title2).foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.calendar?.title ?? item.handoff?.title ?? L("Meeting")).font(.headline).lineLimit(1)
                                    Text(item.handoff.map { L("Meeting on %@", $0.deviceLabel) } ?? item.calendar.map { CalendarMeetingPresentation.subtitle($0, at: library.calendar.now, roomTitle: $0.title) } ?? "").foregroundStyle(.secondary)
                                    Text(roomDetail(item.invitation, engine: item.id.engine)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if let handoff = item.handoff {
                                    Button(L("Join here")) { library.continuation.joinHere(handoff) }
                                    let current = item.currentHandoff(in: library.continuation.candidates, at: Date())
                                    Button(L("Move here")) {
                                        guard let current = item.currentHandoff(in: library.continuation.candidates, at: Date()) else { return }
                                        library.continuation.begin(current)
                                    }.buttonStyle(.borderedProminent).disabled(current == nil)
                                     .help(current == nil ? L("This meeting is no longer available on the other device.") : L("Move here"))
                                } else if let calendar = item.calendar {
                                    Button(L("Join")) { library.open(calendar) }.buttonStyle(.borderedProminent)
                                }
                            }.padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }.onHover { hovering in hoveringHomeMeetings = hovering; if !hovering { refreshHome() } }
                }
                if let status = library.continuation.status {
                    HStack {
                        Text(status).font(.callout)
                        Spacer()
                        if library.continuation.needsManualResume { Button(L("Resume here")) { library.continuation.resumeHere() } }
                        if library.continuation.moving { Button(library.continuation.moveActionTitle) { library.continuation.cancel() } }
                    }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                }
                if homeSnapshot.hasUpdates {
                    Button(L("Show updated meetings")) { homeSnapshot.acceptUpdates() }.font(.callout)
                }
                joinForm
                if showsFirstLibraryGuidance { firstLibraryGuidance }
                if let warning = library.persistenceWarning {
                    HStack { Label(warning, systemImage: "exclamationmark.triangle"); Spacer(); Button(L("Retry")) { library.retryPersistence() } }.font(.callout).foregroundStyle(.orange)
                }
                if !todayMeetingsWithoutHighlights.isEmpty {
                    sectionTitle(L("Today"), action: { workspace.selection = .calendar })
                    ForEach(todayMeetingsWithoutHighlights.prefix(3)) { calendarRow($0) }
                } else if todayMeetings.isEmpty && library.calendar.enabled && library.calendar.access == .allowed && !library.calendar.loading &&
                            library.calendar.error == nil && !library.calendar.selected.isEmpty {
                    HStack {
                        Text(L("No meetings today.")).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Open calendar")) { workspace.selection = .calendar }
                    }.font(.callout)
                }
                if !library.favorites.isEmpty {
                    sectionTitle(L("Favorites"), action: { workspace.selection = .favorites })
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                        ForEach(library.favorites.prefix(8)) { room in roomCard(room) }
                    }
                }
                if !library.recent.isEmpty {
                    sectionTitle(L("Recent rooms"), action: { workspace.selection = .recent })
                    ForEach(library.recent.prefix(4)) { room in roomRow(room) }
                }
                Button(L("Open meeting history")) { workspace.openMeetingHistory() }.font(.callout)
            }.padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle(L("Home"))
    }
    private var todayMeetings: [CalendarMeeting] {
        NativeDesktopHomePresentation.today(library.calendarMeetings, now: library.calendar.now)
    }
    private var todayMeetingsWithoutHighlights: [CalendarMeeting] {
        let highlighted = Set(homeSnapshot.items.prefix(2).compactMap { $0.calendar?.id })
        return todayMeetings.filter { !highlighted.contains($0.id) }
    }
    private func refreshHome() {
        homeSnapshot.update(library.homeMeetings(), calendarMeetings: library.calendarMeetings, allowChanges: acceptsHomeChanges)
    }
    private var firstLibraryGuidance: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "rectangle.stack.badge.plus").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Your meeting library starts here")).font(.headline)
                Text(L("Paste an invitation above to join, or save a favorite to keep it close.")).foregroundStyle(.secondary)
                Text(L("Already have favorites on another device? Open iCloud settings to connect your library.")).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button(L("Add favorite")) { addingFavorite = true }
                    Button(L("Open iCloud settings")) { workspace.settingsTab = 0; workspace.selection = .settings }
                }
            }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(18).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 16))
    }
    private var joinForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Join a meeting")).font(.headline)
            HStack {
                TextField(L("Invitation link"), text: $workspace.invitation).textFieldStyle(.roundedBorder).onSubmit { workspace.joinInput() }.accessibilityIdentifier("nativeGuest.invitation")
                Button(L("Paste")) { workspace.invitation = NSPasteboard.general.string(forType: .string) ?? "" }
                Button(workspace.joinSettingUp ? L("Connecting…") : L("Join")) { workspace.joinInput() }
                    .buttonStyle(.borderedProminent).disabled(workspace.joinSettingUp || workspace.invitation.isEmpty)
            }
            HStack {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                TextField(L("Your name"), text: $library.displayName).focused($editingName).textFieldStyle(.plain).frame(maxWidth: 280).accessibilityIdentifier("nativeGuest.displayName")
                Spacer()
                Button { workspace.settingsTab = 3; workspace.selection = .settings } label: { Label(L("Camera & sound"), systemImage: "slider.horizontal.3") }
            }
            Label(L("Microphone and camera start off"), systemImage: "mic.slash").font(.caption).foregroundStyle(.secondary)
            if let destination = try? library.normalizedDestination(workspace.invitation) {
                AssistantLastOutcome(assistant: workspace.attention.store.assistant, invitation: destination.invitationURL, before: Date())
            }
        }.padding(18).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
    }
    private func sectionTitle(_ title: String, action: @escaping () -> Void) -> some View {
        HStack { Text(title).font(.title3.bold()); Spacer(); Button(L("See all"), action: action) }
    }
    private func roomCard(_ room: RecentRoom) -> some View {
        HStack {
            Button { library.open(room) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(room.displayTitle).font(.headline).lineLimit(1)
                    Text(library.calendar.subtitle(for: room) ?? room.lastVisit.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? L("Saved meeting")).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(height: 16)
                    Text(roomDetail(room.joinURL, engine: room.engine)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    AssistantLastOutcome(assistant: workspace.attention.store.assistant, invitation: room.invitationURL, before: Date())
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { library.toggleFavorite(room) } label: { Image(systemName: room.isStarred ? "star.fill" : "star") }.buttonStyle(.borderless).foregroundStyle(.orange)
        }.padding(14).frame(minHeight: 82).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14)).contextMenu { roomMenu(room) }
    }
    private func roomRow(_ room: RecentRoom) -> some View { roomCard(room) }
    private func roomList(_ rooms: [RecentRoom], title: String, search: Binding<String>, reorder: Bool = false) -> some View {
        let query = search.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = NativeDesktopHomePresentation.rooms(rooms, matching: query)
        return VStack(spacing: 0) {
            HStack {
                TextField(L("Search rooms"), text: search).textFieldStyle(.roundedBorder)
                if !query.isEmpty { Button(L("Clear")) { search.wrappedValue = "" } }
            }.padding()
            List {
                ForEach(matches) { room in
                    roomRow(room).listRowSeparator(.hidden)
                }.onMove { if reorder && query.isEmpty { library.moveFavorites(from: $0, to: $1) } }
            }.listStyle(.plain).overlay {
                if matches.isEmpty {
                    Text(rooms.isEmpty ? L("No saved rooms yet.") : L("No rooms match your search."))
                        .foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
            if library.history.removedRoom != nil { Button(L("Undo removal")) { library.undoDelete() }.padding() }
        }.navigationTitle(title)
    }
    private var agenda: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if !library.calendar.enabled {
                    Label(L("Choose calendars to find your meetings"), systemImage: "calendar")
                    Button(L("Choose calendars")) { workspace.openCalendarSettings() }
                } else if library.calendar.loading {
                    ProgressView(L("Loading calendars…"))
                } else if library.calendar.access == .denied {
                    Label(L("Calendar access is off in System Settings."), systemImage: "calendar.badge.exclamationmark")
                    Button(L("Review calendar access")) { workspace.openCalendarSettings() }
                } else if let error = library.calendar.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button(L("Try Again")) { library.calendar.refresh() }
                } else if library.calendar.selected.isEmpty {
                    Label(L("No calendars selected."), systemImage: "calendar")
                    Button(L("Choose calendars")) { workspace.openCalendarSettings() }
                } else if library.calendarMeetings.isEmpty {
                    Text(L("No meetings with supported invitation links")).foregroundStyle(.secondary).padding(.vertical, 32)
                }
                ForEach(library.calendarMeetings) { calendarRow($0) }
            }.padding(28)
        }.navigationTitle(L("Calendar"))
    }
    private func calendarRow(_ item: CalendarMeeting) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.headline).lineLimit(2)
                Text(CalendarMeetingPresentation.subtitle(item, at: library.calendar.now, roomTitle: item.title)).foregroundStyle(.secondary)
                Text(item.invitation.map { roomDetail($0, engine: item.engine) } ?? "").font(.caption).foregroundStyle(.secondary)
                AssistantLastOutcome(assistant: workspace.attention.store.assistant, invitation: item.invitation,
                    series: item.seriesID, before: item.start)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if let url = item.invitation {
                    if library.history.matching(url, engine: item.engine) != nil { library.history.toggleStar(url) }
                    else { library.history.saveFavorite(url: url, title: item.title, engine: item.engine) }
                }
            } label: {
                Image(systemName: item.invitation.flatMap { library.history.matching($0, engine: item.engine) }?.isStarred == true ? "star.fill" : "star")
            }.buttonStyle(.borderless).foregroundStyle(.orange)
            Button(L("Join")) { library.open(item) }.buttonStyle(.bordered)
        }.padding(16).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
            .contextMenu {
                Button(L("Choose another room")) { library.calendar.choosingMeeting = item }
                Button(L("Reminders…")) { library.calendar.reminders.editing = library.calendar.reminders.occurrence(for: item) }
            }
    }
    @ViewBuilder private func roomMenu(_ room: RecentRoom) -> some View {
        Button(L("Join")) { library.open(room) }
        Button(L("Rename")) { renamed = room.displayTitle; editRoom = room }
        Button(L("Copy invitation")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(room.joinURL.absoluteString, forType: .string) }
        Button(room.isStarred ? L("Remove favorite") : L("Add favorite")) { library.toggleFavorite(room) }
        Button(L("Attention instructions…")) {
            workspace.attention.editingPreset = .init(invitation: room.invitationURL, latest: room.latestInvitationURL, title: room.displayTitle)
        }
        Divider(); Button(L("Remove"), role: .destructive) { library.delete(room) }
    }
    private func roomDetail(_ url: URL, engine: MeetingEngineKind?) -> String {
        let identity = MeetingRoomIdentity(url, engine: engine)
        return [url.host, identity?.room].compactMap { $0 }.joined(separator: " · ")
    }
}

struct NativeDesktopSettingsView: View {
    @ObservedObject var library: NativeDesktopLibrary
    var meeting: NativeDesktopMeetingModel?
    @Binding var tab: Int
    var assistantArea: Binding<NativeDesktopAssistantSettingsArea> = .constant(.overview)
    var attention: AttentionCoordinator? = nil
    #if NATIVE_DIRECT_UPDATES
    var updates: NativeDesktopUpdates? = nil
    #endif
    /// The local MCP server, surfaced on its own settings tab.
    var mcpService: NativeDesktopMCPService? = nil
    /// Obsidian one-way export settings and status.
    var obsidian: ObsidianExportCoordinator? = nil
    @FocusState private var editingName: Bool
    @AppStorage(NativeDesktopGuestEngine.forceTCPRelayKey) private var forceTCPRelay = false
    @AppStorage(NativeDesktopMeetingModel.keepMicrophoneWarmKey) private var keepMicrophoneWarm = false
    @AppStorage(NativeDesktopHeadsetMute.Platform.enabledKey) private var headsetMute = false
    @AppStorage(NativeDesktopHeadsetMute.Platform.disabledReasonKey) private var headsetMuteDisabledReason = ""
    @State private var settingsQuery = ""
    private struct Destination: Identifiable {
        var id: Int
        var title: String
        var symbol: String
        var group: String
    }
    private var destinations: [Destination] {
        var sections: [Destination] = [
            .init(id: 0, title: "General", symbol: "person.crop.circle", group: "Meetings"),
            .init(id: 1, title: "Calendars", symbol: "calendar", group: "Meetings"),
            .init(id: 2, title: "Reminders", symbol: "bell", group: "Meetings"),
            .init(id: 3, title: "Camera & sound", symbol: "slider.horizontal.3", group: "Meetings"),
            .init(id: 5, title: "Transcription", symbol: "text.bubble", group: "Assistant")
        ]
        if attention != nil { sections.append(.init(id: 6, title: "Assistant", symbol: "sparkles", group: "Assistant")) }
        if mcpService != nil { sections.append(.init(id: 7, title: "MCP Server", symbol: "network", group: "Connections")) }
        if obsidian != nil { sections.append(.init(id: 8, title: "Integrations", symbol: "arrow.triangle.branch", group: "Connections")) }
        #if NATIVE_DIRECT_UPDATES
        if updates != nil { sections.append(.init(id: 4, title: "Updates", symbol: "arrow.down.circle", group: "Connections")) }
        #endif
        return sections
    }
    private var filteredDestinations: [Destination] {
        let query = settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return destinations.filter { query.isEmpty || L($0.title).localizedCaseInsensitiveContains(query) || L($0.group).localizedCaseInsensitiveContains(query) }
    }
    private var assistantSearchResults: [NativeDesktopAssistantSettingsArea] {
        attention == nil ? [] : NativeDesktopSettingsSearch.assistantAreas(matching: settingsQuery)
    }
    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < 600 {
                VStack(spacing: 0) {
                    HStack {
                        TextField(L("Find a settings section"), text: $settingsQuery)
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("settings.search")
                        Picker(L("Settings section"), selection: $tab) {
                            ForEach(destinations) { destination in Label(L(destination.title), systemImage: destination.symbol).tag(destination.id) }
                        }.labelsHidden()
                    }.padding()
                    if !settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        compactSettingsResults
                    }
                    Divider()
                    settingsContent
                }
            } else {
                HStack(spacing: 0) {
                    settingsSidebar.frame(width: 190)
                    Divider()
                    settingsContent
                }
            }
        }.navigationTitle(L("Settings"))
            .onChange(of: editingName) { if $0 { library.sync.beginNameEditing() } else { library.sync.endNameEditing() } }
            .onDisappear { if editingName { library.sync.endNameEditing() } }
    }
    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(L("Find a settings section"), text: $settingsQuery)
                .textFieldStyle(.roundedBorder).padding(12)
                .accessibilityIdentifier("settings.search")
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(["Meetings", "Assistant", "Connections"], id: \.self) { group in
                        let items = filteredDestinations.filter { $0.group == group }
                        if !items.isEmpty || (group == "Assistant" && !assistantSearchResults.isEmpty) {
                            Text(L(group)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 10)
                            ForEach(items) { item in
                                Button { tab = item.id } label: {
                                    Label(L(item.title), systemImage: item.symbol)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10).padding(.vertical, 7)
                                        .background(tab == item.id ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                }.buttonStyle(.plain).accessibilityValue(tab == item.id ? L("Selected") : "")
                            }
                            if group == "Assistant" {
                                ForEach(assistantSearchResults) { area in
                                    Button {
                                        assistantArea.wrappedValue = area
                                        tab = 6
                                    } label: {
                                        Label(area.title, systemImage: "chevron.right")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.leading, 20).padding(.trailing, 8).padding(.vertical, 7)
                                            .background(tab == 6 && assistantArea.wrappedValue == area ? Color.accentColor.opacity(0.15) : Color.clear,
                                                        in: RoundedRectangle(cornerRadius: 7))
                                    }.buttonStyle(.plain).accessibilityIdentifier("settings.assistant.\(area.rawValue)")
                                }
                            }
                        }
                    }
                    if filteredDestinations.isEmpty && assistantSearchResults.isEmpty {
                        Text(L("No settings sections match your search.")).foregroundStyle(.secondary).font(.callout).padding(10)
                    }
                }.padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    private var compactSettingsResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(filteredDestinations) { item in
                    Button { tab = item.id; settingsQuery = "" } label: {
                        Label(L(item.title), systemImage: item.symbol).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).padding(.vertical, 4)
                }
                ForEach(assistantSearchResults) { area in
                    Button { assistantArea.wrappedValue = area; tab = 6; settingsQuery = "" } label: {
                        Label(L("Assistant") + " › " + area.title, systemImage: "sparkles")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).padding(.vertical, 4)
                     .accessibilityIdentifier("settings.assistant.\(area.rawValue)")
                }
                if filteredDestinations.isEmpty && assistantSearchResults.isEmpty {
                    Text(L("No settings sections match your search.")).foregroundStyle(.secondary)
                }
            }.padding(.horizontal).padding(.bottom, 8)
        }.frame(maxHeight: 125)
    }
    @ViewBuilder private var settingsContent: some View {
        switch tab {
        case 0:
            Form {
                Section(L("Your name")) { TextField(L("Display name"), text: $library.displayName).focused($editingName) }
                Section(L("Guest meeting website")) {
                    TextField("https://salutejazz.ru", text: $library.guestWebsiteOrigin)
                    Text(L("Used for guest invitations that contain a room code without a website.")).font(.caption).foregroundStyle(.secondary)
                }
                RoomSyncSettingsView(sync: library.sync, continuation: library.continuation)
                Section(L("Meeting setup")) {
                    Button(L("Review meeting setup…")) { library.setup.begin() }
                    Text(L("Choose calendars, reminders, and device options at any time."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L("Guest meeting connection")) {
                    Toggle(L("Use TCP/TLS relay only"), isOn: $forceTCPRelay)
                    Text(L("Applies when you join your next guest meeting. Automatic mode can switch to a TCP/TLS relay if UDP fails."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L("Meetings")) {
                    Toggle(L("Keep the microphone ready in every meeting (experimental)"), isOn: $keepMicrophoneWarm)
                    Text(L("Moving your microphone between meetings skips restarting the device. Meetings you leave the microphone in stay muted, but macOS keeps showing the microphone indicator while you are in any meeting."))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L("Mute with AirPods and headset buttons"), isOn: Binding(get: { headsetMute }, set: { on in
                        headsetMute = on; if on { headsetMuteDisabledReason = "" }
                    }))
                    Text(L("Pressing the stem or the headset button mutes or unmutes your microphone in the meeting that holds it. On some macOS versions turning this on makes the system audio service stop responding when a meeting starts; the app then turns it off again. Applies to meetings joined after turning it on."))
                        .font(.caption).foregroundStyle(.secondary)
                    if !headsetMute && !headsetMuteDisabledReason.isEmpty {
                        Text(L("Turned off after the system audio service stopped responding: %@.", headsetMuteDisabledReason))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }.formStyle(.grouped)
        case 1:
            Form {
                Section {
                    Toggle(L("Find meetings in Calendar"), isOn: Binding(get: { library.calendar.enabled }, set: { library.calendar.setEnabled($0) }))
                    if library.calendar.access == .denied {
                        Text(L("Calendar access is off in System Settings.")).foregroundStyle(.secondary)
                        HStack {
                            Button(L("Open calendar privacy settings")) { openCalendarPrivacySettings() }
                            Button(L("Check Again")) { library.calendar.refresh() }
                        }
                        Text(L("System Settings → Privacy & Security → Calendars")).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(library.calendar.calendars) { calendar in
                        Toggle(isOn: Binding(get: { library.calendar.selected.contains(calendar.id) }, set: { library.calendar.select(calendar.id, included: $0) })) {
                            VStack(alignment: .leading) { Text(calendar.name); Text(calendar.source).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section(L("Automatic joining")) {
                    Toggle(L("Keep running in menu bar"), isOn: Binding(get: { library.calendar.keepInMenuBar }, set: { library.calendar.setKeepInMenuBar($0) }))
                        .disabled(library.calendar.automaticJoinMode == .scheduled)
                    Picker(L("Join scheduled meetings"), selection: Binding(get: { library.calendar.automaticJoinMode }, set: { library.calendar.setAutomaticJoinMode($0) })) {
                        Text(L("Off")).tag(CalendarAutomaticJoinMode.off)
                        Text(L("When opening the app")).tag(CalendarAutomaticJoinMode.whenOpening)
                        Text(L("At scheduled time")).tag(CalendarAutomaticJoinMode.scheduled)
                    }
                    Text(L("Microphone and camera always start off.")).font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        case 2:
            Form {
                Section {
                    Toggle(L("Meeting reminders"), isOn: Binding(get: { library.calendar.reminders.enabled }, set: { value in Task { await library.calendar.reminders.setEnabled(value) } }))
                    NativeDesktopReminderTimingEditor(timing: profileBinding(\.timing))
                    Toggle(L("Show meeting name"), isOn: profileBinding(\.details))
                    Toggle(L("Sound"), isOn: profileBinding(\.sound))
                    Toggle(L("Time Sensitive"), isOn: profileBinding(\.timeSensitive))
                    Button(L("Open notification settings")) { Task { _ = await NotificationSettingsLink.open(isMac: true) } }
                }
            }.formStyle(.grouped)
        case 3:
            NativeDesktopDeviceSettings(liveTrack: meeting?.localCamera, liveAudioAvailable: meeting != nil,
                startLiveAudioCheck: { try await meeting?.engine.startPrivateAudioCheck() },
                stopLiveAudioCheck: { try await meeting?.engine.stopPrivateAudioCheck() },
                liveAudioLevel: { meeting?.engine.privateAudioLevel })
        case 5:
            NativeDesktopTranscriptionSettings(store: .shared, models: attention?.localModels)
        case 6:
            if let attention {
                NativeDesktopIntelligenceSettings(store: attention.store, attention: attention, area: assistantArea)
            }
        case 7:
            if let mcpService {
                NativeDesktopMCPSettings(service: mcpService)
            }
        case 8:
            if let obsidian {
                ObsidianSettingsView(coordinator: obsidian)
            }
        #if NATIVE_DIRECT_UPDATES
        case 4:
            if let updates { NativeDesktopUpdatesView(updates: updates) }
        #endif
        default:
            Text(L("Choose a settings section.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func profileBinding<T>(_ path: WritableKeyPath<ReminderProfile, T>) -> Binding<T> {
        Binding(get: { library.calendar.reminders.profile[keyPath: path] }, set: { value in updateProfile { $0[keyPath: path] = value } })
    }
    private func openCalendarPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        if !NSWorkspace.shared.open(url) {
            _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
    private func updateProfile(_ edit: (inout ReminderProfile) -> Void) { var value = library.calendar.reminders.profile; edit(&value); library.calendar.reminders.setProfile(value) }
}

struct NativeDesktopSetupView: View {
    @ObservedObject var library: NativeDesktopLibrary
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(L("Meeting setup")).font(.title2.bold()); Spacer(); Button(L("Finish later")) { library.setup.finishLater() } }
            Text(L("Step %ld of %ld", library.setup.step.rawValue + 1, MeetingSetupCoordinator.Step.allCases.count))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("meetingSetup.progress")
            switch library.setup.step {
            case .calendar:
                Label(L("Your meetings, ready to join"), systemImage: "calendar").font(.title3)
                Text(L("Choose which calendars Rock'N'Roll for Mac may read. Only meetings with supported invitation links appear."))
                Toggle(L("Find meetings in Calendar"), isOn: Binding(get: { library.calendar.enabled }, set: { library.calendar.setEnabled($0) }))
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(library.calendar.calendars) { calendar in
                            Toggle(calendar.name + " · " + calendar.source, isOn: Binding(get: { library.calendar.selected.contains(calendar.id) }, set: { library.calendar.select(calendar.id, included: $0) }))
                        }
                    }
                }.frame(maxHeight: 150)
            case .reminders:
                Label(L("A reminder at the right time"), systemImage: "bell").font(.title3)
                Text(L("Choose reminder timing and privacy in Settings. Recommended reminders appear at the start, then after 30 seconds if you are in another meeting."))
                Toggle(L("Meeting reminders"), isOn: Binding(get: { library.calendar.reminders.enabled }, set: { enabled in Task { await library.calendar.reminders.setEnabled(enabled) } }))
            case .devices:
                Label(L("Continue between your devices"), systemImage: "laptopcomputer.and.iphone").font(.title3)
                Text(L("Use your iCloud account to sync favorites, their order, history and your display name."))
                Toggle(L("Sync with iCloud"), isOn: Binding(get: { library.sync.enabled }, set: { library.sync.setEnabled($0) }))
                Toggle(L("Offer meeting handoff"), isOn: Binding(get: { library.continuation.enabled }, set: { library.continuation.setEnabled($0) }))
                Text(library.sync.status).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Button(L("Back")) { library.setup.back() }.disabled(library.setup.step == .calendar)
                Spacer()
                if canSkipCurrentStep { Button(L("Not now")) { library.setup.next() } }
                Button(library.setup.step == .devices ? L("Done") : L("Continue")) { library.setup.next() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 500, height: 380).onAppear { library.setup.presentationDidMount() }
    }
    private var canSkipCurrentStep: Bool {
        switch library.setup.step {
        case .calendar: !library.calendar.enabled
        case .reminders: !library.calendar.reminders.enabled
        case .devices: !library.sync.enabled && !library.continuation.enabled
        }
    }
}

/// A live meeting in the sidebar: its role (talking, listening, silenced), who is
/// speaking, and the actions the menu bar offers, without leaving the window.
struct NativeDesktopSidebarMeetingRow: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    @ObservedObject var model: NativeDesktopMeetingModel
    private var speaking: Bool { model.participants.contains { !$0.isLocal && $0.speaking == true } }
    private var live: Bool { model.ownsMicrophone && model.snapshot.microphoneOn }
    /// A move between meetings, or a start, shows at once: the device and server steps take time.
    private var moving: Bool { model.microphoneStarting }
    private var subtitle: String {
        if model.voiceReplyActive { return L("Playing a voice reply…") }
        if moving { return workspace.meetings.count > 1 ? L("Moving microphone…") : L("Starting microphone…") }
        return model.connected ? NativeDesktopWorkspace.statusText(model) + " · " + L("%ld participants", model.participants.count)
            : L(model.snapshot.phase.rawValue.capitalized)
    }
    private var micSymbol: String { moving ? "xmark" : live ? "mic.fill" : model.ownsMicrophone ? "mic.slash" : "mic" }
    private var micLabel: String { moving ? L("Cancel") : live ? L("Mute") : model.ownsMicrophone ? L("Unmute") : L("Talk here") }
    private var micHelp: String {
        if moving { return L("Starting microphone. Click to cancel.") }
        if model.ownsMicrophone { return L("Mute or unmute") }
        if let talk = workspace.talkMeeting, talk !== model { return L("Moves your microphone from “%@” and unmutes it here.", talk.title) }
        return L("Talk here")
    }
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if moving { ProgressView().controlSize(.small) }
                else {
                    Image(systemName: NativeDesktopWorkspace.statusSymbol(model))
                        .foregroundStyle(live ? Color.red : model.snapshot.playoutOn ? Color.accentColor : Color.secondary)
                }
            }.frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(model.title).lineLimit(1)
                    if model.transcriptionIndicator == .on {
                        Image(systemName: "text.bubble.fill").font(.caption2).foregroundStyle(.orange)
                            .help(L("Transcribing")).accessibilityLabel(L("Transcribing"))
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(moving ? Color.orange : live ? Color.red : Color.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            AttentionBadge(attention: workspace.attention, meetingID: model.sessionID)
            AttentionModeChipGate(attention: workspace.attention, model: model)
            if speaking { Image(systemName: "waveform").font(.caption).foregroundStyle(.secondary).help(L("Someone is speaking")) }
            if workspace.isDetached(model) {
                Image(systemName: "macwindow").font(.caption).foregroundStyle(.secondary).help(L("This meeting is open in its own window."))
            }
            Button { model.toggleMicrophone() } label: { Image(systemName: micSymbol).frame(width: 20, height: 20) }
                .buttonStyle(.borderless).foregroundStyle(live ? Color.red : Color.secondary)
                .help(micHelp).accessibilityLabel(micLabel)
            Button { model.togglePlayout() } label: { Image(systemName: model.soundSymbol).frame(width: 20, height: 20) }
                .buttonStyle(.borderless).foregroundStyle(model.snapshot.playoutOn ? Color.secondary : Color.orange)
                .help(model.snapshot.playoutOn ? L("Silence") : L("Sound on"))
                .accessibilityLabel(model.snapshot.playoutOn ? L("Silence") : L("Sound on"))
        }.padding(.vertical, 2)
        .contextMenu {
            Button(L("Show meeting")) { workspace.showMeeting(model) }
            if model.ownsMicrophone { Button(model.snapshot.microphoneOn ? L("Mute") : L("Unmute")) { model.toggleMicrophone() } }
            else { Button(L("Unmute here")) { model.toggleMicrophone() } }
            Button(model.snapshot.playoutOn ? L("Silence") : L("Sound on")) { model.togglePlayout() }
            Divider()
            Button(workspace.isDetached(model) ? L("Move to Main Window") : L("Open in New Window")) { workspace.toggleWindow(model) }
            Button(L("Mini meeting")) { workspace.showMini(model) }
            Divider()
            Button(L("Attention instructions…")) { workspace.attention.editInstructions(for: model) }
            let current = workspace.attention.resolvedMode(model).mode
            Picker(L("Attention"), selection: Binding(get: { current }, set: { workspace.attention.setMode($0, for: model) })) {
                ForEach(AttentionMode.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            Button(L("Copy Invitation Link")) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.invitation.absoluteString, forType: .string)
            }
            Divider()
            Button(L("Leave")) { Task { _ = await workspace.leave(model) } }
        }
    }
}
