import ConferenceCore
import SwiftUI

struct IOSInCallNotesView: View {
    @ObservedObject var workspace: IOSWorkspaceCoordinator
    let sessionID: UUID
    let title: String
    let roomURL: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var guidanceInput = ""

    private var roomScopeKey: String? {
        roomURL.map { "room:" + $0.absoluteString }
    }

    private var roomGuidance: [SyncedGuidanceRule] {
        guard let key = roomScopeKey, let settings = workspace.settings(for: key) else { return [] }
        return settings.guidanceRules.values.map(\.value).filter { !$0.deleted }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Live Meeting Notes"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $draft)
                        .font(.body)
                        .frame(minHeight: 220)
                        .padding(8)
                        .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .onChange(of: draft) { _, newValue in
                            workspace.updateNoteDraft(newValue, for: sessionID)
                        }
                }
                .padding(.horizontal)

                if let scopeKey = roomScopeKey {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Private Assistant Guidance"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField(L("Add instruction for this room…"), text: $guidanceInput)
                                .textFieldStyle(.roundedBorder)
                            Button(L("Add")) {
                                let text = guidanceInput
                                guidanceInput = ""
                                Task {
                                    await workspace.addGuidanceRule(
                                        text,
                                        scopeKey: scopeKey,
                                        scopeKind: .room,
                                        title: title
                                    )
                                }
                            }
                            .disabled(guidanceInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if !roomGuidance.isEmpty {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(roomGuidance) { rule in
                                        HStack {
                                            Text(rule.text)
                                                .font(.footnote)
                                            Spacer()
                                            Button {
                                                Task { await workspace.removeGuidanceRule(id: rule.id, scopeKey: scopeKey) }
                                            } label: {
                                                Image(systemName: "trash")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(8)
                                        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                            .frame(maxHeight: 140)
                        }
                    }
                    .padding(.horizontal)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) {
                        Task {
                            await workspace.flushNotesNow()
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                draft = workspace.noteDraft(for: sessionID)
            }
            .onDisappear {
                Task { await workspace.flushNotesNow() }
            }
        }
    }
}
