import AppKit
import SwiftUI

/// Stable identifiers contain no user data. Catalog construction never opens a
/// feature view, queries a device, reads credentials, or starts a service.
enum NativeSettingsSearchCatalog {
    struct Entry: Identifiable {
        let id: String
        let title: String
        let tab: Int
        let assistantArea: NativeDesktopAssistantSettingsArea?
        let section: String

        /// These controls only appear after an explicit feature or engine choice.
        var requiresPrerequisite: Bool {
            ["settings.handoff", "settings.sync-recent", "settings.sync-workspace", "settings.sync-calendar",
             "settings.sync-transcripts", "settings.sync-now",
             "settings.calendar-privacy", "settings.calendar-refresh", "settings.reminder-before-time",
             "settings.reminder-follow-up-delay", "settings.voice-detector",
             "settings.provider-address", "settings.provider-model", "settings.api-key", "settings.provider-choose",
             "settings.escalation-model", "settings.escalation-key", "settings.writer-model", "settings.writer-key",
             "settings.remote-outcomes", "settings.local-drafts",
             "settings.agent-mcp", "settings.meeting-sends", "settings.voice-model",
             "settings.voice-description", "settings.voice-address", "settings.saved-voice",
             "settings.voice-preparation", "settings.voice-download", "settings.voice-delete", "settings.voice-gpu",
             "settings.voice-gpu-remove", "settings.headphone-approval"].contains(id)
        }

        init(_ id: String, _ title: String, _ tab: Int, _ section: String,
             _ assistantArea: NativeDesktopAssistantSettingsArea? = nil) {
            self.id = "settings." + id
            self.title = title
            self.tab = tab
            self.section = section
            self.assistantArea = assistantArea
        }
    }

