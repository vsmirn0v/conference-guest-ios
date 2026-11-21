import Foundation
import XCTest
@testable import ConferenceCore

final class TaskIntelligenceTests: XCTestCase {
    func testCrossMeetingTaskMatchingAndTranscriptStatusUpdates() {
        let oldSessionID = UUID()
        let newSessionID = UUID()
        let existingTaskID = UUID()
        let otherTaskID = UUID()
        let blockedTaskID = UUID()
        let oldDate = Date(timeIntervalSince1970: 1_760_000_000)
        let newDate = Date(timeIntervalSince1970: 1_760_100_000)

        let existingTasks: [TaskReconciliationCandidateInput] = [
            TaskReconciliationCandidateInput(
                id: existingTaskID,
                sessionID: oldSessionID,
                text: "Integrate Jira issue creation in SDBCTO project",
                owner: "Vitalii Smirnov",
                done: false,
                extended: TaskExtendedMetadata(
                    workflowStatus: .inProgress,
                    contextNotes: "Start with SDBCTO-42 REST endpoint."
                ),
                seriesID: "weekly-sync",
                updatedAt: oldDate
            ),
            TaskReconciliationCandidateInput(
                id: blockedTaskID,
                sessionID: oldSessionID,
                text: "Подготовить интеграцию Apple Reminders",
                owner: "Анна Петрова",
                done: false,
                extended: TaskExtendedMetadata(workflowStatus: .todo),
                seriesID: "weekly-sync",
                updatedAt: oldDate
            ),
            TaskReconciliationCandidateInput(
                id: otherTaskID,
                sessionID: oldSessionID,
                text: "Update onboarding screen layout",
                owner: "Ivan Petrov",
                done: false,
                extended: TaskExtendedMetadata(workflowStatus: .todo),
                updatedAt: oldDate
            )
        ]

        // Negated phrases must not trigger false done transitions.
        XCTAssertNil(CrossMeetingTaskReconciler.detectStatusSignal(in: "Это еще не готово к релизу"))
        XCTAssertNil(CrossMeetingTaskReconciler.detectStatusSignal(in: "This integration is not done yet"))
        XCTAssertEqual(CrossMeetingTaskReconciler.detectStatusSignal(in: "SDBCTO-42 уже готово и задеплоили"), .done)
        XCTAssertEqual(CrossMeetingTaskReconciler.detectStatusSignal(in: "Мы заблокированы по правам"), .blocked)

        let events: [SyncedTranscriptEvent] = [
            SyncedTranscriptEvent(
                id: "e1",
                kind: "transcript",
                occurredAt: newDate,
                speaker: "Anna",
                isOwn: false,
                text: "Интеграция Apple Reminders сейчас заблокирована, ждём доступа.",
                deviceID: "test-device"
            )
        ]

        let followUps = CrossMeetingTaskReconciler.analyzeTranscriptUpdates(
            meetingTitle: "Architecture Sync",
            endedAt: newDate,
            events: events,
            notes: "",
            decisions: [],
            existingTasks: existingTasks
        )

        let extractedSnapshot = SyncedTaskSnapshot(
            id: UUID(),
            text: "Finish SDBCTO-42 Jira integration — done and deployed",
            owner: "В. Смирнов"
        )
        let distinctSnapshot = SyncedTaskSnapshot(
            id: UUID(),
            text: "Create backup retention policy document",
            owner: "Vitalii Smirnov"
        )

        let reconciled = CrossMeetingTaskReconciler.reconcile(
            sessionID: newSessionID,
            meetingTitle: "Architecture Sync",
            endedAt: newDate,
            seriesID: "weekly-sync",
            extractedTasks: [extractedSnapshot, distinctSnapshot],
            existingTasks: existingTasks,
            transcriptFollowUps: followUps,
            myAliases: ["Vitalii Smirnov", "В. Смирнов"]
        )

        XCTAssertEqual(reconciled.newTasks.map(\.snapshot.id), [distinctSnapshot.id])
        XCTAssertEqual(reconciled.links.count, 1)
        XCTAssertEqual(reconciled.links.first?.canonicalTaskID, existingTaskID)

        let jiraUpdate = try? XCTUnwrap(reconciled.canonicalUpdates.first { $0.existingTaskID == existingTaskID })
        XCTAssertEqual(jiraUpdate?.newStatus, .done)
        XCTAssertEqual(jiraUpdate?.markDone, true)

        let remindersUpdate = try? XCTUnwrap(reconciled.canonicalUpdates.first { $0.existingTaskID == blockedTaskID })
        XCTAssertEqual(remindersUpdate?.newStatus, .blocked)
        XCTAssertEqual(remindersUpdate?.markDone, false)
    }

