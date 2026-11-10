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
    /// Tokens the catalog reported for `model`. Nil when the model was typed or the catalog omitted it.
    var contextLength: Int?

    init(kind: Kind, baseURL: String, model: String, contextLength: Int? = nil) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.contextLength = contextLength
    }

    /// Remembers a catalog choice. A typed model name clears the length, because it may be a different model.
    mutating func adopt(model: String, contextLength: Int?) {
        self.model = model
        self.contextLength = contextLength
    }

    /// A text field writing the same string back must not drop a catalogued length.
    mutating func adoptTyped(_ text: String) {
        guard text != model else { return }
        model = text
        contextLength = nil
    }

    /// Context windows OpenAI's model list does not report. More specific ids are listed first.
    static let openAIFallbackContextTokens = 128_000
    static func knownContextLength(model: String) -> Int? {
        let bare = model.lowercased().split(separator: "/").last.map(String.init) ?? model.lowercased()
        let table: [(String, Int)] = [
            ("gpt-4.1", 1_047_576),
            ("gpt-4o", 128_000),
            ("gpt-4-turbo", 128_000),
            ("gpt-4-32k", 32_768),
            ("gpt-3.5-turbo", 16_385),
            ("gpt-4", 8_192),
            ("o4-mini", 200_000),
            ("o3-mini", 200_000),
            ("o3", 200_000),
            ("o1-mini", 128_000),
            ("o1", 200_000),
        ]
        for (prefix, tokens) in table where bare == prefix || bare.hasPrefix(prefix + "-") {
            return tokens
        }
        return nil
    }

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

    private enum CodingKeys: String, CodingKey { case kind, baseURL, model, contextLength }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decode(String.self, forKey: .model)
        contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(contextLength, forKey: .contextLength)
    }
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
        /// Retained in Assistant, marked read, or scheduled for a reminder.
        case missed, seen, reminded
    }
    var id = UUID()
    var at: Date
    var meetingTitle: String
    /// Stable identity added for Moments; old journal entries decode with nil.
    var meetingID: UUID? = nil
    var invitation: URL? = nil
    var seriesID: String? = nil
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
    /// The meeting's mode when it was judged, and whether you were named or asked in the window.
    var mode: AttentionMode? = nil
    var mentioned: Bool? = nil
    /// The writer's exact prompt and its draft, so writers can be compared later.
    var replyMessages: [[String: String]]? = nil
    var draft: ReplyDraft? = nil
    /// What you sent from the card, and whether you changed the draft first.
    var sent: String? = nil
    var reaction: MeetingReaction? = nil
    var edited: Bool? = nil
    /// Local memory excerpts in the exact judge/writer prompt; nil on legacy records.
    var memory: [AssistantMemoryExcerpt]? = nil
    /// Actual custom reminder time; legacy reminders used ten minutes after `at`.
    var reminderAt: Date? = nil
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
    /// The mode of a meeting without its own, by where it is relative to you.
    @Published var situationModes: [AttentionSituation: AttentionMode] {
        didSet { for (situation, mode) in situationModes { defaults.set(mode.rawValue, forKey: Self.modeKey(situation)) } }
    }
    static func modeKey(_ situation: AttentionSituation) -> String { "attention.mode." + situation.rawValue }
    func mode(for situation: AttentionSituation) -> AttentionMode {
        situationModes[situation] ?? AttentionSituation.defaultModes[situation] ?? .watch
    }
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
    @Published var generateOutcomes: Bool { didSet { defaults.set(generateOutcomes, forKey: Self.outcomesKey) } }
    /// A writer outside this Mac receives the transcript only after this explicit opt-in.
    @Published var remoteOutcomes: Bool { didSet { defaults.set(remoteOutcomes, forKey: Self.remoteOutcomesKey) } }
    @Published var pushToTalk: Bool { didSet { defaults.set(pushToTalk, forKey: Self.pushToTalkKey) } }
    @Published var talkBack: Bool { didSet { defaults.set(talkBack, forKey: Self.talkBackKey) } }
    /// The bounded agent runtime over typed tools. Off by default; the existing
    /// single-command interpreter remains the fallback while this is off.
    @Published var agentAssistantEnabled: Bool { didSet { defaults.set(agentAssistantEnabled, forKey: Self.agentAssistantKey) } }
    static let agentAssistantKey = "assistant.agent.enabled"
    /// Expose read-only MCP tools (the app's own MCP backend today; external
    /// servers as they are added) to the agent runtime. Off by default.
    @Published var agentExternalToolsEnabled: Bool { didSet { defaults.set(agentExternalToolsEnabled, forKey: Self.agentExternalToolsKey) } }
    static let agentExternalToolsKey = "assistant.agent.externalTools"
    /// Output-device UIDs the person marked with "This is a headphone".
    @Published private(set) var headphoneUIDs: Set<String>
    static let outcomesKey = "attention.outcomes.enabled", remoteOutcomesKey = "attention.outcomes.remote"
    static let pushToTalkKey = "attention.commands.pushToTalk"
    static let talkBackKey = "attention.commands.talkBack"
    static let headphoneUIDsKey = "attention.voice.headphones"
    /// On-device writers run whenever outcome generation is on. A remote writer also needs
    /// Attention on and `remoteOutcomes`, so a saved key cannot send a transcript by itself.
    func setHeadphoneApproved(_ uid: String, _ approved: Bool) {
        let clean = uid.trimmed
        guard !clean.isEmpty else { return }
        if approved { headphoneUIDs.insert(clean) } else { headphoneUIDs.remove(clean) }
        defaults.set(Array(headphoneUIDs).sorted(), forKey: Self.headphoneUIDsKey)
    }

    var shouldCaptureOutcome: Bool {
        guard generateOutcomes, writerConfigured else { return false }
        if effectiveWriter.onThisMac { return true }
        return enabled && remoteOutcomes
    }
    var effectiveWriter: AttentionProvider { writerProvider ?? provider }
    /// Context of the model that writes outcomes. A separate writer with the same model id
    /// reuses the length learned for the judge. A different, uncatalogued model stays unknown.
    var outcomeContextTokens: Int? {
        let writer = effectiveWriter
        if let length = writer.contextLength { return length }
        if writer.model == provider.model, let length = provider.contextLength { return length }
        if let known = AttentionProvider.knownContextLength(model: writer.model) { return known }
        if writer.kind == .openAI { return AttentionProvider.openAIFallbackContextTokens }
        return nil
    }
    var writerConfigured: Bool {
        let writer = effectiveWriter
        return writer.configured && (!writer.needsKey || hasKey(for: writer))
    }
    /// Cards can draft with the writer.
    var draftsAllowed: Bool {
        draftReplies && writerConfigured && (!effectiveWriter.onThisMac || localDrafts)
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
    @Published private(set) var journalWarning: String?
    let root: URL
    let assistant: AssistantDataStore
    /// Test-teardown entry point: cancels pending library preparation, closes any
    /// open handle, and drains the in-flight prepare. XCTest teardown blocks run
    /// LIFO, so a fixture that calls this right after store creation wins every
    /// race — the queued prepare, mid-flight DDL inside a `close_v2` zombie, and
    /// Swift's scheduled isolated deinits — against directory removal
    /// ("vnode unlinked while in use").
    func closeLibrarySyncForTeardown() async {
        libraryTask?.cancel()
        // Drain BEFORE closing: `sqlite3_close_v2` racing an in-flight `sqlite3_exec`
        // corrupts the connection's internal lock (crash), so the handle must be
        // idle. The cancelled task either never starts, or finishes its uncancellable
        // in-flight section and stops at the next cancellation check.
        await libraryTask?.value
        meetingLibrary.store.closeSync()
    }

    /// Durable meeting library: sessions, notes and outcomes in SQLite. Shared root
    /// with the assistant data keeps tests isolated through the same injection point.
    let meetingLibrary: MeetingLibraryController
    /// Per-session note drafts with debounced autosave.
    let notes: MeetingNotesController
    private let defaults: UserDefaults
    private let keychain: AttentionKeychain
    private var loading = false
    @Published private(set) var momentHistory = AttentionMomentHistory()
    @Published private(set) var momentsLoaded = false
    private var loadingMoments = false
    private var momentBuffer: [AttentionDecisionRecord] = []
    private var momentLoadTask: Task<Void, Never>?
    /// Eager meeting-library preparation (open + legacy migration). Held so teardown
    /// can cancel it: without this, the pending task's strong capture keeps the store
    /// alive past a fixture's teardown block, and the library connection outlives the
    /// directory that was just deleted ("vnode unlinked while in use").
    private var libraryTask: Task<Void, Never>?
    /// Every journal append, from the main thread and from seen-marks, runs here in order.
    private let journalQueue = DispatchQueue(label: "attention.journal.append")

    init(root: URL? = nil, defaults: UserDefaults = .standard, keychain: AttentionKeychain = .init()) {
        let root = root ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory).appendingPathComponent("Attention", isDirectory: true)
        self.root = root; assistant = AssistantDataStore(root: root)
        meetingLibrary = MeetingLibraryController(root: root)
        notes = MeetingNotesController(library: meetingLibrary)
        self.defaults = defaults; self.keychain = keychain
        enabled = defaults.bool(forKey: Self.enabledKey)
        pauseOnBattery = defaults.bool(forKey: Self.batteryKey)
        situationModes = Dictionary(uniqueKeysWithValues: AttentionSituation.allCases.map { situation in
            (situation, defaults.string(forKey: Self.modeKey(situation)).flatMap(AttentionMode.init(rawValue:))
                ?? AttentionSituation.defaultModes[situation] ?? .watch)
        })
        draftReplies = defaults.object(forKey: Self.repliesKey) as? Bool ?? true
        localDrafts = defaults.bool(forKey: Self.localDraftsKey)
        writerProvider = defaults.data(forKey: Self.writerKey).flatMap { try? JSONDecoder().decode(AttentionProvider.self, from: $0) }
        escalationProvider = defaults.data(forKey: Self.escalationKey).flatMap { try? JSONDecoder().decode(AttentionProvider.self, from: $0) }
        voiceEngine = defaults.string(forKey: Self.voiceEngineKey).flatMap(VoiceEngine.init(rawValue:)) ?? .system
        voiceModel = defaults.string(forKey: Self.voiceModelKey) ?? Self.defaultVoiceModel
        voiceDescription = defaults.string(forKey: Self.voiceDescriptionKey) ?? Self.defaultVoiceDescription
        voiceBaseURL = defaults.string(forKey: Self.voiceBaseURLKey) ?? AttentionProvider.defaults[.rapidMLX]!.baseURL
        generateOutcomes = defaults.object(forKey: Self.outcomesKey) as? Bool ?? true
        remoteOutcomes = defaults.bool(forKey: Self.remoteOutcomesKey)
        // On for an upgraded install: the previous implicit default was on and never wrote
        // this key, so an absent value must keep working. An explicit off value is unchanged.
        pushToTalk = defaults.object(forKey: Self.pushToTalkKey) as? Bool ?? true
        talkBack = defaults.bool(forKey: Self.talkBackKey)
        agentAssistantEnabled = defaults.bool(forKey: Self.agentAssistantKey)
        agentExternalToolsEnabled = defaults.bool(forKey: Self.agentExternalToolsKey)
        headphoneUIDs = Set(defaults.stringArray(forKey: Self.headphoneUIDsKey) ?? [])
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
        momentLoadTask = Task { @MainActor [weak self] in await self?.loadMoments() }
        installMeetingLibrary()
    }

    // MARK: Meeting library

    /// Dual-writes outcomes into the repository, then runs the one-time legacy import.
    /// A failed migration keeps assistant.json authoritative and surfaces an error
    /// instead of silently dropping either copy.
    private func installMeetingLibrary() {
        assistant.onPersistOutcome = { [weak self] outcome in
            guard let self else { return }
            Task { await self.meetingLibrary.addOutcome(outcome, state: .ready) }
        }
        assistant.onRemoveOutcome = { [weak self] id in
            guard let self else { return }
            self.meetingLibrary.removeOutcome(id)
        }
        libraryTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            await self?.meetingLibrary.prepare()
            guard !Task.isCancelled else { return }
            await self?.migrateLegacyOutcomesIfNeeded()
        }
    }

    deinit {
        // Cancelling prevents a still-pending prepare from converting its weak
        // capture into a strong one after the store's owner has released it.
        libraryTask?.cancel()
        momentLoadTask?.cancel()
    }

    private func migrateLegacyOutcomesIfNeeded() async {
        let store = meetingLibrary.store
        do {
            if try await store.legacyOutcomesMigrated {
                assistant.markOutcomesExternal()
                await meetingLibrary.refresh()
                return
            }
            let legacy = assistant.legacyOutcomesForMigration()
            if !legacy.isEmpty { backupAssistantFile(name: "assistant.pre-meeting-library-backup.json") }
            try await store.importLegacyOutcomes(legacy)
            assistant.markOutcomesExternal()
            await meetingLibrary.refresh()
        } catch {
            // The legacy file stays authoritative; dual writes stay off and the user sees why.
            assistant.setExternalMigrationFailed(error.localizedDescription)
        }
    }

    /// Byte-exact copy kept before the first migrated write; never pruned as a log.
    private func backupAssistantFile(name: String) {
        let source = root.appendingPathComponent("assistant.json")
        let target = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: source.path),
              !FileManager.default.fileExists(atPath: target.path) else { return }
        try? FileManager.default.copyItem(at: source, to: target)
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
    /// Sets the mode every occurrence of this meeting starts in: on its room, and on its
    /// calendar series when it has one. Nil returns it to the situation defaults.
    func setMeetingMode(_ mode: AttentionMode?, room: URL, latest: URL? = nil, series: String?, title: String) {
        var preset = presetForFeedback(room: room, latest: latest, series: series, title: title)
        if let series, !preset.bindings.contains(.calendarSeries(series)) { preset.bindings.append(.calendarSeries(series)) }
        preset.mode = mode
        save(preset)
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

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()
    private var lastPrunedDay: String?

    /// Appends one JSON line to today's file and removes files older than 30 days.
    func log(_ record: AttentionDecisionRecord) {
        if loadingMoments { momentBuffer.append(record) }
        momentHistory.apply(record)
        let dayString = Self.dayFormatter.string(from: record.at)
        guard var line = try? JSONEncoder.attention.encode(record) else { return }
        line.append(0x0A)
        writeJournal([(line, dayString)], wait: true)
        if lastPrunedDay != dayString {
            lastPrunedDay = dayString
            pruneDecisions(now: record.at)
        }
    }

    private func loadMoments() async {
        guard !momentsLoaded, !loadingMoments else { return }
        loadingMoments = true
        let root = root
        let (restored, dropped) = await Task.detached(priority: .utility) { () -> (AttentionMomentHistory, Int) in
            let read = AttentionDecisionJournal.read(root: root)
            return (AttentionDecisionJournal.reduce(read.records), read.dropped)
        }.value
        if dropped > 0 {
            journalWarning = L("Part of the decision journal could not be read. %ld lines were skipped.", dropped)
        }
        var merged = restored
        for record in momentBuffer { merged.apply(record) }
        momentBuffer.removeAll()
        momentHistory = merged
        loadingMoments = false
        momentsLoaded = true
    }

    /// Awaits launch restoration in tests and before an explicit history action.
    func waitForMoments() async { await momentLoadTask?.value }

    /// Marks exactly the visible unread Moments as seen. The in-memory change is immediate;
    /// the journal lines are appended off the main thread.
    func markMomentsSeen(_ ids: [UUID], at: Date = Date()) {
        let records = momentHistory.markSeen(ids, at: at)
        guard !records.isEmpty else { return }
        // A load that finishes after this call replaces momentHistory from the disk snapshot plus momentBuffer.
        if loadingMoments { momentBuffer.append(contentsOf: records) }
        let lines: [(Data, String)] = records.compactMap { record in
            guard var line = try? JSONEncoder.attention.encode(record) else { return nil }
            line.append(0x0A)
            return (line, Self.dayFormatter.string(from: record.at))
        }
        writeJournal(lines, wait: false)
    }

    /// Awaits journal appends queued by `markMomentsSeen`.
    func waitForJournal() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            journalQueue.async { continuation.resume() }
        }
    }

    private func writeJournal(_ lines: [(Data, String)], wait: Bool) {
        let folder = decisionsFolder
        let work: @Sendable () -> Void = {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (line, day) in lines {
                    let url = folder.appendingPathComponent(day + ".jsonl")
                    try AttentionStore.appendLine(line, to: url)
                }
            } catch {
                probeLog("attention-log-failed", ["lines": lines.count])
            }
        }
        if wait { journalQueue.sync(execute: work) } else { journalQueue.async(execute: work) }
    }

    /// Opens the day file for reading and writing. Write-only handles cannot see the
    /// previous byte, so a torn last line was "repaired" by inserting a blank line every time.
    nonisolated private static func appendLine(_ line: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            // A failed handle must not fall through to an atomic rewrite of the whole day.
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            let length = try handle.seekToEnd()
            if length > 0 {
                try handle.seek(toOffset: length - 1)
                if (try? handle.read(upToCount: 1))?.first != 0x0A {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: [0x0A])
                } else {
                    try handle.seekToEnd()
                }
            }
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
    }

    func decisionFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: decisionsFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func pruneDecisions(now: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.dayFormatter.timeZone
        for url in decisionFiles() {
            guard let date = Self.dayFormatter.date(from: url.deletingPathExtension().lastPathComponent),
                  let days = calendar.dateComponents([.day], from: date, to: now).day, days > 30 else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        let cutoff = now.addingTimeInterval(-Self.decisionRetention)
        momentHistory.drop(olderThan: cutoff)
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
