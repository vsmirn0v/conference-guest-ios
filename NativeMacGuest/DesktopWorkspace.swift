import AppKit
import Combine
import ConferenceCore
import SwiftUI
import UserNotifications

@MainActor final class NativeDesktopWorkspace: NSObject, ObservableObject, NSWindowDelegate {
    enum Section: String, CaseIterable, Identifiable {
        case home = "Home", assistant = "Assistant", favorites = "Favorites", calendar = "Calendar", recent = "Recent meetings", settings = "Settings"
        var id: Self { self }
        var symbol: String {
            switch self { case .home: "house"; case .assistant: "tray"; case .favorites: "star"; case .calendar: "calendar"; case .recent: "clock"; case .settings: "gearshape" }
        }
    }
    let library: NativeDesktopLibrary
    /// Judges the meetings you are not looking at and raises attention cards.
    let attention: AttentionCoordinator
    var mayAdmitMeeting: () -> Bool = { true }
    var onUpdateActivityChanged: () -> Void = {}
    var busyForUpdate: Bool { preparing || !meetings.isEmpty || leaveTask != nil || !meetingLeaves.isEmpty || shutdownBlocked }
    #if NATIVE_DIRECT_UPDATES
    var updates: NativeDesktopUpdates?
    #endif
    /// The local MCP server that lets AI clients work with meetings; set once it starts.
    var mcpService: NativeDesktopMCPService?
    /// A library section is shown unless a meeting is selected in the sidebar.
    @Published var selection: Section = .home { didSet { if selectedMeetingID != nil { selectedMeetingID = nil } } }
    /// The meeting shown in the main window's detail column.
    @Published private(set) var selectedMeetingID: UUID? {
        didSet { if oldValue != selectedMeetingID { synchronizeMeetingPresentation() } }
    }
    @Published var invitation = ""
    @Published var settingsTab = 0
    @Published var error: String?
    /// An informational alert, such as a meeting the organizer ended.
    @Published var notice: (title: String, message: String)?
    /// A join is in flight (setting up or connecting), or every meeting is being left.
    @Published private(set) var preparing = false { didSet { onUpdateActivityChanged() } }
    /// A join is detecting its service or asking about it; the next join waits for
    /// this short step only. Connecting does not hold up another join.
    @Published private(set) var joinSettingUp = false
    /// Simultaneous meetings in join order. One talk meeting holds mic and camera.
    @Published private(set) var meetings: [NativeDesktopMeetingModel] = [] { didSet { onUpdateActivityChanged() } }
    @Published private(set) var talkID: UUID?
    var talkMeeting: NativeDesktopMeetingModel? { meetings.first { $0.sessionID == talkID } }
    /// The meeting single-meeting surfaces act on: the talk meeting, else the latest.
    var meeting: NativeDesktopMeetingModel? { talkMeeting ?? meetings.last }
    static let meetingLimit = 4
    private let multipleMeetings: () -> Bool
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
    private let reminderPresenter = NativeDesktopReminderPresenter()
    private var pendingScheduled: NativeDesktopScheduledJoin?
    private let detect: @MainActor (URL) async throws -> MeetingEngineDetection
    private let makeMeeting: @MainActor (JoinDestination, String, String?, Bool) -> NativeDesktopMeetingModel
    private let makeHandoffActivity: @MainActor (ActiveJam) -> NSUserActivity

    init(library: NativeDesktopLibrary? = nil,
         detect: @escaping @MainActor (URL) async throws -> MeetingEngineDetection = { try await VendorEndpointResolver.makeDetector().detect($0) },
         makeMeeting: (@MainActor (JoinDestination, String, String?, Bool) -> NativeDesktopMeetingModel)? = nil,
         makeHandoffActivity: @escaping @MainActor (ActiveJam) -> NSUserActivity = { NativeDesktopHandoff.activity(for: $0) },
         multipleMeetings: @escaping () -> Bool = { UserDefaults.standard.object(forKey: "nativeDesktop.multipleMeetings") as? Bool ?? true },
         attention: AttentionCoordinator? = nil) {
        let library = library ?? NativeDesktopLibrary()
        self.attention = attention ?? AttentionCoordinator()
        // The agent's read-only calendar tools see future occurrences; they never join or edit.
        self.attention.calendarOccurrences = { [weak library] in
            (library?.calendar.meetings ?? []).filter { $0.start > Date() }
        }
        self.multipleMeetings = multipleMeetings
        self.library = library; self.detect = detect; self.makeHandoffActivity = makeHandoffActivity
        self.makeMeeting = makeMeeting ?? { NativeDesktopMeetingModel(destination: $0, name: $1, title: $2, quiet: $3) }
        super.init()
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
            join(jam.invitation, engine: jam.engine, title: jam.title, quiet: quiet, nameOverride: jam.name)
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
        library.calendar.reminders.activeRoom = { [weak self] in self?.meeting.flatMap { MeetingRoomIdentity($0.invitation, engine: $0.kind) } }
        library.calendar.reminders.scene = { [weak self] in
            let active = self?.meeting.flatMap { MeetingRoomIdentity($0.invitation, engine: $0.kind) }
            return ReminderScene(visible: NSApp.isActive, room: active,
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
        // Store and assistant publishes (a seen-mark, a keystroke in an outcome) must not
        // invalidate the whole workspace. Views that read them observe those objects.
        self.attention.start()
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
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "attention-" + card.id.uuidString, content: content, trigger: nil))
    }