    func testSyncedMeetingTaskMergingCombinesExtendedHistoryAndBindings() {
        let sid = UUID()
        let oid = UUID()
        let tid = UUID()
        let t1 = Date(timeIntervalSince1970: 1_760_000_000)
        let t2 = Date(timeIntervalSince1970: 1_760_010_000)
        let v1 = SyncVersion(counter: 1, device: "mac")
        let v2 = SyncVersion(counter: 2, device: "ios")

        let entryA = TaskMeetingContextEntry(id: UUID(), sessionID: sid, meetingTitle: "Kickoff", observedAt: t1, note: "Initial scope", source: .meetingExtraction)
        let entryB = TaskMeetingContextEntry(id: UUID(), sessionID: sid, meetingTitle: "Followup", observedAt: t2, previousStatus: .todo, updatedStatus: .inProgress, note: "API ready", source: .meetingFollowUp)
        let jiraBinding = ExternalTaskBinding(provider: .jira, externalID: "1001", externalKey: "SDBCTO-42", lastSyncedAt: t2)

        let taskMac = SyncedMeetingTask(
            id: tid,
            sessionID: sid,
            outcomeID: oid,
            ordinal: SyncValue(0, version: v1),
            text: SyncValue("Ship Jira sync", version: v1),
            owner: SyncValue("Vitalii", version: v1),
            assigneeID: SyncValue(nil, version: v1),
            dueDay: SyncValue(nil, version: v1),
            dueAt: SyncValue(nil, version: v1),
            reminderAt: SyncValue(nil, version: v1),
            done: SyncValue(false, version: v1),
            completedAt: SyncValue(nil, version: v1),
            extended: SyncValue(
                TaskExtendedMetadata(workflowStatus: .todo, contextNotes: "From Mac", contextHistory: [entryA]),
                version: v1
            ),
            isDeleted: SyncValue(false, version: v1),
            updatedAt: t1
        )
        let taskIOS = SyncedMeetingTask(
            id: tid,
            sessionID: sid,
            outcomeID: oid,
            ordinal: SyncValue(0, version: v1),
            text: SyncValue("Ship Jira sync", version: v1),
            owner: SyncValue("Vitalii", version: v1),
            assigneeID: SyncValue(nil, version: v1),
            dueDay: SyncValue(nil, version: v1),
            dueAt: SyncValue(nil, version: v1),
            reminderAt: SyncValue(nil, version: v1),
            done: SyncValue(false, version: v1),
            completedAt: SyncValue(nil, version: v1),
            extended: SyncValue(
                TaskExtendedMetadata(workflowStatus: .inProgress, contextNotes: "From iPhone", contextHistory: [entryB], externalBindings: [jiraBinding]),
                version: v2
            ),
            isDeleted: SyncValue(false, version: v1),
            updatedAt: t2
        )

        let merged = taskMac.merging(taskIOS)
        XCTAssertEqual(merged.extended?.value.workflowStatus, .inProgress)
        XCTAssertEqual(merged.extended?.value.contextHistory.map(\.id), [entryA.id, entryB.id])
        XCTAssertEqual(merged.extended?.value.externalBindings.first?.externalKey, "SDBCTO-42")
        XCTAssertTrue(merged.extended?.value.contextNotes.contains("From Mac") == true)
        XCTAssertTrue(merged.extended?.value.contextNotes.contains("From iPhone") == true)
    }

    func testCyrillicAndLatinContactMatcherForJiraDCAndCloud() throws {
        let appContacts = [
            AppContactPerson(displayName: "Виталий Смирнов", aliases: ["В. Смирнов"], isCurrentUser: true),
            AppContactPerson(displayName: "Анна Петрова", aliases: []),
            AppContactPerson(displayName: "Алексей Иванов", aliases: [])
        ]
        let jiraUsers = [
            JiraUserContact(identifier: "v.smirnov", username: "v.smirnov", displayName: "Смирнов Виталий Евгеньевич", emailAddress: "v.smirnov@sberdevices.ru", isServerOrDC: true),
            JiraUserContact(identifier: "a.petrova", username: "a.petrova", displayName: "Anna Petrova", emailAddress: "a.petrova@sberdevices.ru", isServerOrDC: true),
            JiraUserContact(identifier: "cloud-123", username: nil, accountId: "cloud-123", displayName: "Иванов Алексей Сергеевич", isServerOrDC: false)
        ]

        let (mappings, suggestions) = JiraContactMatcher.reconcileMappings(
            appContacts: appContacts,
            jiraUsers: jiraUsers,
            existing: []
        )
        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertEqual(mappings.count, 3)

        let dcUser = try XCTUnwrap(JiraContactMatcher.resolveJiraUser(
            owner: "Виталий Смирнов",
            mappings: mappings,
            jiraUsers: jiraUsers
        ))
        XCTAssertEqual(dcUser.identifier, "v.smirnov")
        XCTAssertEqual(dcUser.assigneePayload()["name"] as? String, "v.smirnov")
        XCTAssertNil(dcUser.assigneePayload()["accountId"])

        let anna = try XCTUnwrap(JiraContactMatcher.resolveJiraUser(
            owner: "Анна Петрова",
            mappings: mappings,
            jiraUsers: jiraUsers
        ))
        XCTAssertEqual(anna.identifier, "a.petrova")

        let cloud = try XCTUnwrap(JiraContactMatcher.resolveJiraUser(
            owner: "Алексей Иванов",
            mappings: mappings,
            jiraUsers: jiraUsers
        ))
        XCTAssertEqual(cloud.assigneePayload()["accountId"] as? String, "cloud-123")
    }

