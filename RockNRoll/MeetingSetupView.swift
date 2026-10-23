import ConferenceCore
import SwiftUI

struct MeetingSetupView: View {
    @ObservedObject var setup: MeetingSetupCoordinator
    @ObservedObject var calendar: CalendarMeetingStore
    @ObservedObject var reminders: CalendarReminderCoordinator
    @ObservedObject var sync: RoomSyncCoordinator
    @ObservedObject var continuation: MeetingContinuationCoordinator
    @State private var choosingCalendars = false
    @State private var requestingNotifications = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("Step %d of %d", setup.step.rawValue + 1, MeetingSetupCoordinator.Step.allCases.count))
                            .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("setup.step")
                        Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                        Text(title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                        Text(explanation).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 8)
                }
                switch setup.step {
                case .calendar: calendarOptions
                case .reminders: reminderOptions
                case .devices: cloudOptions
                }
            }
            .id(setup.step)
            .accessibilityIdentifier("setup.form")
            .navigationTitle(L("Meeting setup"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Finish later")) { setup.finishLater() }
                        .accessibilityIdentifier("setup.later").disabled(requestingNotifications)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    if setup.step != .calendar {
                        Button { setup.back() } label: {
                            Image(systemName: "chevron.left").frame(minWidth: 28, minHeight: 36)
                        }.buttonStyle(.bordered).accessibilityLabel(L("Back")).accessibilityIdentifier("setup.back")
                    }
                    Button { setup.next() } label: {
                        Text(setup.step == .devices ? L("Finish") : L("Continue"))
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("setup.next")
                }
                .font(.headline).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .controlSize(.large).padding().background(.bar).disabled(requestingNotifications)
            }
            .sheet(isPresented: $choosingCalendars) {
                NavigationStack {
                    Form {
                        if calendar.calendars.isEmpty { Text(L("No calendars are available on this device.")) }
                        CalendarSelectionSections(calendar: calendar)
                    }
                    .navigationTitle(L("Choose calendars"))
                    .toolbar { Button(L("Done")) { choosingCalendars = false } }
                }
            }
            .onAppear { calendar.reminders.foregrounded() }
        }
        .interactiveDismissDisabled()
    }
    private var symbol: String {
        switch setup.step { case .calendar: "calendar"; case .reminders: "bell.badge"; case .devices: "icloud" }
    }
    private var title: String {
        switch setup.step {
        case .calendar: L("Your meetings, ready to join")
        case .reminders: L("A reminder at the right time")
        case .devices: L("Your meetings across devices")
        }
    }
    private var explanation: String {
        switch setup.step {
        case .calendar: L("See upcoming meetings on Home from the calendars you choose. Your calendar events are never changed.")
        case .reminders: L("Get reminders for meetings with supported invitation links in your selected calendars.")
        case .devices: L("Optionally keep your name, favorites, recent meetings and reminder preferences together through private iCloud storage.")
        }
    }
    @ViewBuilder private var calendarOptions: some View {
        Section {
            Toggle(L("Show calendar meetings"), isOn: Binding(get: { calendar.enabled }, set: calendar.setEnabled))
                .accessibilityIdentifier("setup.calendar")
            if calendar.enabled {
                if calendar.loading { ProgressView(L("Loading calendars…")) }
                if calendar.access == .allowed {
                    Button { choosingCalendars = true } label: {
                        LabeledContent(L("Choose calendars"), value: L("%d selected", calendar.selected.count))
                    }.accessibilityIdentifier("setup.calendars")
                    if calendar.selected.isEmpty {
                        Text(L("Choose at least one calendar to see its meetings and receive reminders."))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else if calendar.access == .denied {
                    Text(L("Calendar access is off. Allow full access in Settings, then choose calendars here."))
                        .font(.subheadline).foregroundStyle(.secondary)
                    settingsButton
                } else if !calendar.loading {
                    Button(L("Allow calendar access")) { calendar.refresh(requestPermission: true) }
                }
            }
        } footer: {
            Text(L("Calendar access is optional. You can always join by invitation link."))
        }
        if calendar.supportsScheduledJoining {
            CalendarAutomaticJoinSettings(calendar: calendar)
            MacCalendarResidenceSettings(calendar: calendar)
        } else { Section {
            Toggle(L("Join when opening the app"), isOn: Binding(get: { calendar.automaticJoin }, set: calendar.setAutomaticJoin))
                .disabled(!calendar.automaticJoin && (!calendar.enabled || calendar.access != .allowed || calendar.selected.isEmpty))
                .accessibilityIdentifier("setup.autoJoin")
        } footer: {
            Text(L("Off by default. For one verified meeting near its start, a five-second countdown gives you time to cancel. Microphone and camera start off."))
        } }
        if let error = calendar.error { Section { Text(error).foregroundStyle(.red) } }
    }
    @ViewBuilder private var reminderOptions: some View {
        Section {
            Toggle(L("Meeting reminders on this device"), isOn: Binding(get: { reminders.enabled }, set: { value in
                requestingNotifications = true
                Task { await reminders.setEnabled(value); requestingNotifications = false }
            })).disabled(requestingNotifications).accessibilityIdentifier("setup.notifications")
            if requestingNotifications { ProgressView(L("Updating notifications…")) }
            if reminders.authorization == .denied {
                Text(L("Notifications are off in Settings")).font(.subheadline).foregroundStyle(.secondary)
                Button(L("Open Settings")) { Task { await NotificationSettingsLink.open() } }
                    .accessibilityIdentifier("setup.notificationSettings")
            }
            if !calendar.enabled || calendar.access != .allowed || calendar.selected.isEmpty {
                Text(L("Reminders need at least one calendar with supported meeting links."))
                    .font(.subheadline).foregroundStyle(.secondary)
                Button(L("Choose calendars")) { setup.showCalendars() }.accessibilityIdentifier("setup.returnToCalendars")
            }
        } footer: { Text(L("Notification delivery follows your Focus and system settings.")) }
        Section {
            LabeledContent(L("Before start"), value: ReminderFormatting.duration(reminders.profile.timing.before))
            LabeledContent(L("At start"), value: reminders.profile.timing.atStart ? L("On") : L("Off"))
            VStack(alignment: .leading, spacing: 4) {
                Text(L("After start"))
                Text(reminders.profile.timing.followUp.mode == .off ? L("Off") :
                    ReminderFormatting.duration(reminders.profile.timing.followUp.delay) + " · " + reminders.profile.timing.followUp.mode.title)
                    .foregroundStyle(.secondary)
            }
            if reminders.profile != ReminderProfile() {
                Button(L("Use recommended settings")) { reminders.setProfile(ReminderProfile()) }
                    .accessibilityIdentifier("setup.recommended")
            }
            NavigationLink(L("Customize reminders")) { CalendarReminderSettingsView(reminders: reminders, calendar: calendar) }
                .accessibilityIdentifier("setup.customizeReminders")
        } header: { Text(reminders.profile == ReminderProfile() ? L("Recommended settings") : L("Your current settings")) }
        footer: {
            Text(L("Recommended: no reminder before the start, an alert at the start, and a quiet reminder 30 seconds after while this app is open in another meeting. Sound and meeting details are on; Time Sensitive is off."))
        }
        if let error = reminders.error { Section { Text(error).foregroundStyle(.red) } }
    }
    @ViewBuilder private var cloudOptions: some View {
        Section {
            Toggle(L("Sync with iCloud"), isOn: Binding(get: { sync.enabled }, set: sync.setEnabled))
                .accessibilityIdentifier("setup.cloud")
            if sync.enabled {
                Toggle(L("Include recent jams"), isOn: Binding(get: { sync.includeRecent }, set: sync.setIncludeRecent))
                Toggle(L("Show active jams on my devices"), isOn: Binding(get: { continuation.enabled }, set: continuation.setEnabled))
            }
            HStack {
                if sync.busy { ProgressView() }
                Text(sync.status).font(.subheadline).foregroundStyle(.secondary)
            }.accessibilityIdentifier("setup.cloudStatus")
            if let warning = sync.storageWarning { Text(warning).font(.subheadline).foregroundStyle(.orange) }
            if let choice = sync.nameChoice {
                Text(L("Your devices have different saved names. Choose the name to use for future joins."))
                Button(L("Use this device’s name: %@", choice.local)) { sync.chooseName(useCloud: false) }
                Button(L("Use iCloud name: %@", choice.cloud.isEmpty ? L("No saved name") : choice.cloud)) { sync.chooseName(useCloud: true) }
            }
            NavigationLink(L("More iCloud options")) { Form { RoomSyncSettingsView(sync: sync, continuation: continuation) }.navigationTitle(L("Across your devices")) }
        } footer: {
            Text(L("Use the same Apple Account on your devices. Saved invitations can include access codes. Audio, video, chat and transcripts are not synced. Choose calendars and enable notifications separately on each device."))
        }
        Section {
            Text(L("You can finish setup while iCloud connects, or keep everything on this device. Change these choices anytime in Settings."))
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private var settingsButton: some View {
        Button(L("Open Settings")) { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
    }
}
