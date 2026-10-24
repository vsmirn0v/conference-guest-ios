import ConferenceCore
import Foundation
import LiveKit
import LiveKitWebRTC

private enum RockTestError: Error { case assertion(String) }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw RockTestError.assertion(message) }
}
private final class AdmissionResponse: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let busy = request.url?.path == "/api/jams/audio-busy/join"
        let body = Data((busy ? "{\"server_url\":\"wss://rock.example.test\",\"participant_token\":\"12345678901234567890123456789012\",\"jam\":{\"id\":\"audio-busy\",\"title\":\"Fixture\",\"community\":\"fixture\",\"description\":\"\"}}" : "{}").utf8)
        let deliver = { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: busy ? 200 : 400,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if request.url?.path.contains("delayed") == true { DispatchQueue.global().asyncAfter(deadline: .now() + 0.1, execute: deliver) }
        else { deliver() }
    }
    override func stopLoading() {}
}
private final class RockFrameSink: NSObject, LiveKit.VideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [CGSize] = []
    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { .zero }
    var frames: [CGSize] { lock.lock(); defer { lock.unlock() }; return sizes }
    func render(frame: LiveKit.VideoFrame) {
        lock.lock(); sizes.append(CGSize(width: Int(frame.dimensions.width), height: Int(frame.dimensions.height))); lock.unlock()
    }
}
@main private struct NativeDesktopRockEngineTests {
    static func demandPolicy() throws {
        let tracks = (0..<50).flatMap { index in
            [NativeRockRemoteTrack(id: "audio-\(index)", participantID: "person-\(index)", kind: .audio),
             NativeRockRemoteTrack(id: "video-\(index)", participantID: "person-\(index)", kind: .camera)]
        } + [.init(id: "share", participantID: "person-49", kind: .screen)]
        let initial = NativeRockVideoPolicy.demand(for: tracks, visible: nil, focused: nil, playout: true)
        try expect(tracks.filter { $0.kind == .audio }.allSatisfy { initial[$0.id]?.subscribed == true }, "Every audio publication survives a bounded video viewport")
        try expect(tracks.filter { $0.kind != .audio && initial[$0.id]?.subscribed == true }.count == 16,
            "Default receive demand has a hard decoder/bridge budget")
        let reversed = NativeRockVideoPolicy.demand(for: tracks.reversed(), visible: nil, focused: nil, playout: true)
        try expect(initial == reversed, "Publication enumeration order cannot change the bounded selection")
        let hidden = NativeRockVideoPolicy.demand(for: tracks, visible: [], focused: nil, playout: true)
        try expect(tracks.filter { $0.kind != .audio }.allSatisfy { hidden[$0.id]?.subscribed == false }, "Audio-only view creates no remote video bridges")
        try expect(tracks.filter { $0.kind == .audio }.allSatisfy { hidden[$0.id] == initial[$0.id] }, "Video visibility never changes audio intent")
        let focused = NativeRockVideoPolicy.demand(for: tracks, visible: ["person-0"], focused: "person-49", playout: true)
        try expect(Set(focused.filter { $0.value.subscribed && !$0.key.hasPrefix("audio-") }.keys) == ["video-0", "video-49", "share"],
            "Focus retains its camera and screen alongside only visible peers")
        try expect(focused["share"]?.primary == true && focused["video-49"]?.preferredFPS == 30 && focused["video-0"]?.preferredFPS == 15,
            "Focus and screen tracks use detail demand; gallery cameras use thumbnail demand")
        let quiet = NativeRockVideoPolicy.demand(for: tracks, visible: ["person-0"], focused: nil, playout: false)
        try expect(tracks.filter { $0.kind == .audio }.allSatisfy { quiet[$0.id]?.subscribed == false } && quiet["video-0"]?.subscribed == true,
            "Only the explicit playout action disables remote audio")
        let muted = NativeRockRemoteTrack(id: "muted", participantID: "person-0", kind: .camera, muted: true)
        try expect(NativeRockVideoPolicy.demand(for: [muted], visible: nil, focused: nil, playout: true)["muted"]?.subscribed == false,
            "Muted publications need no decoder or pixel bridge")
    }
    static func capturePolicies() throws {
        for size in [CGSize(width: 2560, height: 1600), CGSize(width: 2160, height: 3840), CGSize(width: 3840, height: 2160)] {
            try expect(NativeRockScreenPolicy.dimensions(size) == size, "Native screen aspect is unchanged inside the 4K envelope")
        }
        try expect(NativeRockScreenPolicy.dimensions(CGSize(width: 5120, height: 1440)) == CGSize(width: 3840, height: 1080),
            "Oversized ultrawide content scales proportionally, without 16:9 cropping")
        let square = NativeRockScreenPolicy.dimensions(CGSize(width: 4096, height: 4096))!
        try expect(square.width == square.height && square.width * square.height <= NativeRockScreenPolicy.maximumPixels,
            "Square content respects the pixel budget without changing aspect")
        try expect(NativeRockScreenPolicy.dimensions(CGSize(width: CGFloat.nan, height: 100)) == nil, "Invalid frame dimensions never reach encoding")
        let options = NativeRockScreenPolicy.publishOptions
        try expect(options.screenShareEncoding?.maxBitrate == 18_000_000 && options.screenShareEncoding?.maxFps == 30 &&
            options.degradationPreference == .maintainResolution && !options.simulcast, "Screen sender requests 18Mbps, 30fps and resolution retention")
        try expect(NativeRockCameraPolicy.dimensions(CGSize(width: 1920, height: 1080)) == CGSize(width: 1280, height: 720) &&
            NativeRockCameraPolicy.dimensions(CGSize(width: 1440, height: 1080)) == CGSize(width: 960, height: 720) &&
            NativeRockCameraPolicy.dimensions(CGSize(width: 1080, height: 1920)) == CGSize(width: 720, height: 1280),
            "Camera bounds preserve landscape, 4:3 and portrait aspect")
        let speech = NativeRockAudioPolicy.captureOptions(.speech), music = NativeRockAudioPolicy.captureOptions(.music)
        try expect(speech.echoCancellation && speech.autoGainControl && speech.noiseSuppression &&
            music.echoCancellation && music.echoCancellationMode == .software && !music.autoGainControl && !music.noiseSuppression,
            "Music preserves software echo cancellation while removing speech NS/AGC; Speech retains automatic processing")
        try expect(NativeRockAudioPolicy.processingOptions(.music).echoCancellationMode == .software,
            "Accessory preparation uses the same music processing policy as publication")
    }
    @MainActor static func latestDemand() async throws {
        let coordinator = MediaConfigurationCoordinator<String, NativeRockTrackDemand>(retryDelay: 1)
        let audio = NativeRockTrackDemand(subscribed: true, ready: false, primary: false)
        let shown = NativeRockTrackDemand(subscribed: true, ready: false, primary: false)
        let hidden = NativeRockTrackDemand(subscribed: false, ready: false, primary: false)
        var audioWrites = 0, videoWrites: [Bool] = [], release: CheckedContinuation<Void, Never>?
        let audioRequest = MediaConfigurationCoordinator<String, NativeRockTrackDemand>.Request(key: "audio", value: audio) { _ in audioWrites += 1 }
        coordinator.update([audioRequest]); await coordinator.waitForReconciliation()
        coordinator.update([audioRequest, .init(key: "video", value: shown) { demand in
            videoWrites.append(demand.subscribed)
            await withCheckedContinuation { release = $0 }
        }])
        while release == nil { await Task.yield() }
        coordinator.update([audioRequest, .init(key: "video", value: hidden) { videoWrites.append($0.subscribed) }])
        release?.resume(); await coordinator.waitForReconciliation()
        try expect(audioWrites == 1 && videoWrites == [true, false] && coordinator.isApplied("video", value: hidden),
            "An in-flight subscribe drains the newest hidden demand through one writer, without touching audio")
        var attempts = 0
        coordinator.update([audioRequest, .init(key: "video", value: shown) { _ in attempts += 1; throw RockTestError.assertion("transient") }])
        await coordinator.waitForReconciliation()
        try expect(attempts == 3 && coordinator.didFail("video", value: shown), "Failed SDK configuration has a bounded retry budget and readback")
        coordinator.reset()
    }
    @MainActor static func nativeAspectScreenBridge() async throws {
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory())
        for (inputSize, expected) in [(CGSize(width: 2560, height: 1600), CGSize(width: 2560, height: 1600)),
                                      (CGSize(width: 5120, height: 1440), CGSize(width: 3840, height: 1080))] {
            let source = factory.videoSource(forScreenCast: true)
            let track = factory.videoTrack(with: source, trackId: UUID().uuidString)
            let producer = LKRTCVideoCapturer(delegate: source)
            let bridge = NativeRockScreenBridge(track: track)
            let preparation = Task { try await bridge.attachAndWaitForDimensions() }
            var pixels: CVPixelBuffer?
            try expect(CVPixelBufferCreate(nil, Int(inputSize.width), Int(inputSize.height), kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess, "Synthetic frame allocated")
            for index in 0..<10 {
                source.capturer(producer, didCapture: LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixels!), rotation: ._0,
                    timeStampNs: Int64(index + 1) * 33_333_333))
                try await Task.sleep(for: .milliseconds(20))
            }
            let size = try await preparation.value
            try expect(size == expected, "Actual native screen bridge preserves/fits the first frame aspect")
            let local = await LocalVideoTrack.createBufferTrack(options: BufferCaptureOptions(
                dimensions: Dimensions(width: Int32(size.width), height: Int32(size.height)), fps: 30))
            let sink = RockFrameSink(); local.add(videoRenderer: sink)
            await bridge.setCapturer(local.capturer as! BufferCapturer)
            let deadline = Date().addingTimeInterval(2)
            while sink.frames.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try expect(sink.frames.last == expected, "Buffered native pixels reach the public LiveKit capturer without geometry changes")
            // Publishing starts the SDK track after the bridge supplies its
            // first dimensions. New frames must continue through that transition.
            try await local.start()
            let startedFrames = sink.frames.count
            for index in 0..<8 {
                source.capturer(producer, didCapture: LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixels!), rotation: ._0,
                    timeStampNs: Int64(index + 11) * 33_333_333))
                try await Task.sleep(for: .milliseconds(30))
            }
            try expect(sink.frames.count > startedFrames + 2 && sink.frames.suffix(3).allSatisfy { $0 == expected },
                "Screen and Presenter buffer feeds continue producing native-aspect frames after SDK track startup")
            try expect(local.capturer.dimensions == Dimensions(width: Int32(expected.width), height: Int32(expected.height)),
                "The SDK capturer resolves the actual output geometry used for encoding")
            await bridge.detach(); try await Task.sleep(for: .milliseconds(50))
            let before = sink.frames.count
            source.capturer(producer, didCapture: LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixels!), rotation: ._0, timeStampNs: 1_000_000_000))
            try await Task.sleep(for: .milliseconds(60))
            try expect(sink.frames.count == before, "Retired screen bridges forward no new frame")
            local.remove(videoRenderer: sink)
            try await local.stop()
        }
    }
    @MainActor static func sharedAudioOwnership() async throws {
        var privateLease = GuestAudioOwnerLease(privateCheck: true)
        try expect(privateLease != nil, "A private fixture check acquired exclusive ownership")
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AdmissionResponse.self]
        let engine = NativeDesktopRockEngine(service: JamService(session: URLSession(configuration: configuration)))
        do {
            try await engine.connect(invitation: URL(string: "https://rock.example.test/jams/audio-busy")!, name: "Guest", quiet: true)
            throw RockTestError.assertion("Rock created audio beside a private physical owner")
        } catch NativeDesktopRockError.audioOwnerBusy { }
        try expect(engine.factory == nil && engine.snapshot.phase == .failed,
            "A valid HTTP token cannot bypass the shared audio-owner gate")
        let clean = await engine.leave()
        try expect(clean && GuestAudioOwnerLease(privateCheck: true) == nil, "Rock failure cleanup cannot release another owner's private lease")
        privateLease = nil
        var normal = GuestAudioOwnerLease(privateCheck: false)
        try expect(normal != nil && GuestAudioOwnerLease(privateCheck: true) == nil, "A regular media owner excludes standalone private capture")
        normal = nil
        try expect(GuestAudioOwnerLease(privateCheck: true) != nil, "Confirmed owner release restores private-check availability")
    }
    @MainActor static func main() async {
        do {
            try demandPolicy(); try capturePolicies(); try await latestDemand(); try await nativeAspectScreenBridge(); try await sharedAudioOwnership()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AdmissionResponse.self]
            let engine = NativeDesktopRockEngine(service: JamService(session: URLSession(configuration: configuration)))
            var states: [NativeDesktopExternalSnapshot] = []
            engine.onState = { states.append($0) }
            do { try await engine.setMicrophone(true); throw RockTestError.assertion("Microphone accepted before admission") }
            catch NativeDesktopRockError.notConnected { }
            do {
                try await engine.connect(invitation: URL(string: "https://rock.example.test/jams/team")!, name: "Guest", quiet: true)
                throw RockTestError.assertion("A rejected admission connected")
            } catch JamServiceError.invalidName { }
            try expect(engine.snapshot.phase == .failed && !engine.chat.canSend && engine.factory == nil,
                "Rejected admission cannot initialize media or enable chat")
            try expect(states.allSatisfy { !$0.microphoneOn && !$0.cameraOn && !$0.sharing && !$0.playoutOn },
                "Quiet admission keeps all capture and playout intents off")
            let firstLeave = await engine.leave(), secondLeave = await engine.leave()
            try expect(firstLeave && secondLeave && engine.snapshot.phase == .left, "Leave is safe before successful media admission")
            let pending = Task { @MainActor in
                try await engine.connect(invitation: URL(string: "https://rock.example.test/jams/delayed")!, name: "Guest", quiet: false)
            }
            while engine.snapshot.phase != .connecting { await Task.yield() }
            let left = await engine.leave()
            do { try await pending.value; throw RockTestError.assertion("Stale admission was accepted") }
            catch JamServiceError.invalidName { }
            catch is CancellationError { }
            try expect(left && engine.snapshot.phase == .left && !engine.chat.canSend && engine.factory == nil,
                "A delayed admission cannot resurrect a session after Leave")
            print("PASS: Rock bounded focus/video demand with all audio retained, newest single-writer intent, native-aspect 4K screen bridge/retirement, 30fps/18Mbps policy, camera aspect, capture-off admission and stale-session fencing")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
