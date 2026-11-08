import Combine
import ConferenceCore
import Foundation

struct MeetingOutcomeTask: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var text: String
    var owner = ""
    var dueAt: Date?
    var reminderAt: Date?
    var done = false
}

struct MeetingOutcome: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var meetingID: UUID?
    var meetingTitle: String
    var invitation: URL?
    var seriesID: String?
    var endedAt: Date
    var summary: String
    var decisions: [String] = []
    var tasks: [MeetingOutcomeTask] = []
    var openQuestions: [String] = []

    var shareText: String {
        var parts = [summary.trimmed]
        if !decisions.isEmpty { parts.append(L("Decisions") + ":\n" + decisions.map { "• " + $0 }.joined(separator: "\n")) }
        if !tasks.isEmpty {
            parts.append(L("Tasks") + ":\n" + tasks.map { task in
                "• " + task.text + (task.owner.trimmed.isEmpty ? "" : " — " + task.owner)
            }.joined(separator: "\n"))
        }
        if !openQuestions.isEmpty { parts.append(L("Open questions") + ":\n" + openQuestions.map { "• " + $0 }.joined(separator: "\n")) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

enum AssistantMemoryKind: String, Codable, CaseIterable, Sendable {
    case people = "People", meetings = "Meetings", you = "You"
    var title: String { L(rawValue) }
}

struct AssistantMemoryItem: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: AssistantMemoryKind
    var text: String
    var createdAt: Date
    var updatedAt: Date
    var invitation: URL?
    var seriesID: String?
    var people: [String] = []
}

struct AssistantMemoryExcerpt: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var kind: AssistantMemoryKind
    var text: String
    var sourceID: UUID
}

struct AssistantModeChange: Codable, Equatable, Sendable {
    var at: Date
    var title: String
    var invitation: URL
    var seriesID: String?
    var mode: AttentionMode
}

enum AssistantSuggestionKind: String, Codable, Sendable { case memory, meetingMode, replyStyle }

struct AssistantSuggestion: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var createdAt: Date
    var text: String
    var kind: AssistantSuggestionKind
    var proposedText: String
    var memoryKind: AssistantMemoryKind = .you
    var invitation: URL?
    var seriesID: String?
    var mode: AttentionMode?
}

private struct AssistantDataDocument: Codable {
    var outcomes: [MeetingOutcome] = []
    var memories: [AssistantMemoryItem] = []
    var suggestions: [AssistantSuggestion] = []
    var modeChanges: [AssistantModeChange] = []
    var variantPicks: [String: Int] = [:]
    var retentionDays = 90
}

/// Outcomes, explicit memories and reviewable suggestions. Reads happen once on a
/// utility task; every write sends an immutable snapshot to the same background queue.
@MainActor final class AssistantDataStore: ObservableObject {
    static let outcomeLimit = 200
    static let memoryLimit = 300
    static let suggestionLimit = 30
    static let retrievalLimit = 5

    @Published private(set) var outcomes: [MeetingOutcome] = []
    @Published private(set) var memories: [AssistantMemoryItem] = []
    @Published private(set) var suggestions: [AssistantSuggestion] = []
    @Published private(set) var loaded = false
    @Published private(set) var persistenceWarning: String?
    @Published var retentionDays: Int { didSet { if !loading { prune(); persist() } } }

    private let url: URL
    private let readData: @Sendable (URL) async throws -> Data
    private var document = AssistantDataDocument()
    private var loading = false
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var saveGeneration = 0

    init(root: URL, readData: (@Sendable (URL) async throws -> Data)? = nil) {
        url = root.appendingPathComponent("assistant.json")
        self.readData = readData ?? { try Data(contentsOf: $0) }
        retentionDays = 90
        loadTask = Task { @MainActor [weak self] in await self?.load() }
    }

    func waitForLoad() async { await loadTask?.value }
    func waitForSave() async { await saveTask?.value }

    private func load() async {
        let url = self.url, readData = self.readData
        let restored = await Task.detached(priority: .utility) { () -> AssistantDataDocument? in
            guard let data = try? await readData(url) else { return nil }
            return try? JSONDecoder.attention.decode(AssistantDataDocument.self, from: data)
        }.value
        loading = true
        // A user can edit or delete while the initial disk read is in flight. Every
        // such mutation starts a snapshot save; never replace it with stale bytes.
        if saveGeneration == 0 {
            if let restored { document = restored }
            outcomes = document.outcomes
            memories = document.memories
            suggestions = document.suggestions
            retentionDays = document.retentionDays
        }
        loading = false
        loaded = true
        prune()
    }

