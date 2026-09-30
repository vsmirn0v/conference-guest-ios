import Contacts
import ContactsUI
import ConferenceCore
import SwiftUI

struct JoinView: View {
    @ObservedObject var model: ConferenceModel
    @ObservedObject var catchUp: CatchUpStore
    @ObservedObject var history: RoomHistoryStore
    @ObservedObject var sync: RoomSyncCoordinator
    @ObservedObject var continuation: MeetingContinuationCoordinator
    @State private var showingSavedHistory = false
    @State private var showingContactPicker = false
    @State private var showingSettings = false
    @State private var showingAllRooms = false
    @State private var editingRoom: RecentRoom?
    @State private var roomAlias = ""
    @State private var showingUndo = false
    @State private var undoToken = UUID()
    @State private var staleContinuation: ActiveJam?
    @State private var confirmingStaleContinuation = false
    private let accent = Color(red: 1, green: 0.60, blue: 0.33)
    private let linkAccent = Color(uiColor: .init { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1) :
            UIColor(red: 0.49, green: 0.21, blue: 0.06, alpha: 1)
    })

    private var favorites: [RecentRoom] { history.rooms.filter(\.isStarred) }
    private var recent: [RecentRoom] { history.rooms.filter { !$0.isStarred } }

    var body: some View {
        GeometryReader { window in
          NavigationStack {
            HStack(spacing: 0) {
              if window.size.width >= 900 {
                  Form {
                      if !favorites.isEmpty { roomSection(L("Favorites"), rooms: favorites) }
                      if !recent.isEmpty {
                          roomSection(L("Recent jams"), rooms: showingAllRooms ? recent : Array(recent.prefix(3)))
                          if recent.count > 3 {
                              Button(showingAllRooms ? L("Show fewer") : L("See all %ld recent jams", recent.count)) {
                                  showingAllRooms.toggle()
                              }
                          }
                      }
                  }
                  .frame(width: min(350, window.size.width * 0.34))
                  .scrollContentBackground(.hidden)
                  .background(Color(uiColor: .secondarySystemGroupedBackground))
              }
              Form {
                MeetingContinuationView(continuation: continuation,
                                        busy: model.isJoining || model.isInConference || model.isLeaving,
                                        onJoinHere: { staleContinuation = $0; confirmingStaleContinuation = true })
                Section(L("Join a jam")) {
                    HStack {
                        TextField(L("Invitation link"), text: $model.invite)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textContentType(.URL)
                        Button(L("Paste")) {
                            if let link = UIPasteboard.general.string { model.invite = link }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    Button { model.showingNameEditor = true } label: {
                        HStack {
                            Image(systemName: "person.crop.circle")
                            Text(model.displayName.isEmpty ? L("Add your name") : L("Joining as %@", model.displayName))
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                        .font(.subheadline)
                    }
                    .accessibilityLabel(L("Edit your name, currently %@", model.displayName))
                    if !model.displayName.isEmpty && !validDisplayName {
                        Text(L("Enter a name of up to %ld characters before joining.", model.namePolicy.maximumNameScalars))
                            .font(.footnote).foregroundStyle(.red)
                    }
                    Button { model.join() } label: {
                        HStack {
                            Spacer()
                            if model.isJoining { ProgressView().tint(canJoin ? .black : .primary) }
                            Text(model.isJoining ? L("Joining…") : L("Join jam"))
                                .font(.headline)
                                .foregroundStyle(canJoin ? Color.black : Color.primary)
                            Spacer()
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(!canJoin)
                    #if DEBUG
                    .accessibilityValue(model.testSwitchSequenceCompleted ? "Switch sequence connected" : "")
                    #endif
                    Label(L("Microphone and camera start off"), systemImage: "mic.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if model.status != L("Enter a jam link to begin.") {
                        Text(model.status).font(.footnote)
                            .foregroundStyle(model.statusIsError ? .red : .secondary)
                    }
                    if let media = model.mediaStatus {
                        Text(media).font(.footnote).foregroundStyle(.red)
                    }
                    if model.isJoining || model.isInConference {
                        Button(L("Leave jam"), role: .destructive) { model.leave() }
                    }
                }
                if let warning = catchUp.persistenceWarning, catchUp.timeline.intervals.isEmpty {
                    Section {
                        Text(warning).font(.footnote).foregroundStyle(.orange)
                        Button(L("Delete local history")) { catchUp.finishMeeting() }
                    }
                }
                if let warning = history.persistenceWarning {
                    Section {
                        Text(warning).font(.footnote).foregroundStyle(.orange)
                        Button(L("Retry saving rooms")) { history.retrySave() }
                    }
                }
                if sync.offerSync && !model.isJoining && !model.isInConference {
                    Section(L("Keep your jams across devices")) {
                        Text(L("Sync your name, favorites and recent jams through your private iCloud account."))
                            .font(.subheadline)
                        Button(L("Enable iCloud Sync")) {
                            sync.dismissOffer(); sync.setEnabled(true); showingSettings = true
                        }
                        Button(L("Not now")) { sync.dismissOffer() }.foregroundStyle(.secondary)
                    }
                }
                if window.size.width < 900 && !favorites.isEmpty {
                    roomSection(L("Favorites"), rooms: favorites)
                }
                if window.size.width < 900 && !recent.isEmpty {
                    roomSection(L("Recent jams"), rooms: showingAllRooms ? recent : Array(recent.prefix(3)))
                    if recent.count > 3 {
                        Button(showingAllRooms ? L("Show fewer") : L("See all %ld recent jams", recent.count)) {
                            showingAllRooms.toggle()
                        }
                    }
                }
                if !catchUp.timeline.intervals.isEmpty && !model.isInConference {
                    Section(L("Catch up")) {
                        Button(L("Review missed section")) { showingSavedHistory = true }
                    }
                }
                Section {
                    Button(L("Join a practice room")) {
                        model.receive(url: URL(string: "https://rock.glowsoft.ru/jams/test")!)
                        model.join()
                    }
                } footer: {
                    Text(L("Practice with a shared music group. Other visitors can join; your microphone and camera start off."))
                }
            }
            .frame(maxWidth: window.size.width >= 900 ? 720 : .infinity)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Rock’n’Roll")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel(L("Profile and settings"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if showingUndo {
                    Button(L("Room removed · Undo")) {
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
            .alert(L("Join here without moving the other device?"),
                                isPresented: $confirmingStaleContinuation,
                                presenting: staleContinuation) { jam in
                Button(L("Join with mic and camera off")) { model.joinFromContinuation(jam, quiet: false) }
                Button(L("Cancel"), role: .cancel) {}
            } message: { _ in
                Text(L("The other device may still play meeting audio. Disconnect it or use headphones to avoid echo."))
            }
            .sheet(isPresented: $model.showingNameEditor, onDismiss: model.nameEditorDismissed) { nameSheet }
            .sheet(item: $model.siteSelection) { selection in
                MeetingWebsiteSelectionView(
                    rememberedOrigins: selection.rememberedOrigins,
                    onChoose: { model.chooseWebsite($0) ? nil : model.status },
                    onCancel: { model.siteSelection = nil }
                )
            }
            .sheet(item: $editingRoom) { room in
                NavigationStack {
                    Form {
                        Section {
                            TextField(L("New jam name"), text: $roomAlias)
                                .textInputAutocapitalization(.words)
                        } footer: {
                            Text(L("Current: %@. Only you see this name.", room.displayTitle))
                        }
                    }
                    .navigationTitle(L("Name this jam"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L("Cancel")) { editingRoom = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L("Save")) {
                                model.setAlias(roomAlias, for: room)
                                editingRoom = nil
                            }
                            .disabled(roomAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .confirmationDialog(
                L("Leave the current jam and open the new invitation?"),
                isPresented: $model.showSwitchConfirmation
            ) {
                Button(L("Leave current jam")) { model.replaceWithPending() }
                Button(L("Stay here"), role: .cancel) { model.dismissPending() }
            }
            Spacer(minLength: 0)
            }
          }
        }
        .tint(linkAccent)
    }

    private var validDisplayName: Bool {
        model.validDisplayName
    }

    private var canJoin: Bool {
        !model.invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.isJoining && !model.isInConference && !model.isLeaving
    }

    private var nameSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Name shown to musicians"), text: $model.displayName)
                        .textContentType(.nickname)
                        .autocorrectionDisabled()
                    Button(L("Choose my contact")) { showingContactPicker = true }
                } header: {
                    Text(L("Your name"))
                } footer: {
                    Text(L("This name is saved for future jams. Use up to %ld characters.", model.namePolicy.maximumNameScalars))
                }
            }
            .navigationTitle(L("Your name"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { model.showingNameEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isNameRequiredForJoin ? L("Join jam") : L("Done")) { model.confirmNameEntry() }
                        .disabled(!validDisplayName)
                }
            }
            .sheet(isPresented: $showingContactPicker) {
                ContactNamePicker(isPresented: $showingContactPicker) { model.displayName = $0 }
            }
        }
        .onAppear { sync.beginNameEditing() }
        .onDisappear { sync.endNameEditing() }
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
                    .accessibilityLabel(L("Rejoin %@ on %@", room.displayTitle, room.invitationURL.host() ?? L("meeting website")))
                    .contextMenu {
                        Button { startRename(room) } label: {
                            Label(L("Rename"), systemImage: "pencil")
                        }
                        Button {
                            UIPasteboard.general.url = room.invitationURL
                        } label: {
                            Label(L("Copy invitation"), systemImage: "doc.on.doc")
                        }
                        if room.alias != nil {
                            Button { model.setAlias(nil, for: room) } label: {
                                Label(L("Use original name"), systemImage: "arrow.uturn.backward")
                            }
                        }
                    }
                    Button { model.toggleStar(room) } label: {
                        Image(systemName: room.isStarred ? "star.fill" : "star")
                            .frame(width: 44, height: 44)
                            .foregroundStyle(room.isStarred ? linkAccent : .secondary)
                    }
                    .accessibilityLabel(room.isStarred ? L("Unstar %@", room.displayTitle) : L("Star %@", room.displayTitle))
                }
                .swipeActions {
                    Button(L("Remove"), role: .destructive) {
                        model.remove(room)
                        showingUndo = true
                        let token = UUID()
                        undoToken = token
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(6))
                            if undoToken == token { showingUndo = false }
                        }
                    }
                    Button(L("Rename")) { startRename(room) }
                }
            }
        }
    }

    private func startRename(_ room: RecentRoom) {
        roomAlias = room.alias ?? ""
        editingRoom = room
    }

    private func roomSubtitle(_ room: RecentRoom) -> String {
        "\(room.identifier) · \(room.invitationURL.host() ?? L("Meeting")) · \(room.lastJoined.formatted(.relative(presentation: .named)))"
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section(L("Your name")) {
                    TextField(L("Your name"), text: $model.displayName)
                        .textContentType(.nickname)
                        .autocorrectionDisabled()
                    Button(L("Choose my contact")) { showingContactPicker = true }
                }
                Section(L("Compatible meeting website")) {
                    TextField(L("HTTPS website address"), text: $model.guestWebsiteOrigin)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text(L("Fallback for app links that omit their website. Links with an embedded host open directly."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                RoomSyncSettingsView(sync: sync, continuation: continuation)
                Section(L("About")) {
                    Text(L("Small music groups in Yerevan can plan sessions and share ideas live."))
                    Link(L("Community"), destination: URL(string: "https://rock.glowsoft.ru/community")!)
                    Link(L("Privacy policy"), destination: URL(string: "https://rock.glowsoft.ru/privacy")!)
                    Link(L("Support"), destination: URL(string: "https://rock.glowsoft.ru/support")!)
                    Link(L("Third-party notices"), destination: URL(string: "https://rock.glowsoft.ru/notices")!)
                }
            }
            .navigationTitle(L("Profile and settings"))
            .toolbar { Button(L("Done")) { showingSettings = false } }
            .sheet(isPresented: $showingContactPicker) {
                ContactNamePicker(isPresented: $showingContactPicker) { model.displayName = $0 }
            }
        }
        .onAppear { sync.beginNameEditing() }
        .onDisappear { sync.endNameEditing() }
    }
}

struct MeetingWebsiteSelectionView: View {
    let rememberedOrigins: [URL]
    let onChoose: (String) -> String?
    let onCancel: () -> Void
    @State private var website = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L("This app link does not identify its meeting website. Choose one you trust to open the invitation."))
                        .font(.footnote)
                    ForEach(rememberedOrigins, id: \.absoluteString) { origin in
                        Button(origin.host() ?? origin.absoluteString) {
                            error = onChoose(origin.absoluteString)
                        }
                    }
                } header: {
                    Text(L("Previously used websites"))
                }
                Section(L("Another website")) {
                    TextField("https://meeting.example.org", text: $website)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button(L("Open invitation")) { error = onChoose(website) }
                        .disabled(website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(L("Meeting website"))
            .toolbar { Button(L("Cancel"), action: onCancel) }
        }
        .presentationDetents([.medium, .large])
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
            CatchUpCardsView(store: store)
            .navigationTitle(L("Catch up"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Button(L("Delete local history"), role: .destructive) {
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
