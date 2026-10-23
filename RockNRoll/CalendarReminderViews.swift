import ConferenceCore
import SwiftUI
import AVFAudio

struct CalendarReminderSheet: ViewModifier {
    @ObservedObject var reminders: CalendarReminderCoordinator
    var isActive: () -> Bool = { true }
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { isActive() ? reminders.editing : nil }, set: { if isActive() { reminders.editing = $0 } })) {
            OccurrenceReminderView(occurrence: $0, reminders: reminders)
        }
    }
}

struct CalendarReminderSettingsView: View {
    @ObservedObject var reminders: CalendarReminderCoordinator
    @ObservedObject var calendar: CalendarMeetingStore
    var body: some View {
        Form {
            Section {
                Toggle(L("On this device"), isOn: Binding(get: { reminders.enabled }, set: { value in
                    Task { await reminders.setEnabled(value) }
                })).accessibilityIdentifier("reminders.enabled")
                if reminders.authorization == .denied {
                    Text(L("Notifications are off in Settings")).foregroundStyle(.secondary)
                    Button(L("Open Settings")) { Task { await NotificationSettingsLink.open() } }
                        .accessibilityIdentifier("reminders.notificationSettings")
                }
                if !calendar.enabled || calendar.access != .allowed || calendar.selected.isEmpty {
                    Text(L("Choose calendars with supported meeting invitations in Calendars.")).foregroundStyle(.secondary)
                }
            } footer: { Text(L("For meetings with a supported invitation link.")) }
            ReminderTimingEditor(timing: Binding(get: { reminders.profile.timing }, set: { timing in
                var value = reminders.profile; value.timing = timing; reminders.setProfile(value)
            }))
            if !ProcessInfo.processInfo.isiOSAppOnMac { BackgroundAudioJoinSettingsSection() }
            Section {
                NavigationLink(L("Delivery and privacy")) { ReminderDeliveryView(reminders: reminders) }
                    .accessibilityIdentifier("reminders.delivery")
            }
            if let error = reminders.error { Section { Text(error).foregroundStyle(.red) } }
        }.accessibilityIdentifier("reminders.settingsForm")
            .navigationTitle(L("Meeting reminders"))
            .onAppear { reminders.foregrounded() }
    }
}

private struct ReminderDeliveryView: View {
    @ObservedObject var reminders: CalendarReminderCoordinator
    private func binding(_ key: WritableKeyPath<ReminderProfile, Bool>) -> Binding<Bool> {
        Binding(get: { reminders.profile[keyPath: key] }, set: {
            var profile = reminders.profile; profile[keyPath: key] = $0; reminders.setProfile(profile)
        })
    }
    var body: some View {
        Form {
            Section {
                Toggle(L("Sound"), isOn: binding(\.sound))
                Toggle(L("Time Sensitive"), isOn: binding(\.timeSensitive))
            } footer: { Text(L("Notification delivery follows your Focus and system settings.")) }
            Section {
                Toggle(L("Show meeting details"), isOn: binding(\.details))
            } footer: { Text(L("When off, notifications show only the scheduled time.")) }
        }.navigationTitle(L("Delivery and privacy"))
    }
}

private struct BackgroundAudioJoinSettingsSection: View {
    @AppStorage(BackgroundAudioJoinPrototype.enabledKey) private var backgroundAudioJoin = BackgroundAudioJoinPrototype.defaultEnabled
    @AppStorage(SystemCallCoordinator.controlsPreferenceKey) private var systemCallControls = false
    @AppStorage("savedDisplayName") private var displayName = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var microphonePermission = AVAudioSession.sharedInstance().recordPermission
    @State private var requestingMicrophone = false

    var body: some View {
        Section {
            Toggle(isOn: $backgroundAudioJoin) {
                Text(L("Join audio from notifications")).fixedSize(horizontal: false, vertical: true)
            }
                .accessibilityIdentifier("reminders.backgroundAudioJoin")
                .onChange(of: backgroundAudioJoin) { _ in
                    BackgroundAudioJoinPrototype.shared.preferencesChanged()
                }
            if backgroundAudioJoin {
                Text(L("Touch and hold a calendar meeting notification, then choose Join audio. A normal tap opens the app."))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("reminders.audioInstructions")
                if !MeetingEngineKind.guest.inputPolicy.accepts(name: displayName) {
                    Text(L("Save your name on Home before joining from a notification."))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("reminders.audioNameRequired")
                }
                if systemCallControls {
                    Text(L("Turn off System call controls in Settings > Phone calls to join without opening the app."))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("reminders.audioSystemControls")
                }
                if microphonePermission != .granted {
                    Text(L("Microphone access is required to connect audio. Your microphone stays off until you turn it on."))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if microphonePermission == .undetermined {
                    Button(L("Allow microphone access")) {
                        requestingMicrophone = true
                        AVAudioSession.sharedInstance().requestRecordPermission { _ in
                            Task { @MainActor in
                                microphonePermission = AVAudioSession.sharedInstance().recordPermission
                                requestingMicrophone = false
                            }
                        }
                    }.disabled(requestingMicrophone).accessibilityIdentifier("reminders.microphonePermission")
                } else if microphonePermission == .denied {
                    Button(L("Allow microphone access in Settings")) {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    }.accessibilityIdentifier("reminders.microphoneSettings")
                }
            }
        } header: { Text(L("Joining from notifications")) } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Join guest meetings without opening the app. Microphone and camera start off."))
                if backgroundAudioJoin {
                    Text(L("If audio cannot connect, a notification asks you to open the app. Live Activity can appear after you open it. Turning this off keeps a connected meeting."))
                }
            }
        }
        .onAppear { microphonePermission = AVAudioSession.sharedInstance().recordPermission }
        .onChange(of: scenePhase) { phase in
            if phase == .active { microphonePermission = AVAudioSession.sharedInstance().recordPermission }
        }
    }
}

