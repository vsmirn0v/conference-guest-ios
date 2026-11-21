import Foundation
import XCTest
@testable import ConferenceCore

final class AssistantWakeAndPresetsTests: XCTestCase {
    func testWakePhraseMatcherExtractsRussianAndEnglishCommands() {
        XCTAssertEqual(
            AssistantWakePhraseMatcher.match("рок, подключи меня к текущей встрече"),
            .command("подключи меня к текущей встрече")
        )
        XCTAssertEqual(
            AssistantWakePhraseMatcher.match("Рок сколько было встреч в этом месяце?"),
            .command("сколько было встреч в этом месяце?")
        )
        XCTAssertEqual(
            AssistantWakePhraseMatcher.match("рог, какие у меня задачи на сегодня?"),
            .command("какие у меня задачи на сегодня?")
        )
        XCTAssertEqual(
            AssistantWakePhraseMatcher.match("Эй, Рок-н-ролл! Замуть микрофон"),
            .command("Замуть микрофон")
        )
        XCTAssertEqual(
            AssistantWakePhraseMatcher.match("Hey Rock, join my current meeting"),
            .command("join my current meeting")
        )
        XCTAssertEqual(AssistantWakePhraseMatcher.match("Привет, Рок"), .wakeOnly)
        XCTAssertEqual(AssistantWakePhraseMatcher.match("Rock"), .wakeOnly)
        XCTAssertEqual(
            AssistantWakePhraseMatcher.match("вчера обсуждали рок музыку"),
            .none
        )
        XCTAssertEqual(
            AssistantWakePhraseMatcher.match("рокетная программа"),
            .none
        )
    }

    func testWakeDetectorTwoBeatArmWindow() {
        var detector = AssistantWakeDetector(armWindowSeconds: 5.0)
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)

        XCTAssertEqual(detector.consume(transcript: "просто текст", isFinal: true, now: t0), .ignored)
        XCTAssertEqual(detector.consume(transcript: "Рок", isFinal: false, now: t0), .armed(until: t0.addingTimeInterval(5.0)))
        XCTAssertFalse(detector.isArmed(at: t0))

        XCTAssertEqual(detector.consume(transcript: "Рок", isFinal: true, now: t0), .armed(until: t0.addingTimeInterval(5.0)))
        XCTAssertTrue(detector.isArmed(at: t0.addingTimeInterval(2.0)))

        XCTAssertEqual(
            detector.consume(transcript: "сколько было встреч в этом месяце?", isFinal: true, now: t0.addingTimeInterval(2.5)),
            .triggered(command: "сколько было встреч в этом месяце?")
        )
        XCTAssertFalse(detector.isArmed(at: t0.addingTimeInterval(2.6)))