    func show(section: Section? = nil) {
        if let section { selection = section }
        presentMainWindow()
        library.calendar.showingMacSettings = selection == .settings
        library.setup.finishLaunch(hasMeetingIntent: preparing || !meetings.isEmpty)
        library.foregrounded(allowAutomaticJoin: selection == .home)
        library.setup.offerIfAppropriate(selection == .home && meetings.isEmpty)
    }
    /// The one main window holds the library and every embedded meeting.
    private func presentMainWindow() {
        if window == nil {
            let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            value.delegate = self; value.title = "Rock'N'Roll for Mac"; value.minSize = NSSize(width: 900, height: 560)
            value.isReleasedWhenClosed = false; value.titlebarAppearsTransparent = true
            value.contentView = NSHostingView(rootView: NativeDesktopHomeView(workspace: self, library: library))
            value.setFrameAutosaveName("nativeDesktop.library"); value.center(); window = value
            NativeDesktopForegroundMedia.shared.setHomeWindow(value)
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        installMenuBar(); installKeyboard(); synchronizeMeetingPresentation()
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
    func join(_ url: URL, engine known: MeetingEngineKind? = nil, title: String? = nil, eventID: String? = nil,
              quiet: Bool = false, scheduled: NativeDesktopScheduledJoin? = nil, nameOverride: String? = nil) {
        guard mayAdmitMeeting() else {
            scheduled?.finish(); error = L("An update is being installed. Please try again after Rock'N'Roll for Mac restarts."); return
        }
        guard leaveTask == nil, meetingLeaves.isEmpty, !shutdownBlocked else { scheduled?.finish(); return }
        // Calendar automation never adds a second meeting; a reminder's Join does.
        if scheduled != nil, preparing || !meetings.isEmpty { scheduled?.finish(); return }
        if joinSettingUp {
            // Asked for while another join is still finding its service: it starts
            // right after that step, without waiting for the other to connect.
            queuedJoin = { [weak self] in
                self?.join(url, engine: known, title: title, eventID: eventID, quiet: quiet, nameOverride: nameOverride)
            }
            return
        }
        let room = MeetingRoomIdentity(url, engine: known)
        if let existing = meetings.first(where: { MeetingRoomIdentity($0.invitation, engine: $0.kind) == room }) {
            showMeeting(existing); return
        }
        let replacing = !meetings.isEmpty && !multipleMeetings()
        if replacing {
            let alert = NSAlert(); alert.messageText = L("Join another meeting?")
            alert.informativeText = L("Your current meeting will end before joining the next one.")
            alert.addButton(withTitle: L("Switch meeting")); alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        } else if meetings.count >= Self.meetingLimit {
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
            do {
                if replacing, !(await leaveAllMeetings()) { throw NativeDesktopError.cleanupFailed }
                try Task.checkCancellation(); guard token == joinGeneration else { return }
                guard scheduled?.admission() != false else { throw CancellationError() }
                let detection = try await detect(url)
                try Task.checkCancellation(); guard token == joinGeneration else { return }
                let destination: JoinDestination
                if let resolved = try JoinDestination.resolve(url, detection: detection, knownEngine: known) { destination = resolved }
                else {
                    guard scheduled == nil else { throw NativeDesktopError.ambiguousEngine }
                    destination = try chooseEngine(for: url)
                }
                try Task.checkCancellation()
                let name = (nameOverride ?? library.displayName).trimmingCharacters(in: .whitespacesAndNewlines)
                guard destination.engineKind.inputPolicy.accepts(name: name) else { throw NativeGuestEntryError.invalidName }
                let model = makeMeeting(destination, name, title, quiet)
                ownedModel = model; joinModels[joinID] = ObjectIdentifier(model)
                model.calendarSeriesID = eventID.flatMap { id in library.calendar.meetings.first { $0.id == id }?.seriesID }
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
                library.recordJoin(invitation: model.invitation, title: model.title,
                    identifier: destination.roomIdentifier, engine: model.kind, eventID: eventID)
                library.continuation.targetDidConnect(invitation: model.invitation, sessionID: requestedSession)
                updateContinuation()
            } catch {
                if token == joinGeneration, !(error is CancellationError) { self.error = error.localizedDescription }
                if token == joinGeneration, requestedSession == sessionID { library.continuation.targetDidFail() }
                if let ownedModel, meetings.contains(where: { $0 === ownedModel }) { _ = await leave(ownedModel) }
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
        if preparing != busy { preparing = busy }
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
    @discardableResult func leave(_ model: NativeDesktopMeetingModel) async -> Bool {
        let id = model.sessionID
        if let task = meetingLeaves[id] { return await task.value }
        for (joinID, owner) in joinModels where owner == ObjectIdentifier(model) { joinTasks[joinID]?.cancel() }
        let task = Task { @MainActor () -> Bool in
            attention.captureOutcome(for: model)
            let clean = await model.leave()
            guard self.meetings.contains(where: { $0 === model }) else { return clean }
            if clean {
                self.meetings.removeAll { $0 === model }
                self.meetingWindows.removeValue(forKey: id)?.close()
                self.meetingSubscriptions[id] = nil; self.renderedMeetingStates[id] = nil; self.continuationSessions[id] = nil
                if self.talkID == id { self.talkID = nil }
                if self.talkID == nil, self.meetings.count == 1, let survivor = self.meetings.first {
                    _ = await self.claimTalk(for: survivor)
                }
                if self.selectedMeetingID == id { self.selectedMeetingID = (self.talkMeeting ?? self.meetings.last)?.sessionID }
                self.synchronizeMeetingPresentation()
                self.updateContinuation()
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
        if host.isEmbedded { host.show() }
        else { host.show(tabbedWith: meetingWindows.first { $0.key != model.sessionID && !$0.value.isEmbedded && $0.value.isVisible }?.value) }
        refreshMenu()
    }
    var selectedMeeting: NativeDesktopMeetingModel? { meetings.first { $0.sessionID == selectedMeetingID } }
    var embeddedMeetings: [NativeDesktopMeetingModel] { meetings.filter { meetingWindows[$0.sessionID]?.isEmbedded == true } }
    func isDetached(_ model: NativeDesktopMeetingModel) -> Bool { meetingWindows[model.sessionID]?.detached == true }
    /// While most library sections are shown, the talk meeting (else the latest)
    /// stays in a small floating preview. Assistant keeps its composer unobstructed;
    /// Mini meeting remains available through the explicit meeting action.
    var previewMeeting: NativeDesktopMeetingModel? {
        guard selection != .assistant, selectedMeeting == nil else { return nil }
        let candidates = meetings.filter { meetingWindows[$0.sessionID].map { $0.isEmbedded && !$0.isMiniVisible } ?? false }
        return candidates.first { $0.sessionID == talkID } ?? candidates.last
    }
    var sidebarSelection: NativeDesktopSidebarItem? {
        get { selectedMeetingID.map(NativeDesktopSidebarItem.meeting) ?? .section(selection) }
        set {
            // The sidebar List writes its selection back during view updates;
            // republishing an unchanged value would re-render it in a loop.
            guard newValue != sidebarSelection else { return }
            switch newValue {
            case .section(let section)?: selection = section
            case .meeting(let id)?:
                guard let model = meetings.first(where: { $0.sessionID == id }) else { return }
                selectedMeetingID = id
                if isDetached(model) { showMeeting(model) }
            case nil: break
            }
        }
    }
    func presentEmbedded(_ model: NativeDesktopMeetingModel) {
        guard meetings.contains(where: { $0 === model }) else { return }
        objectWillChange.send()
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
    func showMini(_ model: NativeDesktopMeetingModel) { meetingWindows[model.sessionID]?.showMini() }
    /// Only the selected meeting in a visible main window renders full video.
    func synchronizeMeetingPresentation() {
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        let shown = visible ? selectedMeeting : nil, preview = visible ? previewMeeting : nil
        for model in meetings {
            meetingWindows[model.sessionID]?.synchronizeEmbedded(shown: model === shown, preview: model === preview)
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
    func cloudNotification() async { await library.sync.synchronizeForNotification(); await library.continuation.refresh() }
    func handleURL(_ url: URL) { show(); invitation = url.absoluteString; joinInput() }

    /// Handoff and active-jam reporting describe the talk meeting (else the latest).
    private func continuationSnapshot() -> ActiveJam? {
        guard let meeting, meeting.snapshot.phase == .connected,
              let session = continuationSessions[meeting.sessionID] else { return nil }
        return ActiveJam(deviceID: library.sync.deviceID, sessionID: session, invitation: meeting.invitation,
            title: meeting.title, name: meeting.displayName, deviceLabel: Host.current().localizedName ?? "Mac",
            isSharingScreen: meeting.snapshot.sharing, supportsCompanion: true,
            audioPaused: !meeting.snapshot.playoutOn, engine: meeting.kind)
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
        case .cleanupFailed: "Media could not stop cleanly. Quit and reopen Rock'N'Roll for Mac before joining another meeting."
        case .ambiguousEngine: "The meeting engine could not be identified. Choose its engine before joining."
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
