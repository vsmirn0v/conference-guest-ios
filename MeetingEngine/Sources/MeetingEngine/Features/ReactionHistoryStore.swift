import Combine
import ConferenceCore
import Foundation

public struct MeetingReactionEvent: Equatable, Identifiable, Sendable {
    /// An acknowledgement confirms an exact service echo, not delivery to peers.
    public enum Delivery: Equatable, Sendable { case submitted, acknowledged, failed }

    public let id: String
    public let meetingID: UUID
    public let sequence: Int
    fileprivate let continuity: Int
    public let kind: MeetingReaction
    public let participantID: String
    public private(set) var displayName: String?
    public let isOwn: Bool
    public let receivedAt: Date
    public private(set) var providerTimestamp: Date?
    public private(set) var providerEventID: String?
    public let localSubmissionID: String?
    public fileprivate(set) var delivery: Delivery?
    public fileprivate(set) var isSeen: Bool

    // An echo must not move a locally submitted row to a different time.
    public var timestamp: Date { isOwn ? receivedAt : providerTimestamp ?? receivedAt }

    fileprivate mutating func resolveName(_ name: String) {
        if displayName == nil { displayName = name }
    }
    fileprivate mutating func acknowledge(eventID: String?, timestamp: Date?) {
        delivery = .acknowledged
        providerEventID = eventID ?? providerEventID
        providerTimestamp = timestamp ?? providerTimestamp
    }
}

public struct ReactionHistoryGap: Equatable, Identifiable, Sendable {
    public let id: String
    public let start: Date
    public fileprivate(set) var end: Date?
    public init(id: String, start: Date, end: Date? = nil) {
        self.id = id; self.start = start; self.end = end
    }
}

public struct ReactionHistoryGroup: Equatable, Identifiable, Sendable {
    public let events: [MeetingReactionEvent]
    public init(events: [MeetingReactionEvent]) { self.events = events }
    public var id: String { events[0].id }
    public var start: Date { events[0].timestamp }
    public var end: Date { events[events.count - 1].timestamp }
    public var sequence: Int { events[0].sequence }
    public var participantCount: Int { Set(events.map(\.participantID)).count }
    public var unseenCount: Int { events.filter { !$0.isSeen && !$0.isOwn }.count }
    public var hasUnseenReactions: Bool { unseenCount > 0 }
    public var reactionCounts: [MeetingReaction: Int] {
        events.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 }
    }
}

/// Memory belongs to one local meeting, independently of its views and transports.
/// Providers must select one authoritative receive path when events have no IDs.
@MainActor
public final class ReactionHistoryStore: ObservableObject {
    @Published public private(set) var events: [MeetingReactionEvent] = []
    @Published public private(set) var gaps: [ReactionHistoryGap] = []
    @Published public private(set) var hasUnseenReactions = false
    @Published public private(set) var hasTruncatedHistory = false
    @Published public private(set) var hasTruncatedGapDetails = false
    public private(set) var meetingID: UUID?
    public var isReadingLatest = false

    private struct Identity: Hashable {
        enum Source: Hashable { case provider, local }
        let source: Source
        let participantID: String
        let value: String
    }
    private let maximumEvents: Int
    private let maximumIdentities: Int
    private let maximumGaps: Int
    private let clock: () -> Date
    private var nextSequence = 0
    private var continuity = 0
    private var identities = Set<Identity>()
    private var identityOrder: [Identity] = []
    #if DEBUG
    public var retainedIdentityCount: Int { identities.count }
    #endif

    public init(maximumEvents: Int = 2_000, maximumIdentityCount: Int = 8_000,
         maximumGaps: Int = 128, clock: @escaping () -> Date = Date.init) {
        self.maximumEvents = max(1, maximumEvents)
        maximumIdentities = max(1, maximumIdentityCount)
        self.maximumGaps = max(1, maximumGaps)
        self.clock = clock
    }

    /// Rebinding the same meeting preserves history through a reconnect/UI rebuild.
    public func beginMeeting(id: UUID = UUID()) {
        guard meetingID != id else { return }
        clear()
        meetingID = id
    }

    public func endMeeting() {
        clear()
        meetingID = nil
    }

