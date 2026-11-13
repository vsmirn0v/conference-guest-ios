import AppKit
import Foundation
import AVFoundation
import UniformTypeIdentifiers

@main
struct NativeGuestApplication {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--check-voice-worker") {
            Task.detached {
                do {
                    let child = try ClonedVoiceWorkerProcess()
                    let cache: ClonedVoiceWorkerOutput
                    do {
                        cache = try await child.execute(.init(operation: .cacheScope), timeout: 5)
                    } catch {
                        await child.stop()
                        throw error
                    }
                    await child.stop()
                    print("PASS: embedded cloned voice worker launched and exited; cache: \(cache.message ?? "unknown")")
                    exit(0)
                } catch {
                    print("FAIL: embedded cloned voice worker (\(error.localizedDescription))")
                    exit(1)
                }
            }
            dispatchMain()
        }
        NativeScreenEncoderQuality.prepare()
        if CommandLine.arguments.contains("--check-container") {
            do {
                let store = try NativeGuestSessionStore.appGroupStore()
                let ticket = NativeGuestTicket(invitationURL: URL(string: "https://example.test/calls/probe")!, displayName: "Container check")
                try store.create(ticket)
                guard try store.consumeTicket(ticket.metadata.sessionID) == ticket else { exit(2) }
                try store.removeSession(ticket.metadata.sessionID)
                print("PASS: signed native companion app-group IO and one-use ticket")
                exit(0)
            } catch { print("FAIL: native companion app-group unavailable (\(error))"); exit(1) }
        }
        #if NATIVE_DIRECT_UPDATES
        if CommandLine.arguments.contains("--check-distribution-cloud") {
            let app = NSApplication.shared; app.setActivationPolicy(.accessory)
            Task { @MainActor in
                do { try await NativeDistributionCloudCheck.run(arguments: CommandLine.arguments); exit(0) }
                catch { print("DISTRIBUTION_CLOUD_FAIL \(error)"); exit(1) }
            }
            app.run(); return
        }
        #endif
        #if DEBUG
        if CommandLine.arguments.contains("--check-capture-permissions") {
            print("Native capture authorization: microphone=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) camera=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
            exit(0)
        }
        if CommandLine.arguments.contains("--check-renderer") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                do {
                    let count = try await CompanionRendererCheck.run()
                    print("PASS: native Metal drawable readback, \(count) crop/rotation/mirror fixtures")
                    exit(0)
                } catch { print("FAIL: native renderer fixture (\(error))"); exit(1) }
            }
            app.run(); return
        }
        #endif
        let mode: NativeGuestLaunchMode
        do { mode = try NativeGuestLaunchMode.parse(CommandLine.arguments) }
        catch { fputs("Invalid native guest launch request.\n", stderr); exit(1) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = CompanionAppDelegate(mode: mode)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class CompanionAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let mode: NativeGuestLaunchMode
    private var workspace: NativeDesktopWorkspace?
    private var mcpService: NativeDesktopMCPService?
    private var controller: CompanionMeetingController?
    private var terminating = false
    private var admittingCompanion = false
    private var launched = false
    private var launchURLs: [URL] = []
    private var launchActivity: NSUserActivity?
    #if NATIVE_DIRECT_UPDATES
    private var updates: NativeDesktopUpdates?
    #endif
    private var busyForUpdate: Bool {
        terminating || admittingCompanion || workspace?.busyForUpdate == true || (controller != nil && controller?.finished == false)
    }
    private var companionAdmissionBlock: CompanionMeetingAdmission.Block? {
        CompanionMeetingAdmission.block(admitting: admittingCompanion, finished: controller?.finished,
            cleanupSucceeded: controller?.cleanupSucceeded ?? true)
    }
    private func makeWorkspace() -> NativeDesktopWorkspace {
        let value = NativeDesktopWorkspace()
        value.mayAdmitMeeting = { [weak self] in
            guard let self, !terminating, companionAdmissionBlock == nil else { return false }
            #if NATIVE_DIRECT_UPDATES
            return updates?.mayStartMeeting == true
            #else
            return true
            #endif
        }
        value.meetingAdmissionError = { [weak self] in
            switch self?.companionAdmissionBlock {
            case .active: return L("Finish the companion meeting before joining another meeting.")
            case .failedCleanup: return L("The companion meeting did not stop cleanly. Quit and reopen the app before joining another meeting.")
            case nil: return nil
            }
        }
        #if NATIVE_DIRECT_UPDATES
        value.updates = updates
        value.onUpdateActivityChanged = { [weak self] in
            Task { @MainActor in self?.updates?.activityChanged() }
        }
        #endif
        return value
    }
    init(mode: NativeGuestLaunchMode) { self.mode = mode }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Rock'N'Roll for Mac"
        NativeDiagnosticsLog.shared.start()
        setProbeLogSink { NativeDiagnosticsLog.shared.append($0) }
        NativeDiagnosticReports.shared.onSaved = { probeLog("diagnostic-reports-saved", ["count": $0]) }
        NativeDiagnosticReports.shared.start()
        probeLog("app-launch", ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString])
        let menu = NSMenu(), appMenu = NSMenu(title: appName)
        let item = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        appMenu.addItem(withTitle: L("Quit Rock'N'Roll for Mac"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item)
        let editMenu = NSMenu(title: L("Edit")), editItem = NSMenuItem()
        editMenu.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu; menu.addItem(editItem)
        let windowMenu = NSMenu(title: L("Window")), windowItem = NSMenuItem()
        windowMenu.delegate = self; NativeDesktopWorkspace.addStandardWindowItems(windowMenu)
        windowItem.submenu = windowMenu; menu.addItem(windowItem)
        let helpMenu = NSMenu(title: L("Help")), helpItem = NSMenuItem()
        let diagnostics = NSMenuItem(title: L("Copy Diagnostics"), action: #selector(copyDiagnostics), keyEquivalent: "")
        diagnostics.target = self; helpMenu.addItem(diagnostics)
        let export = NSMenuItem(title: L("Export Diagnostics…"), action: #selector(exportDiagnostics), keyEquivalent: "")
        export.target = self; helpMenu.addItem(export)
        helpItem.submenu = helpMenu; menu.addItem(helpItem); NSApp.helpMenu = helpMenu; NSApp.mainMenu = menu
        let settings = NSMenuItem(title: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; appMenu.insertItem(settings, at: 0)
        let pairMCP = NSMenuItem(title: L("Pair MCP Client…"), action: #selector(pairMCPClient), keyEquivalent: "")
        pairMCP.target = self; appMenu.insertItem(pairMCP, at: 1)
        #if NATIVE_DIRECT_UPDATES
        let check = NSMenuItem(title: L("Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self; appMenu.insertItem(check, at: 1)
        #endif
        let show = NSMenuItem(title: L("Open Rock'N'Roll for Mac"), action: #selector(openHome), keyEquivalent: "n")
        show.target = self; appMenu.insertItem(show, at: 0)
        let pause = NSMenuItem(title: L("Pause All Assistant Participation"),
            action: #selector(pauseAllParticipation), keyEquivalent: "")
        pause.target = self
        appMenu.insertItem(pause, at: max(0, appMenu.numberOfItems - 1))
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        #endif
        #if NATIVE_DIRECT_UPDATES
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("DirectUpdates", isDirectory: true)
            let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
            let safety = try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: build)
            let updates = NativeDesktopUpdates(safety: safety)
            updates.busy = { [weak self] in self?.busyForUpdate ?? true }
            self.updates = updates
            updates.start()
        } catch NativeUpdateSafety.SafetyError.anotherInstanceRunning {
            NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
                .first(where: { $0.processIdentifier != getpid() })?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.terminate(nil); return
        } catch {
            let alert = NSAlert(); alert.messageText = L("Unable to verify update safety")
            alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil); return
        }
        // A newer signed speech-model catalog is used from the next launch.
        Task.detached(priority: .utility) { await ListenModelCatalog.refreshRemote() }
        #endif
        launched = true
        // The speech model's first load after launch is slow (Neural Engine preparation);
        // doing it now, after the window is up, makes the first meeting's transcript start at once.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            // An app or macOS update makes Core AI compile the cloned voice again; start it in the background.
            if UserDefaults.standard.string(forKey: AttentionStore.voiceEngineKey) == VoiceEngine.cloned.rawValue {
                VoiceCloneStore.shared.prepareIfNeeded()
            }
            let listen = ListenModelStore.shared
            guard listen.ready, let model = listen.recognizerModel() else { return }
            LocalSpeechRecognizer.shared.warmUp(model)
        }
        NativeDesktopForegroundMedia.shared.start()
        accept()
        if !launchURLs.isEmpty { let urls = launchURLs; launchURLs.removeAll(); application(NSApp, open: urls) }
        if let activity = launchActivity {
            launchActivity = nil
            _ = application(NSApp, continue: activity, restorationHandler: { _ in })
        }
    }
    private func showJoin(completion: NativeGuestMeetingCompletion? = nil) {
        guard launched, !terminating else { return }
        if workspace == nil {
            workspace = makeWorkspace()
            if let workspace {
                let service = NativeDesktopMCPService(workspace: workspace)
                mcpService = service
                workspace.mcpService = service
                // The assistant's optional MCP tools talk to the same backend in-process.
                workspace.attention.externalToolProvider = AssistantMCPLoopbackProvider(backend: service.toolBackend)
                Task { await service.start() }
            }
        }
        workspace?.show()
        if let completion, completion != .left { workspace?.error = completion.message }
    }
    @objc private func pairMCPClient() {
        showJoin()
        guard let mcpService else { return }
        Task { @MainActor in
            await mcpService.start()
            let instruction = mcpService.makePairingInstruction()
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(instruction, forType: .string)
            let alert = NSAlert(); alert.messageText = L("Pair an AI client")
            alert.informativeText = L("The MCP endpoint and a fresh pairing token were copied to the clipboard. Start rocknroll-native to exchange the token for a scoped client token.")
            alert.addButton(withTitle: L("OK")); alert.runModal()
        }
    }
    private func accept() {
        if mode == .standalone { showJoin(); return }
        #if NATIVE_DIRECT_UPDATES
        guard updates?.mayStartMeeting == true else { showJoin(); return }
        #endif
        admittingCompanion = true
        let sessionID: UUID?
        if case .companion(let id) = mode { sessionID = id } else { sessionID = nil }
        Task { @MainActor in
            defer {
                admittingCompanion = false
                #if NATIVE_DIRECT_UPDATES
                updates?.activityChanged()
                #endif
            }
            do {
                let files = CompanionFiles(store: try NativeGuestSessionStore.appGroupStore())
                guard let ticket = try await files.admit(sessionID, processID: getpid()) else {
                    guard sessionID == nil else { NSApp.terminate(nil); return }
                    showJoin(); return
                }
                guard !terminating else { return }
                let controller = CompanionMeetingController(ticket: ticket, files: files)
                self.controller = controller
                controller.show()
                await controller.start()
            } catch {
                // A direct launch works without a provisioned host container.
                // An explicit host request always fails closed on admission errors.
                if sessionID == nil { showJoin() }
                else {
                    print("Native companion admission failed: \(error is NativeGuestStoreError ? String(describing: error) : "other")")
                    NSApp.terminate(nil)
                }
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        #if NATIVE_DIRECT_UPDATES
        if updates?.safety.installationReserved == true && busyForUpdate { return .terminateCancel }
        #endif
        terminating = true
        Task { @MainActor in
            if let notes = workspace?.attention.store.notes {
                var failures = await notes.flushAll()
                while !failures.isEmpty {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = L("Some notes could not be saved")
                    alert.informativeText = L("Your unsaved text is still in memory. Export a draft or keep editing before quitting.")
                    alert.addButton(withTitle: L("Keep editing"))
                    alert.addButton(withTitle: L("Retry"))
                    alert.addButton(withTitle: L("Export drafts…"))
                    alert.addButton(withTitle: L("Discard unsaved changes"))
                    switch alert.runModal() {
                    case .alertFirstButtonReturn:
                        terminating = false
                        sender.reply(toApplicationShouldTerminate: false)
                        return
                    case .alertSecondButtonReturn:
                        failures = await notes.flushAll()
                    case .alertThirdButtonReturn:
                        for id in failures {
                            let title = workspace?.attention.store.meetingLibrary.cards.first { $0.sessionID == id }?.title ?? L("Meeting notes")
                            _ = MeetingNotesDraftRecovery.export(notes.buffer(sessionID: id), title: title)
                        }
                    case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3):
                        failures.removeAll()
                    default:
                        terminating = false
                        sender.reply(toApplicationShouldTerminate: false)
                        return
                    }
                }
            }
            _ = await workspace?.leave()
            if let controller, !controller.finished { await controller.finish() }
            let clean = await NativeDesktopForegroundMedia.shared.shutdown()
            if !clean { NSLog("Media cleanup was unproven during explicit Quit; process exit releases its devices.") }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        mcpService?.stop()
        workspace?.attention.store.assistant.flushOutcomeEditsSynchronously()
        workspace?.obsidian.stopStatusLoop()
        #if NATIVE_DIRECT_UPDATES
        updates?.willTerminate()
        #endif
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard launched, !terminating else { return true }
        if let controller, !controller.finished { controller.show() }
        else if let workspace { workspace.reopen(hasVisibleWindows: flag) }
        else { showJoin() }
        return true
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { workspace?.dockMenu() }
    @objc private func pauseAllParticipation() {
        for meeting in workspace?.meetings ?? [] { meeting.participation.pause() }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let workspace { workspace.populateWindowMenu(menu) } else { NativeDesktopWorkspace.addStandardWindowItems(menu) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidBecomeActive(_ notification: Notification) { workspace?.library.foregrounded() }
    func applicationDidResignActive(_ notification: Notification) { workspace?.backgrounded() }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { launchURLs = Array(urls.prefix(1)); return }
        showJoin(); if let url = urls.first { workspace?.handleURL(url) }
    }
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { await workspace?.cloudNotification() }
    }
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard launched else { launchActivity = userActivity; return true }
        showJoin(); return workspace?.continueActivity(userActivity) ?? false
    }
    @objc private func openSettings() {
        guard launched else { return }
        if workspace == nil { workspace = makeWorkspace() }
        workspace?.show(section: .settings)
    }
    #if NATIVE_DIRECT_UPDATES
    @objc private func checkForUpdates() { updates?.check() }
    #endif
    @objc private func openHome() { showJoin() }
    @objc private func copyDiagnostics() {
        Task { @MainActor in
            // Audio devices are read off the main thread and bounded: a stalled system
            // audio service must not freeze the app while you ask for help with it.
            let route = await GuestAcousticEnvironment.boundedRoute(names: true)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(NativeDesktopDiagnostics.report(route: route), forType: .string)
            let alert = NSAlert(); alert.messageText = L("Diagnostics copied")
            alert.informativeText = L("Paste them into your message to support. They include the app and macOS versions, audio devices and recent connection events, but no meeting content.")
            alert.runModal()
        }
    }
    @objc private func exportDiagnostics() {
        let stamp = DateFormatter(); stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.dateFormat = "yyyy-MM-dd HH.mm"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RockNRoll Diagnostics \(stamp.string(from: Date())).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        NativeDiagnosticsLog.shared.flush()
        Task { @MainActor in
            let route = await GuestAcousticEnvironment.boundedRoute(names: true)
            do {
                try NativeDiagnosticsArchive.make(report: NativeDesktopDiagnostics.report(route: route), logs: NativeDiagnosticsLog.shared.files,
                    reports: NativeDiagnosticReports.shared.files, destination: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                let alert = NSAlert(); alert.messageText = L("Unable to export diagnostics")
                alert.informativeText = error.localizedDescription; alert.runModal()
            }
        }
    }
}

/// Text a person pastes into a support message: versions, permissions, audio route,
/// installed copies and recent diagnostic events. No meeting links, titles or content;
/// audio device names are included because the person sees the text before sending it.
@MainActor enum NativeDesktopDiagnostics {
    /// The account's real home: a sandboxed NSHomeDirectory() is the container.
    static var homeDirectory: String {
        getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
    }
    /// `route` is the audio devices as `GuestAcousticEnvironment.boundedRoute` read them;
    /// nothing here touches CoreAudio, so the report never waits on the audio service.
    static func report(now: Date = Date(), route: [String: Any] = ["unavailable": "not read"]) -> String {
        func string(_ key: String, _ bundle: Bundle) -> String { bundle.object(forInfoDictionaryKey: key) as? String ?? "?" }
        func version(_ bundle: Bundle) -> String { "\(string("CFBundleShortVersionString", bundle)) (\(string("CFBundleVersion", bundle)))" }
        func path(_ value: String) -> String {
            value.hasPrefix(homeDirectory + "/") ? "~" + value.dropFirst(homeDirectory.count) : value
        }
        func json(_ value: Any) -> String {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "unavailable" }
            return String(decoding: data, as: UTF8.self)
        }
        func access(_ type: AVMediaType) -> String {
            switch AVCaptureDevice.authorizationStatus(for: type) {
            case .authorized: "allowed"
            case .denied: "denied"
            case .restricted: "restricted"
            case .notDetermined: "not asked"
            @unknown default: "unknown"
            }
        }
        var model = [CChar](repeating: 0, count: 64), size = model.count
        let hardware = sysctlbyname("hw.model", &model, &size, nil, 0) == 0 ? String(cString: model) : "?"
        var lines = ["Rock'N'Roll for Mac diagnostics",
            "Created: \(ISO8601DateFormatter().string(from: now)) (uptime \(Int(ProcessInfo.processInfo.systemUptime)))",
            "App: \(version(.main)) at \(path(Bundle.main.bundlePath))",
            "Updates: \(UserDefaults.standard.bool(forKey: "native.updates.beta") ? "beta" : "stable")",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Mac: \(hardware)", "Language: \(Locale.preferredLanguages.first ?? "?")",
            "Microphone: \(access(.audio)); camera: \(access(.video)); screen recording: \(CGPreflightScreenCaptureAccess() ? "allowed" : "not allowed")",
            "Audio devices: \(json(route))",
            "Installed copies:"]
        let copies = Bundle.main.bundleIdentifier.map { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) } ?? []
        lines += copies.prefix(8).map { url in "  \(path(url.path)) \(Bundle(url: url).map(version) ?? "?")" }
        if copies.count > 8 { lines.append("  and \(copies.count - 8) more") }
        lines.append("Saved logs: \(NativeDiagnosticsLog.shared.files.count) files; crash and hang reports: \(NativeDiagnosticReports.shared.files.count)")
        let events = probeLogHistory()
        lines.append("Recent events (\(events.count), oldest first):")
        lines += events
        return lines.joined(separator: "\n")
    }
}
