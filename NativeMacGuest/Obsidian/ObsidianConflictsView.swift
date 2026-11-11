import AppKit
import SwiftUI

struct ObsidianConflict: Identifiable, Sendable {
    let row: ObsidianOutboxRecord
    let binding: ObsidianExportBindingRecord

    var id: String { "\(row.id)/\(binding.component.rawValue)" }
    var title: String { row.snapshot?.session.title ?? L("Meeting notes") }
}

struct ObsidianConflictComparison: Sendable {
    let conflict: ObsidianConflict
    let local: String
    let external: String
    let standaloneCopy: String
    let observedBlockHash: String?
    var observedMetadataHash: String?
}

struct ObsidianConflictsSection: View {
    @ObservedObject var coordinator: ObsidianExportCoordinator
    @State private var isPresented = false

    var body: some View {
        if coordinator.conflictCount > 0 {
            Button(L("Review Obsidian conflicts…")) { isPresented = true }
                .sheet(isPresented: $isPresented) { ObsidianConflictsView(coordinator: coordinator) }
        }
    }
}

private struct ObsidianConflictsView: View {
    let coordinator: ObsidianExportCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var conflicts: [ObsidianConflict] = []
    @State private var selection: ObsidianConflict.ID?
    @State private var comparison: ObsidianConflictComparison?
    @State private var refreshToken = UUID()
    @State private var confirmReplace = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Obsidian conflicts")).font(.title2.bold())
            if conflicts.isEmpty {
                Text(L("No pending file conflicts")).foregroundStyle(.secondary)
            } else {
                Picker(L("Conflicting export"), selection: $selection) {
                    ForEach(conflicts) { conflict in
                        Text(conflict.title + " · " + conflict.binding.relativePath).tag(Optional(conflict.id))
                    }
                }
                if let comparison {
                    HStack(alignment: .top, spacing: 12) {
                        pane(L("Queued Rock’N’Roll revision"), text: comparison.local)
                        pane(L("Current vault contents"), text: comparison.external)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if let comparison {
                    Button(L("Save separate Markdown copy…")) { saveCopy(comparison) }
                    Button(L("Replace managed section…")) { confirmReplace = true }
                        .disabled(comparison.observedBlockHash == nil || busy)
                }
                Spacer()
                Button(L("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 780, height: 480)
        .task { await reload() }
        .task(id: (selection ?? "") + refreshToken.uuidString) {
            comparison = nil
            guard let conflict = conflicts.first(where: { $0.id == selection }) else { return }
            do {
                let reviewed = try await coordinator.compare(conflict)
                if !Task.isCancelled { comparison = reviewed }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        .confirmationDialog(L("Replace the reviewed managed section?"), isPresented: $confirmReplace, titleVisibility: .visible) {
            Button(L("Replace with queued revision"), role: .destructive) {
                guard let comparison else { return }
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        try await coordinator.replaceConflictingBlock(comparison)
                        await reload()
                        refreshToken = UUID()
                    } catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text(L("A backup is saved before writing. Text outside the managed section is preserved."))
        }
    }

    private func pane(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ScrollView {
                Text(text).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity)
    }

    private func reload() async {
        do {
            conflicts = try await coordinator.conflicts()
            if !conflicts.contains(where: { $0.id == selection }) { selection = conflicts.first?.id }
        } catch { self.error = error.localizedDescription }
    }

    private func saveCopy(_ comparison: ObsidianConflictComparison) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Save copy")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let name = MeetingMarkdownTemplate.meetingFileName(title: comparison.conflict.title + " " + L("Copy"),
                sessionID: comparison.conflict.row.sessionID)
            _ = try MeetingManualExport.writeUnique(comparison.standaloneCopy, name: name, directory: directory)
        } catch { self.error = error.localizedDescription }
    }
}
