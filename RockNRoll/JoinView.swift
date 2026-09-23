import SwiftUI

struct JoinView: View {
    @ObservedObject var model: ConferenceModel
    @ObservedObject var catchUp: CatchUpStore
    @State private var showingSavedHistory = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Guest") {
                    TextField("Your name", text: $model.displayName)
                        .textContentType(.nickname)
                        .autocorrectionDisabled()
                }
                Section("Meeting") {
                    TextField("Paste meeting invitation link", text: $model.invite)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("The full link identifies the meeting and its conference service.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !catchUp.timeline.intervals.isEmpty && !model.isInConference {
                    Section("Missed meeting") {
                        Button("Review missed section") { showingSavedHistory = true }
                        if let host = catchUp.roomHost {
                            Text(host).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button("Join with mic and camera off") { model.join() }
                        .disabled(model.invite.isEmpty || model.isJoining || model.isInConference || model.isLeaving)
                    if model.isJoining || model.isInConference {
                        Button("Leave meeting", role: .destructive) { model.leave() }
                    }
                } footer: {
                    Text("You can turn on the microphone and camera during the meeting.")
                }
                Section("Status") {
                    Text(model.status)
                    if let media = model.mediaStatus {
                        Text(media).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Rock’n’Roll")
            .sheet(isPresented: $showingSavedHistory) {
                SavedCatchUpView(store: catchUp)
            }
            .confirmationDialog(
                "Leave the current meeting and open the new invitation?",
                isPresented: $model.showSwitchConfirmation
            ) {
                Button("Leave current meeting") { model.replaceWithPending() }
                Button("Stay here", role: .cancel) { model.dismissPending() }
            }
        }
    }
}

private struct SavedCatchUpView: View {
    @ObservedObject var store: CatchUpStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(CatchUpText.make(timeline: store.timeline,
                                      canView: store.canViewTranscript,
                                      enabled: store.transcriptionEnabled,
                                      warning: store.persistenceWarning)
                     + "\n\nRejoin the meeting to check for additional transcript lines.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle("Catch up")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Mark reviewed") { store.markReviewed() }
                    Spacer()
                    Button("Delete local history", role: .destructive) {
                        store.finishMeeting()
                        dismiss()
                    }
                }
                .padding()
                .background(.regularMaterial)
            }
        }
    }
}
