import Foundation
import Security

public enum TaskSyncApprovalMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case reviewBeforeApply = "review_before_apply"
    case autoApply = "auto_apply"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .reviewBeforeApply: return L("Preview & review packet")
        case .autoApply: return L("Auto-apply without review")
        }
    }
}

public enum TaskSyncRoleMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case personalOwner = "personal_owner"
    case managerLead = "manager_lead"
    case custom

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .personalOwner: return L("Personal Mode (My Tasks Only)")
        case .managerLead: return L("Manager / Lead Mode (Team & Epics)")
        case .custom: return L("Custom Scope")
        }
    }

    public var subtitle: String {
        switch self {
        case .personalOwner:
            return L("Tracks context and updates statuses only on tasks assigned to you.")
        case .managerLead:
            return L("Updates discovered team tasks, Jira Epics, and cross-meeting context for everyone.")
        case .custom:
            return L("Choose specific team members or manually selected tasks to sync.")
        }
    }
}

public enum TaskSyncScopeMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case myTasksOnly = "my_tasks_only"
    case selectedPeople = "selected_people"
    case selectedTasksOnly = "selected_tasks_only"
    case allTasks = "all_tasks"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .myTasksOnly: return L("Assigned to me")
        case .selectedPeople: return L("Selected people")
        case .selectedTasksOnly: return L("Only manually selected tasks")
        case .allTasks: return L("All tasks")
        }
    }
}

public enum TaskSyncDirection: String, Codable, CaseIterable, Sendable, Identifiable {
    case bidirectional
    case exportOnly = "export_only"
    case importOnly = "import_only"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .bidirectional: return L("Two-way (export & import)")
        case .exportOnly: return L("Push local tasks only")
        case .importOnly: return L("Import from external only")
        }
    }

    public var includesExport: Bool { self != .importOnly }
    public var includesImport: Bool { self != .exportOnly }
}

public enum JiraAuthMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case personalAccessToken = "pat"
    case webSession = "web_session"
    case basicAuth = "basic"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .personalAccessToken: return L("Personal Access Token")
        case .webSession: return L("Web Sign-In Session")
        case .basicAuth: return L("Username & Token / Password")
        }
    }
}

public enum JiraExecutionRoute: String, Codable, CaseIterable, Sendable, Identifiable {
    case directWithMacFallback = "direct_or_mac_handover"
    case alwaysViaMac = "always_via_mac"
    case directOnly = "direct_only"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .directWithMacFallback: return L("Direct, hand over to Mac if unreachable")
        case .alwaysViaMac: return L("Always hand over to Mac (VPN / Intranet)")
        case .directOnly: return L("Direct from this device only")
        }
    }
}

public struct JiraConnectionSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var baseURL: String
    public var projectKey: String
    public var defaultIssueType: String
    public var importJQL: String
    public var authMode: JiraAuthMode
    public var usernameOrEmail: String
    public var postMeetingUpdatesAsComments: Bool
    public var executionRoute: JiraExecutionRoute
    public var cachedProjectUsers: [JiraUserContact]

    public init(
        enabled: Bool = false,
        baseURL: String = "",
        projectKey: String = "",
        defaultIssueType: String = "Task",
        importJQL: String = "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC",
        authMode: JiraAuthMode = .personalAccessToken,
        usernameOrEmail: String = "",
        postMeetingUpdatesAsComments: Bool = true,
        executionRoute: JiraExecutionRoute = .directWithMacFallback,
        cachedProjectUsers: [JiraUserContact] = []
    ) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.projectKey = projectKey
        self.defaultIssueType = defaultIssueType
        self.importJQL = importJQL
        self.authMode = authMode
        self.usernameOrEmail = usernameOrEmail
        self.postMeetingUpdatesAsComments = postMeetingUpdatesAsComments
        self.executionRoute = executionRoute
        self.cachedProjectUsers = Array(cachedProjectUsers.prefix(150))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        projectKey = try c.decodeIfPresent(String.self, forKey: .projectKey) ?? ""
        defaultIssueType = try c.decodeIfPresent(String.self, forKey: .defaultIssueType) ?? "Task"
        importJQL = try c.decodeIfPresent(String.self, forKey: .importJQL) ?? "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC"
        authMode = try c.decodeIfPresent(JiraAuthMode.self, forKey: .authMode) ?? .personalAccessToken
        usernameOrEmail = try c.decodeIfPresent(String.self, forKey: .usernameOrEmail) ?? ""
        postMeetingUpdatesAsComments = try c.decodeIfPresent(Bool.self, forKey: .postMeetingUpdatesAsComments) ?? true
        executionRoute = try c.decodeIfPresent(JiraExecutionRoute.self, forKey: .executionRoute) ?? .directWithMacFallback
        cachedProjectUsers = Array((try c.decodeIfPresent([JiraUserContact].self, forKey: .cachedProjectUsers) ?? []).prefix(150))
    }

    public var normalizedBaseURL: URL? {
        var raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        guard !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty else { return nil }
        let isLoopback = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (scheme == "http" && isLoopback) else { return nil }
        return url
    }

    public var isCloudHost: Bool {
        normalizedBaseURL?.host?.lowercased().hasSuffix(".atlassian.net") == true
    }

    public var cleanProjectKey: String {
        projectKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

public struct RemindersConnectionSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var listIdentifier: String?
    public var listTitle: String
    public var importIncompleteReminders: Bool
    public var onlyMyTasksInReminders: Bool

    public init(
        enabled: Bool = false,
        listIdentifier: String? = nil,
        listTitle: String = "Rock'N'Roll",
        importIncompleteReminders: Bool = true,
        onlyMyTasksInReminders: Bool = true
    ) {
        self.enabled = enabled
        self.listIdentifier = listIdentifier
        self.listTitle = listTitle
        self.importIncompleteReminders = importIncompleteReminders
        self.onlyMyTasksInReminders = onlyMyTasksInReminders
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        listIdentifier = try c.decodeIfPresent(String.self, forKey: .listIdentifier)
        listTitle = try c.decodeIfPresent(String.self, forKey: .listTitle) ?? "Rock'N'Roll"
        importIncompleteReminders = try c.decodeIfPresent(Bool.self, forKey: .importIncompleteReminders) ?? true
        onlyMyTasksInReminders = try c.decodeIfPresent(Bool.self, forKey: .onlyMyTasksInReminders) ?? true
    }
}

