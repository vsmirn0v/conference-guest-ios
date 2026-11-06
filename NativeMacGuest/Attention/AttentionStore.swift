import ConferenceCore
import Foundation
import Security

/// Where the judge runs: any OpenAI-compatible chat completions endpoint, or Apple's
/// on-device model (`apple`), which needs no address, model name or key.
struct AttentionProvider: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case openAI, openRouter, rapidMLX, apple, local, custom }
    var kind: Kind
    var baseURL: String
    var model: String

    static let rapidMLXModel = "qwen3.5-4b-4bit"
    static let defaults: [Kind: AttentionProvider] = [
        .openAI: .init(kind: .openAI, baseURL: "https://api.openai.com/v1", model: "gpt-4.1-mini"),
        .openRouter: .init(kind: .openRouter, baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-4.1-mini"),
        .rapidMLX: .init(kind: .rapidMLX, baseURL: "http://127.0.0.1:8000/v1", model: rapidMLXModel),
        .apple: .init(kind: .apple, baseURL: "", model: "system"),
        .local: .init(kind: .local, baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:8b"),
        .custom: .init(kind: .custom, baseURL: "https://", model: ""),
    ]
    var title: String {
        switch kind {
        case .openAI: "OpenAI"; case .openRouter: "OpenRouter"; case .rapidMLX: L("Rapid-MLX on this Mac"); case .apple: L("Apple on this Mac")
        case .local: L("Server on this network"); case .custom: L("Other")
        }
    }
    /// A local server usually needs no key.
    var needsKey: Bool { ![.local, .rapidMLX, .apple].contains(kind) }
    /// The judge runs on this Mac: nothing about your meetings leaves it.
    var onThisMac: Bool {
        if kind == .apple { return true }
        guard let host = URL(string: baseURL.trimmed)?.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }
    var endpoint: URL? {
        guard var base = URL(string: baseURL.trimmed), let scheme = base.scheme?.lowercased(), ["https", "http"].contains(scheme), base.host != nil else { return nil }
        if base.absoluteString.hasSuffix("/") { base = URL(string: String(base.absoluteString.dropLast())) ?? base }
        return base.appendingPathComponent("chat/completions")
    }
    /// Shown as what leaves this Mac; never includes the key.
    var host: String { kind == .apple ? L("this Mac") : URL(string: baseURL.trimmed)?.host ?? baseURL }
    /// Has what a call needs, apart from a key.
    var configured: Bool { kind == .apple || endpoint != nil && !model.trimmed.isEmpty }
}

/// API keys, kept in the login keychain for this app only: one account per provider
/// kind, so a judge, writer and escalation at different providers each send their own.
struct AttentionKeychain: Sendable {
    var service = "dev.vsmirn0v.conferenceguest.attention"
    /// Before beta 71 a single key served every provider.
    var account = "judge-api-key"
    func kind(_ kind: AttentionProvider.Kind) -> Self { var copy = self; copy.account = "judge-api-key." + kind.rawValue; return copy }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read() -> String? {
        var item = query; item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    @discardableResult func write(_ value: String) -> Bool {
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query; addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        return status == errSecSuccess
    }
    @discardableResult func delete() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    /// The legacy key and every provider kind's key.
    func deleteAll() { delete(); for kind in AttentionProvider.Kind.allCases { self.kind(kind).delete() } }
}

/// One judged window and what you did with it; replayed to tune prompts.
struct AttentionDecisionRecord: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case belowThreshold, shown, opened, dismissed, declined, failed
        /// Qualified, but two more urgent cards (or one you are replying from) held the screen.
        case crowdedOut
        /// A reply was drafted for the card (`decisionID`), or drafting failed.
        case drafted, draftFailed
        /// You sent the card's chat reply or a reaction from it.
        case replied, reacted
        /// You had the reply spoken into the meeting.
        case spoken
    }
    var id = UUID()
    var at: Date
    var meetingTitle: String
    var presetID: UUID?
    var window: AttentionWindow?
    var verdict: AttentionVerdict?
    var provider: String
    var model: String
    var latencyMilliseconds: Int?
    var outcome: Outcome
    var declineReason: PresetExample.DeclineReason?
    var error: String?
    /// For an outcome recorded after the verdict: the decision it belongs to.
    var decisionID: UUID?
    /// The exact chat messages sent, so a replay can compare models on the same input.
    var messages: [[String: String]]? = nil
    var threshold: Double? = nil
    /// When an unsure first judge was escalated: its verdict and model (the record's
    /// verdict and model are then the stronger judge's).
    var firstVerdict: AttentionVerdict? = nil
    var firstModel: String? = nil
    /// The writer's exact prompt and its draft, so writers can be compared later.
    var replyMessages: [[String: String]]? = nil
    var draft: ReplyDraft? = nil
    /// What you sent from the card, and whether you changed the draft first.
    var sent: String? = nil
    var reaction: MeetingReaction? = nil
    var edited: Bool? = nil
}

