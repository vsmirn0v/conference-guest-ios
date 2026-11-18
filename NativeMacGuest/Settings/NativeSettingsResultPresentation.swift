import Combine
import Foundation
import SwiftUI

/// Presentation never reads secrets or invokes hardware, keychain, network or feature actions.
enum NativeSettingsResultPresentation {
    private static let descriptions: [String: String] = {
        var result: [String: String] = [:]
        for id in ["settings.display-name", "settings.names", "settings.aliases", "settings.role"] { result[id] = "Your name or role used in meetings." }
        for id in ["settings.website"] { result[id] = "Website used for invitations with a room code." }
        for id in ["settings.setup"] { result[id] = "Review your meeting setup choices." }
        for id in ["settings.relay"] { result[id] = "Choose the connection route for guest meetings." }
        for id in ["settings.mic-warm", "settings.mic-readiness"] { result[id] = "Prepare the microphone for use in meetings." }
        for id in ["settings.headset"] { result[id] = "Use headset controls to mute and unmute." }
        for id in ["settings.sync", "settings.handoff", "settings.sync-recent", "settings.sync-workspace", "settings.sync-calendar", "settings.sync-transcripts", "settings.transcript-archive", "settings.sync-now"] { result[id] = "Sync saved meetings, notes, tasks, calendar schedule or active jams across your devices." }
        for id in ["settings.calendar-enabled", "settings.calendar-selection", "settings.calendar-privacy", "settings.calendar-refresh"] { result[id] = "Choose which calendars provide meetings." }
        for id in ["settings.menu-bar", "settings.auto-join"] { result[id] = "Control background operation and automatic joining." }
        for id in ["settings.reminders", "settings.reminder-timing", "settings.reminder-before", "settings.reminder-before-time", "settings.reminder-at-start", "settings.reminder-follow-up", "settings.reminder-follow-up-delay", "settings.reminder-name", "settings.reminder-sound", "settings.reminder-sensitive", "settings.reminder-other-devices", "settings.notification-settings"] { result[id] = "Choose when and how meeting reminders appear." }
        for id in ["settings.microphone"] { result[id] = "Choose the microphone used by the Mac." }
        for id in ["settings.output"] { result[id] = "Choose the sound output used by the Mac." }
        for id in ["settings.microphone-test"] { result[id] = "Check the input level without changing meeting mute." }
        for id in ["settings.audio-profile"] { result[id] = "Choose processing for speech or music." }
        for id in ["settings.camera", "settings.camera-test"] { result[id] = "Choose or privately preview your camera." }
        for id in ["settings.camera-reactions"] { result[id] = "Share matching reactions for camera effects." }
        for id in ["settings.camera-readiness"] { result[id] = "Prepare camera information before use." }
        for id in ["settings.version", "settings.update-check", "settings.update-download", "settings.update-channel", "settings.check-updates"] { result[id] = "Review the installed version and update preferences." }
        for id in ["settings.transcribe", "settings.transcribe-mic", "settings.transcribe-external", "settings.transcribe-rock"] { result[id] = "Choose which meeting speech is transcribed on this Mac." }
        for id in ["settings.speech-model", "settings.voice-detector", "settings.transcription-model-status", "settings.assistant-model-status"] { result[id] = "Manage the on-device speech recognition components." }
        for id in ["settings.alerts", "settings.battery"] { result[id] = "Control meeting alerts and their battery behavior." }
        for situation in AttentionSituation.allCases { result["settings.\(situation.settingsSearchID)"] = situation.detailKey }
        for id in ["settings.outcomes", "settings.remote-outcomes"] { result[id] = "Choose whether meeting outcomes are created or sent to a provider." }
        for id in ["settings.outcomes-same-room"] { result[id] = "Choose whether back-to-back meetings in the same room create separate outcomes or stay combined." }
        for id in ["settings.instructions"] { result[id] = "Review instructions for individual meetings." }
        for id in ["settings.provider", "settings.provider-address", "settings.provider-model", "settings.api-key", "settings.provider-choose", "settings.provider-compare", "settings.provider-test", "settings.escalation", "settings.escalation-model", "settings.escalation-key"] { result[id] = "Configure the AI that evaluates meeting alerts." }
        for id in ["settings.writer", "settings.writer-model", "settings.writer-key"] { result[id] = "Choose the AI that writes replies and meeting outcomes." }
        for id in ["settings.drafts", "settings.reply-style", "settings.local-drafts"] { result[id] = "Choose how Assistant prepares suggested replies." }
        for id in ["settings.agent", "settings.agent-mcp", "settings.meeting-sends"] { result[id] = "Choose tools and confirmation for Assistant actions." }
        for id in ["settings.push-talk"] { result[id] = "Talk to Assistant using a keyboard shortcut." }
        for id in ["settings.talk-back", "settings.headphone-approval"] { result[id] = "Hear Assistant answers privately in headphones." }
        for id in ["settings.voice-engine", "settings.voice-model", "settings.voice-description", "settings.voice-address", "settings.voice-preview"] { result[id] = "Choose and preview the voice used for spoken replies." }
        for id in ["settings.saved-voice", "settings.voice-preparation", "settings.voice-download", "settings.voice-delete", "settings.voice-gpu", "settings.voice-gpu-remove"] { result[id] = "Manage your saved voice and its on-device model." }
        for id in ["settings.memory", "settings.memory-add", "settings.memory-retention", "settings.memory-export", "settings.memory-delete"] { result[id] = "Review and manage remembered context and retention." }
        for id in ["settings.privacy"] { result[id] = "Review what data is sent to configured providers." }
        for id in ["settings.mcp", "settings.mcp-endpoint", "settings.mcp-pairing", "settings.mcp-clients", "settings.mcp-capabilities"] { result[id] = "Manage the local MCP server and paired clients." }
        for id in ["settings.obsidian", "settings.obsidian-after", "settings.obsidian-updates", "settings.obsidian-layout", "settings.obsidian-vault"] { result[id] = "Configure export of meeting notes to Obsidian." }
        return result
    }()

