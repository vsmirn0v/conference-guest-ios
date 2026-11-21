import Foundation

public struct WorkspaceTaskRecord: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var outcomeID: UUID
    public var meetingTitle: String
    public var meetingDate: Date?
    public var text: String
    public var owner: String
    public var assigneeID: String?
    public var dueDay: String?
    public var dueAt: Date?
    public var reminderAt: Date?
    public var done: Bool
    public var completedAt: Date?
    public var archivedAt: Date?
    public var updatedAt: Date
    public var isOwnedByCurrentUser: Bool
    public var extended: TaskExtendedMetadata

    public init(
        id: UUID,
        sessionID: UUID,
        outcomeID: UUID,
        meetingTitle: String,
        meetingDate: Date? = nil,
        text: String,
        owner: String = "",
        assigneeID: String? = nil,
        dueDay: String? = nil,
        dueAt: Date? = nil,
        reminderAt: Date? = nil,
        done: Bool = false,
        completedAt: Date? = nil,
        archivedAt: Date? = nil,
        updatedAt: Date = Date(),
        isOwnedByCurrentUser: Bool = false,
        extended: TaskExtendedMetadata = .init()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.outcomeID = outcomeID
        self.meetingTitle = meetingTitle
        self.meetingDate = meetingDate
        self.text = text
        self.owner = owner
        self.assigneeID = assigneeID
        self.dueDay = dueDay
        self.dueAt = dueAt
        self.reminderAt = reminderAt
        self.done = done
        self.completedAt = completedAt
        self.archivedAt = archivedAt
        self.updatedAt = updatedAt
        self.isOwnedByCurrentUser = isOwnedByCurrentUser
        self.extended = extended
    }

    public var syncDigest: String {
        let historyCount = extended.contextHistory.count
        let parts = [
            text.trimmingCharacters(in: .whitespacesAndNewlines),
            owner.trimmingCharacters(in: .whitespacesAndNewlines),
            dueDay ?? "",
            String(done),
            extended.workflowStatus.rawValue,
            extended.priority?.rawValue ?? "",
            extended.issueKind.rawValue,
            extended.parentEpicKey ?? "",
            extended.reminderRule?.summaryLabel() ?? "",
            reminderAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "",
            extended.contextNotes.trimmingCharacters(in: .whitespacesAndNewlines),
            String(historyCount)
        ]
        return MeetingWorkspaceSyncDocument.digest(parts.joined(separator: "\u{1F}"))
    }

    public func renderedExternalNotes() -> String {
        var blocks: [String] = []
        if extended.issueKind != .task {
            blocks.append("\(L("Type")): \(extended.issueKind.localizedTitle)")
        }
        if let epicKey = extended.parentEpicKey, !epicKey.isEmpty {
            let epicLabel = extended.parentEpicTitle.map { "\(epicKey) (\($0))" } ?? epicKey
            blocks.append("\(L("Epic")): \(epicLabel)")
        }
        if !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append("\(L("Owner")): \(owner)")
        }
        let originTitle = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !originTitle.isEmpty {
            if let meetingDate {
                blocks.append("\(L("Meeting")): \(originTitle) (\(meetingDate.formatted(date: .abbreviated, time: .omitted)))")
            } else {
                blocks.append("\(L("Meeting")): \(originTitle)")
            }
        }
        blocks.append("\(L("Status")): \(extended.workflowStatus.localizedTitle)")

        if let rule = extended.reminderRule, rule.isEnabled {
            blocks.append("\(L("Reminder Rule")): \(rule.summaryLabel())")
        }

        if !extended.scheduledDiscussions.isEmpty {
            let lines = extended.scheduledDiscussions.prefix(4).map { meeting in
                "- \(meeting.startAt.formatted(date: .abbreviated, time: .shortened)) · \(meeting.title)"
            }.joined(separator: "\n")
            blocks.append("\(L("Scheduled Discussions")):\n\(lines)")
        }

        let cleanContext = extended.contextNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanContext.isEmpty {
            blocks.append("\(L("Context")):\n\(cleanContext)")
        }

        if !extended.contextHistory.isEmpty {
            let timeline = extended.contextHistory.suffix(6).map { entry -> String in
                let date = entry.observedAt.formatted(date: .abbreviated, time: .shortened)
                let transition = entry.updatedStatus.map { " [\($0.localizedTitle)]" } ?? ""
                return "- \(date) · \(entry.meetingTitle)\(transition): \(entry.note)"
            }.joined(separator: "\n")
            blocks.append("\(L("Meeting Timeline")):\n\(timeline)")
        }

        return String(blocks.joined(separator: "\n\n").prefix(6_000))
    }
}

