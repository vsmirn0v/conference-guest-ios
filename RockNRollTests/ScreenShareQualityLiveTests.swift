#if DEBUG
import AVFoundation
import ConferenceCore
import UIKit
import XCTest
@testable import RockNRoll

/// Opt-in media qualification. Run one live method per XCTest process because
/// the binary SDK initializes globally once. Synthetic Presenter pixels qualify
/// the SDK encoder and an independent
/// browser decoder without accessing the desktop, microphone or camera.
@MainActor final class ScreenShareQualityLiveTests: XCTestCase {
    /// Qualifies the rebuilt WebRTC against the unchanged binary SDK and a real
    /// independent sender. Synthetic speech/share must be running before Join.
    func testRebuiltSDKReceivesMediaAfterRepeatedJoins() async throws {
        guard let link = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_REBUILT_SDK_INVITE"] else {
            throw XCTSkip("Opt-in rebuilt SDK compatibility with synthetic browser media")
        }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        let original = window.rootViewController
        let container = UIViewController(); window.rootViewController = container
        defer { window.rootViewController = original }
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let target = try JoinTarget.parse(link)
        let endpoint = try await VendorEndpointResolver.make().resolve(for: target)
        var active = false, ended = false
        engine.onEvent = { event in
            switch event { case .active: active = true; case .left, .failed: ended = true; default: break }
        }
        defer { engine.leave() }
        for attempt in 1...3 {
            active = false; ended = false
            try engine.configure(container: container, networkURL: endpoint, displayName: "Rebuilt transport QA")
            let joinStarted = ProcessInfo.processInfo.systemUptime
            try engine.join(target: target, displayName: "Rebuilt transport QA")
            try await wait { active || ended }; XCTAssertFalse(ended)
            let activeAt = ProcessInfo.processInfo.systemUptime
            try await wait { engine.hasReceivedVideoFrameForTesting || ended }
            XCTAssertFalse(ended)
            let videoAt = ProcessInfo.processInfo.systemUptime
            print("GUEST_VIDEO_START attempt=\(attempt) join_to_first_frame_s=\(videoAt - joinStarted) active_to_first_frame_s=\(videoAt - activeAt)")
            var received = false
            var lastStats: [[String: Any]] = []
            for _ in 0..<20 {
                try await Task.sleep(for: .seconds(1))
                let stats = await GuestMicrophoneProbe.codecEvidenceForTesting()
                lastStats = stats
                let audio = stats.contains { $0["type"] as? String == "inbound-rtp" && $0["kind"] as? String == "audio" && ($0["totalAudioEnergy"] as? NSNumber)?.doubleValue ?? 0 > 0 }
                let video = stats.contains { $0["type"] as? String == "inbound-rtp" && $0["kind"] as? String == "video" && ($0["framesDecoded"] as? NSNumber)?.intValue ?? 0 > 20 }
                if audio && video {
                    print("REBUILT_SDK extended=\(GuestConferencePlayoutReservation.isSupported) attempt=\(attempt) received=\(stats)"); received = true; break
                }
            }
            if !received { print("REBUILT_SDK attempt=\(attempt) failed=\(lastStats)") }
            XCTAssertTrue(received, "Rebuilt SDK must decode actual speech and moving share on every new session")
            XCTAssertFalse(ended)
            if attempt == 1, ProcessInfo.processInfo.isiOSAppOnMac,
               ProcessInfo.processInfo.environment["ROCKNROLL_TEST_REBUILT_SDK_MIC"] == "1" {
                for cycle in 1...3 {
                    let before = await GuestMicrophoneProbe.codecEvidenceForTesting()
                    let capturedBefore = audioCaptureDuration(before), energyBefore = receivedAudioEnergy(before)
                    engine.setMicrophoneForTesting(true)
                    var captured = false
                    for _ in 0..<10 {
                        try await Task.sleep(for: .seconds(1))
                        let stats = await GuestMicrophoneProbe.codecEvidenceForTesting()
                        if audioCaptureDuration(stats) > capturedBefore + 0.5 &&
                            stats.contains(where: { $0["type"] as? String == "outbound-rtp" && $0["kind"] as? String == "audio" && ($0["packetsSent"] as? NSNumber)?.intValue ?? 0 > 10 }) {
                            captured = true; print("REBUILT_MIC cycle=\(cycle) recording=\(stats)"); break
                        }
                    }
                    engine.setMicrophoneForTesting(false)
                    XCTAssertTrue(captured, "The Mac input transition must capture PCM and send Opus")
                    var resumed = false
                    for _ in 0..<10 {
                        try await Task.sleep(for: .seconds(1))
                        let stats = await GuestMicrophoneProbe.codecEvidenceForTesting()
                        if receivedAudioEnergy(stats) > energyBefore + 0.01 {
                            resumed = true; print("REBUILT_MIC cycle=\(cycle) muted=\(stats)"); break
                        }
                    }
                    XCTAssertTrue(resumed, "Output-only playback must recover after stopping microphone capture")
                }
            }
            if attempt == 1, ProcessInfo.processInfo.isiOSAppOnMac,
               ProcessInfo.processInfo.environment["ROCKNROLL_TEST_REBUILT_SDK_CAMERA"] == "1" {
                for cycle in 1...2 {
                    let before = await GuestMicrophoneProbe.codecEvidenceForTesting()
                    let counts = Dictionary(uniqueKeysWithValues: before.filter { $0["type"] as? String == "outbound-rtp" && $0["kind"] as? String == "video" }
                        .compactMap { row -> (String, Int)? in
                            guard let id = row["id"] as? String else { return nil }
                            return (id, (row["framesEncoded"] as? NSNumber)?.intValue ?? 0)
                        })
                    engine.setCameraForTesting(true)
                    var encoded = false
                    for _ in 0..<15 {
                        try await Task.sleep(for: .seconds(1))
                        let stats = await GuestMicrophoneProbe.codecEvidenceForTesting()
                        if stats.contains(where: { row in
                            guard row["type"] as? String == "outbound-rtp", row["kind"] as? String == "video",
                                  let id = row["id"] as? String else { return false }
                            return (row["framesEncoded"] as? NSNumber)?.intValue ?? 0 > (counts[id] ?? 0) + 10 &&
                                (row["packetsSent"] as? NSNumber)?.intValue ?? 0 > 10
                        }) {
                            encoded = true; print("REBUILT_CAMERA cycle=\(cycle) sent=\(stats)"); break
                        }
                    }
                    engine.setCameraForTesting(false)
                    XCTAssertTrue(encoded, "The rebuilt dependency must publish camera frames on every restart")
                    try await Task.sleep(for: .seconds(1))
                }
            }
            engine.leave(); try await wait { ended }
        }
    }
    func testGuestReceivesNativeScreenDetail() async throws {
        guard let link = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SCREEN_QUALITY_RECEIVE_INVITE"] else {
            throw XCTSkip("Opt-in browser-generated 4K screen reception")
        }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        let original = window.rootViewController
        let container = UIViewController(); window.rootViewController = container
        defer { window.rootViewController = original }
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        var active = false, ended = false
        engine.onEvent = { event in
            switch event { case .active: active = true; case .left, .failed: ended = true; default: break }
        }
        let target = try JoinTarget.parse(link)
        let endpoint = try await VendorEndpointResolver.make().resolve(for: target)
        try engine.configure(container: container, networkURL: endpoint, displayName: "Screen detail receiver QA")
        try engine.join(target: target, displayName: "Screen detail receiver QA")
        defer { engine.leave() }
        try await wait { active || ended }; XCTAssertFalse(ended)
        var received = false
        for _ in 0..<20 {
            try await Task.sleep(for: .seconds(1))
            let stats = await GuestMicrophoneProbe.codecEvidenceForTesting().filter { $0["type"] as? String == "inbound-rtp" && $0["kind"] as? String == "video" }
            if stats.contains(where: { ($0["frameWidth"] as? NSNumber)?.intValue == 3840 && ($0["frameHeight"] as? NSNumber)?.intValue == 2160 && ($0["framesDecoded"] as? NSNumber)?.intValue ?? 0 > 10 }) {
                print("SCREEN_DETAIL received=\(stats)"); received = true; break
            }
            print("SCREEN_DETAIL receiving=\(stats)")
        }
        XCTAssertTrue(received, "The SDK should request and decode the source detail")
    }
    func testGuestNativeScreenDetail() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              let link = environment["ROCKNROLL_TEST_SCREEN_QUALITY_INVITE"],
              let receiver = environment["ROCKNROLL_TEST_SCREEN_RECEIVER"].flatMap(URL.init(string:)) else {
            throw XCTSkip("Opt-in authorized guest screen quality qualification")
        }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        let original = window.rootViewController
        let container = UIViewController(); window.rootViewController = container
        defer { window.rootViewController = original }
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        var active = false, ended = false
        engine.onEvent = { event in
            switch event { case .active: active = true; case .left, .failed: ended = true; default: break }
        }
        let target = try JoinTarget.parse(link)
        let endpoint = try await VendorEndpointResolver.make().resolve(for: target)
        try engine.configure(container: container, networkURL: endpoint, displayName: "Screen detail QA")
        try engine.join(target: target, displayName: "Screen detail QA")
        defer { engine.leave() }
        try await wait { active && engine.readyForPresenterForTesting || ended }
        XCTAssertFalse(ended)
        let studio = engine.studioForTesting, model = studio.presenter
        let source = DetailChartSource()
        model.makeScreenSource = { frame, _, selected, _ in
            source.frame = frame; source.selected = selected; return source
        }
        studio.open(.presenter); model.includeCamera = false
        model.selectScreen()
        try await wait { model.hasPreview || ended }
        await model.start()
        XCTAssertTrue(model.running, model.error ?? "Publication did not start")
        for (index, width) in [1920, 2560, 3840, 3840].enumerated() {
            let composed = index == 3
            if composed { model.appendAnnotation([CGPoint(x: 0.01, y: 0.8), CGPoint(x: 0.9, y: 0.8)]) }
            try source.resize(width: width)
            _ = try await URLSession.shared.data(from: receiver.appendingPathComponent("reset"))
            try await Task.sleep(for: .seconds(15))
            let (data, _) = try await URLSession.shared.data(from: receiver.appendingPathComponent("frames"))
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let frames = report["frames"] as? [[String: Any]] ?? []
            XCTAssertTrue(frames.suffix(10).contains { ($0["width"] as? NSNumber)?.intValue == width && ($0["height"] as? NSNumber)?.intValue == width * 9 / 16 },
                "Independent receiver must decode source detail, including annotated Presenter output")
            print("SCREEN_DETAIL source=\(width)x\(width * 9 / 16) composed=\(composed) receiver=\(frames.suffix(2))")
            let stats = await GuestMicrophoneProbe.codecEvidenceForTesting()
            print("SCREEN_DETAIL stats=\(stats.filter { $0["type"] as? String == "outbound-rtp" })")
            print("SCREEN_DETAIL encoders=\(GuestH264ColorEncoder.evidenceForTesting())")
            _ = try await URLSession.shared.data(from: receiver.appendingPathComponent("snapshot-\(width)\(composed ? "-composed" : "")"))
            XCTAssertFalse(ended); XCTAssertNil(model.error)
        }
        model.stop(); await model.waitForScreenStop()
        engine.leave(); try await wait { ended }
    }
    private func audioCaptureDuration(_ stats: [[String: Any]]) -> Double {
        stats.filter { $0["type"] as? String == "media-source" && $0["kind"] as? String == "audio" }
            .compactMap { ($0["totalSamplesDuration"] as? NSNumber)?.doubleValue }.max() ?? 0
    }
    private func receivedAudioEnergy(_ stats: [[String: Any]]) -> Double {
        stats.filter { $0["type"] as? String == "inbound-rtp" && $0["kind"] as? String == "audio" }
            .compactMap { ($0["totalAudioEnergy"] as? NSNumber)?.doubleValue }.max() ?? 0
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(30)
        while !predicate(), Date() < end { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(predicate())
        if !predicate() { throw NSError(domain: "ScreenDetailQualification", code: 1) }
    }
}

