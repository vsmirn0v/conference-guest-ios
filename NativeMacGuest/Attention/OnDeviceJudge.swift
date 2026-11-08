import ConferenceCore
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
struct AppleOnDeviceJudge: AttentionJudge, ReplyWriter, MomentSummarizer, MeetingOutcomeWriter, AssistantCommandInterpreter {
    func judge(_ request: JudgeRequest) async throws -> JudgeResult {
        guard #available(macOS 26.0, *) else { throw OnDeviceJudgeError.unsupportedSystem }
        return try await AppleOnDevice.judge(request)
    }

    func draft(_ request: ReplyRequest) async throws -> ReplyResult {
        guard !request.judge.replyChannels.isEmpty else { throw ReplyDraftError.unavailable }
        guard #available(macOS 26.0, *) else { throw OnDeviceJudgeError.unsupportedSystem }
        return try await AppleOnDevice.draft(request)
    }

    func summarize(_ request: MomentSummaryRequest) async throws -> String {
        guard #available(macOS 26.0, *) else { throw OnDeviceJudgeError.unsupportedSystem }
        return try await AppleOnDevice.summarize(request)
    }

    func outcome(_ request: MeetingOutcomeRequest) async throws -> MeetingOutcomeContent {
        guard #available(macOS 26.0, *) else { throw OnDeviceJudgeError.unsupportedSystem }
        return try await AppleOnDevice.outcome(request)
    }

