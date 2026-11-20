import AppKit
import Combine
import ConferenceCore
import SwiftUI
import UserNotifications

@MainActor final class NativeDesktopWorkspace: NSObject, ObservableObject, NSWindowDelegate {
    enum Section: String, CaseIterable, Identifiable {
        case home = "Home", workspace = "Live", history = "Meeting history", tasks = "Tasks", assistant = "Assistant", favorites = "Favorites", calendar = "Calendar", recent = "Recent meetings", settings = "Settings"
        var id: Self { self }
        var symbol: String {
            switch self { case .home: "house"; case .workspace: "dot.radiowaves.left.and.right"; case .history: "clock.arrow.circlepath"; case .assistant: "tray"; case .tasks: "checklist"; case .favorites: "star"; case .calendar: "calendar"; case .recent: "clock"; case .settings: "gearshape" }
        }
    }
    let library: NativeDesktopLibrary
    /// Judges the meetings you are not looking at and raises attention cards.
    let attention: AttentionCoordinator
    var mayAdmitMeeting: () -> Bool = { true }
    var meetingAdmissionError: () -> String? = { nil }
    var onUpdateActivityChanged: () -> Void = {}
    var busyForUpdate: Bool {
        preparing || !meetings.isEmpty || leaveTask != nil || !meetingLeaves.isEmpty || shutdownBlocked ||
        attention.isRecoveringOutcomes || !attention.outcomeStatus.isEmpty
    }
    #if NATIVE_DIRECT_UPDATES
    var updates: NativeDesktopUpdates?
    @Published private(set) var supportHomeVisit: UUID?
    var focusHomeAfterSupport = false
    var supportVisitIsSafe: Bool {
        !busyForUpdate && pendingScheduled == nil && selectedMeetingID == nil && selection == .home &&
        error == nil && notice == nil && !library.setup.isPresented && !library.continuation.moving &&
        library.persistenceWarning == nil && updates?.safety.installationReserved != true &&
        updates?.busy() != true && updates?.safety.recoveryTargetBuild == nil &&
        invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !(window?.firstResponder is NSTextView)
    }
    private func startSupportHomeVisit() {
        supportHomeVisit = nil
        guard supportVisitIsSafe else { return }
        SupportReminder.shared.recordForegroundUse()
        supportHomeVisit = UUID()
    }
    #endif
    /// The local MCP server that lets AI clients work with meetings; set once it starts.
    var mcpService: NativeDesktopMCPService?
    /// Obsidian one-way export coordinator, created with the meeting library.
    lazy var obsidian = ObsidianExportCoordinator(library: attention.store.meetingLibrary, archive: transcriptArchive)
    private lazy var transcriptArchive = TranscriptArchiveStore()
    /// CloudKit workspace, transcript, task, context-settings and calendar schedule sync coordinator.
    lazy var workspaceSync = MacWorkspaceSyncCoordinator(
        storageRoot: attention.store.root,
        meetingLibrary: attention.store.meetingLibrary,
        notes: attention.store.notes,
        assistant: attention.store.assistant,
        attentionStore: attention.store,
        journalProvider: { [weak self] _ in self?.attention.store.meetingLibrary.workspaceJournal },
        obsidianExportNow: { [weak self] in await self?.obsidian.exportPendingNow() },
        calendar: library.calendar,
        syncPreferences: library.sync,
        archiveStore: transcriptArchive
    )
    /// A library section is shown unless a meeting is selected in the sidebar.
    @Published var selection: Section = .home {
        didSet {
            if selectedMeetingID != nil { selectedMeetingID = nil }
            if selection == .assistant { fitMainWindowToScreen() }
            #if NATIVE_DIRECT_UPDATES
            if oldValue != selection {
                focusHomeAfterSupport = selection == .home && oldValue == .settings && settingsTab == SupportCopy.settingsTab
            }
            if selection != .home && supportHomeVisit != nil { supportHomeVisit = nil }
            #endif
        }
    }
    /// The meeting shown in the main window's detail column.
    @Published private(set) var selectedMeetingID: UUID? {
        didSet {
            if oldValue != selectedMeetingID { synchronizeMeetingPresentation() }
            #if NATIVE_DIRECT_UPDATES
            if selectedMeetingID != nil && supportHomeVisit != nil { supportHomeVisit = nil }
            #endif
        }
    }
    @Published var invitation = ""
    @Published var settingsTab = 0
    @Published var assistantSettingsArea: NativeDesktopAssistantSettingsArea = .overview
    @Published var error: String?
    /// An informational alert, such as a meeting the organizer ended.
    @Published var notice: (title: String, message: String)?
    /// A join is in flight (setting up or connecting), or every meeting is being left.
    @Published private(set) var preparing = false {
        didSet {
            onUpdateActivityChanged()
            #if NATIVE_DIRECT_UPDATES
            if preparing && supportHomeVisit != nil { supportHomeVisit = nil }
            #endif
        }
    }
    /// A join is detecting its service or asking about it; the next join waits for
    /// this short step only. Connecting does not hold up another join.
    @Published private(set) var joinSettingUp = false
    /// Simultaneous meetings in join order. One talk meeting holds mic and camera.
    @Published private(set) var meetings: [NativeDesktopMeetingModel] = [] { didSet { onUpdateActivityChanged() } }
    @Published private(set) var talkID: UUID?
    let workspaceViewState = MeetingWorkspaceViewState()
    var talkMeeting: NativeDesktopMeetingModel? { meetings.first { $0.sessionID == talkID } }
    /// The meeting single-meeting surfaces act on: the talk meeting, else the latest.
    var meeting: NativeDesktopMeetingModel? { talkMeeting ?? meetings.last }
    static let meetingLimit = 4
    private var window: NSWindow?
    private let mainHider = NativeDesktopWindowHider()
    private var meetingWindows: [UUID: NativeDesktopMeetingWindow] = [:]
    private var meetingSubscriptions: [UUID: AnyCancellable] = [:]
    private var renderedMeetingStates: [UUID: String] = [:]
    private var continuationSessions: [UUID: UUID] = [:]
    private var meetingLeaves: [UUID: Task<Bool, Never>] = [:] { didSet { onUpdateActivityChanged() } }
    private var handover: Task<Bool, Never>?
    /// In-flight joins and the meeting each created.
    private var joinTasks: [UUID: Task<Void, Never>] = [:] { didSet { refreshPreparing() } }
    private var joinModels: [UUID: ObjectIdentifier] = [:]
    private var leavingAll = false { didSet { refreshPreparing() } }
    /// A join asked for while another was setting up; it starts right after.
    private var queuedJoin: (@MainActor () -> Void)?
    private var scheduledJoinID: UUID?
    private var statusItem: NSStatusItem?
    private var statusIconLive: Bool?
    private var menuSubscriptionInstalled = false
    private var leaveTask: Task<Bool, Never>?
    /// Changes when every meeting is left; joins started before then stop.
    private var joinGeneration = UUID()
    private var subscriptions = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private var activity: NSUserActivity?
    private var handoffLookup: Task<Void, Never>?
    private var sessionID = UUID()
    private var shutdownBlocked = false
    private var scheduleTransitionTask: Task<Void, Never>?
    private var pendingSessionCreates: [UUID: Task<Void, Never>] = [:]
    private var sameRoomSwitchTasks: [UUID: Task<Void, Never>] = [:]
    static let sameRoomOverrunGrace: TimeInterval = 120
    private let reminderPresenter = NativeDesktopReminderPresenter()
    private var pendingScheduled: NativeDesktopScheduledJoin?
    private let detect: @MainActor (URL) async throws -> MeetingEngineDetection
    private let makeMeeting: @MainActor (JoinDestination, String, String?, Bool) -> NativeDesktopMeetingModel
    private let makeHandoffActivity: @MainActor (ActiveJam) -> NSUserActivity