    @discardableResult
    public func receive(kind: MeetingReaction, participantID: String, displayName: String?,
                 isOwn: Bool = false, providerEventID: String? = nil,
                 providerTimestamp: Date? = nil, receivedAt: Date? = nil,
                 matchingLocalSubmissionID: String? = nil,
                 expectedMeetingID: UUID? = nil) -> MeetingReactionEvent? {
        let time = receivedAt ?? clock()
        guard accepts(expectedMeetingID), valid(participantID), finite(time),
              providerEventID.map(valid) ?? true else { return nil }
        let providerTime = providerTimestamp.flatMap { finite($0) ? $0 : nil }
        if let providerEventID {
            let identity = Identity(source: .provider, participantID: participantID, value: providerEventID)
            guard !identities.contains(identity),
                  !events.contains(where: { $0.participantID == participantID && $0.providerEventID == providerEventID }) else { return nil }
            remember(identity)
        }
        if isOwn {
            // No timestamp/kind matching: a second deliberate tap is a new event.
            if let submissionID = matchingLocalSubmissionID,
               let index = events.firstIndex(where: {
                   $0.isOwn && $0.localSubmissionID == submissionID &&
                   $0.participantID == participantID && $0.kind == kind
               }) {
                events[index].acknowledge(eventID: providerEventID, timestamp: providerTime)
            }
            return nil
        }
        return append(kind: kind, participantID: participantID, displayName: displayName,
                      isOwn: false, time: time, providerTimestamp: providerTime,
                      providerEventID: providerEventID, submissionID: nil)
    }

    /// Call only after the existing send gate and transport accept a submission.
    @discardableResult
    public func recordLocalSubmission(kind: MeetingReaction, participantID: String, displayName: String?,
                               submissionID: String = UUID().uuidString, at: Date? = nil,
                               expectedMeetingID: UUID? = nil) -> MeetingReactionEvent? {
        let time = at ?? clock()
        guard accepts(expectedMeetingID), valid(participantID), valid(submissionID), finite(time) else { return nil }
        let identity = Identity(source: .local, participantID: "", value: submissionID)
        guard !identities.contains(identity),
              !events.contains(where: { $0.localSubmissionID == submissionID }) else { return nil }
        remember(identity)
        return append(kind: kind, participantID: participantID, displayName: displayName,
                      isOwn: true, time: time, providerTimestamp: nil,
                      providerEventID: nil, submissionID: submissionID)
    }

    public func setLocalDelivery(_ delivery: MeetingReactionEvent.Delivery, submissionID: String,
                          expectedMeetingID: UUID? = nil) {
        guard accepts(expectedMeetingID),
              let index = events.firstIndex(where: { $0.localSubmissionID == submissionID }),
              events[index].delivery != .acknowledged,
              events[index].delivery != delivery else { return }
        // A delayed submission callback cannot resurrect an already failed send.
        guard delivery != .submitted else { return }
        events[index].delivery = delivery
    }

    /// Fill an absent snapshot by exact identity; never rewrite a captured name.
    public func resolveUnknownParticipant(id: String, name: String, expectedMeetingID: UUID? = nil) {
        guard accepts(expectedMeetingID), let name = snapshotName(name) else { return }
        var resolved = events
        for index in resolved.indices where resolved[index].participantID == id {
            resolved[index].resolveName(name)
        }
        if resolved != events { events = resolved }
    }

    /// The presentation supplies IDs that were actually visible in the foreground.
    public func markSeen(ids: [String]) {
        guard !ids.isEmpty else { return }
        let visible = Set(ids)
        let changed = events.indices.filter { !events[$0].isSeen && visible.contains(events[$0].id) }
        guard !changed.isEmpty else { return }
        var updated = events
        for index in changed {
            updated[index].isSeen = true
        }
        events = updated; updateUnseen()
    }

    public func beginGap(at: Date? = nil) {
        let time = at ?? clock()
        guard meetingID != nil, finite(time), gaps.last?.end != nil || gaps.isEmpty else { return }
        continuity += 1
        gaps.append(.init(id: UUID().uuidString, start: time, end: nil))
        if gaps.count > maximumGaps {
            gaps.removeFirst(gaps.count - maximumGaps)
            hasTruncatedGapDetails = true
        }
    }

    public func endGap(at: Date? = nil) {
        let time = at ?? clock()
        guard meetingID != nil, finite(time), let index = gaps.indices.last, gaps[index].end == nil else { return }
        continuity += 1
        gaps[index].end = max(gaps[index].start, time)
    }