struct ReminderTimingEditor: View {
    @Binding var timing: ReminderTiming
    var body: some View {
        Section {
            NavigationLink {
                ReminderDurationView(title: L("Before start"), limit: 86400, value: duration(before: true),
                                     remembered: timing.rememberedBefore)
            } label: { durationLabel(L("Before start"), value: timing.before) }
                .accessibilityIdentifier("reminders.before")
            Toggle(L("At start"), isOn: $timing.atStart).accessibilityIdentifier("reminders.atStart")
            NavigationLink {
                ReminderFollowUpView(timing: $timing)
            } label: { followUpLabel }
                .accessibilityIdentifier("reminders.after")
        }
    }
    private var followUpLabel: some View {
        let policy = timing.followUp
        let summary = policy.mode == .off ? L("Off") : ReminderFormatting.duration(policy.delay) + " · " + policy.mode.title
        return ViewThatFits(in: .horizontal) {
            HStack { Text(L("After start")); Spacer(); Text(summary).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 4) { Text(L("After start")); Text(summary).foregroundStyle(.secondary) }
        }.frame(minHeight: 44)
    }
    private func duration(before: Bool) -> Binding<Int?> {
        Binding(get: { before ? timing.before : timing.after }, set: { seconds in
            if before { timing.before = seconds; if let seconds { timing.rememberedBefore = seconds } }
            else { timing.after = seconds; if let seconds { timing.rememberedAfter = seconds } }
        })
    }
    private func durationLabel(_ title: String, value: Int?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { Text(title); Spacer(); Text(ReminderFormatting.duration(value)).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 4) { Text(title); Text(ReminderFormatting.duration(value)).foregroundStyle(.secondary) }
        }.frame(minHeight: 44)
    }
}

extension ReminderFollowUp.Mode {
    var title: String {
        switch self {
        case .off: L("Off")
        case .anotherMeeting: L("While in another meeting")
        case .always: L("Always")
        }
    }
    var detail: String {
        switch self {
        case .off: L("No after-start reminder.")
        case .anotherMeeting: L("A quiet reminder while this app is open in a different meeting.")
        case .always: L("Remind me even when this app is in the background.")
        }
    }
}

private struct ReminderFollowUpView: View {
    @Binding var timing: ReminderTiming
    var body: some View {
        Form {
            Section {
                ForEach(ReminderFollowUp.Mode.allCases, id: \.self) { mode in
                    Button { timing.followUp.mode = mode } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.title)
                                Text(mode.detail).font(.footnote).foregroundStyle(.secondary)
                            }.fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            if timing.followUp.mode == mode { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }.frame(minHeight: 44)
                    }.accessibilityIdentifier("reminders.followUp." + mode.rawValue)
                        .accessibilityAddTraits(timing.followUp.mode == mode ? .isSelected : [])
                }
            }
            if timing.followUp.mode != .off {
                Section {
                    NavigationLink {
                        ReminderDurationView(title: L("Delay"), limit: 3600, value: Binding(
                            get: { timing.followUp.delay }, set: { if let value = $0 {
                                timing.followUp.delay = value; timing.rememberedAfter = value
                            } }), remembered: timing.followUp.delay, allowsOff: false)
                    } label: { HStack { Text(L("Delay")); Spacer(); Text(ReminderFormatting.duration(timing.followUp.delay)).foregroundStyle(.secondary) } }
                        .accessibilityIdentifier("reminders.followUp.delay")
                }
            }
        }.navigationTitle(L("After start"))
    }
}