public struct TaskSyncPreferences: Codable, Equatable, Sendable {
    public static let syncScopeKey = "global:taskSyncPreferences"

    public var roleMode: TaskSyncRoleMode
    public var approvalMode: TaskSyncApprovalMode
    public var autoSyncAfterMeetingOutcome: Bool
    public var scopeMode: TaskSyncScopeMode
    public var selectedPersonKeys: [String]
    public var direction: TaskSyncDirection
    public var jira: JiraConnectionSettings
    public var reminders: RemindersConnectionSettings
    public var contactMappings: [ContactIdentityMapping]

    public var effectiveScopeMode: TaskSyncScopeMode {
        switch roleMode {
        case .personalOwner: return .myTasksOnly
        case .managerLead: return .allTasks
        case .custom: return scopeMode
        }
    }

    public init(
        roleMode: TaskSyncRoleMode = .personalOwner,
        approvalMode: TaskSyncApprovalMode = .reviewBeforeApply,
        autoSyncAfterMeetingOutcome: Bool = false,
        scopeMode: TaskSyncScopeMode = .myTasksOnly,
        selectedPersonKeys: [String] = [],
        direction: TaskSyncDirection = .bidirectional,
        jira: JiraConnectionSettings = .init(),
        reminders: RemindersConnectionSettings = .init(),
        contactMappings: [ContactIdentityMapping] = []
    ) {
        self.roleMode = roleMode
        self.approvalMode = approvalMode
        self.autoSyncAfterMeetingOutcome = autoSyncAfterMeetingOutcome
        self.scopeMode = scopeMode
        self.selectedPersonKeys = selectedPersonKeys
        self.direction = direction
        self.jira = jira
        self.reminders = reminders
        self.contactMappings = contactMappings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        approvalMode = try c.decodeIfPresent(TaskSyncApprovalMode.self, forKey: .approvalMode) ?? .reviewBeforeApply
        autoSyncAfterMeetingOutcome = try c.decodeIfPresent(Bool.self, forKey: .autoSyncAfterMeetingOutcome) ?? false
        let decodedScope = try c.decodeIfPresent(TaskSyncScopeMode.self, forKey: .scopeMode) ?? .myTasksOnly
        scopeMode = decodedScope
        if let explicitRole = try c.decodeIfPresent(TaskSyncRoleMode.self, forKey: .roleMode) {
            roleMode = explicitRole
        } else {
            switch decodedScope {
            case .myTasksOnly: roleMode = .personalOwner
            case .allTasks: roleMode = .managerLead
            case .selectedPeople, .selectedTasksOnly: roleMode = .custom
            }
        }
        selectedPersonKeys = try c.decodeIfPresent([String].self, forKey: .selectedPersonKeys) ?? []
        direction = try c.decodeIfPresent(TaskSyncDirection.self, forKey: .direction) ?? .bidirectional
        jira = try c.decodeIfPresent(JiraConnectionSettings.self, forKey: .jira) ?? .init()
        reminders = try c.decodeIfPresent(RemindersConnectionSettings.self, forKey: .reminders) ?? .init()
        contactMappings = try c.decodeIfPresent([ContactIdentityMapping].self, forKey: .contactMappings) ?? []
    }

    public var anyProviderEnabled: Bool {
        jira.enabled || reminders.enabled
    }

    public func encodeSyncJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decodeSyncJSON(_ raw: String) -> TaskSyncPreferences? {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = raw.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(TaskSyncPreferences.self, from: data)
    }
}

public enum TaskIntegrationSecretKind: String, Sendable {
    case jiraPersonalAccessToken = "jira.pat"
    case jiraBasicSecret = "jira.basic"
    case jiraSessionCookies = "jira.cookies"
}

public struct TaskIntegrationKeychain: Sendable {
    public var service: String

    public init(service: String = "dev.vsmirn0v.conferenceguest.tasksync") {
        self.service = service
    }

    private func query(hostKey: String, kind: TaskIntegrationSecretKind) -> [String: Any] {
        let cleanHost = hostKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let account = "\(kind.rawValue):\(cleanHost.isEmpty ? "default" : cleanHost)"
        var result: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        #if os(macOS)
        result[kSecUseDataProtectionKeychain as String] = true
        #endif
        return result
    }

    public func read(hostKey: String, kind: TaskIntegrationSecretKind) -> String? {
        var item = query(hostKey: hostKey, kind: kind)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func write(_ value: String, hostKey: String, kind: TaskIntegrationSecretKind) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return delete(hostKey: hostKey, kind: kind) }
        let data = Data(clean.utf8)
        let q = query(hostKey: hostKey, kind: kind)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    @discardableResult
    public func delete(hostKey: String, kind: TaskIntegrationSecretKind) -> Bool {
        let status = SecItemDelete(query(hostKey: hostKey, kind: kind) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
