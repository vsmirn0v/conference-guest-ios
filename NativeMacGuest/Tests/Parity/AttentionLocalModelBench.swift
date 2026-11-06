import Foundation
import FoundationModels
import Translation
import XCTest
@testable import RockNativeDesktop

/// Opt-in comparison of on-device judges on the Russian scenarios in
/// Experiments/AttentionBench/ru_scenarios.json (ru_scenarios.py writes it):
///   fm-ru    Apple Foundation Models reading the Russian meeting as is
///   fm-en    the same model after on-device Translation ru→en of every line,
///            the profile and the meeting instructions
///   apple    the app's AppleOnDeviceJudge on the Russian request (translation inside)
///   mlx-ru / mlx-en  Rapid-MLX (127.0.0.1:8000) through the app's own judge client
/// Every answer goes through AttentionPrompt.verdict, as the app does. Results go to
/// .build/attention-bench/. Run with TEST_RUNNER_ATTENTION_BENCH=1; pick engines with
/// TEST_RUNNER_ATTENTION_BENCH_MODES=fm-ru,fm-en,mlx-ru,mlx-en.
final class AttentionLocalModelBench: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    struct Scenario: Decodable {
        struct Line: Decodable { let speaker: String; let text: String; let you: Bool; let chat: Bool }
        let id: String, category: String, expected: AttentionLevel, accept: [AttentionLevel], lines: [Line]
        var holdout: Bool? = nil
    }
    struct File: Decodable {
        struct Profile: Decodable { let name: String; let aliases: [String]; let role: String }
        struct Preset: Decodable { let about: String; let matters: String; let people: [String]; let never: String }
        let profile: Profile, preset: Preset, scenarios: [Scenario]
    }
    struct Outcome: Encodable {
        let mode: String, id: String, category: String, expected: String, accept: [String]
        var level: String? = nil, probability: Double? = nil, reason: String? = nil, evidence: [String]? = nil, action: String? = nil
        var error: String? = nil
        var latency: Double
        var translation: Double?
        /// The English reason translated back to Russian for the card, and how long that took.
        var reasonRu: String? = nil
        var backTranslation: Double? = nil
        var exact: Bool { level == expected }
        var acceptable: Bool { level.map { accept.contains($0) } ?? false }
    }

    /// The meeting a scenario describes, in the app's own request types.
    static func request(_ file: File, _ scenario: Scenario, language: String, texts: [String: String] = [:]) -> JudgeRequest {
        func t(_ s: String) -> String { texts[s] ?? s }
        let profile = AttentionProfile(name: t(file.profile.name), aliases: file.profile.aliases.map(t), role: t(file.profile.role))
        let names = profile.names(fallback: profile.name)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        let lines = scenario.lines.enumerated().map { index, line in
            let text = t(line.text)
            return AttentionWindow.Line(id: "\(scenario.id)-\(index)", ref: "L\(index + 1)", source: line.chat ? .chat : .speech,
                speaker: t(line.speaker), isYou: line.you, text: text, at: start.addingTimeInterval(Double(index) * 4),
                mentionsYou: AttentionWindowBuilder.mentions(text, names))
        }
        let window = AttentionWindow(meetingTitle: t("Инфраструктура"), lines: lines, reactions: [], joined: [], left: [],
            participantCount: 6, microphoneOn: false, soundOn: false, builtAt: start.addingTimeInterval(Double(lines.count) * 4))
        let preset = MeetingPreset(title: t("Инфраструктура"), bindings: [], about: t(file.preset.about), matters: t(file.preset.matters),
            people: file.preset.people.map(t), never: t(file.preset.never), urgency: .normal)
        return JudgeRequest(window: window, preset: preset, profile: profile, yourName: profile.name, language: language,
            replyChannels: ReplyChannels(chat: true))
    }

    /// Every distinct string a scenario shows the judge, so one Translation call covers it.
    static func strings(_ file: File, _ scenario: Scenario) -> [String] {
        var all = [file.profile.name, file.profile.role, file.preset.about, file.preset.matters, file.preset.never, "Инфраструктура"]
        all += file.profile.aliases + file.preset.people + scenario.lines.flatMap { [$0.speaker, $0.text] }
        var seen = Set<String>()
        return all.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func testRussianScenarios() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ATTENTION_BENCH"] == "1" || env["TEST_RUNNER_ATTENTION_BENCH"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_ATTENTION_BENCH=1")
        }
        guard #available(macOS 26.0, *) else { throw XCTSkip("Foundation Models need macOS 26") }
        let modes = (env["ATTENTION_BENCH_MODES"] ?? env["TEST_RUNNER_ATTENTION_BENCH_MODES"] ?? "fm-ru,fm-en,mlx-ru,mlx-en")
            .split(separator: ",").map(String.init)
        let data = try Data(contentsOf: Self.repo.appendingPathComponent("Experiments/AttentionBench/ru_scenarios.json"))
        let file = try JSONDecoder().decode(File.self, from: data)
        let only = env["ATTENTION_BENCH_ONLY"] ?? env["TEST_RUNNER_ATTENTION_BENCH_ONLY"]
        let scenarios = file.scenarios.filter { only == nil || only!.split(separator: ",").contains(Substring($0.id)) }

        let model = SystemLanguageModel.default
        var info: [String: String] = ["availability": "\(model.availability)",
            "supportsRussian": "\(model.supportsLocale(Locale(identifier: "ru_RU")))",
            "translationRuEn": "\(await LanguageAvailability().status(from: .init(identifier: "ru"), to: .init(identifier: "en")))"]
        print("BENCH info \(info)")

        var english: [String: [String: String]] = [:], translationTime: [String: Double] = [:]
        if modes.contains(where: { $0.contains("-en") }) {
            let translator = TranslationSession(installedSource: .init(identifier: "ru"), target: .init(identifier: "en"))
            for scenario in scenarios {
                let sources = Self.strings(file, scenario)
                let started = Date()
                let responses = try await translator.translations(from: sources.enumerated().map {
                    TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) })
                translationTime[scenario.id] = Date().timeIntervalSince(started)
                var map: [String: String] = [:]
                for response in responses { if let index = Int(response.clientIdentifier ?? "") { map[sources[index]] = response.targetText } }
                english[scenario.id] = map
            }
            let sample = scenarios.first.flatMap { s in english[s.id].map { m in s.lines.map { m[$0.text] ?? "?" } } } ?? []
            print("BENCH translation sample \(sample)")
        }

        let backTranslator = modes.contains(where: { $0.contains("-en") })
            ? TranslationSession(installedSource: .init(identifier: "en"), target: .init(identifier: "ru")) : nil
        var outcomes: [Outcome] = []
        for mode in modes {
            for scenario in scenarios {
                let flags = Set(mode.split(separator: "+").dropFirst().map(String.init))
                let en = mode.contains("-en")
                let request = Self.request(file, scenario, language: en ? "en" : "ru", texts: en ? english[scenario.id] ?? [:] : [:])
                var outcome = Outcome(mode: mode, id: scenario.id, category: scenario.category, expected: scenario.expected.rawValue,
                    accept: scenario.accept.map(\.rawValue), error: nil, latency: 0, translation: en ? translationTime[scenario.id] : nil)
                let started = Date()
                do {
                    let verdict: AttentionVerdict
                    if mode.hasPrefix("apple") {
                        // The app's own judge: it detects the language and translates by itself.
                        verdict = try await AppleOnDeviceJudge().judge(request).verdict
                    } else if mode.hasPrefix("fm") {
                        verdict = try await Self.foundationJudge(request, flags: flags)
                    } else {
                        let judge = OpenAIChatJudge(provider: AttentionProvider.defaults[.rapidMLX]!, key: nil, timeout: 90, retryDelays: [])
                        var messages = AttentionPrompt.messages(request)
                        if flags.contains("rules") { messages[0]["content"]! += AppleOnDevice.extraRules }
                        verdict = try await judge.judge(messages: messages, window: request.window).verdict
                    }
                    outcome.level = verdict.level.rawValue; outcome.probability = verdict.probability; outcome.reason = verdict.reason
                    outcome.evidence = verdict.evidence; outcome.action = verdict.action.rawValue
                } catch {
                    outcome.error = String(describing: error).prefix(300).description
                }
                outcome.latency = Date().timeIntervalSince(started)
                if en, let reason = outcome.reason {
                    let back = Date()
                    if let text = try? await backTranslator?.translate(reason).targetText {
                        outcome.reasonRu = text; outcome.backTranslation = Date().timeIntervalSince(back)
                    }
                }
                print("BENCH \(mode) \(scenario.id) expected=\(outcome.expected) got=\(outcome.level ?? "ERR") " +
                      String(format: "%.2fs tr=%.2fs back=%.2fs", outcome.latency, outcome.translation ?? 0, outcome.backTranslation ?? 0) +
                      " \(outcome.error ?? outcome.reason ?? "")" + (outcome.reasonRu.map { " || RU: " + $0 } ?? ""))
                outcomes.append(outcome)
            }
        }

        var summary: [[String: Any]] = []
        let holdout = Set(scenarios.filter { $0.holdout == true }.map(\.id))
        for mode in modes { for split in ["tuning", "holdout"] {
            let rows = outcomes.filter { $0.mode == mode && holdout.contains($0.id) == (split == "holdout") }
            guard !rows.isEmpty else { continue }
            let valid = rows.filter { $0.level != nil }
            let latencies = valid.map(\.latency).sorted()
            let row: [String: Any] = [
                "mode": mode, "split": split, "n": rows.count, "invalid": rows.count - valid.count,
                "exact": rows.filter(\.exact).count, "acceptable": rows.filter(\.acceptable).count,
                "criticalMiss": rows.filter { $0.expected == "now" && $0.level == "no" }.count,
                "missedNow": rows.filter { $0.expected == "now" && $0.level != "now" }.count,
                "falseNow": rows.filter { $0.expected == "no" && $0.level == "now" }.count,
                "falseAlert": rows.filter { $0.expected == "no" && ($0.level == "now" || $0.level == "soon") && !$0.acceptable }.count,
                "medianLatency": latencies.isEmpty ? 0 : latencies[latencies.count / 2],
                "maxLatency": latencies.last ?? 0,
                "medianTranslation": rows.compactMap(\.translation).sorted().dropFirst(rows.compactMap(\.translation).count / 2).first ?? 0,
                "medianBackTranslation": rows.compactMap(\.backTranslation).sorted().dropFirst(rows.compactMap(\.backTranslation).count / 2).first ?? 0,
            ]
            print("BENCH summary \(row)")
            summary.append(row)
        } }
        info["date"] = ISO8601DateFormatter().string(from: Date())
        // The sandboxed test host cannot write into the repository; the log carries every row too.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attention-bench", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent("ru-local-models-\(Int(Date().timeIntervalSince1970)).json")
        let rows = try JSONSerialization.jsonObject(with: JSONEncoder().encode(outcomes))
        try JSONSerialization.data(withJSONObject: ["info": info, "summary": summary, "outcomes": rows],
            options: [.prettyPrinted, .sortedKeys]).write(to: out)
        print("BENCH wrote \(out.path)")
    }

    /// The app's judge prompt on the system model, with guided generation in the
    /// verdict's shape; the answer is then checked like any provider's JSON.
    @available(macOS 26.0, *)
    static func foundationJudge(_ request: JudgeRequest, flags: Set<String> = []) async throws -> AttentionVerdict {
        let messages = AttentionPrompt.messages(request)
        let session = LanguageModelSession(model: .default,
                                          instructions: messages[0]["content"]! + (flags.contains("rules") ? AppleOnDevice.extraRules : ""))
        // Built per window: evidence can only name refs that exist in it.
        let refs = request.window.lines.map(\.ref)
        let ref = DynamicGenerationSchema(name: "Ref", anyOf: refs.isEmpty ? ["L1"] : refs)
        var properties: [DynamicGenerationSchema.Property] = [
            .init(name: "attention", description: "now: the user should join or answer within a minute; soon: within a few minutes; no: not needed.",
                  schema: DynamicGenerationSchema(name: "Level", anyOf: ["no", "soon", "now"])),
            .init(name: "probability", description: "Probability from 0 to 1 that the user needs to act in this meeting now or soon.",
                  schema: DynamicGenerationSchema(type: Double.self, guides: [.range(0...1)])),
            .init(name: "reason", description: "At most two short sentences for the user, naming who wants what.",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "evidence", description: "Refs of the meeting lines the decision rests on.",
                  schema: DynamicGenerationSchema(arrayOf: ref, minimumElements: 0, maximumElements: 4)),
            .init(name: "action", schema: DynamicGenerationSchema(name: "Action", anyOf: ["none", "open", "chat", "reaction"])),
        ]
        // Properties are generated in order: with "order" the model cites lines and explains before it decides.
        if flags.contains("order") { properties = [properties[3], properties[2], properties[0], properties[1], properties[4]] }
        let root = DynamicGenerationSchema(name: "AttentionVerdict", properties: properties)
        let schema = try GenerationSchema(root: root, dependencies: [])
        let response = try await session.respond(to: messages[1]["content"]!, schema: schema,
                                                 options: GenerationOptions(sampling: .greedy))
        let c = response.content
        let json: [String: Any] = ["attention": try c.value(String.self, forProperty: "attention"),
                                   "probability": try c.value(Double.self, forProperty: "probability"),
                                   "reason": try c.value(String.self, forProperty: "reason"),
                                   "evidence": try c.value([String].self, forProperty: "evidence"),
                                   "action": try c.value(String.self, forProperty: "action")]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        return try AttentionPrompt.verdict(from: text, window: request.window)
    }
}

@available(macOS 26.0, *)
@Generable struct GuidedVerdict {
    @Guide(description: "now: the user should join or answer within a minute; soon: within a few minutes; no: not needed.",
           .anyOf(["no", "soon", "now"]))
    var attention: String
    @Guide(description: "Probability from 0 to 1 that the user needs to act in this meeting now or soon.", .range(0...1))
    var probability: Double
    @Guide(description: "At most two short sentences for the user, naming who wants what.")
    var reason: String
    @Guide(description: "Refs of the lines the decision rests on, such as L4.")
    var evidence: [String]
    @Guide(.anyOf(["none", "open", "chat", "reaction"]))
    var action: String
}
