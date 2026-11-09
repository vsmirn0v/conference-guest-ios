import ConferenceCore
import Foundation

/// One saved judge decision, ready to send to another model.
struct ComparisonCase: Identifiable, Equatable, Sendable {
    let id: UUID
    let at: Date
    let meetingTitle: String
    let messages: [[String: String]]
    let window: AttentionWindow
    /// The verdict the app showed or held back, and the model that gave it.
    let original: AttentionVerdict
    let originalModel: String
    let threshold: Double
    var presetID: UUID? = nil
    /// What you did with the card: true for Open, a reply or a reaction, false
    /// for Decline, nil when you never saw it or did not choose.
    let needed: Bool?

    func wouldShow(_ verdict: AttentionVerdict) -> Bool { verdict.level != .no && verdict.probability >= threshold }
}

/// One saved reply draft, with what you then sent.
struct DraftCase: Identifiable, Equatable, Sendable {
    let id: UUID
    let at: Date
    let meetingTitle: String
    let messages: [[String: String]]
    let original: ReplyDraft
    let originalModel: String
    let channels: ReplyChannels
    let sent: String?
    let reaction: MeetingReaction?
}

enum ComparisonLoader {
    /// Reads the decision log, newest first, with decisions you chose on first.
    static func load(_ files: [URL]) -> (cases: [ComparisonCase], drafts: [DraftCase]) {
        var verdicts: [AttentionDecisionRecord] = [], drafted: [AttentionDecisionRecord] = []
        var choices: [UUID: Bool] = [:], sent: [UUID: (String?, MeetingReaction?)] = [:]
        let decoder = JSONDecoder.attention
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let record = try? decoder.decode(AttentionDecisionRecord.self, from: Data(line.utf8)) else { continue }
                if record.verdict != nil, record.window != nil, record.messages?.isEmpty == false { verdicts.append(record); continue }
                guard let decision = record.decisionID else { continue }
                switch record.outcome {
                case .opened: choices[decision] = true
                case .replied, .reacted, .spoken: choices[decision] = true; sent[decision] = (record.sent, record.reaction)
                case .declined: choices[decision] = false
                case .drafted where record.replyMessages?.isEmpty == false && record.draft != nil: drafted.append(record)
                default: break
                }
            }
        }
        let cases = verdicts.compactMap { record -> ComparisonCase? in
            guard let verdict = record.verdict, let window = record.window, let messages = record.messages else { return nil }
            return .init(id: record.id, at: record.at, meetingTitle: record.meetingTitle, messages: messages, window: window,
                         original: verdict, originalModel: record.model,
                         threshold: record.threshold ?? AttentionUrgency.normal.baseThreshold, presetID: record.presetID,
                         needed: choices[record.id])
        }.sorted { ($0.needed != nil) == ($1.needed != nil) ? $0.at > $1.at : $0.needed != nil }
        // The newest draft per card, with what you sent from it.
        var latest: [UUID: AttentionDecisionRecord] = [:]
        for record in drafted { if let card = record.decisionID, (latest[card]?.at ?? .distantPast) <= record.at { latest[card] = record } }
        let drafts = latest.values.compactMap { record -> DraftCase? in
            guard let card = record.decisionID, let messages = record.replyMessages, let draft = record.draft else { return nil }
            return .init(id: card, at: record.at, meetingTitle: record.meetingTitle, messages: messages, original: draft,
                         originalModel: record.model, channels: channels(of: messages), sent: sent[card]?.0, reaction: sent[card]?.1)
        }.sorted { $0.at > $1.at }
        return (cases, drafts)
    }

    /// The answer options the writer was offered, read back from its prompt.
    static func channels(of messages: [[String: String]]) -> ReplyChannels {
        let prompt = messages.last?["content"] ?? ""
        return .init(chat: prompt.contains("a chat message"), reactions: prompt.contains("one reaction:") ? MeetingReaction.allCases : [])
    }
}

/// Finds the threshold under which the saved verdicts would have matched your
/// choices best, instead of moving it ±0.05 per card.
enum ThresholdTuner {
    struct Result: Equatable {
        let threshold: Double
        let agreed: Int
        let labelled: Int
        /// Agreement at the meeting's current threshold, for comparison.
        let currentAgreed: Int
    }
    static let minimumChoices = 6

    /// Needs at least six choices with both kinds among them; ties keep the threshold
    /// closest to the current one.
    static func best(_ cases: [ComparisonCase], current: Double, range: ClosedRange<Double> = MeetingPreset.thresholdRange) -> Result? {
        let labelled = cases.compactMap { item in item.needed.map { (verdict: item.original, needed: $0) } }
        guard labelled.count >= minimumChoices, labelled.contains(where: \.needed), labelled.contains(where: { !$0.needed }) else { return nil }
        func agreed(_ threshold: Double) -> Int {
            labelled.filter { ($0.verdict.level != .no && $0.verdict.probability >= threshold - 1e-9) == $0.needed }.count
        }
        var best = (threshold: current, agreed: agreed(current))
        for step in 0...Int(((range.upperBound - range.lowerBound) / 0.05).rounded()) {
            let threshold = ((range.lowerBound + Double(step) * 0.05) * 100).rounded() / 100
            let score = agreed(threshold)
            if score > best.agreed || score == best.agreed && abs(threshold - current) < abs(best.threshold - current) {
                best = (threshold, score)
            }
        }
        return .init(threshold: best.threshold, agreed: best.agreed, labelled: labelled.count, currentAgreed: agreed(current))
    }
}

