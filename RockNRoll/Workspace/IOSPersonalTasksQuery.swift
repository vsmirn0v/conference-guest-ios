import Foundation

enum IOSTaskGrouping: String, CaseIterable {
    case list, byMeeting
}

enum IOSTaskAssigneeFilter: Hashable {
    case all, unassigned, person(String)
}

struct IOSTaskAssigneeOption: Identifiable {
    var id: String { key }
    let key: String
    let name: String
}

struct IOSTaskMeetingGroup: Identifiable {
    var id: UUID { sessionID }
    let sessionID: UUID
    let title: String
    let date: Date?
    let tasks: [IOSMeetingTaskItem]
}

enum IOSPersonalTasksQuery {
    static func assignees(in tasks: [IOSMeetingTaskItem]) -> (people: [IOSTaskAssigneeOption], hasUnassigned: Bool) {
        var people: [String: String] = [:]
        var hasUnassigned = false
        for task in tasks {
            let name = IOSTaskProfile.cleanedAlias(task.owner)
            if name.isEmpty {
                hasUnassigned = true
            } else {
                let key = IOSTaskProfile.normalized(name)
                if people[key] == nil { people[key] = name }
            }
        }
        return (people.map { IOSTaskAssigneeOption(key: $0.key, name: $0.value) }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }, hasUnassigned)
    }

    static func tasks(_ tasks: [IOSMeetingTaskItem], sessions: [IOSMeetingSessionItem],
                      archiveDates: [UUID: Date], filter: IOSTaskFilter, calendar: Calendar,
                      search: String = "", assignee: IOSTaskAssigneeFilter = .all) -> [IOSMeetingTaskItem] {
        let meetings = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let needle = folded(search.trimmingCharacters(in: .whitespacesAndNewlines))
        return tasks.filter { task in
            let archived = archiveDates[task.id] != nil
            switch filter {
            case .archived: guard archived else { return false }
            case .all: guard !archived else { return false }
            case .open: guard !archived && !task.done else { return false }
            case .done: guard !archived && task.done else { return false }
            }
            switch assignee {
            case .all: break
            case .unassigned: guard IOSTaskProfile.cleanedAlias(task.owner).isEmpty else { return false }
            case .person(let key): guard IOSTaskProfile.normalized(task.owner) == key else { return false }
            }
            return needle.isEmpty || [
                task.text,
                task.owner,
                meetings[task.sessionID]?.title ?? "",
                task.extended.contextNotes,
                task.extended.workflowStatus.localizedTitle,
                task.extended.issueKind.localizedTitle,
                task.extended.parentEpicKey ?? "",
                task.extended.externalBindings.compactMap { $0.externalKey ?? $0.externalID }.joined(separator: " ")
            ].contains { folded($0).contains(needle) }
        }.sorted { lhs, rhs in
            if lhs.done != rhs.done { return !lhs.done }
            let lhsMeeting = meetings[lhs.sessionID]?.startedAt ?? .distantPast
            let rhsMeeting = meetings[rhs.sessionID]?.startedAt ?? .distantPast
            if lhs.done {
                let l = lhs.completedAt ?? lhsMeeting
                let r = rhs.completedAt ?? rhsMeeting
                if l != r { return l > r }
            } else {
                let l = lhs.deadline(calendar: calendar) ?? .distantFuture
                let r = rhs.deadline(calendar: calendar) ?? .distantFuture
                if l != r { return l < r }
                if lhsMeeting != rhsMeeting { return lhsMeeting > rhsMeeting }
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func groupedByMeeting(_ tasks: [IOSMeetingTaskItem], sessions: [IOSMeetingSessionItem]) -> [IOSTaskMeetingGroup] {
        let meetings = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(grouping: tasks, by: \.sessionID).map { sessionID, tasks in
            IOSTaskMeetingGroup(sessionID: sessionID, title: meetings[sessionID]?.title ?? "",
                                date: meetings[sessionID]?.startedAt, tasks: tasks)
        }.sorted { lhs, rhs in
            let l = lhs.date ?? .distantPast
            let r = rhs.date ?? .distantPast
            if l != r { return l > r }
            let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

extension IOSTaskProfile {
    func editingConfirmedNames(name: String, aliases: String) -> Self {
        var result = self
        result.aliases = Self.confirmedAliases(name + "\n" + aliases)
        return result
    }
}

extension IOSMeetingTaskItem {
    private func dueDayDate(calendar: Calendar) -> Date? {
        guard let dueDay else { return nil }
        let parts = dueDay.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]), year > 0,
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        guard components.isValidDate(in: gregorian) else { return nil }
        return gregorian.date(from: components)
    }

    func hasDayDeadline(calendar: Calendar) -> Bool { dueDayDate(calendar: calendar) != nil }

    func dateForDisplay(calendar: Calendar) -> Date? { dueDayDate(calendar: calendar) ?? dueAt }

    func deadline(calendar: Calendar) -> Date? {
        guard let date = dueDayDate(calendar: calendar) else { return dueAt }
        return calendar.dateInterval(of: .day, for: date)?.end
    }

    /// Apply just the edited fields to the latest snapshot, retaining sync changes
    /// that arrived while the sheet was open.
    func applyingEdits(from baseline: Self, text: String, owner: String) -> Self {
        var result = self
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseline.text != cleanText { result.text = cleanText }
        if baseline.owner != cleanOwner {
            result.owner = cleanOwner
            result.assigneeID = nil
            result.reminderAt = nil
        }
        result.updatedAt = Date()
        return result
    }
}
