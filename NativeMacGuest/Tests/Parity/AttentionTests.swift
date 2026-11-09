import AppKit
import AVFoundation
import ConferenceCore
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

/// Attention: presets and feedback, the meeting window, the judge's contract,
/// the OpenAI-compatible client, storage, and the coordinator's card rules.
@MainActor final class AttentionTests: XCTestCase {
    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attention-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func store() -> AttentionStore {
        let defaults = UserDefaults(suiteName: "attention-\(UUID())")!
        let keychain = AttentionKeychain(service: "dev.vsmirn0v.conferenceguest.attention.tests.\(UUID().uuidString)")
        addTeardownBlock { keychain.deleteAll() }
        return AttentionStore(root: folder(), defaults: defaults, keychain: keychain)
    }
    private func message(_ id: String, _ who: String, _ text: String, _ at: Date, own: Bool = false) -> GuestMeetingMessage {
        GuestMeetingMessage(id: id, participantID: who, participantName: who, text: text, sentAt: at, isOwn: own, receivedAt: at)
    }

    // MARK: Presets

    func testFeedbackMovesTheThresholdWithinBounds() {
        var preset = MeetingPreset(title: "d2v2", bindings: [.room("https://example.test/a")])
        XCTAssertEqual(preset.threshold, 0.55, accuracy: 0.0001)
        func example(_ decision: PresetExample.Decision) -> PresetExample {
            .init(at: Date(), level: .now, decision: decision, excerpt: "Anna: DNS?", reason: "Asked about DNS")
        }
        preset.record(example(.declined))
        XCTAssertEqual(preset.threshold, 0.60, accuracy: 0.0001, "A decline makes the meeting quieter")
        for _ in 0..<20 { preset.record(example(.declined)) }
        XCTAssertEqual(preset.threshold, 0.8, accuracy: 0.0001, "Never quieter than the upper bound")
        for _ in 0..<40 { preset.record(example(.approved)) }
        XCTAssertEqual(preset.threshold, 0.3, accuracy: 0.0001, "Never more eager than the lower bound")
        XCTAssertEqual(preset.examples.count, MeetingPreset.exampleLimit)
        XCTAssertEqual(preset.promptExamples.count, 10)
        XCTAssertEqual(preset.promptExamples.first?.id, preset.examples.last?.id, "The judge sees the newest first")
        preset.urgency = .quiet
        XCTAssertLessThanOrEqual(preset.threshold, 0.8)
    }

    // MARK: Window

    func testWindowKeepsThreeMinutesInSpokenOrderAndMarksMentions() {
        let now = Date()
        let transcript = [
            message("old", "Anna", "Это было давно.", now.addingTimeInterval(-400)),
            message("t1", "Igor", "Сертификаты истекают в пятницу.", now.addingTimeInterval(-90)),
            message("t3", "Anna", "Виталий, когда будет готов DNS?", now.addingTimeInterval(-10)),
            message("me", "Vitalii", "Сегодня к вечеру.", now.addingTimeInterval(-5), own: true),
        ]
        let chat = [ChatEntry(id: "c1", sender: "Igor", text: "ссылка на план", sentAt: now.addingTimeInterval(-60), isOwn: false)]
        let window = AttentionWindowBuilder.build(.init(title: "d2v2", transcript: transcript, chat: chat, reactions: [],
            participantCount: 4, joined: ["Maria"], yourNames: ["Виталий", "Vitalii"], microphoneOn: false, soundOn: false, now: now))
        XCTAssertEqual(window.lines.map(\.id), ["t1", "chat-c1", "t3", "me"], "Older than three minutes is left out; chat is placed by time")
        XCTAssertEqual(window.lines.map(\.ref), ["L1", "L2", "L3", "L4"])
        XCTAssertEqual(window.lines.filter(\.mentionsYou).map(\.id), ["t3"], "Your own line does not count as a mention of you")
        XCTAssertTrue(window.lines[3].isYou)
        XCTAssertEqual(window.lines[1].source, .chat)
        let again = AttentionWindowBuilder.build(.init(title: "d2v2", transcript: transcript, chat: chat, reactions: [],
            participantCount: 4, joined: ["Maria"], yourNames: ["Виталий"], microphoneOn: false, soundOn: false, now: now))
        XCTAssertEqual(again.fingerprint, window.fingerprint, "The same content is the same window")
        let more = AttentionWindowBuilder.build(.init(title: "d2v2", transcript: transcript + [message("t4", "Igor", "Ждём.", now)],
            chat: chat, reactions: [], participantCount: 4, joined: ["Maria"], yourNames: [], microphoneOn: false, soundOn: false, now: now))
        XCTAssertNotEqual(more.fingerprint, window.fingerprint)
    }

    func testWindowCapsLinesAndMentionsIgnoreCaseAndDiacritics() {
        let now = Date()
        let transcript = (0..<80).map { message("t\($0)", "Anna", "line \($0)", now.addingTimeInterval(Double($0) - 100)) }
        let window = AttentionWindowBuilder.build(.init(title: "x", transcript: transcript, chat: [], reactions: [],
            participantCount: 2, yourNames: [], microphoneOn: false, soundOn: true, now: now))
        XCTAssertEqual(window.lines.count, AttentionWindowBuilder.lineLimit)
        XCTAssertEqual(window.lines.last?.id, "t79", "The newest lines are kept")
        XCTAssertTrue(AttentionWindowBuilder.mentions("Привет, ВИТАЛИЙ!", ["виталий"]))
        XCTAssertTrue(AttentionWindowBuilder.mentions("Ask Zoë", ["Zoe"]))
        XCTAssertFalse(AttentionWindowBuilder.mentions("Ask Anna", ["Zoe"]))
        XCTAssertEqual(AttentionProfile(name: "", aliases: ["Вит", " ", "V"]).names(fallback: "Vitalii"), ["Vitalii", "Вит"],
                       "Blank and one-letter names are not mentions")
    }

    // MARK: Prompt and verdict

    private func sampleWindow(now: Date = Date()) -> AttentionWindow {
        AttentionWindowBuilder.build(.init(title: "d2v2", transcript: [
            message("t1", "Igor", "Сертификаты истекают в пятницу.", now.addingTimeInterval(-30)),
            message("t2", "Anna", "Виталий, DNS готов? Ждём тебя.", now.addingTimeInterval(-10)),
        ], chat: [], reactions: [], participantCount: 3, yourNames: ["Виталий"], microphoneOn: false, soundOn: false, now: now))
    }

    func testEscalationOnlyForUnsureVerdictsAndAConfiguredOtherJudge() {
        let root = folder(), defaults = UserDefaults(suiteName: "attention-\(UUID())")!
        let keychain = AttentionKeychain(service: "dev.vsmirn0v.conferenceguest.attention.tests.\(UUID().uuidString)")
        addTeardownBlock { keychain.deleteAll() }
        let store = AttentionStore(root: root, defaults: defaults, keychain: keychain)
        store.provider = AttentionProvider.defaults[.apple]!
        func verdict(_ probability: Double) -> AttentionVerdict {
            .init(level: .soon, probability: probability, reason: "r", evidence: [], action: .none)
        }
        XCTAssertNil(store.escalation(for: verdict(0.5)), "No escalation judge chosen")
        store.escalationProvider = AttentionProvider.defaults[.openAI]
        XCTAssertNil(store.escalation(for: verdict(0.5)), "The API judge needs its key first")
        store.setAPIKey("sk-test")
        XCTAssertNil(store.escalation(for: verdict(0.5)), "The judge's key belongs to the judge's provider")
        store.setAPIKey("sk-test", for: AttentionProvider.defaults[.openAI]!)
        XCTAssertEqual(store.escalation(for: verdict(0.5))?.kind, .openAI)
        XCTAssertEqual(store.escalation(for: verdict(0.35))?.kind, .openAI)
        XCTAssertNil(store.escalation(for: verdict(0.8)), "A confident judge decides alone")
        XCTAssertNil(store.escalation(for: verdict(0.2)))
        store.escalationProvider = AttentionProvider.defaults[.apple]
        XCTAssertNil(store.escalation(for: verdict(0.5)), "Never ask the same judge again")
        let reloaded = AttentionStore(root: root, defaults: defaults, keychain: keychain)
        XCTAssertEqual(reloaded.escalationProvider?.kind, .apple)
    }

    /// Review finding 1: one key used to go to every provider, so an OpenRouter writer
    /// or escalation received the OpenAI key. Each provider kind has its own now.
    func testEachProviderKindSendsItsOwnKeyAndTheOldKeyMovesToTheJudge() {
        let root = folder(), defaults = UserDefaults(suiteName: "attention-\(UUID())")!
        let keychain = AttentionKeychain(service: "dev.vsmirn0v.conferenceguest.attention.tests.\(UUID().uuidString)")
        addTeardownBlock { keychain.deleteAll() }
        let openAI = AttentionProvider.defaults[.openAI]!, openRouter = AttentionProvider.defaults[.openRouter]!
        let first = AttentionStore(root: root, defaults: defaults, keychain: keychain)
        first.provider = openRouter
        keychain.write("sk-legacy")   // as a pre-beta-71 install left it
        let store = AttentionStore(root: root, defaults: defaults, keychain: keychain)
        XCTAssertNil(keychain.read(), "The single old key is moved, not kept")
        XCTAssertEqual(store.apiKey(for: openRouter), "sk-legacy", "It belonged to the judge's provider")
        XCTAssertNil(store.apiKey(for: openAI))
        XCTAssertFalse(store.hasKey(for: openAI))
        store.setAPIKey("sk-openai", for: openAI)
        XCTAssertEqual(store.apiKey(for: openAI), "sk-openai")
        XCTAssertEqual(store.apiKey(), "sk-legacy", "The judge keeps its own key")
        store.writerProvider = openAI; store.draftReplies = true
        XCTAssertTrue(store.draftsAllowed)
        store.setAPIKey("", for: openAI)
        XCTAssertFalse(store.draftsAllowed, "The writer's key, not the judge's, decides")
    }

    func testAppleWriterCanDraftWhenLocalDraftsAreAllowed() {
        let store = store()
        store.provider = AttentionProvider.defaults[.apple]!
        store.draftReplies = true
        XCTAssertFalse(store.draftsAllowed, "Drafting on this Mac stays opt-in")
        store.localDrafts = true
        XCTAssertTrue(store.draftsAllowed, "The Apple writer has no address but can draft")
    }

    func testUnansweredQuestionWaitsForSilenceAndIgnoresOwnAndAnswered() {
        let now = Date()
        func window(_ lines: [(String, String, TimeInterval, Bool)]) -> AttentionWindow {
            AttentionWindowBuilder.build(.init(title: "d2v2", transcript: lines.enumerated().map { index, line in
                message("q\(index)", line.0, line.1, now.addingTimeInterval(line.2), own: line.3)
            }, chat: [], reactions: [], participantCount: 3, yourNames: ["Виталий"], microphoneOn: false, soundOn: false, now: now))
        }
        let asked = window([("Anna", "Кто проверит сертификаты?", -5, false)])
        XCTAssertEqual(asked.unansweredQuestion(now: now, after: nil)?.text, "Кто проверит сертификаты?")
        XCTAssertNil(window([("Anna", "Кто проверит сертификаты?", -2, false)]).unansweredQuestion(now: now, after: nil),
                     "Under four seconds of silence is not yet a wait")
        XCTAssertNil(window([("Anna", "Кто проверит?", -9, false), ("Igor", "Я проверю.", -6, false)])
            .unansweredQuestion(now: now, after: nil), "Someone answered")
        XCTAssertNil(window([("Me", "Всё готово?", -6, true)]).unansweredQuestion(now: now, after: nil), "Your own question")
        XCTAssertNil(asked.unansweredQuestion(now: now, after: now.addingTimeInterval(-1)), "Already judged after it")
        XCTAssertNil(window([("Anna", "Проверим сертификаты.", -6, false)]).unansweredQuestion(now: now, after: nil))
    }

    func testPromptCarriesInstructionsExamplesAndMarkedLines() {
        var preset = MeetingPreset(title: "d2v2", bindings: [], about: "Weekly infra sync", matters: "DNS cut-over",
                                   people: ["Анна"], never: "Budget is not mine")
        preset.record(.init(at: Date(), level: .now, decision: .declined, declineReason: .alreadyKnown, excerpt: "Anna: budget?", reason: "Budget"))
        let request = JudgeRequest(window: sampleWindow(), preset: preset, profile: .init(name: "Виталий", aliases: ["Витя"], role: "infra lead"),
                                   yourName: "Vitalii", language: "ru")
        let messages = AttentionPrompt.messages(request)
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertTrue(messages[0]["content"]!.contains("Russian"))
        let user = messages[1]["content"]!
        for expected in ["Виталий (also called Витя)", "infra lead", "Weekly infra sync", "DNS cut-over", "Анна", "Budget is not mine",
                         "did not need attention", "alreadyKnown", "L2", "Anna: Виталий, DNS готов?"] {
            XCTAssertTrue(user.contains(expected), "Prompt misses \(expected)")
        }
        let body = OpenAIChatJudge.body(request, model: "m")
        let format = try? XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
    }

