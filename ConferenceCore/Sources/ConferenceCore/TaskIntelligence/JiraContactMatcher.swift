import Foundation

public struct AppContactPerson: Codable, Equatable, Identifiable, Sendable {
    public var key: String
    public var displayName: String
    public var aliases: [String]
    public var isCurrentUser: Bool
    public var email: String?

    public var id: String { key }

    public init(
        key: String? = nil,
        displayName: String,
        aliases: [String] = [],
        isCurrentUser: Bool = false,
        email: String? = nil
    ) {
        let cleaned = JiraContactMatcher.cleanedName(displayName)
        self.key = key ?? JiraContactMatcher.normalizedKey(cleaned)
        self.displayName = cleaned.isEmpty ? displayName : cleaned
        self.aliases = aliases
        self.isCurrentUser = isCurrentUser
        self.email = email
    }
}

public struct JiraUserContact: Codable, Equatable, Identifiable, Sendable {
    /// Jira Data Center uses `name` as identifier; Jira Cloud uses `accountId`.
    public var identifier: String
    public var username: String?
    public var accountId: String?
    public var displayName: String
    public var emailAddress: String?
    public var isServerOrDC: Bool

    public var id: String { identifier }

    public init(
        identifier: String,
        username: String? = nil,
        accountId: String? = nil,
        displayName: String,
        emailAddress: String? = nil,
        isServerOrDC: Bool
    ) {
        self.identifier = identifier
        self.username = username
        self.accountId = accountId
        self.displayName = displayName
        self.emailAddress = emailAddress
        self.isServerOrDC = isServerOrDC
    }

    public func assigneePayload() -> [String: Any] {
        if isServerOrDC || accountId == nil {
            return ["name": username ?? identifier]
        }
        return ["accountId": accountId ?? identifier]
    }
}

public struct ContactIdentityMapping: Codable, Equatable, Identifiable, Sendable {
    public var appContactKey: String
    public var appDisplayName: String
    public var jiraIdentifier: String
    public var jiraUsername: String?
    public var jiraAccountId: String?
    public var jiraDisplayName: String
    public var jiraEmail: String?
    public var isServerOrDC: Bool
    public var isConfirmedByUser: Bool
    public var confidence: Double
    public var updatedAt: Date

    public var id: String { appContactKey }

    public var asJiraContact: JiraUserContact {
        JiraUserContact(
            identifier: jiraIdentifier,
            username: jiraUsername,
            accountId: jiraAccountId,
            displayName: jiraDisplayName,
            emailAddress: jiraEmail,
            isServerOrDC: isServerOrDC
        )
    }

    public init(
        appContactKey: String,
        appDisplayName: String,
        jiraIdentifier: String,
        jiraUsername: String? = nil,
        jiraAccountId: String? = nil,
        jiraDisplayName: String,
        jiraEmail: String? = nil,
        isServerOrDC: Bool,
        isConfirmedByUser: Bool = false,
        confidence: Double = 1.0,
        updatedAt: Date = Date()
    ) {
        self.appContactKey = appContactKey
        self.appDisplayName = appDisplayName
        self.jiraIdentifier = jiraIdentifier
        self.jiraUsername = jiraUsername
        self.jiraAccountId = jiraAccountId
        self.jiraDisplayName = jiraDisplayName
        self.jiraEmail = jiraEmail
        self.isServerOrDC = isServerOrDC
        self.isConfirmedByUser = isConfirmedByUser
        self.confidence = confidence
        self.updatedAt = updatedAt
    }

    public init(appContact: AppContactPerson, jiraUser: JiraUserContact, confirmed: Bool, confidence: Double, updatedAt: Date = Date()) {
        self.appContactKey = appContact.key
        self.appDisplayName = appContact.displayName
        self.jiraIdentifier = jiraUser.identifier
        self.jiraUsername = jiraUser.username
        self.jiraAccountId = jiraUser.accountId
        self.jiraDisplayName = jiraUser.displayName
        self.jiraEmail = jiraUser.emailAddress
        self.isServerOrDC = jiraUser.isServerOrDC
        self.isConfirmedByUser = confirmed
        self.confidence = confidence
        self.updatedAt = updatedAt
    }
}

public struct ContactMatchSuggestion: Identifiable, Equatable, Sendable {
    public var id: String { "\(appContact.key)->\(jiraUser.identifier)" }
    public let appContact: AppContactPerson
    public let jiraUser: JiraUserContact
    public let confidence: Double
}

