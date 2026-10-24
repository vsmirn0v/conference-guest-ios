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
            panel.setFrame(NSRect(x: visible.maxX - 404, y: visible.maxY - height - 24, width: 380, height: height), display: true)
            panel.orderFrontRegardless()
            mounted = Set(rows.map { $0.0.id })
        }
        return mounted
    }
}

struct NativeDesktopReminderTimingEditor: View {
    @Binding var timing: ReminderTiming
    var body: some View {
        Toggle(L("Before start"), isOn: Binding(get: { timing.before != nil }, set: { timing.before = $0 ? timing.rememberedBefore : nil }))
        if timing.before != nil {
            Stepper(value: Binding(get: { timing.before ?? 120 }, set: { timing.before = $0; timing.rememberedBefore = $0 }), in: 1...86400) { Text(L("Before: %d seconds", timing.before ?? 120)) }
        }
        Toggle(L("At start"), isOn: $timing.atStart)
        Picker(L("After start"), selection: $timing.followUp.mode) {
            Text(L("Off")).tag(ReminderFollowUp.Mode.off)
            Text(L("If in another meeting")).tag(ReminderFollowUp.Mode.anotherMeeting)
            Text(L("Always")).tag(ReminderFollowUp.Mode.always)
        }
        if timing.followUp.mode != .off {
            Stepper(value: $timing.followUp.delay, in: 1...3600) { Text(L("Delay: %d seconds", timing.followUp.delay)) }
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