    func testJiraConnectorCreateFallbackImportAndTransitions() async throws {
        let protocolClass = MockJiraURLProtocol.self
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        let urlSession = URLSession(configuration: config)

        let lock = NSLock()
        var recordedRequests: [(method: String, path: String, auth: String?, body: String?)] = []
        var rejectedPriorityOnce = false

        MockJiraURLProtocol.handler = { request in
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? request.value(forHTTPHeaderField: "Cookie")
            let bodyData = request.httpBody ?? request.httpBodyStream.flatMap { Self.readStream($0) }
            let bodyString = bodyData.map { String(decoding: $0, as: UTF8.self) }
            lock.lock()
            recordedRequests.append((method, path, auth, bodyString))
            lock.unlock()

            func jsonResponse(_ status: Int, _ obj: Any) -> (HTTPURLResponse, Data) {
                let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
                let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (resp, data)
            }

            if path == "/rest/api/2/myself" {
                return jsonResponse(200, ["name": "v.smirnov", "displayName": "Vitalii Smirnov", "emailAddress": "v.smirnov@sberdevices.ru"])
            }
            if path == "/rest/api/2/issue", method == "POST" {
                if let bodyString, bodyString.contains("\"priority\""), !rejectedPriorityOnce {
                    rejectedPriorityOnce = true
                    return jsonResponse(400, ["errors": ["priority": "Field 'priority' cannot be set."]])
                }
                return jsonResponse(201, ["id": "9901", "key": "SDBCTO-777"])
            }
            if path == "/rest/api/2/issue/SDBCTO-777", method == "GET" {
                return jsonResponse(200, [
                    "id": "9901",
                    "key": "SDBCTO-777",
                    "fields": [
                        "summary": "Review SDBCTO rollout",
                        "description": "Created from meeting",
                        "status": ["name": "In Progress", "statusCategory": ["key": "indeterminate"]],
                        "assignee": ["name": "v.smirnov", "displayName": "Vitalii Smirnov"],
                        "updated": "2026-11-21T12:00:00.000+0300"
                    ]
                ])
            }
            if path == "/rest/api/2/search", method == "POST" {
                return jsonResponse(200, [
                    "issues": [[
                        "id": "8801",
                        "key": "SDBCTO-101",
                        "fields": [
                            "summary": "Prepare release checklist",
                            "description": "From Jira",
                            "status": ["name": "Blocked", "statusCategory": ["key": "indeterminate"]],
                            "priority": ["name": "High"],
                            "duedate": "2026-11-30",
                            "assignee": ["name": "a.petrova", "displayName": "Anna Petrova"],
                            "updated": "2026-11-21T11:00:00.000+0300"
                        ]
                    ]]
                ])
            }
            if path == "/rest/api/2/issue/SDBCTO-777/transitions", method == "GET" {
                return jsonResponse(200, [
                    "transitions": [
                        ["id": "21", "name": "Start Progress", "to": ["name": "In Progress", "statusCategory": ["key": "indeterminate"]]],
                        ["id": "31", "name": "Готово", "to": ["name": "Done", "statusCategory": ["key": "done"]]]
                    ]
                ])
            }
            if path == "/rest/api/2/issue/SDBCTO-777/transitions", method == "POST" || path == "/rest/api/2/issue/SDBCTO-777/comment" {
                return jsonResponse(204, [:])
            }
            if path == "/rest/api/2/issue/SDBCTO-777", method == "PUT" {
                return jsonResponse(204, [:])
            }
            return jsonResponse(404, ["errorMessages": ["Not found: \(path)"]])
        }

        let settings = JiraConnectionSettings(
            enabled: true,
            baseURL: "https://tasks.sberdevices.ru",
            projectKey: "SDBCTO",
            defaultIssueType: "Task",
            authMode: .personalAccessToken
        )
        let connector = JiraTaskConnector(
            settings: settings,
            secretProvider: { host, kind in
                (host == "tasks.sberdevices.ru" && kind == .jiraPersonalAccessToken) ? "pat-secret-123" : nil
            },
            session: urlSession
        )

        let me = try await connector.verifyMyself()
        XCTAssertEqual(me.identifier, "v.smirnov")
        XCTAssertTrue(recordedRequests.last?.auth == "Bearer pat-secret-123")

        let created = try await connector.createIssue(JiraIssueWritePayload(
            projectKey: "SDBCTO",
            issueType: "Task",
            summary: "Review SDBCTO rollout",
            description: "Context details",
            priority: .high,
            assignee: me
        ))
        XCTAssertEqual(created.key, "SDBCTO-777")
        XCTAssertTrue(rejectedPriorityOnce)

        let imported = try await connector.searchIssues(jql: "project = SDBCTO")
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.workflowStatus, .blocked)
        XCTAssertEqual(imported.first?.priority, .high)
        XCTAssertEqual(imported.first?.dueDay, "2026-11-30")

