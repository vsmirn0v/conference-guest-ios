import Foundation
import FoundationModels
import NaturalLanguage
import Translation

/// The judge and writer on Apple's on-device model. The system model knows a few
/// languages well; a meeting in another one (Russian, for example) is translated to
/// English on this Mac first, judged in English, and the card's reason and a drafted
/// chat reply are translated back. Nothing leaves this Mac.
///
/// Measured on 43 labelled Russian meetings (Experiments/AttentionBench): translated
/// input with `extraRules` was right on 41, with no missed "now"; Russian given to the
/// model as is was markedly worse.
struct AppleOnDeviceJudge: AttentionJudge, ReplyWriter {
    func judge(_ request: JudgeRequest) async throws -> JudgeResult {
        guard #available(macOS 26.0, *) else { throw OnDeviceJudgeError.unsupportedSystem }
        return try await AppleOnDevice.judge(request)
    }

    func draft(_ request: ReplyRequest) async throws -> ReplyResult {
        guard !request.judge.replyChannels.isEmpty else { throw ReplyDraftError.unavailable }
        guard #available(macOS 26.0, *) else { throw OnDeviceJudgeError.unsupportedSystem }
        return try await AppleOnDevice.draft(request)
    }

    /// Why the on-device judge cannot run here, or nil when it can.
    static var unavailableReason: String? {
        guard #available(macOS 26.0, *) else { return OnDeviceJudgeError.unsupportedSystem.errorDescription }
        return AppleOnDevice.unavailableReason
    }
}

enum OnDeviceJudgeError: LocalizedError, Equatable {
    case unsupportedSystem, notEnabled, deviceNotEligible, modelNotReady, translationMissing(String), tooLong
    var errorDescription: String? {
        switch self {
        case .unsupportedSystem: L("The model on this Mac needs macOS 26 or later.")
        case .notEnabled: L("Turn on Apple Intelligence in System Settings to use the model on this Mac.")
        case .deviceNotEligible: L("This Mac cannot run Apple's on-device model.")
        case .modelNotReady: L("Apple's on-device model is still downloading. Try again later.")
        case .translationMissing(let language):
            L("Download %@ and English in System Settings → General → Language & Region → Translation Languages.", language)
        case .tooLong: L("The meeting text is too long for the model on this Mac.")
        }
    }
}

