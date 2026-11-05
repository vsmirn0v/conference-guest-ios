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
        addTeardownBlock { keychain.delete() }
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
        coordinator.setPaused(true, meetingID: infra.sessionID)
        XCTAssertEqual(coordinator.waitingReason(infra), L("Paused for this meeting."))
        coordinator.setPaused(false, meetingID: infra.sessionID)
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
    }

    func testCoordinatorDraftsAReplyAndSendsOnlyWhatYouApprove() async throws {
        let store = store()
        store.enabled = true; store.provider = .init(kind: .local, baseURL: "http://127.0.0.1:1/v1", model: "m")
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
    }

    private func spin(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 where !predicate() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
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
