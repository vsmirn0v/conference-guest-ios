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
    @State private var showingSettings = false
    @State private var showingAllRooms = false
    @State private var editingRoom: RecentRoom?
    @State private var roomAlias = ""
    @State private var showingUndo = false
    @State private var undoToken = UUID()
    private let accent = Color(red: 1, green: 0.60, blue: 0.33)

    private var favorites: [RecentRoom] { history.rooms.filter(\.isStarred) }
    private var recent: [RecentRoom] { history.rooms.filter { !$0.isStarred } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Join a jam") {
                    HStack {
                        TextField("Invitation link", text: $model.invite)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textContentType(.URL)
                        Button("Paste") {
                            if let link = UIPasteboard.general.string { model.invite = link }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    HStack {
                        Image(systemName: "person.crop.circle")
                        Text("Joining as \(model.displayName)")
                            .lineLimit(1)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    Button { model.join() } label: {
                        HStack {
                            Spacer()
                            if model.isJoining { ProgressView().tint(.white) }
                            Text(model.isJoining ? "Joining…" : "Join jam")
                                .font(.headline)
                            Spacer()
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(model.invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              model.isJoining || model.isInConference || model.isLeaving)
                    #if DEBUG
                    .accessibilityValue(model.testSwitchSequenceCompleted ? "Switch sequence connected" : "")
                    #endif
                    Label("Microphone and camera start off", systemImage: "mic.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if model.status != "Enter a jam link to begin." {
                        Text(model.status).font(.footnote)
                            .foregroundStyle(model.statusIsError ? .red : .secondary)
                    }
                    if let media = model.mediaStatus {
                        Text(media).font(.footnote).foregroundStyle(.red)
                    }
                    if model.isJoining || model.isInConference {
                        Button("Leave jam", role: .destructive) { model.leave() }
                    }
                }
                if !favorites.isEmpty { roomSection("Favorites", rooms: favorites) }
                if !recent.isEmpty {
                    roomSection("Recent jams", rooms: showingAllRooms ? recent : Array(recent.prefix(3)))
                    if recent.count > 3 {
                        Button(showingAllRooms ? "Show fewer" : "See all \(recent.count) recent jams") {
                            showingAllRooms.toggle()
                        }
                    }
                }
                if !catchUp.timeline.intervals.isEmpty && !model.isInConference {
                    Section("Catch up") {
                        Button("Review missed section") { showingSavedHistory = true }
                    }
                }
                Section {
                    Button("Try the test jam") {
                        model.receive(url: URL(string: "https://rock.glowsoft.ru/jams/test")!)
                        model.join()
                    }
                } footer: {
                    Text("Join a small music group with a shared invitation. No account needed.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Rock’n’Roll")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("Profile and settings")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if showingUndo {
                    Button("Room removed · Undo") {
                        history.undoRemoval()
                        showingUndo = false
                    }
                    .padding(12)
                    .background(.regularMaterial, in: Capsule())
                }
            }
            .sheet(isPresented: $showingSavedHistory) {
                SavedCatchUpView(store: catchUp)
            }
            .sheet(isPresented: $showingSettings) { settingsSheet }
            .alert("Name this jam", isPresented: Binding(
                get: { editingRoom != nil },
                set: { if !$0 { editingRoom = nil } }
            )) {
                TextField("Personal name", text: $roomAlias)
                Button("Save") {
                    if let editingRoom { model.setAlias(roomAlias, for: editingRoom) }
                    editingRoom = nil
                }
                Button("Cancel", role: .cancel) { editingRoom = nil }
            } message: {
                Text("Only you see this name.")
            }
            .confirmationDialog(
                "Leave the current jam and open the new invitation?",
                isPresented: $model.showSwitchConfirmation
            ) {
                Button("Leave current jam") { model.replaceWithPending() }
                Button("Stay here", role: .cancel) { model.dismissPending() }
            }
        }
        .tint(accent)
    }

    private func roomSection(_ title: String, rooms: [RecentRoom]) -> some View {
        Section(title) {
            ForEach(rooms) { room in
                HStack(spacing: 10) {
                    Button { model.rejoin(room) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(room.displayTitle).font(.body.weight(.semibold))
                            Text(roomSubtitle(room))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rejoin \(room.displayTitle)")
                    Button { model.toggleStar(room) } label: {
                        Image(systemName: room.isStarred ? "star.fill" : "star")
                            .frame(width: 44, height: 44)
                            .foregroundStyle(room.isStarred ? accent : .secondary)
                    }
                    .accessibilityLabel(room.isStarred ? "Unstar \(room.displayTitle)" : "Star \(room.displayTitle)")
                }
                .contextMenu {
                    Button("Rename") { roomAlias = room.alias ?? ""; editingRoom = room }
                    Button("Copy invitation") { UIPasteboard.general.url = room.invitationURL }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) {
                        model.remove(room)
                        showingUndo = true
                        let token = UUID()
                        undoToken = token
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(6))
                            if undoToken == token { showingUndo = false }
                        }
                    }
                    Button("Rename") { roomAlias = room.alias ?? ""; editingRoom = room }
                }
            }
        }
    }

    private func roomSubtitle(_ room: RecentRoom) -> String {
        let duplicates = history.rooms.filter {
            $0.id != room.id && $0.displayTitle == room.displayTitle &&
                $0.identifier == room.identifier
        }
        let origin = duplicates.isEmpty ? "" : " · \(room.invitationURL.host() ?? "Meeting")"
        return "\(room.identifier)\(origin) · \(room.lastJoined.formatted(.relative(presentation: .named)))"
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Your name") {
                    TextField("Your name", text: $model.displayName)
                        .textContentType(.nickname)
                        .autocorrectionDisabled()
                    Button("Choose my contact") { showingContactPicker = true }
                }
                Section("Compatible meeting website") {
                    TextField("HTTPS website address", text: $model.guestWebsiteOrigin)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Used to open compatible meeting links in the app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("About") {
                    Text("Small music groups in Yerevan can plan sessions and share ideas live.")
                    Link("Community", destination: URL(string: "https://rock.glowsoft.ru/community")!)
                    Link("Privacy policy", destination: URL(string: "https://rock.glowsoft.ru/privacy")!)
                    Link("Support", destination: URL(string: "https://rock.glowsoft.ru/support")!)
                    Link("Third-party notices", destination: URL(string: "https://rock.glowsoft.ru/notices")!)
                }
            }
            .navigationTitle("Profile and settings")
            .toolbar { Button("Done") { showingSettings = false } }
            .sheet(isPresented: $showingContactPicker) {
                ContactNamePicker(isPresented: $showingContactPicker) { model.displayName = $0 }
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
                    if store.timeline.unreadCount > 0 {
                        Button("Mark reviewed") { store.markReviewed() }
                    }
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
