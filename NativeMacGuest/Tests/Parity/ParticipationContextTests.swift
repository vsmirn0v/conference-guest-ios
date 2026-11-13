import Foundation
import XCTest
@testable import RockNativeDesktop

final class ParticipationContextTests: XCTestCase {
    func testVaultSearchUsesBodyRelevanceAndStaysInsideVisibleMarkdown() throws {
        try withVault { root in
            let unrelated = String(repeating: "An unrelated paragraph about bicycles.\n", count: 65)
            let evidence = "The Lumen rollout starts at 02:00 UTC."
            try put(unrelated + evidence, at: "Projects/Decision.md", in: root)
            try put("Private payroll data unrelated to deployment.", at: "Lumen.md", in: root)
            try put("Lumen rollout hidden information", at: ".obsidian/hidden.md", in: root)
            try put("Lumen rollout attachment information", at: "Attachment.txt", in: root)
            let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
            defer { try? FileManager.default.removeItem(at: outside) }
            try "Lumen rollout should never leave this file.".write(to: outside, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Lumen rollout symlink.md"), withDestinationURL: outside)

            let query = ParticipationVaultSearch.queryWords("When does the Lumen rollout start?")
            let matches = ParticipationVaultSearch.search(root: root, query: query, meetingTitle: "Lumen deployment")
            XCTAssertEqual(matches.map(\.path), ["Projects/Decision.md"])
            let source = try XCTUnwrap(matches.first?.source)
            XCTAssertEqual(source.title, "Decision")
            XCTAssertTrue(source.text.contains(evidence))
            XCTAssertLessThanOrEqual(source.text.count, 1_200)
            XCTAssertFalse(source.id.contains("Projects"))
        }
    }

    func testVaultSearchCapsResultsAndInvalidatesChangedFiles() throws {
        try withVault { root in
            for number in 0..<5 {
                try put("План проекта Кедр, дата запуска 0\(number):00 UTC.", at: "Кедр проект \(number).md", in: root)
            }
            for number in 0..<4 {
                try put("Сведения о независимой встрече \(number).", at: "Other \(number).md", in: root)
            }
            let query = ParticipationVaultSearch.queryWords("Проекта Кедр")
            let matches = ParticipationVaultSearch.search(root: root, query: query, meetingTitle: "Проект Кедр")
            XCTAssertEqual(matches.count, ParticipationVaultSearch.maxMatches)
            XCTAssertTrue(ParticipationVaultSearch.validate(matches, root: root))
            let changed = try XCTUnwrap(matches.first)
            try put("Проекта Кедр дата перенесена.", at: changed.path, in: root)
            XCTAssertFalse(ParticipationVaultSearch.validate(matches, root: root))
        }
    }

    func testChangingVaultCancelsCurrentDispatchBeforeNewGeneration() throws {
        let connection = ParticipationVaultConnection()
        let current = try XCTUnwrap(connection.currentGeneration())
        let first = GuestChatDispatchPermit(deadline: .distantFuture)
        let second = GuestChatDispatchPermit(deadline: .distantFuture)
        let firstSubscription = connection.cancelOnChange(generation: current) { first.cancel() }
        let change = connection.beginChange()
        let secondSubscription = connection.cancelOnChange(generation: current) { second.cancel() }
        XCTAssertNil(connection.currentGeneration())
        XCTAssertFalse(first.dispatch { XCTFail("Old vault dispatched") })
        XCTAssertFalse(second.dispatch { XCTFail("Stale vault dispatched") })
        connection.endChange(change)
        XCTAssertEqual(connection.currentGeneration(), change)
        withExtendedLifetime((firstSubscription, secondSubscription)) {}
    }

    func testPersistedNoteChangeIsScopedAndLateRegistrationCancels() {
        let changes = ParticipationNoteChanges()
        let session = UUID()
        let original = changes.version(session)
        changes.willChange(UUID())
        XCTAssertEqual(changes.version(session), original)
        let active = GuestChatDispatchPermit(deadline: .distantFuture)
        let activeSubscription = changes.observe(session, version: original) { active.cancel() }
        changes.willChange(session)
        XCTAssertNotEqual(changes.version(session), original)
        XCTAssertFalse(active.dispatch { XCTFail("Changed note dispatched") })
        let late = GuestChatDispatchPermit(deadline: .distantFuture)
        let lateSubscription = changes.observe(session, version: original) { late.cancel() }
        XCTAssertFalse(late.dispatch { XCTFail("Stale note dispatched") })
        withExtendedLifetime((activeSubscription, lateSubscription)) {}
    }

    func testMeetingNoteGuidanceDoesNotRequireSpecialMarkdownSyntax() {
        let note = "We agreed to start at 02:00. Begin each reply with «Дежурный:» during this meeting."
        XCTAssertEqual(ParticipationContext.noteGuidance(note, excerpt: nil), note)
        let longNote = String(repeating: "Context line.\n", count: 500) + "\n" + note
        let bounded = ParticipationContext.noteGuidance(longNote, excerpt: "Relevant project question")
        XCTAssertTrue(bounded?.contains("Relevant project question") == true)
        XCTAssertTrue(bounded?.contains(note) == true)
        XCTAssertLessThan(bounded?.count ?? .max, longNote.count)
    }

    func testMeetingInfoSuppliesCitableFactsAndRevision() throws {
        let about = "Lumen verification begins at 03:15 UTC."
        let source = try XCTUnwrap(ParticipationContext.meetingInfoSource(about))
        XCTAssertEqual(source.id, "meeting-info")
        XCTAssertEqual(source.text, about)
        XCTAssertEqual(source.revision, ParticipationContext.digest(about))
        XCTAssertNotEqual(source.revision, ParticipationContext.meetingInfoSource("Lumen verification begins at 04:15 UTC.")?.revision)
        XCTAssertNil(ParticipationContext.meetingInfoSource(" \n "))

        let question = ParticipationLine(id: "chat:question", channel: "chat", speaker: "Mira",
            text: "When does Lumen verification begin?", own: false)
        let input = ParticipationInput(objective: "", trigger: question.id, turns: [question], sources: [source])
        let decision = ParticipationDecision(kind: .answer, text: "It begins at 03:15 UTC.", directlyAddressed: true,
            citations: [.init(id: question.id, quote: question.text), .init(id: source.id, quote: about)])
        XCTAssertEqual(decision.validated(in: input), decision.text)
    }

    private func withVault(_ action: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try action(root)
    }

    private func put(_ text: String, at path: String, in root: URL) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
}