    init(library: NativeDesktopLibrary? = nil,
         detect: @escaping @MainActor (URL) async throws -> MeetingEngineDetection = { try await VendorEndpointResolver.makeDetector().detect($0) },
         makeMeeting: (@MainActor (JoinDestination, String, String?, Bool) -> NativeDesktopMeetingModel)? = nil,
         makeHandoffActivity: @escaping @MainActor (ActiveJam) -> NSUserActivity = { NativeDesktopHandoff.activity(for: $0) },
         attention: AttentionCoordinator? = nil) {
        let library = library ?? NativeDesktopLibrary()
        self.attention = attention ?? AttentionCoordinator()
        // The agent's read-only calendar tools see future occurrences; they never join or edit.
        self.attention.calendarOccurrences = { [weak library] in
            (library?.calendar.meetings ?? []).filter { $0.start > Date() }
        }
        self.library = library; self.detect = detect; self.makeHandoffActivity = makeHandoffActivity
        self.makeMeeting = makeMeeting ?? { NativeDesktopMeetingModel(destination: $0, name: $1, title: $2, quiet: $3) }
        super.init()
        Task { [weak self] in
            guard let self else { return }
            await self.attention.store.waitForMeetingLibrary()
            self.obsidian.load()
            await self.attention.store.seedTaskProfileWithMeetingName(self.library.displayName)
        }
        library.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        library.onOpenMeeting = { [weak self] url, engine, title, event in self?.join(url, engine: engine, title: title, eventID: event) }
        library.onScheduledMeeting = { [weak self] request in
            guard let self, let url = request.meeting.invitation else { request.finish(); return }
            join(url, engine: request.meeting.engine, title: request.meeting.title,
                 eventID: request.meeting.id, scheduled: request)
        }
        library.onScheduledInvalidation = { [weak self] in
            guard let self, pendingScheduled != nil, let id = scheduledJoinID else { return }
            joinTasks[id]?.cancel()
        }
        library.canAutomaticallyJoin = { [weak self] in self?.meetings.isEmpty == true && self?.preparing == false && self?.mayAdmitMeeting() == true }
        library.continuation.onSnapshot = { [weak self] in self?.continuationSnapshot() }
        library.continuation.onJoinTarget = { [weak self] jam, quiet in
            guard let self, !preparing, meetings.isEmpty, mayAdmitMeeting() else { return nil }
            join(jam.invitation, engine: jam.engine, title: jam.title, quiet: quiet, nameOverride: jam.name, workspaceID: jam.workspaceSessionID)
            return sessionID
        }
        library.continuation.onPrepareSource = { [weak self] id in
            guard let self, let meeting = continuationMeeting(id) else { throw CancellationError() }
            try await meeting.setTransferHeld(true)
        }
        library.continuation.onResumeSource = { [weak self] id, restoreSending in
            try? await self?.continuationMeeting(id)?.setTransferHeld(false, restoreSending: restoreSending)
        }
        library.continuation.onLeaveSource = { [weak self] id, _ in
            guard let self, let meeting = continuationMeeting(id) else { return false }; return await leave(meeting)
        }
        library.continuation.onCancelTarget = { [weak self] _, id in
            guard let self else { return false }
            if let id, let meeting = continuationMeeting(id) { return await leave(meeting) }
            guard id == sessionID else { return false }; return await leave()
        }
        library.continuation.onActivityChanged = { [weak self] in self?.publishHandoff(self?.continuationSnapshot()) }
        CalendarReminderBroker.shared.install()
        CalendarReminderBroker.shared.attach(library.calendar.reminders)
        CalendarReminderBroker.shared.onAttention = { [weak self] id in
            self?.attention.showMoment(id); self?.show(section: .assistant)
        }
        CalendarReminderBroker.shared.onTask = { [weak self] id in
            guard let self else { return }
            Task { @MainActor in
                let store = self.attention.store
                await store.waitForMeetingLibrary()
                let rows = try? await store.meetingLibrary.store.taskHistory(profile: store.assistant.taskProfile, includeAll: true)
                if let row = rows?.first(where: { $0.id == id }) {
                    self.openMeetingHistory(row.sessionID, tab: .tasks, taskID: row.id, source: .tasks, activate: true)
                } else { self.show(section: .tasks) }
            }
        }
        self.attention.openHistory = { [weak self] id, tab in
            self?.openMeetingHistory(id, tab: tab, source: .assistant)
        }
        library.calendar.reminders.activeRoom = { [weak self] in self?.meeting.flatMap { MeetingRoomIdentity($0.invitation, engine: $0.kind) } }
        library.calendar.reminders.activeConnections = { [weak self] in self?.currentActiveConnections() ?? [] }
        library.calendar.reminders.scene = { [weak self] in
            let connections = self?.currentActiveConnections() ?? []
            return ReminderScene(visible: NSApp.isActive, connections: connections,
                usable: self?.preparing == false && self?.library.setup.isPresented == false && self?.library.calendar.reminders.editing == nil)
        }
        library.calendar.reminders.onPresentation = { [weak self] events in
            guard let self else { return [] }
            return reminderPresenter.render(events, coordinator: library.calendar.reminders)
        }
        library.calendar.reminders.onBackground = { [weak self] in self?.reminderPresenter.hide() }
        library.calendar.setSchedulingAvailable(true)
        self.attention.meetings = { [weak self] in self?.meetings ?? [] }
        self.attention.isOnScreen = { [weak self] in self?.isOnScreen($0) ?? false }
        self.attention.openMeeting = { [weak self] id in self?.openFromAttention(id) }
        self.attention.notify = { card in NativeDesktopWorkspace.postAttentionNotification(card) }
        self.attention.talk.joinMeeting = { [weak self] ref in
            guard let self, let invitation = ref.invitation else { return false }
            join(invitation, title: ref.title); return true
        }
        self.attention.talk.leaveMeeting = { [weak self] model in await self?.leave(model) ?? false }
        // Push-to-talk is app-wide, not tied to the Talk tab's visibility.
        // The publisher emits in willSet, so the controller must use the emitted value.
        self.attention.talk.installHotKey(enabled: self.attention.store.pushToTalk)
        self.attention.talk.observePushToTalk()
        self.attention.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        self.attention.$outcomeStatus.combineLatest(self.attention.$isRecoveringOutcomes)
            .map { $0.isEmpty && !$1 }.removeDuplicates().dropFirst().sink { [weak self] _ in
                // Published emits before the status changes. Recheck admission on the
                // next actor turn, after the summary has been persisted or failed.
                Task { @MainActor [weak self] in self?.onUpdateActivityChanged() }
            }.store(in: &subscriptions)
        // Store and assistant publishes (a seen-mark, a keystroke in an outcome) must not
        // invalidate the whole workspace. Views that read them observe those objects.
        library.calendar.$meetings.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronizeScheduledTransitions() }
        }.store(in: &subscriptions)
        self.attention.store.meetingLibrary.onSessionRenamed = { [weak self] id, title in
            guard let self else { return }
            for model in self.meetings where model.workspaceSessionID == id || model.sessionID == id {
                model.noteUserRenamedSession(title)
            }
        }
        library.sync.onSyncNow = { [weak self] in
            self?.workspaceSync.scheduleSync(delayMilliseconds: 150, localChanges: false)
        }
        library.sync.onSyncPreferencesChanged = { [weak self] in
            self?.workspaceSync.scheduleSync(delayMilliseconds: 100)
        }
        library.sync.onCommittedName = { [weak self] name in
            Task { @MainActor [weak self] in
                await self?.attention.store.seedTaskProfileWithMeetingName(name)
            }
        }
        let existingDeleteSyncedData = library.sync.beforeDeleteSyncedData
        library.sync.beforeDeleteSyncedData = { [weak self] in
            try await existingDeleteSyncedData?()
            try await self?.workspaceSync.clearCloudData()
        }
        self.workspaceSync.onTranscriptChanged = { [weak self] id in self?.offerHistoryRefresh(for: id) }
        self.attention.start()
        self.workspaceSync.start()
    }

    /// The meeting is in front of you: shown in a visible main window, its own
    /// window or Mini meeting, while this app is active.
    func isOnScreen(_ model: NativeDesktopMeetingModel) -> Bool {
        guard NSApp.isActive, let host = meetingWindows[model.sessionID] else { return false }
        if host.isMiniVisible || (!host.isEmbedded && host.isVisible) { return true }
        guard host.isEmbedded, selectedMeetingID == model.sessionID, let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }
    private func openFromAttention(_ id: UUID) {
        guard let model = meetings.first(where: { $0.sessionID == id }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        if isDetached(model) { showMeeting(model) } else { presentEmbedded(model) }
    }
    /// A "now" card while the app is in the background also reaches Notification Center.
    private static func postAttentionNotification(_ card: AttentionCoordinator.Card) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = L("“%@” needs you", card.meetingTitle)
        content.body = card.verdict.reason
        content.threadIdentifier = "attention"
        content.categoryIdentifier = CalendarReminderBroker.attentionCategory
        content.userInfo = ["momentID": card.id.uuidString]
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "attention-" + card.id.uuidString, content: content, trigger: nil))
    }

    func openCalendarSettings() {
        settingsTab = 1
        selection = .settings
    }

    @Published private(set) var lastFinishedHistoryID: UUID?

    func openAssistantMoments() {
        attention.opensAssistantMoments = true
        show(section: .assistant)
    }

    func openMeetingHistory(_ id: UUID? = nil, tab: MeetingHistoryTab = .summary, taskID: UUID? = nil,
                            source: Section? = nil, activate: Bool = false) {
        let navigation = attention.historyNavigation
        if let id {
            navigation.selectedSessionID = id
            navigation.indexVisible = false
            navigation.tab = tab
            navigation.taskID = taskID
            navigation.eventID = nil
        }
        navigation.source = source
        selection = .history
        if activate { show(section: .history) }
    }

    func show(section: Section? = nil) {
        if let section { selection = section }
        presentMainWindow()
        library.calendar.showingMacSettings = selection == .settings
        library.setup.finishLaunch(hasMeetingIntent: preparing || !meetings.isEmpty)
        library.foregrounded(allowAutomaticJoin: selection == .home)
        library.setup.offerIfAppropriate(selection == .home && meetings.isEmpty)
        #if NATIVE_DIRECT_UPDATES
        SupportReminder.shared.beginRecordingUse()
        if selection == .home { startSupportHomeVisit() }
        #endif
    }
    /// The one main window holds the library and every embedded meeting.
    private func presentMainWindow() {
        if window == nil {
            let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            value.delegate = self; value.title = "Rock'N'Roll for Mac"
            value.isReleasedWhenClosed = false; value.titlebarAppearsTransparent = true
            let host = NSHostingView(rootView: NativeDesktopHomeView(workspace: self, library: library))
            host.sizingOptions = []
            value.contentView = host
            value.center()
            value.setFrameAutosaveName("nativeDesktop.library")
            window = value
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .sink { [weak self] _ in self?.fitMainWindowToScreen() }.store(in: &subscriptions)
            NativeDesktopForegroundMedia.shared.setHomeWindow(value)
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        if window?.isVisible != true { fitMainWindowToScreen() }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        installMenuBar(); installKeyboard(); synchronizeMeetingPresentation()
    }

    private func fitMainWindowToScreen() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        window.minSize = NSSize(width: min(900, visible.width), height: min(420, visible.height))
        let fitted = Self.fittedMainWindowFrame(window.frame, in: visible)
        if fitted != window.frame { window.setFrame(fitted, display: true) }
    }

    static func fittedMainWindowFrame(_ frame: NSRect, in visible: NSRect) -> NSRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        return NSRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
                      y: min(max(frame.maxY, visible.minY + height), visible.maxY) - height,
                      width: width, height: height)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        library.calendar.showingMacSettings = false
        if library.setup.isPresented { library.setup.finishLater() }
        return true
    }
    func windowDidMiniaturize(_ notification: Notification) { library.calendar.showingMacSettings = false; synchronizeMeetingPresentationSoon() }
    func windowDidDeminiaturize(_ notification: Notification) {
        library.calendar.showingMacSettings = selection == .settings; synchronizeMeetingPresentationSoon()
    }
    func windowDidChangeOcclusionState(_ notification: Notification) { synchronizeMeetingPresentationSoon() }
    func windowWillClose(_ notification: Notification) {
        attention.store.assistant.flushOutcomeEdits()
        Task { @MainActor [weak self] in await self?.attention.store.notes.flushAll() }
        synchronizeMeetingPresentationSoon()
    }
    /// Window callbacks can arrive inside a SwiftUI update; media state changes after it.
    private func synchronizeMeetingPresentationSoon() {
        DispatchQueue.main.async { [weak self] in self?.synchronizeMeetingPresentation() }
    }
    func windowWillEnterFullScreen(_ notification: Notification) { mainHider.willEnter() }
    func windowDidEnterFullScreen(_ notification: Notification) { if let window { mainHider.didEnter(window) } }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { mainHider.failEnter() }
    func windowWillExitFullScreen(_ notification: Notification) { mainHider.willExit() }
    func windowDidExitFullScreen(_ notification: Notification) { mainHider.didExit() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { mainHider.failExit() }
    func joinInput() {
        do { let destination = try library.normalizedDestination(invitation); join(destination.invitationURL) }
        catch { self.error = error.localizedDescription }
    }
    func canResumeHistory(_ id: UUID, invitation: URL) -> Bool {
        guard let association = workspaceSync.association(for: id),
              let room = MeetingRoomIdentity(invitation), room.workspaceKey == association.roomKey else { return false }
        let connection = ActiveRoomConnection(room: room)
        let next = library.calendar.meetings.filter {
            $0.start > association.start && !$0.allDay && !$0.tentative && $0.isConnected(in: [connection]) &&
                !MeetingCalendarAssociation($0, room: room).matches(association)
        }.map(\.start).min()
        return association.allowsRejoin(at: library.calendar.currentTime, before: next)
    }

    func joinFromHistory(_ id: UUID, invitation: URL, title: String) {
        let canonical = workspaceSync.canonicalSessionID(id)
        if let live = meetings.first(where: { workspaceSync.canonicalSessionID($0.workspaceSessionID) == canonical }) {
            showMeeting(live)
        } else {
            let resumesHistory = canResumeHistory(id, invitation: invitation)
            join(invitation, title: title, quiet: true, historyRejoinID: resumesHistory ? id : nil,
                 startNewHistory: !resumesHistory)
        }
    }

    func join(_ url: URL, engine known: MeetingEngineKind? = nil, title: String? = nil, eventID: String? = nil,
              quiet: Bool = false, scheduled: NativeDesktopScheduledJoin? = nil, nameOverride: String? = nil,
              workspaceID: UUID? = nil, historyRejoinID: UUID? = nil, startNewHistory: Bool = false) {
        guard mayAdmitMeeting() else {
            scheduled?.finish(); error = meetingAdmissionError() ?? L("An update is being installed. Please try again after Rock'N'Roll for Mac restarts."); return
        }
        guard leaveTask == nil, meetingLeaves.isEmpty, !shutdownBlocked else { scheduled?.finish(); return }
        // Calendar automation never adds a second meeting; a reminder's Join does.
        if scheduled != nil, preparing || !meetings.isEmpty { scheduled?.finish(); return }
        if joinSettingUp {
            // Asked for while another join is still finding its service: it starts
            // right after that step, without waiting for the other to connect.
            queuedJoin = { [weak self] in
                self?.join(url, engine: known, title: title, eventID: eventID, quiet: quiet, nameOverride: nameOverride,
                           workspaceID: workspaceID, historyRejoinID: historyRejoinID, startNewHistory: startNewHistory)
            }
            return
        }
        let room = MeetingRoomIdentity(url, engine: known)
        if let room, let existing = meetings.first(where: {
            guard !$0.isClosed, let conn = connection(for: $0) else { return false }
            return conn.matches(room, endpoint: nil)
        }) {
            scheduled?.finish(); showMeeting(existing); return
        }
        if meetings.count >= Self.meetingLimit {
            error = L("You can be in up to %d meetings at once.", Self.meetingLimit); return
        }
        if scheduled == nil { library.setup.suspendForMeeting() }
        error = nil; sessionID = UUID(); joinSettingUp = true
        let joinID = UUID()
        if scheduled != nil { pendingScheduled = scheduled; scheduledJoinID = joinID }
        let token = joinGeneration, requestedSession = sessionID
        joinTasks[joinID] = Task { @MainActor [weak self] in
            guard let self else { return }
            var settingUp = true
            defer {
                scheduled?.finish()
                joinTasks[joinID] = nil; joinModels[joinID] = nil
                if scheduledJoinID == joinID { scheduledJoinID = nil; pendingScheduled = nil }
                if settingUp { endJoinSetup() }
            }
            var ownedModel: NativeDesktopMeetingModel?
            var earlierRecord: MeetingSessionRecord?
            do {
                try Task.checkCancellation(); guard token == joinGeneration else { return }
                guard scheduled?.admission() != false else { throw CancellationError() }
                let detection = try await detect(url)
                try Task.checkCancellation(); guard token == joinGeneration else { return }
                var detectedEndpoint: URL?
                if case .verified(.guest(let endpoint)) = detection { detectedEndpoint = endpoint }
                let destination: JoinDestination
                if let resolved = try JoinDestination.resolve(url, detection: detection, knownEngine: known) { destination = resolved }
                else {
                    guard scheduled == nil else { throw NativeDesktopError.ambiguousEngine }
                    destination = try chooseEngine(for: url)
                }
                try Task.checkCancellation()
                let endpointString = MeetingRoomIdentity.normalizedEndpoint(detectedEndpoint)
                let incomingRoom = MeetingRoomIdentity(destination.invitationURL, engine: destination.engineKind) ?? room
                if let incomingRoom, let existing = meetings.first(where: {
                    guard !$0.isClosed, let conn = connection(for: $0) else { return false }
                    return conn.matches(incomingRoom, endpoint: endpointString)
                }) {
                    settingUp = false; endJoinSetup()
                    showMeeting(existing); return
                }
                let name = (nameOverride ?? library.displayName).trimmingCharacters(in: .whitespacesAndNewlines)
                guard destination.engineKind.inputPolicy.accepts(name: name) else { throw NativeGuestEntryError.invalidName }
                if !name.isEmpty {
                    Task { @MainActor [weak self] in
                        await self?.attention.store.seedTaskProfileWithMeetingName(name)
                    }
                }
                let explicitTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let nowAtJoin = library.calendar.currentTime
                if let historyRejoinID, !canResumeHistory(historyRejoinID, invitation: url) {
                    throw NativeDesktopError.unavailable(L("The meeting is unavailable."))
                }
                let calendarCandidates = incomingRoom.map {
                    library.calendar.matchingHistoryOccurrences(
                        ActiveRoomConnection(room: $0, normalizedEndpoint: endpointString), at: nowAtJoin)
                } ?? []
                let explicitEvent = eventID.flatMap { id in library.calendar.meetings.first { $0.id == id } }
                let calendarMeeting: CalendarMeeting?
                if startNewHistory {
                    calendarMeeting = nil
                } else if let historyRejoinID, let incomingRoom, let saved = workspaceSync.association(for: historyRejoinID) {
                    calendarMeeting = calendarCandidates.first { MeetingCalendarAssociation($0, room: incomingRoom).matches(saved) }
                } else {
                    calendarMeeting = explicitEvent ?? (calendarCandidates.count == 1 ? calendarCandidates.first : nil)
                }
                let association = calendarMeeting.flatMap { event in incomingRoom.map { MeetingCalendarAssociation(event, room: $0) } }
                let locallyKnown = association.flatMap { candidate -> UUID? in
                    guard calendarCandidates.contains(where: { $0.id == calendarMeeting?.id }) else { return nil }
                    return workspaceSync.historySession(matching: candidate)
                }
                let historyID = historyRejoinID.map { workspaceSync.canonicalSessionID($0) }
                let resumedID = workspaceID.map { workspaceSync.canonicalSessionID($0) } ?? historyID ?? locallyKnown
                let prior = if let resumedID { try? await attention.store.meetingLibrary.store.session(resumedID) } else { nil as MeetingSessionRecord? }
                earlierRecord = prior
                let initialTitle = prior?.title ?? (explicitTitle?.isEmpty == false ? explicitTitle : nil) ?? calendarMeeting?.title
                let model = makeMeeting(destination, name, initialTitle, quiet)
                if startNewHistory { model.ignoreCalendarOccurrencesStartingOnOrBefore = nowAtJoin }
                ownedModel = model; joinModels[joinID] = ObjectIdentifier(model)
                model.resolvedEndpoint = detectedEndpoint
                if let resumedID { model.useInitialWorkspaceSession(resumedID) }
                if let calendarMeeting {
                    model.applyScheduledTitle(calendarMeeting.title, seriesID: calendarMeeting.seriesID, calendarMeeting: calendarMeeting)
                } else {
                    model.calendarSeriesID = prior?.calendarSeriesID
                    model.participationCalendar = nil
                }
                if let association, calendarCandidates.contains(where: { $0.id == calendarMeeting?.id }),
                   workspaceID == nil || workspaceSync.association(for: model.workspaceSessionID) == nil {
                    workspaceSync.recordCalendarAssociation(association, sessionID: model.workspaceSessionID)
                }
                model.segments = [
                    NativeDesktopMeetingModel.ScheduledSegment(
                        sessionID: model.workspaceSessionID,
                        calendarEventID: calendarMeeting?.id,
                        seriesID: calendarMeeting?.seriesID ?? model.calendarSeriesID,
                        title: model.title,
                        startedAt: nowAtJoin)
                ]
                model.meetingLibrary = attention.store.meetingLibrary
                model.notes = attention.store.notes
                model.synthesizeVoiceReply = { [weak attention] text in
                    guard let attention else { throw CancellationError() }
                    return try await attention.synthesize(text)
                }
                let initialSessionID = model.workspaceSessionID
                let initialSessionTitle = model.title
                let initialSeriesID = model.calendarSeriesID
                if prior == nil {
                    pendingSessionCreates[initialSessionID] = Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.attention.store.meetingLibrary.createSession(
                            id: initialSessionID, title: initialSessionTitle, invitation: model.invitation,
                            roomIdentity: MeetingRoomIdentity(model.invitation, engine: model.kind)?.displayDetails ?? "",
                            calendarSeriesID: initialSeriesID, startedAt: nowAtJoin)
                        await self.attention.store.meetingLibrary.markSessionConnected(initialSessionID)
                    }
                }
                let concurrent = !meetings.isEmpty, owns = talkMeeting == nil
                if concurrent { model.configureForConcurrentJoin(ownsMicrophone: owns) }
                meetings.append(model); if owns { talkID = model.sessionID }
                continuationSessions[model.sessionID] = requestedSession
                model.microphoneArbiter = { [weak self] target in await self?.claimTalk(for: target) ?? false }
                model.onLeave = { [weak self, weak model] in
                    guard let self, let model else { return }; _ = await leave(model)
                }
                model.onEndedByOrganizer = { [weak self, weak model] in
                    guard let self, let model else { return }
                    notice = (L("Meeting ended"), L("“%@” was ended by the organizer, or you were removed from it.", model.title))
                }
                meetingSubscriptions[model.sessionID] = model.objectWillChange.sink { [weak self, weak model] in
                    Task { @MainActor in if let model { self?.meetingDidChange(model) } }
                }
                meetingWindows[model.sessionID] = NativeDesktopMeetingWindow(model: model, continuation: library.continuation, workspace: self)
                if scheduled != nil && !NSApp.isActive { model.setMediaVisible(false); refreshMenu() }
                else { showMeeting(model) }
                // The meeting is listed and shown: another join may start while this one connects.
                settingUp = false; endJoinSetup()
                guard scheduled?.admission() != false else { throw CancellationError() }
                try await model.connect()
                try Task.checkCancellation()
                guard token == joinGeneration, meetings.contains(where: { $0 === model }), scheduled?.admission() != false else { throw CancellationError() }
                // Commit only after final admission, including same-turn revocation.
                if scheduledJoinID == joinID { scheduledJoinID = nil; pendingScheduled = nil }
                let connectedAt = library.calendar.currentTime
                if prior != nil {
                    model.workspaceJournal?.reopen(sessionID: initialSessionID)
                    attention.store.meetingLibrary.markSessionConnected(initialSessionID)
                }
                workspaceSync.noteLocalSessionJoined(sessionID: initialSessionID, joinedAt: connectedAt,
                    hasOutcomeWriter: attention.store.generateOutcomes)
                if model.segments.count == 1, model.segments[0].sessionID == model.workspaceSessionID {
                    model.segments[0].startedAt = connectedAt
                }
                library.recordJoin(invitation: model.invitation, title: model.title,
                    identifier: destination.roomIdentifier, engine: model.kind,
                    eventID: calendarMeeting?.id ?? eventID, endpoint: endpointString, since: connectedAt)
                library.continuation.targetDidConnect(invitation: model.invitation, sessionID: requestedSession)
                updateContinuation()
                library.calendar.reminders.activeConnectionsChanged()
                synchronizeScheduledTransitions()
            } catch {
                if token == joinGeneration, !(error is CancellationError) { self.error = error.localizedDescription }
                if token == joinGeneration, requestedSession == sessionID { library.continuation.targetDidFail() }
                if let ownedModel, meetings.contains(where: { $0 === ownedModel }) {
                    _ = await leave(ownedModel)
                    if let earlierRecord, let end = earlierRecord.endedAt {
                        ownedModel.workspaceJournal?.end(sessionID: earlierRecord.id, at: end)
                        await attention.store.meetingLibrary.endSession(earlierRecord.id, endedAt: end, awaitingOutcome: false)
                    } else if earlierRecord == nil, !ownedModel.connected {
                        attention.store.meetingLibrary.markSessionFailed(ownedModel.workspaceSessionID)
                    }
                }
            }
        }
    }
    private func chooseEngine(for url: URL) throws -> JoinDestination {
        let kinds: [MeetingEngineKind] = [.guest, .telemost, .trueconf, .community]
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        picker.addItems(withTitles: [L("Guest meeting"), "Telemost", "TrueConf", L("Rock jam")])
        let alert = NSAlert(); alert.messageText = L("Choose meeting service")
        alert.informativeText = L("The website could not identify its meeting service. Choose the service named in your invitation.")
        alert.accessoryView = picker; alert.addButton(withTitle: L("Join")); alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
        return try JoinDestination.verified(url, engine: kinds[picker.indexOfSelectedItem])
    }
    /// Leaves every meeting (Quit, update, "Leave all meetings").
    @discardableResult func leave() async -> Bool {
        if let leaveTask { return await leaveTask.value }
        scheduleTransitionTask?.cancel(); scheduleTransitionTask = nil
        let pending = Array(joinTasks.values)
        queuedJoin = nil; joinGeneration = UUID(); leavingAll = true
        let cleanup = Task { @MainActor in
            for task in pending { task.cancel() }
            for task in pending { await task.value }
            return await self.leaveAllMeetings()
        }
        leaveTask = cleanup
        let clean = await cleanup.value
        leaveTask = nil; leavingAll = false
        return clean
    }
    private func refreshPreparing() {
        let busy = !joinTasks.isEmpty || leavingAll
        if preparing != busy {
            preparing = busy
            if !busy { library.calendar.reminders.refreshPresentation() }
        }
    }
    private func endJoinSetup() {
        joinSettingUp = false
        guard let next = queuedJoin else { return }
        queuedJoin = nil
        Task { @MainActor in next() }
    }
    private func leaveAllMeetings() async -> Bool {
        var clean = true
        for model in meetings.reversed() where !(await leave(model)) { clean = false }
        return clean && !shutdownBlocked
    }
    /// Leaves one meeting; a sole survivor of a departed talk meeting takes the talk role (muted).
    deinit {
        scheduleTransitionTask?.cancel()
    }

    private func connection(for model: NativeDesktopMeetingModel) -> ActiveRoomConnection? {
        MeetingRoomIdentity(model.invitation, engine: model.kind).map {
            ActiveRoomConnection(room: $0, endpoint: model.resolvedEndpoint)
        }
    }

    private func currentActiveConnections() -> [ActiveRoomConnection] {
        meetings.filter { $0.connected && !$0.isClosed }.compactMap { connection(for: $0) }
    }

    func synchronizeScheduledTransitions() {
        scheduleTransitionTask?.cancel(); scheduleTransitionTask = nil
        let active = meetings.filter { $0.connected && !$0.isClosed }
        guard !active.isEmpty else { return }
        let now = library.calendar.currentTime
        let connections = active.compactMap { connection(for: $0) }

        for model in active {
            guard let conn = connection(for: model) else { continue }
            guard let scheduled = library.calendar.currentScheduledMeeting(matching: conn, at: now) else { continue }
            if let cutoff = model.ignoreCalendarOccurrencesStartingOnOrBefore, scheduled.start <= cutoff { continue }

            if model.segments.last?.calendarEventID == scheduled.id {
                let lastIndex = model.segments.count - 1
                if model.segments[lastIndex].title != scheduled.title || model.segments[lastIndex].seriesID != scheduled.seriesID {
                    model.segments[lastIndex].title = scheduled.title
                    model.segments[lastIndex].seriesID = scheduled.seriesID
                    model.applyScheduledTitle(scheduled.title, seriesID: scheduled.seriesID, calendarMeeting: scheduled)
                    let targetSessionID = model.workspaceSessionID
                    let updatedTitle = model.title
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.attention.store.meetingLibrary.updateSessionTitle(targetSessionID, title: updatedTitle)
                    }
                }
            } else if model.segments.count == 1, model.segments[0].calendarEventID == nil,
                      now.timeIntervalSince(model.segments[0].startedAt) < Self.sameRoomOverrunGrace {
                model.segments[0].calendarEventID = scheduled.id
                model.segments[0].seriesID = scheduled.seriesID
                model.segments[0].title = scheduled.title
                model.applyScheduledTitle(scheduled.title, seriesID: scheduled.seriesID, calendarMeeting: scheduled)
                if let room = MeetingRoomIdentity(model.invitation, engine: model.kind) {
                    library.calendar.reminders.joined(
                        room: room,
                        endpoint: MeetingRoomIdentity.normalizedEndpoint(model.resolvedEndpoint),
                        eventID: scheduled.id,
                        since: model.connectedSince ?? model.segments[0].startedAt)
                }
                library.calendar.noteConnected(
                    invitation: model.invitation,
                    engine: model.kind,
                    endpoint: model.resolvedEndpoint,
                    since: model.connectedSince ?? model.segments[0].startedAt,
                    roomID: library.history.matching(model.invitation, engine: model.kind)?.id,
                    at: now)
                library.history.updateTitle(for: model.invitation, title: scheduled.title)
                let targetSessionID = model.workspaceSessionID
                let updatedTitle = model.title
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.attention.store.meetingLibrary.updateSessionTitle(targetSessionID, title: updatedTitle)
                }
            } else {
                let boundary = max(scheduled.start, model.segments.last?.startedAt ?? now)
                handleScheduledTransition(for: model, to: scheduled, at: boundary, now: now)
            }
        }

        if let nextDate = library.calendar.nextTransitionDate(matching: connections, after: now) {
            let delay = max(0.05, nextDate.timeIntervalSince(now))
            scheduleTransitionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.synchronizeScheduledTransitions()
            }
        }
    }

    private func handleScheduledTransition(for model: NativeDesktopMeetingModel, to scheduled: CalendarMeeting,
                                           at boundary: Date, now: Date) {
        let room = MeetingRoomIdentity(model.invitation, engine: model.kind)
        let endpointString = MeetingRoomIdentity.normalizedEndpoint(model.resolvedEndpoint)
        if let room {
            library.calendar.reminders.joined(room: room, endpoint: endpointString,
                                              eventID: scheduled.id, since: model.connectedSince ?? boundary)
        }
        library.calendar.noteConnected(
            invitation: model.invitation,
            engine: model.kind,
            endpoint: model.resolvedEndpoint,
            since: model.connectedSince ?? boundary,
            roomID: library.history.matching(model.invitation, engine: model.kind)?.id,
            at: now)
        library.history.updateTitle(for: model.invitation, title: scheduled.title)

        let previousTitle = model.segments.last?.title ?? model.title
        if !model.segments.isEmpty {
            model.segments[model.segments.count - 1].endedAt = boundary
        }
        let decision = attention.store.effectiveSameRoomTransition(room: model.invitation, series: scheduled.seriesID)
        let mode = decision.mode

        switch mode {
        case .separateSessions:
            let newSessionID = UUID()
            if let room { workspaceSync.recordCalendarAssociation(MeetingCalendarAssociation(scheduled, room: room), sessionID: newSessionID) }
            let protectNote = shouldProtectActiveNote(for: model)
            model.rolloverWorkspaceSession(to: newSessionID, title: scheduled.title, seriesID: scheduled.seriesID,
                                           calendarMeeting: scheduled, at: boundary, protectActiveNote: protectNote)
            model.segments.append(NativeDesktopMeetingModel.ScheduledSegment(
                sessionID: newSessionID,
                calendarEventID: scheduled.id,
                seriesID: scheduled.seriesID,
                title: scheduled.title,
                startedAt: boundary))
            model.workspaceJournal?.recordAction(
                sessionID: newSessionID,
                text: L("Scheduled meeting started: %@", scheduled.title),
                occurredAt: boundary,
                source: "calendarTransition")
            let parentID = model.segments.count >= 2 ? model.segments[model.segments.count - 2].sessionID : nil
            let roomDetails = room?.displayDetails ?? ""
            pendingSessionCreates[newSessionID] = Task { @MainActor [weak self] in
                guard let self else { return }
                if let parentID { await self.pendingSessionCreates[parentID]?.value }
                await self.attention.store.meetingLibrary.createSession(
                    id: newSessionID, title: scheduled.title, invitation: model.invitation,
                    roomIdentity: roomDetails, calendarSeriesID: scheduled.seriesID, startedAt: boundary)
                await self.attention.store.meetingLibrary.markSessionConnected(newSessionID)
            }

        case .continuousSession:
            let sessionID = model.workspaceSessionID
            model.applyScheduledTitle(scheduled.title, seriesID: scheduled.seriesID, calendarMeeting: scheduled)
            model.segments.append(NativeDesktopMeetingModel.ScheduledSegment(
                sessionID: sessionID,
                calendarEventID: scheduled.id,
                seriesID: scheduled.seriesID,
                title: scheduled.title,
                startedAt: boundary))
            model.workspaceJournal?.recordAction(
                sessionID: sessionID,
                text: L("Scheduled meeting started: %@", scheduled.title),
                occurredAt: boundary,
                source: "calendarTransition")
            let chaptered = chapteredTitle(for: sessionID, in: model.segments)
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.pendingSessionCreates[sessionID]?.value
                await self.attention.store.meetingLibrary.updateSessionTitle(sessionID, title: chaptered)
            }
        }

        model.sameRoomTransitionBanner = NativeDesktopMeetingModel.SameRoomTransitionBanner(
            eventID: scheduled.id,
            previousTitle: previousTitle,
            currentTitle: scheduled.title,
            seriesID: scheduled.seriesID,
            mode: mode,
            transitionAt: boundary)
    }

    func setSameRoomTransitionMode(for model: NativeDesktopMeetingModel, mode: SameRoomMeetingTransitionMode, remember: Bool) {
        guard model.segments.count >= 2 else { return }
        let lastIndex = model.segments.count - 1
        let current = model.segments[lastIndex]
        let previous = model.segments[lastIndex - 1]
        if remember {
            attention.store.setSameRoomTransition(mode, room: model.invitation, series: current.seriesID, title: current.title)
        }
        if remember {
            model.sameRoomTransitionBanner = nil
        } else {
            model.sameRoomTransitionBanner?.mode = mode
        }

        let now = library.calendar.currentTime
        let previousSwitch = sameRoomSwitchTasks[model.sessionID]

        switch mode {
        case .continuousSession:
            guard current.sessionID != previous.sessionID else {
                model.segments[lastIndex].explicitSplitChoice = false
                return
            }
            let childID = current.sessionID
            let parentID = previous.sessionID
            model.segments[lastIndex].sessionID = parentID
            model.segments[lastIndex].explicitSplitChoice = false
            model.mergeWorkspaceSessionBack(into: parentID, title: current.title, seriesID: current.seriesID,
                                            calendarMeeting: model.participationCalendar, at: now)
            let chaptered = chapteredTitle(for: parentID, in: model.segments)
            sameRoomSwitchTasks[model.sessionID] = Task { @MainActor [weak self] in
                await previousSwitch?.value
                guard let self else { return }
                await self.pendingSessionCreates[parentID]?.value
                await self.pendingSessionCreates[childID]?.value
                self.pendingSessionCreates[childID] = nil
                let notes = self.attention.store.notes
                await notes.flush(sessionID: childID)
                await notes.flush(sessionID: parentID)
                await notes.load(sessionID: parentID)
                await notes.load(sessionID: childID)
                let parentText = notes.buffer(sessionID: parentID)
                let childText = notes.buffer(sessionID: childID)
                if !childText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let merged: String
                    if parentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        merged = childText
                    } else {
                        let trimmedParent = parentText.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
                        let trimmedChild = childText.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
                        merged = trimmedParent + "\n\n## \(current.title)\n\n" + trimmedChild
                    }
                    notes.update(sessionID: parentID, text: merged, at: now)
                    await notes.flush(sessionID: parentID)
                }
                notes.discard(sessionID: childID)
                await self.attention.store.meetingLibrary.deleteSession(childID)
                await self.attention.store.meetingLibrary.updateSessionTitle(parentID, title: chaptered)
            }

        case .separateSessions:
            model.segments[lastIndex].explicitSplitChoice = true
            guard current.sessionID == previous.sessionID else { return }
            let parentID = previous.sessionID
            let newSessionID = UUID()
            let boundary = current.startedAt
            let protectNote = shouldProtectActiveNote(for: model)
            model.segments[lastIndex].sessionID = newSessionID
            model.rolloverWorkspaceSession(to: newSessionID, title: current.title, seriesID: current.seriesID,
                                           calendarMeeting: model.participationCalendar, at: boundary,
                                           protectActiveNote: protectNote)
            model.workspaceJournal?.splitEvents(from: parentID, into: newSessionID, since: boundary)
            model.workspaceJournal?.end(sessionID: parentID, at: boundary)
            model.workspaceJournal?.recordAction(
                sessionID: newSessionID,
                text: L("Scheduled meeting started: %@", current.title),
                occurredAt: boundary,
                source: "calendarTransition")
            let parentChaptered = chapteredTitle(for: parentID, in: model.segments)
            let roomDetails = MeetingRoomIdentity(model.invitation, engine: model.kind)?.displayDetails ?? ""
            let createTask = Task { @MainActor [weak self] in
                await previousSwitch?.value
                guard let self else { return }
                await self.pendingSessionCreates[parentID]?.value
                await self.attention.store.meetingLibrary.updateSessionTitle(parentID, title: parentChaptered)
                await self.attention.store.meetingLibrary.createSession(
                    id: newSessionID, title: current.title, invitation: model.invitation,
                    roomIdentity: roomDetails, calendarSeriesID: current.seriesID, startedAt: boundary)
                await self.attention.store.meetingLibrary.markSessionConnected(newSessionID)
            }
            pendingSessionCreates[newSessionID] = createTask
            sameRoomSwitchTasks[model.sessionID] = createTask
        }
    }

    private func offerHistoryRefresh(for rawID: UUID) {
        guard attention.store.shouldCaptureOutcome else { return }
        let id = workspaceSync.historySessionID(rawID)
        guard !meetings.contains(where: { workspaceSync.historySessionID($0.workspaceSessionID) == id }),
              workspaceSync.isHistoryRefreshWriter(for: id, at: library.calendar.currentTime),
              let old = attention.store.assistant.outcomes.first(where: { $0.meetingID == id }),
              let session = workspaceSync.historyConversation(for: id, in: attention.store.meetingLibrary.workspaceJournal),
              let end = session.endedAt else { return }
        let window = MeetingOutcomePrompt.historyWindow(title: session.title, events: session.events, endedAt: end,
            onDevice: attention.store.effectiveWriter.kind == .apple, contextTokens: attention.store.outcomeContextTokens)
        guard old.transcriptFingerprint != MeetingOutcomePrompt.fingerprint(window) else { return }
        attention.prepareHistoryOutcome(sessionID: id, title: session.title, endedAt: end, window: window)
    }

    private func shouldProtectActiveNote(for model: NativeDesktopMeetingModel) -> Bool {
        guard let notes = model.notes else { return false }
        let noteID = model.activeNoteSessionID
        if notes.draft(sessionID: noteID)?.isDirty == true { return true }
        if !notes.buffer(sessionID: noteID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return notes.hasEditor(sessionID: noteID) && (NSApp.keyWindow?.firstResponder is NSTextView)
    }

    private func chapteredTitle(for sessionID: UUID, in segments: [NativeDesktopMeetingModel.ScheduledSegment]) -> String {
        var titles: [String] = []
        for segment in segments where segment.sessionID == sessionID {
            let clean = segment.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            if titles.last != clean { titles.append(clean) }
        }
        return titles.joined(separator: " → ")
    }

    private func finalizeSegmentsAndOutcomes(for model: NativeDesktopMeetingModel, leftAt: Date) async -> Set<UUID> {
        await sameRoomSwitchTasks[model.sessionID]?.value
        let pendingIDs = Set([model.sessionID, model.workspaceSessionID] + model.segments.map(\.sessionID))
        for sid in pendingIDs {
            await pendingSessionCreates[sid]?.value
            pendingSessionCreates[sid] = nil
        }

        if model.segments.count >= 2, let last = model.segments.last {
            let previous = model.segments[model.segments.count - 2]
            if leftAt.timeIntervalSince(last.startedAt) <= Self.sameRoomOverrunGrace, !last.explicitSplitChoice {
                var canFold = true
                if last.sessionID != previous.sessionID {
                    let bufferEmpty = attention.store.notes.buffer(sessionID: last.sessionID)
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let persisted = await attention.store.meetingLibrary.note(sessionID: last.sessionID)
                    let persistedEmpty = persisted?.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
                    canFold = bufferEmpty && persistedEmpty
                }
                if canFold {
                    model.segments.removeLast()
                    model.segments[model.segments.count - 1].endedAt = nil
                    if last.sessionID != previous.sessionID {
                        model.mergeWorkspaceSessionBack(into: previous.sessionID, title: previous.title,
                                                        seriesID: previous.seriesID, calendarMeeting: nil, at: leftAt)
                        attention.store.notes.discard(sessionID: last.sessionID)
                        await attention.store.meetingLibrary.deleteSession(last.sessionID)
                    } else {
                        let restored = chapteredTitle(for: previous.sessionID, in: model.segments)
                        let hasOverride = await attention.store.meetingLibrary.store.hasTitleOverride(previous.sessionID)
                        if !hasOverride, !restored.isEmpty {
                            await attention.store.meetingLibrary.updateSessionTitle(previous.sessionID, title: restored)
                        }
                    }
                }
            }
        }

        var groups: [(sessionID: UUID, segments: [NativeDesktopMeetingModel.ScheduledSegment])] = []
        for segment in model.segments {
            if let lastGroup = groups.last, lastGroup.sessionID == segment.sessionID {
                groups[groups.count - 1].segments.append(segment)
            } else {
                groups.append((sessionID: segment.sessionID, segments: [segment]))
            }
        }
        if groups.isEmpty {
            groups = [(sessionID: model.workspaceSessionID, segments: [
                NativeDesktopMeetingModel.ScheduledSegment(
                    sessionID: model.workspaceSessionID,
                    calendarEventID: nil,
                    seriesID: model.calendarSeriesID,
                    title: model.title,
                    startedAt: model.connectedSince ?? leftAt)
            ])]
        }

        var specs: [AttentionCoordinator.OutcomeSegmentSpec] = []
        for (index, group) in groups.enumerated() {
            let from: Date? = index == 0 ? nil : group.segments.first?.startedAt
            let until: Date? = index == groups.count - 1
                ? nil
                : (group.segments.last?.endedAt ?? groups[index + 1].segments.first?.startedAt)
            let endedAt = index == groups.count - 1 ? leftAt : (group.segments.last?.endedAt ?? leftAt)
            let rawChaptered = chapteredTitle(for: group.sessionID, in: model.segments)
            let chaptered = rawChaptered.isEmpty ? model.title : rawChaptered
            let hasOverride = await attention.store.meetingLibrary.store.hasTitleOverride(group.sessionID)
            let resolvedTitle: String
            if hasOverride,
               let saved = (try? await attention.store.meetingLibrary.store.session(group.sessionID))?.title.trimmingCharacters(in: .whitespacesAndNewlines),
               !saved.isEmpty {
                resolvedTitle = saved
            } else {
                resolvedTitle = chaptered
                if group.segments.count > 1 {
                    await attention.store.meetingLibrary.updateSessionTitle(group.sessionID, title: chaptered)
                }
            }
            let chapters: [(at: Date, title: String)] = group.segments.count > 1
                ? group.segments.map { (at: $0.startedAt, title: $0.title) }
                : []
            specs.append(AttentionCoordinator.OutcomeSegmentSpec(
                sessionID: group.sessionID,
                title: resolvedTitle,
                invitation: model.invitation,
                seriesID: group.segments.last?.seriesID ?? model.calendarSeriesID,
                from: from,
                until: until,
                endedAt: endedAt,
                chapters: chapters))
        }

        for spec in specs {
            await workspaceSync.pullAndMergeTranscripts(for: spec.sessionID)
            workspaceSync.noteLocalSessionLeft(sessionID: spec.sessionID, leftAt: spec.endedAt)
        }
        let awaiting = attention.captureOutcomes(for: model, segments: specs)
        for (group, spec) in zip(groups, specs) {
            model.workspaceJournal?.end(sessionID: group.sessionID, at: spec.endedAt)
            await attention.store.meetingLibrary.endSession(
                group.sessionID,
                endedAt: spec.endedAt,
                awaitingOutcome: awaiting.contains(group.sessionID))
        }
        workspaceSync.scheduleSync(delayMilliseconds: 150)
        return awaiting
    }

    @discardableResult func leave(_ model: NativeDesktopMeetingModel) async -> Bool {
        let id = model.sessionID
        if let task = meetingLeaves[id] { return await task.value }
        for (joinID, owner) in joinModels where owner == ObjectIdentifier(model) { joinTasks[joinID]?.cancel() }
        let task = Task { @MainActor () -> Bool in
            let leftAt = library.calendar.currentTime
            attention.noteLeave(model)
            // Local durable flushes are part of leaving; Obsidian export stays queued.
            let noteSessionIDs = Set([id, model.workspaceSessionID, model.activeNoteSessionID] + model.segments.map(\.sessionID))
            for noteSessionID in noteSessionIDs {
                await attention.store.notes.flush(sessionID: noteSessionID)
            }
            let clean = await model.leave()
            guard self.meetings.contains(where: { $0 === model }) else {
                await self.pendingSessionCreates[id]?.value
                await self.attention.store.meetingLibrary.endSession(id, endedAt: leftAt, awaitingOutcome: false)
                self.attention.forgetLeave(id)
                return clean
            }
            if clean {
                _ = await self.finalizeSegmentsAndOutcomes(for: model, leftAt: leftAt)
                if model.connectedSince != nil || model.workspaceJournal?.session(id: model.workspaceSessionID) != nil {
                    self.lastFinishedHistoryID = model.workspaceSessionID
                }
                self.meetings.removeAll { $0 === model }
                for id in Set(model.segments.map(\.sessionID)) { self.offerHistoryRefresh(for: id) }
                self.meetingWindows.removeValue(forKey: id)?.close()
                self.meetingSubscriptions[id] = nil; self.renderedMeetingStates[id] = nil; self.continuationSessions[id] = nil
                self.pendingSessionCreates[id] = nil; self.sameRoomSwitchTasks[id] = nil
                if self.talkID == id { self.talkID = nil }
                if self.talkID == nil, self.meetings.count == 1, let survivor = self.meetings.first {
                    _ = await self.claimTalk(for: survivor)
                }
                if self.selectedMeetingID == id { self.selectedMeetingID = (self.talkMeeting ?? self.meetings.last)?.sessionID }
                self.synchronizeMeetingPresentation()
                self.updateContinuation()
                self.library.calendar.reminders.activeConnectionsChanged()
                self.synchronizeScheduledTransitions()
                self.attention.forgetLeave(id)
            } else {
                self.shutdownBlocked = true; self.error = NativeDesktopError.cleanupFailed.localizedDescription
            }
            self.objectWillChange.send(); self.refreshMenu(); return clean
        }
        meetingLeaves[id] = task
        let clean = await task.value
        meetingLeaves[id] = nil
        return clean
    }
    /// Serializes every talk-role move. The previous talk meeting must confirm it
    /// released mic, camera and input before the target gets the permit and headset.
    func claimTalk(for target: NativeDesktopMeetingModel) async -> Bool {
        let previous = handover
        let task = Task { @MainActor [weak self] () -> Bool in
            _ = await previous?.value
            guard let self, !target.isClosed, meetings.contains(where: { $0 === target }) else { return false }
            let began = ProcessInfo.processInfo.systemUptime
            var released = began
            let from = talkMeeting.flatMap { $0 === target ? nil : $0.kind.rawValue }
            defer {
                let now = ProcessInfo.processInfo.systemUptime
                target.noteHandoverPhases(from: from, releaseMilliseconds: (released - began) * 1000,
                                          assumeMilliseconds: (now - released) * 1000)
            }
            if let current = talkMeeting, current !== target {
                defer { released = ProcessInfo.processInfo.systemUptime }
                guard await current.relinquishMicrophone() else {
                    target.error = L("Couldn’t move your microphone from “%@”. Try again, or leave that meeting.", current.title)
                    return false
                }
            }
            guard !target.isClosed, meetings.contains(where: { $0 === target }) else { return false }
            talkID = target.sessionID
            await target.assumeMicrophone()
            refreshMenu()
            return !target.isClosed && target.ownsMicrophone
        }
        handover = task
        return await task.value
    }
    func showMeeting() { if let meeting { showMeeting(meeting) } }
    /// Selects an embedded meeting in the main window, or fronts a detached one.
    func showMeeting(_ model: NativeDesktopMeetingModel) {
        guard let host = meetingWindows[model.sessionID] else { return }
        host.show()
        refreshMenu()
    }
    var selectedMeeting: NativeDesktopMeetingModel? { meetings.first { $0.sessionID == selectedMeetingID } }
    var embeddedMeetings: [NativeDesktopMeetingModel] { meetings.filter { meetingWindows[$0.sessionID]?.isEmbedded == true } }
    func isDetached(_ model: NativeDesktopMeetingModel) -> Bool { meetingWindows[model.sessionID]?.detached == true }
    /// A meeting not shown in the main window is audio only: the sidebar rows are
    /// the ambient status surface, and floating video is an explicit opt-in
    /// ("Mini meeting"), never an automatic overlay over library sections.
    var sidebarSelection: NativeDesktopSidebarItem? {
        get { selectedMeetingID.map(NativeDesktopSidebarItem.meeting) ?? .section(selection) }
        set {
            // The sidebar List writes its selection back during view updates;
            // republishing an unchanged value would re-render it in a loop.
            guard newValue != sidebarSelection else { return }
            switch newValue {
            case .section(let section)?:
                selection = section
                #if NATIVE_DIRECT_UPDATES
                if section == .home { startSupportHomeVisit() }
                #endif
            case .meeting(let id)?:
                guard let model = meetings.first(where: { $0.sessionID == id }) else { return }
                selectSidebarMeeting(model)
            case nil: break
            }
        }
    }
    func selectSidebarMeeting(_ model: NativeDesktopMeetingModel) {
        if isDetached(model), selectedMeetingID != model.sessionID { selectedMeetingID = model.sessionID }
        showMeeting(model)
    }
    func presentEmbedded(_ model: NativeDesktopMeetingModel) {
        guard meetings.contains(where: { $0 === model }) else { return }
        objectWillChange.send()
        workspaceViewState.focusedID = model.sessionID
        if selectedMeetingID != model.sessionID { selectedMeetingID = model.sessionID }
        presentMainWindow()
    }
    /// A meeting moved between the main window, its own window and Mini meeting.
    func meetingDidMove(_ model: NativeDesktopMeetingModel) {
        objectWillChange.send(); synchronizeMeetingPresentation(); refreshMenu()
    }
    /// Mini meeting replaces the main window while it shows that meeting.
    func meetingDidEnterMini(_ model: NativeDesktopMeetingModel) {
        objectWillChange.send()
        guard selectedMeetingID == model.sessionID, let window, window.isVisible else { synchronizeMeetingPresentation(); return }
        mainHider.hide(window) { [weak self] in self?.synchronizeMeetingPresentation() }
    }
    func toggleWindow(_ model: NativeDesktopMeetingModel) {
        guard let host = meetingWindows[model.sessionID] else { return }
        if host.detached { host.moveToMainWindow() } else { host.detach() }
    }
    func showMini(_ model: NativeDesktopMeetingModel) {
        meetingWindows[model.sessionID]?.showMini()
        // A new floating panel may take the last streaming slot or free one.
        synchronizeMeetingPresentation()
    }
    /// At most this many Mini meeting panels stream video at once; the rest
    /// degrade to an audio info card until a slot frees.
    let maxStreamingMinis = 2
    /// Floating panels currently streaming, in promotion order: the talk meeting
    /// first, then the meetings' own order. Deterministic, so a freed slot never
    /// flaps between two candidates.
    func allowsFloatingMini(_ model: NativeDesktopMeetingModel) -> Bool {
        let candidates = meetings.filter { meetingWindows[$0.sessionID]?.isStreamingMini == true }
        guard candidates.count > maxStreamingMinis else { return true }
        let order = candidates.sorted { a, b in
            if a.sessionID == talkID { return true }
            if b.sessionID == talkID { return false }
            let ai = meetings.firstIndex { $0 === a } ?? meetings.count
            let bi = meetings.firstIndex { $0 === b } ?? meetings.count
            return ai < bi
        }
        return order.prefix(maxStreamingMinis).contains { $0 === model }
    }
    /// Only the selected meeting in a visible main window renders full video.
    func synchronizeMeetingPresentation() {
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        let shown = visible ? selectedMeeting : nil
        for model in meetings {
            meetingWindows[model.sessionID]?.synchronizeEmbedded(shown: model === shown)
        }
        // Detached hosts decide their own presentation, including the streaming cap.
        for model in meetings where isDetached(model) {
            meetingWindows[model.sessionID]?.synchronizePresentation()
        }
    }
    /// Dock click: an open main window comes forward as it is; otherwise the
    /// talk meeting returns instead of Home.
    func reopen(hasVisibleWindows: Bool) {
        guard let current = meeting, let host = meetingWindows[current.sessionID] else { show(); return }
        let mainShown = window.map { $0.isVisible && !$0.isMiniaturized } ?? false
        if !host.isEmbedded || !hasVisibleWindows || !mainShown { showMeeting(current) } else { presentMainWindow() }
    }
    /// An explicit "Leave all meetings" acts at once, like each row's Leave button.
    func leaveAllNow() { Task { _ = await leave() } }
    private func continuationMeeting(_ session: UUID) -> NativeDesktopMeetingModel? {
        meetings.first { continuationSessions[$0.sessionID] == session }
    }
    func activate() { library.foregrounded(); if meeting != nil { showMeeting() } else { show() } }
    func backgrounded() { library.backgrounded() }
    func cloudNotification() async {
        await library.sync.synchronizeForNotification()
        await workspaceSync.synchronizeNow(localChanges: false)
        await library.continuation.refresh()
    }
    func handleURL(_ url: URL) { show(); invitation = url.absoluteString; joinInput() }

    /// Handoff and active-jam reporting describe the talk meeting (else the latest).
    private func continuationSnapshot() -> ActiveJam? {
        guard let meeting, meeting.snapshot.phase == .connected,
              let session = continuationSessions[meeting.sessionID] else { return nil }
        return ActiveJam(deviceID: library.sync.deviceID, sessionID: session, invitation: meeting.invitation,
            title: meeting.title, name: meeting.displayName, deviceLabel: Host.current().localizedName ?? "Mac",
            isSharingScreen: meeting.snapshot.sharing, supportsCompanion: true,
            audioPaused: !meeting.snapshot.playoutOn, engine: meeting.kind,
            workspaceSessionID: meeting.workspaceSessionID)
    }
    private func meetingDidChange(_ meeting: NativeDesktopMeetingModel) {
        guard meetings.contains(where: { $0 === meeting }) else { return }
        let state = [meeting.sessionID.uuidString, meeting.title, meeting.snapshot.phase.rawValue,
            String(meeting.snapshot.microphoneOn), String(meeting.snapshot.cameraOn), String(meeting.snapshot.sharing),
            String(meeting.snapshot.playoutOn), String(meeting.participants.count), String(meeting.ownsMicrophone),
            String(meeting.participants.contains { !$0.isLocal && $0.speaking == true }),
            String(describing: meeting.localCamera.map(ObjectIdentifier.init))].joined(separator: "|")
        guard state != renderedMeetingStates[meeting.sessionID] else { return }
        renderedMeetingStates[meeting.sessionID] = state; objectWillChange.send(); refreshMenu(); updateContinuation()
        if meeting.snapshot.phase == .connected {
            workspaceSync.noteLocalSessionJoined(
                sessionID: meeting.workspaceSessionID,
                joinedAt: library.calendar.currentTime,
                hasOutcomeWriter: attention.store.generateOutcomes
            )
            workspaceSync.noteMicStateChanged(
                sessionID: meeting.workspaceSessionID,
                active: meeting.snapshot.microphoneOn && meeting.ownsMicrophone
            )
        }
    }
    private func updateContinuation() {
        let snapshot = continuationSnapshot()
        library.continuation.updateCurrent(snapshot)
        // Retire the local OS advertisement immediately; cloud withdrawal can fail.
        if snapshot == nil { publishHandoff(nil) }
    }
    private func publishHandoff(_ jam: ActiveJam?) {
        activity?.invalidate(); activity = nil
        guard library.continuation.isAvailable, let jam else { return }
        let value = makeHandoffActivity(jam)
        value.becomeCurrent(); activity = value
    }
    func continueActivity(_ userActivity: NSUserActivity) -> Bool {
        guard let reference = NativeDesktopHandoff.reference(in: userActivity) else { return false }
        handoffLookup?.cancel()
        show()
        handoffLookup = Task { [weak self] in
            guard let self else { return }
            do {
                let candidates = try await library.continuation.refreshAndWait()
                try Task.checkCancellation()
                guard candidates.contains(where: { $0.deviceID == reference.deviceID && $0.sessionID == reference.sessionID }) else {
                    error = L("This meeting is no longer available on the other device."); return
                }
                selection = .home
            } catch is CancellationError {
                // A newer system activity owns the UI.
            } catch {
                guard !Task.isCancelled else { return }
                self.error = L("Active jams could not refresh. Try again when iCloud is available.")
            }
        }; return true
    }
    private func installKeyboard() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let fallback = meeting, event.isARepeat == false else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = event.charactersIgnoringModifiers?.lowercased()
            // Shortcuts act on the meeting whose window is key; unmuting there moves the mic.
            let keyMeeting = meetings.first { self.meetingWindows[$0.sessionID]?.isKeyWindow == true }
                ?? (self.window?.isKeyWindow == true ? self.selectedMeeting.flatMap { self.isDetached($0) ? nil : $0 } : nil)
            let typing = NSApp.keyWindow?.firstResponder is NSTextView || NSApp.keyWindow?.firstResponder is NSTextField
            if event.keyCode == 53 && modifiers.isEmpty, let keyMeeting, keyMeeting.immersive { keyMeeting.immersive = false; return nil }
            if key == "m" && modifiers == [.command, .shift] { (keyMeeting ?? fallback).toggleMicrophone(); return nil }
            if key == "s" && modifiers == [.command, .shift], let keyMeeting { keyMeeting.togglePlayout(); return nil }
            if modifiers == [.command] || modifiers == [.command, .control], let digit = key.flatMap(Int.init) {
                if digit == 0 && modifiers == [.command] { show(section: .home); return nil }
                if digit >= 1 && digit <= meetings.count { showMeeting(meetings[digit - 1]); return nil }
            }
            if event.keyCode == 49 && modifiers.isEmpty && !typing, let keyMeeting { keyMeeting.toggleMicrophone(); return nil }
            return event
        }
    }
    private func installMenuBar() {
        refreshMenu()
        guard !menuSubscriptionInstalled else { return }
        menuSubscriptionInstalled = true
        library.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.refreshMenu() }
        }.store(in: &subscriptions)
    }
    private func refreshMenu() {
        guard library.calendar.keepInMenuBar || !meetings.isEmpty || preparing else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil; statusIconLive = nil; return
        }
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }
        if statusIconLive != !meetings.isEmpty {
            statusIconLive = !meetings.isEmpty
            statusItem?.button?.image = NativeDesktopStatusIcon.image(live: !meetings.isEmpty)
        }
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) {
            let row = NSMenuItem(title: title, action: action, keyEquivalent: ""); row.target = self; menu.addItem(row)
        }
        if meetings.count > 1 {
            for model in meetings {
                let row = NSMenuItem(title: model.title + " · " + Self.statusText(model), action: nil, keyEquivalent: "")
                let actions = NSMenu()
                func action(_ title: String, _ selector: Selector) {
                    let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                    entry.target = self; entry.representedObject = model.sessionID; actions.addItem(entry)
                }
                action(L("Show meeting"), #selector(showMeetingItem(_:)))
                action(model.snapshot.microphoneOn ? L("Mute") : L("Unmute"), #selector(toggleMicItem(_:)))
                action(model.snapshot.playoutOn ? L("Silence") : L("Sound on"), #selector(toggleSoundItem(_:)))
                action(L("Leave"), #selector(leaveItem(_:)))
                row.submenu = actions; menu.addItem(row)
            }
            item(L("Leave all meetings"), #selector(leaveAllFromMenu))
        } else if let meeting {
            menu.addItem(withTitle: meeting.title, action: nil, keyEquivalent: "")
            item(L("Show meeting"), #selector(openMeeting))
            item(meeting.snapshot.microphoneOn ? L("Mute") : L("Unmute"), #selector(toggleMic))
            item(L("Leave"), #selector(leaveFromMenu))
        } else if let next = library.calendar.suggestedMenuMeeting {
            menu.addItem(withTitle: next.title, action: nil, keyEquivalent: "")
            item(L("Join meeting"), #selector(joinSuggested))
            item(L("Skip automatic join for this meeting"), #selector(skipSuggested))
            if library.calendar.automaticJoinPausedUntil.map({ $0 > Date() }) == true {
                item(L("Resume automatic joining"), #selector(resumeSchedule))
            } else { item(L("Pause automatic joining today"), #selector(pauseSchedule)) }
        }
        menu.addItem(.separator()); item(L("Open Rock'N'Roll for Mac"), #selector(openHome))
        item(L("Settings…"), #selector(openSettings)); menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit Rock'N'Roll for Mac"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit); statusItem?.menu = menu
    }
    @objc private func openHome() { show() }
    @objc private func showHomeItem() { show(section: .home) }
    @objc private func toggleWindowItem(_ sender: NSMenuItem) { if let model = menuMeeting(sender) { toggleWindow(model) } }
    @objc private func miniItem(_ sender: NSMenuItem) { if let model = menuMeeting(sender) { showMini(model) } }
    /// Window menu: standard window commands, Home and every meeting (⌘0–⌘4).
    func populateWindowMenu(_ menu: NSMenu) {
        Self.addStandardWindowItems(menu)
        menu.addItem(.separator())
        let home = NSMenuItem(title: L("Home"), action: #selector(showHomeItem), keyEquivalent: "0")
        home.target = self; menu.addItem(home)
        for (index, model) in meetings.enumerated() {
            let row = NSMenuItem(title: model.title, action: #selector(showMeetingItem(_:)), keyEquivalent: index < 9 ? "\(index + 1)" : "")
            row.target = self; row.representedObject = model.sessionID
            row.image = NSImage(systemSymbolName: Self.statusSymbol(model), accessibilityDescription: Self.statusText(model))
            row.state = model.sessionID == selectedMeetingID ? .on : .off
            menu.addItem(row)
        }
        if let current = selectedMeeting ?? meeting {
            menu.addItem(.separator())
            for (title, selector) in [(isDetached(current) ? L("Move Meeting to Main Window") : L("Open Meeting in New Window"), #selector(toggleWindowItem(_:))),
                                      (L("Mini meeting"), #selector(miniItem(_:)))] {
                let row = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                row.target = self; row.representedObject = current.sessionID; menu.addItem(row)
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    }
    static func addStandardWindowItems(_ menu: NSMenu) {
        menu.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: L("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        menu.addItem(withTitle: L("Show Sidebar"), action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
    }
    /// Dock menu: every meeting with its state, then the talk meeting's mic and Leave.
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector, _ model: NativeDesktopMeetingModel? = nil) -> NSMenuItem {
            let row = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            row.target = self; row.representedObject = model?.sessionID; menu.addItem(row); return row
        }
        for model in meetings {
            add(model.title + " · " + Self.statusText(model), #selector(showMeetingItem(_:)), model)
                .image = NSImage(systemSymbolName: Self.statusSymbol(model), accessibilityDescription: nil)
        }
        if let talk = talkMeeting {
            menu.addItem(.separator())
            _ = add(talk.snapshot.microphoneOn ? L("Mute Microphone") : L("Unmute Microphone"), #selector(toggleMicItem(_:)), talk)
            _ = add(L("Leave “%@”", talk.title), #selector(leaveItem(_:)), talk)
            menu.addItem(.separator())
        }
        _ = add(L("Home"), #selector(showHomeItem))
        return menu
    }
    @objc private func openSettings() { show(section: .settings) }
    @objc private func openMeeting() { showMeeting() }
    @objc private func toggleMic() { meeting?.toggleMicrophone() }
    @objc private func leaveFromMenu() { Task { _ = await leave() } }
    @objc private func leaveAllFromMenu() { leaveAllNow() }
    private func menuMeeting(_ sender: NSMenuItem) -> NativeDesktopMeetingModel? {
        meetings.first { $0.sessionID == sender.representedObject as? UUID }
    }
    @objc private func showMeetingItem(_ sender: NSMenuItem) { if let model = menuMeeting(sender) { showMeeting(model) } }
    @objc private func toggleMicItem(_ sender: NSMenuItem) { menuMeeting(sender)?.toggleMicrophone() }
    @objc private func toggleSoundItem(_ sender: NSMenuItem) { menuMeeting(sender)?.togglePlayout() }
    @objc private func leaveItem(_ sender: NSMenuItem) {
        guard let model = menuMeeting(sender) else { return }; Task { _ = await leave(model) }
    }
    static func statusSymbol(_ model: NativeDesktopMeetingModel) -> String {
        if !model.snapshot.playoutOn { return "speaker.slash" }
        if !model.ownsMicrophone { return "ear" }
        return model.snapshot.microphoneOn ? "mic.fill" : "mic.slash"
    }
    /// Talking, Muted, Listening or Silenced, shared by the menu and the Meetings popover.
    static func statusText(_ model: NativeDesktopMeetingModel) -> String {
        if !model.snapshot.playoutOn { return L("Silenced") }
        if !model.ownsMicrophone { return L("Listening") }
        return model.snapshot.microphoneOn ? L("Talking") : L("Muted")
    }
    @objc private func skipSuggested() { if let next = library.calendar.suggestedMenuMeeting { library.calendar.suppressAutomaticJoin(for: next) } }
    @objc private func pauseSchedule() { library.calendar.pauseScheduledJoiningToday() }
    @objc private func resumeSchedule() { library.calendar.resumeScheduledJoining() }
    @objc private func joinSuggested() { if let next = library.calendar.suggestedMenuMeeting { library.open(next) } }
}

enum NativeDesktopSidebarItem: Hashable {
    case section(NativeDesktopWorkspace.Section), meeting(UUID)
}

enum NativeDesktopError: LocalizedError {
    case cleanupFailed, ambiguousEngine, unavailable(String)
    var errorDescription: String? {
        switch self {
        case .cleanupFailed: NSLocalizedString("Media could not stop cleanly. Quit and reopen Rock'N'Roll for Mac before joining another meeting.", comment: "")
        case .ambiguousEngine: NSLocalizedString("The meeting engine could not be identified. Choose its engine before joining.", comment: "")
        case .unavailable(let message): message
        }
    }
}

/// Menu bar glyph from the app icon's two-comma swirl; a center dot marks a live
/// meeting. Template rendering lets macOS tint it for every menu bar appearance.
enum NativeDesktopStatusIcon {
    static func image(live: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let context = NSGraphicsContext.current else { return false }
            // Geometry is authored on a 100-unit square, y down, centred at (50, 50).
            var scale = AffineTransform(scaleByX: rect.width / 100, byY: rect.height / 100)
            scale.append(AffineTransform(translationByX: rect.minX, byY: rect.minY))
            let first = comma(), second = comma()
            var turn = AffineTransform(translationByX: 100, byY: 100)
            turn.prepend(AffineTransform(scaleByX: -1, byY: -1))
            second.forEach { $0.transform(using: turn) }
            for path in first + second { path.transform(using: scale) }
            NSColor.black.setFill(); NSColor.black.setStroke()
            first.forEach { $0.fill() }
            // A thin knockout where one head overlaps the other's tail, as in the app icon.
            context.compositingOperation = .clear
            for path in second { path.lineWidth = 6 * rect.width / 100; path.stroke(); path.fill() }
            context.compositingOperation = .sourceOver
            second.forEach { $0.fill() }
            if live {
                let radius = 8 * rect.width / 100
                NSBezierPath(ovalIn: NSRect(x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = live ? L("Rock'N'Roll for Mac · In a meeting") : "Rock'N'Roll for Mac"
        return image
    }
    /// One swirl half: an outer arc, a tapering inner arc and a round head.
    private static func comma() -> [NSBezierPath] {
        let center = CGPoint(x: 50, y: 50), inner = CGPoint(x: 45.31, y: 58.83)
        let tail = CGPoint(x: 28.80, y: 83.92), end = CGPoint(x: 70.00, y: 15.36), headInner = CGPoint(x: 60.14, y: 32.72)
        func angle(_ from: CGPoint, _ to: CGPoint) -> CGFloat { atan2(to.y - from.y, to.x - from.x) * 180 / .pi }
        let body = NSBezierPath()
        body.move(to: tail)
        body.appendArc(withCenter: center, radius: 40, startAngle: angle(center, tail), endAngle: angle(center, end), clockwise: false)
        body.line(to: headInner)
        body.appendArc(withCenter: inner, radius: 30.03, startAngle: angle(inner, headInner), endAngle: angle(inner, tail), clockwise: true)
        body.close()
        let head = NSBezierPath(ovalIn: NSRect(x: 63.56 - 11.18, y: 26.63 - 11.18, width: 22.36, height: 22.36))
        return [body, head]
    }
}
