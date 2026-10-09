import ConferenceCore
import Foundation
import XCTest
@testable import RockNRoll

final class GuestReactionTransportTests: XCTestCase {
    func testAllTwelveVerifiedCodesAndLegacyValuesDecode() throws {
        XCTAssertEqual(GuestReactionCode.allCases.count, 12)
        XCTAssertEqual(Set(GuestReactionCode.allCases.map(\.kind)), Set(MeetingReaction.allCases))
        for code in GuestReactionCode.allCases {
            let event = try XCTUnwrap(GuestReactionWireEvent.decode(data(event: "reaction", reaction: code.rawValue)))
            guard case .reaction(let room, let group, let reaction) = event else { return XCTFail("Wrong event") }
            XCTAssertEqual(room, "room"); XCTAssertEqual(group, "group")
            XCTAssertEqual(reaction.kind, code.kind); XCTAssertEqual(reaction.participantID, "remote")
            XCTAssertEqual(GuestReactionCode.sent(code.kind), code)
        }
        XCTAssertEqual(GuestReactionCode.received("CLAP"), .applause)
        XCTAssertEqual(GuestReactionCode.received("JOY"), .smile)
        XCTAssertEqual(GuestReactionCode.received("OPEN_MOUTH"), .surprise)
        XCTAssertNil(GuestReactionCode.received("UNKNOWN"))
    }

    func testOnlyFormalEnvelopeAcceptsReactionAndMalformedValuesDrop() {
        for code in ["like", "👍", "unknown", ""] {
            XCTAssertNil(GuestReactionWireEvent.decode(data(event: "reaction", reaction: code)))
        }
        XCTAssertNil(GuestReactionWireEvent.decode(data(event: "chat-message", reaction: "THUMBS_UP")))
        XCTAssertNil(GuestReactionWireEvent.decode(Data("{\"message\":{\"event\":\"reaction\",\"reaction\":\"THUMBS_UP\"}}".utf8)))
        XCTAssertNil(GuestReactionWireEvent.decode(Data("{\"event\":\"reaction\",\"roomId\":\"room\",\"groupId\":\"group\",\"payload\":{\"participantId\":7,\"reaction\":\"THUMBS_UP\"}}".utf8)))
        XCTAssertNil(GuestReactionWireEvent.decode(Data(repeating: 0x20, count: 65_537)))
    }

    func testJoinResponseRequiresValidProtocolIdentityFields() throws {
        let json = Data("""
        {"event":"join-response","roomId":"room","requestId":"request","payload":{
          "roomId":"room","participant":{"participantId":"local","sessionId":"session"},
          "participantGroup":{"groupId":"group"}}}
        """.utf8)
        guard case .joined(let room, let context) = try XCTUnwrap(GuestReactionWireEvent.decode(json)) else {
            return XCTFail("Expected a typed join response")
        }
        XCTAssertEqual(room, "room"); XCTAssertEqual(context.requestID, "request")
        XCTAssertEqual(context.participantID, "local"); XCTAssertEqual(context.sessionID, "session")
        XCTAssertEqual(context.groupID, "group")
        let mismatched = String(decoding: json, as: UTF8.self).replacingOccurrences(of: "\"roomId\":\"room\",\"participant\"", with: "\"roomId\":\"other\",\"participant\"")
        XCTAssertNil(GuestReactionWireEvent.decode(Data(mismatched.utf8)))
        let missingSession = String(decoding: json, as: UTF8.self).replacingOccurrences(of: "\"sessionId\":\"session\"", with: "\"sessionId\":\"\"")
        XCTAssertNil(GuestReactionWireEvent.decode(Data(missingSession.utf8)))
    }

