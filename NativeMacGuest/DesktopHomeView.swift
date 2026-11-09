import AppKit
import ConferenceCore
import SwiftUI

struct NativeDesktopHomeView: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    @ObservedObject var library: NativeDesktopLibrary
    @State private var search = ""
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
        NativeDesktopSettingsView(library: library, meeting: workspace.meeting, tab: $workspace.settingsTab, attention: workspace.attention, updates: workspace.updates)
        #else
        NativeDesktopSettingsView(library: library, meeting: workspace.meeting, tab: $workspace.settingsTab, attention: workspace.attention)
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
                            Label(L(item.rawValue), systemImage: item.symbol)
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
                        case .favorites: roomList(library.favorites, title: L("Favorites"), reorder: true)
                        case .recent: roomList(library.recent, title: L("Recent meetings"))
                        case .calendar: agenda
                        case .assistant: AttentionMomentsView(attention: workspace.attention, store: workspace.attention.store)
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
            .overlay(alignment: .bottomTrailing) {
                if let preview = workspace.previewMeeting {
                    NativeDesktopMiniMeeting(model: preview, onRestore: { workspace.showMeeting(preview) })
                        .frame(width: 400, height: 250).clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.3), radius: 16, y: 6).padding(20)
                        .accessibilityElement(children: .contain).accessibilityLabel(L("Meeting preview"))
                }
            }
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
            NativeDesktopStandaloneToolbarItem {
                NativeDesktopTranscriptionPill(model: meeting, compact: true, announcesInline: detailWidth >= Self.inlineAnnouncementWidth)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let meeting = embeddedMeeting {
                NativeDesktopMeetingsButton(workspace: workspace, current: meeting)
                Button { meeting.panel = meeting.panel == .participants ? nil : .participants } label: { Label(L("Participants"), systemImage: "person.2") }
                    .help(L("Participants"))
                Button { meeting.panel = meeting.panel == .conversation ? nil : .conversation } label: { Label(L("Conversation"), systemImage: "bubble.left") }
                    .help(L("Conversation"))
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
                if !library.favorites.isEmpty {
                    sectionTitle(L("Favorites"), action: { workspace.selection = .favorites })
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                        ForEach(library.favorites.prefix(8)) { room in roomCard(room) }
                    }
                }
                if !library.recent.isEmpty {
                    sectionTitle(L("Recent meetings"), action: { workspace.selection = .recent })
                    ForEach(library.recent.prefix(4)) { room in roomRow(room) }
                }
                if !library.calendarMeetings.isEmpty {
                    sectionTitle(L("Today"), action: { workspace.selection = .calendar })
                    ForEach(library.calendarMeetings.filter { Calendar.current.isDateInToday($0.start) }.prefix(3)) { calendarRow($0) }
                }
            }.padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle(L("Home"))
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
    private func roomList(_ rooms: [RecentRoom], title: String, reorder: Bool = false) -> some View {
        VStack(spacing: 0) {
            TextField(L("Search meetings"), text: $search).textFieldStyle(.roundedBorder).padding()
            List {
                ForEach(rooms.filter { search.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(search) || $0.joinURL.host?.localizedCaseInsensitiveContains(search) == true }) { room in
                    roomRow(room).listRowSeparator(.hidden)
                }.onMove { if reorder && search.isEmpty { library.moveFavorites(from: $0, to: $1) } }
            }.listStyle(.plain)
            if library.history.removedRoom != nil { Button(L("Undo removal")) { library.undoDelete() }.padding() }
        }.navigationTitle(title)
    }
    private var agenda: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if !library.calendar.enabled {
                    Label(L("Choose calendars to find your meetings"), systemImage: "calendar")
                    Button(L("Choose calendars")) { workspace.selection = .settings }
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
    var attention: AttentionCoordinator? = nil
    #if NATIVE_DIRECT_UPDATES
    var updates: NativeDesktopUpdates? = nil
    #endif
    @FocusState private var editingName: Bool
    @AppStorage("nativeDesktop.multipleMeetings") private var multipleMeetings = true
    @AppStorage(NativeDesktopMeetingModel.keepMicrophoneWarmKey) private var keepMicrophoneWarm = false
    @AppStorage(GuestSystemAudio.voiceRepliesKey) private var voiceReplies = false
    @AppStorage(SharedAudioEngine.flagKey) private var sharedAudioEngine = false
    @AppStorage(NativeDesktopHeadsetMute.Platform.enabledKey) private var headsetMute = false
    @AppStorage(NativeDesktopHeadsetMute.Platform.disabledReasonKey) private var headsetMuteDisabledReason = ""
    var body: some View {
        TabView(selection: $tab) {
            Form {
                Section(L("Your name")) { TextField(L("Display name"), text: $library.displayName).focused($editingName) }
                Section(L("Guest meeting website")) {
                    TextField("https://salutejazz.ru", text: $library.guestWebsiteOrigin)
                    Text(L("Used for guest invitations that contain a room code without a website.")).font(.caption).foregroundStyle(.secondary)
                }
                RoomSyncSettingsView(sync: library.sync, continuation: library.continuation)
                Section(L("Meetings")) {
                    Toggle(L("Allow multiple meetings"), isOn: $multipleMeetings)
                    Text(L("Stay connected to several meetings. Your microphone and camera work in one meeting at a time; the others keep playing unless you silence them."))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L("Keep the microphone ready in every meeting (experimental)"), isOn: $keepMicrophoneWarm)
                    Text(L("Moving your microphone between meetings skips restarting the device. Meetings you leave the microphone in stay muted, but macOS keeps showing the microphone indicator while you are in any meeting."))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L("Voice replies (experimental)"), isOn: $voiceReplies)
                    Text(L("Lets the app play a spoken reply into a meeting while your own microphone is held back. Applies to meetings joined after turning it on. Try it from a meeting's More menu."))
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
                    Toggle(L("One audio engine for all meetings (experimental)"), isOn: $sharedAudioEngine)
                    Text(L("Guest meetings share one microphone and speaker setup: moving your microphone needs no device restart and echo cancellation covers every meeting. Takes effect after you quit and reopen the app."))
                        .font(.caption).foregroundStyle(.secondary)
                    if sharedAudioEngine != SharedAudioEngine.enabledAtLaunch {
                        Text(L("Quit and reopen the app to apply.")).font(.caption).foregroundStyle(.orange)
                    }
                }
            }.tabItem { Label(L("General"), systemImage: "person.crop.circle") }.tag(0)
            Form {
                Section {
                    Toggle(L("Find meetings in Calendar"), isOn: Binding(get: { library.calendar.enabled }, set: { library.calendar.setEnabled($0) }))
                    if library.calendar.access == .denied { Text(L("Calendar access is off in System Settings.")).foregroundStyle(.secondary) }
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
            }.tabItem { Label(L("Calendars"), systemImage: "calendar") }.tag(1)
            Form {
                Section {
                    Toggle(L("Meeting reminders"), isOn: Binding(get: { library.calendar.reminders.enabled }, set: { value in Task { await library.calendar.reminders.setEnabled(value) } }))
                    NativeDesktopReminderTimingEditor(timing: profileBinding(\.timing))
                    Toggle(L("Show meeting name"), isOn: profileBinding(\.details))
                    Toggle(L("Sound"), isOn: profileBinding(\.sound))
                    Toggle(L("Time Sensitive"), isOn: profileBinding(\.timeSensitive))
                    Button(L("Open notification settings")) { Task { _ = await NotificationSettingsLink.open(isMac: true) } }
                }
            }.tabItem { Label(L("Reminders"), systemImage: "bell") }.tag(2)
            NativeDesktopDeviceSettings(liveTrack: meeting?.localCamera, liveAudioAvailable: meeting != nil,
                startLiveAudioCheck: { try await meeting?.engine.startPrivateAudioCheck() },
                stopLiveAudioCheck: { try await meeting?.engine.stopPrivateAudioCheck() },
                liveAudioLevel: { meeting?.engine.privateAudioLevel }).tabItem { Label(L("Camera & sound"), systemImage: "slider.horizontal.3") }.tag(3)
            NativeDesktopTranscriptionSettings(store: .shared).tabItem { Label(L("Transcription"), systemImage: "text.bubble") }.tag(5)
            if let attention {
                NativeDesktopIntelligenceSettings(store: attention.store, attention: attention)
                    .tabItem { Label(L("Assistant"), systemImage: "sparkles") }.tag(6)
            }
            #if NATIVE_DIRECT_UPDATES
            if let updates { NativeDesktopUpdatesView(updates: updates).tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag(4) }
            #endif
        }.padding(20).formStyle(.grouped).navigationTitle(L("Settings"))
            .onChange(of: editingName) { if $0 { library.sync.beginNameEditing() } else { library.sync.endNameEditing() } }
            .onDisappear { if editingName { library.sync.endNameEditing() } }
    }
    private func profileBinding<T>(_ path: WritableKeyPath<ReminderProfile, T>) -> Binding<T> {
        Binding(get: { library.calendar.reminders.profile[keyPath: path] }, set: { value in updateProfile { $0[keyPath: path] = value } })
    }
    private func updateProfile(_ edit: (inout ReminderProfile) -> Void) { var value = library.calendar.reminders.profile; edit(&value); library.calendar.reminders.setProfile(value) }
}

struct NativeDesktopSetupView: View {
    @ObservedObject var library: NativeDesktopLibrary
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(L("Meeting setup")).font(.title2.bold()); Spacer(); Button(L("Finish later")) { library.setup.finishLater() } }
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
                Spacer(); Button(library.setup.step == .devices ? L("Done") : L("Continue")) { library.setup.next() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 500, height: 380).onAppear { library.setup.presentationDidMount() }
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
