import XCTest
@testable import RockNRoll

final class GuestPublishingCodecTests: XCTestCase {
    private let socket = UUID(), generation = UUID()
    private func data(_ json: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: json) }
    private func join(_ policy: GuestPublishingCodecPolicy, socket: UUID? = nil) throws {
        _ = policy.outgoing(socket: socket ?? self.socket, data: try data([
            "event": "join", "roomId": "room-uuid", "payload": ["jazzToken": "", "participantName": "Test"]]))
    }
    private func capabilities(_ policy: GuestPublishingCodecPolicy, socket: UUID? = nil, room: String = "room-uuid", mime: String = "video/H264") throws {
        policy.incoming(socket: socket ?? self.socket, data: try data([
            "event": "media-out", "roomId": room, "payload": ["join": ["room": [
                "name": room, "enabledCodecs": [["mime": mime, "fmtpLine": ""]]]]]]))
    }
    private func publish(type: String = "VIDEO", room: String = "room-uuid") throws -> Data {
        try data(["event": "media-in", "roomId": room, "requestId": "preserve", "payload": [
            "method": "ADD_TRACK", "addTrackRequest": ["type": type, "cid": "track", "source": "SCREEN_SHARE",
                "layers": [["width": 1280, "height": 720]], "simulcastCodecs": [["codec": "VP8", "cid": "track"]]]]])
    }
    func testRequiresHardwareAndExplicitCapabilitiesFromJoinedSocket() throws {
        for hardware in [true, false] {
            let policy = GuestPublishingCodecPolicy(hardwareH264: hardware)
            policy.begin(generation: generation, roomID: "room-uuid")
            XCTAssertNil(policy.outgoing(socket: socket, data: try publish()))
            try capabilities(policy); XCTAssertNil(policy.outgoing(socket: socket, data: try publish()))
            try join(policy); try capabilities(policy, room: "wrong-room")
            XCTAssertNil(policy.outgoing(socket: socket, data: try publish()))
            try capabilities(policy)
            XCTAssertEqual(policy.outgoing(socket: socket, data: try publish()) != nil, hardware)
            XCTAssertNil(policy.outgoing(socket: UUID(), data: try publish()))
            XCTAssertNil(policy.outgoing(socket: socket, data: try publish(room: "wrong-room")))
        }
    }
    func testPreservesAudioAndAllUnrelatedPublishingFields() throws {
        let policy = GuestPublishingCodecPolicy(hardwareH264: true)
        policy.begin(generation: generation, roomID: "room-uuid"); try join(policy); try capabilities(policy)
        XCTAssertNil(policy.outgoing(socket: socket, data: try publish(type: "AUDIO")))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: publish()) as? [String: Any])
        var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(policy.outgoing(socket: socket, data: publish()))) as? [String: Any])
        var payload = try XCTUnwrap(changed["payload"] as? [String: Any])
        var request = try XCTUnwrap(payload["addTrackRequest"] as? [String: Any])
        XCTAssertEqual((request["simulcastCodecs"] as? [[String: String]])?.first?["codec"], "h264")
        request["simulcastCodecs"] = [["codec": "VP8", "cid": "track"]]
        payload["addTrackRequest"] = request; changed["payload"] = payload
        XCTAssertEqual(changed as NSDictionary, original as NSDictionary)
        XCTAssertNil(policy.outgoing(socket: socket, data: Data("bad JSON".utf8)))
    }
    func testFallbackIsStickyForOneCallAndLateMessagesCannotAffectReplacement() throws {
        let policy = GuestPublishingCodecPolicy(hardwareH264: true)
        policy.begin(generation: generation, roomID: "room-uuid"); try join(policy); try capabilities(policy)
        XCTAssertNotNil(policy.outgoing(socket: socket, data: try publish()))
        policy.disable(generation: UUID()); XCTAssertNotNil(policy.outgoing(socket: socket, data: try publish()))
        policy.disable(generation: generation); XCTAssertNil(policy.outgoing(socket: socket, data: try publish()))
        let replacement = UUID(), nextSocket = UUID()
        policy.begin(generation: replacement, roomID: "room-uuid")
        try join(policy); try capabilities(policy)
        XCTAssertNil(policy.outgoing(socket: socket, data: try publish()))
        try join(policy, socket: nextSocket); try capabilities(policy, socket: nextSocket)
        policy.end(generation: generation)
        XCTAssertNotNil(policy.outgoing(socket: nextSocket, data: try publish()))
        policy.end(generation: replacement)
        XCTAssertNil(policy.outgoing(socket: nextSocket, data: try publish()))
    }
    func testNoHardwareOrUnsupportedServerRetainsWorkingSDKDefault() throws {
        let policy = GuestPublishingCodecPolicy(hardwareH264: true)
        policy.begin(generation: generation, roomID: "room-uuid"); try join(policy)
        for mime in ["video/VP8", "video/VP9", "video/H265"] {
            try capabilities(policy, mime: mime)
            XCTAssertNil(policy.outgoing(socket: socket, data: try publish()))
        }
    }
    func testDoesNotOverwriteNewerFormatsOrMalformedRequests() throws {
        let policy = GuestPublishingCodecPolicy(hardwareH264: true)
        policy.begin(generation: generation, roomID: "room-uuid"); try join(policy); try capabilities(policy)
        for codecs in [[["codec": "vp9", "cid": "track"]], [["codec": "h265", "cid": "track"]],
                       [["codec": "h264", "cid": "track"]], [["cid": "track"]],
                       [["codec": "vp8", "cid": "other-track"]]] {
            let request: [String: Any] = ["event": "media-in", "roomId": "room-uuid", "payload": [
                "addTrackRequest": ["type": "VIDEO", "cid": "track", "simulcastCodecs": codecs]]]
            XCTAssertNil(policy.outgoing(socket: socket, data: try data(request)))
        }
    }
}
