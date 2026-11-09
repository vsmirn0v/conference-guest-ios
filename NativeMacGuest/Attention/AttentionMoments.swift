import ConferenceCore
import Foundation

/// A durable decision in the Assistant inbox. The decision journal, rather than
/// this in-memory projection, remains the source of truth.
struct AttentionMoment: Identifiable, Equatable, Sendable {
    enum State: String, CaseIterable, Sendable { case live, missed, answered, dismissed, notForMe }
    var id: UUID
    var meetingID: UUID?
    var meetingTitle: String
    var invitation: URL?
    var seriesID: String?
    var presetID: UUID?
    var verdict: AttentionVerdict
    var window: AttentionWindow?
    var threshold: Double
    var provider: String
    var model: String
    var latency: TimeInterval
    var createdAt: Date
    var updatedAt: Date
    var state: State
    var seen = false
    var mode: AttentionMode = .watch
    var mentioned = false
    var draft: ReplyDraft?
    var sent: String?
    var reaction: MeetingReaction?
    var reminderAt: Date?
    var memory: [AssistantMemoryExcerpt] = []
    var evidence: [AttentionWindow.Line] { verdict.evidence.compactMap { window?.line(id: $0) } }
}

struct AttentionQuietChecks: Equatable, Sendable, Identifiable {
    var id: String
    var meetingID: UUID?
    var meetingTitle: String
    var count = 0
    var latestAt: Date = .distantPast
}