/// How one model's verdicts compare with your choices.
struct ComparisonScore: Equatable {
    var judged = 0
    var labelled = 0
    var agreed = 0
    var truePositives = 0, falsePositives = 0, falseNegatives = 0
    var shown = 0
    var failed = 0
    var latencies: [TimeInterval] = []

    var agreement: Double? { labelled == 0 ? nil : Double(agreed) / Double(labelled) }
    var precision: Double? { truePositives + falsePositives == 0 ? nil : Double(truePositives) / Double(truePositives + falsePositives) }
    var recall: Double? { truePositives + falseNegatives == 0 ? nil : Double(truePositives) / Double(truePositives + falseNegatives) }
    var medianLatency: TimeInterval? {
        guard !latencies.isEmpty else { return nil }
        let sorted = latencies.sorted(); return sorted[sorted.count / 2]
    }

    mutating func add(show: Bool, needed: Bool?, latency: TimeInterval?) {
        judged += 1; shown += show ? 1 : 0
        if let latency { latencies.append(latency) }
        guard let needed else { return }
        labelled += 1; agreed += show == needed ? 1 : 0
        truePositives += show && needed ? 1 : 0; falsePositives += show && !needed ? 1 : 0; falseNegatives += !show && needed ? 1 : 0
    }
}

/// Sends saved decisions and drafts to another model and scores the answers
/// against what you did. Nothing is sent into any meeting.
@MainActor final class ModelComparison: ObservableObject {
    struct Row: Identifiable, Equatable {
        let item: ComparisonCase
        var candidate: AttentionVerdict?
        var latency: TimeInterval?
        var error: String?
        var id: UUID { item.id }
        var changed: Bool { candidate.map { item.wouldShow($0) != item.wouldShow(item.original) } ?? false }
    }
    struct DraftRow: Identifiable, Equatable {
        let item: DraftCase
        var candidate: ReplyDraft?
        var error: String?
        var id: UUID { item.id }
    }

    @Published private(set) var cases: [ComparisonCase] = []
    @Published private(set) var drafts: [DraftCase] = []
    @Published private(set) var rows: [Row] = []
    @Published private(set) var draftRows: [DraftRow] = []
    @Published private(set) var running = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var candidateModel = ""
    @Published private(set) var candidateContext: Int?

    var judge: (AttentionProvider, String?, [[String: String]], AttentionWindow) async throws -> JudgeResult = {
        try await OpenAIChatJudge(provider: $0, key: $1).judge(messages: $2, window: $3)
    }
    var write: (AttentionProvider, String?, [[String: String]], ReplyChannels) async throws -> ReplyResult = {
        try await OpenAIChatJudge(provider: $0, key: $1).draft(messages: $2, channels: $3)
    }
    private var task: Task<Void, Never>?

    func load(from store: AttentionStore) {
        let loaded = ComparisonLoader.load(store.decisionFiles())
        cases = loaded.cases; drafts = loaded.drafts
    }

    /// The saved verdicts on the same decisions, scored the same way.
    var originalScore: ComparisonScore {
        var score = ComparisonScore()
        for row in rows { score.add(show: row.item.wouldShow(row.item.original), needed: row.item.needed, latency: nil) }
        return score
    }
    var candidateScore: ComparisonScore {
        var score = ComparisonScore()
        for row in rows {
            guard let verdict = row.candidate else { if row.error != nil { score.failed += 1 }; continue }
            score.add(show: row.item.wouldShow(verdict), needed: row.item.needed, latency: row.latency)
        }
        return score
    }

    /// Runs up to `limit` decisions and `draftLimit` drafts through `model` at
    /// the configured provider, one request at a time.
    func run(model: String, provider: AttentionProvider, key: String?, limit: Int, draftLimit: Int, contextLength: Int? = nil) {
        task?.cancel()
        var candidate = provider
        candidate.adopt(model: model.trimmed, contextLength: contextLength)
        let chosen = Array(cases.prefix(limit)), chosenDrafts = Array(drafts.prefix(draftLimit))
        candidateModel = candidate.model
        candidateContext = contextLength
        rows = chosen.map { Row(item: $0) }; draftRows = chosenDrafts.map { DraftRow(item: $0) }
        done = 0; total = chosen.count + chosenDrafts.count; running = total > 0
        guard running else { return }
        task = Task { @MainActor [weak self] in
            for (index, item) in chosen.enumerated() {
                guard let self, !Task.isCancelled else { return }
                do {
                    let result = try await judge(candidate, key, item.messages, item.window)
                    rows[index].candidate = result.verdict; rows[index].latency = result.latency
                } catch is CancellationError { return }
                catch { rows[index].error = error.localizedDescription }
                done += 1
            }
            for (index, item) in chosenDrafts.enumerated() {
                guard let self, !Task.isCancelled else { return }
                do { draftRows[index].candidate = try await write(candidate, key, item.messages, item.channels).draft }
                catch is CancellationError { return }
                catch { draftRows[index].error = error.localizedDescription }
                done += 1
            }
            self?.running = false
            probeLog("attention-comparison", ["decisions": chosen.count, "drafts": chosenDrafts.count])
        }
    }
    func cancel() { task?.cancel(); task = nil; running = false }
}
