import SwiftUI

struct JoinView: View {
    @ObservedObject var model: ConferenceModel

    var body: some View {
        NavigationStack {
            Form {
                if model.usesNativeSDK {
                    Section("Guest") {
                        TextField("Your name", text: $model.displayName)
                            .textContentType(.nickname)
                            .autocorrectionDisabled()
                    }
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
                    Button(model.usesNativeSDK ? "Join with mic and camera off" : "Open Jazz guest page") { model.join() }
                        .disabled(model.isJoining || model.isInConference || model.isLeaving || model.webMeeting != nil)
                    if model.isJoining || model.isInConference || model.webMeeting != nil {
                        Button("Leave meeting", role: .destructive) { model.leave() }
                    }
                } footer: {
                    Text(model.usesNativeSDK
                         ? "You can turn on the microphone and camera during the meeting."
                         : "Jazz asks for your name and media choices on its guest page. Keep your microphone and camera off before joining.")
                }
                Section("Status") {
                    Text(model.status)
                    if let media = model.mediaStatus {
                        Text(media).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Jazz Guest")
            .fullScreenCover(item: Binding(
                get: { model.webMeeting },
                set: { if $0 == nil { model.leave() } }
            )) { meeting in
                WebMeetingView(meeting: meeting, model: model)
            }
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