/// Pure, allocation-bounded projection of the journal. Every event is O(1)
/// except the explicitly requested sorted inbox queries.
struct AttentionMomentHistory: Equatable, Sendable {
    private(set) var momentsByID: [UUID: AttentionMoment] = [:]
    private(set) var quietByMeeting: [String: AttentionQuietChecks] = [:]
    private var appliedRecordIDs: Set<UUID> = []

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.momentsByID == rhs.momentsByID && lhs.quietByMeeting == rhs.quietByMeeting
    }

    var moments: [AttentionMoment] { Array(momentsByID.values) }
    var quietChecks: [AttentionQuietChecks] { Array(quietByMeeting.values) }
    var unreadCount: Int { momentsByID.values.reduce(0) { $0 + (!$1.seen && [.live, .missed].contains($1.state) ? 1 : 0) } }

    func moment(_ id: UUID) -> AttentionMoment? { momentsByID[id] }
    func moments(filter: AttentionMoment.State?) -> [AttentionMoment] {
        momentsByID.values.filter { filter == nil || $0.state == filter }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString > $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
    }

    mutating func apply(_ record: AttentionDecisionRecord) {
        guard appliedRecordIDs.insert(record.id).inserted else { return }
        let decisionID = record.decisionID ?? record.id
        switch record.outcome {
        case .shown, .crowdedOut:
            guard let verdict = record.verdict else { return }
            var moment = momentsByID[decisionID] ?? AttentionMoment(id: decisionID, meetingID: record.meetingID,
                meetingTitle: record.meetingTitle, invitation: record.invitation, seriesID: record.seriesID,
                presetID: record.presetID, verdict: verdict, window: record.window,
                threshold: record.threshold ?? AttentionUrgency.normal.baseThreshold, provider: record.provider,
                model: record.model, latency: TimeInterval(record.latencyMilliseconds ?? 0) / 1000,
                createdAt: record.at, updatedAt: record.at, state: .live)
            moment.meetingID = record.meetingID ?? moment.meetingID
            moment.meetingTitle = record.meetingTitle
            moment.invitation = record.invitation ?? moment.invitation
            moment.seriesID = record.seriesID ?? moment.seriesID
            moment.presetID = record.presetID ?? moment.presetID
            moment.verdict = verdict
            moment.window = record.window ?? moment.window
            moment.threshold = record.threshold ?? moment.threshold
            moment.provider = record.provider
            moment.model = record.model
            moment.latency = TimeInterval(record.latencyMilliseconds ?? 0) / 1000
            if record.at >= moment.updatedAt { moment.updatedAt = record.at }
            // A later card must not turn an answered, dismissed, or declined Moment back into Missed.
            if ![.answered, .dismissed, .notForMe].contains(moment.state) {
                moment.state = record.outcome == .shown ? .live : .missed
            }
            if record.outcome == .crowdedOut, moment.state != .answered { moment.seen = false }
            moment.mode = record.mode ?? moment.mode
            moment.mentioned = record.mentioned ?? moment.mentioned
            moment.memory = record.memory ?? moment.memory
            momentsByID[decisionID] = moment
        case .missed:
            update(decisionID, record: record) {
                if ![.answered, .dismissed, .notForMe].contains($0.state) { $0.state = .missed }
            }
        case .opened, .replied, .reacted, .spoken:
            update(decisionID, record: record) {
                $0.state = .answered; $0.seen = true
                $0.sent = record.sent ?? $0.sent; $0.reaction = record.reaction ?? $0.reaction
            }
        case .dismissed:
            update(decisionID, record: record) { $0.state = .dismissed; $0.seen = true }
        case .declined:
            update(decisionID, record: record) { $0.state = .notForMe; $0.seen = true }
        case .seen:
            guard var moment = momentsByID[decisionID] else { return }
            moment.seen = true; momentsByID[decisionID] = moment
        case .drafted:
            guard var moment = momentsByID[decisionID] else { return }
            moment.draft = record.draft ?? moment.draft; momentsByID[decisionID] = moment
        case .reminded:
            guard var moment = momentsByID[decisionID] else { return }
            moment.reminderAt = record.reminderAt ?? record.at.addingTimeInterval(600); momentsByID[decisionID] = moment
        case .belowThreshold:
            let key = record.meetingID?.uuidString ?? record.invitation?.absoluteString ?? record.seriesID ?? record.meetingTitle.lowercased()
            var quiet = quietByMeeting[key] ?? AttentionQuietChecks(id: key, meetingID: record.meetingID, meetingTitle: record.meetingTitle)
            quiet.meetingID = record.meetingID ?? quiet.meetingID
            quiet.meetingTitle = record.meetingTitle
            quiet.count += 1; quiet.latestAt = max(quiet.latestAt, record.at)
            quietByMeeting[key] = quiet
        case .failed, .draftFailed:
            break
        }
    }

    /// Old overlays cannot survive a process restart, so unresolved Live items
    /// are retained as Missed when history is restored.
    mutating func drop(olderThan cutoff: Date) {
        momentsByID = momentsByID.filter { $0.value.updatedAt >= cutoff || $0.value.createdAt >= cutoff }
        quietByMeeting = quietByMeeting.filter { $0.value.latestAt >= cutoff }
    }

    mutating func settleHistoricalLive() {
        for (id, var moment) in momentsByID where moment.state == .live {
            moment.state = .missed; momentsByID[id] = moment
        }
    }

    mutating func markSeen(_ ids: [UUID], at: Date) -> [AttentionDecisionRecord] {
        ids.compactMap { id in
            guard var moment = momentsByID[id], !moment.seen else { return nil }
            moment.seen = true; momentsByID[id] = moment
            let record = AttentionDecisionRecord(id: UUID(), at: at, meetingTitle: moment.meetingTitle,
                meetingID: moment.meetingID, invitation: moment.invitation, seriesID: moment.seriesID,
                presetID: moment.presetID, provider: moment.provider, model: moment.model,
                outcome: .seen, decisionID: id)
            appliedRecordIDs.insert(record.id)
            return record
        }
    }

    private mutating func update(_ id: UUID, record: AttentionDecisionRecord, _ change: (inout AttentionMoment) -> Void) {
        guard var moment = momentsByID[id] else { return }
        let updatedAt = moment.updatedAt
        change(&moment)
        if record.outcome != .seen, record.at >= updatedAt { moment.updatedAt = record.at }
        momentsByID[id] = moment
    }
}

/// File IO is deliberately outside the MainActor store and performed only at launch.
enum AttentionDecisionJournal {
    static func read(root: URL) -> (records: [AttentionDecisionRecord], dropped: Int) {
        let folder = root.appendingPathComponent("decisions", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let decoder = JSONDecoder.attention
        var records: [AttentionDecisionRecord] = []
        var dropped = 0
        for url in files {
            guard let data = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if let record = try? decoder.decode(AttentionDecisionRecord.self, from: Data(line.utf8)) { records.append(record) }
                else { dropped += 1 }
            }
        }
        return (records, dropped)
    }

    /// Replays the journal in file order. Sorting by `at` would move a same-second
    /// follow-up ahead of the decision that created the Moment when the clock has no fractions.
    static func reduce(_ records: [AttentionDecisionRecord]) -> AttentionMomentHistory {
        var history = AttentionMomentHistory()
        for record in records { history.apply(record) }
        history.settleHistoricalLive()
        return history
    }
}
