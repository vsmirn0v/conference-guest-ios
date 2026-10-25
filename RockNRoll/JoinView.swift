import ConferenceCore
import SwiftUI

struct JoinView: View {
    @ObservedObject var model: ConferenceModel
    @ObservedObject var catchUp: CatchUpStore
    @ObservedObject var history: RoomHistoryStore
    @ObservedObject var sync: RoomSyncCoordinator
    @ObservedObject var continuation: MeetingContinuationCoordinator
    @ObservedObject var calendar: CalendarMeetingStore
    @ObservedObject var setup: MeetingSetupCoordinator
    @StateObject private var nativeMacRecommendation = NativeMacRecommendation.current()
    @Environment(\.openURL) private var openURL
    @State private var setupAfterSettings: Int?
    @State private var showingSavedHistory = false
    @FocusState private var nameFocused: Bool
    @FocusState private var linkFocused: Bool
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var showingAllFavorites = false
    @State private var showingAgenda = false
    @State private var showingDevices = false
    @State private var agendaSettings = false
    @State private var homeSnapshot = HomeMeetingSnapshot()
    @State private var homeVisible = false
    @StateObject private var homeInteraction = HomeInteractionState()
    @State private var homeNow = Date()
    @State private var homeLayoutNow = Date()
    @State private var foreground = true
    @State private var showingSettings = false
    @AppStorage(SystemCallCoordinator.controlsPreferenceKey) private var systemCallControls = false
    @AppStorage(MeetingActivityCoordinator.enabledKey) private var meetingActivityEnabled = true
    @AppStorage(MeetingActivityCoordinator.titleKey) private var meetingActivityShowTitle = true
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
                            .homeAnchor("join")
                            .background(HomeScrollReference(state: homeInteraction))
                    }
                    if showsNativeMacRecommendation {
                        Section {
                            NativeMacRecommendationCard(recommendation: nativeMacRecommendation, getApp: openNativeMacDownload)
                                .homeAnchor("native-mac-recommendation")
                        }
                    }
                    if !wide { library(wide: false) }
                    CalendarAgendaView(calendar: calendar, history: history, continuation: continuation,
                        busy: busy, onJoin: model.joinCalendarMeeting, onSettings: { showingSettings = true },
                        home: true, excluded: Set(homeSnapshot.items.compactMap { $0.calendar?.id }),
                        onShowAll: { showingAgenda = true }, homeMeetings: homeSnapshot.calendarItems, homeNow: homeLayoutNow,
                        homeState: homeSnapshot.calendarState)
                    secondarySections
                }
                .coordinateSpace(name: "home.main")
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .systemGroupedBackground))
                .accessibilityIdentifier("home.main")
                .onPreferenceChange(HomeRowFrames.self) { homeInteraction.layoutChanged($0) }
            }
            .background(HomeInteractionProbe(state: homeInteraction))
            .navigationTitle(ProcessInfo.processInfo.isiOSAppOnMac ? L("Home") : "Rock’n’Roll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(L("Settings"))
                }
            }
            .safeAreaInset(edge: .bottom) {
              VStack(spacing: 4) {
                automaticJoinBanner
                if showingUndo {
                    Button(L("Room removed · Undo")) {
                        history.undoRemoval()
                        showingUndo = false
                    }
                    .padding(12)
                    .background(ControlChromeBackground(cornerRadius: 24))
                }
              }
            }
            .sheet(isPresented: $showingSavedHistory) {
                SavedCatchUpView(store: catchUp)
            }
            .sheet(isPresented: $showingSettings, onDismiss: {
                if let generation = setupAfterSettings {
                    setupAfterSettings = nil
                    if generation == setup.intentGeneration, !busy, !model.isNameRequiredForJoin,
                       model.siteSelection == nil, model.engineSelection == nil, !calendar.reminders.hasOpenIntent { setup.begin() }
                }
            }) { settingsSheet }
            .sheet(isPresented: Binding(get: { setup.isPresented }, set: { if !$0 { setup.finishLater() } }), onDismiss: {
                setup.presentationDidDismiss()
            }) {
                MeetingSetupView(setup: setup, calendar: calendar, reminders: calendar.reminders, sync: sync, continuation: continuation)
                    .onAppear { setup.presentationDidMount() }
            }
            .modifier(CalendarReminderSheet(reminders: calendar.reminders, isActive: { !showingAgenda }))
            .sheet(isPresented: $showingAgenda) { agendaSheet }
            .sheet(isPresented: $showingDevices, onDismiss: {
                if staleContinuation != nil { confirmingStaleContinuation = true }
            }) { devicesSheet }
            .sheet(isPresented: Binding(get: { mediaCheck.presented }, set: { if !$0 { mediaCheck.close() } })) {
                StudioPanel(model: mediaCheck)
            }
            .onChange(of: busy) { nativeMacRecommendation.observeMeetingActivity($0) }
            .onChange(of: model.isJoining) {
                if $0 { setup.suspendForMeeting(); nameFocused = false; linkFocused = false; sync.endNameEditing(); mediaCheck.close() }
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
            .onChange(of: homeInteracting) { if !$0 { refreshHome(); offerSetup() } }
            .onChange(of: setup.launchReady) { _ in offerSetup() }
            .onChange(of: showingAgenda) { if $0 { calendar.cancelAutomaticJoin(suppress: true) } }
            .onChange(of: showingDevices) { if $0 { calendar.cancelAutomaticJoin(suppress: true) } }
            .onChange(of: blocksScheduledJoining) { calendar.setScheduledUIBlocked($0) }
            .onChange(of: confirmingStaleContinuation) { if !$0 { staleContinuation = nil } }
            .onReceive(calendar.$meetings) { refreshHome(meetings: $0) }
            .onReceive(calendar.$now) { _ in refreshHome() }
            .onChange(of: calendar.access) { _ in refreshHome() }
            .onChange(of: calendar.enabled) { _ in refreshHome() }
            .onChange(of: calendar.selected) { _ in refreshHome() }
            .onChange(of: calendar.loading) { _ in refreshHome() }
            .onChange(of: calendar.error) { _ in refreshHome() }
            .onReceive(continuation.$candidates) { refreshHome(handoffs: $0) }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
                foreground = true; homeInteraction.resume(); refreshHome()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { _ in
                foreground = false; homeInteraction.cancel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in refreshHome() }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refreshHome() }
            .task(id: shouldTick) {
                guard shouldTick else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    refreshHome()
                }
            }
            .onChange(of: model.invite) { _ in calendar.cancelAutomaticJoin(suppress: true) }
            .onChange(of: showingSettings) { if $0 { calendar.cancelAutomaticJoin(suppress: true) } }
            .sheet(isPresented: $calendar.showingMacSettings) {
                NavigationStack {
                    CalendarSettingsView(calendar: calendar)
                        .toolbar { ToolbarItem(placement: .confirmationAction) {
                            Button(L("Done")) { calendar.showingMacSettings = false }
                        } }
                }
            }
            .onChange(of: mediaCheck.presented) { if $0 { calendar.cancelAutomaticJoin(suppress: true) } }
            .onChange(of: model.isNameRequiredForJoin) { required in
                if required { nameFocused = true }
            }
            .onAppear {
                nativeMacRecommendation.observeMeetingActivity(busy)
                calendar.setScheduledUIBlocked(blocksScheduledJoining)
                homeInteraction.resume(); homeVisible = false; refreshHome(); homeVisible = true
                offerSetup()
                calendar.reminders.isEventVisible = { id in
                    guard homeVisible, foreground, !setup.isPresented, !showingSettings, !showingAgenda, !showingDevices,
                          !mediaCheck.presented, !model.isInConference else { return false }
                    if homeInteraction.isAnchorVisible("calendar." + id) { return true }
                    guard let item = homeSnapshot.items.first(where: { $0.calendar?.id == id }) else { return false }
                    return homeInteraction.isAnchorVisible("urgent." + item.id.homeAnchorID)
                }
                if model.isNameRequiredForJoin { nameFocused = true }
            }
            .onDisappear {
                homeVisible = false; calendar.reminders.isEventVisible = { _ in false }
                homeInteraction.cancel(); favoriteDrag.cancel(); sync.endNameEditing()
            }
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

    private var blocksScheduledJoining: Bool {
        nameFocused || linkFocused || showingSettings || showingAgenda || showingDevices || mediaCheck.presented ||
            editingRoom != nil || calendar.choosingMeeting != nil || confirmingStaleContinuation || showingSavedHistory
    }
    private var showsNativeMacRecommendation: Bool { nativeMacRecommendation.showsNotice(isIdle: !busy) }
    private var busy: Bool { model.isJoining || model.isInConference || model.isLeaving || continuation.moving }
    private var homeInteracting: Bool {
        setup.isPresented || homeInteraction.active || nameFocused || linkFocused || favoriteDrag.session != nil || showingSettings || showingAgenda ||
            showingDevices || editingRoom != nil || mediaCheck.presented || confirmingStaleContinuation ||
            calendar.choosingMeeting != nil || model.siteSelection != nil || model.engineSelection != nil ||
            model.showSwitchConfirmation || busy
    }
    private var shouldTick: Bool { homeVisible && foreground && !model.isInConference && (calendar.enabled || !continuation.candidates.isEmpty) }
    private func refreshHome(meetings: [CalendarMeeting]? = nil, handoffs: [ActiveJam]? = nil) {
        homeNow = Date()
        let available = calendar.enabled && calendar.access == .allowed ?
            (meetings ?? calendar.upcoming).filter { calendar.selected.contains($0.calendarID) && $0.end > homeNow && $0.hasResolvedInvitation } : []
        let candidates = HomeMeetingPolicy.candidates(meetings: available,
                            handoffs: handoffs ?? continuation.candidates, at: homeNow)
        let allowChanges = !homeVisible || (!homeInteracting && foreground)
        var updated = homeSnapshot
        updated.update(candidates, calendarMeetings: available,
            calendarState: .init(enabled: calendar.enabled, available: calendar.access == .allowed && !calendar.selected.isEmpty,
                hasSelection: !calendar.selected.isEmpty, loading: calendar.loading, error: calendar.error), allowChanges: allowChanges)
        if allowChanges {
            let before = HomeMeetingPolicy.today(meetings: homeSnapshot.calendarItems, at: homeLayoutNow,
                excluding: Set(homeSnapshot.items.compactMap { $0.calendar?.id })).map(\.id)
            let after = HomeMeetingPolicy.today(meetings: updated.calendarItems, at: homeNow,
                excluding: Set(updated.items.compactMap { $0.calendar?.id })).map(\.id)
            if homeSnapshot.items.map(\.id) != updated.items.map(\.id) || before != after || homeSnapshot.calendarState != updated.calendarState {
                let surviving = Set(updated.items.map { "urgent." + $0.id.homeAnchorID })
                    .union(after.map { "calendar." + $0 }).union(favorites.map { "favorite." + $0.id })
                    .union(recent.map { "recent." + $0.id }).union(["join"])
                    .union(showsNativeMacRecommendation ? ["native-mac-recommendation"] : [])
                homeInteraction.preserveVisibleAnchor(surviving: surviving)
            }
            homeLayoutNow = homeNow
        }
        homeSnapshot = updated
    }
    @ViewBuilder private var urgentSection: some View {
        if !homeSnapshot.items.isEmpty {
            Section {
                ForEach(homeSnapshot.items) { item in
                    HomeMeetingCard(item: item, now: homeNow, calendar: calendar, history: history,
                        continuation: continuation, busy: busy, onJoin: model.joinCalendarMeeting,
                        onStale: { staleContinuation = $0; confirmingStaleContinuation = true })
                        .homeAnchor("urgent." + item.id.homeAnchorID)
                }
            }
        }
    }
    @ViewBuilder private var automaticJoinBanner: some View {
        if let meeting = calendar.joiningMeeting, let seconds = calendar.countdown {
            VStack(alignment: .leading, spacing: 6) {
                Text(meeting.title).font(.headline).lineLimit(2)
                Text(L("Joining in %ld seconds with mic and camera off", seconds)).font(.subheadline)
                HStack {
                    Button(L("Join now")) { model.joinCalendarMeeting(meeting) }
                    Spacer()
                    Button(L("Cancel")) { calendar.cancelAutomaticJoin(suppress: true) }
                }.buttonStyle(.borderless)
            }.padding(12).background(ControlChromeBackground())
                .accessibilityIdentifier("calendar.countdown-banner")
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
                studioButton.fixedSize(horizontal: !stacked, vertical: true)
                    .frame(maxWidth: stacked ? .infinity : nil, alignment: .leading)
            }
            if (model.isNameRequiredForJoin || !model.displayName.isEmpty) && !validDisplayName {
                Text(L("Enter a name of up to %ld characters before joining.", model.namePolicy.maximumNameScalars))
                    .font(.footnote).foregroundStyle(.red)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "mic.slash").accessibilityHidden(true)
                Text(L("Microphone and camera start off")).fixedSize(horizontal: false, vertical: true)
            }.font(.caption).foregroundStyle(.secondary)
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
        if sync.offerSync && !busy && !setup.isPresented {
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
            .modifier(CalendarReminderSheet(reminders: calendar.reminders, isActive: { showingAgenda }))
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
                FavoriteRoomRow(room: room, presentation: RoomRowPresentation(room: room, calendar: calendar), tint: UIColor(linkAccent),
                    history: history, drag: favoriteDrag,
                    onJoin: { model.rejoin(room) }, onRename: { startRename(room) },
                    onStar: { model.toggleStar(room) }, onOriginalName: { model.setAlias(nil, for: room) })
                .homeAnchor("favorite." + room.id)
                .background(HomeScrollReference(state: homeInteraction, main: false))
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 8))
                .swipeActions {
                    Button(L("Remove"), role: .destructive) { removeRoom(room) }
                    Button(L("Rename")) { startRename(room) }
                }
            }
        } header: {
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
            layout {
                Text(L("Favorites"))
                if !textSize.isAccessibilitySize { Spacer() }
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
                        RoomRowText(presentation: RoomRowPresentation(room: room, calendar: calendar))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Rejoin %@ on %@", room.displayTitle, room.invitationURL.host() ?? L("meeting website")))
                    .accessibilityValue(RoomRowPresentation(room: room, calendar: calendar).details)
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
                .homeAnchor("recent." + room.id)
                .background(HomeScrollReference(state: homeInteraction, main: false))
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

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        setupAfterSettings = setup.intentGeneration; showingSettings = false
                    } label: { Label(setup.completed ? L("Meeting setup") : L("Continue meeting setup"), systemImage: "checklist") }
                        .accessibilityIdentifier("settings.setup")
                }
                Section {
                    NavigationLink { CalendarSettingsView(calendar: calendar) } label: {
                        Label(L("Calendars"), systemImage: "calendar")
                    }.accessibilityIdentifier("calendar.settings")
                    NavigationLink {
                        Form {
                            Section {
                                Text(L("Names and saved invitations, including invitation passwords, stay in your private iCloud storage."))
                                    .font(.subheadline)
                            }
                            RoomSyncSettingsView(sync: sync, continuation: continuation)
                        }.navigationTitle(L("Across your devices"))
                    } label: { Label(L("Across your devices"), systemImage: "icloud") }
                        .accessibilityIdentifier("settings.devices")
                    if nativeMacRecommendation.isSupportedHost {
                        NavigationLink { NativeMacRecommendationDetails(getApp: openNativeMacDownload) } label: {
                            Label(L("Rock’n’Roll for Mac"), systemImage: "desktopcomputer")
                        }.accessibilityIdentifier("settings.nativeMacApp")
                    }
                    if !ProcessInfo.processInfo.isiOSAppOnMac {
                        NavigationLink { Form { phoneSettings }.navigationTitle(L("Phone calls")) } label: {
                            Label(L("Phone calls"), systemImage: "phone")
                        }.accessibilityIdentifier("settings.phone")
                    }
                    if NativeGuestCompanionEngine.isSupported {
                        NavigationLink { NativeGuestSettingsView() } label: {
                            Label(L("Native guest preview"), systemImage: "desktopcomputer")
                        }.accessibilityIdentifier("settings.nativeGuest")
                    }
                    NavigationLink { Form { websiteSettings }.navigationTitle(L("Meeting websites")) } label: {
                        Label(L("Meeting websites"), systemImage: "globe")
                    }.accessibilityIdentifier("settings.websites")
                    NavigationLink { Form { aboutSettings }.navigationTitle(L("About")) } label: {
                        Label(L("About"), systemImage: "info.circle")
                    }.accessibilityIdentifier("settings.about")
                }
            }
            .navigationTitle(L("Settings"))
            .toolbar { Button(L("Done")) { showingSettings = false } }
        }
    }
    private func openNativeMacDownload() {
        calendar.cancelAutomaticJoin(suppress: true)
        nativeMacRecommendation.visitDownloadPage { openURL($0) }
    }
    private func offerSetup() {
        setup.offerIfAppropriate(homeVisible && foreground && !homeInteracting && model.invite.isEmpty &&
            !calendar.reminders.hasOpenIntent && !calendar.reminders.presenting && !CalendarReminderBroker.shared.hasPendingIntent)
    }
    private var websiteSettings: some View {
        Section(L("Compatible meeting website")) {
            TextField(L("HTTPS website address"), text: $model.guestWebsiteOrigin)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            Text(L("Fallback for app links that omit their website. Links with an embedded host open directly."))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var phoneSettings: some View {
        Section {
            Toggle(L("System call controls"), isOn: $systemCallControls).accessibilityIdentifier("calls.systemControls")
        } header: { Text(L("Phone calls")) } footer: {
            Text(L("Audio and Picture in Picture keep working with this off. Some cellular networks block phone calls while system call controls are on. Changes apply to the next jam."))
        }
        if MeetingActivitySupport.supported {
            Section {
                Toggle(L("Meeting status outside the app"), isOn: $meetingActivityEnabled)
                    .accessibilityIdentifier("meeting.activity.enabled")
                if meetingActivityEnabled {
                    Toggle(L("Show meeting name"), isOn: $meetingActivityShowTitle)
                        .accessibilityIdentifier("meeting.activity.title")
                }
            } header: { Text(L("Meeting status")) } footer: {
                Text(L("Show microphone and connection status on the Lock Screen and Dynamic Island when System call controls are off."))
            }
        }
    }
    private var aboutSettings: some View {
        Section(L("About")) {
            Text(L("Small music groups in Yerevan can plan sessions and share ideas live."))
            Link(L("Community"), destination: URL(string: "https://rock.glowsoft.ru/community")!)
            Link(L("Privacy policy"), destination: URL(string: "https://rock.glowsoft.ru/privacy")!)
            Link(L("Support"), destination: URL(string: "https://rock.glowsoft.ru/support")!)
            Link(L("Third-party notices"), destination: URL(string: "https://rock.glowsoft.ru/notices")!)
        }
    }
}

private extension MeetingRoomIdentity {
    var homeAnchorID: String { [engine.rawValue, origin, room].joined(separator: "|") }
}

struct HomeRowFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func homeAnchor(_ id: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: HomeRowFrames.self, value: [id: geometry.frame(in: .global)])
        })
    }
}