@MainActor private final class DetailChartSource: PresenterScreenSource {
    var frame: ((CMSampleBuffer) -> Void)?
    var selected: ((PresenterScreenSelection) -> Void)?
    private var pixels: CVPixelBuffer?
    private var task: Task<Void, Never>?
    func start() {
        selected?(.selected)
        try? resize(width: 1920)
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let self, let pixels = self.pixels,
                   let sample = PresenterCompositor.sample(pixels, time: CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 1_000_000_000)) {
                    self.frame?(sample)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
    func stop() async { task?.cancel(); task = nil; pixels = nil }
    func resize(width: Int) throws {
        let height = width * 9 / 16
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let output = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(output), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(output), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: CGFloat(width) / 3840, y: -CGFloat(width) / 3840)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3840, height: 2160))
        for (index, size) in [16, 20, 24, 32, 48, 64].enumerated() {
            let text = "\(size) px • Screen detail / Чёткость текста • ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789"
            (text as NSString).draw(at: CGPoint(x: 80, y: 80 + index * 110), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular), .foregroundColor: UIColor.black])
        }
        UIColor.black.setFill()
        for thickness in [1, 2, 3, 4] {
            for x in stride(from: 80, to: 3600, by: thickness * 2) {
                context.fill(CGRect(x: x, y: 850 + thickness * 200, width: thickness, height: 140))
            }
        }
        pixels = output
    }
}
#endif
