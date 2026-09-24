import Foundation

public enum MissedReason: String, Codable, Hashable, Sendable {
    case anotherCall
    case connection
    case audioInterruption
}

public struct MissedInterval: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let start: Date
    public var end: Date?
    public let reasons: Set<MissedReason>

    public var isOngoing: Bool { end == nil }
}

public struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let speaker: String?
    public let text: String
    /// Nil when the provider's clock cannot safely be aligned with wall time.
    public let spokenAt: Date?

    public init(id: String, speaker: String?, text: String, spokenAt: Date?) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.spokenAt = spokenAt
    }
}

/// A local index of suspected missed time and provider transcript messages.
/// It never equates a received transcript with proof of complete audio coverage.
public struct CatchUpTimeline: Codable {
    public private(set) var intervals: [MissedInterval] = []
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var isTruncated = false
    public private(set) var lastReviewedCount = 0
    public private(set) var reviewedIntervalIDs = Set<UUID>()

    private var activeReasons = Set<MissedReason>()
    private var segmentsByID: [String: TranscriptSegment] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case intervals, segments, isTruncated, lastReviewedCount, reviewedIntervalIDs
        case activeReasons, segmentsByID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        intervals = try values.decode([MissedInterval].self, forKey: .intervals)
        segments = try values.decode([TranscriptSegment].self, forKey: .segments)
        isTruncated = try values.decode(Bool.self, forKey: .isTruncated)
        lastReviewedCount = try values.decodeIfPresent(Int.self, forKey: .lastReviewedCount) ?? 0
        reviewedIntervalIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .reviewedIntervalIDs)
            ?? Set(intervals.prefix(lastReviewedCount).map(\.id))
        activeReasons = try values.decodeIfPresent(Set<MissedReason>.self, forKey: .activeReasons) ?? []
        segmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(intervals, forKey: .intervals)
        try values.encode(segments, forKey: .segments)
        try values.encode(isTruncated, forKey: .isTruncated)
        try values.encode(lastReviewedCount, forKey: .lastReviewedCount)
        try values.encode(reviewedIntervalIDs, forKey: .reviewedIntervalIDs)
        try values.encode(activeReasons, forKey: .activeReasons)
    }

    public var unreadCount: Int {
        intervals.filter { !reviewedIntervalIDs.contains($0.id) }.count
    }

    public func isReviewed(_ interval: MissedInterval) -> Bool {
        reviewedIntervalIDs.contains(interval.id)
    }

    public mutating func begin(_ reason: MissedReason, at time: Date = Date()) {
        guard activeReasons.insert(reason).inserted else { return }
        if activeReasons.count == 1 {
            intervals.append(MissedInterval(id: UUID(), start: time, end: nil, reasons: [reason]))
            if intervals.count > 100 {
                let removed = intervals.removeFirst()
                reviewedIntervalIDs.remove(removed.id)
                isTruncated = true
            }
        } else if let index = intervals.indices.last, intervals[index].end == nil {
            intervals[index] = MissedInterval(id: intervals[index].id,
                                              start: intervals[index].start,
                                              end: nil,
                                              reasons: intervals[index].reasons.union([reason]))
        }
    }

    public mutating func end(_ reason: MissedReason, at time: Date = Date()) {
        guard activeReasons.remove(reason) != nil, activeReasons.isEmpty,
              let index = intervals.indices.last, intervals[index].end == nil else { return }
        intervals[index].end = max(time, intervals[index].start)
    }

    public mutating func upsert(_ incoming: [TranscriptSegment]) {
        var changed = false
        for segment in incoming where !segment.id.isEmpty && !segment.text.isEmpty {
            if segmentsByID[segment.id] != segment {
                segmentsByID[segment.id] = segment
                changed = true
            }
        }
        guard changed else { return }
        let ordered = segmentsByID.values.sorted {
            switch ($0.spokenAt, $1.spokenAt) {
            case let (a?, b?): return a == b ? $0.id < $1.id : a < b
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return $0.id < $1.id
            }
        }
        if ordered.count > 5_000 {
            isTruncated = true
            segments = Array(ordered.suffix(5_000))
            segmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        } else {
            segments = ordered
        }
    }

    public func transcript(during interval: MissedInterval, now: Date = Date()) -> [TranscriptSegment] {
        let end = interval.end ?? now
        return segments.filter { segment in
            guard let timestamp = segment.spokenAt else { return false }
            return timestamp >= interval.start.addingTimeInterval(-5)
                && timestamp <= end.addingTimeInterval(5)
        }
    }

    public mutating func markReviewed() {
        reviewedIntervalIDs.formUnion(intervals.filter { $0.end != nil }.map(\.id))
        lastReviewedCount = reviewedIntervalIDs.count
    }

    public mutating func markReviewed(_ id: UUID) {
        guard intervals.contains(where: { $0.id == id && $0.end != nil }) else { return }
        reviewedIntervalIDs.insert(id)
        lastReviewedCount = reviewedIntervalIDs.count
    }

    /// After an app restart, old CallKit and audio-session reasons cannot be
    /// observed again. Treat the unobserved time as one connection gap.
    public mutating func resumeAfterRestart(at time: Date = Date()) {
        let start = min(time, Date())
        if let index = intervals.indices.last, intervals[index].end == nil {
            activeReasons = [.connection]
            intervals[index] = MissedInterval(id: intervals[index].id,
                                              start: intervals[index].start,
                                              end: nil,
                                              reasons: intervals[index].reasons.union([.connection]))
        } else {
            activeReasons = []
            begin(.connection, at: start)
        }
    }

    /// Some SDK versions send Unix seconds and others milliseconds. An unknown
    /// timestamp remains unaligned rather than being assigned to a missed gap.
    public static func providerDate(_ value: TimeInterval, now: Date = Date()) -> Date? {
        guard value.isFinite else { return nil }
        let seconds = value > 10_000_000_000 ? value / 1_000 : value
        let date = Date(timeIntervalSince1970: seconds)
        guard date >= Date(timeIntervalSince1970: 1_577_836_800),
              date <= now.addingTimeInterval(86_400) else { return nil }
        return date
    }
}
