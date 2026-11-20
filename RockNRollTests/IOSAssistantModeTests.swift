import ConferenceCore
import XCTest
@testable import RockNRoll

@MainActor
final class IOSAssistantModeTests: XCTestCase {
    private actor MockEvaluator: IOSAssistantEvaluating {
        var nextVerdict: IOSAssistantVerdict = .quiet
        var requests: [IOSAssistantEvaluationRequest] = []

        func setVerdict(_ verdict: IOSAssistantVerdict) {
            nextVerdict = verdict
        }

        func evaluate(_ request: IOSAssistantEvaluationRequest) async throws -> IOSAssistantVerdict {
            requests.append(request)
            return nextVerdict
        }

        func capturedRequests() -> [IOSAssistantEvaluationRequest] {
            requests
        }
    }

    private actor SuspendedEvaluator: IOSAssistantEvaluating {
        let started: XCTestExpectation
        var continuation: CheckedContinuation<IOSAssistantVerdict, Never>?

        init(started: XCTestExpectation) { self.started = started }

        func evaluate(_ request: IOSAssistantEvaluationRequest) async throws -> IOSAssistantVerdict {
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }

        func finish() {
            continuation?.resume(returning: .init(needsUser: true, urgency: .now, reason: "Direct question",
                                                  suggestedReply: "Late reply", confidence: 1))
            continuation = nil
        }
    }

    private final class SuiteBox {
        let name: String
        let defaults: UserDefaults

        init() {
            let name = "ios.assistant.tests.\(UUID().uuidString)"
            self.name = name
            self.defaults = UserDefaults(suiteName: name)!
            self.defaults.removePersistentDomain(forName: name)
        }

        deinit {
            defaults.removePersistentDomain(forName: name)
        }
    }

    private func makeCoordinator(
        evaluator: MockEvaluator,
        bridgeBox: @escaping (UUID) -> IOSAssistantSessionBridge?
    ) -> (IOSAssistantCoordinator, SuiteBox, [IOSAssistantAlertCard]) {
        let suite = SuiteBox()
        var notified: [IOSAssistantAlertCard] = []
        let coordinator = IOSAssistantCoordinator(
            workspace: nil,
            preferences: suite.defaults,
            evaluator: evaluator,
            evaluationCooldown: 0,
            mentionCooldown: 0,
            resolveBridge: bridgeBox,
            scheduleNotification: { _ in }
        )
        coordinator.onBannerAlert = { card in
            notified.append(card)
        }
        return (coordinator, suite, notified)
    }

    private func makeEvent(id: String, speaker: String?, isOwn: Bool = false, text: String) -> SyncedTranscriptEvent {
        SyncedTranscriptEvent(
            id: id,
            kind: "transcript",
            occurredAt: Date(),
            speaker: speaker,
            isOwn: isOwn,
            text: text,
            deviceID: isOwn ? "iphone-test" : "remote-test"
        )
    }

    private func bridge(for id: UUID, speak: @escaping (String) -> Void = { _ in }) -> IOSAssistantSessionBridge {
        IOSAssistantSessionBridge(
            controllerID: id, title: "Test meeting", roomKey: "test", calendarSeriesKey: nil,
            localDisplayName: "Алексей", participantNames: ["Ирина"], canSendChat: true,
            isMicUnmuted: false, isForeground: false, ensureTranscription: {},
            sendChat: { _ in }, speakVoice: { speak($0) }
        )
    }