public struct TaskSyncOperation: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case createExternal = "create_external"
        case updateExternal = "update_external"
        case linkExistingExternal = "link_existing_external"
        case updateLocalFromExternal = "update_local_from_external"
        case importToLocal = "import_to_local"

        public var isOutgoing: Bool {
            switch self {
            case .createExternal, .updateExternal, .linkExistingExternal: return true
            case .updateLocalFromExternal, .importToLocal: return false
            }
        }

        public var localizedBadge: String {
            switch self {
            case .createExternal: return L("Create")
            case .updateExternal: return L("Update")
            case .linkExistingExternal: return L("Link")
            case .updateLocalFromExternal: return L("Pull Update")
            case .importToLocal: return L("Import")
            }
        }
    }

    public var id: UUID
    public var isSelected: Bool
    public var provider: ExternalTaskProviderKind
    public var kind: Kind
    public var localTaskID: UUID?
    public var externalID: String?
    public var externalKey: String?
    public var projectOrList: String?
    public var title: String
    public var detailSummary: String
    public var ownerDisplay: String
    public var resolvedJiraAssignee: JiraUserContact?
    public var unmappedOwnerKey: String?
    public var targetWorkflowStatus: TaskWorkflowStatus
    public var priority: TaskPriorityLevel?
    public var issueKind: TaskIssueKind
    public var parentEpicKey: String?
    public var dueDay: String?
    public var dueAt: Date?
    public var externalDescription: String
    public var commentToPost: String?
    public var remoteIssueSnapshot: JiraRemoteIssue?
    public var remoteReminderSnapshot: ReminderItemSnapshot?

    public init(
        id: UUID = UUID(),
        isSelected: Bool = true,
        provider: ExternalTaskProviderKind,
        kind: Kind,
        localTaskID: UUID? = nil,
        externalID: String? = nil,
        externalKey: String? = nil,
        projectOrList: String? = nil,
        title: String,
        detailSummary: String = "",
        ownerDisplay: String = "",
        resolvedJiraAssignee: JiraUserContact? = nil,
        unmappedOwnerKey: String? = nil,
        targetWorkflowStatus: TaskWorkflowStatus = .todo,
        priority: TaskPriorityLevel? = nil,
        issueKind: TaskIssueKind = .task,
        parentEpicKey: String? = nil,
        dueDay: String? = nil,
        dueAt: Date? = nil,
        externalDescription: String = "",
        commentToPost: String? = nil,
        remoteIssueSnapshot: JiraRemoteIssue? = nil,
        remoteReminderSnapshot: ReminderItemSnapshot? = nil
    ) {
        self.id = id
        self.isSelected = isSelected
        self.provider = provider
        self.kind = kind
        self.localTaskID = localTaskID
        self.externalID = externalID
        self.externalKey = externalKey
        self.projectOrList = projectOrList
        self.title = title
        self.detailSummary = detailSummary
        self.ownerDisplay = ownerDisplay
        self.resolvedJiraAssignee = resolvedJiraAssignee
        self.unmappedOwnerKey = unmappedOwnerKey
        self.targetWorkflowStatus = targetWorkflowStatus
        self.priority = priority
        self.issueKind = issueKind
        self.parentEpicKey = parentEpicKey
        self.dueDay = dueDay
        self.dueAt = dueAt
        self.externalDescription = externalDescription
        self.commentToPost = commentToPost
        self.remoteIssueSnapshot = remoteIssueSnapshot
        self.remoteReminderSnapshot = remoteReminderSnapshot
    }
}

public struct TaskSyncPacket: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var operations: [TaskSyncOperation]
    public var assignableJiraUsers: [JiraUserContact]
    public var warnings: [String]
    public var discoveredMappings: [ContactIdentityMapping]
    public var relayJiraViaMac: Bool

    public var selectedCount: Int {
        operations.filter(\.isSelected).count
    }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        operations: [TaskSyncOperation],
        assignableJiraUsers: [JiraUserContact] = [],
        warnings: [String] = [],
        discoveredMappings: [ContactIdentityMapping] = [],
        relayJiraViaMac: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.operations = operations
        self.assignableJiraUsers = assignableJiraUsers
        self.warnings = warnings
        self.discoveredMappings = discoveredMappings
        self.relayJiraViaMac = relayJiraViaMac
    }
}

/// Sync packet queued from iPhone via iCloud Workspace Sync so the user's Mac can execute
/// operations against corporate/intranet Jira and sync the resulting bindings back.
public struct MacJiraHandoverPacket: Codable, Equatable, Identifiable, Sendable {
    public static let scopeKeyPrefix = "global:jiraHandover:"

    public enum Kind: String, Codable, Sendable {
        case applyOperations = "apply_operations"
        case importFromJira = "import_from_jira"
    }

    public enum Status: String, Codable, Sendable {
        case pendingMac = "pending_mac"
        case completedOnMac = "completed_on_mac"
        case failedOnMac = "failed_on_mac"
    }

    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var originDeviceName: String
    public var kind: Kind
    public var status: Status
    public var approvedByUser: Bool
    public var operations: [TaskSyncOperation]
    public var importJQL: String?
    public var summaryMessage: String?
    public var lastErrorMessage: String?

    public var scopeKey: String { Self.scopeKeyPrefix + id.uuidString }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        originDeviceName: String,
        kind: Kind,
        status: Status = .pendingMac,
        approvedByUser: Bool = true,
        operations: [TaskSyncOperation] = [],
        importJQL: String? = nil,
        summaryMessage: String? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.originDeviceName = originDeviceName
        self.kind = kind
        self.status = status
        self.approvedByUser = approvedByUser
        self.operations = operations
        self.importJQL = importJQL
        self.summaryMessage = summaryMessage
        self.lastErrorMessage = lastErrorMessage
    }

    public func encodeSyncJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decodeSyncJSON(_ raw: String) -> MacJiraHandoverPacket? {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = raw.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(MacJiraHandoverPacket.self, from: data)
    }

    public static func shouldHandOverJiraError(_ error: Error) -> Bool {
        if let jiraError = error as? JiraConnectorError {
            return jiraError == .missingCredentials
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .dnsLookupFailed, .secureConnectionFailed,
                 .serverCertificateUntrusted, .appTransportSecurityRequiresSecureConnection:
                return true
            default:
                return false
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let codes: Set<Int> = [
                NSURLErrorNotConnectedToInternet,
                NSURLErrorTimedOut,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorSecureConnectionFailed,
                NSURLErrorServerCertificateUntrusted,
                NSURLErrorAppTransportSecurityRequiresSecureConnection
            ]
            return codes.contains(nsError.code)
        }
        return false
    }
}

public struct TaskSyncLocalMutation: Sendable {
    public var existingTaskID: UUID?
    public var title: String
    public var owner: String
    public var dueDay: String?
    public var dueAt: Date?
    public var done: Bool
    public var completedAt: Date?
    public var newStatus: TaskWorkflowStatus
    public var priority: TaskPriorityLevel?
    public var issueKind: TaskIssueKind
    public var parentEpicKey: String?
    public var contextAddition: String
    public var historyEntry: TaskMeetingContextEntry
    public var binding: ExternalTaskBinding

