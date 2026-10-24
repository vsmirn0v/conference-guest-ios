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
    @State private var acceptsHomeChanges = true
    @State private var bindingLink = ""
    @State private var bindingSeries = true
    @FocusState private var editingName: Bool
    private var blocksScheduledJoining: Bool {
        editingName || addingFavorite || editRoom != nil || library.calendar.choosingMeeting != nil ||
        library.calendar.reminders.editing != nil || library.setup.isPresented
    }
    private var showsFirstLibraryGuidance: Bool {
        library.history.rooms.isEmpty && library.calendar.meetings.isEmpty &&
        library.continuation.candidates.isEmpty && homeSnapshot.items.isEmpty &&
        workspace.meeting == nil && !workspace.preparing && workspace.error == nil &&
        library.persistenceWarning == nil && library.continuation.status == nil &&
        !library.continuation.moving && !library.calendar.loading &&
        !library.sync.enabled && !library.sync.busy && !library.sync.needsFreshAccount &&
        library.sync.nameChoice == nil
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $workspace.selection) {
                Section {
                    ForEach(NativeDesktopWorkspace.Section.allCases) { item in
                        Label(L(item.rawValue), systemImage: item.symbol).tag(item)
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
                if workspace.meeting != nil {
                    Section {
                        Button { workspace.showMeeting() } label: { Label(L("Show meeting"), systemImage: "video.fill") }
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
            Group {
                switch workspace.selection {
                case .settings: NativeDesktopSettingsView(library: library, meeting: workspace.meeting, tab: $workspace.settingsTab)
                case .favorites: roomList(library.favorites, title: L("Favorites"), reorder: true)
                case .recent: roomList(library.recent, title: L("Recent meetings"))
                case .calendar: agenda
                case .home: home
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(.orange)
        .onAppear { refreshHome(); acceptsHomeChanges = false; library.calendar.setScheduledUIBlocked(blocksScheduledJoining) }
        .onChange(of: blocksScheduledJoining) { library.calendar.setScheduledUIBlocked($0) }
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { addingFavorite = true } label: { Label(L("Add favorite"), systemImage: "plus") }
                    .help(L("Save a meeting invitation"))
            }
        }
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
        .alert(L("Could not complete the action"), isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button(L("OK")) { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
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
                                    Button(L("Move here")) { library.continuation.begin(handoff) }.buttonStyle(.borderedProminent)
                                } else if let calendar = item.calendar {
                                    Button(L("Join")) { library.open(calendar) }.buttonStyle(.borderedProminent)
                                }
                            }.padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
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
        homeSnapshot.update(library.homeMeetings, calendarMeetings: library.calendarMeetings, allowChanges: acceptsHomeChanges)
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
                Button(workspace.preparing ? L("Connecting…") : L("Join")) { workspace.joinInput() }
                    .buttonStyle(.borderedProminent).disabled(workspace.preparing || workspace.invitation.isEmpty)
            }
            HStack {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                TextField(L("Your name"), text: $library.displayName).focused($editingName).textFieldStyle(.plain).frame(maxWidth: 280).accessibilityIdentifier("nativeGuest.displayName")
                Spacer()
                Button { workspace.settingsTab = 3; workspace.selection = .settings } label: { Label(L("Camera & sound"), systemImage: "slider.horizontal.3") }
            }
            Label(L("Microphone and camera start off"), systemImage: "mic.slash").font(.caption).foregroundStyle(.secondary)
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
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { library.toggleFavorite(room) } label: { Image(systemName: room.isStarred ? "star.fill" : "star") }.buttonStyle(.borderless).foregroundStyle(.orange)
        }.padding(14).frame(height: 82).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14)).contextMenu { roomMenu(room) }
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
    @FocusState private var editingName: Bool
    var body: some View {
        TabView(selection: $tab) {
            Form {
                Section(L("Your name")) { TextField(L("Display name"), text: $library.displayName).focused($editingName) }
                Section(L("Guest meeting website")) {
                    TextField("https://salutejazz.ru", text: $library.guestWebsiteOrigin)
                    Text(L("Used for guest invitations that contain a room code without a website.")).font(.caption).foregroundStyle(.secondary)
                }
                RoomSyncSettingsView(sync: library.sync, continuation: library.continuation)
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
                Text(L("Choose which calendars Rock’n’Roll may read. Only meetings with supported invitation links appear."))
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
