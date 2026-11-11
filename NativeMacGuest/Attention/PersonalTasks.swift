import Foundation

struct PersonalTaskProfile: Codable, Equatable, Sendable {
    var id: String
    var assigneeID: String?
    var aliases: [String] = []

    var isConfigured: Bool { assigneeID != nil || !aliases.isEmpty }

    static func normalized(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    func owns(_ task: MeetingOutcomeTask) -> Bool {
        if let assignment = task.assigneeID, !assignment.isEmpty {
            return assignment == assigneeID
        }
        let owner = Self.normalized(task.owner)
        return !owner.isEmpty && aliases.contains { Self.normalized($0) == owner }
    }

    static func confirmedAliases(_ lines: String) -> [String] {
        var seen: Set<String> = []
        return lines.split(whereSeparator: \.isNewline).map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }.filter { !$0.isEmpty && seen.insert(normalized($0)).inserted }
    }
}

enum PersonalTaskFilter: String, CaseIterable {
    case all, open, completed
}

struct PersonalTaskRow: Identifiable, Equatable, Sendable {
    var id: UUID { task.id }
    var outcomeID: UUID
    var sessionID: UUID
    var title: String
    var meetingDate: Date?
    var task: MeetingOutcomeTask
    var archivedAt: Date?
}

enum PersonalTaskQuery {
    static func archived(_ task: MeetingOutcomeTask, profile: PersonalTaskProfile, dates: [UUID: Date]) -> Date? {
        profile.owns(task) ? dates[task.id] : nil
    }

    static func rows(_ rows: [PersonalTaskRow], filter: PersonalTaskFilter,
                     calendar: Calendar, archive: Bool = false) -> [PersonalTaskRow] {
        rows.filter { row in
            if archive { return row.archivedAt != nil }
            guard row.archivedAt == nil else { return false }
            return filter == .all || (filter == .completed) == row.task.done
        }.sorted { left, right in
            if left.task.done != right.task.done { return !left.task.done }
            if left.task.done {
                let l = left.task.completedAt ?? left.meetingDate ?? .distantPast
                let r = right.task.completedAt ?? right.meetingDate ?? .distantPast
                if l != r { return l > r }
            } else {
                let l = left.task.deadline(calendar: calendar) ?? .distantFuture
                let r = right.task.deadline(calendar: calendar) ?? .distantFuture
                if l != r { return l < r }
                if left.meetingDate != right.meetingDate {
                    return (left.meetingDate ?? .distantPast) > (right.meetingDate ?? .distantPast)
                }
            }
            return left.id.uuidString < right.id.uuidString
        }
    }
}

extension MeetingOutcomeTask {
    static func dayComponents(_ value: String) -> DateComponents? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              year > 0, (1...12).contains(month), (1...31).contains(day) else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        return components.isValidDate(in: Calendar(identifier: .gregorian)) ? components : nil
    }

    func dateForDisplay(calendar: Calendar) -> Date? {
        guard let dueDay, let components = Self.dayComponents(dueDay) else { return dueAt }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian.date(from: components)
    }

    /// Historical dueAt values retain their exact instant, including midnight.
    func deadline(calendar: Calendar) -> Date? {
        guard dueDay != nil, let day = dateForDisplay(calendar: calendar) else { return dueAt }
        return calendar.dateInterval(of: .day, for: day)?.end
    }
}

extension MeetingOutcome {
    /// Applies only the changes made by an outcome editor to the latest stored
    /// snapshot. Task actions may have committed after that editor rendered.
    func applyingEdits(from baseline: MeetingOutcome, to edited: MeetingOutcome) -> MeetingOutcome {
        var result = self
        if baseline.summary != edited.summary { result.summary = edited.summary }
        if baseline.decisions != edited.decisions { result.decisions = edited.decisions }
        if baseline.openQuestions != edited.openQuestions { result.openQuestions = edited.openQuestions }
        if baseline.taskReviewCandidates != edited.taskReviewCandidates {
            result.taskReviewCandidates = edited.taskReviewCandidates
        }
        if baseline.taskReviewMatches != edited.taskReviewMatches { result.taskReviewMatches = edited.taskReviewMatches }

        let originalTasks = Dictionary(uniqueKeysWithValues: baseline.tasks.map { ($0.id, $0) })
        let editedTasks = Dictionary(uniqueKeysWithValues: edited.tasks.map { ($0.id, $0) })
        result.tasks = tasks.compactMap { task in
            guard let original = originalTasks[task.id] else { return task }
            guard let updated = editedTasks[task.id] else { return nil }
            return task.applyingEdits(from: original, to: updated)
        }
        let resultIDs = Set(result.tasks.map(\.id))
        result.tasks += edited.tasks.filter { originalTasks[$0.id] == nil && !resultIDs.contains($0.id) }
        return result
    }
}

struct MeetingOutcomeEdit: Identifiable, Sendable {
    let id = UUID()
    let baseline: MeetingOutcome?
    let edited: MeetingOutcome

    func apply(to outcome: MeetingOutcome) -> MeetingOutcome {
        guard let baseline else { return edited }
        return outcome.applyingEdits(from: baseline, to: edited)
    }
}

private extension MeetingOutcomeTask {
    func applyingEdits(from baseline: Self, to edited: Self) -> Self {
        var result = self
        if baseline.text != edited.text { result.text = edited.text }
        if baseline.owner != edited.owner { result.owner = edited.owner }
        if baseline.assigneeID != edited.assigneeID { result.assigneeID = edited.assigneeID }
        if baseline.done != edited.done {
            result.done = edited.done
            result.completedAt = edited.completedAt
        }
        if baseline.dueAt != edited.dueAt { result.dueAt = edited.dueAt }
        if baseline.dueDay != edited.dueDay { result.dueDay = edited.dueDay }
        if baseline.reminderAt != edited.reminderAt { result.reminderAt = edited.reminderAt }
        if result.done { result.reminderAt = nil }
        return result
    }
}