        _ = try await connector.updateIssue(
            key: "SDBCTO-777",
            payload: JiraIssueWritePayload(projectKey: "SDBCTO", issueType: "Task", summary: "Review SDBCTO rollout", description: "Updated"),
            targetStatus: .done,
            comment: "Confirmed in standup"
        )
        XCTAssertTrue(recordedRequests.contains { $0.method == "POST" && $0.path == "/rest/api/2/issue/SDBCTO-777/comment" })
        XCTAssertTrue(recordedRequests.contains { $0.method == "POST" && $0.path == "/rest/api/2/issue/SDBCTO-777/transitions" && ($0.body?.contains("\"31\"") == true) })
    }

    func testTaskSyncPlannerScopesLinksAndSelectiveExecution() async throws {
        let s1 = UUID()
        let o1 = UUID()
        let myTaskID = UUID()
        let bobTaskID = UUID()
        let keyMatchedTaskID = UUID()

        let tasks = [
            WorkspaceTaskRecord(
                id: myTaskID, sessionID: s1, outcomeID: o1, meetingTitle: "Standup",
                text: "Ship onboarding flow", owner: "Vitalii Smirnov", isOwnedByCurrentUser: true
            ),
            WorkspaceTaskRecord(
                id: bobTaskID, sessionID: s1, outcomeID: o1, meetingTitle: "Standup",
                text: "Audit database indices", owner: "Bob Jones", isOwnedByCurrentUser: false
            ),
            WorkspaceTaskRecord(
                id: keyMatchedTaskID, sessionID: s1, outcomeID: o1, meetingTitle: "Standup",
                text: "Complete SDBCTO-42 auth setup", owner: "Vitalii Smirnov", isOwnedByCurrentUser: true
            )
        ]

        let jiraIssues = [
            JiraRemoteIssue(
                id: "4200", key: "SDBCTO-42", summary: "Auth setup", description: "",
                statusName: "To Do", workflowStatus: .todo, browseURL: "https://tasks.sberdevices.ru/browse/SDBCTO-42"
            ),
            JiraRemoteIssue(
                id: "4201", key: "SDBCTO-99", summary: "External orphan issue", description: "Details",
                statusName: "In Progress", workflowStatus: .inProgress, browseURL: "https://tasks.sberdevices.ru/browse/SDBCTO-99"
            )
        ]

        var prefs = TaskSyncPreferences(
            approvalMode: .reviewBeforeApply,
            scopeMode: .myTasksOnly,
            direction: .bidirectional,
            jira: JiraConnectionSettings(enabled: true, baseURL: "https://tasks.sberdevices.ru", projectKey: "SDBCTO")
        )

        let packet = TaskSyncPlanner.buildPacket(
            localTasks: tasks,
            jiraIssues: jiraIssues,
            jiraUsers: [],
            preferences: prefs,
            myAliases: ["Vitalii Smirnov"]
        )

        // Bob's task excluded under .myTasksOnly; keyMatchedTask linked instead of duplicated; SDBCTO-99 imported.
        XCTAssertFalse(packet.operations.contains { $0.localTaskID == bobTaskID })
        XCTAssertEqual(packet.operations.first { $0.localTaskID == keyMatchedTaskID }?.kind, .linkExistingExternal)
        XCTAssertEqual(packet.operations.first { $0.localTaskID == myTaskID }?.kind, .createExternal)
        XCTAssertEqual(packet.operations.first { $0.externalKey == "SDBCTO-99" }?.kind, .importToLocal)

        // Selective sync overrides scope for explicit task ID.
        prefs.scopeMode = .selectedTasksOnly
        let selectedPacket = TaskSyncPlanner.buildPacket(
            localTasks: tasks,
            jiraIssues: [],
            preferences: prefs,
            explicitTaskIDs: [bobTaskID]
        )
        XCTAssertEqual(selectedPacket.operations.map(\.localTaskID), [bobTaskID])

        // Execute with one unselected operation to ensure preview selection is honored.
        var reviewed = packet
        for idx in reviewed.operations.indices where reviewed.operations[idx].localTaskID == myTaskID {
            reviewed.operations[idx].isSelected = false
        }
        let stubJira = StubJiraConnector()
        let (mutations, report) = await TaskSyncExecutor.execute(
            packet: reviewed,
            localTasksByID: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) }),
            preferences: prefs,
            jira: stubJira,
            reminders: nil
        )
        XCTAssertEqual(report.createdCount, 0)
        XCTAssertEqual(report.importedCount, 1)
        XCTAssertEqual(report.updatedCount, 1)
        XCTAssertTrue(mutations.contains { $0.existingTaskID == nil && $0.binding.externalKey == "SDBCTO-99" })
        XCTAssertTrue(mutations.contains { $0.existingTaskID == keyMatchedTaskID && $0.binding.externalKey == "SDBCTO-42" })
    }

    func testRoleModesPersonalVsManagerLeadEpicRollupAndRemindersScope() async throws {
        let sOld = UUID()
        let sNew = UUID()
        let epicID = UUID()
        let teammateTaskID = UUID()
        let myTaskID = UUID()
        let t1 = Date(timeIntervalSince1970: 1_760_000_000)
        let t2 = Date(timeIntervalSince1970: 1_760_086_400)

        let existingTasks: [TaskReconciliationCandidateInput] = [
            TaskReconciliationCandidateInput(
                id: epicID,
                sessionID: sOld,
                text: "SDBCTO-10 Q4 Voice Assistant Launch",
                owner: "Vitalii Smirnov",
                extended: TaskExtendedMetadata(
                    workflowStatus: .inProgress,
                    issueKind: .epic,
                    externalBindings: [ExternalTaskBinding(provider: .jira, externalID: "100", externalKey: "SDBCTO-10")]
                ),
                isOwnedByCurrentUser: true,
                updatedAt: t1
            ),
            TaskReconciliationCandidateInput(
                id: teammateTaskID,
                sessionID: sOld,
                text: "Implement calendar webhook listener",
                owner: "Anna Petrova",
                extended: TaskExtendedMetadata(
                    workflowStatus: .todo,
                    issueKind: .task,
                    parentEpicKey: "SDBCTO-10",
                    externalBindings: [ExternalTaskBinding(provider: .jira, externalID: "101", externalKey: "SDBCTO-11")]
                ),
                isOwnedByCurrentUser: false,
                updatedAt: t1
            ),
            TaskReconciliationCandidateInput(
                id: myTaskID,
                sessionID: sOld,
                text: "Ship Mac direct updater signing",
                owner: "Vitalii Smirnov",
                isOwnedByCurrentUser: true,
                updatedAt: t1
            )
        ]

        let extractedTeammateProgress = SyncedTaskSnapshot(
            id: UUID(),
            text: "Implement calendar webhook listener — now in review (PR opened)",
            owner: "Anna Petrova"
        )

        // Personal Mode must NOT silently mutate teammate's task; routes to reviewCandidates instead.
        let personalResult = CrossMeetingTaskReconciler.reconcile(
            sessionID: sNew,
            meetingTitle: "Weekly Standup",
            endedAt: t2,
            extractedTasks: [extractedTeammateProgress],
            existingTasks: existingTasks,
            myAliases: ["Vitalii Smirnov"],
            onlyUpdateOwnedExistingTasks: true
        )
        XCTAssertTrue(personalResult.canonicalUpdates.isEmpty)
        XCTAssertEqual(personalResult.reviewCandidates.count, 1)
        XCTAssertEqual(personalResult.reviewCandidates.first?.suggestedMatchTaskID, teammateTaskID)

        // Manager / Lead Mode updates teammate's task AND rolls up progress onto parent Epic SDBCTO-10!
        let managerResult = CrossMeetingTaskReconciler.reconcile(
            sessionID: sNew,
            meetingTitle: "Weekly Standup",
            endedAt: t2,
            extractedTasks: [extractedTeammateProgress],
            existingTasks: existingTasks,
            myAliases: ["Vitalii Smirnov"],
            onlyUpdateOwnedExistingTasks: false
        )
        let teammateUpdate = try XCTUnwrap(managerResult.canonicalUpdates.first { $0.existingTaskID == teammateTaskID })
        XCTAssertEqual(teammateUpdate.newStatus, .inReview)

        let epicUpdate = try XCTUnwrap(managerResult.canonicalUpdates.first { $0.existingTaskID == epicID })
        XCTAssertTrue(epicUpdate.contextAddition.contains("SDBCTO-11"))
        XCTAssertTrue(epicUpdate.contextAddition.contains("Weekly Standup"))

        // Planner in Manager/Lead Mode exports teammate & Epic to Jira while keeping Reminders personal by default.
        let workspaceTasks = [
            WorkspaceTaskRecord(
                id: epicID, sessionID: sOld, outcomeID: UUID(), meetingTitle: "Roadmap",
                text: "SDBCTO-10 Q4 Launch", owner: "Vitalii Smirnov", isOwnedByCurrentUser: true,
                extended: TaskExtendedMetadata(issueKind: .epic)
            ),
            WorkspaceTaskRecord(
                id: teammateTaskID, sessionID: sOld, outcomeID: UUID(), meetingTitle: "Standup",
                text: "Build calendar webhook", owner: "Anna Petrova", isOwnedByCurrentUser: false,
                extended: TaskExtendedMetadata(parentEpicKey: "SDBCTO-10")
            )
        ]
        var managerPrefs = TaskSyncPreferences(
            roleMode: .managerLead,
            scopeMode: .allTasks,
            direction: .exportOnly,
            jira: JiraConnectionSettings(enabled: true, projectKey: "SDBCTO"),
            reminders: RemindersConnectionSettings(enabled: true, listTitle: "Rock'N'Roll", onlyMyTasksInReminders: true)
        )
        let packetDefaultReminders = TaskSyncPlanner.buildPacket(
            localTasks: workspaceTasks,
            preferences: managerPrefs,
            myAliases: ["Vitalii Smirnov"]
        )
        let jiraTaskIDs = Set(packetDefaultReminders.operations.filter { $0.provider == .jira }.compactMap(\.localTaskID))
        let remTaskIDs = Set(packetDefaultReminders.operations.filter { $0.provider == .appleReminders }.compactMap(\.localTaskID))
        XCTAssertEqual(jiraTaskIDs, Set([epicID, teammateTaskID]))
        XCTAssertEqual(remTaskIDs, Set([epicID]))

        managerPrefs.reminders.onlyMyTasksInReminders = false
        let packetTeamReminders = TaskSyncPlanner.buildPacket(
            localTasks: workspaceTasks,
            preferences: managerPrefs,
            myAliases: ["Vitalii Smirnov"]
        )
        XCTAssertEqual(
            Set(packetTeamReminders.operations.filter { $0.provider == .appleReminders }.compactMap(\.localTaskID)),
            Set([epicID, teammateTaskID])
        )
    }

    func testJiraConnectorParsesAndCreatesEpicsAndParentLinks() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockJiraURLProtocol.self]
        let urlSession = URLSession(configuration: config)
        var capturedBodies: [String] = []

        MockJiraURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            let bodyData = request.httpBody ?? request.httpBodyStream.flatMap { Self.readStream($0) }
            if let bodyData {
                capturedBodies.append(String(decoding: bodyData, as: UTF8.self))
            }
            func jsonResponse(_ status: Int, _ obj: Any) -> (HTTPURLResponse, Data) {
                let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
                let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (resp, data)
            }
            if path == "/rest/api/2/search" {
                return jsonResponse(200, [
                    "issues": [
                        [
                            "id": "500",
                            "key": "SDBCTO-10",
                            "fields": [
                                "summary": "Platform Q4 Epic",
                                "description": "Umbrella",
                                "issuetype": ["name": "Эпик"],
                                "status": ["name": "In Progress", "statusCategory": ["key": "indeterminate"]]
                            ]
                        ],
                        [
                            "id": "501",
                            "key": "SDBCTO-11",
                            "fields": [
                                "summary": "Child deliverable",
                                "description": "",
                                "issuetype": ["name": "Task"],
                                "customfield_10014": "SDBCTO-10",
                                "status": ["name": "To Do", "statusCategory": ["key": "new"]]
                            ]
                        ]
                    ]
                ])
            }
            if path == "/rest/api/2/issue", method == "POST" {
                return jsonResponse(201, ["id": "502", "key": "SDBCTO-12"])
            }
            if path == "/rest/api/2/issue/SDBCTO-12", method == "GET" {
                return jsonResponse(200, [
                    "id": "502",
                    "key": "SDBCTO-12",
                    "fields": [
                        "summary": "Child from app",
                        "description": "",
                        "issuetype": ["name": "Task"],
                        "parent": ["key": "SDBCTO-10"],
                        "status": ["name": "To Do", "statusCategory": ["key": "new"]]
                    ]
                ])
            }
            return jsonResponse(404, [:])
        }

        let connector = JiraTaskConnector(
            settings: JiraConnectionSettings(enabled: true, baseURL: "https://tasks.sberdevices.ru", projectKey: "SDBCTO"),
            secretProvider: { _, _ in "pat-token" },
            session: urlSession
        )

        let searched = try await connector.searchIssues(jql: "project = SDBCTO")
        XCTAssertEqual(searched.first?.issueKind, .epic)
        XCTAssertNil(searched.first?.parentEpicKey)
        XCTAssertEqual(searched.last?.issueKind, .task)
        XCTAssertEqual(searched.last?.parentEpicKey, "SDBCTO-10")

        let created = try await connector.createIssue(JiraIssueWritePayload(
            projectKey: "SDBCTO",
            issueType: "Task",
            issueKind: .task,
            parentEpicKey: "SDBCTO-10",
            summary: "Child from app",
            description: ""
        ))
        XCTAssertEqual(created.key, "SDBCTO-12")
        XCTAssertEqual(created.parentEpicKey, "SDBCTO-10")
        XCTAssertTrue(capturedBodies.contains { $0.contains("customfield_10014") && $0.contains("SDBCTO-10") })
    }

    func testTaskReminderRulesAndLinkedDiscussions() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
        // Saturday Nov 21 2026 10:00
        let sat = cal.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 10, minute: 0))!

        // Weekdays rule on Saturday should advance to Monday Nov 23 09:00.
        let weekdayRule = TaskReminderRule(
            isEnabled: true,
            triggerMode: .atSpecificTime,
            customDate: sat.addingTimeInterval(-3600),
            hourOfDay: 9,
            minuteOfHour: 0,
            repeatRule: .weekdays
        )
        let mondayAlert = try XCTUnwrap(weekdayRule.nextFireDate(after: sat, dueDay: nil, dueAt: nil, calendar: cal))
        let mondayComps = cal.dateComponents([.year, .month, .day, .hour, .weekday], from: mondayAlert)
        XCTAssertEqual(mondayComps.day, 23)
        XCTAssertEqual(mondayComps.weekday, 2)
        XCTAssertEqual(mondayComps.hour, 9)

        // Before-due rule triggers 24h before dueDay at configured hour.
        let beforeDueRule = TaskReminderRule(
            isEnabled: true,
            triggerMode: .beforeDue,
            hourOfDay: 10,
            minuteOfHour: 0,
            offsetMinutesBefore: 24 * 60
        )
        let beforeDueAlert = try XCTUnwrap(beforeDueRule.nextFireDate(after: sat, dueDay: "2026-11-25", dueAt: nil, calendar: cal))
        XCTAssertEqual(cal.component(.day, from: beforeDueAlert), 24)
        XCTAssertEqual(cal.component(.hour, from: beforeDueAlert), 10)

        // Done tasks never fire reminders.
        XCTAssertNil(beforeDueRule.nextFireDate(after: sat, dueDay: "2026-11-25", dueAt: nil, status: .done, done: true, calendar: cal))

        // Before linked discussion meeting + closed-loop reconciliation + .ics export.
        let discussionStart = sat.addingTimeInterval(3 * 3600)
        let taskID = UUID()
        let discussion = TaskLinkedDiscussionMeeting(
            id: UUID(),
            calendarEventIdentifier: "ev-1",
            calendarSeriesID: "ser-1",
            linkedSessionID: nil,
            title: "Deep dive SDBCTO-10 architecture",
            startAt: discussionStart,
            endAt: discussionStart.addingTimeInterval(1800),
            meetingURL: "https://jazz.example.test/room42",
            calendarTitle: "Work"
        )
        let meetingRule = TaskReminderRule(
            isEnabled: true,
            triggerMode: .beforeLinkedMeeting,
            offsetMinutesBefore: 15
        )
        let beforeMeetingFire = try XCTUnwrap(meetingRule.nextFireDate(
            after: sat,
            dueDay: nil,
            dueAt: nil,
            scheduledDiscussions: [discussion],
            calendar: cal
        ))
        XCTAssertEqual(beforeMeetingFire.timeIntervalSince1970, discussionStart.addingTimeInterval(-900).timeIntervalSince1970, accuracy: 1)

        // Closed-loop transcript reconciliation matches discussion meeting back to the Epic/task via [RnR-Task: UUID] or seriesID!
        let newSessionID = UUID()
        let epicCandidate = TaskReconciliationCandidateInput(
            id: taskID,
            sessionID: UUID(),
            text: "Architecture Epic",
            owner: "Vitalii",
            extended: TaskExtendedMetadata(workflowStatus: .todo, issueKind: .epic, scheduledDiscussions: [discussion]),
            isOwnedByCurrentUser: true
        )
        let followUps = CrossMeetingTaskReconciler.analyzeTranscriptUpdates(
            meetingTitle: "Deep dive SDBCTO-10 architecture",
            endedAt: discussionStart,
            sessionID: newSessionID,
            seriesID: "ser-1",
            events: [
                SyncedTranscriptEvent(
                    id: "m1",
                    kind: "transcript",
                    occurredAt: discussionStart,
                    speaker: "Vitalii",
                    isOwn: true,
                    text: "Approved microservice split and moving forward.",
                    deviceID: "mac"
                )
            ],
            notes: "[RnR-Task: \(taskID.uuidString)]",
            decisions: ["Roll out phase 1 on Monday"],
            existingTasks: [epicCandidate]
        )
        XCTAssertEqual(followUps.first?.existingTaskID, taskID)
        XCTAssertTrue(followUps.first?.contextAddition.contains("Roll out phase 1") == true)

        let icsData = TaskCalendarEventConnector.buildICSData(
            draft: TaskCalendarEventDraft(
                title: discussion.title,
                startAt: discussion.startAt,
                endAt: discussion.endAt,
                meetingURL: discussion.meetingURL,
                agendaNotes: "Agenda line"
            ),
            taskID: taskID
        )
        let icsString = String(decoding: icsData, as: UTF8.self)
        XCTAssertTrue(icsString.contains("BEGIN:VEVENT"))
        XCTAssertTrue(icsString.contains("[RnR-Task: \(taskID.uuidString)]"))
        XCTAssertTrue(icsString.contains("https://jazz.example.test/room42"))
    }

    @MainActor
    func testIPhoneToMacCorporateJiraHandoverEndToEnd() async throws {
        let sessionID = UUID()
        let outcomeID = UUID()
        let taskID = UUID()
        let jiraUser = JiraUserContact(
            identifier: "a.petrova",
            username: "a.petrova",
            displayName: "Anna Petrova",
            emailAddress: "a.petrova@sberdevices.ru",
            isServerOrDC: true
        )
        let sharedPrefs = TaskSyncPreferences(
            roleMode: .managerLead,
            approvalMode: .reviewBeforeApply,
            scopeMode: .allTasks,
            direction: .exportOnly,
            jira: JiraConnectionSettings(
                enabled: true,
                baseURL: "https://tasks.sberdevices.ru",
                projectKey: "SDBCTO",
                executionRoute: .directWithMacFallback,
                cachedProjectUsers: [jiraUser]
            ),
            reminders: RemindersConnectionSettings(enabled: true, listTitle: "Rock'N'Roll", onlyMyTasksInReminders: false)
        )

        var sharedTasks = [
            WorkspaceTaskRecord(
                id: taskID,
                sessionID: sessionID,
                outcomeID: outcomeID,
                meetingTitle: "Sprint Planning",
                text: "Verify SDBCTO corporate SSO",
                owner: "Anna Petrova",
                isOwnedByCurrentUser: false,
                extended: TaskExtendedMetadata(workflowStatus: .inProgress)
            )
        ]
        var sharedHandovers: [MacJiraHandoverPacket] = []

        let iosReminders = InMemoryRemindersConnector()
        let iosController = WorkspaceTaskSyncController(hooks: .init(
            isMacPlatform: false,
            deviceName: "iPhone",
            loadTasks: { sharedTasks },
            loadContacts: { [AppContactPerson(displayName: "Anna Petrova")] },
            loadMyAliases: { ["Vitalii Smirnov"] },
            applyMutations: { mutations in
                for m in mutations {
                    if let idx = sharedTasks.firstIndex(where: { $0.id == m.existingTaskID }) {
                        sharedTasks[idx].extended.upsertBinding(m.binding)
                        sharedTasks[idx].extended.appendHistory(m.historyEntry)
                    }
                }
            },
            persistPreferences: { _ in },
            saveHandoverPacket: { packet in
                sharedHandovers.removeAll { $0.id == packet.id }
                sharedHandovers.append(packet)
            },
            loadHandoverPackets: { sharedHandovers },
            makeJiraConnector: { _, _ in UnreachableJiraConnector() },
            makeRemindersConnector: { iosReminders }
        ))
        iosController.updatePreferencesFromRemoteSync(sharedPrefs)

        // 1. iPhone builds packet while corporate Jira is unreachable -> relayJiraViaMac + cached user mapping!
        await iosController.runSync()
        let packet = try XCTUnwrap(iosController.pendingPacket)
        XCTAssertTrue(packet.relayJiraViaMac)
        let jiraOp = try XCTUnwrap(packet.operations.first { $0.provider == .jira })
        XCTAssertEqual(jiraOp.resolvedJiraAssignee?.identifier, "a.petrova")
        XCTAssertEqual(jiraOp.kind, .createExternal)

        // 2. User approves packet on iPhone -> Apple Reminders runs locally; Jira ops hand over to Mac!
        try await iosController.applyPacket(packet)
        let remUpserts = await iosReminders.upsertCount
        XCTAssertEqual(remUpserts, 1)
        XCTAssertNotNil(sharedTasks[0].extended.binding(for: .appleReminders))
        XCTAssertNil(sharedTasks[0].extended.binding(for: .jira))
        XCTAssertEqual(sharedHandovers.count, 1)
        XCTAssertEqual(sharedHandovers.first?.status, .pendingMac)
        XCTAssertEqual(sharedHandovers.first?.operations.first?.resolvedJiraAssignee?.identifier, "a.petrova")

        // 3. Mac picks up pending handover over iCloud, executes on reachable corporate Jira, and updates binding!
        let macJira = RecordingReachableJiraConnector()
        let secretBox = InMemorySecretBox()
        let macController = WorkspaceTaskSyncController(hooks: .init(
            isMacPlatform: true,
            deviceName: "Mac",
            loadTasks: { sharedTasks },
            loadContacts: { [] },
            loadMyAliases: { ["Vitalii Smirnov"] },
            applyMutations: { mutations in
                for m in mutations {
                    if let idx = sharedTasks.firstIndex(where: { $0.id == m.existingTaskID }) {
                        sharedTasks[idx].extended.upsertBinding(m.binding)
                        sharedTasks[idx].extended.appendHistory(m.historyEntry)
                    }
                }
            },
            persistPreferences: { _ in },
            saveHandoverPacket: { packet in
                sharedHandovers.removeAll { $0.id == packet.id }
                sharedHandovers.append(packet)
            },
            loadHandoverPackets: { sharedHandovers },
            readSecret: { host, kind in
                secretBox.read(host: host, kind: kind)
            },
            writeSecret: { value, host, kind in
                secretBox.write(value, host: host, kind: kind)
            },
            makeJiraConnector: { _, _ in macJira }
        ))
        macController.updatePreferencesFromRemoteSync(sharedPrefs)
        macController.saveJiraSecret("corp-pat", kind: .jiraPersonalAccessToken)

        await macController.processPendingHandoversFromIOS()
        let createdOnJira = await macJira.createdPayloads
        XCTAssertEqual(createdOnJira.count, 1)
        XCTAssertEqual(createdOnJira.first?.assignee?.identifier, "a.petrova")
        XCTAssertEqual(sharedTasks[0].extended.binding(for: .jira)?.externalKey, "SDBCTO-801")
        XCTAssertEqual(sharedHandovers.first?.status, .completedOnMac)
        XCTAssertTrue(macController.pendingMacHandovers.isEmpty)
    }

    private static func readStream(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class MockJiraURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (resp, data) = try handler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class StubJiraConnector: JiraTaskConnecting, @unchecked Sendable {
    func verifyMyself() async throws -> JiraUserContact {
        JiraUserContact(identifier: "me", username: "me", displayName: "Me", isServerOrDC: true)
    }
    func fetchProjectMetadata(projectKey: String) async throws -> JiraProjectMetadata {
        JiraProjectMetadata(key: projectKey, name: projectKey, issueTypes: ["Task"])
    }
    func fetchAssignableUsers(projectKey: String, query: String) async throws -> [JiraUserContact] { [] }
    func searchIssues(jql: String, maxResults: Int) async throws -> [JiraRemoteIssue] { [] }
    func createIssue(_ payload: JiraIssueWritePayload) async throws -> JiraRemoteIssue {
        JiraRemoteIssue(id: "new-1", key: "SDBCTO-500", summary: payload.summary, description: payload.description,
                        statusName: "To Do", workflowStatus: .todo)
    }
    func updateIssue(key: String, payload: JiraIssueWritePayload, targetStatus: TaskWorkflowStatus?, comment: String?) async throws -> JiraRemoteIssue {
        JiraRemoteIssue(id: "4200", key: key, summary: payload.summary, description: payload.description,
                        statusName: targetStatus?.localizedTitle ?? "To Do", workflowStatus: targetStatus ?? .todo)
    }
}

private final class InMemorySecretBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func read(host: String, kind: TaskIntegrationSecretKind) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values["\(kind.rawValue):\(host)"]
    }

    func write(_ value: String, host: String, kind: TaskIntegrationSecretKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values["\(kind.rawValue):\(host)"] = value
        return true
    }
}

