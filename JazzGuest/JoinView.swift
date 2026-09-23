import SwiftUI

struct JoinView: View {
    @ObservedObject var model: ConferenceModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Guest") {
                    TextField("Your name", text: $model.displayName)
                        .textContentType(.nickname)
                        .autocorrectionDisabled()
                }
                Section("Meeting") {
                    TextField("Paste Jazz invitation link", text: $model.invite)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Or enter a meeting code and password")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("Meeting code", text: $model.meetingCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Meeting password", text: $model.meetingPassword)
                }
                Section {
                    Button("Join with mic and camera off") { model.join() }
                        .disabled(model.isJoining || model.isInConference || model.isLeaving)
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
            .navigationTitle("Jazz Guest")
            .confirmationDialog(
                "Leave the current meeting and open the new invitation?",
                isPresented: $model.showSwitchConfirmation
            ) {
                Button("Leave current meeting") { model.replaceWithPending() }
                Button("Stay here", role: .cancel) {}
            }
        }
    }
}
