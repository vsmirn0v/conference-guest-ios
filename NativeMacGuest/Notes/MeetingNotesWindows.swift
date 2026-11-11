import AppKit
import Combine
import SwiftUI

@MainActor final class MeetingNotesWindows {
    private weak var notes: MeetingNotesController?
    private var windows: [UUID: MeetingNotesWindow] = [:]
    private let persistsFrames: Bool

    init(notes: MeetingNotesController, persistsFrames: Bool = true) {
        self.notes = notes
        self.persistsFrames = persistsFrames
    }

    @discardableResult
    func open(sessionID: UUID, title: String, date: Date?, isEnded: (() -> Bool)? = nil,
              showInMain: @escaping () -> Void) -> NSWindow? {
        if let existing = windows[sessionID] { existing.show(); return existing.window }
        guard let notes else { return nil }
        let window = MeetingNotesWindow(notes: notes, sessionID: sessionID, title: title,
                                        date: date, isEnded: isEnded, persistsFrames: persistsFrames, showInMain: showInMain) { [weak self] in
            self?.windows[sessionID] = nil
        }
        windows[sessionID] = window
        window.show()
        return window.window
    }
}

@MainActor private final class MeetingNotesWindow: NSObject, NSWindowDelegate {
    private weak var notes: MeetingNotesController?
    let window: NSWindow
    private let sessionID: UUID
    private let onClose: () -> Void
    private let showInMain: () -> Void
    private var cards: AnyCancellable?
    private var screens: AnyCancellable?
    private var allowingClose = false
    private var savingForClose = false
    private static let defaultFrameName = "RockNRoll.MeetingNotes"
    private let frameName: String?

    init(notes: MeetingNotesController, sessionID: UUID, title: String, date: Date?,
         isEnded: (() -> Bool)?, persistsFrames: Bool, showInMain: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.notes = notes
        frameName = persistsFrames ? Self.defaultFrameName + "." + sessionID.uuidString : nil
        self.sessionID = sessionID
        self.onClose = onClose
        self.showInMain = showInMain
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 510),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 340, height: 290)
        let restoredFrame = frameName.map { window.setFrameUsingName($0) || window.setFrameUsingName(Self.defaultFrameName) } ?? false
        if !restoredFrame { window.center() }
        cards = notes.library.$cards.sink { [weak window = window] cards in
            let card = cards.first { $0.sessionID == sessionID }
            let timestamp = (card?.effectiveDate?.date ?? date)?.formatted(date: .abbreviated, time: .shortened)
            window?.title = timestamp.map { "\(card?.title ?? title) · \($0)" } ?? card?.title ?? title
        }
        screens = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.moveOntoScreen() }
        window.contentView = NSHostingView(rootView: Content(notes: notes, library: notes.library,
            sessionID: sessionID, title: title, isEnded: isEnded, showInMain: { [weak self] in self?.returnToMain() }))
    }

    func show() {
        moveOntoScreen()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func moveOntoScreen() {
        let frame = window.frame
        guard !NSScreen.screens.contains(where: {
            $0.visibleFrame.intersection(frame).width >= 140 && $0.visibleFrame.intersection(frame).height >= 80
        }), let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let width = min(frame.width, visible.width), height = min(frame.height, visible.height)
        window.setFrame(NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2,
                               width: width, height: height), display: true)
    }

    private func returnToMain() {
        showInMain()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !allowingClose, let notes else { return true }
        guard !savingForClose else { return false }
        // Resign the first responder so AppKit commits any marked input before flushing.
        guard sender.makeFirstResponder(nil) else { return false }
        savingForClose = true
        Task { [self] in
            let saved = await notes.flush(sessionID: sessionID)
            savingForClose = false
            guard saved || MeetingNotesDraftRecovery.confirmClose(notes: notes, sessionID: sessionID, title: window.title) else { return }
            allowingClose = true
            sender.performClose(nil)
        }
        return false
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        window.contentView = nil
        onClose()
    }

    private func saveFrame() {
        guard let frameName else { return }
        window.saveFrame(usingName: frameName)
        window.saveFrame(usingName: Self.defaultFrameName)
    }

    private struct Content: View {
        @ObservedObject var notes: MeetingNotesController
        @ObservedObject var library: MeetingLibraryController
        let sessionID: UUID
        let title: String
        let isEnded: (() -> Bool)?
        let showInMain: () -> Void

        var body: some View {
            let card = library.cards.first { $0.sessionID == sessionID }
            MeetingNotesView(sessionID: sessionID, notes: notes, title: card?.title ?? title,
                ended: card?.endedAt != nil || isEnded?() == true, returnToMain: showInMain)
        }
    }
}
