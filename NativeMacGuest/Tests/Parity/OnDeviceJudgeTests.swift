import ConferenceCore
import Foundation
import FoundationModels
import XCTest
@testable import RockNativeDesktop

/// The "Apple on this Mac" judge: provider wiring, the request it builds, and, where
/// the model and the Russian–English translation pair are installed, one real call.
final class OnDeviceJudgeTests: XCTestCase {
    private func request(_ lines: [(String, String, Bool)], language: String = "ru") -> JudgeRequest {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        let profile = AttentionProfile(name: "Виталий", aliases: ["Витя"], role: "руководитель инфраструктуры, отвечает за DNS")
        let names = profile.names(fallback: profile.name)
        let window = AttentionWindow(meetingTitle: "Инфраструктура", lines: lines.enumerated().map { index, line in
            .init(id: "id\(index)", ref: "L\(index + 1)", source: .speech, speaker: line.0, isYou: line.2, text: line.1,
                  at: start.addingTimeInterval(Double(index) * 5), mentionsYou: AttentionWindowBuilder.mentions(line.1, names))
        }, reactions: [], joined: [], left: [], participantCount: 5, microphoneOn: false, soundOn: false, builtAt: start)
        let preset = MeetingPreset(title: "Инфраструктура", bindings: [], about: "Планёрка, ведёт Анна.", matters: "переключение DNS",
                                   people: ["Анна"], never: "бюджет не мой")
        return JudgeRequest(window: window, preset: preset, profile: profile, yourName: "Виталий", language: language)
    }

    func testAppleProviderNeedsNoAddressModelOrKey() {
        let apple = AttentionProvider.defaults[.apple]!
        XCTAssertFalse(apple.needsKey)
        XCTAssertTrue(apple.onThisMac)
        XCTAssertTrue(apple.configured)
        XCTAssertNil(apple.endpoint)
        XCTAssertTrue(apple.client(key: nil) is AppleOnDeviceJudge)
        XCTAssertTrue(AttentionProvider.defaults[.rapidMLX]!.client(key: nil) is OpenAIChatJudge)
        XCTAssertFalse(AttentionProvider.defaults[.custom]!.configured)
    }

    func testApplePersistsAsItsOwnKind() throws {
        let data = try JSONEncoder().encode(AttentionProvider.defaults[.apple]!)
        XCTAssertEqual(try JSONDecoder().decode(AttentionProvider.self, from: data).kind, .apple)
    }

    func testMeetingLanguageAndTranslationNeed() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26") }
        let russian = request([("Анна", "Виталий, ты подтверждаешь, что DNS готов к переключению?", false),
                               ("Игорь", "сертификаты истекают в пятницу", false)])
        XCTAssertEqual(AppleOnDevice.meetingLanguage(russian.window)?.languageCode?.identifier, "ru")
        let english = request([("Anna", "Vitaly, can you confirm DNS is ready for the switch?", false)])
        XCTAssertEqual(AppleOnDevice.meetingLanguage(english.window)?.languageCode?.identifier, "en")
        XCTAssertFalse(AppleOnDevice.needsTranslation(.init(identifier: "en")))
        // An English meeting goes to the model as is, with the reason asked for in English.
        let (asIs, source) = try awaitResult { try await AppleOnDevice.englishRequest(english) }
        XCTAssertNil(source)
        XCTAssertEqual(asIs.window.lines.map(\.text), english.window.lines.map(\.text))
        XCTAssertEqual(asIs.language, "en")
    }

    func testVerdictSchemaBuildsForWindowRefs() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26") }
        XCTAssertNoThrow(try AppleOnDevice.verdictSchema(refs: ["L1", "L2", "L3"]))
        XCTAssertNoThrow(try AppleOnDevice.verdictSchema(refs: []))
        XCTAssertNoThrow(try AppleOnDevice.replySchema(ReplyChannels(chat: true, reactions: Array(MeetingReaction.allCases.prefix(2)))))
    }

    /// One real call: a Russian request is translated, judged and its reason comes back in Russian.
    func testRussianDirectQueryOnTheRealModel() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26") }
        guard SystemLanguageModel.default.isAvailable else { throw XCTSkip("Apple's on-device model is not available here") }
        let request = request([("Игорь", "так переключение сегодня или переносим", false),
                               ("Анна", "Виталий, ты подтверждаешь, что DNS готов к переключению? Мы ждём тебя.", false)])
        let result: JudgeResult
        do { result = try await AppleOnDeviceJudge().judge(request) }
        catch OnDeviceJudgeError.translationMissing { throw XCTSkip("Russian–English translation is not downloaded") }
        XCTAssertEqual(result.verdict.level, .now)
        XCTAssertTrue(result.verdict.evidence.allSatisfy { id in request.window.lines.contains { $0.id == id } })
        XCTAssertNotNil(result.verdict.reason.range(of: "\\p{Cyrillic}", options: .regularExpression), result.verdict.reason)
        // The second call finds every line in the translation cache.
        let started = Date()
        _ = try await AppleOnDeviceJudge().judge(request)
        print("ONDEVICE first \(result.latency)s, cached \(Date().timeIntervalSince(started))s")
    }

    private func awaitResult<T>(_ body: @escaping () async throws -> T) throws -> T {
        let expectation = expectation(description: "async")
        var value: Result<T, Error>?
        Task { do { value = .success(try await body()) } catch { value = .failure(error) }; expectation.fulfill() }
        wait(for: [expectation], timeout: 10)
        return try value!.get()
    }
}