    public init(
        existingTaskID: UUID? = nil,
        title: String,
        owner: String,
        dueDay: String? = nil,
        dueAt: Date? = nil,
        done: Bool,
        completedAt: Date? = nil,
        newStatus: TaskWorkflowStatus,
        priority: TaskPriorityLevel? = nil,
        issueKind: TaskIssueKind = .task,
        parentEpicKey: String? = nil,
        contextAddition: String,
        historyEntry: TaskMeetingContextEntry,
        binding: ExternalTaskBinding
    ) {
        self.existingTaskID = existingTaskID
        self.title = title
        self.owner = owner
        self.dueDay = dueDay
        self.dueAt = dueAt
        self.done = done
        self.completedAt = completedAt
        self.newStatus = newStatus
        self.priority = priority
        self.issueKind = issueKind
        self.parentEpicKey = parentEpicKey
        self.contextAddition = contextAddition
        self.historyEntry = historyEntry
        self.binding = binding
    }
}

public struct TaskSyncExecutionReport: Equatable, Sendable {
    public var appliedCount: Int
    public var createdCount: Int
    public var updatedCount: Int
    public var importedCount: Int
    public var failedMessages: [String]

    public init(
        appliedCount: Int = 0,
        createdCount: Int = 0,
        updatedCount: Int = 0,
        importedCount: Int = 0,
        failedMessages: [String] = []
    ) {
        self.appliedCount = appliedCount
        self.createdCount = createdCount
        self.updatedCount = updatedCount
        self.importedCount = importedCount
        self.failedMessages = failedMessages
    }
}

public enum TaskSyncPlanner {
    public static func inExportScope(
        _ task: WorkspaceTaskRecord,
        preferences: TaskSyncPreferences,
        myAliases: [String],
        explicitTaskIDs: Set<UUID>?
    ) -> Bool {
        if let explicitTaskIDs {
            return explicitTaskIDs.contains(task.id)
        }
        guard task.archivedAt == nil else { return false }
        switch preferences.effectiveScopeMode {
        case .myTasksOnly:
            return task.isOwnedByCurrentUser || JiraContactMatcher.isCurrentUserOwner(task.owner, myAliases: myAliases)
        case .selectedPeople:
            let selected = Set(preferences.selectedPersonKeys.map(JiraContactMatcher.normalizedKey))
            let ownerKey = JiraContactMatcher.normalizedKey(task.owner)
            return !ownerKey.isEmpty && selected.contains(ownerKey)
        case .selectedTasksOnly:
            // Automatic scope requires explicit selection when in selectedTasksOnly mode.
            return false
        case .allTasks:
            return true
        }
    }

    public static func inRemindersExportScope(
        _ task: WorkspaceTaskRecord,
        preferences: TaskSyncPreferences,
        myAliases: [String],
        explicitTaskIDs: Set<UUID>?
    ) -> Bool {
        if let explicitTaskIDs {
            return explicitTaskIDs.contains(task.id)
        }
        guard inExportScope(task, preferences: preferences, myAliases: myAliases, explicitTaskIDs: nil) else {
            return false
        }
        guard !preferences.reminders.onlyMyTasksInReminders else {
            return task.isOwnedByCurrentUser || JiraContactMatcher.isCurrentUserOwner(task.owner, myAliases: myAliases)
        }
        return true
    }