    private func persist() {
        document.outcomes = outcomes
        document.memories = memories
        document.suggestions = suggestions
        document.retentionDays = retentionDays
        saveGeneration += 1
        let generation = saveGeneration, snapshot = document, url = self.url
        let previous = saveTask
        saveTask = Task { @MainActor [weak self] in
            // Chain writes in snapshot order. Cancelling a detached file write cannot
            // undo bytes already written, so the newest snapshot must always run last.
            await previous?.value
            let error = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder.attention.encode(snapshot).write(to: url, options: .atomic)
                    return nil
                } catch {
                    probeLog("assistant-data-save-failed", ["generation": generation])
                    return error.localizedDescription
                }
            }.value
            guard let self, self.saveGeneration == generation else { return }
            self.persistenceWarning = error.map { L("Assistant memory could not be saved. %@", $0) }
            probeLog("assistant-data-saved", ["generation": generation, "failed": error != nil])
        }
    }

    private func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-TimeInterval(max(1, retentionDays)) * 86400)
        outcomes = outcomes.filter { $0.endedAt >= cutoff }.sorted { $0.endedAt > $1.endedAt }
        memories = memories.filter { $0.updatedAt >= cutoff }.sorted { $0.updatedAt > $1.updatedAt }
        suggestions = suggestions.filter { $0.createdAt >= cutoff }
        document.modeChanges = document.modeChanges.filter { $0.at >= now.addingTimeInterval(-30 * 86400) }.suffix(100)
        if outcomes.count > Self.outcomeLimit { outcomes.removeLast(outcomes.count - Self.outcomeLimit) }
        if memories.count > Self.memoryLimit { memories.removeLast(memories.count - Self.memoryLimit) }
        if suggestions.count > Self.suggestionLimit { suggestions.removeLast(suggestions.count - Self.suggestionLimit) }
    }

    func addOutcome(_ outcome: MeetingOutcome) {
        outcomes.removeAll { $0.id == outcome.id || ($0.meetingID != nil && $0.meetingID == outcome.meetingID) }
        outcomes.insert(outcome, at: 0)
        absorbOutcome(outcome)
        prune(); persist()
    }

    func updateOutcome(_ outcome: MeetingOutcome) {
        guard let index = outcomes.firstIndex(where: { $0.id == outcome.id }) else { return }
        outcomes[index] = outcome; persist()
    }

    func removeOutcome(_ id: UUID) {
        outcomes.removeAll { $0.id == id }; persist()
    }

    func latestOutcome(invitation: URL? = nil, series: String? = nil, before: Date = .distantFuture) -> MeetingOutcome? {
        outcomes.first { outcome in
            outcome.endedAt < before && ((series != nil && outcome.seriesID == series) ||
                (invitation != nil && outcome.invitation == invitation))
        }
    }

    func seriesOutcomes(invitation: URL? = nil, series: String? = nil) -> [MeetingOutcome] {
        outcomes.filter { (series != nil && $0.seriesID == series) || (invitation != nil && $0.invitation == invitation) }
    }

    func remember(_ text: String, kind: AssistantMemoryKind = .you, invitation: URL? = nil, series: String? = nil, people: [String] = []) {
        let clean = String(text.trimmed.prefix(500))
        guard !clean.isEmpty else { return }
        let now = Date()
        if let index = memories.firstIndex(where: { $0.kind == kind && $0.text.caseInsensitiveCompare(clean) == .orderedSame }) {
            memories[index].updatedAt = now
            memories[index].invitation = invitation ?? memories[index].invitation
            memories[index].seriesID = series ?? memories[index].seriesID
            memories[index].people = Array(Set(memories[index].people + people)).sorted()
        } else {
            memories.insert(.init(kind: kind, text: clean, createdAt: now, updatedAt: now,
                                  invitation: invitation, seriesID: series, people: people), at: 0)
        }
        prune(); persist()
    }

    func updateMemory(_ item: AssistantMemoryItem) {
        guard let index = memories.firstIndex(where: { $0.id == item.id }), !item.text.trimmed.isEmpty else { return }
        var copy = item; copy.text = String(copy.text.trimmed.prefix(500)); copy.updatedAt = Date()
        memories[index] = copy; persist()
    }

    func deleteMemory(_ id: UUID) { memories.removeAll { $0.id == id }; persist() }

    /// Local deterministic retrieval: series/room and participant matches rank above
    /// token overlap and recency. At most five bounded excerpts reach any prompt.
    func retrieve(meetingTitle: String, invitation: URL?, series: String?, people: [String]) -> [AssistantMemoryExcerpt] {
        var candidates: [(score: Int, at: Date, excerpt: AssistantMemoryExcerpt)] = []
        let words = Self.tokens(meetingTitle + " " + people.joined(separator: " "))
        for item in memories {
            var score = item.kind == .you ? 1 : 0
            if let series, item.seriesID == series { score += 12 }
            if let invitation, item.invitation == invitation { score += 8 }
            score += Set(item.people.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) })
                .intersection(people.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }).count * 4
            score += Self.tokens(item.text).intersection(words).count
            guard score > 0 else { continue }
            candidates.append((score, item.updatedAt, .init(id: "memory-" + item.id.uuidString, kind: item.kind,
                text: String(item.text.prefix(350)), sourceID: item.id)))
        }
        for outcome in outcomes {
            var score = 0
            if let series, outcome.seriesID == series { score += 12 }
            if let invitation, outcome.invitation == invitation { score += 8 }
            let excerpts = [outcome.summary] + outcome.decisions + outcome.tasks.map { $0.text }
            for (index, text) in excerpts.enumerated() where !text.trimmed.isEmpty {
                let tokenScore = Self.tokens(text).intersection(words).count
                guard score + tokenScore > 0 else { continue }
                candidates.append((score + tokenScore, outcome.endedAt, .init(id: "outcome-\(outcome.id.uuidString)-\(index)",
                    kind: .meetings, text: String(text.prefix(350)), sourceID: outcome.id)))
            }
        }
        return candidates.sorted { ($0.score, $0.at, $0.excerpt.id) > ($1.score, $1.at, $1.excerpt.id) }
            .prefix(Self.retrievalLimit).map(\.excerpt)
    }

    private static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { $0.count > 2 })
    }

    func observeModeChange(_ mode: AttentionMode, meetingTitle: String, invitation: URL, series: String?, now: Date = Date()) {
        document.modeChanges.append(.init(at: now, title: meetingTitle, invitation: invitation, seriesID: series, mode: mode))
        document.modeChanges = Array(document.modeChanges.suffix(100))
        let matches = document.modeChanges.filter {
            $0.mode == mode && $0.invitation == invitation && $0.seriesID == series && now.timeIntervalSince($0.at) <= 7 * 86400
        }
        if matches.count >= 3, !suggestions.contains(where: { $0.kind == .meetingMode && $0.invitation == invitation && $0.mode == mode }) {
            suggestions.insert(.init(createdAt: now, text: L("You chose %@ for “%@” three times this week.", mode.title, meetingTitle),
                kind: .meetingMode, proposedText: L("Use %@ by default", mode.title), memoryKind: .meetings,
                invitation: invitation, seriesID: series, mode: mode), at: 0)
        }
        prune(); persist()
    }

    func suggestKnownTopic(_ text: String, meetingTitle: String, invitation: URL, series: String?) {
        let clean = String(text.trimmed.prefix(200))
        guard !clean.isEmpty, !suggestions.contains(where: { $0.proposedText == clean && $0.invitation == invitation }) else { return }
        suggestions.insert(.init(createdAt: Date(), text: L("You often already know this topic in “%@”.", meetingTitle),
            kind: .memory, proposedText: clean, memoryKind: .meetings, invitation: invitation, seriesID: series), at: 0)
        prune(); persist()
    }

    func observeVariant(_ stance: String) {
        let clean = stance.trimmed
        guard !clean.isEmpty else { return }
        document.variantPicks[clean, default: 0] += 1
        persist()
    }

    func preferredStance() -> String? { document.variantPicks.max { $0.value < $1.value }?.key }

    /// Removes a suggestion after the caller has applied its proposed change.
    func keepSuggestion(_ id: UUID, editedText: String? = nil) {
        guard let suggestion = suggestions.first(where: { $0.id == id }) else { return }
        if suggestion.kind == .memory || suggestion.kind == .replyStyle {
            remember(editedText?.trimmed.isEmpty == false ? editedText! : suggestion.proposedText,
                kind: suggestion.memoryKind, invitation: suggestion.invitation, series: suggestion.seriesID)
        }
        suggestions.removeAll { $0.id == id }; persist()
    }

    func dropSuggestion(_ id: UUID) { suggestions.removeAll { $0.id == id }; persist() }

    func exportData() throws -> Data {
        let encoder = JSONEncoder.attention; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(AssistantDataDocument(outcomes: outcomes, memories: memories, suggestions: suggestions,
            modeChanges: [], variantPicks: [:], retentionDays: retentionDays))
    }

    func deleteAll() {
        outcomes = []; memories = []; suggestions = []; document = .init(); document.retentionDays = retentionDays
        persist()
    }

    private func absorbOutcome(_ outcome: MeetingOutcome) {
        // Outcomes themselves are retrieved as meeting memory. Do not silently copy
        // their claims into editable memory: only explicit Keep or Remember does that.
        let ownTasks = outcome.tasks.filter { !$0.done && $0.owner.trimmed.isEmpty }
        if !ownTasks.isEmpty {
            let text = ownTasks.prefix(2).map(\.text).joined(separator: "; ")
            if !text.isEmpty, !suggestions.contains(where: { $0.kind == .memory && $0.proposedText == text }) {
                suggestions.insert(.init(createdAt: Date(), text: L("Keep your commitments from “%@” in memory?", outcome.meetingTitle),
                    kind: .memory, proposedText: String(text.prefix(400)), memoryKind: .you,
                    invitation: outcome.invitation, seriesID: outcome.seriesID), at: 0)
            }
        }
    }
}