    static let entries: [Entry] = [
        .init("display-name", "Display name", 0, "General"),
        .init("website", "Guest meeting website", 0, "General"),
        .init("setup", "Review meeting setup…", 0, "General"),
        .init("relay", "Use TCP/TLS relay only", 0, "General"),
        .init("mic-warm", "Keep the microphone ready in every meeting (experimental)", 3, "Camera & sound"),
        .init("headset", "Mute with AirPods and headset buttons", 3, "Camera & sound"),
        .init("sync", "Sync with iCloud", 0, "General"),
        .init("handoff", "Show active jams on my devices", 0, "General"),
        .init("sync-recent", "Include recent jams", 0, "General"),
        .init("sync-workspace", "Sync meeting history, summaries, notes & tasks", 0, "General"),
        .init("sync-calendar", "Share calendar schedule", 0, "General"),
        .init("sync-transcripts", "Raw transcript sync", 0, "General"),
        .init("transcript-archive", "Transcript backup folder", 0, "General"),
        .init("sync-now", "Sync now", 0, "General"),
        .init("calendar-enabled", "Find meetings in Calendar", 1, "Calendars"),
        .init("calendar-selection", "Choose calendars", 1, "Calendars"),
        .init("calendar-privacy", "Open calendar privacy settings", 1, "Calendars"),
        .init("calendar-refresh", "Check Again", 1, "Calendars"),
        .init("menu-bar", "Keep running in menu bar", 1, "Calendars"),
        .init("auto-join", "Join scheduled meetings", 1, "Calendars"),
        .init("reminders", "Meeting reminders", 2, "Reminders"),
        .init("reminder-timing", "Reminder timing", 2, "Reminders"),
        .init("reminder-before", "Before start", 2, "Reminders"),
        .init("reminder-before-time", "Time before start", 2, "Reminders"),
        .init("reminder-at-start", "At start", 2, "Reminders"),
        .init("reminder-follow-up", "After start", 2, "Reminders"),
        .init("reminder-follow-up-delay", "Follow-up delay", 2, "Reminders"),
        .init("reminder-name", "Show meeting name", 2, "Reminders"),
        .init("reminder-sound", "Sound", 2, "Reminders"),
        .init("reminder-sensitive", "Time Sensitive", 2, "Reminders"),
        .init("reminder-other-devices", "Skip when active on another device", 2, "Reminders"),
        .init("notification-settings", "Open notification settings", 2, "Reminders"),
        .init("microphone", "Microphone", 3, "Camera & sound"),
        .init("output", "Output", 3, "Camera & sound"),
        .init("microphone-test", "Check microphone privately", 3, "Camera & sound"),
        .init("audio-profile", "Audio profile", 3, "Camera & sound"),
        .init("mic-readiness", "Microphone readiness", 3, "Camera & sound"),
        .init("camera", "Camera", 3, "Camera & sound"),
        .init("camera-test", "Check camera privately", 3, "Camera & sound"),
        .init("camera-reactions", "Share camera reactions", 3, "Camera & sound"),
        .init("camera-readiness", "Camera readiness", 3, "Camera & sound"),
        .init("version", "Installed version", 4, "Updates"),
        .init("update-check", "Automatically check for updates", 4, "Updates"),
        .init("update-download", "Automatically download updates", 4, "Updates"),
        .init("update-channel", "Beta updates", 4, "Updates"),
        .init("check-updates", "Check for Updates…", 4, "Updates"),
        .init("transcribe", "Transcribe meetings on this Mac", 5, "Transcription"),
        .init("transcribe-mic", "Include my microphone", 5, "Transcription"),
        .init("transcribe-external", "Telemost and TrueConf", 5, "Transcription"),
        .init("transcribe-rock", "Rock jam sessions", 5, "Transcription"),
        .init("speech-model", "Speech model", 5, "Transcription"),
        .init("voice-detector", "Voice detector", 5, "Transcription"),
        .init("transcription-model-status", "On-device models", 5, "Transcription"),
        .init("alerts", "Tell me when a meeting needs me", 6, "Attention", .attention),
        .init("battery", "Pause on battery power", 6, "Attention", .attention),
        .init("outcomes", "Create a meeting outcome when I leave", 6, "Replies", .replies),
        .init("remote-outcomes", "Allow sending the transcript when I leave", 6, "Replies", .replies),
        .init("outcomes-same-room", "Back-to-back meetings in the same room", 6, "Replies", .replies),
        .init("names", "Your name", 6, "Attention", .attention),
        .init("aliases", "Other names", 6, "Attention", .attention),
        .init("role", "Your role", 6, "Attention", .attention),
        .init("instructions", "Meeting instructions", 6, "Attention", .attention),
        .init("provider", "Provider", 6, "Models", .models),
        .init("provider-address", "Address", 6, "Models", .models),
        .init("provider-model", "Model", 6, "Models", .models),
        .init("api-key", "API key", 6, "Models", .models),
        .init("provider-choose", "Choose provider model…", 6, "Models", .models),
        .init("provider-compare", "Compare models…", 6, "Models", .models),
        .init("provider-test", "Test provider", 6, "Models", .models),
        .init("escalation", "When the judge is unsure, ask", 6, "Models", .models),
        .init("escalation-model", "Model to ask", 6, "Models", .models),
        .init("escalation-key", "Escalation API key", 6, "Models", .models),
        .init("assistant-model-status", "On-device models", 6, "Models", .models),
        .init("drafts", "Draft chat replies and reactions on cards", 6, "Replies", .replies),
        .init("reply-style", "How you write", 6, "Replies", .replies),
        .init("writer", "Write replies with", 6, "Models", .models),
        .init("writer-model", "Writer model", 6, "Models", .models),
        .init("writer-key", "Writer API key", 6, "Models", .models),
        .init("local-drafts", "Draft with the model on this Mac anyway", 6, "Replies", .replies),
        .init("agent", "Answer with the bounded agent (typed tools, grounded sources)", 6, "Replies", .replies),
        .init("agent-mcp", "Also offer read-only MCP tools", 6, "Replies", .replies),
        .init("meeting-sends", "Meeting sends", 6, "Replies", .replies),
        .init("push-talk", "Hold ⌥Space to talk to Assistant", 6, "Voice", .voice),
        .init("talk-back", "Speak Assistant answers in headphones", 6, "Voice", .voice),
        .init("headphone-approval", "This is a headphone", 6, "Voice", .voice),
        .init("voice-engine", "Speak replies with", 6, "Voice", .voice),
        .init("voice-model", "Voice model", 6, "Voice", .voice),
        .init("voice-description", "How the voice sounds", 6, "Voice", .voice),
        .init("voice-address", "Address", 6, "Voice", .voice),
        .init("voice-preview", "Listen", 6, "Voice", .voice),
        .init("saved-voice", "Record Your Voice…", 6, "Voice", .voice),
        .init("voice-delete", "Delete Saved Voice…", 6, "Voice", .voice),
        .init("voice-download", "Download model", 6, "Voice", .voice),
        .init("voice-preparation", "Prepare for the Neural Engine", 6, "Voice", .voice),
        .init("voice-gpu", "GPU fallback", 6, "Voice", .voice),
        .init("voice-gpu-remove", "Remove GPU model", 6, "Voice", .voice),
        .init("memory", "Memory", 6, "Memory and privacy", .privacy),
        .init("memory-add", "Add memory", 6, "Memory and privacy", .privacy),
        .init("memory-retention", "Keep local memory for", 6, "Memory and privacy", .privacy),
        .init("memory-export", "Export memory…", 6, "Memory and privacy", .privacy),
        .init("memory-delete", "Delete all assistant memory…", 6, "Memory and privacy", .privacy),
        .init("privacy", "What leaves this Mac", 6, "Memory and privacy", .privacy),
        .init("mcp", "MCP Server", 7, "MCP Server"),
        .init("mcp-endpoint", "Endpoint file", 7, "MCP Server"),
        .init("mcp-pairing", "Copy pairing instructions", 7, "MCP Server"),
        .init("mcp-clients", "Paired clients", 7, "MCP Server"),
        .init("mcp-capabilities", "Capabilities", 7, "MCP Server"),
        .init("obsidian", "Export meetings to Obsidian", 8, "Integrations"),
        .init("obsidian-after", "Save to vault after the meeting", 8, "Integrations"),
        .init("obsidian-updates", "Automatically export updates to Obsidian", 8, "Integrations"),
        .init("obsidian-layout", "Format and placement…", 8, "Integrations"),
        .init("obsidian-vault", "Choose Vault…", 8, "Integrations")
    ] + AttentionSituation.allCases.map { .init($0.settingsSearchID, $0.titleKey, 6, "Attention by situation", .attention) } + supportEntries