private final class UnreachableJiraConnector: JiraTaskConnecting, @unchecked Sendable {
    func verifyMyself() async throws -> JiraUserContact { throw URLError(.cannotFindHost) }
    func fetchProjectMetadata(projectKey: String) async throws -> JiraProjectMetadata { throw URLError(.cannotFindHost) }
    func fetchAssignableUsers(projectKey: String, query: String) async throws -> [JiraUserContact] { throw URLError(.cannotFindHost) }
    func searchIssues(jql: String, maxResults: Int) async throws -> [JiraRemoteIssue] { throw URLError(.cannotFindHost) }
    func createIssue(_ payload: JiraIssueWritePayload) async throws -> JiraRemoteIssue { throw URLError(.cannotFindHost) }
    func updateIssue(key: String, payload: JiraIssueWritePayload, targetStatus: TaskWorkflowStatus?, comment: String?) async throws -> JiraRemoteIssue {
        throw URLError(.cannotFindHost)
    }
}

private actor RecordingReachableJiraConnector: JiraTaskConnecting {
    var createdPayloads: [JiraIssueWritePayload] = []

    func verifyMyself() async throws -> JiraUserContact {
        JiraUserContact(identifier: "v.smirnov", username: "v.smirnov", displayName: "Vitalii", isServerOrDC: true)
    }
    func fetchProjectMetadata(projectKey: String) async throws -> JiraProjectMetadata {
        JiraProjectMetadata(key: projectKey, name: projectKey, issueTypes: ["Task", "Epic"])
    }
    func fetchAssignableUsers(projectKey: String, query: String) async throws -> [JiraUserContact] { [] }
    func searchIssues(jql: String, maxResults: Int) async throws -> [JiraRemoteIssue] { [] }
    func createIssue(_ payload: JiraIssueWritePayload) async throws -> JiraRemoteIssue {
        createdPayloads.append(payload)
        return JiraRemoteIssue(
            id: "801",
            key: "SDBCTO-801",
            summary: payload.summary,
            description: payload.description,
            statusName: "In Progress",
            workflowStatus: .inProgress,
            issueTypeName: payload.issueType,
            issueKind: payload.issueKind,
            parentEpicKey: payload.parentEpicKey,
            assigneeName: payload.assignee?.displayName,
            assigneeIdentifier: payload.assignee?.identifier,
            browseURL: "https://tasks.sberdevices.ru/browse/SDBCTO-801"
        )
    }
    func updateIssue(key: String, payload: JiraIssueWritePayload, targetStatus: TaskWorkflowStatus?, comment: String?) async throws -> JiraRemoteIssue {
        JiraRemoteIssue(
            id: "801",
            key: key,
            summary: payload.summary,
            description: payload.description,
            statusName: targetStatus?.localizedTitle ?? "In Progress",
            workflowStatus: targetStatus ?? .inProgress
        )
    }
}

