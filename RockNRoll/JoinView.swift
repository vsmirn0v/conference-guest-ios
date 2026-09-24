import Contacts
import ContactsUI
import ConferenceCore
import SwiftUI

struct JoinView: View {
    @ObservedObject var model: ConferenceModel
    @ObservedObject var catchUp: CatchUpStore
    @ObservedObject var history: RoomHistoryStore
    @State private var showingSavedHistory = false
    @State private var showingContactPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("You") {
                    TextField("Your name", text: $model.displayName)
                        .textContentType(.nickname)
                        .autocorrectionDisabled()
                    Button("Choose my contact") { showingContactPicker = true }
                }
                if !history.rooms.isEmpty {
                    Section("Recent jams") {
                        ForEach(history.rooms) { room in
                            HStack(spacing: 12) {
                                Button { model.rejoin(room) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(room.title).font(.body.weight(.medium))
                                        Text(room.identifier).font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Rejoin \(room.title)")
                                Button { model.toggleStar(room) } label: {
                                    Image(systemName: room.isStarred ? "star.fill" : "star")
                                        .foregroundStyle(room.isStarred ? .yellow : .secondary)
                                }
                                .accessibilityLabel(room.isStarred ? "Unstar \(room.title)" : "Star \(room.title)")
                            }
                            .swipeActions {
                                Button("Remove", role: .destructive) { model.remove(room) }
                            }
                        }
                    }
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
                        #if DEBUG
                        .accessibilityValue(model.testSwitchSequenceCompleted ? "Switch sequence connected" : "")
                        #endif
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
                Section("Meeting website") {
                    TextField("HTTPS website address", text: $model.guestWebsiteOrigin)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Used to resolve native app links from a compatible meeting website. iOS app-link schemes are registered when the app is built.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Rock’n’Roll")
            .sheet(isPresented: $showingSavedHistory) {
                SavedCatchUpView(store: catchUp)
            }
            .sheet(isPresented: $showingContactPicker) {
                ContactNamePicker(isPresented: $showingContactPicker) { model.displayName = $0 }
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

private struct ContactNamePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onName: (String) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: ContactNamePicker
        init(_ parent: ContactNamePicker) { self.parent = parent }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let name = (CNContactFormatter.string(from: contact, style: .fullName) ?? contact.nickname)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { parent.onName(String(name.prefix(80))) }
            parent.isPresented = false
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.isPresented = false
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