    public static func buildPacket(
        localTasks: [WorkspaceTaskRecord],
        jiraIssues: [JiraRemoteIssue] = [],
        jiraUsers: [JiraUserContact] = [],
        reminders: [ReminderItemSnapshot] = [],
        preferences: TaskSyncPreferences,
        myAliases: [String] = [],
        explicitTaskIDs: Set<UUID>? = nil,
        directionOverride: TaskSyncDirection? = nil,
        providerFilter: ExternalTaskProviderKind? = nil,
        now: Date = Date()
    ) -> TaskSyncPacket {
        let direction = directionOverride ?? preferences.direction
        var operations: [TaskSyncOperation] = []
        var warnings: [String] = []

        // Build/refresh contact mappings for owners present in local tasks.
        let ownerPeople: [AppContactPerson] = Dictionary(
            localTasks.compactMap { task -> (String, AppContactPerson)? in
                let cleaned = JiraContactMatcher.cleanedName(task.owner)
                guard !cleaned.isEmpty else { return nil }
                let key = JiraContactMatcher.normalizedKey(cleaned)
                return (key, AppContactPerson(key: key, displayName: cleaned, aliases: task.isOwnedByCurrentUser ? myAliases : [], isCurrentUser: task.isOwnedByCurrentUser))
            },
            uniquingKeysWith: { a, _ in a }
        ).values.sorted { $0.displayName < $1.displayName }

        let (reconciledMappings, suggestions) = JiraContactMatcher.reconcileMappings(
            appContacts: ownerPeople,
            jiraUsers: jiraUsers,
            existing: preferences.contactMappings,
            now: now
        )
        if !suggestions.isEmpty {
            let names = Array(Set(suggestions.map(\.appContact.displayName))).sorted()
            warnings.append(L("Confirm Jira assignee mapping for: %@", names.joined(separator: ", ")))
        }

        let includeJira = preferences.jira.enabled && (providerFilter == nil || providerFilter == .jira)
        let includeReminders = preferences.reminders.enabled && (providerFilter == nil || providerFilter == .appleReminders)

        var matchedRemoteJiraIDs: Set<String> = []
        var matchedReminderIDs: Set<String> = []

        if direction.includesExport {
            let scopedTasks = localTasks.filter {
                inExportScope($0, preferences: preferences, myAliases: myAliases, explicitTaskIDs: explicitTaskIDs)
            }

            if includeJira {
                let projectKey = preferences.jira.cleanProjectKey
                for task in scopedTasks {
                    let assignee = JiraContactMatcher.resolveJiraUser(
                        owner: task.owner,
                        myAliases: myAliases,
                        mappings: reconciledMappings,
                        jiraUsers: jiraUsers
                    )
                    let ownerKey = JiraContactMatcher.normalizedKey(task.owner)
                    let unmappedOwner = assignee == nil && !ownerKey.isEmpty ? ownerKey : nil

                    if let binding = task.extended.binding(for: .jira) {
                        let remoteKey = binding.externalKey ?? binding.externalID
                        let matchedIssue = jiraIssues.first(where: { $0.id == binding.externalID || $0.key == remoteKey })
                        if let matchedIssue { matchedRemoteJiraIDs.insert(matchedIssue.key) }

                        let localDigestChanged = binding.lastSyncedDigest != nil && binding.lastSyncedDigest != task.syncDigest
                        let localNewerThanSync = task.updatedAt > binding.lastSyncedAt.addingTimeInterval(1)
                        let remoteUpdated = matchedIssue?.updatedAt
                        let remoteChanged = remoteUpdated.map { $0 > (binding.remoteUpdatedAt ?? binding.lastSyncedAt).addingTimeInterval(1) } ?? false

                        if direction.includesImport, let matchedIssue, remoteChanged && !localDigestChanged {
                            operations.append(makeLocalUpdateOperation(
                                fromJiraIssue: matchedIssue,
                                localTask: task,
                                preferences: preferences
                            ))
                        } else if localDigestChanged || localNewerThanSync {
                            let latestHistoryComment = preferences.jira.postMeetingUpdatesAsComments
                                ? latestNewComment(for: task, since: binding.lastSyncedAt)
                                : nil
                            operations.append(TaskSyncOperation(
                                provider: .jira,
                                kind: .updateExternal,
                                localTaskID: task.id,
                                externalID: binding.externalID,
                                externalKey: remoteKey,
                                projectOrList: binding.projectOrList ?? projectKey,
                                title: task.text,
                                detailSummary: L("Update %@ (%@)", remoteKey, task.extended.workflowStatus.localizedTitle),
                                ownerDisplay: task.owner,
                                resolvedJiraAssignee: assignee,
                                unmappedOwnerKey: unmappedOwner,
                                targetWorkflowStatus: task.done ? .done : task.extended.workflowStatus,
                                priority: task.extended.priority,
                                issueKind: task.extended.issueKind,
                                parentEpicKey: task.extended.parentEpicKey,
                                dueDay: task.dueDay,
                                dueAt: task.dueAt,
                                externalDescription: task.renderedExternalNotes(),
                                commentToPost: latestHistoryComment,
                                remoteIssueSnapshot: matchedIssue
                            ))
                        }
                    } else if let existingMatch = findMatchingJiraIssue(for: task, in: jiraIssues, alreadyMatched: matchedRemoteJiraIDs) {
                        matchedRemoteJiraIDs.insert(existingMatch.key)
                        let comment = preferences.jira.postMeetingUpdatesAsComments && !task.extended.contextNotes.isEmpty
                            ? "\(L("Meeting")): \(task.meetingTitle)\n\n\(task.extended.contextNotes)"
                            : nil
                        operations.append(TaskSyncOperation(
                            provider: .jira,
                            kind: .linkExistingExternal,
                            localTaskID: task.id,
                            externalID: existingMatch.id,
                            externalKey: existingMatch.key,
                            projectOrList: projectKey,
                            title: task.text,
                            detailSummary: L("Link to existing %@ (%@)", existingMatch.key, existingMatch.statusName),
                            ownerDisplay: task.owner,
                            resolvedJiraAssignee: assignee,
                            unmappedOwnerKey: unmappedOwner,
                            targetWorkflowStatus: task.done ? .done : task.extended.workflowStatus,
                            priority: task.extended.priority ?? existingMatch.priority,
                            issueKind: existingMatch.issueKind,
                            parentEpicKey: task.extended.parentEpicKey ?? existingMatch.parentEpicKey,
                            dueDay: task.dueDay ?? existingMatch.dueDay,
                            dueAt: task.dueAt,
                            externalDescription: task.renderedExternalNotes(),
                            commentToPost: comment,
                            remoteIssueSnapshot: existingMatch
                        ))
                    } else if !task.done || explicitTaskIDs?.contains(task.id) == true {
                        let createType = task.extended.issueKind == .epic ? TaskIssueKind.epic.localizedTitle : preferences.jira.defaultIssueType
                        operations.append(TaskSyncOperation(
                            provider: .jira,
                            kind: .createExternal,
                            localTaskID: task.id,
                            projectOrList: projectKey,
                            title: task.text,
                            detailSummary: L("Create %@ in %@", createType, projectKey),
                            ownerDisplay: task.owner,
                            resolvedJiraAssignee: assignee,
                            unmappedOwnerKey: unmappedOwner,
                            targetWorkflowStatus: task.done ? .done : task.extended.workflowStatus,
                            priority: task.extended.priority,
                            issueKind: task.extended.issueKind,
                            parentEpicKey: task.extended.parentEpicKey,
                            dueDay: task.dueDay,
                            dueAt: task.dueAt,
                            externalDescription: task.renderedExternalNotes()
                        ))
                    }
                }
            }

            if includeReminders {
                let remindersScopedTasks = localTasks.filter {
                    inRemindersExportScope($0, preferences: preferences, myAliases: myAliases, explicitTaskIDs: explicitTaskIDs)
                }
                let targetListName = preferences.reminders.listTitle
                for task in remindersScopedTasks {
                    if let binding = task.extended.binding(for: .appleReminders) {
                        let matchedReminder = reminders.first(where: { $0.externalIdentifier == binding.externalID || $0.id == binding.externalID })
                        if let matchedReminder {
                            matchedReminderIDs.insert(matchedReminder.externalIdentifier)
                            matchedReminderIDs.insert(matchedReminder.id)
                        }
                        let localChanged = binding.lastSyncedDigest != nil && binding.lastSyncedDigest != task.syncDigest
                        let remoteNewer = matchedReminder?.lastModifiedAt.map { $0 > (binding.remoteUpdatedAt ?? binding.lastSyncedAt).addingTimeInterval(1) } ?? false

                        if direction.includesImport, let matchedReminder, remoteNewer && !localChanged {
                            operations.append(makeLocalUpdateOperation(fromReminder: matchedReminder, localTask: task))
                        } else if localChanged || task.updatedAt > binding.lastSyncedAt.addingTimeInterval(1) {
                            operations.append(TaskSyncOperation(
                                provider: .appleReminders,
                                kind: .updateExternal,
                                localTaskID: task.id,
                                externalID: binding.externalID,
                                projectOrList: binding.projectOrList ?? targetListName,
                                title: task.text,
                                detailSummary: L("Update reminder in %@", targetListName),
                                ownerDisplay: task.owner,
                                targetWorkflowStatus: task.done ? .done : task.extended.workflowStatus,
                                priority: task.extended.priority,
                                dueDay: task.dueDay,
                                dueAt: task.dueAt,
                                externalDescription: task.renderedExternalNotes(),
                                remoteReminderSnapshot: matchedReminder
                            ))
                        }
                    } else if let match = findMatchingReminder(for: task, in: reminders, alreadyMatched: matchedReminderIDs) {
                        matchedReminderIDs.insert(match.externalIdentifier)
                        matchedReminderIDs.insert(match.id)
                        operations.append(TaskSyncOperation(
                            provider: .appleReminders,
                            kind: .linkExistingExternal,
                            localTaskID: task.id,
                            externalID: match.externalIdentifier,
                            projectOrList: match.listTitle ?? targetListName,
                            title: task.text,
                            detailSummary: L("Link to existing reminder in %@", match.listTitle ?? targetListName),
                            ownerDisplay: task.owner,
                            targetWorkflowStatus: task.done ? .done : task.extended.workflowStatus,
                            priority: task.extended.priority,
                            dueDay: task.dueDay ?? match.dueDay,
                            dueAt: task.dueAt ?? match.dueAt,
                            externalDescription: task.renderedExternalNotes(),
                            remoteReminderSnapshot: match
                        ))
                    } else if !task.done || explicitTaskIDs?.contains(task.id) == true {
                        operations.append(TaskSyncOperation(
                            provider: .appleReminders,
                            kind: .createExternal,
                            localTaskID: task.id,
                            projectOrList: targetListName,
                            title: task.text,
                            detailSummary: L("Create reminder in %@", targetListName),
                            ownerDisplay: task.owner,
                            targetWorkflowStatus: task.done ? .done : task.extended.workflowStatus,
                            priority: task.extended.priority,
                            dueDay: task.dueDay,
                            dueAt: task.dueAt,
                            externalDescription: task.renderedExternalNotes()
                        ))
                    }
                }
            }
        }

        // Handle explicit imports / updates from Jira and Reminders when not already bound to local tasks.
        if direction.includesImport && explicitTaskIDs == nil {
            let boundJiraIDs = Set(localTasks.compactMap { $0.extended.binding(for: .jira)?.externalID })
            let boundJiraKeys = Set(localTasks.compactMap { $0.extended.binding(for: .jira)?.externalKey })
            if includeJira {
                for issue in jiraIssues where !matchedRemoteJiraIDs.contains(issue.key) {
                    if let existingLocal = localTasks.first(where: {
                        $0.extended.binding(for: .jira)?.externalKey == issue.key ||
                            $0.extended.binding(for: .jira)?.externalID == issue.id
                    }) {
                        let binding = existingLocal.extended.binding(for: .jira)!
                        if let remoteUpdated = issue.updatedAt,
                           remoteUpdated > (binding.remoteUpdatedAt ?? binding.lastSyncedAt).addingTimeInterval(1) {
                            operations.append(makeLocalUpdateOperation(
                                fromJiraIssue: issue,
                                localTask: existingLocal,
                                preferences: preferences
                            ))
                        }
                        continue
                    }
                    guard !boundJiraIDs.contains(issue.id), !boundJiraKeys.contains(issue.key) else { continue }
                    operations.append(TaskSyncOperation(
                        provider: .jira,
                        kind: .importToLocal,
                        externalID: issue.id,
                        externalKey: issue.key,
                        projectOrList: preferences.jira.cleanProjectKey,
                        title: issue.summary,
                        detailSummary: "\(issue.key) · \(issue.statusName)" + (issue.assigneeName.map { " · \($0)" } ?? ""),
                        ownerDisplay: issue.assigneeName ?? "",
                        targetWorkflowStatus: issue.workflowStatus,
                        priority: issue.priority,
                        issueKind: issue.issueKind,
                        parentEpicKey: issue.parentEpicKey,
                        dueDay: issue.dueDay,
                        externalDescription: issue.description,
                        remoteIssueSnapshot: issue
                    ))
                }
            }

            if includeReminders {
                for reminder in reminders where !matchedReminderIDs.contains(reminder.externalIdentifier) && !matchedReminderIDs.contains(reminder.id) {
                    if let existingLocal = localTasks.first(where: {
                        let ext = $0.extended.binding(for: .appleReminders)?.externalID
                        return ext == reminder.externalIdentifier || ext == reminder.id
                    }) {
                        let binding = existingLocal.extended.binding(for: .appleReminders)!
                        if let remoteUpdated = reminder.lastModifiedAt,
                           remoteUpdated > (binding.remoteUpdatedAt ?? binding.lastSyncedAt).addingTimeInterval(1) {
                            operations.append(makeLocalUpdateOperation(fromReminder: reminder, localTask: existingLocal))
                        }
                        continue
                    }
                    operations.append(TaskSyncOperation(
                        provider: .appleReminders,
                        kind: .importToLocal,
                        externalID: reminder.externalIdentifier,
                        projectOrList: reminder.listTitle ?? preferences.reminders.listTitle,
                        title: reminder.title,
                        detailSummary: L("Import reminder from %@", reminder.listTitle ?? preferences.reminders.listTitle),
                        ownerDisplay: "",
                        targetWorkflowStatus: reminder.isCompleted ? .done : .todo,
                        priority: reminder.priority,
                        dueDay: reminder.dueDay,
                        dueAt: reminder.dueAt,
                        externalDescription: reminder.notes,
                        remoteReminderSnapshot: reminder
                    ))
                }
            }
        }

        return TaskSyncPacket(
            createdAt: now,
            operations: operations,
            assignableJiraUsers: jiraUsers,
            warnings: warnings,
            discoveredMappings: reconciledMappings
        )
    }