private actor InMemoryRemindersConnector: AppleRemindersConnecting {
    var upsertCount = 0

    func requestAccess() async throws -> Bool { true }
    func fetchLists() async throws -> [ReminderListInfo] {
        [ReminderListInfo(id: "rnr", title: "Rock'N'Roll", allowsModification: true)]
    }
    func ensureList(named title: String, preferredID: String?) async throws -> ReminderListInfo {
        ReminderListInfo(id: "rnr", title: title, allowsModification: true)
    }
    func fetchReminders(inListID listID: String?, includeCompleted: Bool) async throws -> [ReminderItemSnapshot] { [] }
    func upsertReminder(
        existingExternalID: String?,
        listID: String?,
        listTitle: String,
        title: String,
        notes: String,
        dueDay: String?,
        dueAt: Date?,
        priority: TaskPriorityLevel?,
        isCompleted: Bool,
        reminderAlarmDate: Date?,
        repeatRule: TaskReminderRepeatRule
    ) async throws -> ReminderItemSnapshot {
        upsertCount += 1
        return ReminderItemSnapshot(
            id: "rem-1",
            externalIdentifier: "ext-rem-1",
            title: title,
            notes: notes,
            isCompleted: isCompleted,
            dueDay: dueDay,
            dueAt: dueAt,
            priority: priority,
            reminderAlarmDate: reminderAlarmDate,
            repeatRule: repeatRule,
            lastModifiedAt: Date(),
            listID: "rnr",
            listTitle: listTitle
        )
    }
}
