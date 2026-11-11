import Foundation
import XCTest
@testable import RockNativeDesktop

final class ParticipationTests: XCTestCase {
    func testDispatchPermitCannotStartAfterCancellationOrExpiry() async {
        let stopped = GuestChatDispatchPermit(deadline: .distantFuture)
        let ready = await stopped.preflight()
        XCTAssertTrue(ready)
        stopped.cancel()
        XCTAssertFalse(stopped.dispatch { XCTFail("Cancelled dispatch started") })
        XCTAssertFalse(stopped.didDispatch)

        let expired = GuestChatDispatchPermit(deadline: .distantPast)
        let readyAfterExpiry = await expired.preflight()
        XCTAssertFalse(readyAfterExpiry)
        XCTAssertFalse(expired.dispatch { XCTFail("Expired dispatch started") })

        let inFlight = GuestChatDispatchPermit(deadline: .distantFuture)
        XCTAssertTrue(inFlight.dispatch {})
        inFlight.cancel()
        XCTAssertTrue(inFlight.didDispatch)
        XCTAssertFalse(inFlight.dispatch { XCTFail("Replayed dispatch started") })
    }

    func testDispatchPermitRejectsStalledSourceValidation() async {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let permit = GuestChatDispatchPermit(deadline: .distantFuture) {
            release.wait()
            return true
        }
        let ready = await permit.preflight()
        XCTAssertFalse(ready)
        XCTAssertTrue(permit.validationFailed)
        XCTAssertFalse(permit.dispatch { XCTFail("Stalled validation authorized dispatch") })
    }

    func testDispatchPermitCannotStartAfterRevocationWhileCheckingSource() async {
        let entered = expectation(description: "Started reading approved source")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let permit = GuestChatDispatchPermit(deadline: .distantFuture) {
            entered.fulfill()
            release.wait()
            return true
        }
        let check = Task { await permit.preflight() }
        await fulfillment(of: [entered], timeout: 2)
        permit.cancel()
        release.signal()
        _ = await check.value
        XCTAssertFalse(permit.dispatch { XCTFail("Revoked source authorized dispatch") })
    }

    func testReceiptReservesOnceAndDistinguishesServerAcceptance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ParticipationReceiptStore(root: root)
        let now = Date()
        var receipt = ParticipationReceipt(id: ParticipationReceipt.hash("chat:event"), sessionID: UUID(),
            grantID: UUID(), payloadHash: ParticipationReceipt.hash("test draft"), evidenceRevisions: [],
            createdAt: now, updatedAt: now, state: .reserved, providerMessageID: UUID().uuidString)
        try store.reserve(receipt)
        XCTAssertThrowsError(try store.reserve(receipt))
        XCTAssertEqual(try store.receipts(for: receipt.sessionID).map(\.state), [.reserved])
        receipt.state = .serverAccepted
        try store.update(receipt)
        XCTAssertEqual(try store.receipts(for: receipt.sessionID).map(\.state), [.serverAccepted])
        receipt.state = .confirmed
        try store.update(receipt)
        XCTAssertEqual(try store.receipts(for: receipt.sessionID).map(\.state), [.confirmed])
        XCTAssertTrue(try store.receipts(for: UUID()).isEmpty)
    }

    func testDecisionRequiresLiteralQuotesAndCurrentHumanTrigger() {
        let input = ParticipationInput(objective: "", trigger: "chat:turn", turns: [
            .init(id: "chat:turn", channel: "chat", speaker: "Mira", text: "Can the assistant recall the deadline?", own: false)
        ], sources: [
            .init(id: "source:deadline", title: "Release schedule", text: "The deadline is Friday.", revision: "current")
        ])
        let trigger = ParticipationDecision.Citation(id: "chat:turn", quote: "recall the deadline?")
        let evidence = ParticipationDecision.Citation(id: "source:deadline", quote: "deadline is Friday")
        let decision = ParticipationDecision(kind: .answer, text: "Friday (Release schedule).",
            directlyAddressed: true, citations: [trigger, evidence])
        XCTAssertEqual(decision.validated(in: input), "Friday (Release schedule).")
        let fabricated = ParticipationDecision(kind: .answer, text: "Monday (Release schedule).", directlyAddressed: true,
            citations: [trigger, .init(id: "source:deadline", quote: "deadline is Monday")])
        XCTAssertNil(fabricated.validated(in: input))
        let missingSource = ParticipationDecision(kind: .answer, text: "Friday.", directlyAddressed: true,
            citations: [trigger, evidence])
        XCTAssertNil(missingSource.validated(in: input))
        let own = ParticipationInput(objective: "", trigger: "chat:turn", turns: [
            .init(id: "chat:turn", channel: "chat", speaker: "Mira", text: "Can the assistant recall the deadline?", own: true)
        ], sources: input.sources)
        XCTAssertNil(decision.validated(in: own))
    }

    func testRetrievalCanFindRelevantExcerptBeyondOpeningSection() {
        let note = String(repeating: "Opening discussion and room logistics.\n", count: 80)
            + "\n## Rollout\nThe rollback window is Friday at noon."
        let excerpt = ParticipationSourceBinding.relevantExcerpt(in: note, matching: "Rollback window")
        XCTAssertTrue(excerpt?.contains("The rollback window is Friday at noon.") == true)
        XCTAssertLessThanOrEqual(excerpt?.count ?? .max, 1_200)
        XCTAssertNil(ParticipationSourceBinding.relevantExcerpt(in: note, matching: "telemetry"))
    }

    func testRetrievalKeepsEvidenceAcrossWindowBoundary() {
        let evidence = "The rollback window is Friday, only if validation passes."
        let note = String(repeating: "room agenda ", count: 99) + "abcde " + evidence
        let excerpt = ParticipationSourceBinding.relevantExcerpt(in: note, matching: "rollback validation")
        XCTAssertTrue(excerpt?.contains(evidence) == true)
        XCTAssertLessThanOrEqual(excerpt?.count ?? .max, 1_200)
    }
}
