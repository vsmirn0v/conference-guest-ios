import ConferenceCore
import SwiftUI

struct CalendarAgendaView: View {
    @ObservedObject var calendar: CalendarMeetingStore
    @ObservedObject var history: RoomHistoryStore
    @ObservedObject var continuation: MeetingContinuationCoordinator
    let busy: Bool
    let onJoin: (CalendarMeeting) -> Void
    let onSettings: () -> Void
    @State private var expanded = false

    var body: some View {
        if calendar.enabled {
            if let meeting = calendar.joiningMeeting, let seconds = calendar.countdown {
                Section {
                    Text(meeting.title).font(.headline)
                    Text(L("Joining in %ld seconds with mic and camera off", seconds)).font(.subheadline)
                    HStack {
                        Button(L("Join now")) { onJoin(meeting) }
                        Spacer()
                        Button(L("Cancel")) { calendar.cancelAutomaticJoin(suppress: true) }
                    }.buttonStyle(.borderless)
                }
            } else if let next = calendar.next {
                Section {
                    row(next, prominent: true)
                } header: { Text(next.isScheduledNow(calendar.now) ? L("Scheduled now") : L("Next meeting")) }
            }
            Section {
                if calendar.access != .allowed || calendar.selected.isEmpty {
                    Button { onSettings() } label: { Label(L("Choose calendars"), systemImage: "calendar") }
                } else {
                    let rows = calendar.upcoming.filter { $0.id != calendar.next?.id }
                    ForEach(expanded ? rows : Array(rows.prefix(3))) { meeting in row(meeting) }
                    if rows.isEmpty && calendar.next == nil {
                        Text(calendar.loading ? L("Checking calendar…") : L("No upcoming meetings in your selected calendars."))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if rows.count > 3 {
                        Button(expanded ? L("Show fewer") : L("See upcoming meetings")) { expanded.toggle() }
                    }
                }
                if let error = calendar.error { Text(error).font(.footnote).foregroundStyle(.red) }
            } header: {
                HStack {
                    Text(L("Calendar meetings")); Spacer()
                    Button(L("Calendars"), action: onSettings).font(.caption).textCase(nil)
                }
            }
        }
    }
    private func row(_ meeting: CalendarMeeting, prominent: Bool = false) -> some View {
        let active = continuation.candidates.first { $0.isRecent(at: Date()) && MeetingRoomIdentity($0.invitation) == meeting.roomIdentity }
        return VStack(alignment: .leading, spacing: prominent ? 10 : 6) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title).font(prominent ? .headline : .body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(time(meeting)).font(.subheadline).foregroundStyle(.secondary)
                    Text([meeting.calendarTitle, meeting.invitation?.host()].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if meeting.tentative { Text(L("Tentative")).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let url = meeting.invitation {
                    let favorite = history.matching(url, engine: meeting.engine)
                    Button {
                        if let favorite, favorite.isStarred { history.toggleStar(favorite.invitationURL) }
                        else { history.saveFavorite(url: url, title: meeting.title, engine: meeting.engine) }
                    } label: {
                        Image(systemName: favorite?.isStarred == true ? "star.fill" : "star")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(favorite?.isStarred == true ? L("Unstar %@", meeting.title) : L("Star %@", meeting.title))
                    .accessibilityIdentifier("calendar.star." + meeting.id)
                }
            }
            HStack {
                Button {
                    if let active { continuation.begin(active, companion: false) }
                    else if meeting.invitation == nil { calendar.choosingMeeting = meeting }
                    else { onJoin(meeting) }
                } label: {
                    Label(active.map { $0.isSharingScreen ? L("Move here and stop sharing") : L("Continue on this device") } ??
                          (meeting.invitation == nil ? L("Choose room") : L("Join")),
                          systemImage: meeting.invitation == nil ? "link" : "video")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderless)
                .disabled(busy)
                .accessibilityIdentifier("calendar.join." + meeting.id)
                Spacer(minLength: 0)
                if meeting.invitation != nil {
                    Button { calendar.choosingMeeting = meeting } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L("Choose another room"))
                }
            }
            if prominent { Text(L("Microphone and camera start off")).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, prominent ? 4 : 0)
    }
    private func time(_ meeting: CalendarMeeting) -> String {
        if meeting.allDay { return meeting.start.formatted(date: .abbreviated, time: .omitted) + " · " + L("All day") }
        return meeting.start.formatted(date: .abbreviated, time: .shortened) + " – " + meeting.end.formatted(date: .omitted, time: .shortened)
    }
}

struct CalendarSettingsView: View {
    @ObservedObject var calendar: CalendarMeetingStore
    var body: some View {
        Form {
            Section {
                Toggle(L("Show calendar meetings"), isOn: Binding(get: { calendar.enabled }, set: calendar.setEnabled))
                    .accessibilityIdentifier("calendar.enabled")
            } footer: {
                Text(L("Find meeting links in calendars you choose. Event details stay on this device. Your calendar is never edited."))
            }
            if calendar.enabled {
                if calendar.access == .denied {
                    Section {
                        Text(L("Allow full calendar access in Settings to read scheduled meetings."))
                        Button(L("Open Settings")) { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                    }
                } else if calendar.access == .notDetermined {
                    Section { Button(L("Allow calendar access")) { calendar.refresh(requestPermission: true) } }
                } else {
                    ForEach(Array(Set(calendar.calendars.map(\.source))).sorted(), id: \.self) { source in
                        Section(source) {
                            ForEach(calendar.calendars.filter { $0.source == source }) { option in
                                Toggle(isOn: Binding(get: { calendar.selected.contains(option.id) },
                                    set: { calendar.select(option.id, included: $0) })) {
                                    HStack(spacing: 10) {
                                        Circle().fill(Color(red: option.color[0], green: option.color[1], blue: option.color[2]))
                                            .frame(width: 10, height: 10).accessibilityHidden(true)
                                        Text(option.name)
                                    }
                                }
                                    .accessibilityIdentifier("calendar.select." + option.id)
                            }
                        }
                    }
                    Section {
                        Toggle(L("Join scheduled meetings when opening the app"), isOn: Binding(get: { calendar.automaticJoin }, set: calendar.setAutomaticJoin))
                            .accessibilityIdentifier("calendar.automaticJoin")
                    } footer: {
                        Text(L("Off by default. A five-second countdown appears only for one verified meeting near its start. Mic and camera stay off. Active calls and invitations take priority."))
                    }
                    Section {
                        Button(L("Refresh calendar")) { calendar.refresh() }.disabled(calendar.loading)
                        Button(L("Forget room associations"), role: .destructive) { calendar.forgetBindings() }
                    } footer: {
                        Text(L("Calendar selection and room associations belong to this device. Saved favorites use your existing iCloud Sync preference."))
                    }
                }
                if calendar.loading { ProgressView(L("Checking calendar…")) }
                if let error = calendar.error { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(L("Calendars"))
        .onAppear { calendar.refresh() }
    }
}

struct CalendarRoomBindingView: View {
    let meeting: CalendarMeeting
    @ObservedObject var calendar: CalendarMeetingStore
    @ObservedObject var history: RoomHistoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var series = true
    private func bind(_ url: URL) { calendar.bind(meeting, to: url, series: series); dismiss() }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(meeting.title).font(.headline)
                    Toggle(L("Remember for this series"), isOn: $series)
                }
                let invitations = meeting.links.compactMap(calendar.invitationNormalizer)
                if !invitations.isEmpty {
                    Section(L("Invitation links")) {
                        ForEach(invitations, id: \.absoluteString) { url in
                            Button((url.host() ?? "") + " · " + url.lastPathComponent) { bind(url) }
                        }
                    }
                }
                if !history.rooms.isEmpty {
                    Section(L("Saved rooms")) {
                        ForEach(history.rooms) { room in Button(room.displayTitle) { bind(room.joinURL) } }
                    }
                }
                Section(L("Another invitation")) {
                    TextField(L("Invitation link"), text: $link).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("calendar.binding.link")
                    Button(L("Use this room")) { if let url = URL(string: link) { bind(url) } }
                        .disabled((try? JoinTarget.parse(link)) == nil)
                }
            }
            .navigationTitle(L("Choose room"))
            .toolbar { Button(L("Cancel")) { dismiss() } }
        }
    }
}