    func interpret(_ request: AssistantCommandRequest) async throws -> AssistantCommand {
        guard #available(macOS 26.0, *) else { throw OnDeviceJudgeError.unsupportedSystem }
        return try await AppleOnDevice.interpret(request)
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
        // A reason that cannot be translated back stays in English rather than losing the card.
        let target = Locale.Language(identifier: request.language)
        if verdict.level != .no, translated.language == "en", target.languageCode != english.languageCode {
            verdict.reason = (try? await OnDeviceTranslator.shared.translate([verdict.reason], from: english, to: target, cache: false))?[verdict.reason]
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
        if englishJudge.language == "en", reasonLanguage.languageCode != english.languageCode, needsTranslation(reasonLanguage) {
            verdict.reason = (try? await OnDeviceTranslator.shared.translate([verdict.reason], from: reasonLanguage, to: english, cache: false))?[verdict.reason]
                ?? verdict.reason
        }
        let channels = request.judge.replyChannels
        let messages = ReplyPrompt.messages(ReplyRequest(judge: englishJudge, verdict: verdict, redraftHint: request.redraftHint))
        let content = try await respond(instructions: messages[0]["content"]!, prompt: messages[1]["content"]!,
                                        schema: replySchema(channels))
        // Parse the two bounded arrays while they are still structured English output;
        // never ask Translation to preserve a delimiter or JSON syntax.
        let stances = try content.value([String].self, forProperty: "stances")
        let texts = try content.value([String].self, forProperty: "texts")
        let variants = zip(stances, texts).prefix(3).map { ["stance": $0.0, "text": $0.1] }
        let object: [String: Any] = [
            "chat": try content.value(String.self, forProperty: "chat"),
            "reaction": try content.value(String.self, forProperty: "reaction"),
            "variants": variants,
        ]
        var draft = try ReplyPrompt.draft(from: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self),
                                          channels: channels)
        if let source, let generated = draft.variants, !generated.isEmpty {
            let values = generated.flatMap { [$0.stance, $0.text] }
            let translated = try await OnDeviceTranslator.shared.translate(values, from: english, to: source, cache: false)
            for index in draft.variants!.indices {
                let old = draft.variants![index]
                draft.variants![index].stance = translated[old.stance] ?? old.stance
                draft.variants![index].text = translated[old.text] ?? old.text
            }
            draft.chat = draft.variants?.first?.text ?? ""
        } else if let source, !draft.chat.isEmpty {
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
    /// language when it was translated. When translation fails (the system service can
    /// return internal errors), the model reads the meeting as is in its own language:
    /// weaker on Russian (25/31 vs 29/31 on the bench) but still a verdict.
    static func englishRequest(_ request: JudgeRequest) async throws -> (JudgeRequest, Locale.Language?) {
        var out = request
        out.language = "en"
        guard let source = meetingLanguage(request.window), needsTranslation(source) else { return (out, nil) }
        var texts = [request.window.meetingTitle, request.profile.name, request.profile.role] + request.profile.aliases
        texts += request.window.lines.flatMap { [$0.speaker, $0.text] }
        texts += request.memory.map(\.text)
        if let preset = request.preset {
            texts += [preset.about, preset.matters, preset.never] + preset.people
            texts += preset.promptExamples.flatMap { [$0.excerpt, $0.reason, $0.note ?? ""] }
        }
        let map: [String: String]
        do { map = try await OnDeviceTranslator.shared.translate(texts, from: source, to: Self.english) }
        catch is CancellationError { throw CancellationError() }
        // Missing languages are for you to download: say so instead of judging weaker.
        catch let error as OnDeviceJudgeError { throw error }
        catch {
            probeLog("on-device-translation-failed", ["error": String(describing: error), "language": source.minimalIdentifier])
            return (request, nil)
        }
        func t(_ text: String) -> String { map[text] ?? text }
        out.window.meetingTitle = t(request.window.meetingTitle)
        out.window.lines = request.window.lines.map {
            .init(id: $0.id, ref: $0.ref, source: $0.source, speaker: t($0.speaker), isYou: $0.isYou, text: t($0.text), at: $0.at,
                  mentionsYou: $0.mentionsYou)
        }
        out.profile.name = t(request.profile.name)
        out.profile.role = t(request.profile.role)
        out.profile.aliases = request.profile.aliases.map(t)
        out.memory = request.memory.map { .init(id: $0.id, kind: $0.kind, text: t($0.text), sourceID: $0.sourceID) }
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

    static func summarize(_ request: MomentSummaryRequest) async throws -> String {
        try checkModel()
        var translated = request
        let (english, source) = try await englishRequest(JudgeRequest(window: request.window, profile: AttentionProfile(),
            yourName: "", language: request.language))
        translated.window = english.window; translated.language = "en"
        if source != nil {
            translated.moment.verdict.reason = (try? await OnDeviceTranslator.shared.translate([request.moment.verdict.reason],
                from: Locale.Language(identifier: request.language), to: Self.english, cache: false))?[request.moment.verdict.reason]
                ?? request.moment.verdict.reason
        }
        let messages = MomentSummaryPrompt.messages(translated)
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "MomentSummary", properties: [
            .init(name: "summary", description: "At most three short factual sentences.", schema: DynamicGenerationSchema(type: String.self))
        ]), dependencies: [])
        let content = try await respond(instructions: messages[0]["content"]!, prompt: messages[1]["content"]!, schema: schema)
        var summary = try MomentSummaryPrompt.parse(try json(content, ["summary"]))
        if let source {
            summary = try await OnDeviceTranslator.shared.translate([summary], from: Self.english, to: source, cache: false)[summary] ?? summary
        }
        return summary
    }

    static func outcome(_ request: MeetingOutcomeRequest) async throws -> MeetingOutcomeContent {
        try checkModel()
        var translated = request
        let (english, source) = try await englishRequest(JudgeRequest(window: request.window, profile: AttentionProfile(),
            yourName: "", language: request.language))
        translated.window = english.window; translated.language = "en"
        let messages = MeetingOutcomePrompt.messages(translated)
        let taskText = DynamicGenerationSchema(type: String.self)
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "MeetingOutcome", properties: [
            .init(name: "summary", description: "At most four short factual sentences.", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "decisions", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))),
            .init(name: "tasks", description: "Each item: task text | owner | ISO due date or empty. Use no vertical bars inside fields.",
                  schema: DynamicGenerationSchema(arrayOf: taskText)),
            .init(name: "open_questions", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))),
        ]), dependencies: [])
        let content = try await respond(instructions: messages[0]["content"]!,
            prompt: messages[1]["content"]! + "\nFor tasks return strings formatted as task | owner | due_at.", schema: schema)
        var summary = try content.value(String.self, forProperty: "summary")
        var decisions = try content.value([String].self, forProperty: "decisions")
        var open = try content.value([String].self, forProperty: "open_questions")
        let rawTasks = try content.value([String].self, forProperty: "tasks")
        let iso = ISO8601DateFormatter()
        var tasks = rawTasks.compactMap { raw -> MeetingOutcomeTask? in
            let fields = raw.components(separatedBy: "|").map(\.trimmed)
            guard let text = fields.first, !text.isEmpty else { return nil }
            return .init(text: text, owner: fields.indices.contains(1) ? fields[1] : "",
                dueAt: fields.indices.contains(2) ? iso.date(from: fields[2]) : nil)
        }
        if let source {
            let values = [summary] + decisions + open + tasks.map(\.text) + tasks.map(\.owner)
            let map = try await OnDeviceTranslator.shared.translate(values, from: Self.english, to: source, cache: false)
            summary = map[summary] ?? summary
            decisions = decisions.map { map[$0] ?? $0 }; open = open.map { map[$0] ?? $0 }
            // Translate human-readable fields only; separators and ISO dates stay intact.
            for index in tasks.indices {
                tasks[index].text = map[tasks[index].text] ?? tasks[index].text
                tasks[index].owner = map[tasks[index].owner] ?? tasks[index].owner
            }
        }
        // Apply the same bounds, deduplication and field validation as remote writers.
        let object: [String: Any] = ["summary": summary, "decisions": decisions, "open_questions": open,
            "tasks": tasks.map { ["text": $0.text, "owner": $0.owner,
                "due_at": $0.dueAt.map(iso.string(from:)) ?? ""] }]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try MeetingOutcomePrompt.parse(String(decoding: data, as: UTF8.self))
    }

    static func interpret(_ request: AssistantCommandRequest) async throws -> AssistantCommand {
        try checkModel()
        let context = request.context
        func field(_ name: String, _ values: [String]) -> DynamicGenerationSchema {
            DynamicGenerationSchema(name: name, anyOf: values)
        }
        let free = DynamicGenerationSchema(type: String.self)
        let root = DynamicGenerationSchema(name: "AssistantCommand", properties: [
            .init(name: "action", schema: field("Action", ["none"] + AssistantCommandAction.allCases.map(\.rawValue))),
            .init(name: "meeting", schema: field("Meeting", [""] + context.meetings.map(\.id.uuidString))),
            .init(name: "moment", schema: field("Moment", [""] + context.moments.map(\.id.uuidString))),
            .init(name: "mode", schema: field("Mode", [""] + AttentionMode.allCases.map(\.rawValue))),
            .init(name: "scope", schema: field("Scope", ["", "untilLeave", "minutes30", "series"])),
            .init(name: "text", schema: free), .init(name: "fact", schema: free),
            .init(name: "reaction", schema: field("Reaction", [""] + MeetingReaction.allCases.map(\.rawValue))),
            .init(name: "n", schema: DynamicGenerationSchema(type: Int.self, guides: [.range(1...20)])),
            .init(name: "minutes", schema: DynamicGenerationSchema(type: Int.self, guides: [.range(1...180)])),
            .init(name: "at", schema: free),
        ])
        let messages = AssistantCommandPrompt.messages(request)
        let content = try await respond(instructions: messages[0]["content"]!, prompt: messages[1]["content"]!,
            schema: try GenerationSchema(root: root, dependencies: []))
        var object: [String: Any] = [:]
        for key in ["action", "meeting", "moment", "mode", "scope", "text", "fact", "reaction", "at"] {
            object[key] = try content.value(String.self, forProperty: key)
        }
        object["n"] = try content.value(Int.self, forProperty: "n")
        object["minutes"] = try content.value(Int.self, forProperty: "minutes")
        return try AssistantCommandPrompt.parse(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self), context: context)
    }

    static func replySchema(_ channels: ReplyChannels) throws -> GenerationSchema {
        let shortText = DynamicGenerationSchema(type: String.self)
        let stance = DynamicGenerationSchema(type: String.self)
        let root = DynamicGenerationSchema(name: "MeetingReply", properties: [
            .init(name: "chat", description: channels.chat
                  ? "The first variant's text, or an empty string when a reaction alone is better."
                  : "Always an empty string: this meeting has no chat.", schema: shortText),
            .init(name: "reaction", description: "An emoji reaction that alone answers, or none.",
                  schema: DynamicGenerationSchema(name: "Reaction", anyOf: ["none"] + channels.reactions.map(\.rawValue))),
            .init(name: "stances", description: "Up to three short stance labels, aligned by index with texts.", schema:
                  DynamicGenerationSchema(arrayOf: stance, minimumElements: 0, maximumElements: 3)),
            .init(name: "texts", description: "Up to three genuinely different reply texts, aligned by index with stances.", schema:
                  DynamicGenerationSchema(arrayOf: shortText, minimumElements: 0, maximumElements: 3)),
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