    func testVerdictIsCheckedAgainstTheWindow() throws {
        let window = sampleWindow()
        let verdict = try AttentionPrompt.verdict(from: #"{"attention":"now","probability":0.86,"reason":"Anna is waiting for your DNS answer.","evidence":["L2","L2"],"action":"open"}"#, window: window)
        XCTAssertEqual(verdict.level, .now); XCTAssertEqual(verdict.evidence, ["t2"], "Refs become line ids, once each")
        XCTAssertThrowsError(try AttentionPrompt.verdict(from: #"{"attention":"now","probability":0.9,"reason":"x","evidence":["L9"],"action":"open"}"#, window: window)) {
            XCTAssertEqual($0 as? AttentionVerdictError, .unknownEvidence("L9"))
        }
        XCTAssertThrowsError(try AttentionPrompt.verdict(from: #"{"attention":"soon","probability":1.4,"reason":"x","evidence":["L1"],"action":"none"}"#, window: window))
        XCTAssertThrowsError(try AttentionPrompt.verdict(from: #"{"attention":"now","probability":0.9,"reason":"x","evidence":[],"action":"open"}"#, window: window)) {
            XCTAssertEqual($0 as? AttentionVerdictError, .noEvidence)
        }
        XCTAssertThrowsError(try AttentionPrompt.verdict(from: "Sure! Here is my answer", window: window)) {
            XCTAssertEqual($0 as? AttentionVerdictError, .malformed)
        }
        let quiet = try AttentionPrompt.verdict(from: #"{"attention":"no","probability":0.1,"reason":"Small talk.","evidence":[],"action":"none"}"#, window: window)
        XCTAssertEqual(quiet.level, .no)
    }

    // MARK: Client

    func testClientSendsSchemaAndKeyAndParsesTheVerdict() async throws {
        let session = StubProtocol.session { request in
            XCTAssertEqual(request.url?.absoluteString, "https://judge.example.test/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key-not-real")
            let body = try JSONSerialization.jsonObject(with: StubProtocol.body(request)) as? [String: Any]
            XCTAssertEqual(body?["model"] as? String, "judge-model")
            return (200, StubProtocol.answer(#"{"attention":"now","probability":0.9,"reason":"Anna waits.","evidence":["L2"],"action":"open"}"#))
        }
        let judge = OpenAIChatJudge(provider: .init(kind: .custom, baseURL: "https://judge.example.test/v1/", model: "judge-model"),
                                    key: "test-key-not-real", session: session, retryDelays: [0, 0])
        let result = try await judge.judge(.init(window: sampleWindow(), preset: nil, profile: .init(), yourName: "V", language: "en"))
        XCTAssertEqual(result.verdict.evidence, ["t2"])
    }

    func testClientMapsErrorsAndRetriesServerFailures() async throws {
        var calls = 0
        let flaky = StubProtocol.session { _ in
            calls += 1
            return calls < 3 ? (503, Data()) : (200, StubProtocol.answer(#"{"attention":"no","probability":0.1,"reason":"Quiet.","evidence":[],"action":"none"}"#))
        }
        let provider = AttentionProvider(kind: .custom, baseURL: "https://judge.example.test/v1", model: "m")
        let request = JudgeRequest(window: sampleWindow(), preset: nil, profile: .init(), yourName: "V", language: "en")
        let result = try await OpenAIChatJudge(provider: provider, key: "k", session: flaky, retryDelays: [0, 0]).judge(request)
        XCTAssertEqual(result.verdict.level, .no); XCTAssertEqual(calls, 3, "Two retries after server errors")
        let denied = StubProtocol.session { _ in (401, Data()) }
        do { _ = try await OpenAIChatJudge(provider: provider, key: "k", session: denied, retryDelays: [0, 0]).judge(request); XCTFail("401") }
        catch { XCTAssertEqual(error as? AttentionJudgeError, .unauthorized(nil)) }
        var quotaCalls = 0
        let quota = StubProtocol.session { _ in
            quotaCalls += 1
            return (429, Data(#"{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","code":"insufficient_quota"}}"#.utf8))
        }
        do { _ = try await OpenAIChatJudge(provider: provider, key: "k", session: quota, retryDelays: [0, 0]).judge(request); XCTFail("quota") }
        catch {
            XCTAssertEqual(error as? AttentionJudgeError, .quota("You exceeded your current quota."))
            XCTAssertTrue(error.localizedDescription.contains("You exceeded your current quota."), "The provider's own reason is shown")
        }
        XCTAssertEqual(quotaCalls, 1, "A quota error is not retried")
        XCTAssertEqual(AttentionJudgeError.from(status: 429, body: Data(#"{"error":{"message":"Slow down","code":"rate_limit_exceeded"}}"#.utf8)),
                       .rateLimited("Slow down"))
        XCTAssertEqual(AttentionJudgeError.from(status: 402, body: Data()), .quota(nil))
        XCTAssertEqual(AttentionJudgeError.from(status: 500, body: Data("<html>".utf8)), .http(500, nil))
        do { _ = try await OpenAIChatJudge(provider: provider, key: nil, session: denied).judge(request); XCTFail("no key") }
        catch { XCTAssertEqual(error as? AttentionJudgeError, .missingKey) }
        let local = AttentionProvider(kind: .local, baseURL: "http://127.0.0.1:11434/v1", model: "m")
        XCTAssertFalse(local.needsKey)
        XCTAssertNil(AttentionProvider(kind: .custom, baseURL: "ftp://x", model: "m").endpoint)
    }

    func testModelCatalogListsSearchesAndPutsStructuredOutputFirst() async throws {
        let session = StubProtocol.session { request in
            XCTAssertEqual(request.url?.absoluteString, "https://judge.example.test/api/v1/models")
            return (200, try JSONSerialization.data(withJSONObject: ["data": [
                ["id": "vendor/plain-model", "name": "Plain", "context_length": 8000, "supported_parameters": ["temperature"],
                 "pricing": ["prompt": "0.0000001"]],
                ["id": "openai/gpt-4.1-mini", "name": "OpenAI: GPT-4.1 Mini", "context_length": 1_047_576,
                 "supported_parameters": ["response_format", "structured_outputs"], "pricing": ["prompt": "0.0000004"]],
                ["id": "openai/gpt-4.1-mini"],
                ["id": "qwen/qwen3-8b", "supported_parameters": ["structured_outputs"]],
            ]]))
        }
        let provider = AttentionProvider(kind: .openRouter, baseURL: "https://judge.example.test/api/v1", model: "")
        let models = try await AttentionModelCatalog.fetch(provider, key: nil, session: session)
        XCTAssertEqual(models.map(\.id), ["openai/gpt-4.1-mini", "qwen/qwen3-8b", "vendor/plain-model"],
                       "Duplicates dropped; models with structured output first")
        XCTAssertEqual(models[0].promptPrice ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(models[2].structuredOutput, false)
        XCTAssertEqual(AttentionModelCatalog.filter(models, query: "GPT mini").map(\.id), ["openai/gpt-4.1-mini"])
        XCTAssertEqual(AttentionModelCatalog.filter(models, query: "  ").count, 3)
        let openAI = AttentionModelCatalog.parse([["id": "gpt-4.1-mini", "object": "model", "owned_by": "openai"]])
        XCTAssertNil(openAI[0].structuredOutput, "OpenAI does not list capabilities; nothing is guessed")
        let denied = StubProtocol.session { _ in (401, Data(#"{"error":{"message":"Incorrect API key provided"}}"#.utf8)) }
        do { _ = try await AttentionModelCatalog.fetch(provider, key: "k", session: denied); XCTFail("401") }
        catch { XCTAssertEqual(error as? AttentionJudgeError, .unauthorized("Incorrect API key provided")) }
    }

#if NATIVE_DIRECT_UPDATES
    func testPublishedInventoryNamesTheNewestBuildForTheChannel() {
        let data = Data(#"{"schemaVersion":1,"stable":{"build":"53","downloadURL":"https://example.test/53.dmg"},"beta":{"build":"55","downloadURL":"https://example.test/55.dmg"}}"#.utf8)
        XCTAssertEqual(NativeDesktopUpdates.latestBuild(in: data, beta: true)?.build, 55)
        XCTAssertEqual(NativeDesktopUpdates.latestBuild(in: data, beta: false)?.build, 53)
        XCTAssertNil(NativeDesktopUpdates.latestBuild(in: Data("{}".utf8), beta: true))
    }
#endif

    // MARK: Store

    func testStoreResolvesPresetsAndKeepsThemAcrossLaunches() throws {
        let store = store()
        let room = URL(string: "https://example.test/calls/abc")!
        store.profile = .init(name: "Vitalii", aliases: ["Витя"], role: "infra")
        let preset = MeetingPreset(title: "Daily", bindings: [.room(room.absoluteString), .calendarSeries("series-1")], matters: "DNS")
        store.save(preset)
        XCTAssertEqual(store.preset(room: room)?.id, preset.id)
        XCTAssertEqual(store.preset(room: URL(string: "https://example.test/calls/other")!, series: "series-1")?.id, preset.id,
                       "Another occurrence of the series uses the same instructions")
        XCTAssertNil(store.preset(room: URL(string: "https://example.test/calls/other")!))
        let reloaded = AttentionStore(root: store.root, defaults: UserDefaults(suiteName: "attention-\(UUID())")!, keychain: .init(service: "unused-\(UUID())"))
        XCTAssertEqual(reloaded.presets, [preset]); XCTAssertEqual(reloaded.profile.aliases, ["Витя"])
    }

    func testKeyStaysInTheKeychainAndOutOfTheDecisionLog() throws {
        let store = store()
        store.provider = .init(kind: .custom, baseURL: "https://judge.example.test/v1", model: "m")
        XCTAssertFalse(store.hasKey); store.enabled = true; XCTAssertFalse(store.ready, "A cloud provider needs a key")
        XCTAssertTrue(store.setAPIKey("  test-secret-value  "))
        XCTAssertTrue(store.hasKey); XCTAssertTrue(store.ready); XCTAssertEqual(store.apiKey(), "test-secret-value")
        store.log(.init(at: Date(), meetingTitle: "Daily", presetID: nil, window: sampleWindow(), verdict: nil,
                        provider: store.provider.host, model: "m", outcome: .failed, error: "unauthorized"))
        let files = store.decisionFiles()
        XCTAssertEqual(files.count, 1)
        let text = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertFalse(text.contains("test-secret-value")); XCTAssertTrue(text.contains("judge.example.test"))
        XCTAssertFalse(String(data: try JSONEncoder().encode(store.provider), encoding: .utf8)!.contains("test-secret-value"))
        store.setAPIKey(""); XCTAssertFalse(store.hasKey)
    }

    func testDecisionLogDropsFilesOlderThanThirtyDays() throws {
        let store = store()
        store.log(.init(at: Date().addingTimeInterval(-40 * 24 * 3600), meetingTitle: "old", presetID: nil, window: nil, verdict: nil,
                        provider: "p", model: "m", outcome: .shown))
        XCTAssertEqual(store.decisionFiles().count, 1)
        store.log(.init(at: Date(), meetingTitle: "new", presetID: nil, window: nil, verdict: nil, provider: "p", model: "m", outcome: .shown))
        XCTAssertEqual(store.decisionFiles().count, 1, "The 40-day-old file is removed")
    }

    // MARK: Mixed audio (Telemost, TrueConf)

    func testSpeakingTimelineAttributesMixedSpeech() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var timeline = SpeakingTimeline()
        timeline.observe(speaking: ["anna"], at: t0)
        timeline.observe(speaking: ["anna"], at: t0.addingTimeInterval(1))
        timeline.observe(speaking: [], at: t0.addingTimeInterval(4))
        timeline.observe(speaking: ["igor"], at: t0.addingTimeInterval(6))
        let now = t0.addingTimeInterval(9)
        XCTAssertEqual(timeline.speaker(start: t0.addingTimeInterval(0.5), end: t0.addingTimeInterval(3.5), now: now), "anna")
        XCTAssertEqual(timeline.speaker(start: t0.addingTimeInterval(6.5), end: t0.addingTimeInterval(8.5), now: now), "igor",
                       "Someone still speaking counts until now")
        XCTAssertNil(timeline.speaker(start: t0.addingTimeInterval(4.6), end: t0.addingTimeInterval(5.4), now: now), "No one was speaking")
        XCTAssertNil(timeline.speaker(start: t0.addingTimeInterval(2), end: t0.addingTimeInterval(8), now: now),
                     "Neither covers half of a line spanning both")
        var both = SpeakingTimeline()
        both.observe(speaking: ["anna", "igor"], at: t0); both.observe(speaking: [], at: t0.addingTimeInterval(3))
        XCTAssertNil(both.speaker(start: t0, end: t0.addingTimeInterval(3), now: now), "Two people equally: no guess")
        var old = SpeakingTimeline()
        old.observe(speaking: ["anna"], at: t0); old.observe(speaking: [], at: t0.addingTimeInterval(1))
        old.observe(speaking: [], at: t0.addingTimeInterval(SpeakingTimeline.retention + 10))
        XCTAssertTrue(old.closed.isEmpty, "Old intervals are dropped")
    }

    func testMixedStreamLinesGetTheSpeakerTheServiceReported() async throws {
        let (infra, _) = try await meeting("telemost-like")
        let t0 = Date()
        infra.observeSpeakingForTesting(["anna"], at: t0)
        infra.observeSpeakingForTesting([], at: t0.addingTimeInterval(3))
        infra.receiveLocalLineForTesting(.init(id: "m1", trackID: "mixed", text: "Виталий, DNS готов?",
            start: t0.addingTimeInterval(0.4), end: t0.addingTimeInterval(2.6)))
        XCTAssertEqual(infra.localTranscript.last?.participantName, "Anna")
        XCTAssertEqual(infra.localTranscript.last?.participantID, "anna")
        infra.receiveLocalLineForTesting(.init(id: "m2", trackID: "mixed", text: "Кто это?",
            start: t0.addingTimeInterval(10), end: t0.addingTimeInterval(11)))
        XCTAssertEqual(infra.localTranscript.last?.participantName, L("Participant"))
    }

    func testTranscriptionSourcesDefaultToGuestExternalOnRockOff() {
        let store = ListenModelStore(catalog: .init(schemaVersion: 1, runtime: "test", models: []), root: folder(),
                                     defaults: UserDefaults(suiteName: "listen-\(UUID())")!)
        XCTAssertTrue(store.transcribesExternal); XCTAssertFalse(store.transcribesRock); XCTAssertTrue(store.includesMicrophone)
    }

    // MARK: Coordinator

    private func meeting(_ name: String) async throws -> (NativeDesktopMeetingModel, AttentionTestEngine) {
        let engine = AttentionTestEngine()
        let model = NativeDesktopMeetingModel(destination: try .verified(URL(string: "https://example.test/calls/\(name)")!, engine: .guest),
                                              name: "Vitalii", title: name, engine: engine)
        try await model.connect()
        addTeardownBlock { _ = await model.leave() }
        return (model, engine)
    }

    func testCoordinatorShowsOneCardAndLearnsFromYourDecisions() async throws {
        let store = store()
        store.enabled = true; store.provider = .init(kind: .local, baseURL: "http://127.0.0.1:1/v1", model: "m")
        store.situationModes[.background] = .watch // This test exercises the Watch cadence, not the default.
        let (daily, _) = try await meeting("daily"), (infra, _) = try await meeting("infra")
        let judge = FakeJudge()
        var clock = Date(), opened: [UUID] = [], notified = 0
        let coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { [daily, infra] }
        coordinator.isOnScreen = { $0 === daily }
        coordinator.hasTranscript = { _ in true }
        coordinator.makeJudge = { _, _ in judge }
        coordinator.now = { clock }
        coordinator.openMeeting = { opened.append($0) }
        coordinator.notify = { _ in notified += 1 }

        await coordinator.tick()
        XCTAssertEqual(judge.calls, 0, "Nothing said yet: nothing to judge")
        daily.receiveLocalLineForTesting(.init(id: "d1", trackID: "a", text: "Виталий, ты тут?", start: clock, end: clock))
        infra.receiveLocalLineForTesting(.init(id: "i1", trackID: "a", text: "Виталий, DNS готов?", start: clock, end: clock))
        judge.next = .init(level: .now, probability: 0.9, reason: "Anna waits.", evidence: ["L1"], action: .open)
        await coordinator.tick()
        XCTAssertEqual(judge.calls, 1); XCTAssertEqual(judge.lastTitle, "infra", "The meeting on screen is not judged")
        let card = try XCTUnwrap(coordinator.card(for: infra.sessionID))
        XCTAssertEqual(card.verdict.level, .now); XCTAssertEqual(notified, 1)

        clock += 30
        await coordinator.tick()
        XCTAssertEqual(judge.calls, 1, "An unchanged window is not judged again")
        infra.receiveLocalLineForTesting(.init(id: "i2", trackID: "a", text: "Ладно, обсудим позже.", start: clock, end: clock))
        judge.next = .init(level: .soon, probability: 0.9, reason: "Still about DNS.", evidence: ["L1"], action: .open)
        await coordinator.tick()
        XCTAssertEqual(judge.calls, 2)
        XCTAssertEqual(coordinator.card(for: infra.sessionID)?.id, card.id, "A held 'now' card is not replaced by repeated evidence")

        coordinator.decline(card, reason: .alreadyKnown)
        XCTAssertNil(coordinator.card(for: infra.sessionID))
        let preset = try XCTUnwrap(store.preset(room: infra.invitation), "Declining creates the room's instructions")
        XCTAssertEqual(preset.examples.last?.decision, .declined); XCTAssertEqual(preset.examples.last?.excerpt, L("Participant") + ": Виталий, DNS готов?")
        XCTAssertEqual(preset.threshold, 0.6, accuracy: 0.0001)

        clock += 30
        infra.receiveLocalLineForTesting(.init(id: "i3", trackID: "a", text: "Виталий, срочно нужен ответ.", start: clock, end: clock))
        judge.next = .init(level: .now, probability: 0.58, reason: "Asked again.", evidence: ["L3"], action: .open)
        await coordinator.tick()
        XCTAssertNil(coordinator.card(for: infra.sessionID), "Below the preset's raised threshold: no card")
        clock += 30
        infra.receiveLocalLineForTesting(.init(id: "i4", trackID: "a", text: "Виталий?", start: clock, end: clock))
        judge.next = .init(level: .now, probability: 0.95, reason: "Waiting for you.", evidence: ["L4"], action: .open)
        await coordinator.tick()
        let second = try XCTUnwrap(coordinator.card(for: infra.sessionID))
        coordinator.open(second)
        XCTAssertEqual(opened, [infra.sessionID]); XCTAssertNil(coordinator.card(for: infra.sessionID))
        XCTAssertEqual(store.preset(room: infra.invitation)?.examples.last?.decision, .approved)

        let decisions = try store.decisionFiles().map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        for outcome in ["shown", "belowThreshold", "declined", "opened"] { XCTAssertTrue(decisions.contains("\"\(outcome)\""), outcome) }
        XCTAssertTrue(decisions.contains("\"messages\""), "Verdicts keep the exact prompt for replay")
    }

    /// Review finding 4: a qualifying card that lost to two more urgent ones still marked
    /// its evidence as shown (so it never came back) and was logged as below threshold.
    func testCrowdedOutCardLeavesItsEvidenceForLaterAndIsLoggedAsSuch() async throws {
        let store = store()
        store.enabled = true; store.provider = .init(kind: .local, baseURL: "http://127.0.0.1:1/v1", model: "m")
        store.situationModes[.background] = .watch // This test exercises the Watch cadence, not the default.
        let (a, _) = try await meeting("a"), (b, _) = try await meeting("b"), (c, _) = try await meeting("c")
        let judge = FakeJudge()
        var clock = Date()
        let coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { [a, b, c] }
        coordinator.hasTranscript = { _ in true }
        coordinator.makeJudge = { _, _ in judge }
        coordinator.now = { clock }
        for (model, id) in [(a, "a1"), (b, "b1"), (c, "c1")] {
            model.receiveLocalLineForTesting(.init(id: id, trackID: "t", text: "Виталий, нужен ответ", start: clock, end: clock))
        }
        judge.next = .init(level: .now, probability: 0.9, reason: "Waiting.", evidence: ["L1"], action: .open)
        await coordinator.tick(); await coordinator.tick()
        XCTAssertNotNil(coordinator.card(for: a.sessionID)); XCTAssertNotNil(coordinator.card(for: b.sessionID))
        judge.next = .init(level: .soon, probability: 0.9, reason: "Soon.", evidence: ["L1"], action: .open)
        await coordinator.tick()
        XCTAssertEqual(judge.lastTitle, "c")
        XCTAssertNil(coordinator.card(for: c.sessionID), "two 'now' cards hold the screen")
        XCTAssertEqual(coordinator.cards.count, 2)

        coordinator.dismiss(try XCTUnwrap(coordinator.card(for: a.sessionID)))
        clock += 30
        c.receiveLocalLineForTesting(.init(id: "c2", trackID: "t", text: "Ждём", start: clock, end: clock))
        await coordinator.tick()
        XCTAssertNotNil(coordinator.card(for: c.sessionID), "the crowded-out lines can still raise a card")
        let decisions = try store.decisionFiles().map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(decisions.contains("\"crowdedOut\""))
    }

    /// Your choice for the meeting beats its series' mode, which beats the situation default;
    /// a timed choice runs out; the situation follows the meeting as it is silenced or shown.
    func testModeResolvesFromMeetingThenSeriesThenSituation() async throws {
        let store = store()
        store.enabled = true; store.provider = .init(kind: .local, baseURL: "http://127.0.0.1:1/v1", model: "m")
        let (infra, engine) = try await meeting("infra")
        var clock = Date(), onScreen = false
        let coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { [infra] }; coordinator.now = { clock }; coordinator.isOnScreen = { _ in onScreen }

        XCTAssertEqual(coordinator.resolvedMode(infra), .init(mode: .mentions, source: .situation(.background)))
        try await engine.setPlayout(false)
        XCTAssertEqual(coordinator.resolvedMode(infra), .init(mode: .watch, source: .situation(.silenced)))
        onScreen = true
        XCTAssertEqual(coordinator.resolvedMode(infra), .init(mode: .off, source: .situation(.onScreen)), "on screen beats silenced")
        XCTAssertEqual(coordinator.waitingReason(infra), L("You are looking at this meeting."))
        store.situationModes[.onScreen] = .mentions
        XCTAssertEqual(coordinator.resolvedMode(infra).mode, .mentions)
        onScreen = false

        coordinator.setMode(.watch, for: infra, scope: .series)
        XCTAssertEqual(coordinator.resolvedMode(infra), .init(mode: .watch, source: .series))
        XCTAssertEqual(store.preset(room: infra.invitation)?.mode, .watch, "Every time is kept on the room's instructions")

        coordinator.setMode(.off, for: infra, scope: .minutes(30))
        XCTAssertEqual(coordinator.resolvedMode(infra), .init(mode: .off, source: .meeting(until: clock.addingTimeInterval(1800))))
        clock += 1801
        await coordinator.tick()
        XCTAssertEqual(coordinator.resolvedMode(infra), .init(mode: .watch, source: .series), "the timed choice ran out")

        coordinator.cycleMode(for: infra)
        XCTAssertEqual(coordinator.resolvedMode(infra), .init(mode: .off, source: .meeting(until: nil)), "Watch → Off")
        coordinator.resetMode(for: infra, series: true)
        XCTAssertNil(store.preset(room: infra.invitation)?.mode)
        XCTAssertEqual(coordinator.resolvedMode(infra), .init(mode: .watch, source: .situation(.silenced)))
    }

    /// Mentions judges a window as soon as you are named, otherwise only every two minutes,
    /// and then shows a card only for an urgent "now"; Off removes the meeting's card.
    func testMentionsJudgesOnYourNameAndOtherwiseOnlyUrgentNow() async throws {
        let store = store()
        store.enabled = true; store.provider = .init(kind: .local, baseURL: "http://127.0.0.1:1/v1", model: "m")
        let (standup, _) = try await meeting("standup")
        let judge = FakeJudge()
        var clock = Date()
        let coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { [standup] }; coordinator.hasTranscript = { _ in true }
        coordinator.makeJudge = { _, _ in judge }; coordinator.now = { clock }
        coordinator.setMode(.mentions, for: standup)

        standup.receiveLocalLineForTesting(.init(id: "s1", trackID: "a", text: "Миграцию переносим на субботу.", start: clock, end: clock))
        judge.next = .init(level: .soon, probability: 0.9, reason: "Migration moved.", evidence: ["L1"], action: .open)
        await coordinator.tick()
        XCTAssertEqual(judge.calls, 1, "the first window is judged once")
        XCTAssertNil(coordinator.card(for: standup.sessionID), "not named: a 'soon' does not reach you in Mentions")

        clock += 30
        standup.receiveLocalLineForTesting(.init(id: "s2", trackID: "a", text: "Окно с часу ночи.", start: clock, end: clock))
        await coordinator.tick()
        XCTAssertEqual(judge.calls, 1, "no name, no urgency check before two minutes")

        clock += 30
        standup.receiveLocalLineForTesting(.init(id: "s3", trackID: "a", text: "Vitalii, can you confirm the window?", start: clock, end: clock))
        judge.next = .init(level: .soon, probability: 0.7, reason: "Asked to confirm.", evidence: ["L3"], action: .chat)
        await coordinator.tick()
        XCTAssertEqual(judge.calls, 2, "your name triggers the judge at once")
        let card = try XCTUnwrap(coordinator.card(for: standup.sessionID), "named: the card shows")
        XCTAssertEqual(card.mode, .mentions); XCTAssertTrue(card.mentioned)

        coordinator.setMode(.off, for: standup)
        XCTAssertNil(coordinator.card(for: standup.sessionID), "Off removes the meeting's card")
        coordinator.setMode(.mentions, for: standup)

        clock += Self.mentionsCadence
        standup.receiveLocalLineForTesting(.init(id: "s4", trackID: "a", text: "Прод упал, все сюда.", start: clock, end: clock))
        judge.next = .init(level: .now, probability: 0.85, reason: "Production is down.", evidence: ["L4"], action: .open)
        await coordinator.tick()
        XCTAssertEqual(judge.calls, 3, "two minutes on, the urgency check runs")
        XCTAssertEqual(coordinator.card(for: standup.sessionID)?.verdict.reason, "Production is down.", "an urgent 'now' reaches you without your name")
        let decisions = try store.decisionFiles().map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(decisions.contains("\"mentions\""), "decisions keep the mode they were judged in")
    }
    private static let mentionsCadence = AttentionCoordinator.mentionsInterval

    func testCoordinatorWaitsWhenOffPausedOrOnBatteryAndReportsFailures() async throws {
        let store = store()
        store.provider = .init(kind: .local, baseURL: "http://127.0.0.1:1/v1", model: "m")
        let (infra, _) = try await meeting("infra")
        let judge = FakeJudge(); judge.error = AttentionJudgeError.transport
        let coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { [infra] }; coordinator.hasTranscript = { _ in true }; coordinator.makeJudge = { _, _ in judge }
        coordinator.power = { .init(pluggedIn: false, lowPowerMode: false) }
        infra.receiveLocalLineForTesting(.init(id: "i1", trackID: "a", text: "Привет", start: Date(), end: Date()))
        XCTAssertEqual(coordinator.waitingReason(infra), L("Attention is off."))
        store.enabled = true
        coordinator.setMode(.off, for: infra)
        XCTAssertEqual(coordinator.waitingReason(infra), L("Off for this meeting."))
        coordinator.resetMode(for: infra)
        store.pauseOnBattery = true
        XCTAssertEqual(coordinator.waitingReason(infra), L("Paused on battery power."))
        store.pauseOnBattery = false
        XCTAssertNil(coordinator.waitingReason(infra))
        await coordinator.tick()
        XCTAssertEqual(judge.calls, 1)
        XCTAssertEqual(coordinator.lastError, AttentionJudgeError.transport.localizedDescription)
        XCTAssertTrue(coordinator.cards.isEmpty)
    }

    // MARK: Phase 5 — replies

    func testReplyDraftKeepsOnlyWhatTheMeetingAccepts() throws {
        let both = ReplyChannels(chat: true, reactions: [.like, .thanks])
        let draft = try ReplyPrompt.draft(from: #"{"chat":"«Да, через минуту подключусь.»","reaction":"like"}"#, channels: both)
        XCTAssertEqual(draft, ReplyDraft(chat: "Да, через минуту подключусь.", reaction: .like), "Quotes around the reply are removed")
        let unknown = try ReplyPrompt.draft(from: #"{"chat":"Ok","reaction":"fire"}"#, channels: both)
        XCTAssertNil(unknown.reaction, "A reaction the meeting does not offer is dropped")
        let noChat = try ReplyPrompt.draft(from: #"{"chat":"Ok","reaction":"thanks"}"#, channels: .init(chat: false, reactions: [.thanks]))
        XCTAssertEqual(noChat, ReplyDraft(chat: "", reaction: .thanks), "Text is dropped where the meeting has no chat")
        XCTAssertThrowsError(try ReplyPrompt.draft(from: #"{"chat":"  ","reaction":"none"}"#, channels: both)) {
            XCTAssertEqual($0 as? ReplyDraftError, .empty)
        }
        XCTAssertThrowsError(try ReplyPrompt.draft(from: "Sure!", channels: both)) { XCTAssertEqual($0 as? ReplyDraftError, .malformed) }
        let long = try ReplyPrompt.draft(from: "{\"chat\":\"\(String(repeating: "a", count: 900))\",\"reaction\":\"none\"}", channels: both)
        XCTAssertEqual(long.chat.count, ReplyPrompt.chatLimit)
        let reactions = (ReplyPrompt.schema(both)["properties"] as? [String: Any])?["reaction"] as? [String: Any]
        XCTAssertEqual(reactions?["enum"] as? [String], ["none", "like", "thanks"], "Only the meeting's reactions are offered")
    }

    func testReplyVariantsAreBoundedRankedAndLegacyRepliesStayDecodable() throws {
        let channels = ReplyChannels(chat: true, reactions: [.like])
        let content = #"{"chat":"Yes, DNS is ready.","reaction":"like","variants":[{"stance":"confirm","text":"Yes, DNS is ready."},{"stance":"ask for time","text":"I need five minutes."},{"stance":"confirm","text":"Yes, DNS is ready."},{"stance":"decline","text":"I cannot confirm yet."},{"stance":"extra","text":"This must be dropped."}]}"#
        let parsed = try ReplyPrompt.draft(from: content, channels: channels)
        XCTAssertEqual(parsed.variants?.count, 3)
        XCTAssertEqual(parsed.variants?.map(\.stance), ["confirm", "ask for time", "decline"])
        XCTAssertEqual(parsed.chat, "Yes, DNS is ready.")
        XCTAssertNil(try ReplyPrompt.draft(from: #"{"chat":"Legacy","reaction":"none"}"#, channels: channels).variants)
        XCTAssertThrowsError(try ReplyPrompt.draft(from: #"{"chat":"Voice","reaction":"none","variants":[{"stance":"confirm","text":"Voice"}]}"#,
                                                  channels: .init(chat: false))) { XCTAssertEqual($0 as? ReplyDraftError, .empty) }

        let edits = [ReplyEdit(at: Date(), draft: "I will check", sent: "I need five minutes to check DNS")]
        let ranked = parsed.ranked(preferredStance: nil, edits: edits)
        XCTAssertEqual(ranked.variants?.first?.stance, "ask for time", "Actual sent wording breaks a tie")
        let preferred = parsed.ranked(preferredStance: "decline", edits: edits)
        XCTAssertEqual(preferred.variants?.first?.stance, "decline", "A recorded stance pick ranks first")
        XCTAssertEqual(preferred.chat, "I cannot confirm yet.")
        XCTAssertEqual(parsed.ranked(preferredStance: nil, edits: []).variants?.map(\.id), parsed.variants?.map(\.id),
                       "Equal scores retain model order")
    }

    func testSelectingAVariantOnlyChangesTheDraftAndRecordsPreference() throws {
        let coordinator = AttentionCoordinator(store: store())
        var sent: [String] = []
        coordinator.deliverChat = { _, text in sent.append(text); return true }
        let window = sampleWindow()
        let first = ReplyVariant(stance: "confirm", text: "Yes")
        let second = ReplyVariant(stance: "decline", text: "Not yet")
        let card = AttentionCoordinator.Card(id: UUID(), meetingID: UUID(), meetingTitle: "Infra",
            invitation: URL(string: "https://example.test/infra")!, seriesID: nil,
            verdict: .init(level: .now, probability: 0.9, reason: "Asked", evidence: [], action: .chat),
            window: window, presetID: nil, threshold: 0.55, provider: "local", model: "m", latency: 0.1, createdAt: Date(),
            channels: .init(chat: true), draft: .init(chat: first.text, reaction: nil, variants: [first, second]))
        coordinator.selectedCard = card
        coordinator.selectVariant(second, for: card)
        XCTAssertEqual(coordinator.selectedCard?.draft?.chat, second.text)
        XCTAssertEqual(coordinator.store.assistant.preferredStance(), "decline")
        XCTAssertTrue(sent.isEmpty, "Choosing a stance never sends it")
    }

    func testReplyPromptCarriesDecisionStyleAndChannels() {
        var profile = AttentionProfile(name: "Vitalii"); profile.replyStyle = "Brief, informal"
        let window = sampleWindow()
        let judge = JudgeRequest(window: window, preset: nil, profile: profile, yourName: "Vitalii", language: "en",
                                 replyChannels: .init(chat: true, reactions: [.like]))
        let verdict = AttentionVerdict(level: .now, probability: 0.9, reason: "Anna asks whether DNS is ready.",
                                       evidence: window.lines.suffix(1).map(\.id), action: .chat)
        let messages = ReplyPrompt.messages(.init(judge: judge, verdict: verdict))
        let system = messages[0]["content"] ?? "", user = messages[1]["content"] ?? ""
        XCTAssertTrue(system.contains("Never invent facts")); XCTAssertTrue(system.contains("Brief, informal"))
        XCTAssertTrue(user.contains("Anna asks whether DNS is ready.")); XCTAssertTrue(user.contains("Based on " + (window.lines.last?.ref ?? "")))
        XCTAssertTrue(user.contains("a chat message or one reaction: like"))
        XCTAssertTrue(AttentionPrompt.userContent(judge).contains("can answer here without joining: chat and reactions"))
        var none = judge; none.replyChannels = .init()
        XCTAssertTrue(AttentionPrompt.userContent(none).contains("cannot answer here without joining"))
        let redraft = ReplyPrompt.userContent(.init(judge: judge, verdict: verdict, redraftHint: "Shorter, in English"))
        XCTAssertTrue(redraft.contains("Redraft direction from the user"))
        XCTAssertTrue(redraft.contains("Shorter, in English"))
    }

    func testCoordinatorDraftsAReplyAndSendsOnlyWhatYouApprove() async throws {
        let store = store()
        // A server elsewhere on the network: drafting with a model on this Mac is opt-in.
        store.enabled = true; store.provider = .init(kind: .local, baseURL: "http://192.168.1.5:1/v1", model: "m")
        store.situationModes[.background] = .watch // This test exercises the Watch cadence, not the default.
        let (infra, _) = try await meeting("infra")
        let judge = FakeJudge(), writer = FakeWriter()
        var sent: [String] = [], reacted: [MeetingReaction] = [], clock = Date()
        let coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { [infra] }; coordinator.hasTranscript = { _ in true }
        coordinator.makeJudge = { _, _ in judge }; coordinator.makeWriter = { _, _ in writer }
        coordinator.now = { clock }
        coordinator.replyChannels = { _ in .init(chat: true, reactions: [.like, .thanks]) }
        coordinator.deliverChat = { _, text in sent.append(text); return true }
        coordinator.deliverReaction = { _, reaction in reacted.append(reaction) }

        infra.receiveLocalLineForTesting(.init(id: "i1", trackID: "a", text: "Виталий, DNS готов?", start: clock, end: clock))
        judge.next = .init(level: .now, probability: 0.9, reason: "Anna waits.", evidence: ["L1"], action: .chat)
        await coordinator.tick()
        XCTAssertEqual(judge.lastChannels, .init(chat: true, reactions: [.like, .thanks]), "The judge knows how you could answer")
        try await spin { coordinator.card(for: infra.sessionID)?.draft != nil }
        let card = try XCTUnwrap(coordinator.card(for: infra.sessionID))
        XCTAssertEqual(writer.calls, 1); XCTAssertEqual(card.draft?.chat, "Сейчас посмотрю и отвечу.")
        XCTAssertTrue(sent.isEmpty, "A draft is never sent by itself")

        clock += 30
        infra.receiveLocalLineForTesting(.init(id: "i2", trackID: "a", text: "Виталий?", start: clock, end: clock))
        judge.next = .init(level: .now, probability: 0.95, reason: "Asked again.", evidence: ["L2"], action: .open)
        await coordinator.tick()
        XCTAssertEqual(coordinator.card(for: infra.sessionID)?.id, card.id, "A card you are replying from is not replaced")

        XCTAssertTrue(coordinator.sendReply(card, text: "Да, DNS готов."))
        XCTAssertEqual(sent, ["Да, DNS готов."]); XCTAssertNil(coordinator.card(for: infra.sessionID))
        XCTAssertEqual(store.preset(room: infra.invitation)?.examples.last?.decision, .approved, "Replying counts as approval")
        let log = try store.decisionFiles().map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        for field in ["\"drafted\"", "\"replied\"", "\"replyMessages\"", "\"edited\":true"] { XCTAssertTrue(log.contains(field), field) }

        // Reactions, and nothing at all when the meeting's instructions turn replies off.
        clock += 30
        infra.receiveLocalLineForTesting(.init(id: "i3", trackID: "a", text: "Спасибо всем!", start: clock, end: clock))
        judge.next = .init(level: .soon, probability: 0.9, reason: "Thanks for the team.", evidence: ["L3"], action: .open)
        await coordinator.tick()
        let thanks = try XCTUnwrap(coordinator.card(for: infra.sessionID))
        XCTAssertNil(thanks.draft, "Only a chat or reaction suggestion drafts by itself"); XCTAssertEqual(writer.calls, 1)
        XCTAssertTrue(coordinator.sendReaction(thanks, .thanks)); XCTAssertEqual(reacted, [.thanks])
        XCTAssertFalse(coordinator.sendReaction(thanks, .fire), "A reaction the meeting does not offer is refused")

        var preset = try XCTUnwrap(store.preset(room: infra.invitation)); preset.suggestReplies = false; store.save(preset)
        clock += 30
        infra.receiveLocalLineForTesting(.init(id: "i4", trackID: "a", text: "Виталий, ещё вопрос.", start: clock, end: clock))
        judge.next = .init(level: .now, probability: 0.95, reason: "Another question.", evidence: ["L4"], action: .chat)
        await coordinator.tick()
        XCTAssertEqual(judge.lastChannels, ReplyChannels()); XCTAssertEqual(coordinator.card(for: infra.sessionID)?.channels, ReplyChannels())
        XCTAssertEqual(writer.calls, 1, "Replies off for this meeting: nothing is drafted")

        // A judge on this Mac: reactions only, no draft, until you opt in.
        preset.suggestReplies = true; store.save(preset)
        if let card = coordinator.card(for: infra.sessionID) { coordinator.dismiss(card) }
        store.provider = .init(kind: .rapidMLX, baseURL: "http://127.0.0.1:8000/v1", model: "m")
        clock += 30
        infra.receiveLocalLineForTesting(.init(id: "i5", trackID: "a", text: "Виталий, подтверди окно.", start: clock, end: clock))
        judge.next = .init(level: .now, probability: 0.95, reason: "Confirm the window.", evidence: ["L5"], action: .chat)
        await coordinator.tick()
        let local = try XCTUnwrap(coordinator.card(for: infra.sessionID))
        XCTAssertFalse(local.canDraft); XCTAssertFalse(local.channels.reactions.isEmpty)
        coordinator.draftReply(local.id)
        XCTAssertEqual(writer.calls, 1, "No draft from a model on this Mac without your opt-in")
    }

    // MARK: Phase 4a — Rapid-MLX on this Mac

    func testRapidMLXRunsOnThisMacWithoutAKey() throws {
        let rapid = try XCTUnwrap(AttentionProvider.defaults[.rapidMLX])
        XCTAssertEqual(rapid.endpoint?.absoluteString, "http://127.0.0.1:8000/v1/chat/completions")
        XCTAssertEqual(rapid.model, AttentionProvider.rapidMLXModel)
        XCTAssertFalse(rapid.needsKey); XCTAssertTrue(rapid.onThisMac)
        XCTAssertTrue(AttentionProvider(kind: .local, baseURL: "http://localhost:11434/v1", model: "m").onThisMac)
        XCTAssertFalse(AttentionProvider(kind: .local, baseURL: "http://192.168.1.5:8000/v1", model: "m").onThisMac,
                       "A server elsewhere on the network is not this Mac")
        XCTAssertFalse(try XCTUnwrap(AttentionProvider.defaults[.openAI]).onThisMac)
        let violation = Data(#"{"error":{"message":"output did not match the schema","code":"json_schema_violation"}}"#.utf8)
        XCTAssertEqual(AttentionJudgeError.from(status: 422, body: violation), .verdict(.malformed))
        XCTAssertFalse(AttentionJudgeError.from(status: 422, body: violation).retryable)
        XCTAssertEqual(AttentionJudgeError.from(status: 422, body: Data("{}".utf8)), .http(422, nil))
    }

    /// A model on this Mac gets JSON mode with the shape in its instructions (strict
    /// schema there costs the prompt cache and half the speed); elsewhere the strict schema stays.
    func testModelsOnThisMacUseJSONModeAndFencedAnswersParse() throws {
        let request = JudgeRequest(window: sampleWindow(), preset: nil, profile: .init(name: "Vitalii"), yourName: "Vitalii", language: "ru")
        let messages = AttentionPrompt.messages(request)
        let local = OpenAIChatJudge(provider: try XCTUnwrap(AttentionProvider.defaults[.rapidMLX]), key: nil)
        let body = local.requestBody(messages: messages, name: AttentionPrompt.schemaName, schema: AttentionPrompt.schema, hint: AttentionPrompt.jsonHint)
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_object")
        XCTAssertEqual((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        let system = ((body["messages"] as? [[String: String]])?.first?["content"]) ?? ""
        XCTAssertTrue(system.hasSuffix(AttentionPrompt.jsonHint))
        let again = local.requestBody(messages: body["messages"] as? [[String: String]] ?? [], name: AttentionPrompt.schemaName,
                                      schema: AttentionPrompt.schema, hint: AttentionPrompt.jsonHint)
        XCTAssertEqual(((again["messages"] as? [[String: String]])?.first?["content"])?.components(separatedBy: "Answer with one JSON object").count, 2,
                       "Saved messages replayed locally get the shape once")
        let remote = OpenAIChatJudge(provider: try XCTUnwrap(AttentionProvider.defaults[.openAI]), key: "k")
        let strict = remote.requestBody(messages: messages, name: AttentionPrompt.schemaName, schema: AttentionPrompt.schema, hint: AttentionPrompt.jsonHint)
        XCTAssertEqual((strict["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
        XCTAssertNil(strict["chat_template_kwargs"])

        let ref = try XCTUnwrap(sampleWindow().lines.last?.ref)
        let fenced = "```json\n{\"attention\":\"now\",\"probability\":0.9,\"reason\":\"Ждут ответа.\",\"evidence\":[\"\(ref)\"],\"action\":\"chat\"}\n```"
        XCTAssertEqual(try AttentionPrompt.verdict(from: fenced, window: sampleWindow()).level, .now)
        XCTAssertEqual(try ReplyPrompt.draft(from: "```\n{\"chat\":\"Сейчас посмотрю.\",\"reaction\":\"none\"}\n```", channels: .init(chat: true)).chat, "Сейчас посмотрю.")
        XCTAssertTrue(ReplyPrompt.jsonHint(.init(chat: true, reactions: [.like])).contains(#""none"|"like""#))
    }

    func testDraftingWithAModelOnThisMacIsOptIn() throws {
        let store = store()
        store.provider = try XCTUnwrap(AttentionProvider.defaults[.openAI])
        XCTAssertFalse(store.draftsAllowed, "No key, no drafts")
        store.setAPIKey("k")
        XCTAssertTrue(store.draftsAllowed)
        store.provider = try XCTUnwrap(AttentionProvider.defaults[.rapidMLX])
        XCTAssertFalse(store.draftsAllowed, "A small local writer answers questions for you")
        store.localDrafts = true
        XCTAssertTrue(store.draftsAllowed)
        store.draftReplies = false
        XCTAssertFalse(store.draftsAllowed)
    }

    /// The app's own client against Rapid-MLX on this Mac, when it is running.
    func testLiveRapidMLXJudgesARussianMeeting() async throws {
        let provider = try XCTUnwrap(AttentionProvider.defaults[.rapidMLX])
        guard (try? await AttentionModelCatalog.fetch(provider, key: nil))?.isEmpty == false else {
            throw XCTSkip("Rapid-MLX is not running on 127.0.0.1:8000")
        }
        let now = Date()
        let lines = [
            GuestMeetingMessage(id: "1", participantID: "a", participantName: "Анна", text: "Давайте пройдёмся по плану релиза.", sentAt: now - 40, isOwn: false),
            GuestMeetingMessage(id: "2", participantID: "b", participantName: "Игорь", text: "Сертификаты истекают в пятницу.", sentAt: now - 20, isOwn: false),
            GuestMeetingMessage(id: "3", participantID: "a", participantName: "Анна", text: "Виталий, ты подтверждаешь, что DNS готов к переключению? Мы ждём тебя.", sentAt: now - 5, isOwn: false),
        ]
        let window = AttentionWindowBuilder.build(.init(title: "Инфраструктура", transcript: lines, chat: [], reactions: [],
            participantCount: 4, yourNames: ["Виталий"], microphoneOn: false, soundOn: false, now: now))
        let request = JudgeRequest(window: window, preset: nil, profile: .init(name: "Виталий", role: "отвечает за DNS"),
                                   yourName: "Виталий", language: "ru", replyChannels: .init(chat: true))
        let result = try await OpenAIChatJudge(provider: provider, key: nil).judge(request)
        XCTAssertEqual(result.verdict.level, .now)
        XCTAssertTrue(result.verdict.evidence.contains("3"), "The verdict cites Anna's question")
        XCTAssertLessThan(result.latency, 30)
    }

    // MARK: Separate writer, local scheduling, learning, voice

    func testAModelOnThisMacJudgesWhileAnotherWrites() async throws {
        let store = store()
        store.enabled = true; store.provider = try XCTUnwrap(AttentionProvider.defaults[.rapidMLX])
        XCTAssertFalse(store.draftsAllowed)
        store.writerProvider = .init(kind: .local, baseURL: "http://192.168.1.5:8000/v1", model: "writer-model")
        XCTAssertTrue(store.draftsAllowed, "A writer elsewhere drafts even though the judge runs here")
        XCTAssertEqual(store.effectiveWriter.model, "writer-model")
        let reloaded = AttentionStore(root: store.root, defaults: UserDefaults(suiteName: "attention-\(UUID())")!,
                                      keychain: AttentionKeychain(service: "t.\(UUID())"))
        XCTAssertNil(reloaded.writerProvider, "Other settings start with the judge as writer")

        let (infra, _) = try await meeting("infra")
        let judge = FakeJudge(), writer = FakeWriter()
        var writerProviders: [String] = []
        let coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { [infra] }; coordinator.hasTranscript = { _ in true }
        coordinator.makeJudge = { _, _ in judge }
        coordinator.makeWriter = { provider, _ in writerProviders.append(provider.model); return writer }
        coordinator.replyChannels = { _ in .init(chat: true) }
        coordinator.power = { .init(pluggedIn: true, lowPowerMode: false) }
        coordinator.thermalState = { .nominal }; coordinator.memoryPressured = { false }
        infra.receiveLocalLineForTesting(.init(id: "i1", trackID: "a", text: "Виталий, DNS готов?", start: Date(), end: Date()))
        judge.next = .init(level: .now, probability: 0.9, reason: "Asked.", evidence: ["L1"], action: .chat)
        await coordinator.tick()
        try await spin { coordinator.card(for: infra.sessionID)?.draft != nil }
        XCTAssertEqual(writerProviders, ["writer-model"])
    }

    func testJudgeOnThisMacChecksMoreOftenAndStepsAsideWhenTheMacIsBusy() async throws {
        let store = store()
        store.enabled = true; store.provider = try XCTUnwrap(AttentionProvider.defaults[.rapidMLX])
        let (infra, _) = try await meeting("infra")
        infra.receiveLocalLineForTesting(.init(id: "i1", trackID: "a", text: "Привет", start: Date(), end: Date()))
        let coordinator = AttentionCoordinator(store: store)
        coordinator.hasTranscript = { _ in true }
        var power = NativeDesktopPowerSnapshot(pluggedIn: true, lowPowerMode: false), thermal = ProcessInfo.ThermalState.nominal, pressure = false
        coordinator.power = { power }; coordinator.thermalState = { thermal }; coordinator.memoryPressured = { pressure }
        XCTAssertEqual(coordinator.interval, 10); XCTAssertEqual(coordinator.callsPerMinuteLimit, 12)
        XCTAssertNil(coordinator.waitingReason(infra))
        power.pluggedIn = false
        XCTAssertEqual(coordinator.interval, 20, "On battery the local judge keeps the normal pace")
        power.pluggedIn = true; thermal = .serious
        XCTAssertEqual(coordinator.waitingReason(infra), L("Paused while this Mac is hot."))
        thermal = .nominal; power.lowPowerMode = true
        XCTAssertEqual(coordinator.waitingReason(infra), L("Paused in Low Power Mode."))
        power.lowPowerMode = false; pressure = true
        XCTAssertEqual(coordinator.waitingReason(infra), L("Paused while this Mac is low on memory."))
        XCTAssertEqual(coordinator.interval, 20)
        store.provider = try XCTUnwrap(AttentionProvider.defaults[.openAI]); store.setAPIKey("k")
        XCTAssertNil(coordinator.waitingReason(infra), "A provider elsewhere does not load this Mac")
        XCTAssertEqual(coordinator.interval, 20)
    }

    func testThresholdTunerFindsTheThresholdThatMatchesYourChoices() {
        func item(_ probability: Double, _ needed: Bool?, level: AttentionLevel = .now) -> ComparisonCase {
            .init(id: UUID(), at: Date(), meetingTitle: "m", messages: [], window: sampleWindow(),
                  original: .init(level: level, probability: probability, reason: "r", evidence: [], action: .open),
                  originalModel: "x", threshold: 0.55, needed: needed)
        }
        // You open cards at 0.75+ and decline 0.6–0.7: the best threshold sits between them.
        let cases = [item(0.9, true), item(0.8, true), item(0.75, true), item(0.7, false), item(0.65, false), item(0.6, false), item(0.4, nil)]
        let result = ThresholdTuner.best(cases, current: 0.55)
        XCTAssertEqual(result?.threshold ?? 0, 0.75, accuracy: 0.001)
        XCTAssertEqual(result?.agreed, 6); XCTAssertEqual(result?.labelled, 6); XCTAssertEqual(result?.currentAgreed, 3)
        XCTAssertNil(ThresholdTuner.best(Array(cases.prefix(5)), current: 0.55), "Too few choices")
        XCTAssertNil(ThresholdTuner.best(cases.map { item($0.original.probability, $0.needed == nil ? nil : true) }, current: 0.55),
                     "Only one kind of choice says nothing about where to cut")
    }

    func testRepeatedDeclinesAndYourEditsReachThePrompts() async throws {
        var preset = MeetingPreset(title: "Infra", bindings: [.room("https://example.test/calls/infra")])
        for _ in 0..<3 { preset.record(.init(at: Date(), level: .soon, decision: .declined, declineReason: .notUrgent, excerpt: "x", reason: "y")) }
        preset.record(.init(at: Date(), level: .soon, decision: .declined, declineReason: .wrongMeeting, excerpt: "x", reason: "y"))
        XCTAssertEqual(preset.repeatedDeclines.map(\.reason), [.notUrgent])
        let judge = JudgeRequest(window: sampleWindow(), preset: preset, profile: .init(name: "Vitalii"), yourName: "Vitalii", language: "ru",
                                 replyChannels: .init(chat: true))
        XCTAssertTrue(AttentionPrompt.userContent(judge).contains("keeps declining cards as: not urgent (3 times)"))
        for index in 0..<12 { preset.recordEdit(.init(at: Date(), draft: "draft \(index)", sent: "sent \(index)")) }
        XCTAssertEqual(preset.replyEdits?.count, MeetingPreset.replyEditLimit)
        var withEdits = judge; withEdits.preset = preset
        let writer = ReplyPrompt.userContent(.init(judge: withEdits, verdict: .init(level: .now, probability: 0.9, reason: "r", evidence: [], action: .chat)))
        XCTAssertTrue(writer.contains("draft: \"draft 11\" → sent: \"sent 11\""))
        XCTAssertFalse(writer.contains("draft 6\""), "Only the five newest edits are shown")

        // Sending an edited draft records it on the meeting's instructions.
        let store = store()
        store.enabled = true; store.provider = .init(kind: .local, baseURL: "http://192.168.1.5:1/v1", model: "m")
        let (infra, _) = try await meeting("infra")
        let fake = FakeJudge(), writerFake = FakeWriter()
        let coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { [infra] }; coordinator.hasTranscript = { _ in true }
        coordinator.makeJudge = { _, _ in fake }; coordinator.makeWriter = { _, _ in writerFake }
        coordinator.replyChannels = { _ in .init(chat: true) }; coordinator.deliverChat = { _, _ in true }
        infra.receiveLocalLineForTesting(.init(id: "i1", trackID: "a", text: "Виталий, DNS готов?", start: Date(), end: Date()))
        fake.next = .init(level: .now, probability: 0.9, reason: "Asked.", evidence: ["L1"], action: .chat)
        await coordinator.tick()
        try await spin { coordinator.card(for: infra.sessionID)?.draft != nil }
        let card = try XCTUnwrap(coordinator.card(for: infra.sessionID))
        XCTAssertTrue(coordinator.sendReply(card, text: "Проверю и напишу через 5 минут."))
        XCTAssertEqual(store.preset(room: infra.invitation)?.replyEdits?.last,
                       .init(at: try XCTUnwrap(store.preset(room: infra.invitation)?.replyEdits?.last?.at),
                             draft: "Сейчас посмотрю и отвечу.", sent: "Проверю и напишу через 5 минут."))
    }

    func testSayItSpeaksTheReplyAndCountsAsApproval() async throws {
        let store = store()
        store.enabled = true; store.provider = .init(kind: .local, baseURL: "http://192.168.1.5:1/v1", model: "m")
        let (trueconf, _) = try await meeting("trueconf")
        let judge = FakeJudge()
        var spoken: [String] = [], played = 0, fail = false
        let coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { [trueconf] }; coordinator.hasTranscript = { _ in true }; coordinator.makeJudge = { _, _ in judge }
        coordinator.replyChannels = { _ in .init() }  // no chat, no reactions
        coordinator.voiceAvailable = { _ in true }
        coordinator.synthesizeOverride = { text in
            spoken.append(text); if fail { throw VoiceSynthesisError.transport }
            return MicrophoneMoveTests.tone(seconds: 0.2, frequency: 300, amplitude: 0.2)
        }
        coordinator.deliverVoice = { _, _ in played += 1 }
        trueconf.receiveLocalLineForTesting(.init(id: "t1", trackID: "a", text: "Виталий, ты с нами?", start: Date(), end: Date()))
        judge.next = .init(level: .now, probability: 0.9, reason: "Asked.", evidence: ["L1"], action: .open)
        await coordinator.tick()
        let card = try XCTUnwrap(coordinator.card(for: trueconf.sessionID))
        XCTAssertTrue(card.canSpeak); XCTAssertTrue(card.channels.isEmpty)
        fail = true
        coordinator.sayReply(card, text: "Да, через минуту буду.")
        try await spin { coordinator.card(for: trueconf.sessionID)?.draftError != nil }
        XCTAssertEqual(played, 0); XCTAssertEqual(coordinator.card(for: trueconf.sessionID)?.speaking, false)
        fail = false
        coordinator.sayReply(card, text: "Да, через минуту буду.")
        try await spin { coordinator.card(for: trueconf.sessionID) == nil }
        XCTAssertEqual(spoken, ["Да, через минуту буду.", "Да, через минуту буду."]); XCTAssertEqual(played, 1)
        XCTAssertEqual(store.preset(room: trueconf.invitation)?.examples.last?.decision, .approved)
        let log = try store.decisionFiles().map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(log.contains("\"spoken\""))
    }

    /// Review finding 5: system synthesis that never signals its end left the card
    /// "speaking" forever. The wait gives up after its timeout and cancels synthesis.
    func testSpeechSynthesisThatNeverFinishesGivesUp() async {
        var cancelled = false
        let started = Date()
        let silent = await VoiceReplySample.bounded(timeout: 0.2, cancel: { cancelled = true }) { _ in }
        XCTAssertNil(silent)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(cancelled)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10)!
        var lateCancel = false
        let spoken = await VoiceReplySample.bounded(timeout: 0.2, cancel: { lateCancel = true }) { finish in finish(buffer) }
        XCTAssertTrue(spoken === buffer)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(lateCancel, "a finished synthesis is not cancelled by the timer")
    }

    func testRapidMLXVoiceRequestAndWAVDecoding() async throws {
        let wav = Self.wav(seconds: 0.5)
        let decoded = try VoiceSynthesis.buffer(fromAudio: wav)
        XCTAssertEqual(Double(decoded.frameLength) / decoded.format.sampleRate, 0.5, accuracy: 0.01)
        XCTAssertThrowsError(try VoiceSynthesis.buffer(fromAudio: Data("not audio".utf8)))
        var sent: [String: Any] = [:]
        let session = StubProtocol.session { request in
            sent = (try? JSONSerialization.jsonObject(with: StubProtocol.body(request))) as? [String: Any] ?? [:]
            XCTAssertEqual(request.url?.path, "/v1/audio/speech")
            return (200, wav)
        }
        let buffer = try await VoiceSynthesis.rapidMLX("Сейчас посмотрю и отвечу.", baseURL: "http://127.0.0.1:8000/v1",
                                                       model: "qwen3-tts-voicedesign-4bit", description: "Calm voice", session: session)
        XCTAssertGreaterThan(buffer.frameLength, 0)
        XCTAssertEqual(sent["model"] as? String, "qwen3-tts-voicedesign-4bit"); XCTAssertEqual(sent["instructions"] as? String, "Calm voice")
        XCTAssertEqual(sent["language"] as? String, "ru", "The reply's language is detected from its text")
        let failing = StubProtocol.session { _ in (404, Data(#"{"detail":"model not found"}"#.utf8)) }
        do { _ = try await VoiceSynthesis.rapidMLX("Привет", baseURL: "http://127.0.0.1:8000/v1", model: "x", description: "", session: failing); XCTFail() }
        catch { XCTAssertEqual(error as? VoiceSynthesisError, .server(404, "model not found")) }
    }

    /// Qwen3-TTS through Rapid-MLX on this Mac, when it runs with audio.
    func testLiveRapidMLXSpeaksRussian() async throws {
        let base = AttentionProvider.defaults[.rapidMLX]!.baseURL
        guard (try? await AttentionModelCatalog.fetch(AttentionProvider.defaults[.rapidMLX]!, key: nil))?.isEmpty == false else {
            throw XCTSkip("Rapid-MLX is not running on 127.0.0.1:8000")
        }
        let buffer: AVAudioPCMBuffer
        do {
            buffer = try await VoiceSynthesis.rapidMLX("Я сейчас на другой встрече, отвечу через пару минут.", baseURL: base,
                model: AttentionStore.defaultVoiceModel, description: AttentionStore.defaultVoiceDescription)
        } catch VoiceSynthesisError.server(let code, _) where code == 404 || code == 400 {
            throw XCTSkip("Rapid-MLX runs without audio")
        }
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        XCTAssertGreaterThan(seconds, 2); XCTAssertLessThan(seconds, 15)
    }

    private static func wav(seconds: Double) -> Data {
        let rate = 24_000, frames = Int(Double(rate) * seconds)
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 2).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16).littleEndian); append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)
        append(UInt32(rate).littleEndian); append(UInt32(rate * 2).littleEndian); append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 2).littleEndian)
        for index in 0..<frames { append(Int16(sin(Double(index) * 0.05) * 8000).littleEndian) }
        return data
    }

    // MARK: Model comparison

    func testComparisonLoadsYourChoicesAndScoresAnotherModel() async throws {
        let store = store()
        let window = sampleWindow(), cited = window.lines.suffix(1).map(\.id)
        let wanted = AttentionVerdict(level: .now, probability: 0.9, reason: "Asked.", evidence: cited, action: .open)
        let quiet = AttentionVerdict(level: .no, probability: 0.1, reason: "Small talk.", evidence: [], action: .none)
        let messages = [["role": "system", "content": "s"], ["role": "user", "content": "u"]]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func verdict(_ id: UUID, _ verdict: AttentionVerdict, at offset: TimeInterval) {
            store.log(.init(id: id, at: base + offset, meetingTitle: "Infra", presetID: nil, window: window, verdict: verdict,
                provider: "api.openai.com", model: "gpt-4.1-mini", outcome: verdict.level == .no ? .belowThreshold : .shown,
                messages: messages, threshold: 0.55))
        }
        let opened = UUID(), declined = UUID(), unseen = UUID(), replied = UUID()
        verdict(opened, wanted, at: 0); verdict(declined, wanted, at: 10); verdict(unseen, quiet, at: 20); verdict(replied, wanted, at: 30)
        func outcome(_ id: UUID, _ outcome: AttentionDecisionRecord.Outcome, sent: String? = nil) {
            store.log(.init(at: base + 40, meetingTitle: "Infra", presetID: nil, window: nil, verdict: nil, provider: "p", model: "m",
                            outcome: outcome, decisionID: id, sent: sent))
        }
        outcome(opened, .opened); outcome(declined, .declined); outcome(replied, .replied, sent: "Да, готово.")
        store.log(.init(at: base + 35, meetingTitle: "Infra", presetID: nil, window: nil, verdict: nil, provider: "p", model: "gpt-4.1-mini",
            outcome: .drafted, decisionID: replied,
            replyMessages: [["role": "system", "content": "s"], ["role": "user", "content": "The user can answer with a chat message."]],
            draft: .init(chat: "Сейчас проверю.", reaction: nil)))

        let loaded = ComparisonLoader.load(store.decisionFiles())
        XCTAssertEqual(loaded.cases.count, 4)
        XCTAssertEqual(loaded.cases.map(\.id), [replied, declined, opened, unseen], "Decisions you chose on come first, newest first")
        XCTAssertEqual(loaded.cases.map(\.needed), [true, false, true, nil], "A reply counts as needed")
        let draft = try XCTUnwrap(loaded.drafts.first)
        XCTAssertEqual(draft.sent, "Да, готово."); XCTAssertEqual(draft.channels, .init(chat: true, reactions: []))

        let comparison = ModelComparison()
        comparison.load(from: store)
        var judged: [String] = []
        comparison.judge = { provider, _, _, window in
            judged.append(provider.model)
            // Shows a card for everything: right for opened and replied, wrong for declined.
            return .init(verdict: .init(level: .soon, probability: 0.8, reason: "Maybe.", evidence: window.lines.suffix(1).map(\.id), action: .open), latency: 0.5)
        }
        comparison.write = { _, _, _, _ in .init(draft: .init(chat: "Посмотрю и отвечу.", reaction: nil), latency: 0.3) }
        comparison.run(model: "other-model", provider: store.provider, key: nil, limit: 10, draftLimit: 5)
        try await spin { !comparison.running }
        XCTAssertEqual(judged, Array(repeating: "other-model", count: 4))
        let original = comparison.originalScore, candidate = comparison.candidateScore
        XCTAssertEqual(original.labelled, 3); XCTAssertEqual(original.agreed, 2, "The saved verdicts showed the declined card too")
        XCTAssertEqual(candidate.agreed, 2); XCTAssertEqual(candidate.shown, 4)
        XCTAssertEqual(candidate.precision ?? 0, 2.0 / 3.0, accuracy: 0.001); XCTAssertEqual(candidate.recall, 1)
        XCTAssertEqual(candidate.medianLatency, 0.5)
        XCTAssertEqual(comparison.rows.filter(\.changed).map(\.id), [unseen], "Only the quiet decision changes")
        XCTAssertEqual(comparison.draftRows.first?.candidate?.chat, "Посмотрю и отвечу.")
    }

    func testMissedMomentRetainsDraftAndAnswersWithoutOverlay() async throws {
        let store = store()
        store.enabled = true; store.provider = .init(kind: .local, baseURL: "http://192.168.1.5:1/v1", model: "m")
        let (infra, _) = try await meeting("infra")
        let judge = FakeJudge(), writer = FakeWriter()
        var sent: [String] = [], clock = Date()
        let coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { [infra] }; coordinator.hasTranscript = { _ in true }; coordinator.now = { clock }
        coordinator.makeJudge = { _, _ in judge }; coordinator.makeWriter = { _, _ in writer }
        coordinator.replyChannels = { _ in .init(chat: true, reactions: [.like]) }
        coordinator.deliverChat = { _, text in sent.append(text); return true }
        infra.receiveLocalLineForTesting(.init(id: "i1", trackID: "a", text: "Vitalii, ready?", start: clock, end: clock))
        judge.next = .init(level: .now, probability: 0.9, reason: "Waiting.", evidence: ["L1"], action: .chat)
        await coordinator.tick()
        let card = try XCTUnwrap(coordinator.card(for: infra.sessionID))
        try await spin { coordinator.card(for: infra.sessionID)?.draft != nil }
        coordinator.setMode(.off, for: infra)
        XCTAssertTrue(coordinator.cards.isEmpty)
        let moment = try XCTUnwrap(store.momentHistory.moment(card.id))
        XCTAssertEqual(moment.state, .missed); XCTAssertNotNil(moment.draft)
        coordinator.setMode(.mentions, for: infra); coordinator.selectMoment(moment)
        let selected = try XCTUnwrap(coordinator.selectedCard)
        XCTAssertTrue(coordinator.sendReply(selected, text: selected.draft?.chat ?? ""))
        XCTAssertEqual(sent.count, 1); XCTAssertTrue(coordinator.cards.isEmpty)
        XCTAssertEqual(store.momentHistory.moment(card.id)?.state, .answered)
        XCTAssertEqual(store.momentHistory.moment(card.id)?.sent, sent[0])
        let terminal = try XCTUnwrap(coordinator.selectedCard)
        XCTAssertTrue(terminal.readOnly); XCTAssertFalse(terminal.channels.chat); XCTAssertFalse(terminal.canSpeak)
        XCTAssertFalse(coordinator.sendReply(selected, text: selected.draft?.chat ?? ""), "Stale pre-terminal card cannot deliver twice")
        XCTAssertEqual(sent.count, 1)
        coordinator.selectMoment(try XCTUnwrap(store.momentHistory.moment(card.id)))
        XCTAssertTrue(coordinator.selectedCard?.readOnly == true, "Reselecting an answered Moment cannot deliver twice")
    }

    func testOverflowClearsWhenDisplacedMeetingGoesOffOrClosesWhileOtherCardsRemain() async throws {
        let store = store()
        store.enabled = true; store.provider = .init(kind: .local, baseURL: "http://192.168.1.5:1/v1", model: "m")
        let (a, _) = try await meeting("overflow-off-a"), (b, _) = try await meeting("overflow-off-b"), (c, _) = try await meeting("overflow-off-c")
        let judge = FakeJudge(), coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { [a, b, c] }; coordinator.hasTranscript = { _ in true }; coordinator.makeJudge = { _, _ in judge }
        for (model, id) in [(a, "a1"), (b, "b1"), (c, "c1")] {
            model.receiveLocalLineForTesting(.init(id: id, trackID: "t", text: "Vitalii?", start: Date(), end: Date()))
        }
        judge.next = .init(level: .now, probability: 0.9, reason: "Waiting.", evidence: ["L1"], action: .open)
        await coordinator.tick(); await coordinator.tick(); await coordinator.tick()
        XCTAssertEqual(coordinator.cards.count, 2)
        XCTAssertEqual(coordinator.overflowMomentIDs.count, 1)
        coordinator.setMode(.off, for: a)
        XCTAssertTrue(coordinator.overflowMomentIDs.isEmpty, "Turning Off the displaced meeting clears its overflow ID while b and c stay visible")
        XCTAssertEqual(coordinator.cards.count, 2)
    }

    func testOverflowTracksOnlyDisplacedLiveMomentsAndClearsAtCycleEnd() async throws {
        let store = store()
        store.enabled = true; store.provider = .init(kind: .local, baseURL: "http://192.168.1.5:1/v1", model: "m")
        let (a, _) = try await meeting("overflow-a"), (b, _) = try await meeting("overflow-b"), (c, _) = try await meeting("overflow-c")
        let judge = FakeJudge(), coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { [a, b, c] }; coordinator.hasTranscript = { _ in true }; coordinator.makeJudge = { _, _ in judge }
        for (model, id) in [(a, "a1"), (b, "b1"), (c, "c1")] {
            model.receiveLocalLineForTesting(.init(id: id, trackID: "t", text: "Vitalii?", start: Date(), end: Date()))
        }
        judge.next = .init(level: .now, probability: 0.9, reason: "Waiting.", evidence: ["L1"], action: .open)
        await coordinator.tick(); await coordinator.tick(); await coordinator.tick()
        XCTAssertEqual(coordinator.cards.count, 2)
        let overflowID = try XCTUnwrap(coordinator.overflowMomentIDs.first)
        let overflow = try XCTUnwrap(store.momentHistory.moment(overflowID))
        XCTAssertEqual(overflow.meetingTitle, "overflow-a", "The two newest cards stay visible")
        XCTAssertEqual(store.momentHistory.moment(overflow.id)?.state, .missed, "A displaced card remains answerable in Assistant")
        coordinator.selectMoment(overflow)
        coordinator.dismiss(try XCTUnwrap(coordinator.selectedCard))
        XCTAssertTrue(coordinator.overflowMomentIDs.isEmpty)
        XCTAssertEqual(store.momentHistory.moment(overflow.id)?.state, .dismissed)

        // Historical unread records never contribute to the overlay count.
        XCTAssertGreaterThan(store.momentHistory.unreadCount, 0)
        XCTAssertTrue(coordinator.overflowMomentIDs.isEmpty)
        for card in coordinator.cards { coordinator.dismiss(card) }
        XCTAssertTrue(coordinator.overflowMomentIDs.isEmpty)
        let relaunched = AttentionCoordinator(store: store)
        XCTAssertTrue(relaunched.overflowMomentIDs.isEmpty)
    }

    func testMomentErrorsAreScopedAndRetryClearsOnlyTheirOwnError() async throws {
        let store = store()
        let (infra, _) = try await meeting("errors")
        let coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { [infra] }
        let first = AttentionMoment(id: UUID(), meetingID: UUID(), meetingTitle: "first", verdict: .init(level: .now, probability: 0.9, reason: "one", evidence: [], action: .open), threshold: 0.5, provider: "p", model: "m", latency: 0, createdAt: Date(), updatedAt: Date(), state: .missed)
        let second = AttentionMoment(id: UUID(), meetingID: UUID(), meetingTitle: "second", verdict: first.verdict, threshold: 0.5, provider: "p", model: "m", latency: 0, createdAt: Date(), updatedAt: Date(), state: .missed)
        await coordinator.summarize(first)
        XCTAssertNotNil(coordinator.summaryErrorByMoment[first.id]); XCTAssertNil(coordinator.summaryErrorByMoment[second.id])
        coordinator.scheduleReminder = { _, _ in throw NSError(domain: "test", code: 1) }
        coordinator.remind(second)
        try await spin { coordinator.reminderErrorByMoment[second.id] != nil }
        XCTAssertNil(coordinator.reminderErrorByMoment[first.id]); XCTAssertNotNil(coordinator.summaryErrorByMoment[first.id])
        coordinator.scheduleReminder = { _, _ in }
        coordinator.remind(second)
        XCTAssertNil(coordinator.reminderErrorByMoment[second.id], "A retry immediately clears its previous error")
    }

    func testClosedMeetingRefusesMissedDelivery() async throws {
        let store = store(); store.enabled = true
        store.provider = .init(kind: .local, baseURL: "http://192.168.1.5:1/v1", model: "m")
        let (infra, _) = try await meeting("closed")
        let judge = FakeJudge(), coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { [infra] }; coordinator.hasTranscript = { _ in true }; coordinator.makeJudge = { _, _ in judge }
        coordinator.replyChannels = { _ in .init(chat: true, reactions: []) }
        infra.receiveLocalLineForTesting(.init(id: "i1", trackID: "a", text: "Vitalii?", start: Date(), end: Date()))
        judge.next = .init(level: .now, probability: 0.9, reason: "Waiting.", evidence: ["L1"], action: .chat)
        await coordinator.tick()
        let card = try XCTUnwrap(coordinator.cards.first)
        coordinator.setMode(.off, for: infra)
        _ = await infra.leave()
        coordinator.selectMoment(try XCTUnwrap(store.momentHistory.moment(card.id)))
        let selected = try XCTUnwrap(coordinator.selectedCard)
        XCTAssertFalse(selected.channels.chat)
        XCTAssertFalse(coordinator.sendReply(selected, text: "late"))
        XCTAssertEqual(store.momentHistory.moment(card.id)?.state, .missed)
    }

    func testNowCardExpiresToMissedAndSummaryUsesOnlyLaterLines() async throws {
        let store = store(); store.enabled = true
        store.provider = .init(kind: .local, baseURL: "http://192.168.1.5:1/v1", model: "m")
        let (infra, _) = try await meeting("summary")
        let judge = FakeJudge(), summarizer = FakeMomentSummarizer()
        var clock = Date()
        let coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { [infra] }; coordinator.hasTranscript = { _ in true }; coordinator.now = { clock }
        coordinator.makeJudge = { _, _ in judge }; coordinator.makeSummarizer = { _, _ in summarizer }
        infra.receiveLocalLineForTesting(.init(id: "q", trackID: "a", text: "Vitalii?", start: clock, end: clock))
        judge.next = .init(level: .now, probability: 0.9, reason: "Waiting.", evidence: ["L1"], action: .open)
        await coordinator.tick()
        let card = try XCTUnwrap(coordinator.cards.first)
        clock += AttentionCoordinator.holdNow + 1
        await coordinator.tick()
        XCTAssertTrue(coordinator.cards.isEmpty)
        let moment = try XCTUnwrap(store.momentHistory.moment(card.id)); XCTAssertEqual(moment.state, .missed)
        infra.receiveLocalLineForTesting(.init(id: "answer", trackID: "a", text: "I answered instead.", start: clock, end: clock))
        await coordinator.summarize(moment)
        XCTAssertEqual(summarizer.calls, 1); XCTAssertEqual(summarizer.request?.window.lines.map(\.id), ["answer"])
        XCTAssertEqual(coordinator.summaryByMoment[moment.id], "Someone answered.")
        let quiet = AttentionMoment(id: UUID(), meetingID: infra.sessionID, meetingTitle: infra.title,
            invitation: infra.invitation, verdict: moment.verdict, threshold: 0.5, provider: "local", model: "m",
            latency: 0, createdAt: clock + 1000, updatedAt: clock + 1000, state: .missed)
        await coordinator.summarize(quiet)
        XCTAssertEqual(summarizer.calls, 1, "No later lines means no model call")
        XCTAssertEqual(coordinator.summaryByMoment[quiet.id], L("No later transcript or chat yet."))
    }

    // MARK: Outcomes and local assistant data

    func testOutcomeParsingAndSnapshotBounds() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        {"summary":"  Release moved.  ","decisions":["Ship Monday","Ship Monday",""],
        "tasks":[{"text":"Update DNS","owner":"Anna","due_at":"\(ISO8601DateFormatter().string(from: due))"},
        {"text":" ","owner":"Nobody","due_at":""}],"open_questions":["Who owns rollback?"]}
        """
        let parsed = try MeetingOutcomePrompt.parse(json)
        XCTAssertEqual(parsed.summary, "Release moved.")
        XCTAssertEqual(parsed.decisions, ["Ship Monday"])
        XCTAssertEqual(parsed.tasks.count, 1)
        XCTAssertEqual(parsed.tasks[0].dueAt, due)
        XCTAssertEqual(parsed.openQuestions, ["Who owns rollback?"])

        let now = Date()
        let transcript = (0..<300).map { message("t\($0)", "Anna", "line \($0)", now.addingTimeInterval(Double($0))) }
        let window = MeetingOutcomePrompt.window(title: "infra", transcript: transcript, chat: [], yourName: "Vitalii", now: now, onDevice: true)
        XCTAssertEqual(window.lines.count, MeetingOutcomePrompt.maxLines)
        XCTAssertEqual(window.lines.first?.id, "t240")
        XCTAssertEqual(window.lines.last?.ref, "L60")
        XCTAssertLessThanOrEqual(window.lines.reduce(0) { $0 + $1.text.count }, MeetingOutcomePrompt.maxCharacters)
        let remote = MeetingOutcomePrompt.window(title: "infra", transcript: transcript, chat: [], yourName: "Vitalii", now: now)
        XCTAssertEqual(remote.lines.first?.id, "t0")
        XCTAssertEqual(remote.lines.last?.id, "t299")
        XCTAssertGreaterThan(remote.lines.count, window.lines.count)
        XCTAssertEqual(MeetingOutcomePrompt.remoteCharacterBudget(contextTokens: nil),
            MeetingOutcomePrompt.remoteCharacterBudget(contextTokens: MeetingOutcomePrompt.unknownContextTokens))
        XCTAssertLessThan(MeetingOutcomePrompt.remoteCharacterBudget(contextTokens: nil), 20_000,
            "An unknown model is given a small window, not the 80,000-character ceiling")
        XCTAssertEqual(MeetingOutcomePrompt.remoteCharacterBudget(contextTokens: 128_000), MeetingOutcomePrompt.maxRemoteCharacters)
        let long = (0..<80).map { message("L\($0)", "Anna", String(repeating: "x", count: 2_000), now.addingTimeInterval(Double($0))) }
        let clipped = MeetingOutcomePrompt.window(title: "infra", transcript: long, chat: [], yourName: "Vitalii", now: now)
        XCTAssertEqual(clipped.lines.first?.id, "L0")
        XCTAssertEqual(clipped.lines.last?.id, "L79")
        XCTAssertTrue(clipped.lines.contains { $0.id == "omitted" }, "A gap between the kept ends is marked so they are not read as continuous")
        let marker = try XCTUnwrap(clipped.lines.first { $0.id == "omitted" })
        XCTAssertEqual(marker.ref, "", "The gap is not a citable line")
        XCTAssertEqual(marker.source, .note)
        XCTAssertTrue(marker.text.hasPrefix("[… ") && marker.text.hasSuffix(" lines omitted …]"))
        let prompt = MeetingOutcomePrompt.messages(.init(meetingTitle: "infra", endedAt: now, window: clipped, language: "en"))
            .first { $0["role"] == "user" }?["content"] ?? ""
        XCTAssertTrue(prompt.contains(marker.text))
        XCTAssertFalse(prompt.contains(": " + marker.text), "The gap is not labelled as someone's speech")
        let smallBudget = MeetingOutcomePrompt.remoteCharacterBudget(contextTokens: 4_096)
        let small = MeetingOutcomePrompt.window(title: "infra", transcript: long, chat: [], yourName: "Vitalii", now: now, contextTokens: 4_096)
        let wide = MeetingOutcomePrompt.window(title: "infra", transcript: long, chat: [], yourName: "Vitalii", now: now, contextTokens: 128_000)
        XCTAssertEqual(small.lines.first?.id, "L0")
        XCTAssertEqual(small.lines.last?.id, "L79")
        XCTAssertTrue(small.lines.contains { $0.id == "omitted" })
        XCTAssertLessThanOrEqual(small.lines.filter { $0.id != "omitted" }.reduce(0) { $0 + $1.text.count }, smallBudget)
        XCTAssertLessThan(small.lines.filter { $0.id != "omitted" }.count, wide.lines.filter { $0.id != "omitted" }.count)
        let tight = MeetingOutcomePrompt.window(title: "infra", transcript: transcript, chat: [], yourName: "Vitalii", now: now, contextTokens: 3_300)
        XCTAssertEqual(tight.lines.first?.id, "t0")
        XCTAssertEqual(tight.lines.last?.id, "t299")
        XCTAssertTrue(tight.lines.contains { $0.id == "omitted" })
        let legacy = #"{"kind":"openRouter","baseURL":"https://openrouter.ai/api/v1","model":"small"}"#
        let decoded = try JSONDecoder().decode(AttentionProvider.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.contextLength, "A saved provider without a catalog length still loads")
        let fresh = store()
        XCTAssertEqual(fresh.outcomeContextTokens, 1_047_576, "gpt-4.1-mini is a known large OpenAI context, not the 8k default")
        fresh.provider.adopt(model: "gpt-4", contextLength: nil)
        XCTAssertEqual(fresh.outcomeContextTokens, 8_192)
        fresh.provider.adopt(model: "mystery-model", contextLength: nil)
        XCTAssertEqual(fresh.outcomeContextTokens, AttentionProvider.openAIFallbackContextTokens)
        fresh.provider = AttentionProvider(kind: .openRouter, baseURL: "https://openrouter.ai/api/v1", model: "mystery-model")
        XCTAssertNil(fresh.outcomeContextTokens, "An unknown OpenRouter model keeps the small default")
        fresh.provider.adopt(model: "small", contextLength: 4_096)
        var typed = fresh.provider
        typed.adoptTyped("small")
        XCTAssertEqual(typed.contextLength, 4_096, "Writing the same model text back keeps the catalogued length")
        typed.adoptTyped("typed-by-hand")
        XCTAssertNil(typed.contextLength)
        XCTAssertEqual(fresh.outcomeContextTokens, 4_096)
        fresh.writerProvider = AttentionProvider(kind: .openRouter, baseURL: "https://openrouter.ai/api/v1", model: "other")
        XCTAssertNil(fresh.outcomeContextTokens, "A different writer with no catalog length uses the conservative default")
        fresh.writerProvider?.adopt(model: "small", contextLength: nil)
        XCTAssertEqual(fresh.outcomeContextTokens, 4_096, "The same model id reuses the length stored for the judge")
        XCTAssertEqual(AssistantCaptureLimit.sampleLimit, AssistantCaptureLimit.holdSeconds * AssistantCaptureLimit.sampleRate)
        XCTAssertEqual(AssistantCaptureLimit.holdSeconds, 30)
    }

    func testAssistantDataPersistsEditsAndFindsLastTime() async throws {
        let root = folder(), data = AssistantDataStore(root: root)
        await data.waitForLoad()
        let invitation = URL(string: "https://example.test/calls/infra")!
        let outcome = MeetingOutcome(meetingTitle: "Infra", invitation: invitation, seriesID: "series", endedAt: Date().addingTimeInterval(-60),
            summary: "We agreed to migrate.", decisions: ["Migrate"], tasks: [.init(text: "Check DNS")], openQuestions: [])
        data.addOutcome(outcome)
        data.remember("I prefer concise replies", kind: .you)
        await data.waitForSave()
        XCTAssertEqual(data.latestOutcome(invitation: invitation)?.id, outcome.id)
        XCTAssertEqual(data.seriesOutcomes(series: "series").count, 1)
        XCTAssertTrue(data.retrieve(meetingTitle: "Infra", invitation: invitation, series: "series", people: []).count <= 5)

        let restored = AssistantDataStore(root: root)
        await restored.waitForLoad()
        XCTAssertEqual(restored.outcomes.first?.summary, "We agreed to migrate.")
        XCTAssertEqual(restored.memories.first?.text, "I prefer concise replies")
        var edited = try XCTUnwrap(restored.outcomes.first)
        edited.summary = "Edited"; edited.tasks[0].done = true
        restored.updateOutcome(edited)
        await restored.waitForSave()
        let again = AssistantDataStore(root: root)
        await again.waitForLoad()
        XCTAssertEqual(again.outcomes.first?.summary, "Edited")
        XCTAssertTrue(again.outcomes.first?.tasks[0].done == true)
        let exported = try XCTUnwrap(String(data: restored.exportData(), encoding: .utf8))
        XCTAssertTrue(exported.contains("I prefer concise replies"))
        restored.deleteAll(); await restored.waitForSave()
        XCTAssertTrue(restored.outcomes.isEmpty && restored.memories.isEmpty)
    }

    func testAssistantMutationDuringInitialLoadIsNotOverwrittenByStaleBytes() async throws {
        let root = folder(), seed = AssistantDataStore(root: root)
        await seed.waitForLoad()
        seed.remember("Old value")
        await seed.waitForSave()
        let stale = try Data(contentsOf: root.appendingPathComponent("assistant.json"))
        let gate = GuestCompletion<Data>()
        let data = AssistantDataStore(root: root, readData: { _ in
            try await withCheckedThrowingContinuation { gate.install($0, timeout: 5) }
        })
        data.remember("New value")
        gate.finish(.success(stale))
        await data.waitForLoad()
        XCTAssertEqual(data.memories.map(\.text), ["New value", "Old value"])
        await data.waitForSave()
        let restored = AssistantDataStore(root: root)
        await restored.waitForLoad()
        XCTAssertEqual(restored.memories.map(\.text), ["New value", "Old value"])

        // An explicit deleteAll during initial load must not let stale disk bytes resurrect.
        let clearGate = GuestCompletion<Data>()
        let cleared = AssistantDataStore(root: root, readData: { _ in
            try await withCheckedThrowingContinuation { clearGate.install($0, timeout: 5) }
        })
        cleared.deleteAll()
        clearGate.finish(.success(stale))
        await cleared.waitForLoad()
        XCTAssertTrue(cleared.memories.isEmpty)

        // Corrupt JSON backs up the unreadable bytes and sets persistenceWarning instead of silently losing them.
        let corruptRoot = folder()
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let badBytes = Data("{not valid json".utf8)
        try badBytes.write(to: corruptRoot.appendingPathComponent("assistant.json"))
        let corruptStore = AssistantDataStore(root: corruptRoot)
        await corruptStore.waitForLoad()
        XCTAssertNotNil(corruptStore.persistenceWarning)
        XCTAssertEqual(try Data(contentsOf: corruptRoot.appendingPathComponent("assistant.corrupt.json")), badBytes)
    }

    func testOutcomeCaptureDoesNotWaitForWriterAndRunsOnce() async throws {
        let store = store()
        store.provider = .init(kind: .local, baseURL: "http://127.0.0.1:1/v1", model: "m")
        let (infra, _) = try await meeting("outcome")
        infra.calendarSeriesID = "infra-series"
        infra.receiveLocalLineForTesting(.init(id: "line", trackID: "a", text: "Anna will update DNS.", start: Date(), end: Date()))
        let writer = FakeOutcomeWriter(), coordinator = AttentionCoordinator(store: store)
        coordinator.makeOutcomeWriter = { _, _ in writer }
        coordinator.captureOutcome(for: infra)
        XCTAssertTrue(store.assistant.outcomes.isEmpty, "Capture returns without awaiting the writer")
        try await spin { store.assistant.outcomes.count == 1 }
        XCTAssertEqual(writer.calls, 1)
        XCTAssertEqual(writer.request?.window.lines.map(\.id), ["line"])
        XCTAssertEqual(store.assistant.outcomes.first?.seriesID, "infra-series")
        coordinator.captureOutcome(for: infra)
        XCTAssertEqual(writer.calls, 1)
        XCTAssertTrue(store.assistant.outcomes.first?.shareText.contains("Update DNS") == true)
    }

    func testOutcomeReminderIsRecordedOnlyAfterScheduling() async throws {
        let store = store(); await store.assistant.waitForLoad()
        let outcome = MeetingOutcome(meetingTitle: "Infra", endedAt: Date(), summary: "Summary", tasks: [.init(text: "Check DNS")])
        store.assistant.addOutcome(outcome)
        let coordinator = AttentionCoordinator(store: store)
        var scheduled = false
        coordinator.scheduleOutcomeReminder = { _, _, _ in scheduled = true }
        coordinator.remind(outcome.tasks[0], in: outcome)
        try await spin { scheduled && store.assistant.outcomes.first?.tasks[0].reminderAt != nil }
        XCTAssertTrue(scheduled)
    }

    func testAssistantCommandSchemaParsesEveryActionAndRejectsUnknownIDs() throws {
        let meeting = UUID(), moment = UUID(), now = Date()
        let context = AssistantCommandContext(meetings: [.init(id: meeting, title: "Infra", invitation: nil, active: true)],
            moments: [.init(id: moment, meetingTitle: "Infra", reason: "DNS question")], now: now)
        let future = ISO8601DateFormatter().string(from: now.addingTimeInterval(900))
        for action in AssistantCommandAction.allCases {
            var object: [String: Any] = ["action": action.rawValue, "meeting": "", "moment": "", "mode": "", "scope": "untilLeave",
                "text": "", "fact": "", "reaction": "", "n": 5, "minutes": 10, "at": ""]
            switch action {
            case .setAttention: object["meeting"] = meeting.uuidString; object["mode"] = "mentions"
            case .join, .leave, .mute, .readChat, .catchUp: object["meeting"] = meeting.uuidString
            case .sendChat, .say: object["meeting"] = meeting.uuidString; object["text"] = "I will check"
            case .react: object["meeting"] = meeting.uuidString; object["reaction"] = "like"
            case .remind: object["moment"] = moment.uuidString; object["at"] = future
            case .remember: object["fact"] = "I prefer concise replies"
            }
            let data = try JSONSerialization.data(withJSONObject: object)
            let command = try AssistantCommandPrompt.parse(String(decoding: data, as: UTF8.self), context: context)
            XCTAssertEqual(command.action, action)
            XCTAssertEqual(command.needsConfirmation, [.sendChat, .say, .react, .leave, .join].contains(action))
        }
        let unknown = #"{"action":"join","meeting":"\#(UUID().uuidString)","moment":"","mode":"","scope":"","text":"","fact":"","reaction":"","n":5,"minutes":10,"at":""}"#
        XCTAssertThrowsError(try AssistantCommandPrompt.parse(unknown, context: context)) {
            XCTAssertEqual($0 as? AssistantCommandError, .unknownMeeting)
        }
        XCTAssertThrowsError(try AssistantCommandPrompt.parse("not json", context: context))
        let prompt = AssistantCommandPrompt.messages(.init(input: "switch Infra to mentions", context: context))
        XCTAssertTrue(prompt[1]["content"]!.contains(meeting.uuidString))
        XCTAssertTrue(prompt[1]["content"]!.contains(moment.uuidString))
        let schema = AssistantCommandPrompt.schema(context)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertTrue(((properties["meeting"] as? [String: Any])?["enum"] as? [String])?.contains(meeting.uuidString) == true)
    }

    func testAssistantCommandsConfirmOutwardActionsAndScopeSendBypass() async throws {
        let store = store(); store.provider = .init(kind: .local, baseURL: "http://192.168.1.5:1/v1", model: "m")
        let (infra, _) = try await meeting("infra")
        infra.chat.canSend = true
        let coordinator = AttentionCoordinator(store: store); coordinator.meetings = { [infra] }
        var sent: [String] = [], interpreted: [AssistantCommandRequest] = []
        coordinator.deliverChat = { _, text in sent.append(text); return true }
        let talk = coordinator.talk
        talk.interpretOverride = { request in
            interpreted.append(request)
            return .init(action: .sendChat, meetingID: infra.sessionID, text: "I will check")
        }
        await talk.run("send that I will check")
        XCTAssertEqual(talk.pending?.command.action, .sendChat)
        XCTAssertTrue(sent.isEmpty, "The model decision alone never sends")
        talk.cancelPending(); XCTAssertNil(talk.pending); XCTAssertTrue(sent.isEmpty)

        await talk.run("send that I will check")
        talk.confirmPending()
        try await spin { sent.count == 1 }
        XCTAssertEqual(sent, ["I will check"])
        XCTAssertEqual(interpreted.last?.context.meetings.first?.id, infra.sessionID)

        talk.setDirectSend(true, for: infra.sessionID)
        await talk.run("send that I will check")
        try await spin { sent.count == 2 }
        XCTAssertNil(talk.pending, "The bypass applies to this meeting's outward sends")
        talk.interpretOverride = { _ in .init(action: .leave) }
        talk.targetMeetingID = infra.sessionID
        await talk.run("leave")
        XCTAssertEqual(talk.pending?.command.action, .leave, "Leave still confirms when send bypass is on")
        XCTAssertEqual(talk.pending?.command.meetingID, infra.sessionID, "Confirmation binds the meeting chosen when it was rendered")
        talk.targetMeetingID = UUID()
        XCTAssertEqual(talk.pending?.command.meetingID, infra.sessionID, "Changing the picker cannot retarget a pending leave")
        talk.cancelPending()
    }

    func testAssistantCommandsExecuteReadsMemoryModeMuteAndCustomReminder() async throws {
        let store = store(); await store.assistant.waitForLoad()
        let (infra, engine) = try await meeting("infra")
        var clock = Date()
        let coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { [infra] }; coordinator.now = { clock }
        coordinator.scheduleReminder = { _, _ in }
        var features = GuestMeetingSnapshot()
        features.messages = [message("chat", "Anna", "DNS is ready", clock.addingTimeInterval(-30))]
        infra.receiveFeaturesForTesting(features)
        infra.receiveLocalLineForTesting(.init(id: "line", trackID: "anna", text: "The migration is Monday",
            start: clock.addingTimeInterval(-20), end: clock.addingTimeInterval(-19)))
        let talk = coordinator.talk

        talk.perform(.init(action: .remember, text: "I prefer concise replies"))
        try await spin { store.assistant.memories.contains { $0.text == "I prefer concise replies" } }
        talk.perform(.init(action: .readChat, meetingID: infra.sessionID, count: 1))
        try await spin { talk.entries.last?.text.contains("Anna: DNS is ready") == true }
        talk.perform(.init(action: .catchUp, meetingID: infra.sessionID, minutes: 10))
        try await spin { talk.entries.last?.text.contains("The migration is Monday") == true }
        XCTAssertTrue(talk.entries.last?.text.contains(L("%@ (chat): %@", "Anna", "DNS is ready")) == true)

        talk.perform(.init(action: .setAttention, meetingID: infra.sessionID, mode: .mentions, scope: .untilLeave))
        try await spin { coordinator.resolvedMode(infra).mode == .mentions }
        try await engine.setMicrophone(true)
        talk.perform(.init(action: .mute, meetingID: infra.sessionID))
        try await spin { !infra.snapshot.microphoneOn }

        let verdict = AttentionVerdict(level: .now, probability: 0.9, reason: "DNS question", evidence: [], action: .open)
        let record = AttentionDecisionRecord(at: clock, meetingTitle: infra.title, meetingID: infra.sessionID,
            invitation: infra.invitation, verdict: verdict, provider: "local", model: "m", outcome: .shown)
        store.log(record)
        let reminderAt = clock.addingTimeInterval(900)
        talk.perform(.init(action: .remind, momentID: record.id, at: reminderAt))
        try await spin { store.momentHistory.moment(record.id)?.reminderAt == reminderAt }
        clock += 60
        XCTAssertEqual(store.momentHistory.moment(record.id)?.reminderAt, reminderAt)
    }

    func testAssistantTalkBackRequiresARealHeadphoneDataSource() {
        XCTAssertTrue(AssistantHeadphoneRoute.isHeadphoneSource(0x6864706e))
        XCTAssertFalse(AssistantHeadphoneRoute.isHeadphoneSource(0x73706b72), "Built-in speakers never qualify")
        XCTAssertFalse(AssistantHeadphoneRoute.isHeadphoneSource(0), "Unknown output routes fail closed")
        XCTAssertTrue(AssistantHeadphoneRoute.accepts(source: AssistantHeadphoneRoute.headphonesDataSource, transport: 0, deviceUID: "jack", approved: []))
        XCTAssertFalse(AssistantHeadphoneRoute.accepts(source: 0, transport: AssistantHeadphoneRoute.bluetoothTransport, deviceUID: "airpods", approved: []),
            "Bluetooth stays closed until this device is marked")
        XCTAssertTrue(AssistantHeadphoneRoute.accepts(source: 0, transport: AssistantHeadphoneRoute.bluetoothTransport, deviceUID: "airpods", approved: ["airpods"]))
        XCTAssertTrue(AssistantHeadphoneRoute.accepts(source: 0, transport: AssistantHeadphoneRoute.usbTransport, deviceUID: "usb-headset", approved: ["usb-headset"]))
        XCTAssertFalse(AssistantHeadphoneRoute.accepts(source: AssistantHeadphoneRoute.internalSpeaker, transport: 0, deviceUID: "speakers", approved: ["speakers"]),
            "Built-in speakers cannot be opted in")
    }

    func testMemoryIsBoundedRelevantAndInspectableInHistory() async throws {
        let data = AssistantDataStore(root: folder()); await data.waitForLoad()
        let invitation = URL(string: "https://example.test/calls/infra")!
        data.remember("Anna owns the DNS migration", kind: .people, people: ["Anna"])
        data.remember("The infra sync decided to migrate on Monday", kind: .meetings, invitation: invitation, series: "infra")
        for index in 0..<8 { data.remember("General preference \(index)", kind: .you) }
        let excerpts = data.retrieve(meetingTitle: "Infra sync", invitation: invitation, series: "infra", people: ["Anna"])
        XCTAssertEqual(excerpts.count, 5)
        XCTAssertTrue(excerpts.contains { $0.text.contains("decided to migrate") })
        let request = JudgeRequest(window: sampleWindow(), profile: .init(), yourName: "Vitalii", language: "en", memory: excerpts)
        let prompt = try XCTUnwrap(AttentionPrompt.messages(request).first?["content"])
        XCTAssertTrue(AttentionPrompt.userContent(request).contains("decided to migrate"))
        XCTAssertFalse(prompt.contains("decided to migrate"), "Evidence belongs in the user content, not system instructions")

        let verdict = AttentionVerdict(level: .now, probability: 0.9, reason: "Asked", evidence: [], action: .chat)
        let record = AttentionDecisionRecord(at: Date(), meetingTitle: "Infra", invitation: invitation, verdict: verdict,
            provider: "local", model: "m", outcome: .shown, memory: excerpts)
        var history = AttentionMomentHistory(); history.apply(record)
        XCTAssertEqual(history.moment(record.id)?.memory, excerpts)
        let encoded = try JSONEncoder.attention.encode(record)
        let legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var object = legacy; object["memory"] = nil
        let decoded = try JSONDecoder.attention.decode(AttentionDecisionRecord.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.memory)
    }

    func testAssistantMeetingTargetDefaultsToMicrophoneOwnerAndPreservesChoice() async throws {
        let (first, _) = try await meeting("first")
        let (second, _) = try await meeting("second")
        first.configureForConcurrentJoin(ownsMicrophone: false)
        second.configureForConcurrentJoin(ownsMicrophone: true)
        let coordinator = AttentionCoordinator(store: store())
        var live = [first, second]
        coordinator.meetings = { live }
        let talk = coordinator.talk

        XCTAssertEqual(talk.reconcileMeetingTarget(), second.sessionID, "The microphone owner is the initial Assistant context")
        talk.targetMeetingID = first.sessionID
        second.configureForConcurrentJoin(ownsMicrophone: false)
        first.configureForConcurrentJoin(ownsMicrophone: true)
        XCTAssertEqual(talk.reconcileMeetingTarget(), first.sessionID, "A valid explicit target survives microphone handover")

        live = [second]
        XCTAssertEqual(talk.reconcileMeetingTarget(), second.sessionID, "A closed target is repaired to the remaining live meeting")
        live = []
        XCTAssertNil(talk.reconcileMeetingTarget(), "No live meeting means no implicit outward target")
    }

    func testReviewFixesForPrivacyDecodeJournalAndPushToTalk() async throws {
        let fresh = store()
        XCTAssertTrue(fresh.pushToTalk, "An upgrade keeps the previous on default until the person turns it off")
        fresh.provider = AttentionProvider.defaults[.openAI]!
        XCTAssertTrue(fresh.setAPIKey("sk-test"))
        fresh.generateOutcomes = true
        fresh.enabled = false
        XCTAssertFalse(fresh.shouldCaptureOutcome, "Attention off never sends a transcript to a remote writer")
        fresh.enabled = true
        XCTAssertFalse(fresh.remoteOutcomes)
        XCTAssertFalse(fresh.shouldCaptureOutcome, "Remote outcome generation is off until an explicit opt-in")
        fresh.remoteOutcomes = true
        XCTAssertTrue(fresh.shouldCaptureOutcome)
        fresh.provider = AttentionProvider.defaults[.apple]!
        fresh.enabled = false
        XCTAssertTrue(fresh.shouldCaptureOutcome, "On-device outcomes still run while Attention is off")

        let partial = #"{"summary":"Release moved.","decisions":["Ship"],"tasks":[{"text":"Update"#
        let repaired = try MeetingOutcomePrompt.parse(partial)
        XCTAssertEqual(repaired.summary, "Release moved.")
        XCTAssertEqual(repaired.decisions, ["Ship"])
        XCTAssertTrue(repaired.tasks.isEmpty, "A value cut in the middle is dropped, not closed into a fake task")
        let ownerCut = try MeetingOutcomePrompt.parse(#"{"summary":"Kept","tasks":[{"text":"a","owner":"#)
        XCTAssertTrue(ownerCut.tasks.isEmpty, "A task cut after a finished field is dropped, not kept as a partial object")
        let cutDecisions = try MeetingOutcomePrompt.parse(#"{"summary":"ok","decisions":["a","b"#)
        XCTAssertEqual(cutDecisions.decisions, ["a"], "A finished array element is kept when the next one is cut")
        let cutQuestions = try MeetingOutcomePrompt.parse(#"{"summary":"ok","open_questions":["Who?","Wh"#)
        XCTAssertEqual(cutQuestions.openQuestions, ["Who?"])
        XCTAssertThrowsError(try MeetingOutcomePrompt.parse(#"{"summary":"Rel"#))
        let dangling = try MeetingOutcomePrompt.parse(#"{"summary":"Kept","decis"#)
        XCTAssertEqual(dangling.summary, "Kept")
        XCTAssertTrue(dangling.decisions.isEmpty)

        let root = folder(), data = AssistantDataStore(root: root)
        await data.waitForLoad()
        data.remember("Kept fact")
        await data.waitForSave()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("assistant.json"))) as? [String: Any])
        var memories = try XCTUnwrap(object["memories"] as? [Any])
        memories.insert(NSNull(), at: 0)
        memories.append("scalar")
        memories.append([1, 2])
        object["memories"] = memories
        object["outcomes"] = [["summary": "Missing end", "meetingTitle": "Infra"]]
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent("assistant.json"))
        let loaded = AssistantDataStore(root: root)
        await loaded.waitForLoad()
        XCTAssertEqual(loaded.memories.map(\.text), ["Kept fact"])
        XCTAssertTrue(loaded.outcomes.isEmpty, "An outcome without endedAt is not given a fabricated date")
        XCTAssertNotNil(loaded.loadWarning)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("assistant.recovered.json")), try Data(contentsOf: root.appendingPathComponent("assistant.json")))
        let sameDamage = AssistantDataStore(root: root)
        await sameDamage.waitForLoad()
        let recoveredNames = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).filter { $0.contains("recovered") }
        XCTAssertEqual(recoveredNames, ["assistant.recovered.json"], "The same damaged bytes are not copied again on the next launch")
        loaded.remember("Added after repair")
        await loaded.waitForSave()
        XCTAssertNotNil(loaded.loadWarning)
        let again = AssistantDataStore(root: root)
        await again.waitForLoad()
        XCTAssertTrue(again.memories.contains { $0.text == "Kept fact" })
        XCTAssertTrue(again.memories.contains { $0.text == "Added after repair" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("assistant.recovered.json").path))
        XCTAssertNotEqual(try Data(contentsOf: root.appendingPathComponent("assistant.recovered.json")), try Data(contentsOf: root.appendingPathComponent("assistant.json")))
        let firstBackup = try Data(contentsOf: root.appendingPathComponent("assistant.recovered.json"))
        let damagedAgain = AssistantDataStore(root: root)
        await damagedAgain.waitForLoad()
        try JSONSerialization.data(withJSONObject: ["memories": [NSNull()]]).write(to: root.appendingPathComponent("assistant.json"))
        let secondDamage = AssistantDataStore(root: root)
        await secondDamage.waitForLoad()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("assistant.recovered.json")), firstBackup,
            "A later damaged load keeps the first backup")

        let (first, _) = try await meeting("rejoin")
        let coordinator = AttentionCoordinator(store: fresh)
        await fresh.waitForMoments()
        let verdict = AttentionVerdict(level: .now, probability: 0.9, reason: "Asked", evidence: [], action: .open)
        let shownID = UUID()
        fresh.log(.init(id: shownID, at: Date(), meetingTitle: first.title, meetingID: first.sessionID, invitation: first.invitation,
            presetID: nil, window: nil, verdict: verdict, provider: "local", model: "m", outcome: .shown))
        let moment = try XCTUnwrap(fresh.momentHistory.moment(shownID))
        coordinator.meetings = { [first] }
        XCTAssertEqual(coordinator.meeting(for: moment)?.sessionID, first.sessionID)
        _ = await first.leave()
        let (second, _) = try await meeting("rejoin")
        coordinator.meetings = { [second] }
        XCTAssertEqual(coordinator.meeting(for: moment)?.sessionID, second.sessionID, "A rejoined room is not stuck read-only")

        var sent: [String] = []
        coordinator.meetings = { [second] }
        second.chat.canSend = true
        coordinator.deliverChat = { _, text in sent.append(text); return true }
        let outcome = MeetingOutcome(meetingID: first.sessionID, meetingTitle: "rejoin", invitation: first.invitation, endedAt: Date(), summary: "Done")
        XCTAssertEqual(coordinator.outcomeChatTarget(outcome)?.sessionID, second.sessionID)
        XCTAssertFalse(coordinator.sendOutcome(outcome, to: UUID()))
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(coordinator.sendOutcome(outcome, to: second.sessionID))
        XCTAssertEqual(sent.count, 1)

        let talk = coordinator.talk
        talk.observePushToTalk()
        XCTAssertEqual(talk.hotKeyMonitorCount, 0)
        XCTAssertFalse(talk.globalHotKeyInstalled)
        fresh.pushToTalk = true
        XCTAssertGreaterThanOrEqual(talk.hotKeyMonitorCount, 1, "Enabling through $pushToTalk installs immediately, not after relaunch")
        fresh.pushToTalk = false
        XCTAssertEqual(talk.hotKeyMonitorCount, 0)
        XCTAssertFalse(talk.globalHotKeyInstalled, "Disabling removes the global hotkey as well as the in-app monitor")
        XCTAssertEqual(AssistantPushToTalkHotKey.action(type: .keyDown, keyCode: 49, option: true, isRepeat: false,
            enabled: true, appActive: true, textFocused: true, listening: false), .ignore)
        XCTAssertEqual(AssistantPushToTalkHotKey.action(type: .keyDown, keyCode: 49, option: true, isRepeat: false,
            enabled: true, appActive: false, textFocused: false, listening: false), .start)
        XCTAssertEqual(AssistantPushToTalkHotKey.action(type: .keyDown, keyCode: 49, option: true, isRepeat: false,
            enabled: false, appActive: false, textFocused: false, listening: false), .ignore)
        XCTAssertEqual(AssistantPushToTalkHotKey.action(type: .keyUp, keyCode: 49, option: false, isRepeat: false,
            enabled: true, appActive: false, textFocused: false, listening: true), .stop)
        XCTAssertEqual(AssistantPushToTalkHotKey.action(type: .keyDown, keyCode: 0, option: true, isRepeat: false,
            enabled: true, appActive: false, textFocused: false, listening: false), .ignore)

        let meetingID = UUID(), momentID = UUID(), now = Date()
        let context = AssistantCommandContext(meetings: [.init(id: meetingID, title: "Infra", invitation: nil, active: true)],
            moments: [.init(id: momentID, meetingTitle: "Infra", reason: "DNS")], now: now)
        let remembered = #"{"action":"remember","meeting":"","moment":"","mode":"","scope":"","text":"do not store this","fact":"keep this fact","reaction":"","n":5,"minutes":10,"at":""}"#
        let rememberedCommand = try AssistantCommandPrompt.parse(remembered, context: context)
        XCTAssertEqual(rememberedCommand.text, "keep this fact")
        let leaked = #"{"action":"sendChat","meeting":"\#(meetingID.uuidString)","moment":"","mode":"","scope":"","text":"","fact":"secret","reaction":"","n":5,"minutes":10,"at":""}"#
        XCTAssertThrowsError(try AssistantCommandPrompt.parse(leaked, context: context))
        let zonaless = #"{"action":"remind","meeting":"","moment":"\#(momentID.uuidString)","mode":"","scope":"","text":"","fact":"","reaction":"","n":5,"minutes":10,"at":"2030-01-02T15:00"}"#
        let reminder = try AssistantCommandPrompt.parse(zonaless, context: context)
        func parts(_ text: String, utc: Bool = false) throws -> DateComponents {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = utc ? TimeZone(secondsFromGMT: 0)! : .current
            return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: try XCTUnwrap(AssistantTime.parse(text)))
        }
        let reminderParts = try parts("2030-01-02T15:00")
        XCTAssertEqual(reminderParts.year, 2030)
        XCTAssertEqual(reminderParts.month, 1)
        XCTAssertEqual(reminderParts.day, 2)
        XCTAssertEqual(reminderParts.hour, 15)
        XCTAssertEqual(reminderParts.minute, 0)
        XCTAssertEqual(reminder.at, AssistantTime.parse("2030-01-02T15:00"))
        let spaced = try parts("2030-01-02 15:30")
        XCTAssertEqual(spaced.year, 2030)
        XCTAssertEqual(spaced.month, 1)
        XCTAssertEqual(spaced.day, 2)
        XCTAssertEqual(spaced.hour, 15)
        XCTAssertEqual(spaced.minute, 30)
        let zoned = try parts("2030-01-02 15:00Z", utc: true)
        XCTAssertEqual(zoned.year, 2030)
        XCTAssertEqual(zoned.month, 1)
        XCTAssertEqual(zoned.day, 2)
        XCTAssertEqual(zoned.hour, 15)
        XCTAssertEqual(zoned.minute, 0)
        let dayOnly = try parts("2030-01-02")
        XCTAssertEqual(dayOnly.year, 2030)
        XCTAssertEqual(dayOnly.month, 1)
        XCTAssertEqual(dayOnly.day, 2)
        XCTAssertEqual(dayOnly.hour, 0)
        XCTAssertEqual(dayOnly.minute, 0)
        let unpadded = try parts("2030-1-2")
        XCTAssertEqual(unpadded.year, 2030)
        XCTAssertEqual(unpadded.month, 1)
        XCTAssertEqual(unpadded.day, 2)
        XCTAssertEqual(unpadded.hour, 0)
        XCTAssertEqual(unpadded.minute, 0)
        let unpaddedTime = try parts("2030-1-2 15:00")
        XCTAssertEqual(unpaddedTime.year, 2030)
        XCTAssertEqual(unpaddedTime.month, 1)
        XCTAssertEqual(unpaddedTime.day, 2)
        XCTAssertEqual(unpaddedTime.hour, 15)
        XCTAssertEqual(unpaddedTime.minute, 0)
        let shortHour = try parts("2030-01-2T9:05")
        XCTAssertEqual(shortHour.year, 2030)
        XCTAssertEqual(shortHour.month, 1)
        XCTAssertEqual(shortHour.day, 2)
        XCTAssertEqual(shortHour.hour, 9)
        XCTAssertEqual(shortHour.minute, 5)
        XCTAssertNil(AssistantTime.parse("2030-01-02T24:00"), "An impossible hour is rejected, not turned into midnight")
        XCTAssertNil(AssistantTime.parse("2030-01-02T15:75"))
        XCTAssertNil(AssistantTime.parse("2030-02-30"))
        XCTAssertEqual(reminder.needsConfirmation, false)
        let joining = #"{"action":"join","meeting":"\#(meetingID.uuidString)","moment":"","mode":"","scope":"","text":"","fact":"","reaction":"","n":5,"minutes":10,"at":""}"#
        XCTAssertTrue(try AssistantCommandPrompt.parse(joining, context: context).needsConfirmation)

        fresh.assistant.observeVariant("Подтвердить")
        XCTAssertEqual(fresh.assistant.preferredStance(), "confirm")
        let ranked = ReplyDraft(chat: "Да", reaction: nil, variants: [
            .init(stance: "подтвердить", text: "Да"), .init(stance: "decline", text: "Нет")
        ]).ranked(preferredStance: fresh.assistant.preferredStance(), edits: [])
        XCTAssertEqual(ranked.variants?.first?.stance, "подтвердить")

        for _ in 0..<3 {
            fresh.assistant.observeModeChange(.watch, meetingTitle: "Infra sync", invitation: first.invitation, series: nil)
        }
        let suggestion = try XCTUnwrap(fresh.assistant.suggestions.first { $0.kind == .meetingMode })
        coordinator.keepSuggestion(suggestion.id)
        XCTAssertEqual(fresh.preset(room: first.invitation)?.title, "Infra sync")
        struct NotTheCacheError: Error {}
        XCTAssertFalse(VoxCacheRecovery.isUnusableCacheError(NotTheCacheError()))
        enum CacheProbe: Error { case nilError }
        XCTAssertTrue(VoxCacheRecovery.isUnusableCacheError(CacheProbe.nilError))
        let recovered = await VoxModelRecovery.recover { () async throws -> Int in throw NotTheCacheError() }
        XCTAssertNil(recovered)

        let journal = store(); await journal.waitForMoments()
        journal.log(.init(at: Date(), meetingTitle: "Day", presetID: nil, window: nil, verdict: verdict, provider: "local", model: "m", outcome: .shown))
        journal.log(.init(at: Date(), meetingTitle: "Day", presetID: nil, window: nil, verdict: nil, provider: "local", model: "m", outcome: .belowThreshold))
        let lines = try String(contentsOf: journal.decisionFiles()[0], encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.filter { !$0.isEmpty }.count, 2)
        XCTAssertFalse((lines.last?.isEmpty == true ? lines.dropLast() : lines).contains(""),
            "A repaired line ending does not insert a blank record")
    }

    func testOutcomeEditsAreNotWrittenOnEveryKeystroke() async throws {
        let root = folder(), data = AssistantDataStore(root: root)
        await data.waitForLoad()
        let outcome = MeetingOutcome(meetingTitle: "Infra", endedAt: Date(), summary: "Original")
        data.addOutcome(outcome)
        await data.waitForSave()
        var edited = outcome
        edited.summary = "Typed"
        data.updateOutcome(edited)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("assistant.json"), encoding: .utf8).contains("Typed"))
        await data.waitForSave()
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("assistant.json"), encoding: .utf8).contains("Typed"))
        let untouched = try Data(contentsOf: root.appendingPathComponent("assistant.json"))
        data.flushOutcomeEditsSynchronously()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("assistant.json")), untouched,
            "Quit does not rewrite the file when no edit is waiting")
        var pending = edited
        pending.summary = "Quit save"
        data.updateOutcome(pending)
        data.flushOutcomeEditsSynchronously()
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("assistant.json"), encoding: .utf8).contains("Quit save"))
        let quitRoot = folder()
        try FileManager.default.createDirectory(at: quitRoot, withIntermediateDirectories: true)
        let sentinel = Data("kept".utf8)
        try sentinel.write(to: quitRoot.appendingPathComponent("assistant.json"))
        let early = AssistantDataStore(root: quitRoot)
        early.flushOutcomeEditsSynchronously()
        XCTAssertEqual(try Data(contentsOf: quitRoot.appendingPathComponent("assistant.json")), sentinel,
            "Quit before load does not replace assistant.json with an empty document")
    }

    private func spin(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 where !predicate() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
}

private final class FakeOutcomeWriter: MeetingOutcomeWriter, @unchecked Sendable {
    var calls = 0
    var request: MeetingOutcomeRequest?
    func outcome(_ request: MeetingOutcomeRequest) async throws -> MeetingOutcomeContent {
        calls += 1; self.request = request
        try? await Task.sleep(for: .milliseconds(30))
        return .init(summary: "DNS migration reviewed.", decisions: ["Migrate"], tasks: [.init(text: "Update DNS", owner: "Anna")], openQuestions: [])
    }
}

private final class FakeMomentSummarizer: MomentSummarizer, @unchecked Sendable {
    var calls = 0
    var request: MomentSummaryRequest?
    func summarize(_ request: MomentSummaryRequest) async throws -> String {
        calls += 1; self.request = request; return "Someone answered."
    }
}

private final class FakeWriter: ReplyWriter, @unchecked Sendable {
    var calls = 0
    func draft(_ request: ReplyRequest) async throws -> ReplyResult {
        calls += 1
        return .init(draft: .init(chat: "Сейчас посмотрю и отвечу.", reaction: .like), latency: 0.1)
    }
}

private final class FakeJudge: AttentionJudge, @unchecked Sendable {
    var next = AttentionVerdict(level: .no, probability: 0.1, reason: "Quiet.", evidence: [], action: .none)
    var error: Error?
    var calls = 0
    var lastTitle: String?
    var lastChannels: ReplyChannels?
    func judge(_ request: JudgeRequest) async throws -> JudgeResult {
        calls += 1; lastTitle = request.window.meetingTitle; lastChannels = request.replyChannels
        if let error { throw error }
        let evidence = next.evidence.compactMap { ref in request.window.line(ref: ref)?.id }
        var verdict = next; verdict.evidence = evidence
        return .init(verdict: verdict, latency: 0.2)
    }
}

/// Answers every request with a scripted status and body.
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    static func session(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> URLSession {
        Self.handler = handler
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return data
    }
    static func answer(_ content: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": content]]]])
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler?(request) ?? (500, Data())
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

/// Connects at once with two participants and no media.
@MainActor private final class AttentionTestEngine: NativeDesktopMeetingEngine {
    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    var factory: LKRTCPeerConnectionFactory? { nil }
    private(set) var snapshot = NativeDesktopExternalSnapshot()
    var incomingVideo: [NativeDesktopExternalVideo] { [] }
    func connect(invitation: URL, name: String, quiet: Bool) async throws {
        snapshot = .init(phase: .connected, playoutOn: !quiet, participants: [
            .init(id: "me", name: name, isLocal: true), .init(id: "anna", name: "Anna")])
        onState?(snapshot)
    }
    func reconnect() async throws {}
    func setMicrophone(_ enabled: Bool) async throws { snapshot.microphoneOn = enabled; onState?(snapshot) }
    func setCamera(_ enabled: Bool) async throws {}
    func setPlayout(_ enabled: Bool) async throws { snapshot.playoutOn = enabled; onState?(snapshot) }
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {}
    func leave() async -> Bool { snapshot.phase = .left; onState?(snapshot); return true }
}