    private static var supportEntries: [Entry] {
        #if NATIVE_DIRECT_UPDATES
        return [.init("author-support", SupportCopy.text("Support the author"), SupportCopy.settingsTab, "App")]
        #else
        return []
        #endif
    }

    static func search(query: String, availableTabs: Set<Int>) -> [Entry] {
        func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let normalized = fold(trimmed)
        let tokens = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return entries.enumerated().compactMap { index, entry -> (Int, Int, Entry)? in
            guard availableTabs.contains(entry.tab) else { return nil }
            let titles = [fold(L(entry.title)), fold(entry.title)]
            let description = NativeSettingsResultPresentation.descriptionKey(for: entry)
            let area = entry.assistantArea.map { fold($0.title) } ?? ""
            var corpus = (titles + [fold(L(entry.section)), fold(entry.section), area, fold(L(description)), fold(description)]).joined(separator: " ")
            #if NATIVE_DIRECT_UPDATES
            if entry.tab == SupportCopy.settingsTab { corpus += " " + fold(SupportCopy.text("donate donation gift tip subscription")) }
            #endif
            guard tokens.allSatisfy({ corpus.contains($0) }) else { return nil }
            let score = titles.map { title in
                (title == normalized ? 100 : 0) + (title.hasPrefix(normalized) ? 30 : 0)
                    + tokens.filter { title.contains($0) }.count * 10
            }.max() ?? 0
            return (score, index, entry)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.map { $0.2 }
    }
}

private struct NativeSettingRevealKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var nativeSettingRevealID: String? {
        get { self[NativeSettingRevealKey.self] }
        set { self[NativeSettingRevealKey.self] = newValue }
    }
}

private struct NativeSettingsFocusScopeKey: EnvironmentKey {
    static let defaultValue: NativeSettingsFocusScope? = nil
}

private extension EnvironmentValues {
    var nativeSettingsFocusScope: NativeSettingsFocusScope? {
        get { self[NativeSettingsFocusScopeKey.self] }
        set { self[NativeSettingsFocusScopeKey.self] = newValue }
    }
}

struct NativeSettingScrollTarget: PreferenceKey {
    struct Selection: Equatable {
        let requestID: String
        let anchorID: String
        let isEnabled: Bool

