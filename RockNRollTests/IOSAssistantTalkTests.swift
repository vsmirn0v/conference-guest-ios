import AVFoundation
import ConferenceCore
import XCTest
@testable import RockNRoll

@MainActor
final class IOSAssistantTalkTests: XCTestCase {
    private final class SuiteBox {
        let name: String
        let defaults: UserDefaults

        init() {
            name = "ios.assistant.talk.tests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
        }

        deinit {
            defaults.removePersistentDomain(forName: name)
        }
    }

    private func makeSessionItem(id: UUID = UUID(), title: String, startedAt: Date) -> IOSMeetingSessionItem {
        IOSMeetingSessionItem(
            id: id,
            occurrenceKey: "occ-\(id.uuidString)",
            title: title,
            hasTitleOverride: false,
            invitation: URL(string: "https://meet.example.com/\(id.uuidString)"),
            roomIdentity: "meet.example.com",
            calendarSeriesID: nil,
            externalSeriesID: nil,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1800),
            timeZoneID: "UTC",
            state: "ended",
            legs: [:],
            outcomeClaim: nil,
            obsidianReceipt: nil,
            manualObsidianSaveAt: nil,
            createdAt: startedAt,
            updatedAt: startedAt
        )
    }

    func testWakeWordMonthlyMeetingCountAutoAnswers() async {
        let suite = SuiteBox()
        let voiceStore = IOSVoiceStore(preferences: suite.defaults)
        voiceStore.autoAuditionVoiceReplies = false

        let speech = IOSAssistantSpeechCoordinator()
        speech.isTestingEnvironment = true

        let fixedNow = Date(timeIntervalSince1970: 1_760_500_000) // Oct 2025
        let cal = Calendar(identifier: .gregorian)
        let lastMonth = cal.date(byAdding: .month, value: -1, to: fixedNow)!

        let talk = IOSAssistantTalkController(speech: speech, voiceStore: voiceStore)
        talk.now = { fixedNow }
        talk.sessionsProvider = { [self] in
            [
                makeSessionItem(title: "Product Sync", startedAt: fixedNow.addingTimeInterval(-86_400)),
                makeSessionItem(title: "Design Review", startedAt: fixedNow.addingTimeInterval(-172_800)),
                makeSessionItem(title: "Last Month Kickoff", startedAt: lastMonth),
            ]
        }

        speech.onWakeCommand = { command in
            await talk.run(command, source: .voiceWake)
        }

        let outcome = await speech.processTranscriptForTesting("рок, сколько было встреч в этом месяце?", isFinal: true, now: fixedNow)
        XCTAssertEqual(outcome, .triggered(command: "сколько было встреч в этом месяце?"))
        XCTAssertNil(talk.pendingApproval)
        let answer = talk.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(answer.contains("2"), "Expected 2 meetings this month, got: \(answer)")
        XCTAssertTrue(answer.contains("Product Sync"))
        XCTAssertFalse(answer.contains("Last Month Kickoff"))
    }

    func testWakeJoinCurrentMeetingAutoExecutesWhileTypedAsks() async {
        let suite = SuiteBox()
        let voiceStore = IOSVoiceStore(preferences: suite.defaults)
        voiceStore.autoAuditionVoiceReplies = false

        let speech = IOSAssistantSpeechCoordinator()
        speech.isTestingEnvironment = true
        let fixedNow = Date(timeIntervalSince1970: 1_760_500_000)
        let ongoingInvite = URL(string: "https://meet.example.com/current-standup")!
        let candidate = JoinableMeetingCandidate(
            id: CurrentMeetingTargetResolver.stableID(namespace: "calendar", key: "standup"),
            title: "Current Standup",
            invitation: ongoingInvite,
            source: .ongoingCalendar,
            start: fixedNow.addingTimeInterval(-300),
            end: fixedNow.addingTimeInterval(1500)
        )

        var joinedCandidates: [JoinableMeetingCandidate] = []
        let talk = IOSAssistantTalkController(speech: speech, voiceStore: voiceStore)
        talk.now = { fixedNow }
        talk.joinableTargets = { _ in [candidate] }
        talk.onJoinCandidate = { item in
            joinedCandidates.append(item)
            return true
        }
        speech.onWakeCommand = { command in
            await talk.run(command, source: .voiceWake)
        }

        // Typed join requires explicit confirmation
        await talk.run("join current meeting", source: .typed)
        XCTAssertEqual(talk.pendingApproval?.kind, .join)
        XCTAssertTrue(joinedCandidates.isEmpty)
        talk.cancelPendingApproval()
        XCTAssertNil(talk.pendingApproval)

        // Voice wake join executes immediately
        _ = await speech.processTranscriptForTesting("рок, подключи меня к текущей встрече", isFinal: true, now: fixedNow)
        XCTAssertNil(talk.pendingApproval)
        XCTAssertEqual(joinedCandidates.map(\.invitation), [ongoingInvite])
    }

    func testVoiceConfirmationPolicyForMuteParticipateChatAndLeave() async {
        let suite = SuiteBox()
        let voiceStore = IOSVoiceStore(preferences: suite.defaults)
        voiceStore.autoAuditionVoiceReplies = false
        let speech = IOSAssistantSpeechCoordinator()
        speech.isTestingEnvironment = true
        let assistant = IOSAssistantCoordinator(workspace: nil, preferences: suite.defaults, resolveBridge: { _ in nil })

        let meetingID = UUID()
        assistant.setParticipationOptions(for: meetingID, askBeforeSending: true, output: .chat, goal: "")

        var mutedCalled = false
        var participateObjective: String?
        var sentChat: [String] = []
        var leaveCalled = false

        let talk = IOSAssistantTalkController(assistant: assistant, speech: speech, voiceStore: voiceStore)
        talk.activeMeetingsProvider = {
            [(id: meetingID, title: "Engineering Sync", isUnmuted: true, canSendChat: true, sessionID: nil)]
        }
        talk.onMuteMeeting = { _ in
            mutedCalled = true
            return "Muted"
        }
        talk.onRequestParticipation = { _, goal in
            participateObjective = goal
        }
        talk.onSendChat = { _, text in
            sentChat.append(text)
        }
        talk.onLeaveMeeting = { _ in
            leaveCalled = true
            return true
        }

        // 1. Voice mute & participate execute immediately without approval
        await talk.run("выключи микрофон", source: .voiceWake)
        XCTAssertTrue(mutedCalled)
        XCTAssertNil(talk.pendingApproval)

        await talk.run("перейди в режим участия с контекстом согласовать релиз", source: .voiceWake)
        XCTAssertEqual(participateObjective, "согласовать релиз")
        XCTAssertNil(talk.pendingApproval)

        // 2. Voice chat asks before sending when askBeforeSending == true
        await talk.run("отправь в чат Буду через 5 минут", source: .voiceWake)
        XCTAssertEqual(talk.pendingApproval?.kind, .sendChat)
        XCTAssertTrue(sentChat.isEmpty)
        talk.confirmPendingApproval()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sentChat, ["Буду через 5 минут"])

        // 3. Voice leave always requires confirmation
        await talk.run("покинь встречу", source: .voiceWake)
        XCTAssertEqual(talk.pendingApproval?.kind, .leave)
        XCTAssertFalse(leaveCalled)
        talk.cancelPendingApproval()
        XCTAssertFalse(leaveCalled)
    }

    func testDictationPopulatesAndCancelsCleanly() async {
        let speech = IOSAssistantSpeechCoordinator()
        speech.isTestingEnvironment = true
        speech.transcribeOverride = { _ in "Обсудить бюджет Q4" }

        var capturedFinal = ""
        speech.startDictation(
            onPartial: { _ in },
            onFinal: { text in capturedFinal = text }
        )
        XCTAssertEqual(speech.mode, .dictating)

        // Simulate 0.5 s audio burst (~8000 samples) + silence hangover (~12000 zeros) -> VAD emits segment
        let speechBurst = (0..<8_000).map { i in Float(sin(Double(i) * 0.1) * 0.25) }
        let silenceTail = [Float](repeating: 0, count: 16_000)
        await speech.processSampleChunkForTesting(speechBurst + silenceTail)
        XCTAssertEqual(capturedFinal, "Обсудить бюджет Q4")
        XCTAssertEqual(speech.mode, .idle)

        // Manual cancel leaves previous state intact
        speech.startDictation(onPartial: { _ in }, onFinal: { _ in XCTFail("Cancelled dictation must not commit") })
        speech.stopDictation(commit: false)
        XCTAssertEqual(speech.mode, .idle)
    }

    func testVoiceStorePresetPersistenceAndFallbackSynthesis() async throws {
        let suite = SuiteBox()
        let store = IOSVoiceStore(preferences: suite.defaults)
        store.wakeWordEnabled = false
        store.assistantAuditionVoice = .voxPreset(.warmFemale)
        store.autoAuditionVoiceReplies = false
        store.autoAuditionTypedReplies = true

        let reloaded = IOSVoiceStore(preferences: suite.defaults)
        XCTAssertFalse(reloaded.wakeWordEnabled)
        XCTAssertEqual(reloaded.assistantAuditionVoice, .voxPreset(.warmFemale))
        XCTAssertFalse(reloaded.autoAuditionVoiceReplies)
        XCTAssertTrue(reloaded.autoAuditionTypedReplies)

        // Without VoxCPM2 model downloaded on simulator, audition cleanly falls back to iPhone system voice
        do {
            let buffer = try await reloaded.synthesizeAssistantResponse("Проверка голоса ассистента")
            XCTAssertGreaterThan(buffer.frameLength, 0)
        } catch {
            // In bare CI simulator environments without system TTS voices installed, allow system error rather than voxModelNotInstalled
            XCTAssertNotEqual(error as? IOSVoiceSynthesisError, .voxModelNotInstalled)
        }
    }
}