/// Presets, your profile, the judge settings and the decision log. Everything is
/// stored on this Mac; only the meeting window and its preset go to the provider.
@MainActor final class AttentionStore: ObservableObject {
    static let shared = AttentionStore()
    static let enabledKey = "attention.judge.enabled"
    static let batteryKey = "attention.judge.pauseOnBattery"
    static let providerKey = "attention.judge.provider"
    static let repliesKey = "attention.replies.enabled"
    static let decisionRetention: TimeInterval = 30 * 24 * 3600

    private struct Document: Codable { var profile = AttentionProfile(); var presets: [MeetingPreset] = [] }

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.enabledKey) } }
    @Published var pauseOnBattery: Bool { didSet { defaults.set(pauseOnBattery, forKey: Self.batteryKey) } }
    /// Cards offer a drafted chat reply or reaction where the meeting accepts one.
    @Published var draftReplies: Bool { didSet { defaults.set(draftReplies, forKey: Self.repliesKey) } }
    /// Small models on this Mac judge well but answer questions for you when they
    /// draft, so drafting with them is opt-in.
    @Published var localDrafts: Bool { didSet { defaults.set(localDrafts, forKey: Self.localDraftsKey) } }
    static let localDraftsKey = "attention.replies.local"
    /// Who drafts replies; nil means the judge's provider. Lets a model on this Mac
    /// judge while a stronger model elsewhere writes. Uses the same keychain key.
    @Published var writerProvider: AttentionProvider? {
        didSet {
            if let writerProvider, let data = try? JSONEncoder().encode(writerProvider) { defaults.set(data, forKey: Self.writerKey) }
            else { defaults.removeObject(forKey: Self.writerKey) }
        }
    }
    static let writerKey = "attention.writer.provider"
    /// A stronger judge asked again when the first one is unsure; nil means never.
    @Published var escalationProvider: AttentionProvider? {
        didSet {
            if let escalationProvider, let data = try? JSONEncoder().encode(escalationProvider) { defaults.set(data, forKey: Self.escalationKey) }
            else { defaults.removeObject(forKey: Self.escalationKey) }
        }
    }
    static let escalationKey = "attention.judge.escalation"
    /// Probabilities the first judge is unsure about.
    static let escalationBand = 0.35...0.65
    /// The escalation judge to ask for this verdict, or nil.
    func escalation(for verdict: AttentionVerdict) -> AttentionProvider? {
        guard let strong = escalationProvider, strong != provider, Self.escalationBand.contains(verdict.probability),
              strong.configured, !strong.needsKey || hasKey(for: strong) else { return nil }
        return strong
    }

    /// The voice that speaks a reply into a meeting ("Say it" on a card).
    @Published var voiceEngine: VoiceEngine { didSet { defaults.set(voiceEngine.rawValue, forKey: Self.voiceEngineKey) } }
    @Published var voiceModel: String { didSet { defaults.set(voiceModel, forKey: Self.voiceModelKey) } }
    /// How the voice should sound, for a VoiceDesign model.
    @Published var voiceDescription: String { didSet { defaults.set(voiceDescription, forKey: Self.voiceDescriptionKey) } }
    @Published var voiceBaseURL: String { didSet { defaults.set(voiceBaseURL, forKey: Self.voiceBaseURLKey) } }
    static let voiceEngineKey = "attention.voice.engine", voiceModelKey = "attention.voice.model"
    static let voiceDescriptionKey = "attention.voice.description", voiceBaseURLKey = "attention.voice.baseURL"
    static let defaultVoiceModel = "qwen3-tts-voicedesign-4bit"
    static let defaultVoiceDescription = "A calm, clear adult voice speaking at a natural pace, like a colleague in a work call."
    var effectiveWriter: AttentionProvider { writerProvider ?? provider }
    /// Cards can draft with the writer.
    var draftsAllowed: Bool {
        let writer = effectiveWriter
        return draftReplies && writer.configured && (!writer.onThisMac || localDrafts) && (!writer.needsKey || hasKey(for: writer))
    }
    @Published var provider: AttentionProvider {
        didSet { if let data = try? JSONEncoder().encode(provider) { defaults.set(data, forKey: Self.providerKey) } }
    }
    @Published var profile: AttentionProfile { didSet { if profile != oldValue { save() } } }
    @Published private(set) var presets: [MeetingPreset] = []
    /// Provider kinds with a key in the keychain.
    @Published private(set) var keyedKinds: Set<AttentionProvider.Kind> = []
    /// The judge's provider has its key.
    var hasKey: Bool { hasKey(for: provider) }
    func hasKey(for provider: AttentionProvider) -> Bool { keyedKinds.contains(provider.kind) }
    @Published private(set) var persistenceWarning: String?
    let root: URL
    private let defaults: UserDefaults
    private let keychain: AttentionKeychain
    private var loading = false

    init(root: URL? = nil, defaults: UserDefaults = .standard, keychain: AttentionKeychain = .init()) {
        self.root = root ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory).appendingPathComponent("Attention", isDirectory: true)
        self.defaults = defaults; self.keychain = keychain
        enabled = defaults.bool(forKey: Self.enabledKey)
        pauseOnBattery = defaults.bool(forKey: Self.batteryKey)
        draftReplies = defaults.object(forKey: Self.repliesKey) as? Bool ?? true
        localDrafts = defaults.bool(forKey: Self.localDraftsKey)
        writerProvider = defaults.data(forKey: Self.writerKey).flatMap { try? JSONDecoder().decode(AttentionProvider.self, from: $0) }
        escalationProvider = defaults.data(forKey: Self.escalationKey).flatMap { try? JSONDecoder().decode(AttentionProvider.self, from: $0) }
        voiceEngine = defaults.string(forKey: Self.voiceEngineKey).flatMap(VoiceEngine.init(rawValue:)) ?? .system
        voiceModel = defaults.string(forKey: Self.voiceModelKey) ?? Self.defaultVoiceModel
        voiceDescription = defaults.string(forKey: Self.voiceDescriptionKey) ?? Self.defaultVoiceDescription
        voiceBaseURL = defaults.string(forKey: Self.voiceBaseURLKey) ?? AttentionProvider.defaults[.rapidMLX]!.baseURL
        provider = defaults.data(forKey: Self.providerKey).flatMap { try? JSONDecoder().decode(AttentionProvider.self, from: $0) }
            ?? AttentionProvider.defaults[.openAI]!
        profile = AttentionProfile()
        // The single pre-beta-71 key belonged to the judge's provider at the time.
        if let legacy = keychain.read(), !legacy.trimmed.isEmpty {
            if keychain.kind(provider.kind).read() == nil { keychain.kind(provider.kind).write(legacy) }
            keychain.delete()
        }
        keyedKinds = Set(AttentionProvider.Kind.allCases.filter { keychain.kind($0).read()?.trimmed.isEmpty == false })
        load()
    }

    private var documentURL: URL { root.appendingPathComponent("presets.json") }
    private var decisionsFolder: URL { root.appendingPathComponent("decisions", isDirectory: true) }

    private func load() {
        loading = true; defer { loading = false }
        guard let data = try? Data(contentsOf: documentURL) else { return }
        do {
            let document = try JSONDecoder.attention.decode(Document.self, from: data)
            profile = document.profile; presets = document.presets
        } catch { persistenceWarning = L("Meeting instructions could not be read. Changes will replace them.") }
    }
    private func save() {
        guard !loading else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try JSONEncoder.attention.encode(Document(profile: profile, presets: presets))
            try data.write(to: documentURL, options: .atomic)
            persistenceWarning = nil
        } catch { persistenceWarning = L("Meeting instructions could not be saved.") }
    }

    // MARK: Key

    /// Only for building the request; the key is never logged or exported.
    func apiKey() -> String? { apiKey(for: provider) }
    func apiKey(for provider: AttentionProvider) -> String? {
        keychain.kind(provider.kind).read().flatMap { $0.trimmed.isEmpty ? nil : $0.trimmed }
    }
    @discardableResult func setAPIKey(_ value: String) -> Bool { setAPIKey(value, for: provider) }
    @discardableResult func setAPIKey(_ value: String, for provider: AttentionProvider) -> Bool {
        let clean = value.trimmed, account = keychain.kind(provider.kind)
        let saved = clean.isEmpty ? account.delete() : account.write(clean)
        if apiKey(for: provider) != nil { keyedKinds.insert(provider.kind) } else { keyedKinds.remove(provider.kind) }
        return saved
    }
    var ready: Bool { enabled && provider.configured && (!provider.needsKey || hasKey) }

    // MARK: Presets

    /// The room's own preset first, then one for the calendar series it was joined from.
    func preset(room: URL, latest: URL? = nil, series: String? = nil) -> MeetingPreset? {
        let rooms = [room, latest].compactMap { $0?.absoluteString }
        if let match = presets.first(where: { $0.bindings.contains { if case .room(let key) = $0 { rooms.contains(key) } else { false } } }) {
            return match
        }
        guard let series else { return nil }
        return presets.first { $0.bindings.contains(.calendarSeries(series)) }
    }
    func preset(id: UUID) -> MeetingPreset? { presets.first { $0.id == id } }
    func save(_ preset: MeetingPreset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) { presets[index] = preset } else { presets.append(preset) }
        save()
    }
    func delete(_ id: UUID) { presets.removeAll { $0.id == id }; save() }
    /// The room's preset, created empty when the room has none.
    func presetForFeedback(room: URL, latest: URL?, series: String?, title: String) -> MeetingPreset {
        preset(room: room, latest: latest, series: series) ?? MeetingPreset(title: title, bindings: [.room(room.absoluteString)])
    }
    func record(_ example: PresetExample, in preset: MeetingPreset) {
        var updated = self.preset(id: preset.id) ?? preset
        updated.record(example); save(updated)
    }
    func recordEdit(_ edit: ReplyEdit, in preset: MeetingPreset) {
        var updated = self.preset(id: preset.id) ?? preset
        updated.recordEdit(edit); save(updated)
    }

    // MARK: Decisions

    /// Appends one JSON line to today's file and removes files older than 30 days.
    func log(_ record: AttentionDecisionRecord) {
        do {
            try FileManager.default.createDirectory(at: decisionsFolder, withIntermediateDirectories: true)
            let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.locale = Locale(identifier: "en_US_POSIX")
            let url = decisionsFolder.appendingPathComponent(day.string(from: record.at) + ".jsonl")
            var line = try JSONEncoder.attention.encode(record); line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: line)
            } else { try line.write(to: url, options: .atomic) }
            pruneDecisions(now: record.at)
        } catch { probeLog("attention-log-failed", [:]) }
    }
    func decisionFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: decisionsFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func pruneDecisions(now: Date) {
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.locale = Locale(identifier: "en_US_POSIX")
        for url in decisionFiles() {
            guard let date = day.date(from: url.deletingPathExtension().lastPathComponent),
                  now.timeIntervalSince(date) > Self.decisionRetention else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension JSONEncoder {
    static var attention: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
extension JSONDecoder {
    static var attention: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
