import Foundation

/// Curated VoxCPM2 VoiceDesign neural style presets for zero-shot local Assistant auditioning.
public enum AssistantVoxVoicePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case calmAssistant
    case warmFemale
    case crispMale
    case brightConversational

    public var id: String { rawValue }

    public var localizedTitleKey: String {
        switch self {
        case .calmAssistant: return "Calm Assistant"
        case .warmFemale: return "Warm Female"
        case .crispMale: return "Crisp Male"
        case .brightConversational: return "Bright Conversational"
        }
    }

    public var localizedSubtitleKey: String {
        switch self {
        case .calmAssistant: return "Balanced, articulate assistant voice at a steady pace."
        case .warmFemale: return "Friendly, natural female voice with clear diction."
        case .crispMale: return "Clear, steady male voice with crisp articulation."
        case .brightConversational: return "Upbeat conversational voice with warm energy."
        }
    }

    public var localizedTitle: String { L(localizedTitleKey) }
    public var localizedSubtitle: String { L(localizedSubtitleKey) }

    public var voiceDesignInstruction: String {
        switch self {
        case .calmAssistant:
            return "A calm, warm, articulate assistant voice speaking clearly at a natural conversational pace"
        case .warmFemale:
            return "A warm, friendly female voice with clear diction and natural pacing"
        case .crispMale:
            return "A clear, steady male voice with crisp articulation and moderate pace"
        case .brightConversational:
            return "An upbeat, natural conversational voice with bright tone"
        }
    }

    public func formattedPrompt(for text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }
        return "(\(voiceDesignInstruction))\(clean)"
    }
}

/// Which local voice auditions Assistant answers on the user's device.
public enum AssistantAuditionVoiceSelection: Codable, Equatable, Hashable, Sendable {
    case voxPreset(AssistantVoxVoicePreset)
    case clonedVoice
    case personalVoice
    case systemVoice(identifier: String)

    public static let defaultSelection: Self = .voxPreset(.calmAssistant)

    private enum CodingKeys: String, CodingKey {
        case kind, preset, identifier
    }

    private enum Kind: String, Codable {
        case voxPreset, clonedVoice, personalVoice, systemVoice
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .voxPreset:
            let preset = try container.decodeIfPresent(AssistantVoxVoicePreset.self, forKey: .preset) ?? .calmAssistant
            self = .voxPreset(preset)
        case .clonedVoice:
            self = .clonedVoice
        case .personalVoice:
            self = .personalVoice
        case .systemVoice:
            let identifier = try container.decodeIfPresent(String.self, forKey: .identifier) ?? ""
            self = .systemVoice(identifier: identifier)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .voxPreset(let preset):
            try container.encode(Kind.voxPreset, forKey: .kind)
            try container.encode(preset, forKey: .preset)
        case .clonedVoice:
            try container.encode(Kind.clonedVoice, forKey: .kind)
        case .personalVoice:
            try container.encode(Kind.personalVoice, forKey: .kind)
        case .systemVoice(let identifier):
            try container.encode(Kind.systemVoice, forKey: .kind)
            try container.encode(identifier, forKey: .identifier)
        }
    }

    public var localizedSummary: String {
        switch self {
        case .voxPreset(let preset):
            return L("VoxCPM2 · %@", preset.localizedTitle)
        case .clonedVoice:
            return L("My cloned voice")
        case .personalVoice:
            return L("Personal Voice")
        case .systemVoice(let id):
            return id.isEmpty ? L("System voice (automatic)") : L("System voice")
        }
    }
}

public enum AssistantVoicePreferences {
    public static let voiceSelectionKey = "assistant.audition.voiceSelection"
    public static let autoSpeakVoiceRepliesKey = "assistant.audition.autoSpeakVoiceReplies"
    public static let autoSpeakTypedRepliesKey = "assistant.audition.autoSpeakTypedReplies"
    public static let wakeWordEnabledKey = "assistant.wakeWord.enabled"

    public static func loadAuditionVoice(from defaults: UserDefaults = .standard) -> AssistantAuditionVoiceSelection {
        guard let data = defaults.data(forKey: voiceSelectionKey),
              let decoded = try? JSONDecoder().decode(AssistantAuditionVoiceSelection.self, from: data) else {
            return .defaultSelection
        }
        return decoded
    }

    public static func saveAuditionVoice(_ selection: AssistantAuditionVoiceSelection, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: voiceSelectionKey)
    }

    public static func loadAutoSpeakVoiceReplies(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: autoSpeakVoiceRepliesKey) as? Bool ?? true
    }

    public static func loadAutoSpeakTypedReplies(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: autoSpeakTypedRepliesKey)
    }

    public static func loadWakeWordEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: wakeWordEnabledKey) as? Bool ?? true
    }
}
