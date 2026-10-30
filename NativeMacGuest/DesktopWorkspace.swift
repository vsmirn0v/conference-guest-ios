import AppKit
import Combine
import ConferenceCore
import SwiftUI
import UserNotifications

@MainActor final class NativeDesktopWorkspace: NSObject, ObservableObject, NSWindowDelegate {
    enum Section: String, CaseIterable, Identifiable {
        case home = "Home", favorites = "Favorites", calendar = "Calendar", recent = "Recent meetings", settings = "Settings"
        var id: Self { self }
        var symbol: String {
            switch self { case .home: "house"; case .favorites: "star"; case .calendar: "calendar"; case .recent: "clock"; case .settings: "gearshape" }
        }
    }
    let library: NativeDesktopLibrary
    var mayAdmitMeeting: () -> Bool = { true }
    var onUpdateActivityChanged: () -> Void = {}
    var busyForUpdate: Bool { preparing || !meetings.isEmpty || leaveTask != nil || !meetingLeaves.isEmpty || shutdownBlocked }
    #if NATIVE_DIRECT_UPDATES
    var updates: NativeDesktopUpdates?
    #endif
    @Published var selection: Section = .home
    @Published var invitation = ""
    @Published var settingsTab = 0
    @Published var error: String?
    @Published private(set) var preparing = false { didSet { onUpdateActivityChanged() } }
    /// Simultaneous meetings in join order. One talk meeting holds mic and camera.
    @Published private(set) var meetings: [NativeDesktopMeetingModel] = [] { didSet { onUpdateActivityChanged() } }
    @Published private(set) var talkID: UUID?
    var talkMeeting: NativeDesktopMeetingModel? { meetings.first { $0.sessionID == talkID } }
    /// The meeting single-meeting surfaces act on: the talk meeting, else the latest.
    var meeting: NativeDesktopMeetingModel? { talkMeeting ?? meetings.last }
    static let meetingLimit = 4
    private let multipleMeetings: () -> Bool
    private var window: NSWindow?
    private var meetingWindows: [UUID: NativeDesktopMeetingWindow] = [:]
    private var meetingSubscriptions: [UUID: AnyCancellable] = [:]
    private var renderedMeetingStates: [UUID: String] = [:]
    private var continuationSessions: [UUID: UUID] = [:]
    private var meetingLeaves: [UUID: Task<Bool, Never>] = [:] { didSet { onUpdateActivityChanged() } }
    private var handover: Task<Bool, Never>?
    private weak var joiningModel: NativeDesktopMeetingModel?
    private var statusItem: NSStatusItem?
    private var statusIconLive: Bool?
    private var menuSubscriptionInstalled = false
    private var leaveTask: Task<Bool, Never>?
    private var joinTask: Task<Void, Never>?
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
         multipleMeetings: @escaping () -> Bool = { UserDefaults.standard.object(forKey: "nativeDesktop.multipleMeetings") as? Bool ?? true }) {
        let library = library ?? NativeDesktopLibrary()
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
            guard let self, pendingScheduled != nil else { return }
            joinTask?.cancel()
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
    }

    func show(section: Section? = nil) {
        if let section { selection = section }
        if window == nil {
            let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            value.delegate = self; value.title = "Rock'N'Roll for Mac"; value.minSize = NSSize(width: 760, height: 540)
            value.isReleasedWhenClosed = false; value.titlebarAppearsTransparent = true
            value.contentView = NSHostingView(rootView: NativeDesktopHomeView(workspace: self, library: library))
            value.setFrameAutosaveName("nativeDesktop.library"); value.center(); window = value
            NativeDesktopForegroundMedia.shared.setHomeWindow(value)
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        library.calendar.showingMacSettings = selection == .settings
        library.setup.finishLaunch(hasMeetingIntent: preparing || !meetings.isEmpty)
        library.foregrounded(allowAutomaticJoin: selection == .home)
        library.setup.offerIfAppropriate(selection == .home && meetings.isEmpty)
        installMenuBar(); installKeyboard()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        library.calendar.showingMacSettings = false
        if library.setup.isPresented { library.setup.finishLater() }
        return true
    }
    func windowDidMiniaturize(_ notification: Notification) { library.calendar.showingMacSettings = false }
    func windowDidDeminiaturize(_ notification: Notification) { library.calendar.showingMacSettings = selection == .settings }
    func joinInput() {
        do { let destination = try library.normalizedDestination(invitation); join(destination.invitationURL) }
        catch { self.error = error.localizedDescription }
    }
    func join(_ url: URL, engine known: MeetingEngineKind? = nil, title: String? = nil, eventID: String? = nil,
              quiet: Bool = false, scheduled: NativeDesktopScheduledJoin? = nil, nameOverride: String? = nil) {
        guard mayAdmitMeeting() else {
            scheduled?.finish(); error = L("An update is being installed. Please try again after Rock'N'Roll for Mac restarts."); return
        }
        guard !preparing, leaveTask == nil, meetingLeaves.isEmpty, !shutdownBlocked else { scheduled?.finish(); return }
        // Calendar automation never adds a second meeting; a reminder's Join does.
        if scheduled != nil, !meetings.isEmpty { scheduled?.finish(); return }
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
        preparing = true; error = nil; sessionID = UUID(); joinGeneration = UUID(); pendingScheduled = scheduled
        let token = joinGeneration, requestedSession = sessionID
        joinTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                scheduled?.finish()
                if joinGeneration == token { preparing = false; joinTask = nil; pendingScheduled = nil }
            }
            var ownedModel: NativeDesktopMeetingModel?
            defer { if let ownedModel, joiningModel === ownedModel { joiningModel = nil } }
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
                ownedModel = model; joiningModel = model
                let concurrent = !meetings.isEmpty, owns = talkMeeting == nil
                if concurrent { model.configureForConcurrentJoin(ownsMicrophone: owns) }
                meetings.append(model); if owns { talkID = model.sessionID }
                continuationSessions[model.sessionID] = requestedSession
                model.microphoneArbiter = { [weak self] target in await self?.claimTalk(for: target) ?? false }
                model.onLeave = { [weak self, weak model] in
                    guard let self, let model else { return }; _ = await leave(model)
                }
                meetingSubscriptions[model.sessionID] = model.objectWillChange.sink { [weak self, weak model] in
                    Task { @MainActor in if let model { self?.meetingDidChange(model) } }
                }
                meetingWindows[model.sessionID] = NativeDesktopMeetingWindow(model: model, continuation: library.continuation, workspace: self)
                if scheduled != nil && !NSApp.isActive { model.setMediaVisible(false); refreshMenu() }
                else { showMeeting(model) }
                guard scheduled?.admission() != false else { throw CancellationError() }
                try await model.connect()
                try Task.checkCancellation()
                guard token == joinGeneration, meetings.contains(where: { $0 === model }), scheduled?.admission() != false else { throw CancellationError() }
                // Commit only after final admission, including same-turn revocation.
                pendingScheduled = nil
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
        let pending = joinTask
        joinTask = nil; joinGeneration = UUID(); preparing = true
        let cleanup = Task { @MainActor in
            pending?.cancel(); await pending?.value
            return await self.leaveAllMeetings()
        }
        leaveTask = cleanup
        let clean = await cleanup.value
        leaveTask = nil; preparing = false
        return clean
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
        if joiningModel === model { joinTask?.cancel() }
        let task = Task { @MainActor () -> Bool in
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
            if let current = talkMeeting, current !== target {
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
    func showMeeting(_ model: NativeDesktopMeetingModel) {
        let visible = meetingWindows.first { $0.key != model.sessionID && $0.value.isVisible }?.value
        meetingWindows[model.sessionID]?.show(tabbedWith: visible); refreshMenu()
    }
    func leaveAllConfirmed() {
        let alert = NSAlert(); alert.messageText = L("Leave all meetings?")
        alert.addButton(withTitle: L("Leave all")); alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { _ = await leave() }
    }
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
            let typing = NSApp.keyWindow?.firstResponder is NSTextView || NSApp.keyWindow?.firstResponder is NSTextField
            if key == "m" && modifiers == [.command, .shift] { (keyMeeting ?? fallback).toggleMicrophone(); return nil }
            if key == "s" && modifiers == [.command, .shift], let keyMeeting { keyMeeting.togglePlayout(); return nil }
            if modifiers == [.command, .control], let digit = key.flatMap(Int.init), digit >= 1, digit <= meetings.count {
                showMeeting(meetings[digit - 1]); return nil
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
            item(L("Leave all meetings…"), #selector(leaveAllFromMenu))
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
    @objc private func openSettings() { show(section: .settings) }
    @objc private func openMeeting() { showMeeting() }
    @objc private func toggleMic() { meeting?.toggleMicrophone() }
    @objc private func leaveFromMenu() { Task { _ = await leave() } }
    @objc private func leaveAllFromMenu() { leaveAllConfirmed() }
    private func menuMeeting(_ sender: NSMenuItem) -> NativeDesktopMeetingModel? {
        meetings.first { $0.sessionID == sender.representedObject as? UUID }
    }
    @objc private func showMeetingItem(_ sender: NSMenuItem) { if let model = menuMeeting(sender) { showMeeting(model) } }
    @objc private func toggleMicItem(_ sender: NSMenuItem) { menuMeeting(sender)?.toggleMicrophone() }
    @objc private func toggleSoundItem(_ sender: NSMenuItem) { menuMeeting(sender)?.togglePlayout() }
    @objc private func leaveItem(_ sender: NSMenuItem) {
        guard let model = menuMeeting(sender) else { return }; Task { _ = await leave(model) }
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