    func testMutedSoundChoosesSavedModeUnlessMeetingHasAnExplicitOverride() async {
        let id = UUID(), other = UUID(), suite = SuiteBox()
        var meeting = bridge(for: id)
        meeting.isForeground = true
        var listening = 0
        var released = 0
        meeting.ensureTranscription = { listening += 1 }
        meeting.releaseTranscription = { released += 1 }
        let otherMeeting = bridge(for: other)
        let coordinator = IOSAssistantCoordinator(
            workspace: nil, preferences: suite.defaults, evaluator: MockEvaluator(),
            resolveBridge: { $0 == id ? meeting : otherMeeting }, scheduleNotification: { _ in }
        )
        coordinator.activePresentationChanged(foregroundControllerID: id)
        XCTAssertEqual(coordinator.resolvedMode(for: id), .off)
        meeting.isMeetingSoundEnabled = false
        coordinator.refreshMode(for: id)
        await Task.yield()
        XCTAssertEqual(coordinator.resolvedMode(for: id), .follow)
        XCTAssertEqual(listening, 1)
        XCTAssertEqual(coordinator.resolvedMode(for: other), .off)

        meeting.isForeground = false
        coordinator.defaultSilencedMode = .mentions
        XCTAssertEqual(coordinator.resolvedMode(for: id), .mentions)
        let reopened = IOSAssistantCoordinator(workspace: nil, preferences: suite.defaults, resolveBridge: { _ in meeting })
        XCTAssertEqual(reopened.defaultSilencedMode, .mentions)
        meeting.isMeetingSoundEnabled = true
        coordinator.refreshMode(for: id)
        await Task.yield()
        XCTAssertEqual(coordinator.resolvedMode(for: id), .off)
        XCTAssertEqual(released, 1)
        coordinator.setMode(.off, for: id)
        meeting.isMeetingSoundEnabled = false
        coordinator.refreshMode(for: id)
        XCTAssertEqual(coordinator.resolvedMode(for: id), .off)
    }

    func testSilencedParticipationPausesForOpenMicAndKeepsAutomaticReplyPrivate() async {
        let id = UUID(), suite = SuiteBox(), evaluator = MockEvaluator()
        var meeting = bridge(for: id)
        meeting.isMicUnmuted = true
        meeting.isMeetingSoundEnabled = false
        meeting.canDeliverAutomaticReplies = false
        meeting.sendChat = { _ in XCTFail("A silenced meeting must keep the draft private") }
        meeting.speakVoice = { _ in XCTFail("A silenced meeting must keep the draft private") }
        let coordinator = IOSAssistantCoordinator(
            workspace: nil, preferences: suite.defaults, evaluator: evaluator, modelAvailable: { true },
            resolveBridge: { _ in meeting }, scheduleNotification: { _ in }
        )
        coordinator.defaultSilencedMode = .participating
        coordinator.setParticipationOptions(for: id, askBeforeSending: false, output: .voiceAndChat, goal: "")
        coordinator.refreshMode(for: id)
        XCTAssertTrue(coordinator.isPausedForMicrophone(controllerID: id))
        meeting.isMicUnmuted = false
        coordinator.handleMicrophoneChange(controllerID: id, unmuted: false)
        await evaluator.setVerdict(.init(needsUser: true, urgency: .now, reason: "Asked", suggestedReply: "Confirmed.", confidence: 1))
        coordinator.observeEvents([makeEvent(id: "q", speaker: "Tim", text: "Will you join?")], for: id)
        await coordinator.evaluateNow(controllerID: id)
        XCTAssertEqual(coordinator.alertCards.first?.suggestedReply, "Confirmed.")
        XCTAssertEqual(coordinator.alertCards.first?.deliveryNote, L("Private text · not sent"))
        XCTAssertEqual(coordinator.alertCards.first?.deliveredAutomatically, false)
        XCTAssertEqual(coordinator.alertCards.first?.deliveryFailed, false)
    }

