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