    private static func findMatchingJiraIssue(
        for task: WorkspaceTaskRecord,
        in issues: [JiraRemoteIssue],
        alreadyMatched: Set<String>
    ) -> JiraRemoteIssue? {
        let localKeys = CrossMeetingTaskReconciler.extractIssueKeys(from: task.text + " " + task.extended.contextNotes)
        if let exact = issues.first(where: { !alreadyMatched.contains($0.key) && localKeys.contains($0.key) }) {
            return exact
        }
        return issues.first { issue in
            guard !alreadyMatched.contains(issue.key) else { return false }
            return CrossMeetingTaskReconciler.textSimilarity(task.text, issue.summary) >= 0.78
        }
    }

    private static func findMatchingReminder(
        for task: WorkspaceTaskRecord,
        in reminders: [ReminderItemSnapshot],
        alreadyMatched: Set<String>
    ) -> ReminderItemSnapshot? {
        reminders.first { item in
            guard !alreadyMatched.contains(item.externalIdentifier) && !alreadyMatched.contains(item.id) else { return false }
            return CrossMeetingTaskReconciler.textSimilarity(task.text, item.title) >= 0.80
        }
    }

    private static func latestNewComment(for task: WorkspaceTaskRecord, since date: Date) -> String? {
        let fresh = task.extended.contextHistory.filter { $0.observedAt > date && $0.source != .jiraSync }
        guard !fresh.isEmpty else { return nil }
        return fresh.map { entry in
            let transition = entry.updatedStatus.map { " [\($0.localizedTitle)]" } ?? ""
            return "\(entry.meetingTitle)\(transition): \(entry.note)"
        }.joined(separator: "\n")
    }