/// Observe touch/scroll state without replacing Form's scroll delegate or
/// competing with buttons, context menus and native favorite drag gestures.
@MainActor
final class HomeInteractionState: NSObject, ObservableObject {
    @Published private(set) var active = false
    weak var scrollView: UIScrollView?
    private var touching = false
    private var acceptingEvents = true
    private var restoringAnchor = false
    private var settle: Task<Void, Never>?
    private var lastMovement = Date.distantPast
    private struct ScrollObservation {
        weak var scroll: UIScrollView?
        var clients: Int
        let token: NSKeyValueObservation
    }
    private var scrolls: [ObjectIdentifier: ScrollObservation] = [:]
    private var frames: [String: CGRect] = [:]
    private var anchor: (id: String, y: CGFloat)?

    func isAnchorVisible(_ id: String) -> Bool {
        guard let frame = frames[id], let scrollView, scrollView.window != nil else { return false }
        return frame.intersects(scrollView.convert(scrollView.bounds, to: nil))
    }

    func touch(_ touching: Bool, in view: UIView?) {
        guard acceptingEvents else { return }
        settle?.cancel(); settle = nil
        self.touching = touching
        if touching {
            if !active { active = true }
        } else { scrolled() }
    }
    func register(_ scroll: UIScrollView) {
        let id = ObjectIdentifier(scroll)
        if var existing = scrolls[id] { existing.clients += 1; scrolls[id] = existing; return }
        // Wheel/trackpad scrolls need not produce UITouch events. Observe the
        // actual Form as well as its existing pan; never replace its delegate.
        let token = scroll.observe(\.contentOffset, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue != change.newValue else { return }
            // Our own anchor correction is synchronous and must not restart
            // interaction protection after every structural refresh.
            guard self?.restoringAnchor != true else { return }
            DispatchQueue.main.async { [weak self] in self?.scrolled() }
        }
        scroll.panGestureRecognizer.addTarget(self, action: #selector(scrollPanChanged(_:)))
        scrolls[id] = .init(scroll: scroll, clients: 1, token: token)
    }
    func unregister(_ scroll: UIScrollView) {
        let id = ObjectIdentifier(scroll)
        guard var existing = scrolls[id] else { return }
        if existing.clients > 1 { existing.clients -= 1; scrolls[id] = existing; return }
        existing.token.invalidate()
        scroll.panGestureRecognizer.removeTarget(self, action: #selector(scrollPanChanged(_:)))
        scrolls.removeValue(forKey: id)
    }
    @objc private func scrollPanChanged(_ pan: UIPanGestureRecognizer) { scrolled() }
    private func scrolled() {
        guard acceptingEvents else { return }
        lastMovement = Date()
        if !active { active = true }
        guard !touching, settle == nil else { return }
        settle = Task { [weak self] in
            // One task exists only while input/scrolling settles. New offsets
            // extend its quiet period without allocating a task per frame.
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            while let self, !Task.isCancelled {
                let moving = scrolls.values.contains { entry in
                    guard let scroll = entry.scroll else { return false }
                    return scroll.isTracking || scroll.isDragging || scroll.isDecelerating ||
                        scroll.panGestureRecognizer.state == .began || scroll.panGestureRecognizer.state == .changed
                }
                if !touching, !moving, Date().timeIntervalSince(lastMovement) >= 0.18 { break }
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            }
            guard let self, !touching else { return }
            active = false; settle = nil
        }
    }
    func preserveVisibleAnchor(surviving: Set<String>) {
        guard anchor == nil, let scrollView, scrollView.contentOffset.y > -scrollView.adjustedContentInset.top + 2 else { return }
        let visible = scrollView.convert(scrollView.bounds.inset(by: scrollView.adjustedContentInset), to: nil)
        anchor = frames.filter { surviving.contains($0.key) && $0.value.intersects(visible) }
            .min { $0.value.minY < $1.value.minY }.map { ($0.key, $0.value.minY) }
    }
    func layoutChanged(_ frames: [String: CGRect]) {
        self.frames = frames
        guard let anchor else { return }
        self.anchor = nil
        guard !active, let scrollView, let frame = frames[anchor.id] else { return }
        let delta = frame.minY - anchor.y
        guard abs(delta) > 0.5 else { return }
        let minimum = -scrollView.adjustedContentInset.top
        let maximum = max(minimum, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        restoringAnchor = true
        defer { restoringAnchor = false }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x,
            y: min(maximum, max(minimum, scrollView.contentOffset.y + delta))), animated: false)
    }
    func resume() { acceptingEvents = true }
    func cancel() {
        acceptingEvents = false; settle?.cancel(); settle = nil; touching = false; active = false; anchor = nil
    }
}

private struct HomeScrollReference: UIViewRepresentable {
    let state: HomeInteractionState
    var main = true
    func makeUIView(context: Context) -> UIView { Reference(state: state, main: main) }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: ()) { (view as? Reference)?.disconnect() }
    private final class Reference: UIView {
        weak var state: HomeInteractionState?
        private weak var registered: UIScrollView?
        private let main: Bool
        init(state: HomeInteractionState, main: Bool) {
            self.state = state; self.main = main; super.init(frame: .zero); isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { disconnect(); return }
            var ancestor = superview
            while let current = ancestor, !(current is UIScrollView) { ancestor = current.superview }
            let scroll = ancestor as? UIScrollView
            guard scroll !== registered else { return }
            disconnect()
            if let scroll { state?.register(scroll); registered = scroll; if main { state?.scrollView = scroll } }
        }
        func disconnect() {
            if let registered { state?.unregister(registered) }
            registered = nil
        }
    }
}

