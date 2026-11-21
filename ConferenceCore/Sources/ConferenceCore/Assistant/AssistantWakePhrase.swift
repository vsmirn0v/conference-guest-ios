import Foundation

public enum AssistantInputSource: String, Codable, Sendable {
    case typed
    case voicePushToTalk
    case voiceWake
    case externalMCP

    public var isVoice: Bool {
        self == .voicePushToTalk || self == .voiceWake
    }
}

/// Parses natural Russian and English voice invocations addressed to Rock / Рок.
public struct AssistantWakePhraseMatcher: Sendable {
    public enum Match: Equatable, Sendable {
        case none
        case wakeOnly
        case command(String)
    }

    private static let leadingGreetings: Set<String> = [
        "эй", "привет", "слушай", "окей", "ок", "алло", "скажи", "пожалуйста",
        "hey", "hi", "hello", "ok", "okay", "listen", "yo"
    ]

    private static let singleWakeWords: Set<String> = [
        "рок", "рог", "рока", "рокк", "рокнролл", "рокнрол",
        "rock", "rok", "rocknroll", "rock'n'roll", "rock’n’roll"
    ]

    private static let multiWordWakeSequences: [[String]] = [
        ["рок", "н", "ролл"],
        ["рок", "н", "рол"],
        ["рок", "и", "ролл"],
        ["rock", "n", "roll"],
        ["rock", "and", "roll"]
    ]

    private static let postWakeConnectors: Set<String> = [
        "пожалуйста", "пожалуйста,", "please"
    ]

    public static func match(_ transcript: String) -> Match {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        let tokens = tokenize(trimmed)
        guard !tokens.isEmpty else { return .none }

        var index = 0
        while index < tokens.count && leadingGreetings.contains(tokens[index].normalized) {
            index += 1
        }
        guard index < tokens.count else { return .none }

        var matchedWakeEnd: Int?
        for sequence in multiWordWakeSequences {
            if index + sequence.count <= tokens.count {
                let slice = tokens[index..<(index + sequence.count)].map(\.normalized)
                if slice == sequence {
                    matchedWakeEnd = index + sequence.count
                    break
                }
            }
        }

        if matchedWakeEnd == nil {
            let candidate = tokens[index].normalized
            if (candidate == "рок" || candidate == "rock"),
               index + 2 < tokens.count,
               ["н", "n"].contains(tokens[index + 1].normalized),
               ["ролл", "рол", "roll"].contains(tokens[index + 2].normalized) {
                matchedWakeEnd = index + 3
            } else if singleWakeWords.contains(candidate) {
                matchedWakeEnd = index + 1
            }
        }

        guard let wakeEnd = matchedWakeEnd else { return .none }
        var commandStartTokenIndex = wakeEnd
        while commandStartTokenIndex < tokens.count,
              postWakeConnectors.contains(tokens[commandStartTokenIndex].normalized) {
            commandStartTokenIndex += 1
        }

        guard commandStartTokenIndex < tokens.count else {
            return .wakeOnly
        }

        let startOffset = tokens[commandStartTokenIndex].range.lowerBound
        let rawRemainder = String(trimmed[startOffset...])
        let cleanRemainder = stripLeadingSeparators(rawRemainder)
        guard !cleanRemainder.isEmpty else { return .wakeOnly }
        return .command(cleanRemainder)
    }

    private struct Token {
        let normalized: String
        let range: Range<String.Index>
    }

    private static func tokenize(_ text: String) -> [Token] {
        var result: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex && isSeparator(text[index]) {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex && !isSeparator(text[index]) {
                index = text.index(after: index)
            }
            let raw = String(text[start..<index])
            let normalized = normalizeToken(raw)
            if !normalized.isEmpty {
                result.append(Token(normalized: normalized, range: start..<index))
            }
        }
        return result
    }

    private static func isSeparator(_ ch: Character) -> Bool {
        if ch.isWhitespace { return true }
        if ch == "-" || ch == "—" || ch == "–" { return true }
        return ch.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) && $0 != "'" && $0 != "’" }
    }

    private static func normalizeToken(_ token: String) -> String {
        let lower = token
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "’", with: "'")
        let trimmed = lower.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
        return trimmed
    }

    private static func stripLeadingSeparators(_ text: String) -> String {
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            if ch.isWhitespace || ch == "," || ch == ":" || ch == ";" || ch == "-" || ch == "—" || ch == "." || ch == "!" || ch == "?" {
                idx = text.index(after: idx)
            } else {
                break
            }
        }
        return String(text[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Maintains a short armed follow-up window after a standalone "Рок" / "Rock" wake utterance.
public struct AssistantWakeDetector: Sendable {
    public enum Outcome: Equatable, Sendable {
        case ignored
        case armed(until: Date)
        case triggered(command: String)
    }

    public let armWindowSeconds: TimeInterval
    public private(set) var armedUntil: Date?

    public init(armWindowSeconds: TimeInterval = 5.0) {
        self.armWindowSeconds = armWindowSeconds
    }

    public func isArmed(at now: Date) -> Bool {
        guard let armedUntil else { return false }
        return now <= armedUntil
    }

    public mutating func reset() {
        armedUntil = nil
    }

    public mutating func consume(transcript: String, isFinal: Bool, now: Date) -> Outcome {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if let until = armedUntil, now > until { armedUntil = nil }
            return .ignored
        }

        let match = AssistantWakePhraseMatcher.match(trimmed)
        if !isFinal {
            if match != .none {
                return .armed(until: now.addingTimeInterval(armWindowSeconds))
            }
            if let until = armedUntil, now <= until {
                return .armed(until: until)
            }
            return .ignored
        }

        switch match {
        case .command(let command):
            armedUntil = nil
            return .triggered(command: command)
        case .wakeOnly:
            let until = now.addingTimeInterval(armWindowSeconds)
            armedUntil = until
            return .armed(until: until)
        case .none:
            if let until = armedUntil, now <= until {
                armedUntil = nil
                return .triggered(command: trimmed)
            }
            armedUntil = nil
            return .ignored
        }
    }
}

/// Shared voice vs typed confirmation policy for Assistant actions.
public enum AssistantVoiceApprovalPolicy {
    private static let autoApprovedVoiceKinds: Set<String> = [
        "join", "mute", "setAttention", "participate", "remind", "remember", "readChat", "catchUp"
    ]
    private static let meetingSendKinds: Set<String> = [
        "sendChat", "say", "react"
    ]

    public static func shouldAutoApprove(
        actionKind: String,
        inputSource: AssistantInputSource,
        sendsWithoutAsking: Bool
    ) -> Bool {
        if inputSource == .externalMCP {
            return actionKind == "remember"
        }
        if actionKind == "remember" {
            return true
        }
        if actionKind == "leave" {
            return false
        }
        if meetingSendKinds.contains(actionKind) {
            return sendsWithoutAsking
        }
        if inputSource.isVoice {
            return autoApprovedVoiceKinds.contains(actionKind)
        }
        return false
    }
}
