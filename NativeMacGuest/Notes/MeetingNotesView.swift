import AppKit
import SwiftUI

/// The meeting panel, Outcome detail and detached window all open this editor by session ID.
struct MeetingNotesView: View {
    let sessionID: UUID
    @ObservedObject var notes: MeetingNotesController
    let title: String
    var ended = false
    var openWindow: (() -> Void)?
    var returnToMain: (() -> Void)?
    @State private var editorID = UUID()
    @State private var formatted = true
    @State private var command: NoteFormattingCommand?
    @State private var commandID = UUID()
    @State private var leaseBlocked = false

    private var draft: MeetingNotesController.Draft? { notes.draft(sessionID: sessionID) }
    private var owner: UUID? { notes.editorOwner(sessionID: sessionID) }
    private var editing: Bool { owner == editorID }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    if ended { Text(L("Meeting ended")).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                Button {
                    formatted.toggle()
                } label: {
                    Image(systemName: formatted ? "chevron.left.forwardslash.chevron.right" : "text.alignleft")
                }
                .accessibilityLabel(formatted ? L("Show Markdown source") : L("Show formatted view"))
                .help(formatted ? L("Show Markdown source") : L("Show formatted view"))
                Menu {
                    ForEach(NoteFormattingCommand.allCases, id: \.self) { item in
                        Button { command = item; commandID = UUID() } label: {
                            Label(item.title, systemImage: item.symbol)
                        }
                    }
                } label: {
                    Image(systemName: "textformat").help(L("Format"))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!editing)
                if let openWindow {
                    Button(action: openWindow) { Image(systemName: "macwindow.badge.plus") }
                        .accessibilityLabel(L("Open notes in a separate window"))
                        .help(L("Open notes in a separate window"))
                }
                if let returnToMain {
                    Button(action: returnToMain) { Image(systemName: "arrow.up.left.square") }
                        .accessibilityLabel(L("Show in main window"))
                        .help(L("Show in main window"))
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if draft?.savedText != nil, !editing {
                HStack(spacing: 8) {
                    if owner != nil {
                        Button(L("Go to active editor")) { notes.focusEditor(sessionID: sessionID) }
                    }
                    Button(L("Edit here")) { activateEditor() }
                    Spacer()
                }
                .buttonStyle(.link)
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            MeetingNotesEditor(notes: notes, sessionID: sessionID, editorID: editorID,
                               formatted: formatted, command: command, commandID: commandID)
                .overlay(alignment: .topLeading) {
                    if draft?.text.isEmpty == true, editing {
                        Text(L("Add notes")).foregroundStyle(.tertiary)
                            .padding(.leading, 17).padding(.top, 12).allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 220)
                .accessibilityIdentifier("meeting.notes.editor")
            Divider()
            statusBar.padding(.horizontal, 12).padding(.vertical, 6)
        }
        .onDisappear {
            guard let openWindow, notes.draft(sessionID: sessionID)?.isDirty == true else { return }
            Task {
                await Task.yield()
                let saved = await notes.flush(sessionID: sessionID)
                guard !saved, !notes.hasEditor(sessionID: sessionID) else { return }
                if !MeetingNotesDraftRecovery.confirmClose(notes: notes, sessionID: sessionID, title: title) {
                    openWindow()
                }
            }
        }
        .task(id: sessionID) {
            await notes.load(sessionID: sessionID)
            if !Task.isCancelled { claimUnownedDocument() }
        }
        .onChange(of: owner) { current in
            if current == nil { claimUnownedDocument() }
        }
    }

    private func claimUnownedDocument() {
        if notes.editorOwner(sessionID: sessionID) == nil {
            notes.claimEditor(editorID, sessionID: sessionID)
        }
    }

    private func activateEditor() {
        leaseBlocked = !notes.claimEditor(editorID, sessionID: sessionID)
        if !leaseBlocked { notes.focusEditor(sessionID: sessionID) }
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            if let error = draft?.saveError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(L("Couldn’t save notes")).foregroundStyle(.red).help(error)
                Button(L("Retry")) {
                    Task {
                        if draft?.savedText == nil && draft?.isDirty != true {
                            await notes.load(sessionID: sessionID)
                            if owner == nil { notes.claimEditor(editorID, sessionID: sessionID) }
                        } else {
                            await notes.flush(sessionID: sessionID)
                        }
                    }
                }
                if draft?.isDirty == true {
                    Button(L("Export draft…")) {
                        _ = MeetingNotesDraftRecovery.export(notes.buffer(sessionID: sessionID), title: title)
                    }
                }
            } else if leaseBlocked, !editing {
                Text(L("Finish composing text in the active editor before switching."))
            } else if draft?.isDirty == true {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text(L("Saving locally…"))
            } else if draft?.savedText?.isEmpty == false || draft?.revision ?? 0 > 0 {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(L("Saved on this Mac"))
            } else if draft?.savedText != nil {
                Text(L("No notes yet"))
            } else {
                Text(L("Loading notes…"))
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
}

@MainActor enum MeetingNotesDraftRecovery {
    static func export(_ markdown: String, title: String) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (title.isEmpty ? L("Meeting notes") : title.replacingOccurrences(of: "/", with: "-")) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    static func confirmClose(notes: MeetingNotesController, sessionID: UUID, title: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("Couldn’t save notes")
        alert.informativeText = L("Export the current draft to another location or keep the editor open to retry.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Keep editing"))
        alert.addButton(withTitle: L("Export draft and close…"))
        alert.addButton(withTitle: L("Close and keep draft in memory"))
        switch alert.runModal() {
        case .alertSecondButtonReturn: return export(notes.buffer(sessionID: sessionID), title: title)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
}

/// Derived only from an already-open draft: inspecting the toolbar must not
/// load notes, claim an editor, or change the underlying saved data.
enum MeetingNotesEntryStatus: Equatable {
    case unknown, saving, saved, failed

    init(draft: MeetingNotesController.Draft?) {
        guard let draft else { self = .unknown; return }
        if draft.saveError != nil { self = .failed }
        else if draft.isDirty { self = .saving }
        else if draft.savedText?.isEmpty == false || (draft.revision ?? 0) > 0 { self = .saved }
        else { self = .unknown }
    }
}

/// The status is attached to the existing Notes action, so its error opens the
/// same editor that already provides retry and export-draft recovery.
struct MeetingNotesEntryButton: View {
    @ObservedObject var notes: MeetingNotesController
    let sessionID: UUID
    let open: () -> Void

    private var status: MeetingNotesEntryStatus { .init(draft: notes.draft(sessionID: sessionID)) }
    private var detail: String {
        switch status {
        case .unknown: L("Notes")
        case .saving: L("Saving locally…")
        case .saved: L("Saved on this Mac")
        case .failed: L("Notes need attention. Open notes to see recovery options.")
        }
    }

    var body: some View {
        Button(action: open) {
            Image(systemName: "note.text").frame(width: 32, height: 30)
                .overlay(alignment: .bottomTrailing) {
                    switch status {
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                            .foregroundStyle(.red).accessibilityHidden(true)
                    case .saving:
                        ProgressView().controlSize(.mini).scaleEffect(0.7).accessibilityHidden(true)
                    case .unknown, .saved: EmptyView()
                    }
                }
        }
        .buttonStyle(.plain)
        .help(detail)
        .accessibilityLabel(L("Notes"))
        .accessibilityValue(detail)
        .accessibilityIdentifier("meeting.notes.entry")
    }
}

/// Adapts the in-call panel to the session editor without giving the editor control of media.
struct LiveMeetingNotes: View {
    @ObservedObject var model: NativeDesktopMeetingModel
    var workspace: NativeDesktopWorkspace?

    var body: some View {
        if let notes = model.notes {
            LiveContent(model: model, notes: notes, library: notes.library, workspace: workspace)
                .id(model.sessionID)
        } else {
            Text(L("Meeting notes are unavailable.")).padding()
        }
    }

    private struct LiveContent: View {
        @ObservedObject var model: NativeDesktopMeetingModel
        @ObservedObject var notes: MeetingNotesController
        @ObservedObject var library: MeetingLibraryController
        var workspace: NativeDesktopWorkspace?

        var body: some View {
            let card = library.cards.first { $0.sessionID == model.sessionID }
            let title = card?.title ?? model.title
            let id = model.sessionID
            MeetingNotesView(sessionID: id, notes: notes, title: title, ended: card?.endedAt != nil, openWindow: {
                let originalWindow = NSApp.keyWindow
                notes.windows.open(sessionID: id, title: title, date: card?.startedAt ?? Date(),
                    isEnded: { [weak model] in model?.isClosed ?? true },
                    showInMain: { [weak workspace, weak model, weak originalWindow] in
                    guard let workspace else {
                        originalWindow?.deminiaturize(nil)
                        originalWindow?.makeKeyAndOrderFront(nil)
                        return
                    }
                    if let model, !model.isClosed, !workspace.isDetached(model) {
                        model.panel = .notes
                        workspace.presentEmbedded(model)
                    } else {
                        workspace.attention.requestedOutcomeSessionID = id
                        workspace.show(section: .assistant)
                    }
                })
            })
        }
    }
}
