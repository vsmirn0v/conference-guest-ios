import ConferenceCore
import CryptoKit
import LiveKitWebRTC
import XCTest
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
    func testPhysicalCodecEvidenceAndRecovery() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Hardware codec qualification requires a physical device")
        #endif
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TRUECONF_INVITE"] else { throw XCTSkip("Authorized room required") }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        let previous = window.rootViewController, idle = UIApplication.shared.isIdleTimerDisabled
        let container = UIViewController(); window.rootViewController = container; UIApplication.shared.isIdleTimerDisabled = true
        defer { window.rootViewController = previous; UIApplication.shared.isIdleTimerDisabled = idle }
        let engine = TrueConfCallEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), chat: ChatStore())
        var active = 0, ended = false
        engine.onEvent = { event in switch event { case .active: active += 1; case .left, .failed: ended = true; default: break } }
        try engine.join(target: TrueConfTarget.parse(invitation), name: "Hardware Codec QA", container: container, quiet: false)
        defer { engine.leave() }
        try await wait { active > 0 || ended }; XCTAssertFalse(ended)
        guard !ended else { return }
        engine.setSendingForTesting(microphone: false, camera: true)
        try await Task.sleep(for: .seconds(8))
        let first = await engine.codecEvidenceForTesting()
        let initialFrames = first.reduce(into: [String: Int]()) { counts, row in
            if let id = row["id"] as? String, row["type"] as? String == "outbound-rtp" { counts[id] = (row["framesEncoded"] as? NSNumber)?.intValue ?? 0 }
        }
        print("TRUECONF_CODEC " + String(decoding: try JSONSerialization.data(withJSONObject: first, options: .sortedKeys), as: UTF8.self))
        XCTAssertTrue(first.contains { $0["type"] as? String == "inbound-rtp" && $0["mimeType"] as? String == "video/H264" && $0["decoderImplementation"] as? String == "VideoToolbox" && (($0["framesDecoded"] as? NSNumber)?.intValue ?? 0) > 10 })
        XCTAssertTrue(first.contains { $0["type"] as? String == "outbound-rtp" && (($0["framesEncoded"] as? NSNumber)?.intValue ?? 0) > 10 })
        engine.setSendingForTesting(microphone: false, camera: false)
        let studio = engine.studioForTesting
        studio.presenter.selectCanvas(); studio.open(.presenter)
        try await wait { studio.presenter.hasPreview }
        await studio.presenter.start(); try await wait { studio.presenter.running }
        for index in 0..<20 {
            studio.presenter.appendAnnotation([CGPoint(x: 0.1, y: Double(index) / 25), CGPoint(x: 0.8, y: Double(index) / 25)])
            try await Task.sleep(for: .milliseconds(250))
        }
        let presenting = await engine.codecEvidenceForTesting()
        print("TRUECONF_PRESENTER_CODEC " + String(decoding: try JSONSerialization.data(withJSONObject: presenting, options: .sortedKeys), as: UTF8.self))
        XCTAssertTrue(presenting.contains {
            $0["type"] as? String == "outbound-rtp" &&
            (($0["framesEncoded"] as? NSNumber)?.intValue ?? 0) > (initialFrames[$0["id"] as? String ?? ""] ?? 0) + 10
        }, "Presenter must encode fresh frames after camera stops")
        await studio.presenter.stop()
        let before = active; engine.interruptForTesting(); try await wait { active > before || ended }; XCTAssertFalse(ended)
        try await Task.sleep(for: .seconds(4))
        let recovered = await engine.codecEvidenceForTesting()
        print("TRUECONF_CODEC_RECOVERED " + String(decoding: try JSONSerialization.data(withJSONObject: recovered, options: .sortedKeys), as: UTF8.self))
        XCTAssertTrue(recovered.contains { $0["type"] as? String == "inbound-rtp" && $0["mimeType"] as? String == "video/H264" && (($0["framesDecoded"] as? NSNumber)?.intValue ?? 0) > 10 })
        XCTAssertFalse(ended)
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
    func testPresenterAndInputMeterContractsAvailableBeforeJoin() {
        let engine = TrueConfCallEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), chat: ChatStore())
        let studio = engine.studioForTesting
        XCTAssertTrue(studio.presenter.available); XCTAssertNotNil(studio.soundCheck.verifyMuted)
        XCTAssertEqual(studio.microphoneActivity.status, .muted); XCTAssertFalse(studio.microphoneActivity.samplingNeeded)
        studio.end()
    }
    func testPhysicalMicrophoneLevelAndBackgroundSampling() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Actual input level requires a physical microphone")
        #endif
        guard let text = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TRUECONF_INVITE"] else { throw XCTSkip("Authorized TrueConf room required") }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        let previous = window.rootViewController, container = UIViewController(); window.rootViewController = container
        defer { window.rootViewController = previous }
        let engine = TrueConfCallEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), chat: ChatStore())
        var active = false, ended = false
        engine.onEvent = { event in switch event { case .active: active = true; case .failed, .left: ended = true; default: break } }
        engine.onMediaStatus = { if let message = $0 { print("TRUECONF_STATE \(message)") } }
        try engine.join(target: TrueConfTarget.parse(text), name: "Rock Microphone QA", container: container, quiet: false)
        defer { engine.leave() }
        try await wait { active || ended }; XCTAssertFalse(ended)
        if ended { throw TrueConfError.rejected }
        engine.setSendingForTesting(microphone: true, camera: false)
        let activity = engine.studioForTesting.microphoneActivity
        for _ in 0..<12 {
            if activity.status == .on && activity.hasSignal || ended { break }
            print("TRUECONF_MICROPHONE state=\(activity.status) signal=\(activity.hasSignal) sending=\(engine.microphoneSendingForTesting)")
            try await Task.sleep(for: .seconds(1))
        }
        try await wait { activity.status == .on && activity.hasSignal || ended }; XCTAssertFalse(ended)
        var peak = activity.level
        print("TRUECONF_MICROPHONE listening")
        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(250)); peak = max(peak, activity.level) }
        XCTAssertGreaterThan(peak, 0, "Requires sound near iVitalii")
        print("TRUECONF_MICROPHONE peak=\(peak)")
        activity.setFloating(true); activity.setForeground(false); activity.clear()
        try await wait { activity.hasSignal }; XCTAssertTrue(activity.samplingNeeded)
        print("TRUECONF_MICROPHONE floating=\(activity.level)")
        activity.setForeground(true); activity.setFloating(false)
        engine.setSendingForTesting(microphone: false, camera: false)
        XCTAssertEqual(activity.status, .muted); XCTAssertFalse(activity.hasSignal)
        engine.leave(); try await wait { ended }
    }
    func testLiveReceiveRecoveryAndPresenter() async throws {
        guard let text = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TRUECONF_INVITE"] else { throw XCTSkip("Authorized TrueConf room and synthetic source required") }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        let previous = window.rootViewController, container = UIViewController(); window.rootViewController = container
        defer { window.rootViewController = previous }
        let engine = TrueConfCallEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), chat: ChatStore())
        var active = 0, ended = false
        engine.onEvent = { event in switch event { case .active: active += 1; case .failed, .left: ended = true; default: break } }
        engine.onMediaStatus = { message in if let message { print("TRUECONF_STATE \(message)") } }
        try engine.join(target: TrueConfTarget.parse(text), name: "Rock Presenter QA", container: container, quiet: false)
        defer { engine.leave() }
        try await wait { active > 0 || ended }; XCTAssertFalse(ended)
        if ended { throw TrueConfError.rejected }
        try await requireReceivedMedia(engine, label: "initial")
        XCTAssertFalse(engine.microphoneSendingForTesting)
        #if !targetEnvironment(simulator)
        let beforeHold = active
        try await engine.setTransferHeld(true, restoreSending: true)
        try await wait { !LKRTCAudioSession.sharedInstance().isAudioEnabled }
        try await Task.sleep(for: .seconds(2))
        try await engine.setTransferHeld(false, restoreSending: true)
        try await wait { active > beforeHold || ended }; XCTAssertFalse(ended)
        try await requireReceivedMedia(engine, label: "after-hold")
        print("TRUECONF_CALLKIT hold restored")
        #endif
        let before = active; engine.interruptForTesting(); try await wait { active > before || ended }; XCTAssertFalse(ended)
        try await requireReceivedMedia(engine, label: "after-transport-recovery")
        let studio = engine.studioForTesting
        studio.presenter.selectCanvas(); studio.open(.presenter); try await wait { studio.presenter.hasPreview }
        await studio.presenter.start(); try await wait { engine.isSharingScreen || ended }; XCTAssertFalse(ended)
        var frames = await engine.sentScreenFramesForTesting()
        let sendDeadline = Date().addingTimeInterval(12)
        while frames < 3, Date() < sendDeadline { try await Task.sleep(for: .milliseconds(200)); frames = await engine.sentScreenFramesForTesting() }
        XCTAssertGreaterThanOrEqual(frames, 3)
        print("TRUECONF_PRESENTER frames=\(frames)")
        studio.held = true; try await wait { !engine.isSharingScreen && !studio.presenter.running }
        studio.held = false; XCTAssertFalse(studio.presenter.running)
        engine.leave(); try await wait { ended }; XCTAssertFalse(engine.hasJoinStarted)
    }
    private func requireReceivedMedia(_ engine: TrueConfCallEngine, label: String) async throws {
        var media = await engine.receiveEvidenceForTesting()
        let deadline = Date().addingTimeInterval(12)
        while media.frames < 10 || media.energy == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200)); media = await engine.receiveEvidenceForTesting()
        }
        XCTAssertGreaterThanOrEqual(media.frames, 10); XCTAssertGreaterThan(media.energy, 0)
        print("TRUECONF_RECEIVE \(label) frames=\(media.frames) energy=\(media.energy)")
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        if !condition() { XCTFail("Required TrueConf state was not reached"); throw TrueConfError.timedOut }
    }
}