    static func descriptionKey(for entry: NativeSettingsSearchCatalog.Entry) -> String {
        descriptions[entry.id] ?? "Review this setting."
    }

    static func description(for entry: NativeSettingsSearchCatalog.Entry) -> String {
        L(descriptionKey(for: entry))
    }

    /// Returns nil for an action or a state that has not loaded. Private text
    /// and device selections use a neutral prompt without reading their values.
    @MainActor static func value(for entry: NativeSettingsSearchCatalog.Entry,
                                 library: NativeDesktopLibrary,
                                 attention: AttentionCoordinator?,
                                 obsidian: ObsidianExportCoordinator?) -> String? {
        let defaults = UserDefaults.standard
        func toggle(_ enabled: Bool) -> String { L(enabled ? "On" : "Off") }
        let store = attention?.store
        if let situation = AttentionSituation.allCases.first(where: { entry.id == "settings.\($0.settingsSearchID)" }) {
            return store?.mode(for: situation).title
        }
        switch entry.id {
        case "settings.display-name", "settings.website", "settings.microphone", "settings.output", "settings.camera":
            return L("Open to view")
        case "settings.names", "settings.aliases", "settings.role", "settings.reply-style":
            return store == nil ? nil : L("Open to view")
        case "settings.relay": return toggle(defaults.bool(forKey: UniversalMeetingEngine.forceTCPRelayKey))
        case "settings.mic-warm": return toggle(defaults.bool(forKey: NativeDesktopMeetingModel.keepMicrophoneWarmKey))
        case "settings.headset": return toggle(defaults.bool(forKey: NativeDesktopHeadsetMute.Platform.enabledKey))
        case "settings.sync": return toggle(library.sync.enabled)
        case "settings.handoff": return toggle(library.continuation.enabled)
        case "settings.sync-recent": return toggle(library.sync.includeRecent)
        case "settings.sync-workspace": return toggle(library.sync.syncWorkspace)
        case "settings.sync-calendar": return toggle(library.sync.shareCalendar)
        case "settings.sync-transcripts": return library.sync.transcriptRetention.title
        case "settings.transcript-archive": return library.sync.archiveFolderName ?? L("On this device")
        case "settings.calendar-enabled": return toggle(library.calendar.enabled)
        case "settings.menu-bar": return toggle(library.calendar.keepInMenuBar)
        case "settings.auto-join": return library.calendar.automaticJoinMode.title
        case "settings.reminders": return toggle(library.calendar.reminders.enabled)
        case "settings.reminder-before": return toggle(library.calendar.reminders.profile.timing.before != nil)
        case "settings.reminder-before-time": return library.calendar.reminders.profile.timing.before.map { L("Before: %d seconds", $0) }
        case "settings.reminder-at-start": return toggle(library.calendar.reminders.profile.timing.atStart)
        case "settings.reminder-follow-up":
            switch library.calendar.reminders.profile.timing.followUp.mode {
            case .off: return L("Off")
            case .anotherMeeting: return L("If in another meeting")
            case .always: return L("Always")
            }
        case "settings.reminder-follow-up-delay":
            let followUp = library.calendar.reminders.profile.timing.followUp
            return followUp.mode == .off ? nil : L("Delay: %d seconds", followUp.delay)
        case "settings.reminder-name": return toggle(library.calendar.reminders.profile.details)
        case "settings.reminder-sound": return toggle(library.calendar.reminders.profile.sound)
        case "settings.reminder-sensitive": return toggle(library.calendar.reminders.profile.timeSensitive)
        case "settings.reminder-other-devices": return toggle(library.calendar.reminders.suppressOtherDevices)
        case "settings.audio-profile": return L(GuestAudioProfile.saved == .speech ? "Speech" : "Music")
        case "settings.mic-readiness": return NativeDesktopJoinReadinessPolicy.current().microphone.title
        case "settings.camera-readiness": return NativeDesktopJoinReadinessPolicy.current().camera.title
        case "settings.camera-reactions": return toggle(defaults.object(forKey: "nativeDesktop.shareCameraReactions") as? Bool ?? true)
        case "settings.transcribe": return toggle(defaults.bool(forKey: ListenModelStore.enabledKey))
        case "settings.transcribe-mic": return toggle(defaults.object(forKey: ListenModelStore.microphoneKey) as? Bool ?? true)
        case "settings.transcribe-external": return toggle(defaults.object(forKey: ListenModelStore.externalKey) as? Bool ?? true)
        case "settings.transcribe-rock": return toggle(defaults.bool(forKey: ListenModelStore.rockKey))
        case "settings.alerts": return store.map { toggle($0.enabled) }
        case "settings.battery": return store.map { toggle($0.pauseOnBattery) }
        case "settings.outcomes": return store.map { toggle($0.generateOutcomes) }
        case "settings.remote-outcomes": return store.map { toggle($0.remoteOutcomes) }
        case "settings.outcomes-same-room": return store.map(\.sameRoomTransitionDefault.title)
        case "settings.drafts": return store.map { toggle($0.draftReplies) }
        case "settings.local-drafts": return store.map { toggle($0.localDrafts) }
        case "settings.agent": return store.map { toggle($0.agentAssistantEnabled) }
        case "settings.agent-mcp": return store.map { toggle($0.agentExternalToolsEnabled) }
        case "settings.meeting-sends": return store.map { L($0.agentMeetingSendDefault == .askEveryTime ? "Ask every time" : "Send immediately") }
        case "settings.push-talk": return store.map { toggle($0.pushToTalk) }
        case "settings.talk-back": return store.map { toggle($0.talkBack) }
        case "settings.provider": return store?.provider.title
        // hasKey is an in-memory set maintained by AttentionStore; it does not
        // read the keychain or reveal the credential.
        case "settings.api-key": return store.map { L($0.hasKey ? "Configured" : "Not configured") }
        case "settings.escalation-key":
            guard let store, let provider = store.escalationProvider, provider.needsKey else { return nil }
            return L(store.hasKey(for: provider) ? "Configured" : "Not configured")
        case "settings.writer-key":
            guard let store, let provider = store.writerProvider, provider.needsKey else { return nil }
            return L(store.hasKey(for: provider) ? "Configured" : "Not configured")
        case "settings.writer": return store.map { $0.writerProvider?.title ?? L("The judge's provider") }
        case "settings.escalation": return store.map { $0.escalationProvider?.title ?? L("Nobody") }
        case "settings.voice-engine":
            guard let engine = store?.voiceEngine else { return nil }
            switch engine {
            case .system: return L("The macOS voice")
            case .rapidMLX: return L("Rapid-MLX voice server")
            case .personal: return L("Your Personal Voice")
            case .cloned: return L("Your voice, on the Neural Engine")
            }
        case "settings.obsidian": return obsidian?.destination.map { toggle($0.enabled) }
        case "settings.obsidian-after": return obsidian?.destination.map { toggle($0.saveAfterMeeting) }
        case "settings.obsidian-updates": return obsidian?.destination.map { toggle($0.syncChanges) }
        case "settings.version":
            guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return nil }
            return "\(version) (\(build))"
        default: return nil
        }
    }

    #if NATIVE_DIRECT_UPDATES
    @MainActor static func updateValue(for entry: NativeSettingsSearchCatalog.Entry, updates: NativeDesktopUpdates?) -> String? {
        guard let updates, let updater = updates.updater else { return nil }
        switch entry.id {
        case "settings.update-check": return L(updater.automaticallyChecksForUpdates ? "On" : "Off")
        case "settings.update-download": return L(updater.automaticallyDownloadsUpdates ? "On" : "Off")
        case "settings.update-channel": return L(updates.beta ? "Beta" : "Stable")
        default: return nil
        }
    }
    #endif
}

