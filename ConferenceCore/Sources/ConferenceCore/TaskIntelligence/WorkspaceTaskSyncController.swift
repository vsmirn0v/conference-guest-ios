import Combine
import Foundation

@MainActor
public final class WorkspaceTaskSyncController: ObservableObject {
    public struct HostHooks {
        public var isMacPlatform: Bool
        public var deviceName: String
        public var loadTasks: @MainActor () async -> [WorkspaceTaskRecord]
        public var loadContacts: @MainActor () async -> [AppContactPerson]
        public var loadMyAliases: @MainActor () -> [String]
        public var applyMutations: @MainActor ([TaskSyncLocalMutation]) async throws -> Void
        public var persistPreferences: @MainActor (TaskSyncPreferences) async -> Void
        public var saveHandoverPacket: @MainActor (MacJiraHandoverPacket) async -> Void
        public var loadHandoverPackets: @MainActor () -> [MacJiraHandoverPacket]
        public var readSecret: (@Sendable (String, TaskIntegrationSecretKind) -> String?)?
        public var writeSecret: (@Sendable (String, String, TaskIntegrationSecretKind) -> Bool)?
        public var makeJiraConnector: (JiraConnectionSettings, TaskIntegrationKeychain) -> any JiraTaskConnecting
        public var makeRemindersConnector: () -> any AppleRemindersConnecting
        public var makeCalendarConnector: () -> any TaskCalendarEventConnecting
        public var onCalendarEventCreated: @MainActor () async -> Void

        public init(
            isMacPlatform: Bool = {
                #if os(macOS)
                return true
                #else
                return false
                #endif
            }(),
            deviceName: String = {
                #if os(macOS)
                return "Mac"
                #else
                return "iPhone"
                #endif
            }(),
            loadTasks: @escaping @MainActor () async -> [WorkspaceTaskRecord],
            loadContacts: @escaping @MainActor () async -> [AppContactPerson],
            loadMyAliases: @escaping @MainActor () -> [String],
            applyMutations: @escaping @MainActor ([TaskSyncLocalMutation]) async throws -> Void,
            persistPreferences: @escaping @MainActor (TaskSyncPreferences) async -> Void,
            saveHandoverPacket: @escaping @MainActor (MacJiraHandoverPacket) async -> Void = { _ in },
            loadHandoverPackets: @escaping @MainActor () -> [MacJiraHandoverPacket] = { [] },
            readSecret: (@Sendable (String, TaskIntegrationSecretKind) -> String?)? = nil,
            writeSecret: (@Sendable (String, String, TaskIntegrationSecretKind) -> Bool)? = nil,
            makeJiraConnector: @escaping (JiraConnectionSettings, TaskIntegrationKeychain) -> any JiraTaskConnecting = {
                JiraTaskConnector(settings: $0, keychain: $1)
            },
            makeRemindersConnector: @escaping () -> any AppleRemindersConnecting = { AppleRemindersConnector() },
            makeCalendarConnector: @escaping () -> any TaskCalendarEventConnecting = { TaskCalendarEventConnector() },
            onCalendarEventCreated: @escaping @MainActor () async -> Void = {}
        ) {
            self.isMacPlatform = isMacPlatform
            self.deviceName = deviceName
            self.loadTasks = loadTasks
            self.loadContacts = loadContacts
            self.loadMyAliases = loadMyAliases
            self.applyMutations = applyMutations
            self.persistPreferences = persistPreferences
            self.saveHandoverPacket = saveHandoverPacket
            self.loadHandoverPackets = loadHandoverPackets
            self.readSecret = readSecret
            self.writeSecret = writeSecret
            self.makeJiraConnector = makeJiraConnector
            self.makeRemindersConnector = makeRemindersConnector
            self.makeCalendarConnector = makeCalendarConnector
            self.onCalendarEventCreated = onCalendarEventCreated
        }
    }

