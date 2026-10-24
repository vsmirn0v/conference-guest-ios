import AppKit
import Foundation
import AVFoundation

@main
struct NativeGuestApplication {
    @MainActor static func main() {
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

@MainActor final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private let mode: NativeGuestLaunchMode
    private var workspace: NativeDesktopWorkspace?
    private var controller: CompanionMeetingController?
    private var terminating = false
    init(mode: NativeGuestLaunchMode) { self.mode = mode }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), appMenu = NSMenu(), item = NSMenuItem()
        appMenu.addItem(withTitle: L("Quit Rock’n’Roll"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        editItem.submenu = editMenu; menu.addItem(editItem); NSApp.mainMenu = menu
        let settings = NSMenuItem(title: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; appMenu.insertItem(settings, at: 0)
        let show = NSMenuItem(title: L("Open Rock’n’Roll"), action: #selector(openHome), keyEquivalent: "n")
        show.target = self; appMenu.insertItem(show, at: 0)
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        #endif
        accept()
    }
    private func showJoin(completion: NativeGuestMeetingCompletion? = nil) {
        guard !terminating else { return }
        if workspace == nil { workspace = NativeDesktopWorkspace() }
        workspace?.show()
        if let completion, completion != .left { workspace?.error = completion.message }
    }
    private func accept() {
        if mode == .standalone { showJoin(); return }
        let sessionID: UUID?
        if case .companion(let id) = mode { sessionID = id } else { sessionID = nil }
        Task { @MainActor in
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
        terminating = true
        Task { @MainActor in
            _ = await workspace?.leave()
            if let controller, !controller.finished { await controller.finish() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let controller, !controller.finished { controller.show() }
        else { showJoin() }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidBecomeActive(_ notification: Notification) { workspace?.library.foregrounded() }
    func applicationDidResignActive(_ notification: Notification) { workspace?.backgrounded() }
    func application(_ application: NSApplication, open urls: [URL]) {
        showJoin(); if let url = urls.first { workspace?.handleURL(url) }
    }
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { await workspace?.cloudNotification() }
    }
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        showJoin(); return workspace?.continueActivity(userActivity) ?? false
    }
    @objc private func openSettings() {
        if workspace == nil { workspace = NativeDesktopWorkspace() }
        workspace?.show(section: .settings)
    }
    @objc private func openHome() { showJoin() }
}