    private static func makeLocalUpdateOperation(
        fromJiraIssue issue: JiraRemoteIssue,
        localTask: WorkspaceTaskRecord,
        preferences: TaskSyncPreferences
    ) -> TaskSyncOperation {
        TaskSyncOperation(
            provider: .jira,
            kind: .updateLocalFromExternal,
            localTaskID: localTask.id,
            externalID: issue.id,
            externalKey: issue.key,
            projectOrList: preferences.jira.cleanProjectKey,
            title: localTask.text,
            detailSummary: L("Update from %@ -> %@", issue.key, issue.statusName),
            ownerDisplay: issue.assigneeName ?? localTask.owner,
            targetWorkflowStatus: issue.workflowStatus,
            priority: issue.priority ?? localTask.extended.priority,
            issueKind: issue.issueKind != .task ? issue.issueKind : localTask.extended.issueKind,
            parentEpicKey: issue.parentEpicKey ?? localTask.extended.parentEpicKey,
            dueDay: issue.dueDay ?? localTask.dueDay,
            externalDescription: issue.description,
            remoteIssueSnapshot: issue
        )
    }

    private static func makeLocalUpdateOperation(
        fromReminder reminder: ReminderItemSnapshot,
        localTask: WorkspaceTaskRecord
    ) -> TaskSyncOperation {
        let nextStatus: TaskWorkflowStatus = reminder.isCompleted
            ? .done
            : (localTask.extended.workflowStatus.isTerminalDone ? .todo : localTask.extended.workflowStatus)
        return TaskSyncOperation(
            provider: .appleReminders,
            kind: .updateLocalFromExternal,
            localTaskID: localTask.id,
            externalID: reminder.externalIdentifier,
            projectOrList: reminder.listTitle,
            title: reminder.title.isEmpty ? localTask.text : reminder.title,
            detailSummary: reminder.isCompleted ? L("Completed in Apple Reminders") : L("Updated in Apple Reminders"),
            ownerDisplay: localTask.owner,
            targetWorkflowStatus: nextStatus,
            priority: reminder.priority ?? localTask.extended.priority,
            dueDay: reminder.dueDay ?? localTask.dueDay,
            dueAt: reminder.dueAt ?? localTask.dueAt,
            externalDescription: reminder.notes,
            remoteReminderSnapshot: reminder
        )
    }
}

