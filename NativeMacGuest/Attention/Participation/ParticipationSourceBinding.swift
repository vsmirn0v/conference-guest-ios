import Foundation
import NaturalLanguage

struct ParticipationSourceBinding: Sendable {
    let context: ParticipationKnowledgeReviewContext?
    let approvals: [ParticipationKnowledgeApproval]
    let scope = ParticipationKnowledgeScope()

    static var empty: Self { Self() }

    private init() {
        context = nil
        approvals = []
    }

    init?(context: ParticipationKnowledgeReviewContext?, approvals: [ParticipationKnowledgeApproval]) {
        guard approvals.count <= 2, Set(approvals.map(\.id)).count == approvals.count else { return nil }
        if !approvals.isEmpty {
            guard let context, context.matches(context),
                  approvals.allSatisfy({ $0.grant.audience == context.audience
                      && $0.grant.allowedProcessors == [context.processorID]
                      && $0.grant.expiresAt == context.expiresAt }) else { return nil }
        }
        self.context = context
        self.approvals = approvals
        for approval in approvals { scope.approve(approval.grant) }
    }

    var revisions: [String] { approvals.map { $0.grant.source.revision }.sorted() }

    func read(matching query: String? = nil) throws -> [ParticipationSource] {
        guard !approvals.isEmpty else { return [] }
        guard let context, context.matches(context) else { throw ParticipationKnowledgeError.expired }
        return try approvals.compactMap { approval in
            let snapshot = try approval.read(scope: scope, audience: context.audience, processor: context.processorID)
            let excerpt = if let query { Self.relevantExcerpt(in: snapshot.markdown, matching: query) }
                else { String(snapshot.markdown.prefix(1_200)) }
            guard let excerpt else { return nil }
            return .init(id: "source:" + approval.id.uuidString, title: String(snapshot.title.prefix(140)),
                text: excerpt, revision: snapshot.revision)
        }
    }

    /// Rank contiguous, overlapping excerpts by their shared query terms.
    /// Prefer line and word boundaries so a fixed width does not split evidence.
    static func relevantExcerpt(in markdown: String, matching query: String) -> String? {
        let terms = words(query)
        guard !terms.isEmpty else { return nil }
        var sections: [(text: String, matches: Set<String>)] = []
        var frequency: [String: Int] = [:]
        var start = markdown.startIndex
        while start < markdown.endIndex {
            let limit = markdown.index(start, offsetBy: 1_200, limitedBy: markdown.endIndex) ?? markdown.endIndex
            let midpoint = markdown.index(start, offsetBy: 600, limitedBy: limit) ?? limit
            let trailingHalf = markdown[midpoint..<limit]
            let boundary = trailingHalf.lastIndex(of: "\n") ?? trailingHalf.lastIndex(where: \.isWhitespace)
            let end = limit < markdown.endIndex ? boundary.map { markdown.index(after: $0) } ?? limit : limit
            let text = String(markdown[start..<end])
            let matches = words(text).intersection(terms)
            if !matches.isEmpty {
                sections.append((text, matches))
                for term in matches { frequency[term, default: 0] += 1 }
            }
            if end == markdown.endIndex { break }
            let overlap = markdown.index(end, offsetBy: -350)
            let nextBoundary = markdown[overlap..<end].dropLast().firstIndex(where: \.isWhitespace)
            start = nextBoundary.map { markdown.index(after: $0) } ?? overlap
        }
        return sections.max { left, right in
            func score(_ matches: Set<String>) -> Double {
                matches.sorted().reduce(0) { $0 + 1 / Double(frequency[$1, default: 1]) }
            }
            return score(left.matches) < score(right.matches)
        }?.text
    }

    private static func words(_ text: String) -> Set<String> {
        let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "und"))
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalized
        return Set(tokenizer.tokens(for: normalized.startIndex..<normalized.endIndex).map { String(normalized[$0]) })
    }

    func revokeAll() {
        for approval in approvals { scope.revoke(approval.id) }
    }
}