        var availabilityMessage: String? {
            if !isEnabled { return L("This setting is currently unavailable.") }
            if requestID != anchorID,
               NativeSettingsSearchCatalog.entries.first(where: { $0.id == requestID })?.requiresPrerequisite == true {
                return L("This setting may require another selection or feature to be enabled.")
            }
            return nil
        }
    }

    static let defaultValue: Selection? = nil

    static func reduce(value: inout Selection?, nextValue: () -> Selection?) {
        guard let next = nextValue() else { return }
        if value == nil || next.requestID == next.anchorID { value = next }
    }
}

private struct NativeSettingAnchor: ViewModifier {
    @Environment(\.nativeSettingRevealID) private var selected
    @Environment(\.nativeSettingsFocusScope) private var focusScope
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool
    let id: String
    let fallbackFor: Set<String>
    let nativeControlFocus: Bool
    let onFocusChange: (Bool) -> Void
    private var target: String? { selected == id || selected.map(fallbackFor.contains) == true ? selected : nil }

    func body(content: Content) -> some View {
        content.id(id)
            .preference(key: NativeSettingScrollTarget.self,
                        value: target.map { .init(requestID: $0, anchorID: id, isEnabled: isEnabled) })
            .focused($focused)
            .background(target == nil ? Color.clear : Color.accentColor.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 6))
            .background {
                if nativeControlFocus, isEnabled, let target, let focusScope {
                    NativeSettingFocusProbe(id: target, scope: focusScope) {
                        focused = true
                        return true
                    }.accessibilityHidden(true)
                }
            }
            .onChange(of: focused) { onFocusChange($0) }
            .onDisappear { if focused { onFocusChange(false) } }
    }
}

/// A focus request stays in the key window that accepted the result.
@MainActor
private final class NativeSettingsFocusScope {
    private struct Target {
        let id: String
        weak var view: NSView?
        let focus: () -> Bool
    }

    private var targets: [ObjectIdentifier: Target] = [:]
    private var activityMonitor: Any?
    private var keyWindowObserver: NSObjectProtocol?
    private weak var requestWindow: NSWindow?
    private var requestID: String?

    func register(id: String, view: NSView, focus: @escaping () -> Bool) {
        targets[ObjectIdentifier(view)] = Target(id: id, view: view, focus: focus)
    }

    func unregister(_ view: NSView) {
        targets.removeValue(forKey: ObjectIdentifier(view))
    }

    func begin(_ id: String) {
        cancel()
        guard let window = NSApp.keyWindow else { return }
        requestID = id
        requestWindow = window
        activityMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            self?.cancel()
            return event
        }
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    func isPending(_ id: String) -> Bool { requestID == id }

    func cancel() {
        requestID = nil
        requestWindow = nil
        if let activityMonitor {
            NSEvent.removeMonitor(activityMonitor)
            self.activityMonitor = nil
        }
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
            self.keyWindowObserver = nil
        }
    }

    func focus(_ id: String) {
        guard isPending(id), let window = requestWindow, window.isKeyWindow else { return }
        let matching = targets.values.filter { target in
            guard target.id == id, let view = target.view, view.window === window,
                  !view.isHiddenOrHasHiddenAncestor, let content = window.contentView else { return false }
            let visible = view.bounds.intersection(view.visibleRect)
            guard !visible.isEmpty else { return false }
            return view.convert(visible, to: content).intersects(content.bounds)
        }
        guard matching.count == 1, let target = matching.first else { return }
        if target.focus() { cancel() }
    }
}

private struct NativeSettingFocusProbe: NSViewRepresentable {
    let id: String
    let scope: NativeSettingsFocusScope
    let focus: () -> Bool

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.register(view, scope: scope, id: id, focus: focus)
    }

    func makeCoordinator() -> NativeSettingFocusRegistration { .init() }

    static func dismantleNSView(_ view: NSView, coordinator: NativeSettingFocusRegistration) {
        coordinator.unregister(view)
    }
}

@MainActor
private final class NativeSettingFocusRegistration {
    private weak var scope: NativeSettingsFocusScope?

