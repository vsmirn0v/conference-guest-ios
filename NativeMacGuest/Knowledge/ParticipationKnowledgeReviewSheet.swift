import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An exact-file review. The host owns the current context and commits/revokes approvals
/// through the same barrier used for participation; picking files never publishes anything.
@MainActor
struct ParticipationKnowledgeReviewSheet: View {
    let context: ParticipationKnowledgeReviewContext
    let currentContext: @MainActor () -> ParticipationKnowledgeReviewContext?
    let approvals: [ParticipationKnowledgeApproval]
    let onApprove: @MainActor (ParticipationKnowledgeApproval) -> Bool
    let onRevoke: @MainActor (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var folder: ParticipationKnowledgeFolder?
    @State private var preview: ParticipationKnowledgeSnapshot?
    @State private var acceptsProcessor = false
    @State private var status: String?
    @State private var work: Task<Void, Never>?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { clock in
            let isCurrent = context.matches(currentContext(), now: clock.date)
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                approvedNotes(at: clock.date, isCurrent: isCurrent)
                Divider()
                picker(disabled: !isCurrent || work != nil)
                if let preview {
                    sourcePreview(preview)
                    Toggle(L("Allow %@ to process this note for meeting replies", context.processorLabel),
                           isOn: $acceptsProcessor)
                        .disabled(!isCurrent || work != nil)
                }
                if !isCurrent {
                    Label(L("Sharing scope changed or expired. Close this sheet and review the current meeting."),
                          systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
                if let status {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button(L("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(L("Allow this note in this meeting")) { approve() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isCurrent || work != nil || preview == nil || !acceptsProcessor)
                }
            }
            .padding(20)
            .frame(width: 560)
        }
        .onDisappear {
            work?.cancel()
            work = nil
            resetPreview()
            folder = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("Meeting knowledge")).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(L("Meeting: %@", context.meetingTitle)).font(.headline)
            Text(L("The assistant may quote approved notes and name them in replies visible to everyone currently in this meeting. Review sharing again if the audience changes."))
            Text(L("Processor: %@", context.processorLabel)).fontWeight(.medium)
            Text(verbatim: context.processingDescription)
            Text(L("Access ends when you leave or at %@, whichever comes first.",
                   context.expiresAt.formatted(date: .abbreviated, time: .shortened)))
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func approvedNotes(at now: Date, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Allowed in this meeting")).font(.headline).accessibilityAddTraits(.isHeader)
            if approvals.isEmpty {
                Text(L("No notes are approved.")).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(approvals) { approval in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: approval.grant.source.relativePath)
                                        .lineLimit(1).truncationMode(.middle)
                                        .help(approval.grant.source.relativePath)
                                    if !isCurrent || approval.grant.expiresAt <= now || approval.grant.audience != context.audience
                                        || !approval.grant.allowedProcessors.contains(context.processorID) {
                                        Text(L("Review needed")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button(L("Remove access")) { onRevoke(approval.id) }
                                    .accessibilityLabel(L("Remove access to %@", approval.grant.source.relativePath))
                                    .help(L("Stops future use. Replies already sent remain in meeting chat."))
                            }
                        }
                    }
                }
                .frame(maxHeight: 110)
            }
        }
        .font(.callout)
    }

    private func picker(disabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Private to me")).font(.headline).accessibilityAddTraits(.isHeader)
            Text(L("Choose a folder on a local disk, then choose and review one Markdown note at a time. Other notes, links and attachments stay outside this approval."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(folder == nil ? L("Choose folder…") : L("Change folder…")) { chooseFolder() }
                if let folder {
                    Text(verbatim: folder.name).lineLimit(1).truncationMode(.middle).help(folder.name)
                    Spacer()
                    Button(L("Choose note…")) { chooseNote(in: folder) }
                }
            }
            .disabled(disabled)
        }
    }

    private func sourcePreview(_ source: ParticipationKnowledgeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: source.relativePath).font(.subheadline.weight(.medium))
                .lineLimit(1).truncationMode(.middle).help(source.relativePath)
            ScrollView {
                Text(verbatim: source.markdown).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 175)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(L("Exact Markdown preview"))
        }
    }

    private func chooseFolder() {
        guard context.matches(currentContext()), work == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.resolvesAliases = false
        panel.prompt = L("Choose folder")
        panel.message = L("Choose the folder containing the Markdown notes you want to review. No notes are approved by choosing a folder.")
        guard panel.runModal() == .OK, let selectedURL = panel.url, context.matches(currentContext()) else { return }
        resetPreview()
        folder = nil
        do {
            folder = try ParticipationKnowledgeFolder(selectedURL: selectedURL)
        } catch ParticipationKnowledgeError.nonlocalVolume {
            status = message(for: ParticipationKnowledgeError.nonlocalVolume)
        } catch {
            status = L("The selected folder could not be opened. Choose it again.")
        }
    }

    private func chooseNote(in folder: ParticipationKnowledgeFolder) {
        guard context.matches(currentContext()), work == nil else { return }
        do {
            let path = try folder.withAccess { root -> String? in
                let panel = NSOpenPanel()
                panel.directoryURL = root
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                panel.resolvesAliases = false
                panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
                panel.prompt = L("Preview note")
                panel.message = L("Choose a Markdown note within the selected folder.")
                guard panel.runModal() == .OK, let selectedURL = panel.url else { return nil }
                return try ParticipationKnowledgeFolder.relativePath(selectedURL: selectedURL, root: root)
            }
            guard let path, context.matches(currentContext()) else { return }
            resetPreview()
            work = Task {
                defer { if !Task.isCancelled { work = nil } }
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try folder.inspect(relativePath: path) }
                }.value
                guard !Task.isCancelled, context.matches(currentContext()) else { return }
                switch result {
                case .success(let source): preview = source
                case .failure(let error): status = message(for: error)
                }
            }
        } catch {
            resetPreview()
            status = message(for: error)
        }
    }

    private func approve() {
        guard context.matches(currentContext()), acceptsProcessor, work == nil, let folder, let preview else { return }
        guard !approvals.contains(where: { approval in
            let source = approval.grant.source
            return source.rootDevice == preview.rootDevice && source.rootInode == preview.rootInode
                && source.relativePath == preview.relativePath
        }) else {
            status = L("Remove this note’s existing access before approving it again.")
            return
        }
        status = nil
        work = Task {
            defer { if !Task.isCancelled { work = nil } }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try folder.approve(reviewed: preview, context: context) }
            }.value
            guard !Task.isCancelled, context.matches(currentContext()) else { return }
            switch result {
            case .success(let approval):
                resetPreview()
                status = onApprove(approval) ? L("Note approved for this meeting.") : L("This note was not approved. Review the current sharing scope.")
            case .failure(let error):
                resetPreview()
                status = message(for: error)
            }
        }
    }

    private func resetPreview() {
        preview = nil
        acceptsProcessor = false
        status = nil
    }

    private func message(for error: Error) -> String {
        switch error as? ParticipationKnowledgeError {
        case .invalidPath: L("Choose a visible Markdown file inside the selected folder.")
        case .unsupportedFile: L("Choose a regular Markdown file. Linked files are excluded.")
        case .tooLarge: L("Choose a Markdown note smaller than 1 MB.")
        case .invalidText: L("The selected note is not valid UTF-8 text.")
        case .nonlocalVolume: L("Network volumes aren’t supported. Choose a folder on a local disk.")
        case .sourceChanged: L("The note changed after review. Choose it again and review the new version.")
        case .expired, .audienceChanged, .processorDenied: L("This note was not approved. Review the current sharing scope.")
        default: L("The selected note could not be opened. Check the folder and choose the note again.")
        }
    }
}
