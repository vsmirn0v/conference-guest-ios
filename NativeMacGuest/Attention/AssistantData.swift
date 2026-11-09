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

    init(id: UUID = UUID(), text: String, owner: String = "", dueAt: Date? = nil, reminderAt: Date? = nil, done: Bool = false) {
        self.id = id; self.text = text; self.owner = owner; self.dueAt = dueAt; self.reminderAt = reminderAt; self.done = done
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
        dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        reminderAt = try c.decodeIfPresent(Date.self, forKey: .reminderAt)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }
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

    init(id: UUID = UUID(), meetingID: UUID? = nil, meetingTitle: String, invitation: URL? = nil, seriesID: String? = nil,
         endedAt: Date, summary: String, decisions: [String] = [], tasks: [MeetingOutcomeTask] = [], openQuestions: [String] = []) {
        self.id = id; self.meetingID = meetingID; self.meetingTitle = meetingTitle; self.invitation = invitation
        self.seriesID = seriesID; self.endedAt = endedAt; self.summary = summary
        self.decisions = decisions; self.tasks = tasks; self.openQuestions = openQuestions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        meetingID = try c.decodeIfPresent(UUID.self, forKey: .meetingID)
        meetingTitle = try c.decodeIfPresent(String.self, forKey: .meetingTitle) ?? ""
        invitation = try c.decodeIfPresent(URL.self, forKey: .invitation)
        seriesID = try c.decodeIfPresent(String.self, forKey: .seriesID)
        // A missing end time used to become distantPast, and the next prune deleted the outcome.
        endedAt = try c.decode(Date.self, forKey: .endedAt)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        tasks = try c.decodeIfPresent([MeetingOutcomeTask].self, forKey: .tasks) ?? []
        openQuestions = try c.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
    }

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

    init(id: UUID = UUID(), kind: AssistantMemoryKind, text: String, createdAt: Date, updatedAt: Date,
         invitation: URL? = nil, seriesID: String? = nil, people: [String] = []) {
        self.id = id; self.kind = kind; self.text = text; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.invitation = invitation; self.seriesID = seriesID; self.people = people
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(AssistantMemoryKind.self, forKey: .kind) ?? .you
        text = try c.decode(String.self, forKey: .text)
        // Do not invent "now": a fabricated createdAt would survive retention and replace the file.
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        invitation = try c.decodeIfPresent(URL.self, forKey: .invitation)
        seriesID = try c.decodeIfPresent(String.self, forKey: .seriesID)
        people = try c.decodeIfPresent([String].self, forKey: .people) ?? []
    }
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
    /// The meeting the suggestion is about. The sentence in `text` is localized and is not a title.
    var meetingTitle: String?

    init(id: UUID = UUID(), createdAt: Date, text: String, kind: AssistantSuggestionKind, proposedText: String,
         memoryKind: AssistantMemoryKind = .you, invitation: URL? = nil, seriesID: String? = nil, mode: AttentionMode? = nil,
         meetingTitle: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.text = text; self.kind = kind
        self.proposedText = proposedText; self.memoryKind = memoryKind
        self.invitation = invitation; self.seriesID = seriesID; self.mode = mode; self.meetingTitle = meetingTitle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        text = try c.decode(String.self, forKey: .text)
        kind = try c.decodeIfPresent(AssistantSuggestionKind.self, forKey: .kind) ?? .memory
        proposedText = try c.decodeIfPresent(String.self, forKey: .proposedText) ?? text
        memoryKind = try c.decodeIfPresent(AssistantMemoryKind.self, forKey: .memoryKind) ?? .you
        invitation = try c.decodeIfPresent(URL.self, forKey: .invitation)
        seriesID = try c.decodeIfPresent(String.self, forKey: .seriesID)
        mode = try c.decodeIfPresent(AttentionMode.self, forKey: .mode)
        meetingTitle = try c.decodeIfPresent(String.self, forKey: .meetingTitle)
    }
}

/// An empty Decodable. The synthesized init accepts null, numbers, strings and arrays,
/// so a bad element is consumed and the array index advances. It is not a skip that can stall.
private struct AnyDecodable: Decodable {}

private struct LossyDecodableArray<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var skipped = 0
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try container.decode(AnyDecodable.self)
                skipped += 1
            }
        }
    }
}

private struct AssistantDataDocument: Codable {
    var outcomes: [MeetingOutcome] = []
    var memories: [AssistantMemoryItem] = []
    var suggestions: [AssistantSuggestion] = []
    var modeChanges: [AssistantModeChange] = []
    var variantPicks: [String: Int] = [:]
    var retentionDays = 90
    /// Items or collections that could not be read. Not written back.
    var droppedItems = 0
    var degraded = false

