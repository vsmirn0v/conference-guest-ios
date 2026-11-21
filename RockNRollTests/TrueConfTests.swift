import ConferenceCore
import CryptoKit
import LiveKitWebRTC
import XCTest
@testable import MeetingEngine
@testable import RockNRoll

@MainActor
final class TrueConfTests: XCTestCase {
    func testH264FactoryPreservesDefaultsAndMatchesBaselineServer() {
        let decoder = NativeH264DecoderFactory()
        let original = LKRTCDefaultVideoDecoderFactory().supportedCodecs()
        XCTAssertEqual(decoder.supportedCodecs().count, original.count + 1)
        for codec in original { XCTAssertTrue(decoder.supportedCodecs().contains { $0.name == codec.name && $0.parameters == codec.parameters }) }
        XCTAssertNotNil(decoder.createDecoder(NativeH264Codec.baseline))
        let once = NativeH264Codec.supported(addingTo: original)
        XCTAssertEqual(NativeH264Codec.supported(addingTo: once).count, once.count)
        XCTAssertFalse(NativeH264Codec.isBaseline(.init(name: "VP8")))
        #if targetEnvironment(simulator)
        XCTAssertFalse(NativeH264Codec.hardwareDecodingAvailable)
        #endif
    }
    func testBootstrapRejectsWrongOriginRoomAndDuplicateCredentials() throws {
        let target = try TrueConfTarget.parse("https://server.test/c/test")
        func data(_ url: String) throws -> Data { try JSONSerialization.data(withJSONObject: ["clients": [["type": "web", "platform": "webrtc", "web_url": url]]]) }
        let value = try TrueConfBootstrap.decode(data("https://server.test/webrtc/test#login=guest%20name&token=temporary"), target: target)
        XCTAssertEqual(value.login, "guest name"); XCTAssertEqual(value.socketURL.absoluteString, "wss://server.test/websocket/")
        let mixed = try JSONSerialization.data(withJSONObject: ["clients": [
            ["type": "standalone", "platform": "ios"],
            ["type": "web", "platform": "webrtc", "web_url": "https://server.test/webrtc-widget/test#login=widget&token=t"],
            ["type": "web", "platform": "webrtc", "web_url": "https://server.test/webrtc/test#login=correct&token=t"]]])
        XCTAssertEqual(try TrueConfBootstrap.decode(mixed, target: target).login, "correct")
        for url in ["https://evil.test/webrtc/test#login=g&token=t", "https://server.test:8443/webrtc/test#login=g&token=t",
                    "http://server.test/webrtc/test#login=g&token=t", "https://server.test/webrtc/other#login=g&token=t",
                    "https://server.test/webrtc/test#login=g&token=t&token=x"] {
            XCTAssertThrowsError(try TrueConfBootstrap.decode(data(url), target: target))
        }
        for error in [TrueConfError.ended, .rejected, .unavailable, .invalidResponse] { XCTAssertFalse(error.isRetryable) }
    }
    func testSessionBoundTURNDecryptionRejectsTamperingAndOtherSessions() throws {
        let cid = "session-cid-123456789", stream = "conference-stream"
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(cid.utf8)), salt: Data(stream.utf8),
            info: Data("app=bridge;module=conference;dir=s2c;".utf8), outputByteCount: 32)
        let box = try AES.GCM.seal(Data("test-password".utf8), using: key, nonce: AES.GCM.Nonce(data: Data(cid.utf8).prefix(12)))
        let hex = (box.ciphertext + box.tag).map { String(format: "%02x", $0) }.joined()
        let server: [String: Any] = ["address": "turn.example.test", "port": 443, "transport": 1, "serviceType": 1, "userName": "test", "credential": hex]
        let decoded = try TrueConfICE.decode([server], cid: cid, stream: stream)
        XCTAssertEqual(decoded.first?["credential"] as? String, "test-password")
        XCTAssertEqual(decoded.first?["urls"] as? [String], ["turn:turn.example.test:443?transport=tcp"])
        XCTAssertThrowsError(try TrueConfICE.decode([server], cid: "another-session-id", stream: stream))
        XCTAssertThrowsError(try TrueConfICE.decode([server], cid: cid, stream: "different-room"))
        var bad = server; bad["credential"] = String(repeating: "00", count: hex.count / 2)
        XCTAssertThrowsError(try TrueConfICE.decode([bad], cid: cid, stream: stream))
    }
    func testRosterIncrementalRemovalAndPresentationState() throws {
        var roster = TrueConfRoster()
        func row(_ id: String, type: Int = 0, status: Int = 0) -> [String: Any] { ["trueconfId": id, "displayname": id, "videoType": type, "DeviceStatus": status] }
        try roster.apply(["type": 1, "list": [row("first"), row("second", status: 262148)]])
        try roster.apply(["type": 2, "list": [row("third", type: 2)]])
        XCTAssertEqual(roster.participants.count, 3); XCTAssertEqual(roster.participants["third"]?.screenShareOn, true)
        XCTAssertEqual(roster.participants["third"]?.cameraOn, false)
        XCTAssertEqual(roster.participants["second"]?.microphoneOn, false)
        try roster.apply(["type": 3, "list": [row("first")]])
        XCTAssertNil(roster.participants["first"]); XCTAssertEqual(roster.participants.count, 2)
        try roster.apply(["type": 4, "list": [row("second")]])
        XCTAssertEqual(roster.participants.count, 1)
    }
    func testLayoutUsesCornersAndRejectsInvalidRegions() throws {
        let body: [String: Any] = ["width": 1920, "height": 1080, "list": [["id": "right", "rect": [960, 540, 1920, 1080]]]]
        let regions = try TrueConfRoster.regions(body)
        XCTAssertEqual(regions["right"], CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        for rect in [[-1, 0, 960, 540], [960, 0, 500, 540], [0, 0, 2000, 1080]] {
            XCTAssertThrowsError(try TrueConfRoster.regions(["width": 1920, "height": 1080, "list": [["id": "x", "rect": rect]]]))
        }
    }
    func testCompositeCropPreservesTheSelectedPixels() throws {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pixels), kCVReturnSuccess)
        let source = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(source, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(source, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(source, 0)
        for row in 0..<8 { for column in 0..<8 { y[row * stride + column] = UInt8(row * 8 + column + 16) } }
        memset(CVPixelBufferGetBaseAddressOfPlane(source, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(source, 1) * 4)
        CVPixelBufferUnlockBaseAddress(source, [])
        let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: source), rotation: ._0, timeStampNs: 1)
        let output = try XCTUnwrap(NativeVideoPixelBuffer().convert(frame, region: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)))
        XCTAssertEqual(CVPixelBufferGetWidth(output), 4); XCTAssertEqual(CVPixelBufferGetHeight(output), 4)
        CVPixelBufferLockBaseAddress(output, .readOnly); defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        XCTAssertEqual(CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt8.self).pointee, 52)
        XCTAssertNil(NativeVideoPixelBuffer().convert(frame, region: CGRect(x: 1, y: 0, width: 1, height: 1)))
    }
    func testRegionsSkipsZeroAreaHiddenSlotAndUpdatesVideoSource() throws {
        var roster = TrueConfRoster()
        try roster.apply(["type": 1, "list": [["trueconfId": "alice", "displayname": "Alice", "videoType": 0, "DeviceStatus": 0]]])
        XCTAssertEqual(roster.participants["alice"]?.cameraOn, true)
        roster.updateVideoSource(["UserName": "alice", "Type": 2])
        XCTAssertEqual(roster.participants["alice"]?.screenShareOn, true)
        XCTAssertEqual(roster.participants["alice"]?.cameraOn, false)

        let regions = try TrueConfRoster.regions([
            "width": 1920,
            "height": 1080,
            "list": [
                ["id": "hidden", "rect": [0, 0, 0, 0]],
                ["id": "alice", "rect": [0, 0, 1920, 1080]]
            ]
        ])
        XCTAssertNil(regions["hidden"])
        XCTAssertEqual(regions["alice"], CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    func testAdapterReceivesScreenShareAcrossLayoutModesAndDedicatedTrack() async throws {
        let factory = LKRTCPeerConnectionFactory()
        let primaryTrack = factory.videoTrack(with: factory.videoSource(), trackId: "tc-primary")
        let contentTrack = factory.videoTrack(with: factory.videoSource(), trackId: "tc-content")

        let adapter = TrueConfAdapter()
        adapter.snapshot.phase = .connected
        adapter.localID = "self"
        adapter.transport = TrueConfTransport(server: URL(string: "wss://example.invalid")!, session: URLSession(configuration: .ephemeral))
        let attempt = adapter.supervisor.generation
        adapter.tracks["0"] = primaryTrack

        // 1. Sole screen sharer with empty layout falls back to full-frame primary track.
        try await adapter.receiveTrueConf(["method": "SendPartsList", "type": 1, "list": [
            ["trueconfId": "alice", "displayname": "Alice", "DeviceStatus": 0, "videoType": 2]
        ]], attempt: attempt)
        XCTAssertEqual(adapter.incomingVideo.map(\.id), ["alice.screen"])
        XCTAssertEqual(adapter.incomingVideo.first?.source, .screen)
        XCTAssertNil(adapter.incomingVideo.first?.crop)
        XCTAssertTrue(adapter.incomingVideo.first?.track.isEqual(primaryTrack) == true)

        // 2. Screen sharer with camera-muted DeviceStatus (4 << 16) still emits screen when layout has their region.
        try await adapter.receiveTrueConf(["method": "SendPartsList", "type": 4, "list": [
            ["trueconfId": "alice", "displayname": "Alice", "DeviceStatus": 262148, "videoType": 2]
        ]], attempt: attempt)
        try await adapter.receiveTrueConf(["method": "webrtc", "type": "layout", "width": 1920, "height": 1080, "list": [
            ["id": "alice", "rect": [0, 0, 1920, 1080]]
        ]], attempt: attempt)
        XCTAssertEqual(adapter.snapshot.participants.first { $0.id == "alice" }?.sharing, true)
        XCTAssertEqual(adapter.incomingVideo.map(\.id), ["alice.screen"])
        XCTAssertEqual(adapter.incomingVideo.first?.crop, CGRect(x: 0, y: 0, width: 1, height: 1))

        // 3. Layout with both camera region and #content region emits both camera and screen.
        try await adapter.receiveTrueConf(["method": "webrtc", "type": "layout", "width": 1920, "height": 1080, "list": [
            ["id": "alice", "rect": [0, 0, 960, 1080]],
            ["id": "alice#content", "rect": [960, 0, 1920, 1080]]
        ]], attempt: attempt)
        XCTAssertEqual(adapter.incomingVideo.map(\.id), ["alice.camera", "alice.screen"])
        XCTAssertEqual(adapter.incomingVideo.first { $0.source == .camera }?.crop, CGRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(adapter.incomingVideo.first { $0.source == .screen }?.crop, CGRect(x: 0.5, y: 0, width: 0.5, height: 1))

        // 4. Dedicated second video track for screen share without #content layout crop.
        adapter.tracks["1"] = contentTrack
        try await adapter.receiveTrueConf(["method": "webrtc", "type": "layout", "width": 1920, "height": 1080, "list": [
            ["id": "alice", "rect": [0, 0, 1920, 1080]]
        ]], attempt: attempt)
        let screen = try XCTUnwrap(adapter.incomingVideo.first { $0.source == .screen })
        XCTAssertTrue(screen.track.isEqual(contentTrack))
        XCTAssertNil(screen.crop)

        // 5. VideoSourceType switches back to camera when DeviceStatus clears video mute.
        try await adapter.receiveTrueConf(["method": "DeviceStatus", "UserName": "alice", "DeviceStatus": 0], attempt: attempt)
        try await adapter.receiveTrueConf(["method": "VideoSourceType", "UserName": "alice", "Type": 0], attempt: attempt)
        XCTAssertEqual(adapter.incomingVideo.map(\.id), ["alice.camera"])
    }
}
