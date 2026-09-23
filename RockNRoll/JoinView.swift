import SwiftUI

struct JoinView: View {
    @ObservedObject var model: ConferenceModel
    @ObservedObject var catchUp: CatchUpStore
    @State private var showingSavedHistory = false

    var body: some View {
        NavigationStack {
            Form {
                Section("You") {
                    TextField("Your name", text: $model.displayName)
                        .textContentType(.nickname)
                        .autocorrectionDisabled()
                }
                Section("Jam") {
                    TextField("Paste jam invitation link", text: $model.invite)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Open a jam link shared by your group. No account is needed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Try the test jam") {
                        model.receive(url: URL(string: "https://rock.glowsoft.ru/jams/test")!)
                    }
                }
                if !catchUp.timeline.intervals.isEmpty && !model.isInConference {
                    Section("Missed jam") {
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
                        Button("Leave jam", role: .destructive) { model.leave() }
                    }
                } footer: {
                    Text("You can turn on the microphone and camera during the jam.")
                }
                Section("Status") {
                    Text(model.status)
                    if let media = model.mediaStatus {
                        Text(media).foregroundStyle(.orange)
                    }
                }
                Section("About Rock’n’Roll") {
                    Text("A place for small music groups in Yerevan to plan sessions and share ideas live.")
                    Link("Community", destination: URL(string: "https://rock.glowsoft.ru/community")!)
                    Link("Privacy policy", destination: URL(string: "https://rock.glowsoft.ru/privacy")!)
                    Link("Support", destination: URL(string: "https://rock.glowsoft.ru/support")!)
                    Link("Third-party notices", destination: URL(string: "https://rock.glowsoft.ru/notices")!)
                }
            }
            .navigationTitle("Rock’n’Roll")
            .sheet(isPresented: $showingSavedHistory) {
                SavedCatchUpView(store: catchUp)
            }
            .confirmationDialog(
                "Leave the current jam and open the new invitation?",
                isPresented: $model.showSwitchConfirmation
            ) {
                Button("Leave current jam") { model.replaceWithPending() }
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
                     + "\n\nRejoin the jam to check for additional transcript lines.")
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