    func register(_ view: NSView, scope: NativeSettingsFocusScope?, id: String?, focus: @escaping () -> Bool) {
        if self.scope !== scope || id == nil { unregister(view) }
        guard let id else { return }
        self.scope = scope
        scope?.register(id: id, view: view, focus: focus)
    }

    func register(_ control: NSControl, scope: NativeSettingsFocusScope?, id: String?) {
        register(control, scope: scope, id: control.isEnabled ? id : nil) { [weak control] in
            guard let control, control.isEnabled, control.acceptsFirstResponder, let window = control.window else { return false }
            return window.makeFirstResponder(control) && window.firstResponder === control
        }
    }

    func unregister(_ view: NSView) {
        scope?.unregister(view)
        scope = nil
    }
}

/// AppKit switches can take an explicit first-responder request even when ordinary
/// keyboard navigation covers only text inputs. The native switch handles Space.
struct NativeSettingsSwitch: View {
    let title: String
    @Binding var isOn: Bool
    let id: String
    var fallbackFor: Set<String> = []
    var accessibilityID: String? = nil
    @Environment(\.nativeSettingRevealID) private var selected
    @Environment(\.nativeSettingsFocusScope) private var focusScope

    var body: some View {
        LabeledContent {
            NativeSettingsSwitchControl(title: title, isOn: $isOn, accessibilityID: accessibilityID ?? id,
                                        requestID: selected == id || selected.map(fallbackFor.contains) == true ? selected : nil,
                                        focusScope: focusScope)
        } label: {
            Text(title)
        }
        .nativeSettingAnchor(id, fallbackFor: fallbackFor)
    }
}

private struct NativeSettingsSwitchControl: NSViewRepresentable {
    let title: String
    @Binding var isOn: Bool
    let accessibilityID: String
    let requestID: String?
    let focusScope: NativeSettingsFocusScope?
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> Switch {
        let view = Switch()
        view.target = view
        view.action = #selector(Switch.valueChanged)
        return view
    }

    func updateNSView(_ view: Switch, context: Context) {
        view.isEnabled = isEnabled
        view.setAccessibilityLabel(title)
        view.setAccessibilityIdentifier(accessibilityID)
        view.readState = { isOn ? .on : .off }
        view.onChange = { value in
            if isOn != value { isOn = value }
        }
        view.reconcileState()
        context.coordinator.register(view, scope: focusScope, id: requestID)
    }

    func makeCoordinator() -> NativeSettingFocusRegistration { .init() }

    static func dismantleNSView(_ view: Switch, coordinator: NativeSettingFocusRegistration) {
        coordinator.unregister(view)
    }

    final class Switch: NSSwitch {
        var readState: () -> NSControl.StateValue = { .off }
        var onChange: (Bool) -> Void = { _ in }

        // Leave traversal of ordinary controls to the user's keyboard setting.
        override var canBecomeKeyView: Bool {
            NSApp.isFullKeyboardAccessEnabled && super.canBecomeKeyView
        }

        func reconcileState() {
            let actual = readState()
            if state != actual { state = actual }
        }

        @objc func valueChanged() {
            guard isEnabled else { return }
            onChange(state == .on)
            // A setter can decline the request without scheduling a view update.
            DispatchQueue.main.async { [weak self] in self?.reconcileState() }
        }
    }
}

