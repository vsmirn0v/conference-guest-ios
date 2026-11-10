import ConferenceCore
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class LiveTranscriptPanelTests: XCTestCase {
    func testLiveTextMergesReactionWithoutMarkingItSeen() async throws {
        let (window, previous) = try makeWindow()
        defer { window.isHidden = true; previous?.makeKey() }
        let base = Date()
        let catchUp = CatchUpStore()
        catchUp.observe(messages: [TranscriptSegment(id: "line", speaker: "Ani", text: "Hello everyone", spokenAt: base)],
                        canView: true, enabled: true)
        let chat = ChatStore()
        chat.reactionHistoryAvailable = true
        chat.reactionHistory.beginMeeting()
        chat.reactionHistory.receive(kind: .heart, participantID: "ani", displayName: "Ani",
                                     providerTimestamp: base.addingTimeInterval(1),
                                     receivedAt: base.addingTimeInterval(1))
        let panel = ConversationPanelViewController(catchUp: catchUp, chat: chat, initialMode: .liveText)
        window.rootViewController = panel
        window.makeKeyAndVisible()
        await drainUpdates()

        let text = try transcriptText(in: panel)
        XCTAssertTrue(text.contains("Hello everyone"))
        XCTAssertTrue(text.contains("❤️  Ani"))
        XCTAssertTrue(chat.reactionHistory.hasUnseenReactions, "Live text must not acknowledge reaction history")
    }

    func testReactionRemainsVisibleWhenTranscriptIsUnavailable() async throws {
        let (window, previous) = try makeWindow()
        defer { window.isHidden = true; previous?.makeKey() }
        let base = Date()
        let catchUp = CatchUpStore()
        catchUp.observe(messages: [TranscriptSegment(id: "hidden", speaker: "Ani", text: "Hidden line", spokenAt: base)],
                        canView: false, enabled: false)
        catchUp.transcriptUnavailableReason = "This meeting has no transcript feed."
        let chat = ChatStore()
        chat.reactionHistoryAvailable = true
        chat.reactionHistory.beginMeeting()
        chat.reactionHistory.receive(kind: .like, participantID: "ani", displayName: nil,
                                     providerTimestamp: base.addingTimeInterval(1),
                                     receivedAt: base.addingTimeInterval(1))
        let panel = ConversationPanelViewController(catchUp: catchUp, chat: chat, initialMode: .liveText)
        window.rootViewController = panel
        window.makeKeyAndVisible()
        await drainUpdates()

        let text = try transcriptText(in: panel)
        XCTAssertTrue(text.contains("This meeting has no transcript feed."))
        XCTAssertTrue(text.contains("👍  \(L("Participant"))"))
        XCTAssertFalse(text.contains("Hidden line"), "Transcript lines stay hidden while unavailable")
    }

    func testOwnAndResolvedParticipantNamesUseLiveTextLabels() async throws {
        let (window, previous) = try makeWindow()
        defer { window.isHidden = true; previous?.makeKey() }
        let base = Date()
        let catchUp = CatchUpStore()
        catchUp.observe(messages: [], canView: true, enabled: true)
        let chat = ChatStore()
        chat.reactionHistoryAvailable = true
        chat.reactionHistory.beginMeeting()
        chat.reactionHistory.receive(kind: .like, participantID: "unknown", displayName: nil,
                                     providerTimestamp: base, receivedAt: base)
        chat.reactionHistory.recordLocalSubmission(kind: .heart, participantID: "local", displayName: "Rock QA",
                                                   submissionID: "local-1", at: base.addingTimeInterval(1))
        let panel = ConversationPanelViewController(catchUp: catchUp, chat: chat, initialMode: .liveText)
        window.rootViewController = panel
        window.makeKeyAndVisible()
        await drainUpdates()

        let text = try transcriptText(in: panel)
        XCTAssertTrue(text.contains("👍  \(L("Participant"))"))
        XCTAssertTrue(text.contains("❤️  \(L("You"))"))

        chat.reactionHistory.resolveUnknownParticipant(id: "unknown", name: "Narek")
        await drainUpdates()
        let resolved = try transcriptText(in: panel)
        XCTAssertTrue(resolved.contains("👍  Narek"))
        XCTAssertFalse(resolved.contains("👍  \(L("Participant"))"))
    }

    func testBackgroundReactionFlushesOnActivation() async throws {
        let (window, previous) = try makeWindow()
        defer { window.isHidden = true; previous?.makeKey() }
        let catchUp = CatchUpStore()
        catchUp.observe(messages: [], canView: true, enabled: true)
        let chat = ChatStore()
        chat.reactionHistoryAvailable = true
        chat.reactionHistory.beginMeeting()
        let panel = ConversationPanelViewController(catchUp: catchUp, chat: chat, initialMode: .liveText)
        window.rootViewController = panel
        window.makeKeyAndVisible()
        await drainUpdates()

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        chat.reactionHistory.receive(kind: .wave, participantID: "ani", displayName: "Ani")
        await drainUpdates()
        XCTAssertFalse(try transcriptText(in: panel).contains("👋  Ani"))

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await drainUpdates()
        XCTAssertTrue(try transcriptText(in: panel).contains("👋  Ani"))
    }

    func testReasonOnlyUpdateReplacesStaleStatusText() async throws {
        let (window, previous) = try makeWindow()
        defer { window.isHidden = true; previous?.makeKey() }
        let catchUp = CatchUpStore()
        catchUp.observe(messages: [], canView: false, enabled: false)
        let chat = ChatStore()
        chat.reactionHistoryAvailable = true
        chat.reactionHistory.beginMeeting()
        chat.reactionHistory.receive(kind: .heart, participantID: "ani", displayName: "Ani")
        let panel = ConversationPanelViewController(catchUp: catchUp, chat: chat, initialMode: .liveText)
        window.rootViewController = panel
        window.makeKeyAndVisible()
        await drainUpdates()

        XCTAssertTrue(try transcriptText(in: panel).contains(L("Transcripts aren’t available in this room.")))
        catchUp.transcriptUnavailableReason = "Transcript permission was revoked."
        await drainUpdates()
        let text = try transcriptText(in: panel)
        XCTAssertTrue(text.contains("Transcript permission was revoked."))
        XCTAssertFalse(text.contains(L("Transcripts aren’t available in this room.")))
        XCTAssertTrue(text.contains("❤️  Ani"))
    }

    private func makeWindow() throws -> (UIWindow, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        return (window, previous)
    }

    private func transcript(in panel: ConversationPanelViewController) throws -> UITextView {
        try XCTUnwrap(find(UITextView.self, in: panel.view).first { $0.accessibilityLabel == L("Jam transcript") })
    }

    private func transcriptText(in panel: ConversationPanelViewController) throws -> String {
        try XCTUnwrap(transcript(in: panel).text)
    }

    private func drainUpdates() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    private func find<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { find(type, in: $0) }
    }
}