    @Published public var preferences: TaskSyncPreferences
    @Published public var isBusy = false
    @Published public var statusMessage: String?
    @Published public var errorMessage: String?
    @Published public var pendingPacket: TaskSyncPacket?
    @Published public var lastReport: TaskSyncExecutionReport?
    @Published public var assignableJiraUsers: [JiraUserContact] = []
    @Published public var currentJiraUser: JiraUserContact?
    @Published public var reminderLists: [ReminderListInfo] = []
    @Published public var appContacts: [AppContactPerson] = []
    @Published public var pendingMacHandovers: [MacJiraHandoverPacket] = []
    @Published public var recentCompletedHandovers: [MacJiraHandoverPacket] = []

    public let keychain: TaskIntegrationKeychain
    private let defaultsKey = "workspace.taskSyncPreferences.v1"
    private let hooks: HostHooks
    private var isProcessingHandovers = false

    public var isMacHost: Bool { hooks.isMacPlatform }

    public init(hooks: HostHooks, keychain: TaskIntegrationKeychain = .init()) {
        self.hooks = hooks
        self.keychain = keychain
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let decoded = TaskSyncPreferences.decodeSyncJSON(raw) {
            self.preferences = decoded
            self.assignableJiraUsers = decoded.jira.cachedProjectUsers
        } else {
            self.preferences = TaskSyncPreferences()
        }
    }

    public func refreshHandoverState() {
        let all = hooks.loadHandoverPackets().sorted { $0.updatedAt > $1.updatedAt }
        pendingMacHandovers = all.filter { $0.status == .pendingMac }
        recentCompletedHandovers = Array(all.filter { $0.status != .pendingMac }.prefix(10))
    }

    public func updatePreferencesFromRemoteSync(_ remote: TaskSyncPreferences) {
        if assignableJiraUsers.isEmpty && !remote.jira.cachedProjectUsers.isEmpty {
            assignableJiraUsers = remote.jira.cachedProjectUsers
        }
        guard remote != preferences else { return }
        preferences = remote
        if !remote.jira.cachedProjectUsers.isEmpty && assignableJiraUsers.isEmpty {
            assignableJiraUsers = remote.jira.cachedProjectUsers
        }
        UserDefaults.standard.set(remote.encodeSyncJSON(), forKey: defaultsKey)
    }

    public func savePreferences(_ updated: TaskSyncPreferences) async {
        preferences = updated
        UserDefaults.standard.set(updated.encodeSyncJSON(), forKey: defaultsKey)
        await hooks.persistPreferences(updated)
    }

    public func setRoleMode(_ mode: TaskSyncRoleMode) async {
        var updated = preferences
        updated.roleMode = mode
        switch mode {
        case .personalOwner:
            updated.scopeMode = .myTasksOnly
        case .managerLead:
            updated.scopeMode = .allTasks
        case .custom:
            break
        }
        await savePreferences(updated)
    }

    public func refreshAppContacts() async {
        appContacts = await hooks.loadContacts()
        if assignableJiraUsers.isEmpty && !preferences.jira.cachedProjectUsers.isEmpty {
            assignableJiraUsers = preferences.jira.cachedProjectUsers
        }
    }

    public func jiraHostKey(for settings: JiraConnectionSettings? = nil) -> String {
        (settings ?? preferences.jira).normalizedBaseURL?.host?.lowercased() ?? "default"
    }

