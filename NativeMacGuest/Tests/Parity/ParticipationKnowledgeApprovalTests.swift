import Foundation
import XCTest
@testable import RockNativeDesktop

final class ParticipationKnowledgeApprovalTests: XCTestCase {
    private func context(audience: ParticipationKnowledgeAudience, processorID: String = "approved-model",
                         description: String = "Selected excerpts are sent to the configured provider.") -> ParticipationKnowledgeReviewContext {
        .init(audience: audience, meetingTitle: "Release planning", processorID: processorID, processorLabel: "Approved Model",
              processingDescription: description, expiresAt: Date(timeIntervalSince1970: 200))
    }

    func testAnOpenReviewCannotApproveAfterRosterOrProcessorChange() {
        let session = UUID()
        let audience = ParticipationKnowledgeAudience(sessionID: session, roomIdentity: "release", rosterEpoch: 7)
        let newAudience = ParticipationKnowledgeAudience(sessionID: session, roomIdentity: "release", rosterEpoch: 8)
        let review = context(audience: audience)
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(review.matches(review, now: now))
        XCTAssertFalse(review.matches(nil, now: now))
        XCTAssertFalse(review.matches(context(audience: newAudience), now: now))
        XCTAssertFalse(review.matches(context(audience: audience, processorID: "other-model"), now: now))
        XCTAssertFalse(review.matches(review, now: review.expiresAt))
        let undisclosedProcessing = context(audience: audience, description: "")
        XCTAssertFalse(undisclosedProcessing.matches(undisclosedProcessing, now: now))
    }

    func testOnlyPathComponentsUnderChosenFolderCanBePreviewed() throws {
        let root = URL(fileURLWithPath: "/example/Notes", isDirectory: true)
        let note = root.appendingPathComponent("Release/Réunion.md")
        XCTAssertEqual(try ParticipationKnowledgeFolder.relativePath(selectedURL: note, root: root), "Release/Réunion.md")
        let sibling = URL(fileURLWithPath: "/example/Notes-old/Release/Réunion.md")
        XCTAssertThrowsError(try ParticipationKnowledgeFolder.relativePath(selectedURL: sibling, root: root))
        XCTAssertThrowsError(try ParticipationKnowledgeFolder.relativePath(selectedURL: root, root: root))
    }

    func testFolderBookmarkDoesNotAuthorizeAChangedOrUnregisteredNote() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Decision.md")
        try "Roll out to 10%.".write(to: file, atomically: true, encoding: .utf8)
        let folder = try ParticipationKnowledgeFolder(selectedURL: root)
        let preview = try folder.inspect(relativePath: "Decision.md")
        let audience = ParticipationKnowledgeAudience(sessionID: UUID(), roomIdentity: "release", rosterEpoch: 7)
        let review = ParticipationKnowledgeReviewContext(audience: audience, meetingTitle: "Release planning", processorID: "local",
            processorLabel: "On-device model", processingDescription: "Approved notes are processed on this Mac.",
            expiresAt: Date().addingTimeInterval(600))
        let approval = try folder.approve(reviewed: preview, context: review)
        let scope = ParticipationKnowledgeScope()

        XCTAssertThrowsError(try approval.read(scope: scope, audience: audience, processor: "local")) {
            XCTAssertEqual($0 as? ParticipationKnowledgeError, .revoked)
        }
        scope.approve(approval.grant)
        XCTAssertEqual(try approval.read(scope: scope, audience: audience, processor: "local"), preview)

        try "Roll out to 90%.".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try folder.approve(reviewed: preview, context: review)) {
            XCTAssertEqual($0 as? ParticipationKnowledgeError, .sourceChanged)
        }
        XCTAssertThrowsError(try approval.read(scope: scope, audience: audience, processor: "local")) {
            XCTAssertEqual($0 as? ParticipationKnowledgeError, .sourceChanged)
        }
    }
}