/// Result rows observe the stores whose values they display. Services are not
/// constructed and device inventories or credentials are never queried here.
@MainActor struct NativeSettingsSearchResultRow: View {
    let entry: NativeSettingsSearchCatalog.Entry
    @ObservedObject var library: NativeDesktopLibrary
    let attention: AttentionCoordinator?
    let obsidian: ObsidianExportCoordinator?
    #if NATIVE_DIRECT_UPDATES
    let updates: NativeDesktopUpdates?
    #endif
    let onOpen: () -> Void
    @State private var changeGeneration = 0

    private var storeChanges: AnyPublisher<Void, Never> {
        attention?.store.objectWillChange.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()
    }
    private var obsidianChanges: AnyPublisher<Void, Never> {
        obsidian?.objectWillChange.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()
    }
    private var currentValue: String? {
        #if NATIVE_DIRECT_UPDATES
        if let result = NativeSettingsResultPresentation.updateValue(for: entry, updates: updates) { return result }
        #endif
        return NativeSettingsResultPresentation.value(for: entry, library: library, attention: attention, obsidian: obsidian)
    }
    private var row: some View {
        let _ = changeGeneration
        return Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L(entry.title))
                    Text(entry.assistantArea.map { L("Assistant") + " › " + $0.title } ?? L(entry.section))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(NativeSettingsResultPresentation.description(for: entry)).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let value = currentValue {
                    Text(value).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }.padding(10).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("settings.result.\(entry.id)")
            .onReceive(storeChanges) { _ in changeGeneration &+= 1 }
            .onReceive(obsidianChanges) { _ in changeGeneration &+= 1 }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in changeGeneration &+= 1 }
    }
    var body: some View {
        #if NATIVE_DIRECT_UPDATES
        row.onReceive(updates?.objectWillChange.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in changeGeneration &+= 1 }
        #else
        row
        #endif
    }
}