    func testMatchingJoinResponseAndPublicLocalIdentityAreRequired() {
        var scope = GuestReactionScope(roomID: "room")
        let task = UUID(), other = UUID()
        scope.confirmLocalParticipant("local")
        XCTAssertNil(scope.accept(received(), task: task, outgoing: false))
        _ = scope.accept(.join(room: "other", request: "join"), task: other, outgoing: true)
        XCTAssertFalse(scope.hasModernProtocol)
        _ = scope.accept(.join(room: "room", request: "join"), task: task, outgoing: false)
        XCTAssertFalse(scope.hasModernProtocol)
        _ = scope.accept(.join(room: "room", request: "join"), task: task, outgoing: true)
        XCTAssertTrue(scope.hasModernProtocol); XCTAssertFalse(scope.ready)
        _ = scope.accept(joined(request: "wrong"), task: task, outgoing: false)
        XCTAssertFalse(scope.ready)
        _ = scope.accept(joined(), task: other, outgoing: false)
        XCTAssertFalse(scope.ready)
        _ = scope.accept(joined(participant: "another"), task: task, outgoing: false)
        XCTAssertFalse(scope.ready)
        _ = scope.accept(joined(), task: task, outgoing: false)
        XCTAssertTrue(scope.ready)
        XCTAssertEqual(scope.accept(received(), task: task, outgoing: false)?.kind, .heart)
        XCTAssertNil(scope.accept(received(room: "other"), task: task, outgoing: false))
        XCTAssertNil(scope.accept(received(group: "other"), task: task, outgoing: false))
        XCTAssertNil(scope.accept(received(), task: task, outgoing: true))
    }

    func testReconnectRetiresOldTaskAndLeaveCannotBeRearmed() {
        var scope = GuestReactionScope(roomID: "room")
        let first = UUID(), second = UUID()
        scope.confirmLocalParticipant("local")
        _ = scope.accept(.join(room: "room", request: "join"), task: first, outgoing: true)
        _ = scope.accept(joined(), task: first, outgoing: false)
        XCTAssertNotNil(scope.accept(received(), task: first, outgoing: false))
        _ = scope.accept(.join(room: "room", request: "next"), task: second, outgoing: true)
        XCTAssertFalse(scope.ready)
        XCTAssertNil(scope.accept(received(), task: first, outgoing: false))
        _ = scope.accept(.join(room: "room", request: "stale"), task: first, outgoing: true)
        XCTAssertEqual(scope.taskID, second)
        _ = scope.accept(joined(request: "next"), task: second, outgoing: false)
        XCTAssertNotNil(scope.accept(received(), task: second, outgoing: false))
        scope.stop()
        _ = scope.accept(.join(room: "room", request: "join"), task: UUID(), outgoing: true)
        XCTAssertFalse(scope.hasModernProtocol); XCTAssertFalse(scope.ready)
        XCTAssertNil(scope.accept(received(), task: second, outgoing: false))
    }

    func testSameTaskRejoinAndSendFailureRevokeReadiness() {
        var scope = GuestReactionScope(roomID: "room")
        let task = UUID()
        scope.confirmLocalParticipant("local")
        _ = scope.accept(.join(room: "room", request: "join"), task: task, outgoing: true)
        _ = scope.accept(joined(), task: task, outgoing: false)
        XCTAssertTrue(scope.ready)
        _ = scope.accept(.join(room: "room", request: "retry"), task: task, outgoing: true)
        XCTAssertFalse(scope.ready)
        _ = scope.accept(joined(), task: task, outgoing: false)
        XCTAssertFalse(scope.ready)
        _ = scope.accept(joined(request: "retry"), task: task, outgoing: false)
        XCTAssertTrue(scope.ready)
        scope.retire(task)
        XCTAssertFalse(scope.ready)
        XCTAssertNil(scope.accept(received(), task: task, outgoing: false))
    }

    func testBackgroundDropsQueuedEventsWithoutReplayOnForeground() {
        let window = GuestReactionDeliveryWindow()
        let before = window.token
        XCTAssertTrue(window.accepts(before))
        window.setVisible(false)
        XCTAssertFalse(window.accepts(before)); XCTAssertNil(window.token)
        window.setVisible(true)
        XCTAssertFalse(window.accepts(before)); XCTAssertTrue(window.accepts(window.token))
        window.setVisible(false)
        XCTAssertFalse(window.accepts(nil))
    }

    private func data(event: String, reaction: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["event": event, "roomId": "room", "groupId": "group",
            "payload": ["participantId": "remote", "reaction": reaction]])
    }
    private func joined(request: String = "join", participant: String = "local") -> GuestReactionWireEvent {
        .joined(room: "room", .init(requestID: request, participantID: participant, sessionID: "session", groupID: "group"))
    }
    private func received(room: String = "room", group: String = "group") -> GuestReactionWireEvent {
        .reaction(room: room, group: group, GuestReceivedReaction(kind: .heart, participantID: "remote"))
    }
}
