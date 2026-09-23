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

    private var activeReasons = Set<MissedReason>()
    private var segmentsByID: [String: TranscriptSegment] = [:]

    public init() {}

    public var unreadCount: Int {
        max(0, intervals.count - lastReviewedCount)
    }

    public mutating func begin(_ reason: MissedReason, at time: Date = Date()) {
        guard activeReasons.insert(reason).inserted else { return }
        if activeReasons.count == 1 {
            intervals.append(MissedInterval(id: UUID(), start: time, end: nil, reasons: [reason]))
            if intervals.count > 100 {
                intervals.removeFirst()
                lastReviewedCount = max(0, lastReviewedCount - 1)
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
        lastReviewedCount = intervals.filter { $0.end != nil }.count
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