    func testMentionAtEndOfFinalTranscriptNotifiesOnceWithoutCallingModel() async {
        let id = UUID(), suite = SuiteBox(), evaluator = MockEvaluator()
        let meeting = bridge(for: id)
        let notified = expectation(description: "Final mention generates a notification")
        let coordinator = IOSAssistantCoordinator(
            workspace: nil, preferences: suite.defaults, evaluator: evaluator, modelAvailable: { true },
            resolveBridge: { _ in meeting }, scheduleNotification: { _ in notified.fulfill() }
        )
        coordinator.setMode(.mentions, for: id)
        let partial = makeEvent(id: "same", speaker: "Ирина", text: "Есть вопрос")
        var final = partial
        final.text += ", Алексей."
        coordinator.observeEvents([partial], for: id, partialEventIDs: [partial.id])
        await Task.yield()
        coordinator.observeEvents([final], for: id)
        await fulfillment(of: [notified], timeout: 2)
        coordinator.observeEvents([final], for: id)
        XCTAssertEqual(coordinator.alertCards.map(\.excerpt), ["Ирина: Есть вопрос, Алексей."])
        let requests = await evaluator.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testDirectAddressWithoutLiteralAliasUsesModelInMentions() async {
        let id = UUID(), suite = SuiteBox(), evaluator = MockEvaluator()
        let meeting = bridge(for: id)
        let notified = expectation(description: "Model-recognized direct address")
        await evaluator.setVerdict(.init(needsUser: true, urgency: .now, reason: "Direct question",
                                         suggestedReply: nil, confidence: 1))
        let coordinator = IOSAssistantCoordinator(
            workspace: nil, preferences: suite.defaults, evaluator: evaluator, modelAvailable: { true },
            resolveBridge: { _ in meeting }, scheduleNotification: { _ in notified.fulfill() }
        )
        coordinator.setMode(.mentions, for: id)
        coordinator.observeEvents([makeEvent(id: "q", speaker: "Ирина", text: "Ты можешь подтвердить?")], for: id)
        await fulfillment(of: [notified], timeout: 2)
        let requests = await evaluator.capturedRequests()
        XCTAssertEqual(requests.map(\.mode), [.mentions])
        XCTAssertEqual(coordinator.alertCards.first?.reason, "Direct question")
    }

    func testAssistantDoesNotReadCredentialsOrSendWhenMeetingDataPermissionIsMissing() async {
        let evaluator = IOSAssistantLLMService(
            configProvider: { throw IOSRemoteAIConsentError.permissionRequired },
            apiKeyProvider: { _ in
                XCTFail("The provider must not be contacted without permission")
                return nil
            }
        )
        let request = IOSAssistantEvaluationRequest(
            mode: .follow, meetingTitle: "Private", participantNames: [], userAliases: [],
            contextAbout: "", contextMatters: "", contextNever: "", guidanceRules: [],
            participationGoal: "", replyStyle: "", notesDraft: "Private note", recentEvents: [], language: "en"
        )
        do {
            _ = try await evaluator.evaluate(request)
            XCTFail("Expected permission to be required")
        } catch IOSRemoteAIConsentError.permissionRequired {
            // No remote request was constructed.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testParticipateEvaluatesLastQuestionDuringCooldownAndSpeaksViaOpenAI() async {
        let id = UUID(), suite = SuiteBox()
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [AssistantProviderFixture.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let evaluator = IOSAssistantLLMService(
            configProvider: { PortableOutcomeConfiguration(providerKind: .openAI, model: "gpt-5.4-mini") },
            apiKeyProvider: { _ in "fixture" }, urlSession: session
        )
        let delivered = expectation(description: "Only the last turn needs a voice reply")
        let meeting = bridge(for: id) { reply in
            XCTAssertEqual(reply, "Confirmed.")
            delivered.fulfill()
        }
        let coordinator = IOSAssistantCoordinator(
            workspace: nil, preferences: suite.defaults, evaluator: evaluator, modelAvailable: { true },
            evaluationCooldown: 0.2, resolveBridge: { _ in meeting }, scheduleNotification: { _ in }
        )
        coordinator.setMode(.participating, for: id)
        coordinator.setParticipationOptions(for: id, askBeforeSending: false, output: .voice, goal: "")
        let first = makeEvent(id: "intro", speaker: "Ирина", text: "First agenda item.")
        coordinator.observeEvents([first], for: id)
        await coordinator.evaluateNow(controllerID: id)
        XCTAssertTrue(coordinator.alertCards.isEmpty)
        let question = makeEvent(id: "q", speaker: "Ирина", text: "Can you confirm?")
        coordinator.observeEvents([first, question], for: id)
        await fulfillment(of: [delivered], timeout: 3)
        XCTAssertEqual(coordinator.alertCards.first?.deliveredAutomatically, true)
        XCTAssertNil(coordinator.evaluationErrors[id])
    }

    func testChatFailureStillSendsAutomaticVoiceAndReportsPartialDelivery() async throws {
        let id = UUID(), suite = SuiteBox(), evaluator = MockEvaluator()
        let alerted = expectation(description: "User is notified about the failed channel")
        await evaluator.setVerdict(.init(needsUser: true, urgency: .now, reason: "Direct question",
                                         suggestedReply: "Confirmed.", confidence: 1))
        var spoken: [String] = []
        var meeting = bridge(for: id) { spoken.append($0) }
        meeting.isForeground = true
        meeting.sendChat = { _ in throw URLError(.networkConnectionLost) }
        let coordinator = IOSAssistantCoordinator(
            workspace: nil, preferences: suite.defaults, evaluator: evaluator, modelAvailable: { true },
            resolveBridge: { _ in meeting }, scheduleNotification: { _ in alerted.fulfill() }
        )
        coordinator.setMode(.participating, for: id)
        coordinator.setParticipationOptions(for: id, askBeforeSending: false, output: .voiceAndChat, goal: "")
        coordinator.observeEvents([makeEvent(id: "q", speaker: "Ирина", text: "Can you confirm?")], for: id)
        await fulfillment(of: [alerted], timeout: 2)
        let card = try XCTUnwrap(coordinator.alertCards.first)
        XCTAssertEqual(spoken, ["Confirmed."])
        XCTAssertTrue(card.deliveredAutomatically)
        XCTAssertTrue(card.deliveryFailed)
        XCTAssertTrue(card.deliveryNote?.contains(L("Voice")) == true)
        XCTAssertTrue(card.deliveryNote?.contains(L("Chat")) == true)
    }

    func testTurningParticipationOffWhileProviderIsThinkingDiscardsLateVoiceReply() async {
        let id = UUID(), suite = SuiteBox()
        let started = expectation(description: "Provider received the question")
        let evaluator = SuspendedEvaluator(started: started)
        let meeting = bridge(for: id) { _ in XCTFail("Participation was turned off") }
        let coordinator = IOSAssistantCoordinator(
            workspace: nil, preferences: suite.defaults, evaluator: evaluator, modelAvailable: { true },
            resolveBridge: { _ in meeting }, scheduleNotification: { _ in XCTFail("Unexpected late alert") }
        )
        coordinator.setMode(.participating, for: id)
        coordinator.setParticipationOptions(for: id, askBeforeSending: false, output: .voice, goal: "")
        coordinator.observeEvents([makeEvent(id: "q", speaker: "Ирина", text: "Can you confirm?")], for: id)
        let check = Task { await coordinator.evaluateNow(controllerID: id) }
        await fulfillment(of: [started], timeout: 2)
        coordinator.setMode(.off, for: id)
        await evaluator.finish()
        await check.value
        XCTAssertTrue(coordinator.alertCards.isEmpty)
    }

    func testMentionModeTriggersDeterministicallyAndIgnoresOwnLines() async {
        let evaluator = MockEvaluator()
        let controllerID = UUID()
        let bridge = IOSAssistantSessionBridge(
            controllerID: controllerID,
            title: "Design Sync",
            roomKey: "https://rock.glowsoft.ru/jams/design",
            calendarSeriesKey: nil,
            localDisplayName: "Vitalii",
            participantNames: ["Anna", "Boris"],
            canSendChat: true,
            isMicUnmuted: false,
            isForeground: true,
            ensureTranscription: {},
            sendChat: { _ in },
            speakVoice: { _ in }
        )

        let suite = SuiteBox()
        let coordinator = IOSAssistantCoordinator(
            workspace: nil,
            preferences: suite.defaults,
            evaluator: evaluator,
            modelAvailable: { false },
            evaluationCooldown: 0,
            mentionCooldown: 0,
            resolveBridge: { $0 == controllerID ? bridge : nil },
            scheduleNotification: { _ in }
        )

        coordinator.setMode(.mentions, for: controllerID)
        XCTAssertEqual(coordinator.resolvedMode(for: controllerID), .mentions)

        // Own utterance mentioning own name should NOT trigger an alert.
        coordinator.observeEvents([
            makeEvent(id: "own-1", speaker: "Vitalii", isOwn: true, text: "Vitalii here testing")
        ], for: controllerID)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(coordinator.alertCards.isEmpty)

        // Remote utterance mentioning "Vitalii" MUST trigger an alert card even without LLM.
        coordinator.observeEvents([
            makeEvent(id: "rem-1", speaker: "Anna", text: "Hey Vitalii, can you confirm the deadline?")
        ], for: controllerID)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(coordinator.alertCards.count, 1)
        let card = coordinator.alertCards[0]
        XCTAssertEqual(card.controllerID, controllerID)
        XCTAssertEqual(card.mode, .mentions)
        XCTAssertEqual(card.urgency, .now)
        XCTAssertTrue(card.excerpt.contains("Anna: Hey Vitalii"))
    }

    func testFollowModeUsesEvaluatorAndPublishesCard() async {
        let evaluator = MockEvaluator()
        await evaluator.setVerdict(IOSAssistantVerdict(
            needsUser: true,
            urgency: .now,
            reason: "Asking whether iOS beta is ready for TestFlight.",
            suggestedReply: "Yes, build 129 is uploading now.",
            confidence: 0.92
        ))

        let controllerID = UUID()
        var transcriptionStarted = false
        let bridge = IOSAssistantSessionBridge(
            controllerID: controllerID,
            title: "Release Standup",
            roomKey: "https://rock.glowsoft.ru/jams/release",
            calendarSeriesKey: nil,
            localDisplayName: "Alex",
            participantNames: ["Ivan"],
            canSendChat: true,
            isMicUnmuted: false,
            isForeground: false,
            ensureTranscription: { transcriptionStarted = true },
            sendChat: { _ in },
            speakVoice: { _ in }
        )

        let suite = SuiteBox()
        let defaultsConfig = PortableOutcomeConfiguration(providerKind: .custom, baseURL: "https://llm.example.test/v1", model: "gpt-test")
        if let encoded = try? JSONEncoder().encode(defaultsConfig) {
            suite.defaults.set(encoded, forKey: IOSWorkspaceCoordinator.outcomeConfigDefaultsKey)
        }
        var notifiedCards: [IOSAssistantAlertCard] = []
        let coordinator = IOSAssistantCoordinator(
            workspace: nil,
            preferences: suite.defaults,
            evaluator: evaluator,
            modelAvailable: { true },
            evaluationCooldown: 0,
            mentionCooldown: 0,
            resolveBridge: { $0 == controllerID ? bridge : nil },
            scheduleNotification: { card in notifiedCards.append(card) }
        )

        coordinator.setMode(.follow, for: controllerID)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(transcriptionStarted)

        coordinator.observeEvents([
            makeEvent(id: "ev-1", speaker: "Ivan", text: "Do we ship build 129 today?")
        ], for: controllerID)
        await coordinator.evaluateNow(controllerID: controllerID)

        let captured = await evaluator.capturedRequests()
        XCTAssertFalse(captured.isEmpty)
        XCTAssertEqual(coordinator.alertCards.count, 1)
        XCTAssertEqual(coordinator.alertCards[0].suggestedReply, "Yes, build 129 is uploading now.")
        XCTAssertEqual(notifiedCards.count, 1, "Background call triggers local notification alert")
        coordinator.dismissCard(coordinator.alertCards[0].id)
        XCTAssertTrue(coordinator.alertCards.isEmpty)
    }

    func testParticipatingModeAskFirstManualSendSpeakAndMicAutoPause() async throws {
        let evaluator = MockEvaluator()
        await evaluator.setVerdict(IOSAssistantVerdict(
            needsUser: true,
            urgency: .now,
            reason: "Question directed at you",
            suggestedReply: "I will check the CloudKit sync logs right away.",
            confidence: 0.9
        ))

        let controllerID = UUID()
        var micUnmuted = false
        var sentChats: [String] = []
        var spokenReplies: [String] = []

        let makeBridge: () -> IOSAssistantSessionBridge = {
            IOSAssistantSessionBridge(
                controllerID: controllerID,
                title: "Sync Triage",
                roomKey: "https://rock.glowsoft.ru/jams/triage",
                calendarSeriesKey: nil,
                localDisplayName: "Vitalii",
                participantNames: ["Elena"],
                canSendChat: true,
                isMicUnmuted: micUnmuted,
                isForeground: true,
                ensureTranscription: {},
                sendChat: { sentChats.append($0) },
                speakVoice: { spokenReplies.append($0) }
            )
        }

        let suite = SuiteBox()
        let coordinator = IOSAssistantCoordinator(
            workspace: nil,
            preferences: suite.defaults,
            evaluator: evaluator,
            modelAvailable: { true },
            evaluationCooldown: 0,
            mentionCooldown: 0,
            resolveBridge: { $0 == controllerID ? makeBridge() : nil },
            scheduleNotification: { _ in }
        )

        // Default is askBeforeSending = true
        coordinator.setMode(.participating, for: controllerID)
        XCTAssertTrue(coordinator.effectiveAskBeforeSending(for: controllerID))

        coordinator.observeEvents([
            makeEvent(id: "p-1", speaker: "Elena", text: "Vitalii, can you look into CloudKit?")
        ], for: controllerID)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(coordinator.alertCards.count, 1)
        XCTAssertTrue(sentChats.isEmpty, "Ask-before-sending must not auto-send")
        XCTAssertTrue(spokenReplies.isEmpty)

        // User edits & sends manually to chat and speaks
        let cardID = coordinator.alertCards[0].id
        coordinator.updateCardDraft(cardID, text: "Checking CloudKit now.")
        try await coordinator.sendCardToChat(cardID)
        try await coordinator.speakCardReply(cardID)
        XCTAssertEqual(sentChats, ["Checking CloudKit now."])
        XCTAssertEqual(spokenReplies, ["Checking CloudKit now."])

        // Mic unmute pauses participating automatically
        micUnmuted = true
        coordinator.handleMicrophoneChange(controllerID: controllerID, unmuted: true)
        XCTAssertTrue(coordinator.isPausedForMicrophone(controllerID: controllerID))

        coordinator.setParticipationOptions(
            for: controllerID,
            askBeforeSending: false,
            output: .voiceAndChat,
            goal: "Confirm status"
        )

        // While paused for mic unmuted, new events must NOT auto-reply
        coordinator.observeEvents([
            makeEvent(id: "p-2", speaker: "Elena", text: "Vitalii, are you still checking?")
        ], for: controllerID)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(sentChats.count, 1, "Must remain paused while mic is unmuted")
        XCTAssertEqual(spokenReplies.count, 1)

        // Mute mic again -> resumes and auto-delivers when askBeforeSending == false
        micUnmuted = false
        coordinator.handleMicrophoneChange(controllerID: controllerID, unmuted: false)
        XCTAssertFalse(coordinator.isPausedForMicrophone(controllerID: controllerID))

        coordinator.observeEvents([
            makeEvent(id: "p-3", speaker: "Elena", text: "Vitalii, ready whenever you are!")
        ], for: controllerID)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(sentChats.count, 2, "Should auto-deliver to chat once mic is muted again")
        XCTAssertEqual(spokenReplies.count, 2, "Should auto-deliver to voice once mic is muted again")
    }

    func testVerdictJSONParsingAndLocalMentionHelper() throws {
        let parsed = try IOSAssistantLLMService.parseVerdict("""
        ```json
        {"needs_user": true, "urgency": "now", "reason": "Direct question about rollout.", "suggested_reply": "Rolling out today.", "confidence": 0.94}
        ```
        """)
        XCTAssertTrue(parsed.needsUser)
        XCTAssertEqual(parsed.urgency, .now)
        XCTAssertEqual(parsed.suggestedReply, "Rolling out today.")

        let partial = [
            makeEvent(id: "1", speaker: "Ben", text: "This is vital information."),
            makeEvent(id: "2", speaker: "Ben", text: "Ask @Vitalii to confirm.")
        ]
        let found = IOSAssistantCoordinator.findMention(in: partial, aliases: ["Vitalii"])
        XCTAssertEqual(found?.event.id, "2")
    }
}

private final class AssistantProviderFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let body: Data
            if let data = request.httpBody {
                body = data
            } else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                body = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: stream))
            }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            XCTAssertEqual(json["model"] as? String, "gpt-5.4-mini")
            XCTAssertNotNil(json["max_completion_tokens"])
            XCTAssertNil(json["max_tokens"])
            XCTAssertNil(json["temperature"])
            let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
            let needsReply = messages.last?["content"]?.contains("Can you confirm?") == true
            let verdict = needsReply
                ? #"{"needs_user":true,"urgency":"now","reason":"Confirmation requested","suggested_reply":"Confirmed."}"#
                : #"{"needs_user":false,"urgency":"none"}"#
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": verdict]]]])
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200,
                                                         httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
