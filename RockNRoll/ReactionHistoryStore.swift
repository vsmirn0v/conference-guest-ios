import Combine
import ConferenceCore
import Foundation

struct MeetingReactionEvent: Equatable, Identifiable, Sendable {
    /// An acknowledgement confirms an exact service echo, not delivery to peers.
    enum Delivery: Equatable, Sendable { case submitted, acknowledged, failed }

    let id: String
    let meetingID: UUID
    let sequence: Int
    fileprivate let continuity: Int
    let kind: MeetingReaction
    let participantID: String
    private(set) var displayName: String?
    let isOwn: Bool
    let receivedAt: Date
    private(set) var providerTimestamp: Date?
    private(set) var providerEventID: String?
    let localSubmissionID: String?
    fileprivate(set) var delivery: Delivery?
    fileprivate(set) var isSeen: Bool

    // An echo must not move a locally submitted row to a different time.
    var timestamp: Date { isOwn ? receivedAt : providerTimestamp ?? receivedAt }

    fileprivate mutating func resolveName(_ name: String) {
        if displayName == nil { displayName = name }
    }
    fileprivate mutating func acknowledge(eventID: String?, timestamp: Date?) {
        delivery = .acknowledged
        providerEventID = eventID ?? providerEventID
        providerTimestamp = timestamp ?? providerTimestamp
    }
}

struct ReactionHistoryGap: Equatable, Identifiable, Sendable {
    let id: String
    let start: Date
    fileprivate(set) var end: Date?
}

struct ReactionHistoryGroup: Equatable, Identifiable, Sendable {
    let events: [MeetingReactionEvent]
    var id: String { events[0].id }
    var start: Date { events[0].timestamp }
    var end: Date { events[events.count - 1].timestamp }
    var sequence: Int { events[0].sequence }
    var participantCount: Int { Set(events.map(\.participantID)).count }
    var unseenCount: Int { events.filter { !$0.isSeen && !$0.isOwn }.count }
    var hasUnseenReactions: Bool { unseenCount > 0 }
    var reactionCounts: [MeetingReaction: Int] {
        events.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 }
    }
}

/// Memory belongs to one local meeting, independently of its views and transports.
/// Providers must select one authoritative receive path when events have no IDs.
@MainActor
final class ReactionHistoryStore: ObservableObject {
    @Published private(set) var events: [MeetingReactionEvent] = []
    @Published private(set) var gaps: [ReactionHistoryGap] = []
    @Published private(set) var hasUnseenReactions = false
    @Published private(set) var hasTruncatedHistory = false
    private(set) var meetingID: UUID?
    var isReadingLatest = false

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
    var retainedIdentityCount: Int { identities.count }

    init(maximumEvents: Int = 2_000, maximumIdentityCount: Int = 8_000,
         maximumGaps: Int = 128, clock: @escaping () -> Date = Date.init) {
        self.maximumEvents = max(1, maximumEvents)
        maximumIdentities = max(1, maximumIdentityCount)
        self.maximumGaps = max(1, maximumGaps)
        self.clock = clock
    }

    /// Rebinding the same meeting preserves history through a reconnect/UI rebuild.
    func beginMeeting(id: UUID = UUID()) {
        guard meetingID != id else { return }
        clear()
        meetingID = id
    }

    func endMeeting() {
        clear()
        meetingID = nil
    }

    @discardableResult
    func receive(kind: MeetingReaction, participantID: String, displayName: String?,
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
    func recordLocalSubmission(kind: MeetingReaction, participantID: String, displayName: String?,
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

    func setLocalDelivery(_ delivery: MeetingReactionEvent.Delivery, submissionID: String,
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
    func resolveUnknownParticipant(id: String, name: String, expectedMeetingID: UUID? = nil) {
        guard accepts(expectedMeetingID), let name = snapshotName(name) else { return }
        var resolved = events
        for index in resolved.indices where resolved[index].participantID == id {
            resolved[index].resolveName(name)
        }
        if resolved != events { events = resolved }
    }

    /// The presentation supplies IDs that were actually visible in the foreground.
    func markSeen(ids: [String]) {
        let visible = Set(ids)
        var updated = events
        for index in updated.indices where visible.contains(updated[index].id) {
            updated[index].isSeen = true
        }
        if updated != events { events = updated; updateUnseen() }
    }

    func beginGap(at: Date? = nil) {
        let time = at ?? clock()
        guard meetingID != nil, finite(time), gaps.last?.end != nil || gaps.isEmpty else { return }
        continuity += 1
        gaps.append(.init(id: UUID().uuidString, start: time, end: nil))
        if gaps.count > maximumGaps {
            gaps.removeFirst(gaps.count - maximumGaps)
            hasTruncatedHistory = true
        }
    }

    func endGap(at: Date? = nil) {
        let time = at ?? clock()
        guard meetingID != nil, finite(time), let index = gaps.indices.last, gaps[index].end == nil else { return }
        continuity += 1
        gaps[index].end = max(gaps[index].start, time)
    }

    /// Receipt order is authoritative when the provider supplies no event sequence.
    /// A timestamp tie with a chat boundary is split conservatively.
    func projection(chatBoundaries: [Date] = []) -> [ReactionHistoryGroup] {
        let boundaries = chatBoundaries.filter(finite).sorted()
        var groups: [ReactionHistoryGroup] = []
        var current: [MeetingReactionEvent] = []
        for event in events {
            if let first = current.first, let previous = current.last {
                let interval = event.receivedAt.timeIntervalSince(previous.receivedAt)
                let span = event.receivedAt.timeIntervalSince(first.receivedAt)
                let displayInterval = event.timestamp.timeIntervalSince(previous.timestamp)
                let displaySpan = event.timestamp.timeIntervalSince(first.timestamp)
                let crossesChat = boundaries.contains { previous.timestamp <= $0 && $0 <= event.timestamp }
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
        isReadingLatest = false
    }
}
