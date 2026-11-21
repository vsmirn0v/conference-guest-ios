import Foundation

struct PersonalTaskProfile: Codable, Equatable, Sendable {
    var id: String
    var assigneeID: String?
    var aliases: [String] = []

    var isConfigured: Bool { assigneeID != nil || !aliases.isEmpty }

    static func cleanedAlias(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func normalized(_ name: String) -> String {
        cleanedAlias(name)
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    @discardableResult
    mutating func appendAliasIfMissing(_ name: String) -> Bool {
        let cleaned = Self.cleanedAlias(name)
        guard !cleaned.isEmpty else { return false }
        let key = Self.normalized(cleaned)
        guard !aliases.contains(where: { Self.normalized($0) == key }) else { return false }
        aliases.append(cleaned)
        return true
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

enum PersonalTaskGrouping: String, CaseIterable {
    case list, byMeeting
}

enum PersonalTaskAssigneeFilter: Equatable, Hashable, Sendable {
    case all
    case unassigned
    case person(String)
}

struct PersonalTaskAssigneeOption: Identifiable, Equatable, Sendable {
    let key: String
    let displayName: String
    var id: String { key }
}

struct PersonalTaskMeetingGroup: Identifiable, Equatable, Sendable {
    var id: UUID { sessionID }
    let sessionID: UUID
    let title: String
    let meetingDate: Date?
    let rows: [PersonalTaskRow]
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

    private static func searchFolded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func assignees(in rows: [PersonalTaskRow]) -> (people: [PersonalTaskAssigneeOption], hasUnassigned: Bool) {
        var peopleByKey: [String: String] = [:]
        var hasUnassigned = false
        for row in rows where row.archivedAt == nil {
            let cleaned = PersonalTaskProfile.cleanedAlias(row.task.owner)
            if cleaned.isEmpty {
                hasUnassigned = true
            } else {
                let key = PersonalTaskProfile.normalized(cleaned)
                if peopleByKey[key] == nil {
                    peopleByKey[key] = cleaned
                }
            }
        }
        let people = peopleByKey
            .map { PersonalTaskAssigneeOption(key: $0.key, displayName: $0.value) }
            .sorted {
                let cmp = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                return cmp == .orderedSame ? $0.key < $1.key : cmp == .orderedAscending
            }
        return (people, hasUnassigned)
    }

    static func rows(_ rows: [PersonalTaskRow], filter: PersonalTaskFilter,
                     calendar: Calendar, archive: Bool = false,
                     search: String = "",
                     assignee: PersonalTaskAssigneeFilter = .all) -> [PersonalTaskRow] {
        let needle = searchFolded(search.trimmingCharacters(in: .whitespacesAndNewlines))
        return rows.filter { row in
            if archive { return row.archivedAt != nil }
            guard row.archivedAt == nil else { return false }
            guard filter == .all || (filter == .completed) == row.task.done else { return false }
            switch assignee {
            case .all:
                break
            case .unassigned:
                guard PersonalTaskProfile.cleanedAlias(row.task.owner).isEmpty else { return false }
            case .person(let key):
                guard PersonalTaskProfile.normalized(row.task.owner) == key else { return false }
            }
            if !needle.isEmpty {
                let matches = searchFolded(row.task.text).contains(needle)
                    || searchFolded(row.task.owner).contains(needle)
                    || searchFolded(row.title).contains(needle)
                    || searchFolded(row.task.extended.contextNotes).contains(needle)
                    || searchFolded(row.task.extended.workflowStatus.localizedTitle).contains(needle)
                    || searchFolded(row.task.extended.issueKind.localizedTitle).contains(needle)
                    || searchFolded(row.task.extended.parentEpicKey ?? "").contains(needle)
                    || row.task.extended.externalBindings.contains { binding in
                        searchFolded(binding.externalKey ?? binding.externalID).contains(needle)
                    }
                guard matches else { return false }
            }
            return true
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

    static func groupedByMeeting(_ sortedRows: [PersonalTaskRow]) -> [PersonalTaskMeetingGroup] {
        var grouped: [UUID: (title: String, meetingDate: Date?, rows: [PersonalTaskRow])] = [:]
        for row in sortedRows {
            if var entry = grouped[row.sessionID] {
                if entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !row.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    entry.title = row.title
                }
                if let date = row.meetingDate, entry.meetingDate.map({ date > $0 }) ?? true {
                    entry.meetingDate = date
                }
                entry.rows.append(row)
                grouped[row.sessionID] = entry
            } else {
                grouped[row.sessionID] = (row.title, row.meetingDate, [row])
            }
        }
        return grouped.map { sessionID, entry in
            PersonalTaskMeetingGroup(
                sessionID: sessionID,
                title: entry.title,
                meetingDate: entry.meetingDate,
                rows: entry.rows
            )
        }.sorted { lhs, rhs in
            let lDate = lhs.meetingDate ?? .distantPast
            let rDate = rhs.meetingDate ?? .distantPast
            if lDate != rDate { return lDate > rDate }
            let cmp = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return lhs.sessionID.uuidString < rhs.sessionID.uuidString
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
        if baseline.extended != edited.extended { result.extended = edited.extended }
        if result.done { result.reminderAt = nil }
        result.extended.applyDoneFlag(result.done)
        return result
    }
}