struct NativeSettingsPopup<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [Value]
    let titleForChoice: (Value) -> String
    let id: String
    var fallbackFor: Set<String> = []
    var accessibilityID: String? = nil
    var showsLabel = true
    @Environment(\.nativeSettingRevealID) private var selected
    @Environment(\.nativeSettingsFocusScope) private var focusScope

    var body: some View {
        Group {
            if showsLabel {
                LabeledContent { control } label: { Text(title) }
            } else {
                control
            }
        }
        .nativeSettingAnchor(id, fallbackFor: fallbackFor)
    }

    private var control: some View {
        Popup(title: title, selection: $selection, choices: choices.map { ($0, titleForChoice($0)) },
              accessibilityID: accessibilityID ?? id,
              requestID: selected == id || selected.map(fallbackFor.contains) == true ? selected : nil,
              focusScope: focusScope)
    }

    private struct Popup: NSViewRepresentable {
        let title: String
        @Binding var selection: Value
        let choices: [(value: Value, title: String)]
        let accessibilityID: String
        let requestID: String?
        let focusScope: NativeSettingsFocusScope?
        @Environment(\.isEnabled) private var isEnabled

        func makeNSView(context: Context) -> PopupButton {
            let view = PopupButton(frame: .zero, pullsDown: false)
            view.autoenablesItems = false
            return view
        }

        func updateNSView(_ view: PopupButton, context: Context) {
            view.isEnabled = isEnabled
            view.setAccessibilityLabel(title)
            view.setAccessibilityIdentifier(accessibilityID)
            let titles = choices.map(\.title)
            if view.itemTitles != titles {
                view.removeAllItems()
                // Populate NSMenu directly so equal localized titles can retain
                // distinct item identities and typed selection values.
                for title in titles {
                    let item = NSMenuItem(title: title, action: #selector(PopupButton.choose(_:)), keyEquivalent: "")
                    item.target = view
                    view.menu?.addItem(item)
                }
                view.invalidateIntrinsicContentSize()
            }
            view.readIndex = { choices.firstIndex { $0.value == selection } }
            view.onChange = { index in
                guard choices.indices.contains(index) else { return }
                let value = choices[index].value
                if selection != value { selection = value }
            }
            view.reconcileSelection()
            context.coordinator.register(view, scope: focusScope, id: requestID)
        }

        func makeCoordinator() -> NativeSettingFocusRegistration { .init() }

        static func dismantleNSView(_ view: PopupButton, coordinator: NativeSettingFocusRegistration) {
            coordinator.unregister(view)
        }
    }
}

private final class PopupButton: NSPopUpButton {
    var readIndex: () -> Int? = { nil }
    var onChange: (Int) -> Void = { _ in }

    override var canBecomeKeyView: Bool {
        NSApp.isFullKeyboardAccessEnabled && super.canBecomeKeyView
    }

    func reconcileSelection() {
        let selectedIndex = readIndex()
        if (selectedIndex ?? -1) != indexOfSelectedItem {
            select(selectedIndex.flatMap(item(at:)))
        }
    }

    @objc func choose(_ item: NSMenuItem) {
        let index = index(of: item)
        guard isEnabled, index >= 0 else { return }
        onChange(index)
        // Use the latest binding after menu tracking unwinds. If the model
        // publishes a later change, updateNSView applies that value in turn.
        DispatchQueue.main.async { [weak self] in self?.reconcileSelection() }
    }
}

struct NativeSettingsSegmented<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [Value]
    let titleForChoice: (Value) -> String
    let id: String
    let accessibilityID: String
    @Environment(\.nativeSettingRevealID) private var selected
    @Environment(\.nativeSettingsFocusScope) private var focusScope

    var body: some View {
        Control(title: title, selection: $selection, choices: choices.map { ($0, titleForChoice($0)) },
                accessibilityID: accessibilityID, requestID: selected == id ? id : nil, focusScope: focusScope)
            .fixedSize()
            .nativeSettingAnchor(id)
    }

    private struct Control: NSViewRepresentable {
        let title: String
        @Binding var selection: Value
        let choices: [(value: Value, title: String)]
        let accessibilityID: String
        let requestID: String?
        let focusScope: NativeSettingsFocusScope?
        @Environment(\.isEnabled) private var isEnabled

        func makeNSView(context: Context) -> SegmentedControl {
            let view = SegmentedControl()
            view.trackingMode = .selectOne
            view.target = view
            view.action = #selector(SegmentedControl.valueChanged)
            return view
        }

        func updateNSView(_ view: SegmentedControl, context: Context) {
            view.isEnabled = isEnabled
            view.setAccessibilityLabel(title)
            view.setAccessibilityIdentifier(accessibilityID)
            let titles = choices.map(\.title)
            if (0..<view.segmentCount).map({ view.label(forSegment: $0) ?? "" }) != titles {
                view.segmentCount = titles.count
                for (index, title) in titles.enumerated() { view.setLabel(title, forSegment: index) }
                view.invalidateIntrinsicContentSize()
            }
            view.readIndex = { choices.firstIndex { $0.value == selection } ?? -1 }
            view.onChange = { index in
                guard choices.indices.contains(index) else { return }
                let choice = choices[index].value
                if choice != selection { selection = choice }
            }
            view.reconcileSelection()
            context.coordinator.register(view, scope: focusScope, id: requestID)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: SegmentedControl, context: Context) -> CGSize? {
            nsView.intrinsicContentSize
        }

        func makeCoordinator() -> NativeSettingFocusRegistration { .init() }

        static func dismantleNSView(_ view: SegmentedControl, coordinator: NativeSettingFocusRegistration) {
            coordinator.unregister(view)
        }
    }

    private final class SegmentedControl: NSSegmentedControl {
        var readIndex: () -> Int = { -1 }
        var onChange: (Int) -> Void = { _ in }
        private var pendingDisable = false

        override var isEnabled: Bool {
            get { super.isEnabled && !pendingDisable }
            set {
                guard !newValue, window?.firstResponder === self else {
                    pendingDisable = false
                    if super.isEnabled != newValue { super.isEnabled = newValue }
                    return
                }
                guard !pendingDisable else { return }
                pendingDisable = true
                // A cell disabled while focused asks AppKit to traverse the key
                // loop. Wait until SwiftUI has applied its environment update.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.pendingDisable else { return }
                    if self.window?.firstResponder === self { self.window?.makeFirstResponder(nil) }
                    self.pendingDisable = false
                    self.isEnabled = false
                }
            }
        }

        override var acceptsFirstResponder: Bool { isEnabled }
        override var canBecomeKeyView: Bool {
            NSApp.isFullKeyboardAccessEnabled && super.canBecomeKeyView
        }

        func reconcileSelection() {
            let index = readIndex()
            if selectedSegment != index { selectedSegment = index }
        }

        @objc func valueChanged() {
            guard isEnabled else { return }
            onChange(selectedSegment)
            DispatchQueue.main.async { [weak self] in self?.reconcileSelection() }
        }
    }
}