public enum JiraContactMatcher {
    private static let cyrillicToLatinMap: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
        "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
        "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
        "і": "i", "ї": "yi", "є": "ye", "ґ": "g"
    ]

    public static func cleanedName(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func normalizedKey(_ raw: String) -> String {
        cleanedName(raw).workspaceFolded
    }

    public static func transliterateCyrillicToLatin(_ text: String) -> String {
        let folded = text.workspaceFolded
        var out = ""
        out.reserveCapacity(folded.count * 2)
        for ch in folded {
            if let mapped = cyrillicToLatinMap[ch] {
                out.append(mapped)
            } else {
                out.append(ch)
            }
        }
        return out
    }

    public static func nameVariants(_ raw: String) -> [String] {
        let base = normalizedKey(raw)
        let latin = transliterateCyrillicToLatin(base)
        // Also normalize common Russian/English spelling variants (ii/iy/y, x/ks).
        let compact = latin
            .replacingOccurrences(of: "iy", with: "i")
            .replacingOccurrences(of: "ii", with: "i")
            .replacingOccurrences(of: "yy", with: "y")
            .replacingOccurrences(of: "kh", with: "h")
        return Array(Set([base, latin, compact].filter { !$0.isEmpty }))
    }

    public static func tokens(_ raw: String) -> [String] {
        transliterateCyrillicToLatin(raw)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    public static func isCurrentUserOwner(_ owner: String, myAliases: [String]) -> Bool {
        let cleanOwner = normalizedKey(owner)
        guard !cleanOwner.isEmpty else { return false }
        let aliasKeys = Set(myAliases.map(normalizedKey)).filter { !$0.isEmpty }
        guard !aliasKeys.isEmpty else { return false }
        if aliasKeys.contains(cleanOwner) { return true }
        return matchScore(name: owner, aliases: [], candidateNames: myAliases) >= 0.86
    }

    public static func areCompatibleOwners(_ lhs: String, _ rhs: String, myAliases: [String] = []) -> Bool {
        let cleanL = normalizedKey(lhs)
        let cleanR = normalizedKey(rhs)
        guard !cleanL.isEmpty && !cleanR.isEmpty else { return true }
        if cleanL == cleanR { return true }
        let aliasKeys = Set(myAliases.map(normalizedKey))
        if aliasKeys.contains(cleanL) && aliasKeys.contains(cleanR) { return true }
        return matchScore(name: lhs, aliases: [], candidateNames: [rhs]) >= 0.78
    }

    public static func matchScore(
        name: String,
        aliases: [String] = [],
        email: String? = nil,
        candidateNames: [String],
        candidateEmail: String? = nil,
        candidateUsername: String? = nil
    ) -> Double {
        let sources = ([name] + aliases).map(cleanedName).filter { !$0.isEmpty }
        let targets = candidateNames.map(cleanedName).filter { !$0.isEmpty }
        guard !sources.isEmpty, !targets.isEmpty else { return 0 }

        if let e1 = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           let e2 = candidateEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !e1.isEmpty, e1 == e2 {
            return 1.0
        }

        var best = 0.0
        for source in sources {
            let sourceVariants = Set(nameVariants(source))
            let sourceTokens = Set(tokens(source))
            let emailLocalSource = email?.split(separator: "@").first.map { String($0).lowercased() }

            for target in targets {
                let targetVariants = Set(nameVariants(target))
                if !sourceVariants.isDisjoint(with: targetVariants) {
                    best = max(best, source.workspaceFolded == target.workspaceFolded ? 1.0 : 0.96)
                    continue
                }
                let targetTokens = Set(tokens(target))
                if !sourceTokens.isEmpty && !targetTokens.isEmpty {
                    let intersection = sourceTokens.intersection(targetTokens)
                    if sourceTokens == targetTokens {
                        best = max(best, 0.94)
                        continue
                    }
                    // Handle "First Last" vs "Last First Middle" or patronymic included in Jira displayName.
                    if sourceTokens.count >= 2 && (sourceTokens.isSubset(of: targetTokens) || targetTokens.isSubset(of: sourceTokens)) {
                        best = max(best, 0.92)
                        continue
                    }
                    if intersection.count >= 2 {
                        best = max(best, 0.90)
                        continue
                    }
                    // Initial + surname match, e.g. "V. Smirnov" or "В. Смирнов" vs "Vitalii Smirnov" or "v.smirnov".
                    if sourceTokens.count == 2 && targetTokens.count >= 2 {
                        let sArr = tokens(source)
                        let tArr = tokens(target)
                        if sArr.count == 2,
                           ((sArr[0].count == 1 && tArr.contains(where: { $0 == sArr[1] }) && tArr.contains(where: { $0.hasPrefix(sArr[0]) }))
                            || (sArr[1].count == 1 && tArr.contains(where: { $0 == sArr[0] }) && tArr.contains(where: { $0.hasPrefix(sArr[1]) }))) {
                            best = max(best, 0.87)
                        }
                    }
                    if intersection.count == 1 && (sourceTokens.count == 1 || targetTokens.count == 1) {
                        let single = intersection.first!
                        if single.count >= 4 {
                            best = max(best, 0.72)
                        }
                    }
                }
            }

            if let username = candidateUsername?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !username.isEmpty {
                let uTokens = tokens(username)
                let sArr = tokens(source)
                if let eLocal = emailLocalSource, !eLocal.isEmpty, eLocal == username {
                    best = max(best, 0.94)
                } else if sArr.count >= 2 {
                    let uJoined = uTokens.joined()
                    let firstInitialLast = String(sArr[0].prefix(1)) + sArr.last!
                    let lastFirstInitial = sArr.last! + String(sArr[0].prefix(1))
                    if uJoined == firstInitialLast || uJoined == lastFirstInitial || Set(uTokens) == Set(sArr) {
                        best = max(best, 0.88)
                    }
                }
            }

            if let emailPrefix = candidateEmail?.split(separator: "@").first.map({ String($0).lowercased() }),
               !emailPrefix.isEmpty {
                let eTokens = tokens(emailPrefix)
                let sArr = tokens(source)
                if sArr.count >= 2 {
                    let eJoined = eTokens.joined()
                    let firstInitialLast = String(sArr[0].prefix(1)) + sArr.last!
                    if eJoined == firstInitialLast || Set(eTokens) == Set(sArr) {
                        best = max(best, 0.86)
                    }
                }
            }
        }
        return best
    }

    public static func matchScore(appContact: AppContactPerson, jiraUser: JiraUserContact) -> Double {
        matchScore(
            name: appContact.displayName,
            aliases: appContact.aliases,
            email: appContact.email,
            candidateNames: [jiraUser.displayName, jiraUser.username].compactMap { $0 },
            candidateEmail: jiraUser.emailAddress,
            candidateUsername: jiraUser.username
        )
    }

    public static func reconcileMappings(
        appContacts: [AppContactPerson],
        jiraUsers: [JiraUserContact],
        existing: [ContactIdentityMapping],
        now: Date = Date()
    ) -> (mappings: [ContactIdentityMapping], suggestions: [ContactMatchSuggestion]) {
        var byAppKey = Dictionary(existing.map { ($0.appContactKey, $0) }, uniquingKeysWith: { a, b in
            a.isConfirmedByUser ? a : (b.isConfirmedByUser ? b : (a.updatedAt >= b.updatedAt ? a : b))
        })
        let validJiraIDs = Set(jiraUsers.map(\.identifier))
        var suggestions: [ContactMatchSuggestion] = []

        for contact in appContacts {
            if let current = byAppKey[contact.key], current.isConfirmedByUser {
                if let refreshed = jiraUsers.first(where: { $0.identifier == current.jiraIdentifier }) {
                    byAppKey[contact.key] = ContactIdentityMapping(
                        appContact: contact,
                        jiraUser: refreshed,
                        confirmed: true,
                        confidence: 1.0,
                        updatedAt: current.updatedAt
                    )
                }
                continue
            }
            if !jiraUsers.isEmpty,
               let current = byAppKey[contact.key],
               !validJiraIDs.contains(current.jiraIdentifier),
               !current.isConfirmedByUser {
                byAppKey.removeValue(forKey: contact.key)
            }
            let scored = jiraUsers
                .map { ($0, matchScore(appContact: contact, jiraUser: $0)) }
                .filter { $0.1 >= 0.55 }
                .sorted { lhs, rhs in
                    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                    return lhs.0.displayName.localizedCaseInsensitiveCompare(rhs.0.displayName) == .orderedAscending
                }
            guard let top = scored.first else { continue }
            let runnerUpScore = scored.dropFirst().first?.1 ?? 0
            if top.1 >= 0.86 && (top.1 - runnerUpScore >= 0.10 || scored.count == 1) {
                byAppKey[contact.key] = ContactIdentityMapping(
                    appContact: contact,
                    jiraUser: top.0,
                    confirmed: false,
                    confidence: top.1,
                    updatedAt: now
                )
            } else {
                for candidate in scored.prefix(3) {
                    suggestions.append(ContactMatchSuggestion(
                        appContact: contact,
                        jiraUser: candidate.0,
                        confidence: candidate.1
                    ))
                }
            }
        }

        let sorted = byAppKey.values.sorted {
            $0.appDisplayName.localizedCaseInsensitiveCompare($1.appDisplayName) == .orderedAscending
        }
        return (sorted, suggestions)
    }

    public static func resolveJiraUser(
        owner: String,
        myAliases: [String] = [],
        mappings: [ContactIdentityMapping],
        jiraUsers: [JiraUserContact] = []
    ) -> JiraUserContact? {
        let key = normalizedKey(owner)
        guard !key.isEmpty else { return nil }
        if let direct = mappings.first(where: { $0.appContactKey == key }) {
            return direct.asJiraContact
        }
        let aliasKeys = Set(myAliases.map(normalizedKey))
        if aliasKeys.contains(key),
           let aliasMapping = mappings.first(where: { aliasKeys.contains($0.appContactKey) }) {
            return aliasMapping.asJiraContact
        }
        guard !jiraUsers.isEmpty else { return nil }
        let contact = AppContactPerson(displayName: owner, aliases: aliasKeys.contains(key) ? myAliases : [])
        let scored = jiraUsers
            .map { ($0, matchScore(appContact: contact, jiraUser: $0)) }
            .filter { $0.1 >= 0.86 }
            .sorted { $0.1 > $1.1 }
        guard let top = scored.first else { return nil }
        let second = scored.dropFirst().first?.1 ?? 0
        return (scored.count == 1 || top.1 - second >= 0.10) ? top.0 : nil
    }
}
