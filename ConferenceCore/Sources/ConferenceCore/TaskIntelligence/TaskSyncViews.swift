import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sync Packet Preview & Review Sheet

public struct TaskSyncPacketReviewSheet: View {
    @ObservedObject public var controller: WorkspaceTaskSyncController
    @State private var draftPacket: TaskSyncPacket
    @State private var filterTab = 0 // 0: All, 1: Outgoing, 2: Incoming
    @State private var expandedOps: Set<UUID> = []
    @State private var saveNewMappings = true
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    public init(controller: WorkspaceTaskSyncController, packet: TaskSyncPacket) {
        self.controller = controller
        _draftPacket = State(initialValue: packet)
    }

    private var confirmButtonTitle: String {
        let selected = draftPacket.operations.filter(\.isSelected)
        if draftPacket.relayJiraViaMac,
           !selected.isEmpty,
           selected.allSatisfy({ $0.provider == .jira }) {
            return L("Hand Over (%ld)", draftPacket.selectedCount)
        }
        return L("Apply (%ld)", draftPacket.selectedCount)
    }

    private var visibleIndices: [Int] {
        draftPacket.operations.indices.filter { idx in
            let op = draftPacket.operations[idx]
            switch filterTab {
            case 1: return op.kind.isOutgoing
            case 2: return !op.kind.isOutgoing
            default: return true
            }
        }
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerControls
                Divider()
                if draftPacket.relayJiraViaMac {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "laptopcomputer.and.iphone")
                            .foregroundStyle(.blue)
                        Text(L("Corporate Jira is unreachable from this iPhone. Approved Jira decisions will be handed over to your Mac via iCloud and synced there."))
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.08))
                    Divider()
                }
                if !draftPacket.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(draftPacket.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "person.badge.key.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.08))
                    Divider()
                }
                List {
                    ForEach(visibleIndices, id: \.self) { index in
                        operationRow(index: index)
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                }
            }
            .navigationTitle(L("Review Sync Packet"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) {
                        controller.pendingPacket = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmButtonTitle) {
                        Task { await applyNow() }
                    }
                    .disabled(controller.isBusy || draftPacket.selectedCount == 0)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 660, minHeight: 500)
        #endif
    }

    private var headerControls: some View {
        VStack(spacing: 8) {
            HStack {
                Picker(L("Direction"), selection: $filterTab) {
                    Text(L("All (%ld)", draftPacket.operations.count)).tag(0)
                    Text(L("Outgoing (%ld)", draftPacket.operations.filter { $0.kind.isOutgoing }.count)).tag(1)
                    Text(L("Incoming (%ld)", draftPacket.operations.filter { !$0.kind.isOutgoing }.count)).tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack {
                Button(L("Select All")) {
                    for i in draftPacket.operations.indices { draftPacket.operations[i].isSelected = true }
                }
                .font(.caption)
                Button(L("Deselect All")) {
                    for i in draftPacket.operations.indices { draftPacket.operations[i].isSelected = false }
                }
                .font(.caption)
                Spacer()
                if !draftPacket.assignableJiraUsers.isEmpty {
                    Toggle(L("Remember assignee matches"), isOn: $saveNewMappings)
                        .font(.caption)
                        #if os(macOS)
                        .toggleStyle(.checkbox)
                        #endif
                }
            }
        }
        .padding(12)
    }

    private func operationRow(index: Int) -> some View {
        let op = draftPacket.operations[index]
        let isExpanded = expandedOps.contains(op.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Toggle("", isOn: $draftPacket.operations[index].isSelected)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(op.provider.localizedTitle)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(op.provider == .jira ? Color.blue.opacity(0.15) : Color.orange.opacity(0.15), in: Capsule())
                        Text(op.kind.localizedBadge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(badgeColor(for: op.kind).opacity(0.16), in: Capsule())
                            .foregroundStyle(badgeColor(for: op.kind))
                        if op.issueKind != .task {
                            Text(op.issueKind.localizedTitle.uppercased())
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(op.issueKind == .epic ? Color.purple.opacity(0.18) : Color.secondary.opacity(0.16), in: Capsule())
                                .foregroundStyle(op.issueKind == .epic ? Color.purple : Color.secondary)
                        }
                        if let key = op.externalKey {
                            Text(key)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if let epicKey = op.parentEpicKey, !epicKey.isEmpty {
                            Text("↳ \(epicKey)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.purple)
                        }
                        Spacer()
                        Button {
                            if isExpanded { expandedOps.remove(op.id) } else { expandedOps.insert(op.id) }
                        } label: {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(op.title)
                        .font(.body)
                    Text(op.detailSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if op.provider == .jira && op.kind.isOutgoing {
                        HStack(spacing: 6) {
                            Image(systemName: op.resolvedJiraAssignee == nil ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle.badge.checkmark")
                                .font(.caption)
                                .foregroundStyle(op.resolvedJiraAssignee == nil && !op.ownerDisplay.isEmpty ? .orange : .secondary)
                            if !op.ownerDisplay.isEmpty {
                                Text(L("Owner: %@", op.ownerDisplay))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !draftPacket.assignableJiraUsers.isEmpty {
                                Picker(L("Jira Assignee"), selection: Binding(
                                    get: { draftPacket.operations[index].resolvedJiraAssignee?.identifier ?? "" },
                                    set: { newID in
                                        let picked = draftPacket.assignableJiraUsers.first { $0.identifier == newID }
                                        draftPacket.operations[index].resolvedJiraAssignee = picked
                                    }
                                )) {
                                    Text(L("Unassigned")).tag("")
                                    ForEach(draftPacket.assignableJiraUsers) { user in
                                        Text("\(user.displayName) (\(user.username ?? user.identifier))").tag(user.identifier)
                                    }
                                }
                                .font(.caption)
                                #if os(macOS)
                                .labelsHidden()
                                .frame(maxWidth: 220)
                                #endif
                            } else if let mapped = op.resolvedJiraAssignee {
                                Text("→ \(mapped.displayName)")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }

                    if isExpanded {
                        if !op.externalDescription.isEmpty {
                            Text(op.externalDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                        }
                        if let comment = op.commentToPost, !comment.isEmpty {
                            Text(L("Comment: %@", comment))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func badgeColor(for kind: TaskSyncOperation.Kind) -> Color {
        switch kind {
        case .createExternal: return .green
        case .updateExternal: return .blue
        case .linkExistingExternal: return .purple
        case .updateLocalFromExternal: return .teal
        case .importToLocal: return .indigo
        }
    }

    @MainActor
    private func applyNow() async {
        errorText = nil
        if saveNewMappings {
            for op in draftPacket.operations where op.isSelected && op.provider == .jira {
                guard !op.ownerDisplay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let user = op.resolvedJiraAssignee else { continue }
                let person = AppContactPerson(displayName: op.ownerDisplay)
                await controller.setManualContactMapping(appContact: person, jiraUser: user)
            }
        }
        do {
            try await controller.applyPacket(draftPacket)
            if controller.errorMessage == nil {
                dismiss()
            } else {
                errorText = controller.errorMessage
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Task Sync & External Integrations Settings Sheet

public struct TaskSyncSettingsSheet: View {
    @ObservedObject public var controller: WorkspaceTaskSyncController
    @State private var prefs: TaskSyncPreferences
    @State private var jiraSecretDraft: String = ""
    @State private var showWebSignIn = false
    @State private var contactSearch = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    public init(controller: WorkspaceTaskSyncController) {
        self.controller = controller
        _prefs = State(initialValue: controller.preferences)
    }

    public var body: some View {
        NavigationStack {
            Form {
                syncPolicySection
                jiraSection
                contactMatchingSection
                remindersSection

                if let status = controller.statusMessage {
                    Section {
                        Label(status, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                if let error = controller.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(L("Task Sync & Integrations"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save")) {
                        Task {
                            commitSecretDraft()
                            await controller.savePreferences(prefs)
                            dismiss()
                        }
                    }
                }
            }
            .task {
                await controller.refreshAppContacts()
                controller.refreshHandoverState()
                loadSecretDraft(for: prefs.jira)
            }
            .sheet(isPresented: $showWebSignIn) {
                if let url = prefs.jira.normalizedBaseURL {
                    JiraWebSignInSheet(baseURL: url) { mode, secret, user in
                        prefs.jira.enabled = true
                        prefs.jira.authMode = mode
                        prefs.jira.usernameOrEmail = user.username ?? user.identifier
                        jiraSecretDraft = mode == .personalAccessToken ? secret : ""
                        let host = prefs.jira.normalizedBaseURL?.host?.lowercased() ?? "default"
                        let kind: TaskIntegrationSecretKind = mode == .personalAccessToken ? .jiraPersonalAccessToken : .jiraSessionCookies
                        _ = controller.keychain.write(secret, hostKey: host, kind: kind)
                        controller.currentJiraUser = user
                        Task {
                            await controller.savePreferences(prefs)
                            _ = await controller.testJiraConnectionAndRefreshContacts(using: prefs.jira)
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 620)
        #endif
    }

    private var syncPolicySection: some View {
        Section(L("Sync Workflow & Role Mode")) {
            Picker(L("Team Role Mode"), selection: $prefs.roleMode) {
                ForEach(TaskSyncRoleMode.allCases) { role in
                    Text(role.localizedTitle).tag(role)
                }
            }
            .onChange(of: prefs.roleMode) { role in
                switch role {
                case .personalOwner:
                    prefs.scopeMode = .myTasksOnly
                case .managerLead:
                    prefs.scopeMode = .allTasks
                case .custom:
                    break
                }
            }
            Text(prefs.roleMode.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(L("Approval Mode"), selection: $prefs.approvalMode) {
                ForEach(TaskSyncApprovalMode.allCases) { mode in
                    Text(mode.localizedTitle).tag(mode)
                }
            }
            Picker(L("Sync Direction"), selection: $prefs.direction) {
                ForEach(TaskSyncDirection.allCases) { dir in
                    Text(dir.localizedTitle).tag(dir)
                }
            }
            if prefs.roleMode == .custom {
                Picker(L("Task Scope"), selection: $prefs.scopeMode) {
                    ForEach(TaskSyncScopeMode.allCases) { scope in
                        Text(scope.localizedTitle).tag(scope)
                    }
                }
                if prefs.scopeMode == .selectedPeople {
                    selectedPeopleChecklist
                }
            }
            Toggle(L("Sync automatically after meeting outcomes"), isOn: $prefs.autoSyncAfterMeetingOutcome)
        }
    }

    @ViewBuilder
    private var selectedPeopleChecklist: some View {
        let people = controller.appContacts
        if people.isEmpty {
            Text(L("No people found in existing tasks yet."))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(people) { person in
                let isPicked = prefs.selectedPersonKeys.contains(person.key)
                Toggle(isOn: Binding(
                    get: { isPicked },
                    set: { enabled in
                        if enabled {
                            if !prefs.selectedPersonKeys.contains(person.key) {
                                prefs.selectedPersonKeys.append(person.key)
                            }
                        } else {
                            prefs.selectedPersonKeys.removeAll { $0 == person.key }
                        }
                    }
                )) {
                    Text(person.displayName + (person.isCurrentUser ? " (\(L("You")))" : ""))
                }
            }
        }
    }

    private var jiraSection: some View {
        Section(L("Jira Integration")) {
            Toggle(L("Enable Jira sync"), isOn: $prefs.jira.enabled)
            TextField(L("Jira URL"), text: $prefs.jira.baseURL)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                #endif
            TextField(L("Home Project Key"), text: $prefs.jira.projectKey)
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                #endif
            TextField(L("Default Issue Type"), text: $prefs.jira.defaultIssueType)
            TextField(L("Import JQL"), text: $prefs.jira.importJQL, axis: .vertical)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            HStack {
                Button(L("SDBCTO Open")) {
                    let project = prefs.jira.cleanProjectKey.isEmpty ? "SDBCTO" : prefs.jira.cleanProjectKey
                    prefs.jira.importJQL = "project = \(project) AND resolution = Unresolved ORDER BY updated DESC"
                }
                .font(.caption)
                Button(L("My Open Issues")) {
                    let project = prefs.jira.cleanProjectKey
                    prefs.jira.importJQL = project.isEmpty
                        ? "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC"
                        : "project = \(project) AND assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC"
                }
                .font(.caption)
            }
            .buttonStyle(.borderless)

            Picker(L("Authentication"), selection: $prefs.jira.authMode) {
                ForEach(JiraAuthMode.allCases) { mode in
                    Text(mode.localizedTitle).tag(mode)
                }
            }
            .onChange(of: prefs.jira.authMode) { _ in
                loadSecretDraft(for: prefs.jira)
            }

            if prefs.jira.authMode == .basicAuth {
                TextField(L("Username or Email"), text: $prefs.jira.usernameOrEmail)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                SecureField(L("API Token / Password"), text: $jiraSecretDraft)
            } else if prefs.jira.authMode == .personalAccessToken {
                SecureField(L("Personal Access Token"), text: $jiraSecretDraft)
                HStack {
                    if let base = prefs.jira.normalizedBaseURL {
                        Button(L("Open PAT Page in Safari")) {
                            var url = base.appendingPathComponent("secure/ViewProfile.jspa")
                            if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                                comps.queryItems = [URLQueryItem(name: "selectedTab", value: "com.atlassian.pats.pats-plugin:jira-user-personal-access-tokens")]
                                url = comps.url ?? url
                            }
                            openURL(url)
                        }
                        .font(.caption)
                    }
                    Spacer()
                    Button(L("Sign in via Web…")) { showWebSignIn = true }
                        .font(.caption)
                        .disabled(prefs.jira.normalizedBaseURL == nil)
                }
            } else {
                HStack {
                    Text(controller.hasJiraSecret(for: prefs.jira) ? L("Web session cookies saved") : L("Not signed in"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Sign in via Web…")) { showWebSignIn = true }
                        .disabled(prefs.jira.normalizedBaseURL == nil)
                }
            }

            Toggle(L("Post meeting updates as Jira comments"), isOn: $prefs.jira.postMeetingUpdatesAsComments)

            Picker(L("Corporate Jira Route"), selection: $prefs.jira.executionRoute) {
                ForEach(JiraExecutionRoute.allCases) { route in
                    Text(route.localizedTitle).tag(route)
                }
            }
            Text(L("When corporate Jira is only reachable on Mac (VPN / intranet), iPhone sync decisions hand over via iCloud and run on your Mac."))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !controller.pendingMacHandovers.isEmpty || !controller.recentCompletedHandovers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !controller.pendingMacHandovers.isEmpty {
                        Label(
                            L("%ld handover packet(s) waiting for Mac", controller.pendingMacHandovers.count),
                            systemImage: "laptopcomputer.and.iphone"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        if controller.isMacHost {
                            Button(L("Process iPhone Handovers Now")) {
                                Task { await controller.processPendingHandoversFromIOS() }
                            }
                            .font(.caption)
                        }
                    }
                    ForEach(controller.recentCompletedHandovers.prefix(3)) { item in
                        HStack(spacing: 6) {
                            Image(systemName: item.status == .completedOnMac ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(item.status == .completedOnMac ? .green : .red)
                            Text(item.summaryMessage ?? item.lastErrorMessage ?? L("Handover completed"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Button {
                commitSecretDraft()
                Task {
                    await controller.savePreferences(prefs)
                    _ = await controller.testJiraConnectionAndRefreshContacts(using: prefs.jira)
                    prefs.contactMappings = controller.preferences.contactMappings
                }
            } label: {
                HStack {
                    Text(L("Verify Jira Connection & Load Project Users"))
                    Spacer()
                    if controller.isBusy { ProgressView().controlSize(.small) }
                }
            }
            .disabled(controller.isBusy || prefs.jira.normalizedBaseURL == nil)
        }
    }

    private var contactMatchingSection: some View {
        Section(L("Contact Matching (App Contacts ↔ Jira)")) {
            if !controller.appContacts.isEmpty {
                HStack {
                    TextField(L("Filter people…"), text: $contactSearch)
                    Button(L("Auto-Match")) {
                        Task {
                            commitSecretDraft()
                            await controller.savePreferences(prefs)
                            await controller.autoMatchContacts()
                            prefs.contactMappings = controller.preferences.contactMappings
                        }
                    }
                }
                let filtered = controller.appContacts.filter {
                    contactSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        $0.displayName.localizedCaseInsensitiveContains(contactSearch)
                }
                ForEach(filtered) { person in
                    let mapped = prefs.contactMappings.first { $0.appContactKey == person.key }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(person.displayName + (person.isCurrentUser ? " (\(L("You")))" : ""))
                                .font(.body)
                            Spacer()
                            if let mapped {
                                Text(mapped.jiraDisplayName)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(mapped.isConfirmedByUser ? Color.green : Color.accentColor)
                            } else {
                                Text(L("Unmatched"))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        if !controller.assignableJiraUsers.isEmpty {
                            Picker(L("Jira User"), selection: Binding(
                                get: { mapped?.jiraIdentifier ?? "" },
                                set: { newID in
                                    prefs.contactMappings.removeAll { $0.appContactKey == person.key }
                                    if let picked = controller.assignableJiraUsers.first(where: { $0.identifier == newID }) {
                                        prefs.contactMappings.append(ContactIdentityMapping(
                                            appContact: person,
                                            jiraUser: picked,
                                            confirmed: true,
                                            confidence: 1.0
                                        ))
                                    }
                                }
                            )) {
                                Text(L("None / Unassigned")).tag("")
                                ForEach(controller.assignableJiraUsers) { user in
                                    Text("\(user.displayName) (\(user.username ?? user.identifier))").tag(user.identifier)
                                }
                            }
                            .font(.caption)
                            #if os(macOS)
                            .labelsHidden()
                            #endif
                        }
                    }
                }
            } else {
                Text(L("Contacts discovered in meetings appear here so you can match them to Jira assignees."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var remindersSection: some View {
        Section(L("Apple Reminders Integration")) {
            Toggle(L("Enable Apple Reminders sync"), isOn: $prefs.reminders.enabled)
            TextField(L("Reminders List Name"), text: $prefs.reminders.listTitle)
            if !controller.reminderLists.isEmpty {
                Picker(L("Target List"), selection: Binding(
                    get: { prefs.reminders.listIdentifier ?? "" },
                    set: { id in
                        prefs.reminders.listIdentifier = id.isEmpty ? nil : id
                        if let found = controller.reminderLists.first(where: { $0.id == id }) {
                            prefs.reminders.listTitle = found.title
                        }
                    }
                )) {
                    Text(L("Match by name (%@)", prefs.reminders.listTitle)).tag("")
                    ForEach(controller.reminderLists.filter(\.allowsModification)) { list in
                        Text(list.title).tag(list.id)
                    }
                }
            }
            Toggle(L("Only import open reminders"), isOn: $prefs.reminders.importIncompleteReminders)
            Toggle(L("Only sync my own tasks to Apple Reminders"), isOn: $prefs.reminders.onlyMyTasksInReminders)
            HStack {
                Button(L("Grant Access & Load Lists")) {
                    Task { await controller.refreshReminderLists() }
                }
                Spacer()
                Button(L("Create / Select List")) {
                    Task {
                        await controller.ensureDefaultReminderList(named: prefs.reminders.listTitle)
                        prefs.reminders = controller.preferences.reminders
                    }
                }
            }
        }
    }

    private func loadSecretDraft(for settings: JiraConnectionSettings) {
        let host = settings.normalizedBaseURL?.host?.lowercased() ?? "default"
        switch settings.authMode {
        case .personalAccessToken:
            jiraSecretDraft = controller.keychain.read(hostKey: host, kind: .jiraPersonalAccessToken) ?? ""
        case .basicAuth:
            jiraSecretDraft = controller.keychain.read(hostKey: host, kind: .jiraBasicSecret) ?? ""
        case .webSession:
            jiraSecretDraft = ""
        }
    }

    private func commitSecretDraft() {
        let host = prefs.jira.normalizedBaseURL?.host?.lowercased() ?? "default"
        let clean = jiraSecretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        switch prefs.jira.authMode {
        case .personalAccessToken:
            _ = controller.keychain.write(clean, hostKey: host, kind: .jiraPersonalAccessToken)
        case .basicAuth:
            _ = controller.keychain.write(clean, hostKey: host, kind: .jiraBasicSecret)
        case .webSession:
            break
        }
    }
}

// MARK: - Task Extended Context, Custom Reminder Rules & Linked Discussion Meetings

public struct TaskDetailEditPayload: Equatable, Sendable {
    public var text: String
    public var owner: String
    public var status: TaskWorkflowStatus
    public var priority: TaskPriorityLevel?
    public var issueKind: TaskIssueKind
    public var parentEpicKey: String?
    public var dueDay: String?
    public var reminderAt: Date?
    public var reminderRule: TaskReminderRule?
    public var scheduledDiscussions: [TaskLinkedDiscussionMeeting]
    public var contextNotes: String

    public init(
        text: String,
        owner: String,
        status: TaskWorkflowStatus,
        priority: TaskPriorityLevel?,
        issueKind: TaskIssueKind = .task,
        parentEpicKey: String? = nil,
        dueDay: String? = nil,
        reminderAt: Date? = nil,
        reminderRule: TaskReminderRule? = nil,
        scheduledDiscussions: [TaskLinkedDiscussionMeeting] = [],
        contextNotes: String
    ) {
        self.text = text
        self.owner = owner
        self.status = status
        self.priority = priority
        self.issueKind = issueKind
        self.parentEpicKey = parentEpicKey
        self.dueDay = dueDay
        self.reminderAt = reminderAt
        self.reminderRule = reminderRule
        self.scheduledDiscussions = scheduledDiscussions
        self.contextNotes = contextNotes
    }
}

private struct TaskCalendarICSFile: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .calendarEvent) { item in
            item.data
        }
    }
}

public struct TaskDiscussionMeetingSheet: View {
    public let task: WorkspaceTaskRecord
    public let syncController: WorkspaceTaskSyncController?
    public let onLinked: @MainActor (_ meeting: TaskLinkedDiscussionMeeting, _ addPreMeetingReminder: Bool) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0 // 0: Create calendar event, 1: Link upcoming calendar event
    @State private var title: String
    @State private var startAt: Date
    @State private var durationMinutes = 30
    @State private var meetingURL: String
    @State private var agendaNotes: String
    @State private var selectedCalendarID = ""
    @State private var remindBeforeMeeting = true
    @State private var calendars: [WritableEventCalendarInfo] = []
    @State private var upcomingEvents: [UpcomingCalendarEventSummary] = []
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?

    public init(
        task: WorkspaceTaskRecord,
        syncController: WorkspaceTaskSyncController? = nil,
        onLinked: @escaping @MainActor (TaskLinkedDiscussionMeeting, Bool) async -> Void
    ) {
        self.task = task
        self.syncController = syncController
        self.onLinked = onLinked

        let jiraKey = task.extended.binding(for: .jira)?.externalKey
        let prefix = task.extended.issueKind == .epic ? L("Epic Review") : L("Discuss")
        let defaultTitle: String = if let jiraKey, !jiraKey.isEmpty {
            "\(prefix) \(jiraKey): \(task.text)"
        } else {
            "\(prefix): \(task.text)"
        }
        _title = State(initialValue: String(defaultTitle.prefix(200)))

        let nextHalfHour = Self.defaultStartDate()
        _startAt = State(initialValue: nextHalfHour)

        let existingLink = task.extended.scheduledDiscussions.first?.meetingURL ?? ""
        _meetingURL = State(initialValue: existingLink)

        var agenda: [String] = []
        if let jiraURL = task.extended.binding(for: .jira)?.externalURL {
            agenda.append("Jira: \(jiraURL)")
        }
        if !task.owner.isEmpty {
            agenda.append("\(L("Owner")): \(task.owner)")
        }
        if !task.extended.contextNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            agenda.append(task.extended.contextNotes)
        }
        _agendaNotes = State(initialValue: agenda.joined(separator: "\n\n"))
    }

    public var body: some View {
        NavigationStack {
            Form {
                Picker(L("Action"), selection: $mode) {
                    Text(L("New Calendar Event")).tag(0)
                    Text(L("Link Existing Event")).tag(1)
                }
                .pickerStyle(.segmented)

                if mode == 0 {
                    createSection
                } else {
                    linkExistingSection
                }

                if let error {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(L("Discussion Meeting"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
                if mode == 0 {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Create Event")) {
                            Task { await createEvent() }
                        }
                        .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .task {
                await loadCalendarsAndEvents()
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 500)
        #endif
    }

    @ViewBuilder
    private var createSection: some View {
        Section(L("Event Details")) {
            TextField(L("Meeting title"), text: $title)
            DatePicker(L("Starts"), selection: $startAt, displayedComponents: [.date, .hourAndMinute])
            Picker(L("Duration"), selection: $durationMinutes) {
                Text(L("15 min")).tag(15)
                Text(L("30 min")).tag(30)
                Text(L("45 min")).tag(45)
                Text(L("60 min")).tag(60)
                Text(L("90 min")).tag(90)
            }
            if !calendars.isEmpty {
                Picker(L("Calendar"), selection: $selectedCalendarID) {
                    ForEach(calendars) { cal in
                        Text("\(cal.title) (\(cal.sourceTitle))").tag(cal.id)
                    }
                }
            }
            TextField(L("Conference / Room URL (optional)"), text: $meetingURL)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                #endif
            Toggle(L("Set task reminder 15 min before meeting"), isOn: $remindBeforeMeeting)
        }

        Section(L("Agenda & Task Context")) {
            TextEditor(text: $agendaNotes)
                .frame(minHeight: 90)
            let draft = TaskCalendarEventDraft(
                calendarIdentifier: selectedCalendarID.isEmpty ? nil : selectedCalendarID,
                title: title,
                startAt: startAt,
                endAt: startAt.addingTimeInterval(TimeInterval(durationMinutes * 60)),
                meetingURL: meetingURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : meetingURL,
                agendaNotes: agendaNotes
            )
            let ics = TaskCalendarICSFile(
                data: TaskCalendarEventConnector.buildICSData(draft: draft, taskID: task.id)
            )
            ShareLink(
                item: ics,
                preview: SharePreview(title, image: Image(systemName: "calendar"))
            ) {
                Label(L("Share Calendar Invite (.ics)"), systemImage: "square.and.arrow.up")
            }
        }
    }

    @ViewBuilder
    private var linkExistingSection: some View {
        Section(L("Upcoming Calendar Meetings")) {
            if loading {
                HStack {
                    ProgressView()
                    Text(L("Loading calendars…"))
                        .foregroundStyle(.secondary)
                }
            } else if upcomingEvents.isEmpty {
                Text(L("No upcoming calendar events found in the next 3 weeks."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(upcomingEvents) { event in
                    Button {
                        Task {
                            let linked = TaskLinkedDiscussionMeeting(
                                calendarEventIdentifier: event.calendarItemIdentifier,
                                calendarSeriesID: event.seriesID,
                                title: event.title,
                                startAt: event.startAt,
                                endAt: event.endAt,
                                meetingURL: event.meetingURL,
                                calendarTitle: event.calendarTitle,
                                agendaNotes: event.notes
                            )
                            await onLinked(linked, remindBeforeMeeting)
                            dismiss()
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.title)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text("\(event.startAt.formatted(date: .abbreviated, time: .shortened)) · \(event.calendarTitle)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "link.badge.plus")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Toggle(L("Set task reminder 15 min before linked meeting"), isOn: $remindBeforeMeeting)
        }
    }

    @MainActor
    private func loadCalendarsAndEvents() async {
        loading = true
        error = nil
        defer { loading = false }
        let connector: any TaskCalendarEventConnecting = TaskCalendarEventConnector()
        do {
            let writable: [WritableEventCalendarInfo]
            let upcoming: [UpcomingCalendarEventSummary]
            if let syncController {
                writable = try await syncController.fetchWritableEventCalendars()
                upcoming = try await syncController.fetchUpcomingCalendarEvents(daysAhead: 21)
            } else {
                writable = try await connector.requestAccessAndFetchCalendars()
                upcoming = try await connector.fetchUpcomingEvents(daysAhead: 21)
            }
            calendars = writable
            if selectedCalendarID.isEmpty, let first = writable.first {
                selectedCalendarID = first.id
            }
            upcomingEvents = upcoming
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func createEvent() async {
        saving = true
        error = nil
        let draft = TaskCalendarEventDraft(
            calendarIdentifier: selectedCalendarID.isEmpty ? nil : selectedCalendarID,
            title: title,
            startAt: startAt,
            endAt: startAt.addingTimeInterval(TimeInterval(durationMinutes * 60)),
            meetingURL: meetingURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : meetingURL,
            agendaNotes: agendaNotes,
            alarmOffsetMinutesBefore: remindBeforeMeeting ? 15 : 10
        )
        do {
            let linked: TaskLinkedDiscussionMeeting
            if let syncController {
                linked = try await syncController.createTaskDiscussionCalendarEvent(draft, forTaskID: task.id)
            } else {
                linked = try await TaskCalendarEventConnector().createDiscussionEvent(draft, forTaskID: task.id)
            }
            await onLinked(linked, remindBeforeMeeting)
            dismiss()
        } catch {
            saving = false
            self.error = error.localizedDescription
        }
    }

    private static func defaultStartDate() -> Date {
        let cal = Calendar.current
        let base = Date().addingTimeInterval(3600)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: base)
        let roundedMinute = (comps.minute ?? 0) < 30 ? 30 : 0
        let extraHour = (comps.minute ?? 0) < 30 ? 0 : 1
        var target = DateComponents()
        target.year = comps.year
        target.month = comps.month
        target.day = comps.day
        target.hour = (comps.hour ?? 10) + extraHour
        target.minute = roundedMinute
        return cal.date(from: target) ?? base
    }
}

public struct TaskDetailAndContextSheet: View {
    public let task: WorkspaceTaskRecord
    public let syncController: WorkspaceTaskSyncController?
    public let knownEpics: [(key: String, title: String)]
    public let onSave: @MainActor (TaskDetailEditPayload) async -> Bool
    public let onDelete: (@MainActor () async -> Bool)?
    public let onOpenMeeting: ((UUID) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var text: String
    @State private var owner: String
    @State private var status: TaskWorkflowStatus
    @State private var issueKind: TaskIssueKind
    @State private var parentEpicKey: String
    @State private var hasPriority: Bool
    @State private var priority: TaskPriorityLevel
    @State private var hasDueDay: Bool
    @State private var dueDate: Date
    @State private var hasReminder: Bool
    @State private var triggerMode: TaskReminderTriggerMode
    @State private var customReminderDate: Date
    @State private var reminderTimeOfDay: Date
    @State private var offsetMinutesBefore: Int
    @State private var repeatRule: TaskReminderRepeatRule
    @State private var escalateBlockedOrOverdue: Bool
    @State private var scheduledDiscussions: [TaskLinkedDiscussionMeeting]
    @State private var contextNotes: String
    @State private var showDiscussionSheet = false
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var error: String?

    public init(
        task: WorkspaceTaskRecord,
        syncController: WorkspaceTaskSyncController? = nil,
        knownEpics: [(key: String, title: String)] = [],
        onSave: @escaping @MainActor (TaskDetailEditPayload) async -> Bool,
        onDelete: (@MainActor () async -> Bool)? = nil,
        onOpenMeeting: ((UUID) -> Void)? = nil
    ) {
        self.task = task
        self.syncController = syncController
        self.knownEpics = knownEpics
        self.onSave = onSave
        self.onDelete = onDelete
        self.onOpenMeeting = onOpenMeeting
        _text = State(initialValue: task.text)
        _owner = State(initialValue: task.owner)
        _status = State(initialValue: task.done ? .done : task.extended.workflowStatus)
        _issueKind = State(initialValue: task.extended.issueKind)
        _parentEpicKey = State(initialValue: task.extended.parentEpicKey ?? "")
        _hasPriority = State(initialValue: task.extended.priority != nil)
        _priority = State(initialValue: task.extended.priority ?? .medium)
        let parsedDue = Self.dateFromDayString(task.dueDay) ?? task.dueAt
        _hasDueDay = State(initialValue: parsedDue != nil)
        _dueDate = State(initialValue: parsedDue ?? Date())

        let existingRule = task.extended.reminderRule
        let initialEnabled = (existingRule?.isEnabled == true) || task.reminderAt != nil
        _hasReminder = State(initialValue: initialEnabled)
        _triggerMode = State(initialValue: existingRule?.triggerMode ?? .atSpecificTime)
        _customReminderDate = State(initialValue: existingRule?.customDate ?? task.reminderAt ?? Date().addingTimeInterval(3600))
        let hour = existingRule?.hourOfDay ?? 9
        let minute = existingRule?.minuteOfHour ?? 0
        _reminderTimeOfDay = State(initialValue: Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date())
        _offsetMinutesBefore = State(initialValue: existingRule?.offsetMinutesBefore ?? 60)
        _repeatRule = State(initialValue: existingRule?.repeatRule ?? .none)
        _escalateBlockedOrOverdue = State(initialValue: existingRule?.escalateWhenBlockedOrOverdue ?? false)
        _scheduledDiscussions = State(initialValue: task.extended.scheduledDiscussions)
        _contextNotes = State(initialValue: task.extended.contextNotes)
    }

    private var currentRuleDraft: TaskReminderRule? {
        guard hasReminder else { return nil }
        let hm = Calendar.current.dateComponents([.hour, .minute], from: reminderTimeOfDay)
        return TaskReminderRule(
            isEnabled: true,
            triggerMode: triggerMode,
            customDate: customReminderDate,
            hourOfDay: hm.hour ?? 9,
            minuteOfHour: hm.minute ?? 0,
            offsetMinutesBefore: offsetMinutesBefore,
            repeatRule: repeatRule,
            escalateWhenBlockedOrOverdue: escalateBlockedOrOverdue
        )
    }

    private var computedNextAlert: Date? {
        let dueStr = hasDueDay ? Self.dayString(from: dueDate) : nil
        return currentRuleDraft?.nextFireDate(
            after: Date(),
            dueDay: dueStr,
            dueAt: task.dueAt,
            status: status,
            done: status.isTerminalDone,
            scheduledDiscussions: scheduledDiscussions
        )
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section(L("Task")) {
                    TextField(L("What needs to be done?"), text: $text, axis: .vertical)
                    TextField(L("Owner"), text: $owner)
                    Picker(L("Issue Type"), selection: $issueKind) {
                        ForEach(TaskIssueKind.allCases) { kind in
                            Label(kind.localizedTitle, systemImage: kind.systemImage).tag(kind)
                        }
                    }
                    if issueKind != .epic {
                        HStack {
                            TextField(L("Parent Epic Key (e.g. SDBCTO-10)"), text: $parentEpicKey)
                                #if os(iOS)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                #endif
                            if !knownEpics.isEmpty {
                                Menu(L("Epics")) {
                                    Button(L("None")) { parentEpicKey = "" }
                                    ForEach(knownEpics, id: \.key) { epic in
                                        Button("\(epic.key) · \(epic.title)") {
                                            parentEpicKey = epic.key
                                        }
                                    }
                                }
                                .font(.caption)
                            }
                        }
                    }
                    Picker(L("Status"), selection: $status) {
                        ForEach(TaskWorkflowStatus.allCases) { s in
                            Label(s.localizedTitle, systemImage: s.systemImage).tag(s)
                        }
                    }
                    Toggle(L("Set priority"), isOn: $hasPriority)
                    if hasPriority {
                        Picker(L("Priority"), selection: $priority) {
                            ForEach(TaskPriorityLevel.allCases) { p in
                                Text(p.localizedTitle).tag(p)
                            }
                        }
                    }
                    Toggle(L("Set due date"), isOn: $hasDueDay)
                    if hasDueDay {
                        DatePicker(L("Due Date"), selection: $dueDate, displayedComponents: [.date])
                    }
                }

                reminderRulesSection
                discussionsSection

                Section(L("Extended Context")) {
                    TextEditor(text: $contextNotes)
                        .frame(minHeight: 110)
                    Text(L("Context from subsequent meetings and external trackers accumulates here and is included when syncing to Jira or Reminders."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !task.extended.externalBindings.isEmpty || syncController?.preferences.anyProviderEnabled == true {
                    Section(L("External Sync")) {
                        ForEach(task.extended.externalBindings) { binding in
                            HStack {
                                Label(binding.externalKey ?? binding.provider.localizedTitle, systemImage: binding.provider == .jira ? "link.circle.fill" : "checklist")
                                Spacer()
                                if let remoteStatus = binding.remoteStatus {
                                    Text(remoteStatus)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let urlString = binding.externalURL, let url = URL(string: urlString) {
                                    Button(L("Open")) { openURL(url) }
                                        .font(.caption)
                                }
                            }
                        }
                        if let syncController, syncController.preferences.anyProviderEnabled {
                            Button {
                                Task {
                                    await syncController.runSync(explicitTaskIDs: [task.id])
                                    dismiss()
                                }
                            } label: {
                                Label(L("Sync This Task Now…"), systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                    }
                }

                if !task.extended.contextHistory.isEmpty {
                    Section(L("Cross-Meeting Timeline (%ld)", task.extended.contextHistory.count)) {
                        ForEach(task.extended.contextHistory.reversed()) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(entry.meetingTitle)
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Text(entry.observedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let next = entry.updatedStatus {
                                    let label = entry.previousStatus.map { "\($0.localizedTitle) → \(next.localizedTitle)" } ?? next.localizedTitle
                                    Text(label)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(Color.accentColor)
                                }
                                Text(entry.note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let quote = entry.evidenceQuote, !quote.isEmpty {
                                    Text("“\(quote)”")
                                        .font(.caption2)
                                        .italic()
                                        .foregroundStyle(.secondary)
                                }
                                if let sid = entry.sessionID,
                                   sid != TaskExtendedMetadata.externalImportsSessionID,
                                   let onOpenMeeting {
                                    Button(L("Open Meeting")) {
                                        dismiss()
                                        onOpenMeeting(sid)
                                    }
                                    .font(.caption2)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if onDelete != nil {
                    Section {
                        Button(L("Delete task"), role: .destructive) { confirmingDelete = true }
                    }
                }

                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .disabled(saving)
            .navigationTitle(issueKind == .epic ? L("Epic Details") : L("Task Details"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save")) {
                        saving = true
                        error = nil
                        Task {
                            let dueStr = hasDueDay ? Self.dayString(from: dueDate) : nil
                            let rule = currentRuleDraft
                            let nextAlert = rule?.nextFireDate(
                                after: Date(),
                                dueDay: dueStr,
                                dueAt: task.dueAt,
                                status: status,
                                done: status.isTerminalDone,
                                scheduledDiscussions: scheduledDiscussions
                            )
                            let cleanEpic = parentEpicKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                            let payload = TaskDetailEditPayload(
                                text: text,
                                owner: owner,
                                status: status,
                                priority: hasPriority ? priority : nil,
                                issueKind: issueKind,
                                parentEpicKey: issueKind == .epic || cleanEpic.isEmpty ? nil : cleanEpic,
                                dueDay: dueStr,
                                reminderAt: nextAlert,
                                reminderRule: rule,
                                scheduledDiscussions: scheduledDiscussions,
                                contextNotes: contextNotes
                            )
                            let ok = await onSave(payload)
                            if ok { dismiss() } else { saving = false; error = L("Could not save task changes.") }
                        }
                    }
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showDiscussionSheet) {
                TaskDiscussionMeetingSheet(task: task, syncController: syncController) { linked, addPreReminder in
                    if !scheduledDiscussions.contains(where: {
                        $0.id == linked.id ||
                            (linked.calendarEventIdentifier != nil && $0.calendarEventIdentifier == linked.calendarEventIdentifier)
                    }) {
                        scheduledDiscussions.append(linked)
                        scheduledDiscussions.sort { $0.startAt < $1.startAt }
                    }
                    if addPreReminder {
                        hasReminder = true
                        triggerMode = .beforeLinkedMeeting
                        offsetMinutesBefore = 15
                    }
                }
            }
            .confirmationDialog(L("Delete task"), isPresented: $confirmingDelete, titleVisibility: .visible) {
                if let onDelete {
                    Button(L("Delete task"), role: .destructive) {
                        saving = true
                        Task {
                            if await onDelete() { dismiss() } else { saving = false }
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
        #endif
    }

    private var reminderRulesSection: some View {
        Section(L("Reminder & Rules")) {
            Toggle(L("Enable task reminder"), isOn: $hasReminder)
            if hasReminder {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button(L("+1 hour")) { applyPreset(.inOneHour()) }
                        Button(L("Tonight 18:00")) { applyPreset(.tonight()) }
                        Button(L("Tomorrow 09:00")) { applyPreset(.tomorrowMorning()) }
                        Button(L("Next Mon 09:00")) { applyPreset(.nextMondayMorning()) }
                        if hasDueDay {
                            Button(L("1d before due")) { applyPreset(.oneDayBeforeDue()) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Picker(L("Trigger"), selection: $triggerMode) {
                    ForEach(TaskReminderTriggerMode.allCases) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }

                switch triggerMode {
                case .atSpecificTime:
                    DatePicker(L("Date & Time"), selection: $customReminderDate, displayedComponents: [.date, .hourAndMinute])
                case .onDueDate:
                    DatePicker(L("Alert Time"), selection: $reminderTimeOfDay, displayedComponents: [.hourAndMinute])
                    if !hasDueDay {
                        Text(L("Set a due date above for this trigger to fire."))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                case .beforeDue:
                    Picker(L("Lead Time"), selection: $offsetMinutesBefore) {
                        Text(L("15 minutes")).tag(15)
                        Text(L("30 minutes")).tag(30)
                        Text(L("1 hour")).tag(60)
                        Text(L("3 hours")).tag(180)
                        Text(L("1 day")).tag(1440)
                        Text(L("2 days")).tag(2880)
                    }
                    if !hasDueDay {
                        Text(L("Set a due date above for this trigger to fire."))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                case .beforeLinkedMeeting:
                    Picker(L("Lead Time"), selection: $offsetMinutesBefore) {
                        Text(L("10 minutes")).tag(10)
                        Text(L("15 minutes")).tag(15)
                        Text(L("30 minutes")).tag(30)
                        Text(L("1 hour")).tag(60)
                    }
                    if scheduledDiscussions.isEmpty {
                        Text(L("Link or schedule a discussion meeting below."))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Picker(L("Repeat Rule"), selection: $repeatRule) {
                    ForEach(TaskReminderRepeatRule.allCases) { r in
                        Text(r.localizedTitle).tag(r)
                    }
                }

                Toggle(L("Daily nudge if blocked or overdue"), isOn: $escalateBlockedOrOverdue)

                HStack {
                    if let next = computedNextAlert {
                        Label(
                            L("Next alert: %@", next.formatted(date: .abbreviated, time: .shortened)),
                            systemImage: "bell.badge.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    } else {
                        Text(L("No upcoming alert under current conditions."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Clear"), role: .destructive) {
                        hasReminder = false
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var discussionsSection: some View {
        Section(L("Discussion Meetings & Calendar")) {
            ForEach(scheduledDiscussions) { meeting in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting.title)
                            .font(.body)
                        Text(meeting.startAt.formatted(date: .abbreviated, time: .shortened) + (meeting.calendarTitle.map { " · \($0)" } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let urlString = meeting.meetingURL, let url = URL(string: urlString) {
                        Button(L("Open")) { openURL(url) }
                            .font(.caption)
                    }
                    Button {
                        scheduledDiscussions.removeAll { $0.id == meeting.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                showDiscussionSheet = true
            } label: {
                Label(L("Schedule / Link Discussion Meeting…"), systemImage: "calendar.badge.plus")
            }
        }
    }

    private func applyPreset(_ rule: TaskReminderRule) {
        hasReminder = true
        triggerMode = rule.triggerMode
        if let custom = rule.customDate {
            customReminderDate = custom
        }
        reminderTimeOfDay = Calendar.current.date(bySettingHour: rule.hourOfDay, minute: rule.minuteOfHour, second: 0, of: Date()) ?? reminderTimeOfDay
        offsetMinutesBefore = rule.offsetMinutesBefore
        repeatRule = rule.repeatRule
    }

    private static func dayString(from date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 2026, comps.month ?? 1, comps.day ?? 1)
    }

    private static func dateFromDayString(_ value: String?) -> Date? {
        guard let value else { return nil }
        let parts = value.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return Calendar.current.date(from: DateComponents(year: y, month: m, day: d))
    }
}
