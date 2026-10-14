import AVFoundation
import ConferenceCore
import UIKit
import WebRTC
import XCTest
@testable import RockNRoll

/// Opt-in: independent synthetic participants must already be publishing.
@MainActor
final class GuestMediaResponsivenessLiveTests: XCTestCase {
    func testMediaControlsWithConcurrentIncomingStreams() async throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_RESPONSIVENESS_INVITE"] else {
            throw XCTSkip("Requires a disposable room with independent media publishers")
        }
        for media: AVMediaType in [.audio, .video] {
            if AVCaptureDevice.authorizationStatus(for: media) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: media)
            }
            guard AVCaptureDevice.authorizationStatus(for: media) == .authorized else {
                throw XCTSkip("Capture permission is needed for the live media-control check")
            }
        }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow })
        let original = window.rootViewController, host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore())
        let pulse = MainQueueLatencyProbe()
        defer { pulse.stop(); engine.leave(); window.rootViewController = original }
        var active = false, ended = false
        engine.onEvent = { event in
            if event == .active { active = true }
            if [.left, .failed, .canceled, .evicted].contains(event) { ended = true }
        }
        func wait(_ name: String, _ predicate: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while !predicate(), !ended, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard predicate(), !ended else {
                throw NSError(domain: "MediaResponsiveness", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out: " + name])
            }
        }
        let target = try JoinTarget.parse(invitation)
        try engine.configure(container: host, networkURL: await VendorEndpointResolver.make().resolve(for: target),
                             displayName: "Media controls QA")
        try engine.join(target: target, displayName: "Media controls QA")
        try await wait("connected media") { active && engine.hasReceivedVideoFrameForTesting }
        let required = Int(ProcessInfo.processInfo.environment["ROCKNROLL_TEST_RESPONSIVENESS_STREAMS"] ?? "1") ?? 1
        func incomingVideos(_ rows: [[String: Any]]) -> Int {
            rows.filter { $0["type"] as? String == "inbound-rtp" && $0["kind"] as? String == "video" &&
                (($0["framesDecoded"] as? NSNumber)?.intValue ?? 0) > 0 }.count
        }
        var before = await GuestMicrophoneProbe.codecEvidenceForTesting()
        let mediaDeadline = ProcessInfo.processInfo.systemUptime + 25
        while incomingVideos(before) < required, !ended, ProcessInfo.processInfo.systemUptime < mediaDeadline {
            try await Task.sleep(for: .seconds(1))
            before = await GuestMicrophoneProbe.codecEvidenceForTesting()
        }
        let inbound = before.filter { $0["type"] as? String == "inbound-rtp" }
        print("MEDIA_LOAD pid=\(getpid()) incomingVideo=\(incomingVideos(before)) incomingAudio=\(inbound.filter { $0["kind"] as? String == "audio" }.count)")
        guard incomingVideos(before) >= required else {
            throw NSError(domain: "MediaResponsiveness", code: 2, userInfo: [NSLocalizedDescriptionKey: "Required incoming load was not established"])
        }
        if let seconds = Double(ProcessInfo.processInfo.environment["ROCKNROLL_TEST_RESPONSIVENESS_MANUAL_SECONDS"] ?? ""), seconds > 0 {
            print("MEDIA_MANUAL_READY seconds=\(min(seconds, 300))")
            try await Task.sleep(for: .seconds(min(seconds, 300)))
            return
        }
        let peers = GuestPeerRegistry.snapshot().filter { $0.connectionState == .connected }
        let churnStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<30 { autoreleasepool { for peer in peers { _ = peer.transceivers.count; _ = peer.receivers.count } } }
        print("MEDIA_RECEIVER_WRAPPERS elapsed_ms=\((ProcessInfo.processInfo.systemUptime - churnStart) * 1000)")
        let packet = expectation(description: "Real receiver observer gets its first-packet callback")
        packet.assertForOverFulfill = false
        let delegate = FirstPacketDelegate(packet)
        let receiver = try XCTUnwrap(peers.flatMap { $0.receivers }.first { $0.track?.kind == "audio" })
        receiver.delegate = delegate
        await fulfillment(of: [packet], timeout: 3)
        receiver.delegate = nil
        pulse.start()
        let studio = engine.studioForTesting
        for cycle in 0..<4 {
            for enabled in [true, false] {
                let micStart = ProcessInfo.processInfo.systemUptime
                engine.setMicrophoneForTesting(enabled)
                let micReturned = ProcessInfo.processInfo.systemUptime
                try await wait("microphone state") { studio.microphoneOn == enabled }
                print("MEDIA_CONTROL cycle=\(cycle) kind=microphone on=\(enabled) synchronous_ms=\((micReturned-micStart)*1000) ready_ms=\((ProcessInfo.processInfo.systemUptime-micStart)*1000)")
                try await Task.sleep(for: .seconds(1))
                let cameraStart = ProcessInfo.processInfo.systemUptime
                engine.setCameraForTesting(enabled)
                let cameraReturned = ProcessInfo.processInfo.systemUptime
                try await wait("camera state") { studio.cameraOn == enabled }
                print("MEDIA_CONTROL cycle=\(cycle) kind=camera on=\(enabled) synchronous_ms=\((cameraReturned-cameraStart)*1000) ready_ms=\((ProcessInfo.processInfo.systemUptime-cameraStart)*1000)")
                try await Task.sleep(for: .seconds(1))
            }
        }
        pulse.stop()
        let after = await GuestMicrophoneProbe.codecEvidenceForTesting()
        func receivedBytes(_ rows: [[String: Any]], kind: String) -> Int64 {
            rows.filter { $0["type"] as? String == "inbound-rtp" && $0["kind"] as? String == kind }
                .reduce(0) { $0 + (($1["bytesReceived"] as? NSNumber)?.int64Value ?? 0) }
        }
        XCTAssertGreaterThan(receivedBytes(after, kind: "audio"), receivedBytes(before, kind: "audio"))
        XCTAssertGreaterThan(receivedBytes(after, kind: "video"), receivedBytes(before, kind: "video"))
        print("MEDIA_MAIN_QUEUE max_ms=\(pulse.maximumDelay * 1000)")
        XCTAssertLessThan(pulse.maximumDelay, 0.5, "Media controls must not block the UI queue")
    }
}

private final class MainQueueLatencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var pending = false
    private var maximum = 0.0
    var maximumDelay: Double { lock.lock(); defer { lock.unlock() }; return maximum }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "qa.main-queue-latency", qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.pending else { self.lock.unlock(); return }
            self.pending = true; self.lock.unlock()
            let start = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                self.lock.lock()
                let delay = ProcessInfo.processInfo.systemUptime - start
                if delay > 0.2 { print("MEDIA_MAIN_STALL queued_at=\(start) delay_ms=\(delay * 1000) time=\(Date().timeIntervalSince1970)") }
                self.maximum = max(self.maximum, delay)
                self.pending = false; self.lock.unlock()
            }
        }
        self.timer = timer; timer.resume()
    }
    func stop() { timer?.cancel(); timer = nil }
    deinit { timer?.cancel() }
}

private final class FirstPacketDelegate: NSObject, RTCRtpReceiverDelegate {
    let packet: XCTestExpectation
    init(_ packet: XCTestExpectation) { self.packet = packet }
    func rtpReceiver(_ rtpReceiver: RTCRtpReceiver, didReceiveFirstPacketFor mediaType: RTCRtpMediaType) {
        packet.fulfill()
    }
}