struct NativeSettingsStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let id: String
    @Environment(\.nativeSettingRevealID) private var selected
    @Environment(\.nativeSettingsFocusScope) private var focusScope

    var body: some View {
        LabeledContent {
            Control(title: title, value: $value, range: range, id: id,
                    requestID: selected == id ? id : nil, focusScope: focusScope)
        } label: {
            Text(title)
        }.nativeSettingAnchor(id)
    }

    private struct Control: NSViewRepresentable {
        let title: String
        @Binding var value: Int
        let range: ClosedRange<Int>
        let id: String
        let requestID: String?
        let focusScope: NativeSettingsFocusScope?
        @Environment(\.isEnabled) private var isEnabled

        func makeNSView(context: Context) -> Stepper {
            let view = Stepper()
            view.valueWraps = false
            view.autorepeat = true
            view.target = view
            view.action = #selector(Stepper.valueChanged)
            return view
        }

        func updateNSView(_ view: Stepper, context: Context) {
            view.isEnabled = isEnabled
            view.minValue = Double(range.lowerBound)
            view.maxValue = Double(range.upperBound)
            view.setAccessibilityLabel(title)
            view.setAccessibilityIdentifier(id)
            view.readValue = { value }
            view.onChange = { if value != $0 { value = $0 } }
            view.reconcileValue()
            context.coordinator.register(view, scope: focusScope, id: requestID)
        }

        func makeCoordinator() -> NativeSettingFocusRegistration { .init() }

        static func dismantleNSView(_ view: Stepper, coordinator: NativeSettingFocusRegistration) {
            coordinator.unregister(view)
        }
    }

    private final class Stepper: NSStepper {
        var readValue: () -> Int = { 0 }
        var onChange: (Int) -> Void = { _ in }

        override var acceptsFirstResponder: Bool { isEnabled }
        override var canBecomeKeyView: Bool {
            NSApp.isFullKeyboardAccessEnabled && super.canBecomeKeyView
        }

        func reconcileValue() {
            let actual = readValue()
            if integerValue != actual { integerValue = actual }
        }

        override func moveUp(_ sender: Any?) { step(by: 1) }
        override func moveDown(_ sender: Any?) { step(by: -1) }

        override func keyDown(with event: NSEvent) {
            switch event.specialKey {
            case .upArrow: moveUp(self)
            case .downArrow: moveDown(self)
            default: super.keyDown(with: event)
            }
        }

        private func step(by amount: Int) {
            guard isEnabled else { return }
            integerValue = min(Int(maxValue), max(Int(minValue), integerValue + amount))
            valueChanged()
        }

        @objc func valueChanged() {
            guard isEnabled else { return }
            onChange(integerValue)
            DispatchQueue.main.async { [weak self] in self?.reconcileValue() }
        }
    }
}

