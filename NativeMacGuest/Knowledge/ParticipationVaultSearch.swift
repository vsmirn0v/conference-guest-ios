import Foundation
import NaturalLanguage

/// Read-only lexical retrieval within one user-connected vault. Paths and file
/// identities stay local. The processor receives only ranked Markdown excerpts.
enum ParticipationVaultSearch {
    static let maxEntries = 2_000
    static let maxReads = 40
    static let maxMatches = 3
    static let byteLimit = 256 * 1_024

    struct Match: Sendable {
        let source: ParticipationSource
        let path: String
        let rootDevice: UInt64
        let rootInode: UInt64
        let fileDevice: UInt64
        let fileInode: UInt64

        init(_ snapshot: ParticipationKnowledgeSnapshot, excerpt: String) {
            path = snapshot.relativePath
            rootDevice = snapshot.rootDevice
            rootInode = snapshot.rootInode
            fileDevice = snapshot.fileDevice
            fileInode = snapshot.fileInode
            source = .init(id: "obsidian:" + ParticipationContext.digest(path),
                title: String(snapshot.title.prefix(140)), text: excerpt, revision: snapshot.revision)
        }

        func matches(_ snapshot: ParticipationKnowledgeSnapshot) -> Bool {
            rootDevice == snapshot.rootDevice && rootInode == snapshot.rootInode
                && fileDevice == snapshot.fileDevice && fileInode == snapshot.fileInode
                && source.revision == snapshot.revision
        }
    }

    private struct Candidate {
        let path: String
        let titleMatches: Set<String>
        let meetingMatches: Int
        let modified: Date
    }

    static func search(root: URL, query: [String], meetingTitle: String) -> [Match] {
        guard !query.isEmpty, !Task.isCancelled, root.isFileURL,
              let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .volumeIsLocalKey]),
              rootValues.isDirectory == true, rootValues.isSymbolicLink != true, rootValues.volumeIsLocal == true
        else { return [] }
        let folder = root.standardizedFileURL
        let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
            .fileSizeKey, .contentModificationDateKey, .volumeIsLocalKey]
        guard let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let queryTerms = Set(query)
        let meetingTerms = Set(queryWords(meetingTitle))
        var candidates: [Candidate] = []
        for _ in 0..<maxEntries {
            guard !Task.isCancelled, let file = entries.nextObject() as? URL else { break }
            guard let values = try? file.resourceValues(forKeys: keys) else {
                if file.hasDirectoryPath { entries.skipDescendants() }
                continue
            }
            if values.isDirectory == true && (values.isSymbolicLink == true || values.volumeIsLocal != true) {
                entries.skipDescendants()
            }
            guard values.isSymbolicLink != true, values.volumeIsLocal != false, values.isRegularFile == true,
                  let size = values.fileSize, (1...byteLimit).contains(size),
                  file.pathExtension.caseInsensitiveCompare("md") == .orderedSame else { continue }
            let standardized = file.standardizedFileURL.path
            guard standardized.hasPrefix(prefix) else { continue }
            let path = String(standardized.dropFirst(prefix.count))
            let pathTitle = (path as NSString).deletingPathExtension.replacingOccurrences(of: "/", with: " ")
            let pathTerms = Set(queryWords(pathTitle))
            candidates.append(.init(path: path, titleMatches: pathTerms.intersection(queryTerms),
                meetingMatches: pathTerms.intersection(meetingTerms).count,
                modified: values.contentModificationDate ?? .distantPast))
        }
        candidates.sort { left, right in
            if left.titleMatches.count != right.titleMatches.count { return left.titleMatches.count > right.titleMatches.count }
            if left.meetingMatches != right.meetingMatches { return left.meetingMatches > right.meetingMatches }
            if left.modified != right.modified { return left.modified > right.modified }
            return left.path < right.path
        }
        var matched: [(match: Match, terms: Set<String>, candidate: Candidate)] = []
        var documentFrequency: [String: Int] = [:]
        var documents = 0
        let queryText = query.joined(separator: " ")
        for candidate in candidates.prefix(maxReads) {
            guard !Task.isCancelled else { return [] }
            guard let snapshot = try? ParticipationKnowledgeReader.inspect(root: root,
                relativePath: candidate.path, byteLimit: byteLimit) else { continue }
            documents += 1
            guard let excerpt = ParticipationSourceBinding.relevantExcerpt(in: snapshot.markdown, matching: queryText),
                  !excerpt.trimmed.isEmpty else { continue }
            let terms = Set(words(excerpt)).intersection(queryTerms)
            guard !terms.isEmpty else { continue }
            for term in terms { documentFrequency[term, default: 0] += 1 }
            matched.append((Match(snapshot, excerpt: excerpt), terms, candidate))
        }
        var ranked: [(match: Match, score: Double, path: String)] = []
        for result in matched {
            let informative = result.terms.filter { documents < 3 || documentFrequency[$0, default: 0] * 3 <= documents * 2 }
            guard informative.count >= min(2, queryTerms.count)
                    || !informative.isDisjoint(with: result.candidate.titleMatches) else { continue }
            let weight = informative.sorted().reduce(0.0) { $0 + 1 / Double(documentFrequency[$1, default: 1]) }
            let titleWeight = informative.intersection(result.candidate.titleMatches).count
            let score = weight * 4 + Double(titleWeight * 3 + min(result.candidate.meetingMatches, 2))
            ranked.append((result.match, score, result.candidate.path))
        }
        ranked.sort { left, right in
            left.score == right.score ? left.path < right.path : left.score > right.score
        }
        var seen: Set<String> = []
        var results: [Match] = []
        for result in ranked where seen.insert(result.match.source.revision).inserted {
            results.append(result.match)
            if results.count == maxMatches { break }
        }
        return results
    }

    static func validate(_ matches: [Match], root: URL) -> Bool {
        matches.allSatisfy { match in
            guard !Task.isCancelled, let current = try? ParticipationKnowledgeReader.inspect(root: root,
                relativePath: match.path, byteLimit: byteLimit) else { return false }
            return match.matches(current)
        }
    }

    static func queryWords(_ value: String) -> [String] {
        Array(words(value).reversed().prefix(24).reversed())
    }

    private static func words(_ value: String) -> [String] {
        let normalized = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "und"))
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalized
        var seen: Set<String> = []
        return tokenizer.tokens(for: normalized.startIndex..<normalized.endIndex).compactMap { range in
            let token = String(normalized[range])
            guard token.count >= 3 || (token.count >= 2 && token.allSatisfy(\.isNumber)),
                  seen.insert(token).inserted else { return nil }
            return token
        }
    }
}
