import SwiftUI

/// Notes panel for one meeting: raw Markdown editor, formatting actions, and an
/// honest local-save status. Saved is shown only after the SQLite commit succeeds.
struct MeetingNotesView: View {
    let model: NativeDesktopMeetingModel
    @ObservedObject private var notes: MeetingNotesController
    @ObservedObject private var library: MeetingLibraryController
    @State private var text: String = ""
    @State private var selection: NSRange = NSRange(location: 0, length: 0)
    @State private var hydratedSession: UUID?

    init(model: NativeDesktopMeetingModel) {
        self.model = model
        let notes = model.notes ?? MeetingNotesController(library: model.meetingLibrary ?? MeetingLibraryController(root: FileManager.default.temporaryDirectory))
        let library = model.meetingLibrary ?? notes.library
        self.notes = notes
        self.library = library
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(model.title).font(.headline).lineLimit(1)
                Spacer()
                Menu {
                    ForEach(NoteFormattingCommand.allCases, id: \.self) { command in
                        Button(command.title) { apply(command) }
                    }
                } label: { Image(systemName: "textformat").help(L("Format")) }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            MeetingNotesEditor(text: text, onChange: { newText in
                text = newText
                notes.update(sessionID: model.sessionID, text: newText)
            }, onSelectionChange: { range in
                selection = range
            })
            .frame(minWidth: 320, minHeight: 240)
            Divider()
            statusBar.padding(.horizontal, 12).padding(.vertical, 6)
        }
        .onAppear { hydrateIfNeeded() }
        .onChange(of: model.sessionID) { _ in hydrateIfNeeded() }
        .id(model.sessionID)
    }

    @ViewBuilder private var statusBar: some View {
        HStack(spacing: 6) {
            switch notes.draft(sessionID: model.sessionID)?.saveError {
            case .some(let error):
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                Text(L("Couldn’t save. Your text is kept in memory.")).foregroundColor(.red)
                Button(L("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button(L("Retry")) {
                    notes.update(sessionID: model.sessionID, text: text)
                    Task { await notes.flush(sessionID: model.sessionID) }
                }
            case .none:
                switch library.noteStatus[model.sessionID] {
                case .some(.saving):
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundColor(.secondary)
                    Text(L("Saving…")).foregroundColor(.secondary)
                case .some(.saved(let date)):
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(L("Saved on device at %@", Self.time.string(from: date))).foregroundColor(.secondary)
                case .some(.failed(let error)):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text(error).foregroundColor(.red).lineLimit(1)
                case .none:
                    Image(systemName: "circle").foregroundColor(.secondary)
                    Text(L("No notes yet")).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .font(.caption)
    }

    private func apply(_ command: NoteFormattingCommand) {
        let result = command.apply(to: text, selection: selection)
        text = result.text
        selection = result.selection
        notes.update(sessionID: model.sessionID, text: result.text)
    }

    private func hydrateIfNeeded() {
        guard hydratedSession != model.sessionID else { return }
        hydratedSession = model.sessionID
        text = notes.buffer(sessionID: model.sessionID)
        if notes.draft(sessionID: model.sessionID) == nil {
            Task { @MainActor in
                if let record = await library.note(sessionID: model.sessionID) {
                    notes.hydrate(sessionID: model.sessionID, text: record.markdown)
                    text = record.markdown
                }
            }
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