struct NativeSettingsButton: View {
    let title: String
    var role: ButtonRole? = nil
    let id: String
    var fallbackFor: Set<String> = []
    var accessibilityID: String? = nil
    let action: () -> Void
    @Environment(\.nativeSettingRevealID) private var selected
    @Environment(\.nativeSettingsFocusScope) private var focusScope

    var body: some View {
        Control(title: title, destructive: role == .destructive, accessibilityID: accessibilityID ?? id,
                requestID: selected == id || selected.map(fallbackFor.contains) == true ? selected : nil,
                focusScope: focusScope, action: action)
            .nativeSettingAnchor(id, fallbackFor: fallbackFor)
    }

    private struct Control: NSViewRepresentable {
        let title: String
        let destructive: Bool
        let accessibilityID: String
        let requestID: String?
        let focusScope: NativeSettingsFocusScope?
        let action: () -> Void
        @Environment(\.isEnabled) private var isEnabled

        func makeNSView(context: Context) -> PushButton {
            let view = PushButton()
            view.bezelStyle = .rounded
            view.target = view
            view.action = #selector(PushButton.press)
            return view
        }

        func updateNSView(_ view: PushButton, context: Context) {
            view.title = title
            view.isEnabled = isEnabled
            view.hasDestructiveAction = destructive
            view.setAccessibilityIdentifier(accessibilityID)
            view.onPress = action
            context.coordinator.register(view, scope: focusScope, id: requestID)
        }

        func makeCoordinator() -> NativeSettingFocusRegistration { .init() }

        static func dismantleNSView(_ view: PushButton, coordinator: NativeSettingFocusRegistration) {
            coordinator.unregister(view)
        }
    }

    private final class PushButton: NSButton {
        var onPress: () -> Void = {}

        override var canBecomeKeyView: Bool {
            NSApp.isFullKeyboardAccessEnabled && super.canBecomeKeyView
        }

        @objc func press() { onPress() }
    }
}

private struct NativeSettingsReveal: ViewModifier {
    @Environment(\.nativeSettingRevealID) private var selected
    @State private var focusScope = NativeSettingsFocusScope()
    @State private var scrollTarget: NativeSettingScrollTarget.Selection?

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .environment(\.nativeSettingsFocusScope, focusScope)
                .onPreferenceChange(NativeSettingScrollTarget.self) { scrollTarget = $0 }
                .task(id: selected) { await reveal(selected, proxy: proxy) }
                .onDisappear { focusScope.cancel() }
        }
    }

    @MainActor private func reveal(_ id: String?, proxy: ScrollViewProxy) async {
        guard let id else { focusScope.cancel(); return }
        focusScope.begin(id)
        // An advanced disclosure can mount its contents one update after the route.
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard !Task.isCancelled else { return }
        let target = scrollTarget?.requestID == id ? scrollTarget : nil
        proxy.scrollTo(target?.anchorID ?? id, anchor: .center)
        if focusScope.isPending(id), let message = target?.availabilityMessage,
           let entry = NativeSettingsSearchCatalog.entries.first(where: { $0.id == id }) {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                  userInfo: [.announcement: L(entry.title) + ". " + message,
                                             .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        // The scroll can mount a lazily rendered control on the next layout pass.
        for _ in 0..<4 {
            guard focusScope.isPending(id) else { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
            guard !Task.isCancelled else { return }
            focusScope.focus(id)
        }
        if focusScope.isPending(id) { focusScope.cancel() }
    }
}

extension View {
    func nativeSettingAnchor(_ id: String, fallbackFor: Set<String> = [], nativeControlFocus: Bool = false,
                             onFocusChange: @escaping (Bool) -> Void = { _ in }) -> some View {
        modifier(NativeSettingAnchor(id: id, fallbackFor: fallbackFor, nativeControlFocus: nativeControlFocus, onFocusChange: onFocusChange))
    }
    func nativeSettingsReveal() -> some View { modifier(NativeSettingsReveal()) }
}