@available(macOS 26.0, *)
enum AppleOnDevice {
    /// Added to the judge's rules for the system model, which otherwise treats the
    /// user's interests as if the meeting were discussing them.
    static let extraRules = """

    - The meeting instructions and the user's role describe what the user cares about. They are not part of \
    the conversation; judge only what the meeting lines say.
    - "soon" needs a meeting line that discusses one of the user's topics as open work, or says the user will be asked.
    - Greetings, thanks, praise, jokes and matters already answered or closed are "no", even when they mention \
    the user or the user's topics.
    - A line asking the user to answer, including in the chat, is "now". So is a failure or a deadline within the hour \
    in the user's area.
    """
    static let english = Locale.Language(identifier: "en")

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): OnDeviceJudgeError.notEnabled.errorDescription
        case .unavailable(.deviceNotEligible): OnDeviceJudgeError.deviceNotEligible.errorDescription
        default: OnDeviceJudgeError.modelNotReady.errorDescription
        }
    }

    static func judge(_ request: JudgeRequest) async throws -> JudgeResult {
        let started = Date()
        try checkModel()
        let (translated, _) = try await englishRequest(request)
        let messages = AttentionPrompt.messages(translated)
        let content = try await respond(instructions: messages[0]["content"]! + extraRules, prompt: messages[1]["content"]!,
                                        schema: verdictSchema(refs: request.window.lines.map(\.ref)))
        var verdict: AttentionVerdict
        do { verdict = try AttentionPrompt.verdict(from: json(content, ["attention", "reason", "action"], number: "probability",
                                                                list: "evidence"), window: request.window) }
        catch let error as AttentionVerdictError { throw AttentionJudgeError.verdict(error) }
        // Only a card shows the reason; a "no" keeps the English one in the decision log.
        let target = Locale.Language(identifier: request.language)
        if verdict.level != .no, target.languageCode != english.languageCode {
            verdict.reason = try await OnDeviceTranslator.shared.translate([verdict.reason], from: english, to: target, cache: false)[verdict.reason]
                ?? verdict.reason
        }
        return .init(verdict: verdict, latency: Date().timeIntervalSince(started))
    }

    static func draft(_ request: ReplyRequest) async throws -> ReplyResult {
        let started = Date()
        try checkModel()
        let (englishJudge, source) = try await englishRequest(request.judge)
        var verdict = request.verdict
        // The card shows the reason in your language; the writer reads it in English.
        let reasonLanguage = Locale.Language(identifier: request.judge.language)
        if reasonLanguage.languageCode != english.languageCode, needsTranslation(reasonLanguage) {
            verdict.reason = try await OnDeviceTranslator.shared.translate([verdict.reason], from: reasonLanguage, to: english, cache: false)[verdict.reason]
                ?? verdict.reason
        }
        let channels = request.judge.replyChannels
        let messages = ReplyPrompt.messages(ReplyRequest(judge: englishJudge, verdict: verdict))
        let content = try await respond(instructions: messages[0]["content"]!, prompt: messages[1]["content"]!,
                                        schema: replySchema(channels))
        var draft = try ReplyPrompt.draft(from: json(content, ["chat", "reaction"]), channels: channels)
        if let source, !draft.chat.isEmpty {
            draft.chat = try await OnDeviceTranslator.shared.translate([draft.chat], from: english, to: source, cache: false)[draft.chat]
                ?? draft.chat
        }
        return .init(draft: draft, latency: Date().timeIntervalSince(started))
    }

    private static func checkModel() throws {
        switch SystemLanguageModel.default.availability {
        case .available: return
        case .unavailable(.appleIntelligenceNotEnabled): throw OnDeviceJudgeError.notEnabled
        case .unavailable(.deviceNotEligible): throw OnDeviceJudgeError.deviceNotEligible
        default: throw OnDeviceJudgeError.modelNotReady
        }
    }

    static func needsTranslation(_ language: Locale.Language) -> Bool {
        language.languageCode != english.languageCode
            && !SystemLanguageModel.default.supportsLocale(Locale(identifier: language.minimalIdentifier))
    }

    /// The language most of the meeting's lines are in, when one is clear.
    static func meetingLanguage(_ window: AttentionWindow) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(window.lines.map(\.text).joined(separator: "\n"))
        guard let dominant = recognizer.dominantLanguage, dominant != .undetermined else { return nil }
        return Locale.Language(identifier: dominant.rawValue)
    }

    /// The request as the model reads it: in English when the model does not know the
    /// meeting's language, with the reason asked for in English. Returns the meeting's
    /// language when it was translated.
    static func englishRequest(_ request: JudgeRequest) async throws -> (JudgeRequest, Locale.Language?) {
        var out = request
        out.language = "en"
        guard let source = meetingLanguage(request.window), needsTranslation(source) else { return (out, nil) }
        var texts = [request.window.meetingTitle, request.profile.name, request.profile.role] + request.profile.aliases
        texts += request.window.lines.flatMap { [$0.speaker, $0.text] }
        if let preset = request.preset {
            texts += [preset.about, preset.matters, preset.never] + preset.people
            texts += preset.promptExamples.flatMap { [$0.excerpt, $0.reason, $0.note ?? ""] }
        }
        let map = try await OnDeviceTranslator.shared.translate(texts, from: source, to: Self.english)
        func t(_ text: String) -> String { map[text] ?? text }
        out.window.meetingTitle = t(request.window.meetingTitle)
        out.window.lines = request.window.lines.map {
            .init(id: $0.id, ref: $0.ref, source: $0.source, speaker: t($0.speaker), isYou: $0.isYou, text: t($0.text), at: $0.at,
                  mentionsYou: $0.mentionsYou)
        }
        out.profile.name = t(request.profile.name)
        out.profile.role = t(request.profile.role)
        out.profile.aliases = request.profile.aliases.map(t)
        if var preset = request.preset {
            preset.about = t(preset.about); preset.matters = t(preset.matters); preset.never = t(preset.never)
            preset.people = preset.people.map(t)
            let shown = Set(preset.promptExamples.map(\.id))
            preset.examples = preset.examples.map { example in
                guard shown.contains(example.id) else { return example }
                var example = example
                example.excerpt = t(example.excerpt); example.reason = t(example.reason); example.note = example.note.map(t)
                return example
            }
            out.preset = preset
        }
        return (out, source)
    }

    /// The verdict's shape for this window: evidence can only name refs that exist in it.
    static func verdictSchema(refs: [String]) throws -> GenerationSchema {
        let root = DynamicGenerationSchema(name: "AttentionVerdict", properties: [
            .init(name: "attention", description: "now: the user should join or answer within a minute; soon: within a few minutes; no: not needed.",
                  schema: DynamicGenerationSchema(name: "Level", anyOf: AttentionLevel.allCases.map(\.rawValue))),
            .init(name: "probability", description: "Probability from 0 to 1 that the user needs to act in this meeting now or soon.",
                  schema: DynamicGenerationSchema(type: Double.self, guides: [.range(0...1)])),
            .init(name: "reason", description: "At most two short sentences for the user, naming who wants what.",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "evidence", description: "Refs of the meeting lines the decision rests on.",
                  schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(name: "Ref", anyOf: refs.isEmpty ? ["L1"] : refs),
                                                  minimumElements: 0, maximumElements: 4)),
            .init(name: "action", schema: DynamicGenerationSchema(name: "Action", anyOf: AttentionAction.allCases.map(\.rawValue))),
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    static func replySchema(_ channels: ReplyChannels) throws -> GenerationSchema {
        let root = DynamicGenerationSchema(name: "MeetingReply", properties: [
            .init(name: "chat", description: channels.chat
                  ? "The chat message the user would send, or an empty string when a reaction alone is better."
                  : "Always an empty string: this meeting has no chat.", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "reaction", description: "An emoji reaction that alone answers, or none.",
                  schema: DynamicGenerationSchema(name: "Reaction", anyOf: ["none"] + channels.reactions.map(\.rawValue))),
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func respond(instructions: String, prompt: String, schema: GenerationSchema) async throws -> GeneratedContent {
        let session = LanguageModelSession(model: .default, instructions: instructions)
        do {
            return try await session.respond(to: prompt, schema: schema, options: GenerationOptions(sampling: .greedy)).content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: throw OnDeviceJudgeError.tooLong
            case .guardrailViolation, .refusal: throw AttentionJudgeError.refused
            default: throw error
            }
        }
    }

    /// The generated fields as the JSON the shared validators read.
    private static func json(_ content: GeneratedContent, _ strings: [String], number: String? = nil, list: String? = nil) throws -> String {
        var object: [String: Any] = [:]
        for key in strings { object[key] = try content.value(String.self, forProperty: key) }
        if let number { object[number] = try content.value(Double.self, forProperty: number) }
        if let list { object[list] = try content.value([String].self, forProperty: list) }
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

/// On-device Translation with a per-process cache, so a line is translated once
/// however many windows it stays in.
@available(macOS 26.0, *)
actor OnDeviceTranslator {
    static let shared = OnDeviceTranslator()
    static let cacheLimit = 4000
    private var sessions: [String: TranslationSession] = [:]
    private var cache: [String: String] = [:]
    private var order: [String] = []

    /// Translations keyed by source text. Empty texts are skipped.
    func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language, cache useCache: Bool = true) async throws -> [String: String] {
        let pair = (source.languageCode?.identifier ?? source.minimalIdentifier) + ">" + (target.languageCode?.identifier ?? target.minimalIdentifier)
        var result: [String: String] = [:], missing: [String] = []
        for text in Set(texts) where !text.trimmed.isEmpty {
            if useCache, let hit = cache[pair + "\n" + text] { result[text] = hit } else { missing.append(text) }
        }
        guard !missing.isEmpty else { return result }
        let session = try await session(pair, source: source, target: target)
        let responses = try await session.translations(from: missing.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        })
        for response in responses {
            guard let index = response.clientIdentifier.flatMap(Int.init), missing.indices.contains(index) else { continue }
            result[missing[index]] = response.targetText
            if useCache { remember(pair + "\n" + missing[index], response.targetText) }
        }
        return result
    }

    private func session(_ pair: String, source: Locale.Language, target: Locale.Language) async throws -> TranslationSession {
        if let session = sessions[pair] { return session }
        guard await LanguageAvailability().status(from: source, to: target) == .installed else {
            let missing = source.languageCode == AppleOnDevice.english.languageCode ? target : source
            throw OnDeviceJudgeError.translationMissing(Locale.current.localizedString(forIdentifier: missing.minimalIdentifier) ?? missing.minimalIdentifier)
        }
        let session = TranslationSession(installedSource: source, target: target)
        sessions[pair] = session
        return session
    }

    private func remember(_ key: String, _ value: String) {
        if cache.updateValue(value, forKey: key) == nil { order.append(key) }
        if order.count > Self.cacheLimit {
            for key in order.prefix(order.count - Self.cacheLimit) { cache[key] = nil }
            order.removeFirst(order.count - Self.cacheLimit)
        }
    }
}
