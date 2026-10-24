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
    @Published var selection: Section = .home
    @Published var invitation = ""
    @Published var settingsTab = 0
    @Published var error: String?
    @Published private(set) var preparing = false
    @Published private(set) var meeting: NativeDesktopMeetingModel?
    private var window: NSWindow?
    private var meetingWindow: NativeDesktopMeetingWindow?
    private var statusItem: NSStatusItem?
    private var menuSubscriptionInstalled = false
    private var leaveTask: Task<Bool, Never>?
    private var joinTask: Task<Void, Never>?
    private var joinGeneration = UUID()
    private var subscriptions = Set<AnyCancellable>()
    private var renderedMeetingState: String?
    private var meetingSubscription: AnyCancellable?
    private var keyMonitor: Any?
    private var activity: NSUserActivity?
    private var sessionID = UUID()
    private var shutdownBlocked = false
    private let reminderPresenter = NativeDesktopReminderPresenter()
    private var pendingScheduled: NativeDesktopScheduledJoin?
    private let detect: @MainActor (URL) async throws -> MeetingEngineDetection
    private let makeMeeting: @MainActor (JoinDestination, String, String?, Bool) -> NativeDesktopMeetingModel

    init(library: NativeDesktopLibrary? = nil,
         detect: @escaping @MainActor (URL) async throws -> MeetingEngineDetection = { try await VendorEndpointResolver.makeDetector().detect($0) },
         makeMeeting: (@MainActor (JoinDestination, String, String?, Bool) -> NativeDesktopMeetingModel)? = nil) {
        let library = library ?? NativeDesktopLibrary()
        self.library = library; self.detect = detect
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
        library.canAutomaticallyJoin = { [weak self] in self?.meeting == nil && self?.preparing == false }
        library.continuation.onSnapshot = { [weak self] in self?.continuationSnapshot() }
        library.continuation.onJoinTarget = { [weak self] jam, quiet in
            guard let self, !preparing, meeting == nil else { return nil }
            join(jam.invitation, engine: jam.engine, title: jam.title, quiet: quiet)
            return sessionID
        }
        library.continuation.onPrepareSource = { [weak self] id in
            guard let self, self.sessionID == id, let meeting else { throw CancellationError() }
            try await meeting.setTransferHeld(true)
        }
        library.continuation.onResumeSource = { [weak self] id, restoreSending in
            guard self?.sessionID == id else { return }; try? await self?.meeting?.setTransferHeld(false, restoreSending: restoreSending)
        }
        library.continuation.onLeaveSource = { [weak self] id, _ in
            guard self?.sessionID == id else { return false }; return await self?.leave() ?? false
        }
        library.continuation.onCancelTarget = { [weak self] _, id in
            guard let self, id == sessionID else { return false }; return await leave()
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
            value.delegate = self; value.title = "Rock’n’Roll"; value.minSize = NSSize(width: 760, height: 540)
            value.isReleasedWhenClosed = false; value.titlebarAppearsTransparent = true
            value.contentView = NSHostingView(rootView: NativeDesktopHomeView(workspace: self, library: library))
            value.setFrameAutosaveName("nativeDesktop.library"); value.center(); window = value
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        library.calendar.showingMacSettings = selection == .settings
        library.setup.finishLaunch(hasMeetingIntent: preparing || meeting != nil)
        library.foregrounded(allowAutomaticJoin: selection == .home)
        library.setup.offerIfAppropriate(selection == .home && meeting == nil)
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
              quiet: Bool = false, scheduled: NativeDesktopScheduledJoin? = nil) {
        guard !preparing, leaveTask == nil, !shutdownBlocked else { scheduled?.finish(); return }
        if scheduled != nil, meeting != nil { scheduled?.finish(); return }
        if let meeting {
            if MeetingRoomIdentity(url, engine: known) == MeetingRoomIdentity(meeting.invitation, engine: meeting.kind) {
                showMeeting(); return
            }
            let alert = NSAlert(); alert.messageText = L("Join another meeting?")
            alert.informativeText = L("Your current meeting will end before joining the next one.")
            alert.addButton(withTitle: L("Switch meeting")); alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
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
            do {
                if meeting != nil, !(await leaveActive()) { throw NativeDesktopError.cleanupFailed }
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
                let name = library.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard destination.engineKind.inputPolicy.accepts(name: name) else { throw NativeGuestEntryError.invalidName }
                let model = makeMeeting(destination, name, title, quiet)
                meeting = model; ownedModel = model
                model.onLeave = { [weak self] in _ = await self?.leave() }
                meetingSubscription = model.objectWillChange.sink { [weak self] in
                    Task { @MainActor in self?.meetingDidChange() }
                }
                meetingWindow = NativeDesktopMeetingWindow(model: model, continuation: library.continuation)
                if scheduled != nil && !NSApp.isActive { model.setMediaVisible(false); refreshMenu() }
                else { showMeeting() }
                guard scheduled?.admission() != false else { throw CancellationError() }
                try await model.connect()
                try Task.checkCancellation()
                guard token == joinGeneration, meeting === model, scheduled?.admission() != false else { throw CancellationError() }
                // Commit only after final admission, including same-turn revocation.
                pendingScheduled = nil
                library.recordJoin(invitation: model.invitation, title: model.title,
                    identifier: destination.roomIdentifier, engine: model.kind, eventID: eventID)
                library.continuation.targetDidConnect(invitation: model.invitation, sessionID: requestedSession)
                updateContinuation()
            } catch {
                if token == joinGeneration, !(error is CancellationError) { self.error = error.localizedDescription }
                if token == joinGeneration, requestedSession == sessionID { library.continuation.targetDidFail() }
                if let ownedModel, meeting === ownedModel { _ = await leaveActive() }
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
    @discardableResult func leave() async -> Bool {
        if let leaveTask { return await leaveTask.value }
        let pending = joinTask, owned = meeting
        joinTask = nil; joinGeneration = UUID(); preparing = true
        let cleanup = Task { @MainActor in
            pending?.cancel(); await pending?.value
            if let owned, self.meeting === owned { return await self.leaveActive() }
            return !self.shutdownBlocked
        }
        leaveTask = cleanup
        let clean = await cleanup.value
        leaveTask = nil; preparing = false
        return clean
    }
    private func leaveActive() async -> Bool {
        guard let old = meeting else { return !shutdownBlocked }
        let clean = await old.leave()
        guard meeting === old else { return clean }
        shutdownBlocked = !clean
        if clean {
            meetingWindow?.close(); meetingWindow = nil; meeting = nil; meetingSubscription = nil; renderedMeetingState = nil
            library.continuation.updateCurrent(nil)
        } else { error = NativeDesktopError.cleanupFailed.localizedDescription }
        refreshMenu(); return clean
    }
    func showMeeting() { meetingWindow?.show(); refreshMenu() }
    func activate() { library.foregrounded(); if meeting != nil { showMeeting() } else { show() } }
    func backgrounded() { library.backgrounded() }
    func cloudNotification() async { await library.sync.synchronizeForNotification(); await library.continuation.refresh() }
    func handleURL(_ url: URL) { show(); invitation = url.absoluteString; joinInput() }

    private func continuationSnapshot() -> ActiveJam? {
        guard let meeting, meeting.snapshot.phase == .connected else { return nil }
        return ActiveJam(deviceID: library.sync.deviceID, sessionID: sessionID, invitation: meeting.invitation,
            title: meeting.title, name: meeting.displayName, deviceLabel: Host.current().localizedName ?? "Mac",
            isSharingScreen: meeting.snapshot.sharing, supportsCompanion: true,
            audioPaused: !meeting.snapshot.playoutOn, engine: meeting.kind)
    }
    private func meetingDidChange() {
        guard let meeting else { return }
        let state = [meeting.sessionID.uuidString, meeting.title, meeting.snapshot.phase.rawValue,
            String(meeting.snapshot.microphoneOn), String(meeting.snapshot.cameraOn), String(meeting.snapshot.sharing),
            String(meeting.snapshot.playoutOn), String(meeting.participants.count), String(describing: meeting.localCamera.map(ObjectIdentifier.init))].joined(separator: "|")
        guard state != renderedMeetingState else { return }
        renderedMeetingState = state; objectWillChange.send(); refreshMenu(); updateContinuation()
    }
    private func updateContinuation() { library.continuation.updateCurrent(continuationSnapshot()) }
    private func publishHandoff(_ jam: ActiveJam?) {
        activity?.invalidate(); activity = nil
        guard library.continuation.isAvailable, let jam else { return }
        let value = NativeDesktopHandoff.activity(for: jam)
        value.becomeCurrent(); activity = value
    }
    func continueActivity(_ userActivity: NSUserActivity) -> Bool {
        guard let reference = NativeDesktopHandoff.reference(in: userActivity) else { return false }
        show(); Task {
            await library.continuation.refresh()
            guard library.continuation.candidates.contains(where: { $0.deviceID == reference.deviceID && $0.sessionID == reference.sessionID }) else {
                error = L("This meeting is no longer available on the other device."); return
            }
            selection = .home
        }; return true
    }
    private func installKeyboard() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let meeting, event.isARepeat == false else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let shortcut = event.charactersIgnoringModifiers?.lowercased() == "m" && modifiers == [.command, .shift]
            let typing = NSApp.keyWindow?.firstResponder is NSTextView || NSApp.keyWindow?.firstResponder is NSTextField
            if shortcut || (event.keyCode == 49 && modifiers.isEmpty && !typing && meetingWindow?.isKeyWindow == true) {
                meeting.toggleMicrophone(); return nil
            }
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
        guard library.calendar.keepInMenuBar || meeting != nil || preparing else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil; return
        }
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem?.button?.image = NSImage(systemSymbolName: "video", accessibilityDescription: "Rock’n’Roll")
        }
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) {
            let row = NSMenuItem(title: title, action: action, keyEquivalent: ""); row.target = self; menu.addItem(row)
        }
        if let meeting {
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
        menu.addItem(.separator()); item(L("Open Rock’n’Roll"), #selector(openHome))
        item(L("Settings…"), #selector(openSettings)); menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit Rock’n’Roll"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit); statusItem?.menu = menu
    }
    @objc private func openHome() { show() }
    @objc private func openSettings() { show(section: .settings) }
    @objc private func openMeeting() { showMeeting() }
    @objc private func toggleMic() { meeting?.toggleMicrophone() }
    @objc private func leaveFromMenu() { Task { _ = await leave() } }
    @objc private func skipSuggested() { if let next = library.calendar.suggestedMenuMeeting { library.calendar.suppressAutomaticJoin(for: next) } }
    @objc private func pauseSchedule() { library.calendar.pauseScheduledJoiningToday() }
    @objc private func resumeSchedule() { library.calendar.resumeScheduledJoining() }
    @objc private func joinSuggested() { if let next = library.calendar.suggestedMenuMeeting { library.open(next) } }
}

enum NativeDesktopError: LocalizedError {
    case cleanupFailed, ambiguousEngine, unavailable(String)
    var errorDescription: String? {
        switch self {
        case .cleanupFailed: "Media could not stop cleanly. Quit and reopen Rock’n’Roll before joining another meeting."
        case .ambiguousEngine: "The meeting engine could not be identified. Choose its engine before joining."
        case .unavailable(let message): message
        }
    }
}
