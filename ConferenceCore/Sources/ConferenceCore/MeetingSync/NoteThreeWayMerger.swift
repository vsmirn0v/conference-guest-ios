import Foundation

public enum NoteThreeWayMerger {
    public struct MergeResult: Equatable, Sendable {
        public var markdown: String
        public var hadConflict: Bool
        public var archivedLoser: String?

        public init(markdown: String, hadConflict: Bool, archivedLoser: String? = nil) {
            self.markdown = markdown
            self.hadConflict = hadConflict
            self.archivedLoser = archivedLoser
        }
    }

    public static func merge(
        base: String?,
        local: String,
        localVersion: SyncVersion,
        remote: String,
        remoteVersion: SyncVersion
    ) -> MergeResult {
        if local == remote {
            return MergeResult(markdown: local, hadConflict: false)
        }
        let localTrimmed = local.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteTrimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseTrimmed = base?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let base, local == base {
            return MergeResult(markdown: remote, hadConflict: false)
        }
        if let base, remote == base {
            return MergeResult(markdown: local, hadConflict: false)
        }
        if base == nil || baseTrimmed.isEmpty {
            if localTrimmed.isEmpty { return MergeResult(markdown: remote, hadConflict: false) }
            if remoteTrimmed.isEmpty { return MergeResult(markdown: local, hadConflict: false) }
            return MergeResult(
                markdown: mergeFreshNotes(
                    first: localVersion < remoteVersion ? local : remote,
                    second: localVersion < remoteVersion ? remote : local
                ),
                hadConflict: false
            )
        }

        let baseLines = lines(base ?? "")
        let localLines = lines(local)
        let remoteLines = lines(remote)

        let matchesLocal = lcsMatches(baseLines, localLines)
        let matchesRemote = lcsMatches(baseLines, remoteLines)

        // Common anchors where both local and remote still retain the base line.
        let localMap = Dictionary(uniqueKeysWithValues: matchesLocal)
        let remoteMap = Dictionary(uniqueKeysWithValues: matchesRemote)
        var anchors: [(baseIndex: Int, localIndex: Int, remoteIndex: Int)] = []
        var lastLocal = -1
        var lastRemote = -1
        for b in 0..<baseLines.count {
            if let li = localMap[b], let ri = remoteMap[b], li > lastLocal, ri > lastRemote {
                anchors.append((b, li, ri))
                lastLocal = li
                lastRemote = ri
            }
        }
        anchors.append((baseLines.count, localLines.count, remoteLines.count))

        var output: [String] = []
        var hadConflict = false
        var baseCursor = 0
        var localCursor = 0
        var remoteCursor = 0

        for anchor in anchors {
            let bSlice = Array(baseLines[baseCursor..<anchor.baseIndex])
            let lSlice = Array(localLines[localCursor..<anchor.localIndex])
            let rSlice = Array(remoteLines[remoteCursor..<anchor.remoteIndex])

            if !(bSlice.isEmpty && lSlice.isEmpty && rSlice.isEmpty) {
                if lSlice == rSlice {
                    output.append(contentsOf: lSlice)
                } else if lSlice == bSlice {
                    output.append(contentsOf: rSlice)
                } else if rSlice == bSlice {
                    output.append(contentsOf: lSlice)
                } else if bSlice.isEmpty {
                    output.append(contentsOf: mergeDisjointAdditions(
                        first: localVersion < remoteVersion ? lSlice : rSlice,
                        second: localVersion < remoteVersion ? rSlice : lSlice
                    ))
                } else {
                    hadConflict = true
                    let remoteWins = localVersion < remoteVersion
                    let primary = remoteWins ? rSlice : lSlice
                    let secondary = remoteWins ? lSlice : rSlice
                    output.append(contentsOf: primary)
                    if !secondary.isEmpty {
                        output.append("> " + L("Note from another device:"))
                        for line in secondary {
                            output.append(line.isEmpty ? ">" : "> " + line)
                        }
                    }
                }
            }

            if anchor.baseIndex < baseLines.count {
                output.append(baseLines[anchor.baseIndex])
            }
            baseCursor = anchor.baseIndex + 1
            localCursor = anchor.localIndex + 1
            remoteCursor = anchor.remoteIndex + 1
        }

        let merged = output.joined(separator: "\n")
        let loser = hadConflict ? (localVersion < remoteVersion ? local : remote) : nil
        return MergeResult(markdown: merged, hadConflict: hadConflict, archivedLoser: loser)
    }

