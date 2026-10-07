import ConferenceCore
import SwiftUI

struct JoinView: View {
    @ObservedObject var model: ConferenceModel
    @ObservedObject var catchUp: CatchUpStore
    @ObservedObject var history: RoomHistoryStore
    @ObservedObject var sync: RoomSyncCoordinator
    @ObservedObject var continuation: MeetingContinuationCoordinator
    @ObservedObject var calendar: CalendarMeetingStore
    @State private var showingSavedHistory = false
    @FocusState private var nameFocused: Bool
    @FocusState private var linkFocused: Bool
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var showingAllFavorites = false
    @State private var showingAgenda = false
    @State private var showingDevices = false
    @State private var agendaSettings = false
    @State private var homeSnapshot = HomeMeetingSnapshot()
    @State private var homeNow = Date()
    @State private var homeAtTop = true
    @State private var foreground = true
    @State private var showingSettings = false
    @State private var showingAllRooms = false
    @StateObject private var mediaCheck = StudioModel(audioControl: .fullProcessing, preferences: .standard)
    @StateObject private var favoriteDrag = FavoriteDragState()
    @State private var editingRoom: RecentRoom?
    @State private var roomAlias = ""
    @State private var showingUndo = false
    @State private var undoToken = UUID()
    @State private var staleContinuation: ActiveJam?
    @State private var confirmingStaleContinuation = false
    private let accent = Color(red: 1, green: 0.60, blue: 0.33)
    private let linkAccent = Color(uiColor: .init { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1) :
            UIColor(red: 0.49, green: 0.21, blue: 0.06, alpha: 1)
    })

    private var favorites: [RecentRoom] { history.rooms.filter(\.isStarred) }
    private var recent: [RecentRoom] { history.rooms.filter { !$0.isStarred } }

    var body: some View {
        GeometryReader { window in
          NavigationStack {
            HStack(spacing: 0) {
                let wide = window.size.width >= 820 && !textSize.isAccessibilitySize
                if wide {
                    Form { library(wide: true) }
                        .frame(width: min(320, window.size.width * 0.32))
                        .scrollContentBackground(.hidden)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .accessibilityIdentifier("home.library")
                }
                Form {
                    urgentSection
                    Section {
                        joinPanel(width: window.size.width - (wide ? min(320, window.size.width * 0.32) : 0))
                            .background(homeSnapshot.items.isEmpty ? topMarker : nil)
                    }
                    if !wide { library(wide: false) }
                    CalendarAgendaView(calendar: calendar, history: history, continuation: continuation,
                        busy: busy, onJoin: model.joinCalendarMeeting, onSettings: { showingSettings = true },
                        home: true, excluded: Set(homeSnapshot.items.compactMap { $0.calendar?.id }),
                        onShowAll: { showingAgenda = true })
                    secondarySections
                }
                .coordinateSpace(name: "home.main")
                .onPreferenceChange(HomeTopPreference.self) { position in
                    if let position {
                        let atTop = position > -12
                        if atTop != homeAtTop { homeAtTop = atTop; if atTop { refreshHome() } }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .systemGroupedBackground))
                .accessibilityIdentifier("home.main")
            }
            .navigationTitle(ProcessInfo.processInfo.isiOSAppOnMac ? L("Home") : "Rock’n’Roll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(L("Settings"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if showingUndo {
                    Button(L("Room removed · Undo")) {
                        history.undoRemoval()
                        showingUndo = false
                    }
                    .padding(12)
                    .background(.regularMaterial, in: Capsule())
                }
            }
            .sheet(isPresented: $showingSavedHistory) {
                SavedCatchUpView(store: catchUp)
            }
            .sheet(isPresented: $showingSettings) { settingsSheet }
            .sheet(isPresented: $showingAgenda) { agendaSheet }
            .sheet(isPresented: $showingDevices, onDismiss: {
                if staleContinuation != nil { confirmingStaleContinuation = true }
            }) { devicesSheet }
            .sheet(isPresented: Binding(get: { mediaCheck.presented }, set: { if !$0 { mediaCheck.close() } })) {
                StudioPanel(model: mediaCheck)
            }
            .onChange(of: model.isJoining) {
                if $0 { nameFocused = false; linkFocused = false; sync.endNameEditing(); mediaCheck.close() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { _ in
                nameFocused = false
                linkFocused = false
                sync.endNameEditing()
            }
            .onChange(of: nameFocused) { focused in
                if focused { calendar.cancelAutomaticJoin(suppress: true) }
                if focused { sync.beginNameEditing() } else { sync.endNameEditing() }
            }
            .onChange(of: linkFocused) { if $0 { calendar.cancelAutomaticJoin(suppress: true) } }
            .onChange(of: homeInteracting) { if !$0 { refreshHome() } }
            .onChange(of: showingAgenda) { if $0 { calendar.cancelAutomaticJoin(suppress: true) } }
            .onChange(of: showingDevices) { if $0 { calendar.cancelAutomaticJoin(suppress: true) } }
            .onChange(of: confirmingStaleContinuation) { if !$0 { staleContinuation = nil } }
            .onReceive(calendar.$meetings) { refreshHome(meetings: $0) }
            .onReceive(calendar.$now) { _ in refreshHome() }
            .onReceive(continuation.$candidates) { refreshHome(handoffs: $0) }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
                foreground = true; refreshHome()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { _ in foreground = false }
            .task(id: shouldTick) {
                guard shouldTick else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    refreshHome()
                }
            }
            .onChange(of: model.invite) { _ in calendar.cancelAutomaticJoin(suppress: true) }
            .onChange(of: showingSettings) { if $0 { calendar.cancelAutomaticJoin(suppress: true) } }
            .onChange(of: mediaCheck.presented) { if $0 { calendar.cancelAutomaticJoin(suppress: true) } }
            .onChange(of: model.isNameRequiredForJoin) { required in
                if required { nameFocused = true }
            }
            .onAppear { refreshHome(); if model.isNameRequiredForJoin { nameFocused = true } }
            .onDisappear { favoriteDrag.cancel(); sync.endNameEditing() }
            .alert(L("Join here without moving the other device?"),
                                isPresented: $confirmingStaleContinuation,
                                presenting: staleContinuation) { jam in
                Button(L("Join with mic and camera off")) { model.joinFromContinuation(jam, quiet: false) }
                Button(L("Cancel"), role: .cancel) {}
            } message: { _ in
                Text(L("The other device may still play meeting audio. Disconnect it or use headphones to avoid echo."))
            }
            .sheet(item: $model.siteSelection) { selection in
                MeetingWebsiteSelectionView(
                    rememberedOrigins: selection.rememberedOrigins,
                    onChoose: { model.chooseWebsite($0) ? nil : model.status },
                    onCancel: { model.siteSelection = nil }
                )
            }
            .sheet(item: Binding(get: { showingAgenda ? nil : calendar.choosingMeeting },
                                set: { calendar.choosingMeeting = $0 })) { meeting in
                CalendarRoomBindingView(meeting: meeting, calendar: calendar, history: history)
            }
            .confirmationDialog(L("Choose meeting engine"),
                isPresented: Binding(get: { model.engineSelection != nil },
                                     set: { if !$0 { model.dismissEngineSelection() } }),
                titleVisibility: .visible) {
                Button(L("Guest meeting")) { model.chooseEngine(community: false) }
                Button(L("Community jam")) { model.chooseEngine(community: true) }
                Button(L("Cancel"), role: .cancel) { model.dismissEngineSelection() }
            } message: {
                Text(L("This website supports two meeting engines. Choose how to join."))
            }
            .sheet(item: $editingRoom) { room in
                NavigationStack {
                    Form {
                        Section {
                            TextField(L("New jam name"), text: $roomAlias)
                                .textInputAutocapitalization(.words)
                        } footer: {
                            Text(L("Current: %@. Only you see this name.", room.displayTitle))
                        }
                    }
                    .navigationTitle(L("Name this jam"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L("Cancel")) { editingRoom = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L("Save")) {
                                model.setAlias(roomAlias, for: room)
                                editingRoom = nil
                            }
                            .disabled(roomAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .confirmationDialog(
                L("Leave the current jam and open the new invitation?"),
                isPresented: $model.showSwitchConfirmation
            ) {
                Button(L("Leave current jam")) { model.replaceWithPending() }
                Button(L("Stay here"), role: .cancel) { model.dismissPending() }
            }
          }
        }
        .tint(linkAccent)
    }

    private var busy: Bool { model.isJoining || model.isInConference || model.isLeaving || continuation.moving }
    private var homeInteracting: Bool {
        nameFocused || linkFocused || favoriteDrag.session != nil || showingSettings || showingAgenda ||
            showingDevices || editingRoom != nil || mediaCheck.presented || confirmingStaleContinuation ||
            calendar.choosingMeeting != nil || model.siteSelection != nil || model.engineSelection != nil ||
            model.showSwitchConfirmation || busy
    }
    private var shouldTick: Bool { foreground && !model.isInConference && (calendar.enabled || !continuation.candidates.isEmpty) }
    private func refreshHome(meetings: [CalendarMeeting]? = nil, handoffs: [ActiveJam]? = nil) {
        homeNow = Date()
        homeSnapshot.update(HomeMeetingPolicy.candidates(meetings: meetings ?? calendar.upcoming,
                            handoffs: handoffs ?? continuation.candidates, at: homeNow),
                            allowChanges: homeAtTop && !homeInteracting)
    }
    private var topMarker: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: HomeTopPreference.self, value: geometry.frame(in: .named("home.main")).minY)
        }
    }
    @ViewBuilder private var urgentSection: some View {
        if let meeting = calendar.joiningMeeting, let seconds = calendar.countdown {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(meeting.title).font(.headline)
                    Text(L("Joining in %ld seconds with mic and camera off", seconds)).font(.subheadline)
                    HStack {
                        Button(L("Join now")) { model.joinCalendarMeeting(meeting) }
                        Spacer()
                        Button(L("Cancel")) { calendar.cancelAutomaticJoin(suppress: true) }
                    }.buttonStyle(.borderless)
                }.background(topMarker)
            }
        } else if !homeSnapshot.items.isEmpty {
            Section {
                ForEach(homeSnapshot.items) { item in
                    HomeMeetingCard(item: item, now: homeNow, calendar: calendar, history: history,
                        continuation: continuation, busy: busy, onJoin: model.joinCalendarMeeting,
                        onStale: { staleContinuation = $0; confirmingStaleContinuation = true })
                        .background(item.id == homeSnapshot.items.first?.id ? topMarker : nil)
                }
            }
        }
    }
    private func joinPanel(width: CGFloat) -> some View {
        let stacked = width < 360 || textSize.isAccessibilitySize
        // Changing field contents must not replace the focused TextField.
        // AnyLayout preserves child identity when window/text size changes.
        let row = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) :
                            AnyLayout(HStackLayout(spacing: 8))
        return VStack(alignment: .leading, spacing: 4) {
            row {
                invitationEntry.frame(maxWidth: .infinity)
                joinButton.frame(maxWidth: stacked ? .infinity : nil).fixedSize(horizontal: !stacked, vertical: true)
            }
            row {
                nameEntry.frame(minWidth: 90, maxWidth: .infinity)
                studioButton.fixedSize(horizontal: true, vertical: true)
            }
            if (model.isNameRequiredForJoin || !model.displayName.isEmpty) && !validDisplayName {
                Text(L("Enter a name of up to %ld characters before joining.", model.namePolicy.maximumNameScalars))
                    .font(.footnote).foregroundStyle(.red)
            }
            Label(L("Microphone and camera start off"), systemImage: "mic.slash")
                .font(.caption).foregroundStyle(.secondary)
            if model.status != L("Enter a jam link to begin.") {
                Text(model.status).font(.footnote).foregroundStyle(model.statusIsError ? .red : .secondary)
            }
            if let media = model.mediaStatus { Text(media).font(.footnote).foregroundStyle(.red) }
            if model.isJoining || model.isInConference {
                Button(L("Leave jam"), role: .destructive) { model.leave() }.frame(minHeight: 44)
            }
        }.padding(.vertical, 2)
    }
    private var invitationEntry: some View {
        HStack(spacing: 4) {
            TextField(L("Invitation link"), text: $model.invite)
                .accessibilityIdentifier("invitation.input")
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.URL).textContentType(.URL).focused($linkFocused)
                .submitLabel(.go).onSubmit { join() }.frame(minWidth: 100, minHeight: 44)
            Button(L("Paste")) { if let link = UIPasteboard.general.string { model.invite = link } }
                .buttonStyle(.borderless).font(.subheadline.weight(.semibold)).fixedSize().frame(minWidth: 44, minHeight: 44)
        }
    }
    private var nameEntry: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(L("Your name"), text: $model.displayName)
                .accessibilityIdentifier("name.input").accessibilityLabel(L("Your name"))
                .textContentType(.nickname).autocorrectionDisabled().focused($nameFocused)
                .submitLabel(.go).onSubmit { join() }.font(.subheadline).frame(minHeight: 44)
        }
    }
    private var studioButton: some View {
        Button {
            mediaCheck.applyProfile = { _ in }; mediaCheck.open(.camera)
        } label: {
            Label(L("Camera & sound"), systemImage: "slider.horizontal.3")
                .labelStyle(.titleAndIcon).font(.subheadline).frame(minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(L("Check camera & sound")).accessibilityIdentifier("studio.prejoin").disabled(busy)
    }
    private var joinButton: some View {
        Button { join() } label: {
            HStack(spacing: 5) {
                if model.isJoining { ProgressView() }
                Text(model.isJoining ? L("Joining…") : L("Join")).font(.subheadline.weight(.semibold))
                    .foregroundStyle(canJoin ? Color.black : Color.primary)
            }.frame(minHeight: 36)
        }.buttonStyle(.borderedProminent).tint(accent).disabled(!canJoin)
        .accessibilityLabel(model.isJoining ? L("Joining…") : L("Join jam")).accessibilityIdentifier("join.start")
        #if DEBUG
        .accessibilityValue(model.testSwitchSequenceCompleted ? "Switch sequence connected" : "")
        #endif
    }
    @ViewBuilder private func library(wide: Bool) -> some View {
        if !favorites.isEmpty { favoriteSection(wide: wide) }
        if !recent.isEmpty {
            roomSection(L("Recent jams"), rooms: showingAllRooms ? recent : Array(recent.prefix(2)))
            if recent.count > 2 {
                Button(showingAllRooms ? L("Show fewer") : L("See all %ld recent jams", recent.count)) { showingAllRooms.toggle() }
            }
        }
    }
    @ViewBuilder private var secondarySections: some View {
        if !continuation.candidates.isEmpty || continuation.status != nil {
            Section {
                if let status = continuation.status { Text(status).font(.footnote).foregroundStyle(.secondary) }
                Button(L("Other devices")) { showingDevices = true }.accessibilityIdentifier("home.devices")
                if continuation.moving { Button(continuation.moveActionTitle) { continuation.cancel() } }
            }
        }
        if let warning = catchUp.persistenceWarning, catchUp.timeline.intervals.isEmpty {
            Section { Text(warning).font(.footnote).foregroundStyle(.orange)
                Button(L("Delete local history")) { catchUp.finishMeeting() } }
        }
        if let warning = history.persistenceWarning {
            Section { Text(warning).font(.footnote).foregroundStyle(.orange)
                Button(L("Retry saving rooms")) { history.retrySave() } }
        }
        if sync.offerSync && !busy {
            Section(L("Keep your jams across devices")) {
                Text(L("Sync your name, favorites and recent jams through your private iCloud account.")).font(.subheadline)
                Button(L("Enable iCloud Sync")) { sync.dismissOffer(); sync.setEnabled(true); showingSettings = true }
                Button(L("Not now")) { sync.dismissOffer() }.foregroundStyle(.secondary)
            }
        }
        if !catchUp.timeline.intervals.isEmpty && !model.isInConference {
            Section(L("Catch up")) { Button(L("Review missed section")) { showingSavedHistory = true } }
        }
        Section {
            Button(L("Join a practice room")) {
                model.receive(url: URL(string: "https://rock.glowsoft.ru/jams/test")!); model.join()
            }
        } footer: { Text(L("Practice with a shared music group. Other visitors can join; your microphone and camera start off.")) }
    }
    private var agendaSheet: some View {
        NavigationStack {
            Form {
                CalendarAgendaView(calendar: calendar, history: history, continuation: continuation,
                    busy: busy, onJoin: { showingAgenda = false; model.joinCalendarMeeting($0) },
                    onSettings: { agendaSettings = true })
            }
            .navigationTitle(L("Upcoming meetings")).navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $agendaSettings) { CalendarSettingsView(calendar: calendar) }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { showingAgenda = false } } }
            .sheet(item: $calendar.choosingMeeting) { CalendarRoomBindingView(meeting: $0, calendar: calendar, history: history) }
        }
    }
    private var devicesSheet: some View {
        NavigationStack {
            Form {
                MeetingContinuationView(continuation: continuation, busy: busy, onJoinHere: {
                    staleContinuation = $0; showingDevices = false
                })
            }
            .navigationTitle(L("Other devices")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { showingDevices = false } } }
        }
    }
    private var validDisplayName: Bool {
        model.validDisplayName
    }

    private var canJoin: Bool {
        !model.invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !busy
    }

    private func join() {
        nameFocused = false
        linkFocused = false
        sync.endNameEditing()
        model.join()
        if model.isNameRequiredForJoin { nameFocused = true }
    }

    private func favoriteSection(wide: Bool) -> some View {
        Section {
            let rooms = favoriteDrag.displayedRooms(favorites)
            ForEach(wide || showingAllFavorites ? rooms : Array(rooms.prefix(3))) { room in
                FavoriteRoomRow(room: room, subtitle: roomSubtitle(room), tint: UIColor(linkAccent),
                    history: history, drag: favoriteDrag,
                    onJoin: { model.rejoin(room) }, onRename: { startRename(room) },
                    onStar: { model.toggleStar(room) }, onOriginalName: { model.setAlias(nil, for: room) })
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 8))
                .swipeActions {
                    Button(L("Remove"), role: .destructive) { removeRoom(room) }
                    Button(L("Rename")) { startRename(room) }
                }
            }
        } header: {
            HStack {
                Text(L("Favorites")); Spacer()
                if !wide && favorites.count > 3 {
                    Button(showingAllFavorites ? L("Show fewer") : L("Show all")) { showingAllFavorites.toggle() }
                        .textCase(nil).accessibilityIdentifier("favorites.expand")
                }
            }
        }
    }

    private func roomSection(_ title: String, rooms: [RecentRoom]) -> some View {
        Section {
            ForEach(rooms) { room in
                HStack(spacing: 10) {
                    Button { model.rejoin(room) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(room.displayTitle).font(.body.weight(.semibold))
                            Text(roomSubtitle(room))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Rejoin %@ on %@", room.displayTitle, room.invitationURL.host() ?? L("meeting website")))
                    .contextMenu {
                        Button { startRename(room) } label: {
                            Label(L("Rename"), systemImage: "pencil")
                        }
                        Button {
                            UIPasteboard.general.url = room.joinURL
                        } label: {
                            Label(L("Copy invitation"), systemImage: "doc.on.doc")
                        }
                        if room.alias != nil {
                            Button { model.setAlias(nil, for: room) } label: {
                                Label(L("Use original name"), systemImage: "arrow.uturn.backward")
                            }
                        }
                    }
                    Button { model.toggleStar(room) } label: {
                        Image(systemName: room.isStarred ? "star.fill" : "star")
                            .frame(width: 44, height: 44)
                            .foregroundStyle(room.isStarred ? linkAccent : .secondary)
                    }
                    .accessibilityLabel(room.isStarred ? L("Unstar %@", room.displayTitle) : L("Star %@", room.displayTitle))
                }
                .swipeActions {
                    Button(L("Remove"), role: .destructive) {
                        removeRoom(room)
                    }
                    Button(L("Rename")) { startRename(room) }
                }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
            }
        }
    }

    private func removeRoom(_ room: RecentRoom) {
        model.remove(room); showingUndo = true
        let token = UUID(); undoToken = token
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if undoToken == token { showingUndo = false }
        }
    }

    private func startRename(_ room: RecentRoom) {
        roomAlias = room.alias ?? ""
        editingRoom = room
    }

    private func roomSubtitle(_ room: RecentRoom) -> String {
        if let metadata = calendar.subtitle(for: room) { return metadata }
        let visit = room.lastVisit?.formatted(.relative(presentation: .named)) ?? L("Saved · Not joined yet")
        return "\(room.identifier) · \(room.joinURL.host() ?? L("Meeting")) · \(visit)"
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { CalendarSettingsView(calendar: calendar) } label: {
                        Label(L("Calendars"), systemImage: "calendar")
                    }.accessibilityIdentifier("calendar.settings")
                }
                Section(L("Compatible meeting website")) {
                    TextField(L("HTTPS website address"), text: $model.guestWebsiteOrigin)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text(L("Fallback for app links that omit their website. Links with an embedded host open directly."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                RoomSyncSettingsView(sync: sync, continuation: continuation)
                Section(L("About")) {
                    Text(L("Small music groups in Yerevan can plan sessions and share ideas live."))
                    Link(L("Community"), destination: URL(string: "https://rock.glowsoft.ru/community")!)
                    Link(L("Privacy policy"), destination: URL(string: "https://rock.glowsoft.ru/privacy")!)
                    Link(L("Support"), destination: URL(string: "https://rock.glowsoft.ru/support")!)
                    Link(L("Third-party notices"), destination: URL(string: "https://rock.glowsoft.ru/notices")!)
                }
            }
            .navigationTitle(L("Settings"))
            .toolbar { Button(L("Done")) { showingSettings = false } }
        }
    }
}

struct MeetingWebsiteSelectionView: View {
    let rememberedOrigins: [URL]
    let onChoose: (String) -> String?
    let onCancel: () -> Void
    @State private var website = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L("This app link does not identify its meeting website. Choose one you trust to open the invitation."))
                        .font(.footnote)
                    ForEach(rememberedOrigins, id: \.absoluteString) { origin in
                        Button(origin.host() ?? origin.absoluteString) {
                            error = onChoose(origin.absoluteString)
                        }
                    }
                } header: {
                    Text(L("Previously used websites"))
                }
                Section(L("Another website")) {
                    TextField("https://meeting.example.org", text: $website)
                        .accessibilityIdentifier("meeting.website-input")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button(L("Open invitation")) { error = onChoose(website) }
                        .disabled(website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(L("Meeting website"))
            .toolbar { Button(L("Cancel"), action: onCancel) }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SavedCatchUpView: View {
    @ObservedObject var store: CatchUpStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CatchUpCardsView(store: store)
            .navigationTitle(L("Catch up"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Button(L("Delete local history"), role: .destructive) {
                        store.finishMeeting()
                        dismiss()
                    }
                }
                .padding()
                .background(.regularMaterial)
            }
        }
    }
}