public enum TaskSyncExecutor {
    public static func execute(
        packet: TaskSyncPacket,
        localTasksByID: [UUID: WorkspaceTaskRecord],
        preferences: TaskSyncPreferences,
        jira: (any JiraTaskConnecting)?,
        reminders: (any AppleRemindersConnecting)?,
        now: Date = Date()
    ) async -> (mutations: [TaskSyncLocalMutation], report: TaskSyncExecutionReport) {
        var mutations: [TaskSyncLocalMutation] = []
        var report = TaskSyncExecutionReport()

        for op in packet.operations where op.isSelected {
            switch (op.provider, op.kind) {
            case (.jira, .createExternal):
                guard let jira, let localID = op.localTaskID, let localTask = localTasksByID[localID] else { continue }
                do {
                    let payload = JiraIssueWritePayload(
                        projectKey: op.projectOrList ?? preferences.jira.cleanProjectKey,
                        issueType: op.issueKind == .epic ? TaskIssueKind.epic.jiraIssueTypeName : preferences.jira.defaultIssueType,
                        issueKind: op.issueKind,
                        parentEpicKey: op.parentEpicKey ?? localTask.extended.parentEpicKey,
                        summary: op.title,
                        description: op.externalDescription.isEmpty ? localTask.renderedExternalNotes() : op.externalDescription,
                        dueDay: op.dueDay ?? localTask.dueDay,
                        priority: op.priority ?? localTask.extended.priority,
                        assignee: op.resolvedJiraAssignee
                    )
                    var issue = try await jira.createIssue(payload)
                    if op.targetWorkflowStatus != .todo && issue.workflowStatus != op.targetWorkflowStatus {
                        issue = try await jira.updateIssue(
                            key: issue.key,
                            payload: payload,
                            targetStatus: op.targetWorkflowStatus,
                            comment: nil
                        )
                    }
                    let binding = ExternalTaskBinding(
                        provider: .jira,
                        externalID: issue.id,
                        externalKey: issue.key,
                        externalURL: issue.browseURL,
                        projectOrList: payload.projectKey,
                        remoteStatus: issue.statusName,
                        remoteAssignee: issue.assigneeName,
                        lastSyncedAt: now,
                        remoteUpdatedAt: issue.updatedAt,
                        lastSyncedDigest: localTask.syncDigest
                    )
                    mutations.append(TaskSyncLocalMutation(
                        existingTaskID: localID,
                        title: localTask.text,
                        owner: localTask.owner,
                        dueDay: localTask.dueDay,
                        dueAt: localTask.dueAt,
                        done: localTask.done,
                        completedAt: localTask.completedAt,
                        newStatus: localTask.extended.workflowStatus,
                        priority: localTask.extended.priority,
                        issueKind: localTask.extended.issueKind,
                        parentEpicKey: localTask.extended.parentEpicKey ?? issue.parentEpicKey,
                        contextAddition: "",
                        historyEntry: TaskMeetingContextEntry(
                            sessionID: localTask.sessionID,
                            meetingTitle: localTask.meetingTitle,
                            observedAt: now,
                            previousStatus: nil,
                            updatedStatus: nil,
                            note: L("Synced to Jira issue %@", issue.key),
                            source: .jiraSync
                        ),
                        binding: binding
                    ))
                    report.appliedCount += 1
                    report.createdCount += 1
                } catch {
                    report.failedMessages.append("\(op.title): \(error.localizedDescription)")
                }

            case (.jira, .updateExternal), (.jira, .linkExistingExternal):
                guard let jira, let localID = op.localTaskID, let localTask = localTasksByID[localID],
                      let issueKey = op.externalKey ?? op.externalID else { continue }
                do {
                    let payload = JiraIssueWritePayload(
                        projectKey: op.projectOrList ?? preferences.jira.cleanProjectKey,
                        issueType: op.issueKind == .epic ? TaskIssueKind.epic.jiraIssueTypeName : preferences.jira.defaultIssueType,
                        issueKind: op.issueKind,
                        parentEpicKey: op.parentEpicKey ?? localTask.extended.parentEpicKey,
                        summary: op.title,
                        description: op.externalDescription.isEmpty ? localTask.renderedExternalNotes() : op.externalDescription,
                        dueDay: op.dueDay ?? localTask.dueDay,
                        priority: op.priority ?? localTask.extended.priority,
                        assignee: op.resolvedJiraAssignee
                    )
                    let updated = try await jira.updateIssue(
                        key: issueKey,
                        payload: payload,
                        targetStatus: op.targetWorkflowStatus,
                        comment: op.commentToPost
                    )
                    let binding = ExternalTaskBinding(
                        provider: .jira,
                        externalID: updated.id,
                        externalKey: updated.key,
                        externalURL: updated.browseURL,
                        projectOrList: payload.projectKey,
                        remoteStatus: updated.statusName,
                        remoteAssignee: updated.assigneeName,
                        lastSyncedAt: now,
                        remoteUpdatedAt: updated.updatedAt,
                        lastSyncedDigest: localTask.syncDigest
                    )
                    mutations.append(TaskSyncLocalMutation(
                        existingTaskID: localID,
                        title: localTask.text,
                        owner: localTask.owner,
                        dueDay: localTask.dueDay,
                        dueAt: localTask.dueAt,
                        done: localTask.done,
                        completedAt: localTask.completedAt,
                        newStatus: localTask.extended.workflowStatus,
                        priority: localTask.extended.priority,
                        issueKind: updated.issueKind != .task ? updated.issueKind : localTask.extended.issueKind,
                        parentEpicKey: localTask.extended.parentEpicKey ?? updated.parentEpicKey,
                        contextAddition: "",
                        historyEntry: TaskMeetingContextEntry(
                            sessionID: localTask.sessionID,
                            meetingTitle: localTask.meetingTitle,
                            observedAt: now,
                            previousStatus: nil,
                            updatedStatus: nil,
                            note: op.kind == .linkExistingExternal
                                ? L("Linked to Jira issue %@", updated.key)
                                : L("Updated Jira issue %@", updated.key),
                            source: .jiraSync
                        ),
                        binding: binding
                    ))
                    report.appliedCount += 1
                    report.updatedCount += 1
                } catch {
                    report.failedMessages.append("\(issueKey): \(error.localizedDescription)")
                }

            case (.jira, .importToLocal), (.jira, .updateLocalFromExternal):
                guard let issue = op.remoteIssueSnapshot else { continue }
                let existing = op.localTaskID.flatMap { localTasksByID[$0] }
                let binding = ExternalTaskBinding(
                    provider: .jira,
                    externalID: issue.id,
                    externalKey: issue.key,
                    externalURL: issue.browseURL,
                    projectOrList: op.projectOrList ?? preferences.jira.cleanProjectKey,
                    remoteStatus: issue.statusName,
                    remoteAssignee: issue.assigneeName,
                    lastSyncedAt: now,
                    remoteUpdatedAt: issue.updatedAt,
                    lastSyncedDigest: existing?.syncDigest
                )
                let done = issue.workflowStatus.isTerminalDone
                mutations.append(TaskSyncLocalMutation(
                    existingTaskID: existing?.id,
                    title: issue.summary,
                    owner: existing?.owner.isEmpty == false ? existing!.owner : (issue.assigneeName ?? ""),
                    dueDay: issue.dueDay ?? existing?.dueDay,
                    dueAt: existing?.dueAt,
                    done: done,
                    completedAt: done ? (existing?.completedAt ?? now) : nil,
                    newStatus: issue.workflowStatus,
                    priority: issue.priority ?? existing?.extended.priority,
                    issueKind: issue.issueKind,
                    parentEpicKey: issue.parentEpicKey ?? existing?.extended.parentEpicKey,
                    contextAddition: existing == nil ? issue.description : "",
                    historyEntry: TaskMeetingContextEntry(
                        sessionID: existing?.sessionID,
                        meetingTitle: existing?.meetingTitle ?? "Jira (\(issue.key))",
                        observedAt: now,
                        previousStatus: existing?.extended.workflowStatus,
                        updatedStatus: issue.workflowStatus,
                        note: L("Synced from Jira %@ (%@)", issue.key, issue.statusName),
                        source: .jiraSync
                    ),
                    binding: binding
                ))
                report.appliedCount += 1
                if existing == nil { report.importedCount += 1 } else { report.updatedCount += 1 }

            case (.appleReminders, .createExternal), (.appleReminders, .updateExternal), (.appleReminders, .linkExistingExternal):
                guard let reminders, let localID = op.localTaskID, let localTask = localTasksByID[localID] else { continue }
                do {
                    let saved = try await reminders.upsertReminder(
                        existingExternalID: op.externalID,
                        listID: preferences.reminders.listIdentifier,
                        listTitle: preferences.reminders.listTitle,
                        title: op.title,
                        notes: op.externalDescription.isEmpty ? localTask.renderedExternalNotes() : op.externalDescription,
                        dueDay: op.dueDay ?? localTask.dueDay,
                        dueAt: op.dueAt ?? localTask.dueAt,
                        priority: op.priority ?? localTask.extended.priority,
                        isCompleted: localTask.done || op.targetWorkflowStatus.isTerminalDone,
                        reminderAlarmDate: localTask.reminderAt,
                        repeatRule: localTask.extended.reminderRule?.repeatRule ?? .none
                    )
                    let binding = ExternalTaskBinding(
                        provider: .appleReminders,
                        externalID: saved.externalIdentifier,
                        externalKey: saved.listTitle,
                        projectOrList: saved.listTitle,
                        remoteStatus: saved.isCompleted ? L("Completed") : L("Open"),
                        lastSyncedAt: now,
                        remoteUpdatedAt: saved.lastModifiedAt ?? now,
                        lastSyncedDigest: localTask.syncDigest
                    )
                    mutations.append(TaskSyncLocalMutation(
                        existingTaskID: localID,
                        title: localTask.text,
                        owner: localTask.owner,
                        dueDay: localTask.dueDay,
                        dueAt: localTask.dueAt,
                        done: localTask.done,
                        completedAt: localTask.completedAt,
                        newStatus: localTask.extended.workflowStatus,
                        priority: localTask.extended.priority,
                        issueKind: localTask.extended.issueKind,
                        parentEpicKey: localTask.extended.parentEpicKey,
                        contextAddition: "",
                        historyEntry: TaskMeetingContextEntry(
                            sessionID: localTask.sessionID,
                            meetingTitle: localTask.meetingTitle,
                            observedAt: now,
                            previousStatus: nil,
                            updatedStatus: nil,
                            note: op.kind == .createExternal ? L("Added to Apple Reminders") : L("Updated in Apple Reminders"),
                            source: .remindersSync
                        ),
                        binding: binding
                    ))
                    report.appliedCount += 1
                    if op.kind == .createExternal { report.createdCount += 1 } else { report.updatedCount += 1 }
                } catch {
                    report.failedMessages.append("\(op.title): \(error.localizedDescription)")
                }

            case (.appleReminders, .importToLocal), (.appleReminders, .updateLocalFromExternal):
                guard let reminder = op.remoteReminderSnapshot else { continue }
                let existing = op.localTaskID.flatMap { localTasksByID[$0] }
                let binding = ExternalTaskBinding(
                    provider: .appleReminders,
                    externalID: reminder.externalIdentifier,
                    externalKey: reminder.listTitle,
                    projectOrList: reminder.listTitle,
                    remoteStatus: reminder.isCompleted ? L("Completed") : L("Open"),
                    lastSyncedAt: now,
                    remoteUpdatedAt: reminder.lastModifiedAt,
                    lastSyncedDigest: existing?.syncDigest
                )
                let nextStatus: TaskWorkflowStatus = reminder.isCompleted
                    ? .done
                    : (existing?.extended.workflowStatus.isTerminalDone == true ? .todo : (existing?.extended.workflowStatus ?? .todo))
                mutations.append(TaskSyncLocalMutation(
                    existingTaskID: existing?.id,
                    title: reminder.title,
                    owner: existing?.owner ?? "",
                    dueDay: reminder.dueDay ?? existing?.dueDay,
                    dueAt: reminder.dueAt ?? existing?.dueAt,
                    done: reminder.isCompleted,
                    completedAt: reminder.isCompleted ? (reminder.completionDate ?? existing?.completedAt ?? now) : nil,
                    newStatus: nextStatus,
                    priority: reminder.priority ?? existing?.extended.priority,
                    contextAddition: existing == nil ? reminder.notes : "",
                    historyEntry: TaskMeetingContextEntry(
                        sessionID: existing?.sessionID,
                        meetingTitle: existing?.meetingTitle ?? (reminder.listTitle ?? L("Apple Reminders")),
                        observedAt: now,
                        previousStatus: existing?.extended.workflowStatus,
                        updatedStatus: nextStatus,
                        note: L("Synced from Apple Reminders"),
                        source: .remindersSync
                    ),
                    binding: binding
                ))
                report.appliedCount += 1
                if existing == nil { report.importedCount += 1 } else { report.updatedCount += 1 }
            }
        }

        return (mutations, report)
    }
}