    public func saveJiraSecret(_ secret: String, kind: TaskIntegrationSecretKind, settings: JiraConnectionSettings? = nil) {
        let host = jiraHostKey(for: settings)
        let clean = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            _ = keychain.delete(hostKey: host, kind: kind)
            if let writeSecret = hooks.writeSecret {
                _ = writeSecret("", host, kind)
            }
            return
        }
        if let writeSecret = hooks.writeSecret {
            _ = writeSecret(clean, host, kind)
        } else {
            _ = keychain.write(clean, hostKey: host, kind: kind)
        }
    }

    public func readJiraSecret(kind: TaskIntegrationSecretKind, settings: JiraConnectionSettings? = nil) -> String? {
        readJiraSecret(host: jiraHostKey(for: settings), kind: kind)
    }

    private func readJiraSecret(host: String, kind: TaskIntegrationSecretKind) -> String? {
        if let readSecret = hooks.readSecret {
            return readSecret(host, kind)
        }
        return keychain.read(hostKey: host, kind: kind)
    }

    public func hasJiraSecret(for settings: JiraConnectionSettings? = nil) -> Bool {
        let host = jiraHostKey(for: settings)
        let target = settings ?? preferences.jira
        switch target.authMode {
        case .personalAccessToken:
            return !(readJiraSecret(host: host, kind: .jiraPersonalAccessToken)?.isEmpty ?? true)
        case .webSession:
            return !(readJiraSecret(host: host, kind: .jiraSessionCookies)?.isEmpty ?? true)
        case .basicAuth:
            return !target.usernameOrEmail.isEmpty && !(readJiraSecret(host: host, kind: .jiraBasicSecret)?.isEmpty ?? true)
        }
    }

    public func testJiraConnectionAndRefreshContacts(using customSettings: JiraConnectionSettings? = nil) async -> Bool {
        let targetSettings = customSettings ?? preferences.jira
        isBusy = true
        errorMessage = nil
        statusMessage = L("Connecting to Jira…")
        defer { isBusy = false }

        let connector = hooks.makeJiraConnector(targetSettings, keychain)
        do {
            let me = try await connector.verifyMyself()
            currentJiraUser = me
            let projectKey = targetSettings.cleanProjectKey
            var details = L("Signed in as %@", me.displayName)
            if !projectKey.isEmpty {
                if let meta = try? await connector.fetchProjectMetadata(projectKey: projectKey) {
                    details += " · \(meta.key) (\(meta.name))"
                }
                let users = (try? await connector.fetchAssignableUsers(projectKey: projectKey, query: "")) ?? []
                assignableJiraUsers = users
            }
            let contacts = await hooks.loadContacts()
            appContacts = contacts
            if !assignableJiraUsers.isEmpty {
                let (merged, _) = JiraContactMatcher.reconcileMappings(
                    appContacts: contacts,
                    jiraUsers: assignableJiraUsers,
                    existing: preferences.contactMappings
                )
                var updated = preferences
                updated.contactMappings = merged
                if hooks.isMacPlatform {
                    updated.jira.cachedProjectUsers = Array(assignableJiraUsers.prefix(150))
                }
                await savePreferences(updated)
            }
            statusMessage = details
            return true
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func fetchWritableEventCalendars() async throws -> [WritableEventCalendarInfo] {
        try await hooks.makeCalendarConnector().requestAccessAndFetchCalendars()
    }

    public func fetchUpcomingCalendarEvents(daysAhead: Int = 21) async throws -> [UpcomingCalendarEventSummary] {
        try await hooks.makeCalendarConnector().fetchUpcomingEvents(daysAhead: daysAhead)
    }

    public func createTaskDiscussionCalendarEvent(
        _ draft: TaskCalendarEventDraft,
        forTaskID taskID: UUID
    ) async throws -> TaskLinkedDiscussionMeeting {
        let linked = try await hooks.makeCalendarConnector().createDiscussionEvent(draft, forTaskID: taskID)
        await hooks.onCalendarEventCreated()
        return linked
    }

    public func autoMatchContacts() async {
        appContacts = await hooks.loadContacts()
        if preferences.jira.enabled && assignableJiraUsers.isEmpty && hasJiraSecret() {
            let connector = hooks.makeJiraConnector(preferences.jira, keychain)
            if let users = try? await connector.fetchAssignableUsers(projectKey: preferences.jira.cleanProjectKey, query: "") {
                assignableJiraUsers = users
            }
        }
        let (merged, _) = JiraContactMatcher.reconcileMappings(
            appContacts: appContacts,
            jiraUsers: assignableJiraUsers,
            existing: preferences.contactMappings
        )
        var updated = preferences
        updated.contactMappings = merged
        await savePreferences(updated)
    }

    public func setManualContactMapping(appContact: AppContactPerson, jiraUser: JiraUserContact?) async {
        var updated = preferences
        updated.contactMappings.removeAll { $0.appContactKey == appContact.key }
        if let jiraUser {
            updated.contactMappings.append(ContactIdentityMapping(
                appContact: appContact,
                jiraUser: jiraUser,
                confirmed: true,
                confidence: 1.0
            ))
        }
        await savePreferences(updated)
    }

    public func refreshReminderLists() async {
        let connector = hooks.makeRemindersConnector()
        do {
            let lists = try await connector.fetchLists()
            reminderLists = lists
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func ensureDefaultReminderList(named title: String) async {
        let connector = hooks.makeRemindersConnector()
        do {
            let ensured = try await connector.ensureList(named: title, preferredID: preferences.reminders.listIdentifier)
            reminderLists = try await connector.fetchLists()
            var updated = preferences
            updated.reminders.listIdentifier = ensured.id
            updated.reminders.listTitle = ensured.title
            await savePreferences(updated)
            statusMessage = L("Reminders list ready: %@", ensured.title)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Runs either interactive preview packet preparation or direct auto-apply depending on preferences (or explicit override).
    public func runSync(
        explicitTaskIDs: Set<UUID>? = nil,
        directionOverride: TaskSyncDirection? = nil,
        providerFilter: ExternalTaskProviderKind? = nil,
        automaticTrigger: Bool = false
    ) async {
        guard preferences.anyProviderEnabled else {
            if !automaticTrigger {
                errorMessage = L("Enable Jira or Apple Reminders in Task Sync settings first.")
            }
            return
        }
        isBusy = true
        errorMessage = nil
        statusMessage = L("Building sync packet…")
        defer { isBusy = false }

        do {
            let packet = try await buildSyncPacket(
                explicitTaskIDs: explicitTaskIDs,
                directionOverride: directionOverride,
                providerFilter: providerFilter
            )

            // On iPhone when import-only from Jira is requested while corporate Jira is routed via Mac:
            if !hooks.isMacPlatform,
               directionOverride == .importOnly,
               preferences.jira.enabled,
               (providerFilter == nil || providerFilter == .jira),
               packet.relayJiraViaMac {
                let jql = preferences.jira.importJQL.trimmingCharacters(in: .whitespacesAndNewlines)
                if !jql.isEmpty {
                    let handover = MacJiraHandoverPacket(
                        originDeviceName: hooks.deviceName,
                        kind: .importFromJira,
                        status: .pendingMac,
                        approvedByUser: true,
                        operations: [],
                        importJQL: jql,
                        summaryMessage: L("Requested Jira import from %@", hooks.deviceName)
                    )
                    await hooks.saveHandoverPacket(handover)
                    refreshHandoverState()
                    if packet.operations.isEmpty {
                        statusMessage = L("Handed over Jira import request to your Mac.")
                        pendingPacket = nil
                        return
                    }
                }
            }

            if packet.operations.isEmpty {
                statusMessage = L("All tasks in scope are already up to date.")
                pendingPacket = nil
                return
            }

            if !packet.discoveredMappings.isEmpty && packet.discoveredMappings != preferences.contactMappings {
                var updated = preferences
                updated.contactMappings = packet.discoveredMappings
                await savePreferences(updated)
            }

            if preferences.approvalMode == .autoApply {
                statusMessage = L("Applying %ld sync updates…", packet.selectedCount)
                try await applyPacket(packet)
            } else {
                pendingPacket = packet
                statusMessage = nil
            }
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    public func buildSyncPacket(
        explicitTaskIDs: Set<UUID>? = nil,
        directionOverride: TaskSyncDirection? = nil,
        providerFilter: ExternalTaskProviderKind? = nil
    ) async throws -> TaskSyncPacket {
        let tasks = await hooks.loadTasks()
        let contacts = await hooks.loadContacts()
        appContacts = contacts
        let aliases = hooks.loadMyAliases()

        var jiraIssues: [JiraRemoteIssue] = []
        var jiraUsers: [JiraUserContact] = assignableJiraUsers.isEmpty
            ? preferences.jira.cachedProjectUsers
            : assignableJiraUsers
        var relayJiraViaMac = false
        var warnings: [String] = []

        if preferences.jira.enabled && (providerFilter == nil || providerFilter == .jira) {
            let canHandOver = !hooks.isMacPlatform && preferences.jira.executionRoute != .directOnly
            if !hooks.isMacPlatform && preferences.jira.executionRoute == .alwaysViaMac {
                relayJiraViaMac = true
                warnings.append(L("Corporate Jira route is set to Mac handover. Approved Jira operations will run on your Mac."))
            } else {
                let connector = hooks.makeJiraConnector(preferences.jira, keychain)
                let projectKey = preferences.jira.cleanProjectKey
                do {
                    if jiraUsers.isEmpty && !projectKey.isEmpty {
                        let fetchedUsers = try await connector.fetchAssignableUsers(projectKey: projectKey, query: "")
                        jiraUsers = fetchedUsers
                        assignableJiraUsers = fetchedUsers
                        if hooks.isMacPlatform && !fetchedUsers.isEmpty && fetchedUsers != preferences.jira.cachedProjectUsers {
                            var updated = preferences
                            updated.jira.cachedProjectUsers = Array(fetchedUsers.prefix(150))
                            await savePreferences(updated)
                        }
                    }
                    let jql = preferences.jira.importJQL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !jql.isEmpty {
                        jiraIssues = try await connector.searchIssues(jql: jql, maxResults: 100)
                    }
                } catch {
                    if canHandOver && MacJiraHandoverPacket.shouldHandOverJiraError(error) {
                        relayJiraViaMac = true
                        warnings.append(L("Jira is unreachable from iPhone (%@). Approved changes will be handed over to your Mac.", error.localizedDescription))
                    } else {
                        throw error
                    }
                }
            }
        }

        var reminders: [ReminderItemSnapshot] = []
        if preferences.reminders.enabled && (providerFilter == nil || providerFilter == .appleReminders) {
            let connector = hooks.makeRemindersConnector()
            reminders = try await connector.fetchReminders(
                inListID: preferences.reminders.listIdentifier,
                includeCompleted: !preferences.reminders.importIncompleteReminders
            )
        }

        var packet = TaskSyncPlanner.buildPacket(
            localTasks: tasks,
            jiraIssues: jiraIssues,
            jiraUsers: jiraUsers,
            reminders: reminders,
            preferences: preferences,
            myAliases: aliases,
            explicitTaskIDs: explicitTaskIDs,
            directionOverride: directionOverride,
            providerFilter: providerFilter
        )
        packet.relayJiraViaMac = relayJiraViaMac
        if !warnings.isEmpty {
            packet.warnings = warnings + packet.warnings
        }
        return packet
    }

    public func applyPacket(_ packet: TaskSyncPacket) async throws {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        let tasks = await hooks.loadTasks()
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

        let selectedJiraOps = packet.operations.filter { $0.isSelected && $0.provider == .jira }
        let reminderOnlyPacket = TaskSyncPacket(
            id: packet.id,
            createdAt: packet.createdAt,
            operations: packet.operations.filter { $0.provider != .jira },
            assignableJiraUsers: packet.assignableJiraUsers,
            warnings: packet.warnings,
            discoveredMappings: packet.discoveredMappings
        )

        var handoverJiraInsteadOfDirect = !hooks.isMacPlatform && !selectedJiraOps.isEmpty && (
            packet.relayJiraViaMac || preferences.jira.executionRoute == .alwaysViaMac
        )

        if !handoverJiraInsteadOfDirect,
           !hooks.isMacPlatform,
           !selectedJiraOps.isEmpty,
           preferences.jira.executionRoute == .directWithMacFallback {
            if !hasJiraSecret() {
                handoverJiraInsteadOfDirect = true
            } else {
                do {
                    _ = try await hooks.makeJiraConnector(preferences.jira, keychain).verifyMyself()
                } catch where MacJiraHandoverPacket.shouldHandOverJiraError(error) {
                    handoverJiraInsteadOfDirect = true
                }
            }
        }

        var handedOverCount = 0
        if handoverJiraInsteadOfDirect && !selectedJiraOps.isEmpty {
            let handover = MacJiraHandoverPacket(
                originDeviceName: hooks.deviceName,
                kind: .applyOperations,
                status: .pendingMac,
                approvedByUser: true,
                operations: selectedJiraOps,
                importJQL: nil,
                summaryMessage: L("%ld Jira changes queued from %@", selectedJiraOps.count, hooks.deviceName)
            )
            await hooks.saveHandoverPacket(handover)
            refreshHandoverState()
            handedOverCount = selectedJiraOps.count
        }

        let effectivePacket = handedOverCount > 0 ? reminderOnlyPacket : packet
        let jira = (handedOverCount == 0 && preferences.jira.enabled) ? hooks.makeJiraConnector(preferences.jira, keychain) : nil
        let reminders = preferences.reminders.enabled ? hooks.makeRemindersConnector() : nil

        let (mutations, report) = await TaskSyncExecutor.execute(
            packet: effectivePacket,
            localTasksByID: tasksByID,
            preferences: preferences,
            jira: jira,
            reminders: reminders
        )
        if !mutations.isEmpty {
            try await hooks.applyMutations(mutations)
        }
        lastReport = report
        pendingPacket = nil

        if !report.failedMessages.isEmpty {
            errorMessage = report.failedMessages.joined(separator: "\n")
        }
        if handedOverCount > 0 && report.appliedCount > 0 {
            statusMessage = L("Applied %ld Reminders updates; handed over %ld Jira actions to Mac.", report.appliedCount, handedOverCount)
        } else if handedOverCount > 0 {
            statusMessage = L("Handed over %ld Jira actions to your Mac via iCloud.", handedOverCount)
        } else {
            statusMessage = L(
                "Synced %ld items (%ld created, %ld updated, %ld imported).",
                report.appliedCount, report.createdCount, report.updatedCount, report.importedCount
            )
        }
    }

    /// Runs on Mac when pending handover packets arrive from iPhone via iCloud Workspace Sync.
    public func processPendingHandoversFromIOS() async {
        guard hooks.isMacPlatform, !isProcessingHandovers else { return }
        refreshHandoverState()
        let pending = pendingMacHandovers
        guard !pending.isEmpty else { return }

        guard preferences.jira.enabled else {
            statusMessage = L("%ld Jira sync packets from iPhone waiting (enable Jira on Mac).", pending.count)
            return
        }
        guard hasJiraSecret() else {
            statusMessage = L("%ld Jira sync packets from iPhone waiting for Jira sign-in on Mac.", pending.count)
            return
        }

        isProcessingHandovers = true
        isBusy = true
        defer {
            isProcessingHandovers = false
            isBusy = false
            refreshHandoverState()
        }

        let connector = hooks.makeJiraConnector(preferences.jira, keychain)
        do {
            _ = try await connector.verifyMyself()
        } catch {
            if MacJiraHandoverPacket.shouldHandOverJiraError(error) {
                for var item in pending {
                    item.updatedAt = Date()
                    item.lastErrorMessage = L("Waiting for corporate Jira reachability on Mac (%@)", error.localizedDescription)
                    await hooks.saveHandoverPacket(item)
                }
                statusMessage = L("Waiting for corporate Jira / VPN on Mac (%ld pending from iPhone).", pending.count)
            } else {
                errorMessage = error.localizedDescription
            }
            return
        }

        let localTasks = await hooks.loadTasks()
        var tasksByID = Dictionary(uniqueKeysWithValues: localTasks.map { ($0.id, $0) })

        for var handover in pending {
            do {
                if handover.kind == .importFromJira {
                    let jql = (handover.importJQL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                        ? handover.importJQL!
                        : preferences.jira.importJQL
                    let issues = try await connector.searchIssues(jql: jql, maxResults: 100)
                    let packet = TaskSyncPlanner.buildPacket(
                        localTasks: localTasks,
                        jiraIssues: issues,
                        jiraUsers: assignableJiraUsers,
                        reminders: [],
                        preferences: preferences,
                        myAliases: hooks.loadMyAliases(),
                        directionOverride: .importOnly,
                        providerFilter: .jira
                    )
                    if handover.approvedByUser || preferences.approvalMode == .autoApply {
                        let (mutations, report) = await TaskSyncExecutor.execute(
                            packet: packet,
                            localTasksByID: tasksByID,
                            preferences: preferences,
                            jira: connector,
                            reminders: nil
                        )
                        if !mutations.isEmpty {
                            try await hooks.applyMutations(mutations)
                        }
                        handover.status = report.failedMessages.isEmpty ? .completedOnMac : .failedOnMac
                        handover.updatedAt = Date()
                        handover.summaryMessage = L("Imported %ld Jira issues on Mac.", report.importedCount + report.updatedCount)
                        handover.lastErrorMessage = report.failedMessages.isEmpty ? nil : report.failedMessages.joined(separator: "; ")
                    } else {
                        pendingPacket = packet
                        handover.status = .completedOnMac
                        handover.updatedAt = Date()
                        handover.summaryMessage = L("Prepared %ld Jira updates for review on Mac.", packet.operations.count)
                    }
                    await hooks.saveHandoverPacket(handover)
                } else {
                    if !handover.approvedByUser && preferences.approvalMode == .reviewBeforeApply {
                        pendingPacket = TaskSyncPacket(operations: handover.operations, assignableJiraUsers: assignableJiraUsers)
                        handover.status = .completedOnMac
                        handover.updatedAt = Date()
                        handover.summaryMessage = L("Opened %ld operations for review on Mac.", handover.operations.count)
                        await hooks.saveHandoverPacket(handover)
                        continue
                    }

                    var resolvedOps: [TaskSyncOperation] = []
                    for var op in handover.operations {
                        if let lid = op.localTaskID, tasksByID[lid] == nil {
                            tasksByID[lid] = WorkspaceTaskRecord(
                                id: lid,
                                sessionID: TaskExtendedMetadata.externalImportsSessionID,
                                outcomeID: TaskExtendedMetadata.externalImportsOutcomeID,
                                meetingTitle: L("Synced from %@", handover.originDeviceName),
                                text: op.title,
                                owner: op.ownerDisplay,
                                dueDay: op.dueDay,
                                dueAt: op.dueAt,
                                done: op.targetWorkflowStatus.isTerminalDone,
                                extended: TaskExtendedMetadata(
                                    workflowStatus: op.targetWorkflowStatus,
                                    priority: op.priority,
                                    issueKind: op.issueKind,
                                    parentEpicKey: op.parentEpicKey
                                )
                            )
                        }
                        // Prevent duplicate Jira issue creation if the text already references a remote key.
                        if op.kind == .createExternal,
                           let explicitKey = CrossMeetingTaskReconciler.extractIssueKeys(from: op.title).first {
                            let existingIssue: JiraRemoteIssue?
                            if let fullConnector = connector as? JiraTaskConnector {
                                existingIssue = try? await fullConnector.fetchIssue(key: explicitKey)
                            } else {
                                existingIssue = (try? await connector.searchIssues(jql: "key = \(explicitKey)", maxResults: 1))?.first
                            }
                            if let existingIssue {
                                op.kind = .linkExistingExternal
                                op.externalID = existingIssue.id
                                op.externalKey = existingIssue.key
                                op.remoteIssueSnapshot = existingIssue
                            }
                        }
                        resolvedOps.append(op)
                    }

                    let execPacket = TaskSyncPacket(operations: resolvedOps, assignableJiraUsers: assignableJiraUsers)
                    let (mutations, report) = await TaskSyncExecutor.execute(
                        packet: execPacket,
                        localTasksByID: tasksByID,
                        preferences: preferences,
                        jira: connector,
                        reminders: nil
                    )
                    let annotatedMutations = mutations.map { mutation -> TaskSyncLocalMutation in
                        var copy = mutation
                        copy.historyEntry.note += " (\(L("via Mac handover")))"
                        return copy
                    }
                    if !annotatedMutations.isEmpty {
                        try await hooks.applyMutations(annotatedMutations)
                    }
                    handover.status = report.failedMessages.isEmpty ? .completedOnMac : .failedOnMac
                    handover.updatedAt = Date()
                    handover.summaryMessage = L(
                        "Synced %ld Jira items via Mac (%ld created, %ld updated).",
                        report.appliedCount, report.createdCount, report.updatedCount
                    )
                    handover.lastErrorMessage = report.failedMessages.isEmpty ? nil : report.failedMessages.joined(separator: "; ")
                    await hooks.saveHandoverPacket(handover)
                }
            } catch {
                if MacJiraHandoverPacket.shouldHandOverJiraError(error) {
                    handover.updatedAt = Date()
                    handover.lastErrorMessage = L("Waiting for corporate Jira on Mac: %@", error.localizedDescription)
                } else {
                    handover.status = .failedOnMac
                    handover.updatedAt = Date()
                    handover.lastErrorMessage = error.localizedDescription
                }
                await hooks.saveHandoverPacket(handover)
            }
        }
        statusMessage = L("Processed %ld Jira handover(s) from iPhone.", pending.count)
    }
}
