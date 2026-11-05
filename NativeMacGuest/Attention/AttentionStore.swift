import Foundation
import Security

/// Where the judge runs: any OpenAI-compatible chat completions endpoint.
struct AttentionProvider: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case openAI, openRouter, local, custom }
    var kind: Kind
    var baseURL: String
    var model: String

    static let defaults: [Kind: AttentionProvider] = [
        .openAI: .init(kind: .openAI, baseURL: "https://api.openai.com/v1", model: "gpt-4.1-mini"),
        .openRouter: .init(kind: .openRouter, baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-4.1-mini"),
        .local: .init(kind: .local, baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:8b"),
        .custom: .init(kind: .custom, baseURL: "https://", model: ""),
    ]
    var title: String {
        switch kind { case .openAI: "OpenAI"; case .openRouter: "OpenRouter"; case .local: L("Server on this network"); case .custom: L("Other") }
    }
    /// A local server usually needs no key.
    var needsKey: Bool { kind != .local }
    var endpoint: URL? {
        guard var base = URL(string: baseURL.trimmed), let scheme = base.scheme?.lowercased(), ["https", "http"].contains(scheme), base.host != nil else { return nil }
        if base.absoluteString.hasSuffix("/") { base = URL(string: String(base.absoluteString.dropLast())) ?? base }
        return base.appendingPathComponent("chat/completions")
    }
    /// Shown as what leaves this Mac; never includes the key.
    var host: String { URL(string: baseURL.trimmed)?.host ?? baseURL }
}

/// The judge's API key, kept in the login keychain for this app only.
struct AttentionKeychain: Sendable {
    var service = "dev.vsmirn0v.conferenceguest.attention"
    var account = "judge-api-key"
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
}

/// One judged window and what you did with it; replayed to tune prompts.
struct AttentionDecisionRecord: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case belowThreshold, shown, opened, dismissed, declined, failed }
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
}

/// Presets, your profile, the judge settings and the decision log. Everything is
/// stored on this Mac; only the meeting window and its preset go to the provider.
@MainActor final class AttentionStore: ObservableObject {
    static let shared = AttentionStore()
    static let enabledKey = "attention.judge.enabled"
    static let batteryKey = "attention.judge.pauseOnBattery"
    static let providerKey = "attention.judge.provider"
    static let decisionRetention: TimeInterval = 30 * 24 * 3600

    private struct Document: Codable { var profile = AttentionProfile(); var presets: [MeetingPreset] = [] }

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.enabledKey) } }
    @Published var pauseOnBattery: Bool { didSet { defaults.set(pauseOnBattery, forKey: Self.batteryKey) } }
    @Published var provider: AttentionProvider {
        didSet { if let data = try? JSONEncoder().encode(provider) { defaults.set(data, forKey: Self.providerKey) } }
    }
    @Published var profile: AttentionProfile { didSet { if profile != oldValue { save() } } }
    @Published private(set) var presets: [MeetingPreset] = []
    @Published private(set) var hasKey: Bool
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
        provider = defaults.data(forKey: Self.providerKey).flatMap { try? JSONDecoder().decode(AttentionProvider.self, from: $0) }
            ?? AttentionProvider.defaults[.openAI]!
        hasKey = keychain.read()?.isEmpty == false
        profile = AttentionProfile()
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
    func apiKey() -> String? { keychain.read().flatMap { $0.trimmed.isEmpty ? nil : $0.trimmed } }
    @discardableResult func setAPIKey(_ value: String) -> Bool {
        let clean = value.trimmed
        let saved = clean.isEmpty ? keychain.delete() : keychain.write(clean)
        hasKey = apiKey() != nil
        return saved
    }
    var ready: Bool { enabled && provider.endpoint != nil && !provider.model.trimmed.isEmpty && (!provider.needsKey || hasKey) }

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