    /// Union only overlapping/touching intervals. Never label healthy time as an outage.
    /// Raw boundaries still split reaction groups independently of this presentation.
    public var interruptionIntervals: [ReactionHistoryGap] {
        var result: [ReactionHistoryGap] = []
        for gap in gaps.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, last.end.map({ gap.start <= $0 }) ?? true {
                result[result.count - 1].end = last.end.flatMap { end in gap.end.map { max(end, $0) } }
            } else { result.append(gap) }
        }
        return result
    }

    /// Receipt order is authoritative when the provider supplies no event sequence.
    /// A timestamp tie with a chat boundary is split conservatively.
    public func projection(chatBoundaries: [Date] = []) -> [ReactionHistoryGroup] {
        let boundaries = chatBoundaries.filter(finite).sorted()
        func hasChatBoundary(from start: Date, through end: Date) -> Bool {
            guard start <= end else { return false }
            var lower = 0, upper = boundaries.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if boundaries[middle] < start { lower = middle + 1 }
                else { upper = middle }
            }
            return lower < boundaries.count && boundaries[lower] <= end
        }
        var groups: [ReactionHistoryGroup] = []
        var current: [MeetingReactionEvent] = []
        for event in events {
            if let first = current.first, let previous = current.last {
                let interval = event.receivedAt.timeIntervalSince(previous.receivedAt)
                let span = event.receivedAt.timeIntervalSince(first.receivedAt)
                let displayInterval = event.timestamp.timeIntervalSince(previous.timestamp)
                let displaySpan = event.timestamp.timeIntervalSince(first.timestamp)
                let crossesChat = hasChatBoundary(from: previous.timestamp, through: event.timestamp)
                let crossesGap = previous.continuity != event.continuity
                if interval < 0 || interval > 5 || span > 10 || displayInterval < 0 ||
                    displayInterval > 5 || displaySpan > 10 || crossesChat || crossesGap {
                    groups.append(.init(events: current)); current = []
                }
            }
            current.append(event)
        }
        if !current.isEmpty { groups.append(.init(events: current)) }
        return groups
    }

    private func append(kind: MeetingReaction, participantID: String, displayName: String?,
                        isOwn: Bool, time: Date, providerTimestamp: Date?, providerEventID: String?,
                        submissionID: String?) -> MeetingReactionEvent? {
        guard let meetingID else { return nil }
        let event = MeetingReactionEvent(id: UUID().uuidString, meetingID: meetingID,
            sequence: nextSequence, continuity: continuity, kind: kind, participantID: participantID,
            displayName: snapshotName(displayName), isOwn: isOwn, receivedAt: time,
            providerTimestamp: providerTimestamp, providerEventID: providerEventID,
            localSubmissionID: submissionID, delivery: isOwn ? .submitted : nil, isSeen: isOwn)
        nextSequence += 1
        events.append(event)
        if events.count > maximumEvents {
            events.removeFirst(events.count - maximumEvents)
            hasTruncatedHistory = true
        }
        updateUnseen()
        return event
    }

    private func remember(_ identity: Identity) {
        guard identities.insert(identity).inserted else { return }
        identityOrder.append(identity)
        if identityOrder.count > maximumIdentities {
            let removed = identityOrder.count - maximumIdentities
            identityOrder.prefix(removed).forEach { identities.remove($0) }
            identityOrder.removeFirst(removed)
            hasTruncatedHistory = true
        }
    }

    private func accepts(_ expected: UUID?) -> Bool {
        meetingID != nil && (expected == nil || expected == meetingID)
    }
    private func valid(_ id: String) -> Bool { !id.isEmpty && id.utf8.count <= 1_024 }
    private func finite(_ date: Date) -> Bool { date.timeIntervalSinceReferenceDate.isFinite }
    private func snapshotName(_ name: String?) -> String? {
        guard let name, name.utf8.count <= 1_024,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return name
    }
    private func updateUnseen() {
        let value = events.contains { !$0.isOwn && !$0.isSeen }
        if hasUnseenReactions != value { hasUnseenReactions = value }
    }
    private func clear() {
        events = []; gaps = []; identities = []; identityOrder = []
        nextSequence = 0; continuity = 0; hasUnseenReactions = false; hasTruncatedHistory = false
        hasTruncatedGapDetails = false
        isReadingLatest = false
    }
}