/// Track touch identities rather than batches: lifting/cancelling one finger
/// must not release the protected layout while another finger remains down.
struct HomeTouchLifetime<Touch: Hashable> {
    private var touches: Set<Touch> = []
    var isActive: Bool { !touches.isEmpty }
    mutating func begin(_ incoming: Set<Touch>) -> Bool {
        let first = touches.isEmpty; touches.formUnion(incoming); return first
    }
    mutating func end(_ outgoing: Set<Touch>) -> Bool {
        touches.subtract(outgoing); return touches.isEmpty
    }
    mutating func reset() { touches.removeAll() }
}

private struct HomeInteractionProbe: UIViewRepresentable {
    let state: HomeInteractionState
    func makeUIView(context: Context) -> Probe { Probe(state: state) }
    func updateUIView(_ view: Probe, context: Context) {}
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.detach() }
    final class Probe: UIView, UIGestureRecognizerDelegate {
        weak var state: HomeInteractionState?
        private var observer: TouchObserver?
        init(state: HomeInteractionState) { self.state = state; super.init(frame: .zero); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow(); detach()
            guard let window else { return }
            let observer = TouchObserver(target: nil, action: nil)
            observer.cancelsTouchesInView = false; observer.delaysTouchesBegan = false; observer.delaysTouchesEnded = false
            observer.delegate = self
            observer.onTouch = { [weak state] touching, view in state?.touch(touching, in: view) }
            window.addGestureRecognizer(observer); self.observer = observer
        }
        func detach() { if let observer { observer.view?.removeGestureRecognizer(observer) }; observer = nil }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            window != nil && bounds.contains(touch.location(in: self))
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
    private final class TouchObserver: UIGestureRecognizer {
        var onTouch: ((Bool, UIView?) -> Void)?
        private var touches = HomeTouchLifetime<UITouch>()
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func touchesBegan(_ incoming: Set<UITouch>, with event: UIEvent) {
            let first = touches.begin(incoming)
            state = first ? .began : .changed
            if first { onTouch?(true, incoming.first?.view) }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { state = .changed }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, cancelled: false) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, cancelled: true) }
        private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
            if self.touches.end(touches) { state = cancelled ? .cancelled : .ended; onTouch?(false, nil) }
            else { state = .changed }
        }
        override func reset() {
            super.reset()
            if touches.isActive { touches.reset(); onTouch?(false, nil) }
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