        // Expired arm window ignores unaddressed speech
        _ = detector.consume(transcript: "Рок", isFinal: true, now: t0.addingTimeInterval(10))
        XCTAssertEqual(
            detector.consume(transcript: "поговорим о проекте", isFinal: true, now: t0.addingTimeInterval(16)),
            .ignored
        )
    }

    func testVoiceApprovalPolicyMatchesUserRequirements() {
        XCTAssertTrue(AssistantVoiceApprovalPolicy.shouldAutoApprove(actionKind: "join", inputSource: .voiceWake, sendsWithoutAsking: false))
        XCTAssertTrue(AssistantVoiceApprovalPolicy.shouldAutoApprove(actionKind: "mute", inputSource: .voiceWake, sendsWithoutAsking: false))
        XCTAssertTrue(AssistantVoiceApprovalPolicy.shouldAutoApprove(actionKind: "setAttention", inputSource: .voicePushToTalk, sendsWithoutAsking: false))
        XCTAssertTrue(AssistantVoiceApprovalPolicy.shouldAutoApprove(actionKind: "participate", inputSource: .voiceWake, sendsWithoutAsking: false))
        XCTAssertTrue(AssistantVoiceApprovalPolicy.shouldAutoApprove(actionKind: "remind", inputSource: .voiceWake, sendsWithoutAsking: false))
        XCTAssertTrue(AssistantVoiceApprovalPolicy.shouldAutoApprove(actionKind: "remember", inputSource: .voiceWake, sendsWithoutAsking: false))

        XCTAssertFalse(AssistantVoiceApprovalPolicy.shouldAutoApprove(actionKind: "leave", inputSource: .voiceWake, sendsWithoutAsking: true))
        XCTAssertFalse(AssistantVoiceApprovalPolicy.shouldAutoApprove(actionKind: "sendChat", inputSource: .voiceWake, sendsWithoutAsking: false))
        XCTAssertTrue(AssistantVoiceApprovalPolicy.shouldAutoApprove(actionKind: "sendChat", inputSource: .voiceWake, sendsWithoutAsking: true))
        XCTAssertFalse(AssistantVoiceApprovalPolicy.shouldAutoApprove(actionKind: "say", inputSource: .voiceWake, sendsWithoutAsking: false))
        XCTAssertFalse(AssistantVoiceApprovalPolicy.shouldAutoApprove(actionKind: "join", inputSource: .externalMCP, sendsWithoutAsking: true))
        XCTAssertFalse(AssistantVoiceApprovalPolicy.shouldAutoApprove(actionKind: "join", inputSource: .typed, sendsWithoutAsking: false))
    }

    func testVoxPresetFormattingAndVoicePreferenceRoundTrip() {
        let prompt = AssistantVoxVoicePreset.calmAssistant.formattedPrompt(for: "  У вас 4 встречи в этом месяце.  ")
        XCTAssertTrue(prompt.hasPrefix("("))
        XCTAssertTrue(prompt.hasSuffix(")У вас 4 встречи в этом месяце."))

        let suiteName = "assistant.voice.prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AssistantVoicePreferences.loadAuditionVoice(from: defaults), .voxPreset(.calmAssistant))
        AssistantVoicePreferences.saveAuditionVoice(.clonedVoice, to: defaults)
        XCTAssertEqual(AssistantVoicePreferences.loadAuditionVoice(from: defaults), .clonedVoice)
        AssistantVoicePreferences.saveAuditionVoice(.systemVoice(identifier: "com.apple.voice.ru"), to: defaults)
        XCTAssertEqual(AssistantVoicePreferences.loadAuditionVoice(from: defaults), .systemVoice(identifier: "com.apple.voice.ru"))
    }

    func testCurrentMeetingTargetResolverPrioritizesOngoingThenImminentThenRooms() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        var ongoing = CalendarMeeting(
            id: "ev-ongoing", seriesID: "s-1", calendarID: "cal", calendarTitle: "Work",
            title: "Архитектурный синк", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1800)
        )
        ongoing.invitation = URL(string: "https://meet.example.com/j/arch")!
        ongoing.engine = .guest

        var imminent = CalendarMeeting(
            id: "ev-next", seriesID: "s-2", calendarID: "cal", calendarTitle: "Work",
            title: "Следующая", start: now.addingTimeInterval(900), end: now.addingTimeInterval(2700)
        )
        imminent.invitation = URL(string: "https://meet.example.com/j/next")!
        imminent.engine = .guest

        let room = RecentRoom(
            invitationURL: URL(string: "https://meet.example.com/j/daily")!,
            title: "Daily",
            identifier: "daily",
            isStarred: true,
            lastJoined: now.addingTimeInterval(-3600)
        )

        let candidates = CurrentMeetingTargetResolver.rankedCandidates(
            now: now,
            calendarMeetings: [imminent, ongoing],
            handoffs: [],
            rooms: [room]
        )

        XCTAssertEqual(candidates.map(\.title), ["Архитектурный синк", "Следующая", "Daily"])
        XCTAssertEqual(candidates.first?.source, .ongoingCalendar)
        XCTAssertEqual(
            CurrentMeetingTargetResolver.bestCurrentMeeting(from: candidates, now: now)?.id,
            candidates.first?.id
        )
        XCTAssertEqual(
            CurrentMeetingTargetResolver.stableID(namespace: "calendar", key: "ev-ongoing"),
            candidates.first?.id
        )
    }
}
