import Foundation
import XCTest
@testable import RockNativeDesktop

final class ParticipationSourceBindingTests: XCTestCase {
    private func context(audience: ParticipationKnowledgeAudience, processor: String = "apple-system-on-device",
                         expiresAt: Date) -> ParticipationKnowledgeReviewContext {
        .init(audience: audience, meetingTitle: "Release planning", processorID: processor,
              processorLabel: "On-device model", processingDescription: "Approved excerpts are processed on this Mac.",
              expiresAt: expiresAt)
    }

    private func withNote(_ run: (URL, ParticipationKnowledgeFolder, ParticipationKnowledgeReviewContext) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Schedule.md")
        try "Rollout starts Friday.".write(to: file, atomically: true, encoding: .utf8)
        let folder = try ParticipationKnowledgeFolder(selectedURL: root)
        let audience = ParticipationKnowledgeAudience(sessionID: UUID(), roomIdentity: "release", rosterEpoch: 7)
        try await run(file, folder, context(audience: audience, expiresAt: Date().addingTimeInterval(600)))
    }

    func testBindingAcceptsOnlyApprovalsForTheReviewedRoomRosterProcessorAndDeadline() async throws {
        try await withNote { _, folder, review in
            let snapshot = try folder.inspect(relativePath: "Schedule.md")
            let approval = try folder.approve(reviewed: snapshot, context: review)
            let binding = try XCTUnwrap(ParticipationSourceBinding(context: review, approvals: [approval]))
            let approvedSource = try XCTUnwrap(binding.read().first)
            XCTAssertEqual(approvedSource.id, "source:" + approval.id.uuidString)
            XCTAssertEqual(approvedSource.text, "Rollout starts Friday.")
            XCTAssertEqual(binding.revisions, [snapshot.revision])

            let audience = review.audience
            let otherRoom = ParticipationKnowledgeAudience(sessionID: audience.sessionID, roomIdentity: "another-room",
                                                            rosterEpoch: audience.rosterEpoch)
            let otherRoster = ParticipationKnowledgeAudience(sessionID: audience.sessionID, roomIdentity: audience.roomIdentity,
                                                              rosterEpoch: audience.rosterEpoch + 1)
            let changedScopes = [
                context(audience: otherRoom, expiresAt: review.expiresAt),
                context(audience: otherRoster, expiresAt: review.expiresAt),
                context(audience: audience, processor: "remote", expiresAt: review.expiresAt),
                context(audience: audience, expiresAt: review.expiresAt.addingTimeInterval(60)),
            ]
            for changed in changedScopes {
                XCTAssertNil(ParticipationSourceBinding(context: changed, approvals: [approval]))
            }
            XCTAssertNil(ParticipationSourceBinding(context: nil, approvals: [approval]))
        }
    }

    func testChangedNoteCannotPassTheDispatchPermitPreflight() async throws {
        try await withNote { file, folder, review in
            let snapshot = try folder.inspect(relativePath: "Schedule.md")
            let approval = try folder.approve(reviewed: snapshot, context: review)
            let binding = try XCTUnwrap(ParticipationSourceBinding(context: review, approvals: [approval]))
            XCTAssertEqual(try binding.read().first?.text, "Rollout starts Friday.")
            let permit = GuestChatDispatchPermit(deadline: review.expiresAt) { (try? binding.read()) != nil }

            try "Rollout starts Monday.".write(to: file, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try binding.read()) { error in
                XCTAssertEqual(error as? ParticipationKnowledgeError, .sourceChanged)
            }
            let accepted = await permit.preflight()
            XCTAssertFalse(accepted)
            XCTAssertTrue(permit.validationFailed)
            XCTAssertFalse(permit.dispatch { XCTFail("A changed note reached the WebSocket send") })
        }
    }

    func testNewApprovalDoesNotReviveRevokedBindingCapturedByAnOldPermit() async throws {
        try await withNote { _, folder, review in
            let snapshot = try folder.inspect(relativePath: "Schedule.md")
            let original = try folder.approve(reviewed: snapshot, context: review)
            let originalBinding = try XCTUnwrap(ParticipationSourceBinding(context: review, approvals: [original]))
            let captured = originalBinding
            let oldPermit = GuestChatDispatchPermit(deadline: review.expiresAt) { (try? captured.read()) != nil }

            originalBinding.revokeAll()
            let reapproval = try folder.approve(reviewed: snapshot, context: review)
            let newBinding = try XCTUnwrap(ParticipationSourceBinding(context: review, approvals: [reapproval]))
            XCTAssertNotEqual(reapproval.id, original.id)
            XCTAssertEqual(try newBinding.read().first?.text, snapshot.markdown)
            XCTAssertThrowsError(try captured.read()) { error in
                XCTAssertEqual(error as? ParticipationKnowledgeError, .revoked)
            }
            let accepted = await oldPermit.preflight()
            XCTAssertFalse(accepted)
            XCTAssertFalse(oldPermit.dispatch { XCTFail("A revoked approval was reused after reapproval") })
        }
    }
}