    init(outcomes: [MeetingOutcome] = [], memories: [AssistantMemoryItem] = [], suggestions: [AssistantSuggestion] = [],
         modeChanges: [AssistantModeChange] = [], variantPicks: [String: Int] = [:], retentionDays: Int = 90) {
        self.outcomes = outcomes; self.memories = memories; self.suggestions = suggestions
        self.modeChanges = modeChanges; self.variantPicks = variantPicks; self.retentionDays = retentionDays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func array<T: Decodable>(_ key: CodingKeys) -> (elements: [T], skipped: Int, damaged: Bool) {
            guard c.contains(key) else { return ([], 0, false) }
            do {
                guard let decoded = try c.decodeIfPresent(LossyDecodableArray<T>.self, forKey: key) else { return ([], 0, true) }
                return (decoded.elements, decoded.skipped, decoded.skipped > 0)
            } catch { return ([], 0, true) }
        }
        let outcomesDecoded: (elements: [MeetingOutcome], skipped: Int, damaged: Bool) = array(.outcomes)
        let memoriesDecoded: (elements: [AssistantMemoryItem], skipped: Int, damaged: Bool) = array(.memories)
        let suggestionsDecoded: (elements: [AssistantSuggestion], skipped: Int, damaged: Bool) = array(.suggestions)
        let modeChangesDecoded: (elements: [AssistantModeChange], skipped: Int, damaged: Bool) = array(.modeChanges)
        outcomes = outcomesDecoded.elements
        memories = memoriesDecoded.elements
        suggestions = suggestionsDecoded.elements
        modeChanges = modeChangesDecoded.elements
        var skipped = outcomesDecoded.skipped + memoriesDecoded.skipped + suggestionsDecoded.skipped + modeChangesDecoded.skipped
        degraded = outcomesDecoded.damaged || memoriesDecoded.damaged || suggestionsDecoded.damaged || modeChangesDecoded.damaged
        if c.contains(.variantPicks) {
            if let picks = try? c.decodeIfPresent([String: Int].self, forKey: .variantPicks) {
                variantPicks = picks
            } else { variantPicks = [:]; degraded = true; skipped += 1 }
        } else { variantPicks = [:] }
        if degraded && skipped == 0 { skipped = 1 }
        droppedItems = skipped
        retentionDays = (try? c.decodeIfPresent(Int.self, forKey: .retentionDays)) ?? 90
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outcomes, forKey: .outcomes)
        try c.encode(memories, forKey: .memories)
        try c.encode(suggestions, forKey: .suggestions)
        try c.encode(modeChanges, forKey: .modeChanges)
        try c.encode(variantPicks, forKey: .variantPicks)
        try c.encode(retentionDays, forKey: .retentionDays)
    }
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
    @Published private(set) var loadWarning: String?
    @Published private(set) var saveWarning: String?
    /// The load problem stays visible after a later save attempt. A save problem does not replace it.
    var persistenceWarning: String? { loadWarning ?? saveWarning }
    /// A degraded file is kept as-is. Saves must not replace the only copy with a partial decode.
    private var retainOriginalFile = false
    @Published var retentionDays: Int {
        didSet {
            if !loading {
                if !loaded { retentionChangedDuringLoad = true }
                prune(); persist()
            }
        }
    }

    private let url: URL
    private let readData: @Sendable (URL) async throws -> Data
    private var document = AssistantDataDocument()
    private var loading = false
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var saveGeneration = 0
    private var clearedDuringLoad = false
    private var retentionChangedDuringLoad = false
    private var deletedOutcomeIDs: Set<UUID> = []
    private var deletedMemoryIDs: Set<UUID> = []
    private var deletedSuggestionIDs: Set<UUID> = []
    private var pendingOutcomeSave: Task<Void, Never>?

    init(root: URL, readData: (@Sendable (URL) async throws -> Data)? = nil) {
        url = root.appendingPathComponent("assistant.json")
        self.readData = readData ?? { try Data(contentsOf: $0) }
        retentionDays = 90
        loadTask = Task { @MainActor [weak self] in await self?.load() }
    }

    func waitForLoad() async { await loadTask?.value }
    func waitForSave() async {
        flushOutcomeEdits()
        await saveTask?.value
    }

    private func load() async {
        let url = self.url, readData = self.readData
        let (restored, corruptError, dropped) = await Task.detached(priority: .utility) { () -> (AssistantDataDocument?, String?, Int) in
            guard let data = try? await readData(url), !data.isEmpty else { return (nil, nil, 0) }
            do {
                let document = try JSONDecoder.attention.decode(AssistantDataDocument.self, from: data)
                if document.degraded {
                    let backup = url.deletingLastPathComponent().appendingPathComponent("assistant.recovered.json")
                    try? data.write(to: backup, options: .atomic)
                }
                return (document, nil, document.droppedItems)
            } catch {
                let backup = url.deletingLastPathComponent().appendingPathComponent("assistant.corrupt.json")
                try? data.write(to: backup, options: .atomic)
                return (nil, error.localizedDescription, 0)
            }
        }.value
        loading = true
        if let corruptError {
            retainOriginalFile = true
            loadWarning = L("Assistant memory could not be read. A copy was kept. %@", corruptError)
            probeLog("assistant-data-corrupt", [:])
        } else if let restored, restored.degraded || dropped > 0 {
            retainOriginalFile = true
            loadWarning = L("Assistant memory was partly unreadable. %ld items were copied to assistant.recovered.json.", max(dropped, 1))
            probeLog("assistant-data-recovered", ["dropped": dropped])
        }
        let mutatedDuringLoad = saveGeneration > 0
        if saveGeneration == 0 {
            if let restored { document = restored }
            outcomes = document.outcomes
            memories = document.memories
            suggestions = document.suggestions
            retentionDays = document.retentionDays
        } else if let restored, !clearedDuringLoad {
            let outcomeIDs = Set(outcomes.map(\.id)).union(deletedOutcomeIDs)
            let outcomeMeetings = Set(outcomes.compactMap(\.meetingID))
            for item in restored.outcomes where !outcomeIDs.contains(item.id) && !(item.meetingID.map(outcomeMeetings.contains) ?? false) {
                outcomes.append(item)
            }
            let memoryIDs = Set(memories.map(\.id)).union(deletedMemoryIDs)
            for item in restored.memories where !memoryIDs.contains(item.id) &&
                !memories.contains(where: { $0.kind == item.kind && $0.text.caseInsensitiveCompare(item.text) == .orderedSame }) {
                memories.append(item)
            }
            let suggestionIDs = Set(suggestions.map(\.id)).union(deletedSuggestionIDs)
            for item in restored.suggestions where !suggestionIDs.contains(item.id) {
                suggestions.append(item)
            }
            document.modeChanges = Array((restored.modeChanges + document.modeChanges).suffix(100))
            for (stance, count) in restored.variantPicks { document.variantPicks[stance, default: 0] += count }
            if !retentionChangedDuringLoad { retentionDays = restored.retentionDays }
        }
        deletedOutcomeIDs.removeAll(); deletedMemoryIDs.removeAll(); deletedSuggestionIDs.removeAll()
        loading = false
        loaded = true
        prune()
        if !retainOriginalFile, mutatedDuringLoad, restored != nil, !clearedDuringLoad { persist() }
    }

    /// Keystrokes update memory at once and reach disk shortly after typing pauses.
    func flushOutcomeEdits() {
        guard pendingOutcomeSave != nil else { return }
        pendingOutcomeSave?.cancel()
        pendingOutcomeSave = nil
        persist()
    }

    private func scheduleOutcomePersist() {
        pendingOutcomeSave?.cancel()
        pendingOutcomeSave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.pendingOutcomeSave = nil
            self.persist()
        }
    }

    private func persist() {
        pendingOutcomeSave?.cancel()
        pendingOutcomeSave = nil
        if retainOriginalFile {
            saveWarning = L("Changes to Assistant memory are not being saved over the incomplete file. The original was kept.")
            return
        }
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
            self.saveWarning = error.map { L("Assistant memory could not be saved. %@", $0) }
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
        outcomes[index] = outcome
        // A write during the initial load has to be recorded before that load merges disk state.
        if !loaded { persist() } else { scheduleOutcomePersist() }
    }

    func removeOutcome(_ id: UUID) {
        if !loaded { deletedOutcomeIDs.insert(id) }
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

    func deleteMemory(_ id: UUID) {
        if !loaded { deletedMemoryIDs.insert(id) }
        memories.removeAll { $0.id == id }; persist()
    }

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
                invitation: invitation, seriesID: series, mode: mode, meetingTitle: meetingTitle), at: 0)
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
        let clean = ReplyStance.normalize(stance)
        guard !clean.isEmpty else { return }
        document.variantPicks[clean, default: 0] += 1
        persist()
    }

    /// The stance id chosen most often. Free-form and localized labels are folded into the same id.
    func preferredStance() -> String? {
        var totals: [String: Int] = [:]
        for (key, count) in document.variantPicks { totals[ReplyStance.normalize(key), default: 0] += count }
        return totals.max { lhs, rhs in lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value }?.key
    }

    /// Removes a suggestion after the caller has applied its proposed change.
    func keepSuggestion(_ id: UUID, editedText: String? = nil) {
        guard let suggestion = suggestions.first(where: { $0.id == id }) else { return }
        if !loaded { deletedSuggestionIDs.insert(id) }
        if suggestion.kind == .memory || suggestion.kind == .replyStyle {
            remember(editedText?.trimmed.isEmpty == false ? editedText! : suggestion.proposedText,
                kind: suggestion.memoryKind, invitation: suggestion.invitation, series: suggestion.seriesID)
        }
        suggestions.removeAll { $0.id == id }; persist()
    }

    func dropSuggestion(_ id: UUID) {
        if !loaded { deletedSuggestionIDs.insert(id) }
        suggestions.removeAll { $0.id == id }; persist()
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder.attention; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(AssistantDataDocument(outcomes: outcomes, memories: memories, suggestions: suggestions,
            modeChanges: [], variantPicks: [:], retentionDays: retentionDays))
    }

    func deleteAll() {
        if !loaded { clearedDuringLoad = true }
        retainOriginalFile = false
        loadWarning = nil
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
