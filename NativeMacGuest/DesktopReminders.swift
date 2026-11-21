import AppKit
import ConferenceCore
import SwiftUI

/// Foreground follow-ups use a nonmodal panel; they never interrupt media or steal focus.
@MainActor final class NativeDesktopReminderPresenter {
    private var panel: NSPanel?
    private var mounted = Set<String>()
    func hide() { panel?.orderOut(nil); mounted = [] }
    func render(_ events: [ReminderForegroundEvent], coordinator: CalendarReminderCoordinator) -> Set<String> {
        let rows = events.compactMap { event in coordinator.occurrence(for: event).map { (event, $0) } }
        guard !rows.isEmpty, NSApp.isActive else { hide(); return [] }
        if panel == nil {
            let value = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
                styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            value.title = L("Meeting reminder"); value.level = .floating; value.hidesOnDeactivate = true
            value.isReleasedWhenClosed = false; panel = value
        }
        panel?.contentView = NSHostingView(rootView: ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(rows, id: \.0.id) { event, occurrence in
                VStack(alignment: .leading, spacing: 8) {
                    Text(coordinator.profile.details ? occurrence.title : L("Scheduled meeting")).font(.headline).lineLimit(2)
                    Text(occurrence.start, style: .time).foregroundStyle(.secondary)
                    HStack {
                        Button(L("Join")) { coordinator.open(reference: occurrence.reference, join: true) }.buttonStyle(.borderedProminent)
                        Button(L("Later")) { Task { await coordinator.action(reference: occurrence.reference, snooze: true, scope: event.scope) } }
                        Button(L("Skip")) { Task { await coordinator.action(reference: occurrence.reference, snooze: false, scope: event.scope) } }
                    }
                }
            }
        }.padding(20).frame(width: 380)
        })
        if let panel, let visible = NSScreen.main?.visibleFrame {
            let height = min(CGFloat(rows.count) * 140 + 20, max(180, visible.height - 48))
            let isRTL = NSApp.userInterfaceLayoutDirection == .rightToLeft
            let originX = isRTL ? visible.minX + 24 : visible.maxX - 404
            panel.setFrame(NSRect(x: originX, y: visible.maxY - height - 24, width: 380, height: height), display: true)
            panel.orderFrontRegardless()
            mounted = Set(rows.map { $0.0.id })
        }
        return mounted
    }
}

struct NativeDesktopReminderTimingEditor: View {
    @Binding var timing: ReminderTiming
    var body: some View {
        NativeSettingsSwitch(
            title: L("Before start"),
            isOn: Binding(get: { timing.before != nil }, set: { timing.before = $0 ? timing.rememberedBefore : nil }),
            id: "settings.reminder-before",
            fallbackFor: timing.before == nil ? ["settings.reminder-before-time", "settings.reminder-timing"] : ["settings.reminder-timing"]
        )
        if timing.before != nil {
            HStack {
                NativeSettingsStepper(
                    title: L("Before: %d seconds", timing.before ?? 120),
                    value: Binding(get: { timing.before ?? 120 }, set: { value in
                        var updated = timing
                        updated.before = value
                        updated.rememberedBefore = value
                        timing = updated
                    }),
                    range: 1...86_400,
                    id: "settings.reminder-before-time"
                )
                Menu(L("Common times")) {
                    ForEach([1, 2, 5, 10, 15], id: \.self) { minutes in
                        Button(minutes == 1 ? L("1 minute") : L("%ld minutes", minutes)) {
                            var updated = timing
                            updated.before = minutes * 60
                            updated.rememberedBefore = minutes * 60
                            timing = updated
                        }
                    }
                }
            }
        }
        NativeSettingsSwitch(title: L("At start"), isOn: $timing.atStart, id: "settings.reminder-at-start")
        NativeSettingsPopup(
            title: L("After start"), selection: $timing.followUp.mode, choices: ReminderFollowUp.Mode.allCases,
            titleForChoice: { mode in
                switch mode {
                case .off: L("Off")
                case .anotherMeeting: L("If in another meeting")
                case .always: L("Always")
                }
            },
            id: "settings.reminder-follow-up",
            fallbackFor: timing.followUp.mode == .off ? ["settings.reminder-follow-up-delay"] : []
        )
        if timing.followUp.mode != .off {
            HStack {
                NativeSettingsStepper(title: L("Delay: %d seconds", timing.followUp.delay),
                                      value: $timing.followUp.delay, range: 1...3600,
                                      id: "settings.reminder-follow-up-delay")
                Menu(L("Common times")) {
                    ForEach([1, 2, 5, 10, 15], id: \.self) { minutes in
                        Button(minutes == 1 ? L("1 minute") : L("%ld minutes", minutes)) { timing.followUp.delay = minutes * 60 }
                    }
                }
            }
        }
    }
}

struct NativeDesktopOccurrenceReminderView: View {
    let occurrence: ReminderOccurrence
    @ObservedObject var reminders: CalendarReminderCoordinator
    private var override: Binding<ReminderOverride> {
        Binding(get: { reminders.override(for: occurrence) }, set: { reminders.setOverride($0, for: occurrence) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(occurrence.title).font(.title2.bold())
            Text(occurrence.start.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            Form {
                Picker(L("Reminders"), selection: Binding(get: { override.wrappedValue.mode }, set: { mode in
                    var value = override.wrappedValue
                    if mode == .custom, !value.customized { value.custom = reminders.profile.timing; value.customized = true }
                    value.mode = mode; override.wrappedValue = value
                })) {
                    Text(L("Use defaults")).tag(ReminderOverride.Mode.defaults)
                    Text(L("Custom")).tag(ReminderOverride.Mode.custom)
                    Text(L("Off")).tag(ReminderOverride.Mode.off)
                }
                if override.wrappedValue.mode == .custom {
                    NativeDesktopReminderTimingEditor(timing: Binding(get: { override.wrappedValue.custom }, set: {
                        var value = override.wrappedValue; value.custom = $0; override.wrappedValue = value
                    }))
                }
            }
            HStack { Spacer(); Button(L("Done")) { reminders.editing = nil }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 460)
    }
}