private struct ReminderDurationView: View {
    let title: String
    let limit: Int
    @Binding var value: Int?
    let remembered: Int
    var allowsOff = true
    @Environment(\.dismiss) private var dismiss
    @State private var custom = false
    @State private var quantity = "2"
    @State private var unit = 60
    private var seconds: Int? {
        guard let number = Int(quantity), number > 0, number <= limit / unit else { return nil }
        return number * unit
    }
    var body: some View {
        Form {
            if !custom { Section {
                if allowsOff { choice(nil) }
                ForEach([10, 15, 30, 60, 120, 300, 600], id: \.self) { choice($0) }
                Button(L("Custom…")) {
                    let seconds = value ?? remembered
                    unit = seconds % 60 == 0 ? 60 : 1; quantity = String(seconds / unit); custom = true
                }.frame(minHeight: 44).accessibilityIdentifier("reminders.custom")
            } }
            if custom {
                Section {
                    TextField(L("Duration"), text: $quantity).keyboardType(.numberPad)
                        .accessibilityIdentifier("reminders.quantity")
                    Picker(L("Unit"), selection: $unit) {
                        Text(L("Seconds")).tag(1); Text(L("Minutes")).tag(60)
                        if limit > 3600 { Text(L("Hours")).tag(3600) }
                    }
                    if seconds == nil { Text(L("Choose a duration between 1 second and %@.", ReminderFormatting.duration(limit))).foregroundStyle(.secondary) }
                } header: { Text(L("Custom duration")) }
            }
        }.navigationTitle(title)
            .navigationBarBackButtonHidden(custom)
            .toolbar {
                if custom {
                    ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { custom = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Save")) { value = seconds; dismiss() }.disabled(seconds == nil)
                            .accessibilityIdentifier("reminders.saveDuration")
                    }
                }
            }
    }
    private func choice(_ seconds: Int?) -> some View {
        Button { value = seconds; dismiss() } label: {
            HStack {
                Text(ReminderFormatting.duration(seconds)); Spacer()
                if value == seconds { Image(systemName: "checkmark").accessibilityHidden(true) }
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.accessibilityIdentifier("reminders.duration." + (seconds.map(String.init) ?? "off"))
            .accessibilityAddTraits(value == seconds ? .isSelected : [])
    }
}

struct OccurrenceReminderView: View {
    let occurrence: ReminderOccurrence
    @ObservedObject var reminders: CalendarReminderCoordinator
    @Environment(\.dismiss) private var dismiss
    private var override: Binding<ReminderOverride> {
        Binding(get: { reminders.override(for: occurrence) }, set: { reminders.setOverride($0, for: occurrence) })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(ReminderFormatting.safeTitle(occurrence.title)).font(.headline)
                    Text(occurrence.start.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                } footer: { Text(L("For this meeting only.")) }
                if !reminders.enabled {
                    Section {
                        Button(L("Enable reminders on this device")) { Task { await reminders.setEnabled(true) } }
                    }
                }
                Section {
                    Picker(L("Reminders"), selection: Binding(get: { override.wrappedValue.mode }, set: { mode in
                        var value = override.wrappedValue
                        if mode == .custom, !value.customized { value.custom = reminders.profile.timing; value.customized = true }
                        value.mode = mode; override.wrappedValue = value
                    })) {
                        Text(L("Use defaults")).tag(ReminderOverride.Mode.defaults)
                        Text(L("Custom")).tag(ReminderOverride.Mode.custom)
                        Text(L("Off")).tag(ReminderOverride.Mode.off)
                    }.pickerStyle(.inline).labelsHidden()
                }
                if override.wrappedValue.mode == .custom {
                    ReminderTimingEditor(timing: Binding(get: { override.wrappedValue.custom }, set: {
                        var value = override.wrappedValue; value.custom = $0; override.wrappedValue = value
                    }))
                }
                if let error = reminders.error { Text(error).foregroundStyle(.red) }
            }.accessibilityIdentifier("reminders.occurrenceForm")
                .navigationTitle(L("Reminders"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
    }
}

struct ReminderMeetingView: View {
    let occurrence: ReminderOccurrence?
    var activeElsewhere: ActiveJam?
    var switching: Bool
    let onJoin: () -> Void
    let onMove: (ActiveJam) -> Void
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if let occurrence {
                    Section {
                        Text(ReminderFormatting.safeTitle(occurrence.title)).font(.headline)
                        Text(occurrence.start.formatted(date: .abbreviated, time: .shortened))
                        Text(occurrence.room?.displayDetails ?? "").foregroundStyle(.secondary)
                        if occurrence.end <= Date() { Text(L("This meeting's scheduled time has ended.")).foregroundStyle(.secondary) }
                    }
                    if switching { Text(L("Leave the current meeting to join this one?")) }
                    Section {
                        Button(switching ? L("Leave and join") : occurrence.end <= Date() ? L("Join anyway") : activeElsewhere == nil ? L("Join") : L("Join here")) {
                            dismiss(); onJoin()
                        }.frame(minHeight: 44).accessibilityIdentifier("reminders.join")
                        if let activeElsewhere, !switching {
                            Button(L("Move here")) { dismiss(); onMove(activeElsewhere) }.frame(minHeight: 44)
                        }
                    }
                } else { Text(L("This meeting is no longer available.")) }
            }.navigationTitle(L("Meeting reminder"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } } }
        }.onDisappear(perform: onDismiss)
    }
}