    private static func mergeDisjointAdditions(first: [String], second: [String]) -> [String] {
        if first == second { return first }
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        let matches = lcsMatches(first, second)
        var out: [String] = []
        var cursorA = 0
        var cursorB = 0
        for (idxA, idxB) in matches {
            out.append(contentsOf: first[cursorA..<idxA])
            out.append(contentsOf: second[cursorB..<idxB])
            out.append(first[idxA])
            cursorA = idxA + 1
            cursorB = idxB + 1
        }
        out.append(contentsOf: first[cursorA..<first.count])
        out.append(contentsOf: second[cursorB..<second.count])
        return out
    }

    private static func mergeFreshNotes(first: String, second: String) -> String {
        let firstParagraphs = first.components(separatedBy: "\n\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let secondParagraphs = second.components(separatedBy: "\n\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        var seen = Set(firstParagraphs)
        var combined = firstParagraphs
        for paragraph in secondParagraphs where seen.insert(paragraph).inserted {
            combined.append(paragraph)
        }
        return combined.joined(separator: "\n\n")
    }

    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// Computes aligned matching line indices between `base` and `target`.
    /// Trims common prefix/suffix first and bounds large DP matrices cleanly.
    private static func lcsMatches(_ base: [String], _ target: [String]) -> [(Int, Int)] {
        var prefix = 0
        while prefix < base.count && prefix < target.count && base[prefix] == target[prefix] {
            prefix += 1
        }
        var suffix = 0
        while prefix + suffix < base.count && prefix + suffix < target.count &&
            base[base.count - 1 - suffix] == target[target.count - 1 - suffix] {
            suffix += 1
        }

        var result: [(Int, Int)] = []
        result.reserveCapacity(prefix + suffix + 16)
        for i in 0..<prefix {
            result.append((i, i))
        }

        let bStart = prefix
        let bEnd = base.count - suffix
        let tStart = prefix
        let tEnd = target.count - suffix
        let m = bEnd - bStart
        let n = tEnd - tStart

        if m > 0 && n > 0 {
            if m * n <= 200_000 {
                var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
                for i in stride(from: m - 1, through: 0, by: -1) {
                    for j in stride(from: n - 1, through: 0, by: -1) {
                        if base[bStart + i] == target[tStart + j] {
                            dp[i][j] = dp[i + 1][j + 1] + 1
                        } else {
                            dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                        }
                    }
                }
                var i = 0
                var j = 0
                while i < m && j < n {
                    if base[bStart + i] == target[tStart + j] {
                        result.append((bStart + i, tStart + j))
                        i += 1
                        j += 1
                    } else if dp[i + 1][j] >= dp[i][j + 1] {
                        i += 1
                    } else {
                        j += 1
                    }
                }
            } else {
                // Large document fallback: align unique matching lines greedily in order.
                var targetIndices: [String: [Int]] = [:]
                for j in 0..<n {
                    targetIndices[target[tStart + j], default: []].append(j)
                }
                var lastJ = -1
                for i in 0..<m {
                    if let matches = targetIndices[base[bStart + i]],
                       let nextJ = matches.first(where: { $0 > lastJ }) {
                        result.append((bStart + i, tStart + nextJ))
                        lastJ = nextJ
                    }
                }
            }
        }

        for s in 0..<suffix {
            result.append((base.count - suffix + s, target.count - suffix + s))
        }
        return result
    }
}
