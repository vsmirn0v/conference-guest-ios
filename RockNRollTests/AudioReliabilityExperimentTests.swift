#if DEBUG
import AVFoundation
import Darwin
import LiveKitWebRTC
import XCTest
@testable import RockNRoll

/// Real Opus + H.264 through an identical finite-bandwidth best-effort link.
/// Completely synthetic, opt-in; policies never enter the production engines.
@MainActor
final class AudioReliabilityExperimentTests: XCTestCase {
    enum Mode: String, CaseIterable { case baseline, mediaPriorities, bandwidthPriority, dscp, videoYield }
    func testAudioAgainstVideoCongestionAndUIStalls() async throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_AUDIO_RELIABILITY"] == "1" else {
            throw XCTSkip("Opt-in synthetic audio/video scheduling comparison")
        }
        let rounds = Int(ProcessInfo.processInfo.environment["ROCKNROLL_TEST_AUDIO_ROUNDS"] ?? "1") ?? 1
        for round in 0..<max(1, min(3, rounds)) {
            let modes = round % 2 == 0 ? Mode.allCases : Mode.allCases.reversed().map { $0 }
            for mode in modes { try await run(mode, round: round) }
        }
    }

    private func run(_ mode: Mode, round: Int) async throws {
        _ = LKRTCInitializeSSL()
        LKRTCPeerConnectionFactory.configureFieldTrials(mode == .mediaPriorities ? "WebRTC-MediaTaskQueuePriorities/Enabled/" : nil)
        let device = MicrophoneFixtureDevice()
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: device)
        LKRTCPeerConnectionFactory.configureFieldTrials(nil)
        NativeRTCPeer.dscpForTesting = mode == .dscp
        defer { NativeRTCPeer.dscpForTesting = false }
        let sender = try NativeRTCPeer(target: "PUBLISHER", factory: factory, ice: [])
        let receiver = try NativeRTCPeer(target: "SUBSCRIBER", factory: factory, ice: [])
        NativeRTCPeer.dscpForTesting = false
        let audio = try XCTUnwrap(sender.connection.transceivers.first { $0.mediaType == .audio }?.sender)
        let video = try XCTUnwrap(sender.connection.transceivers.first { $0.mediaType == .video }?.sender)
        let source = factory.videoSource(), capture = LKRTCVideoCapturer(delegate: source)
        let track = factory.videoTrack(with: source, trackId: "audio-congestion-camera")
        video.track = track
        let parameters = audio.parameters
        if mode == .bandwidthPriority { parameters.encodings.first?.bitratePriority = 4 }
        if mode == .dscp { parameters.encodings.first?.networkPriority = .high }
        audio.parameters = parameters
        XCTAssertEqual(audio.parameters.encodings.first?.bitratePriority, mode == .bandwidthPriority ? 4 : 1)
        if mode == .dscp { XCTAssertEqual(audio.parameters.encodings.first?.networkPriority, .high) }
        let videoParameters = video.parameters
        videoParameters.encodings.first?.maxBitrateBps = 1_000_000
        videoParameters.encodings.first?.maxFramerate = 30
        video.parameters = videoParameters
        let relay = try AudioPacketDelayRelay(), port = try await relay.start()
        sender.onCandidate = { value in Task { @MainActor in try? await relay.add(value, from: 0, to: receiver, port: port) } }
        receiver.onCandidate = { value in Task { @MainActor in try? await relay.add(value, from: 1, to: sender, port: port) } }
        var feed: Task<Void, Never>?
        defer { feed?.cancel(); relay.stop() }
        do {
            sender.setMicrophone(true, profile: .music)
            func strip(_ value: [String: Any]) -> [String: Any] {
                var result = value
                if let sdp = value["sdp"] as? String {
                    result["sdp"] = sdp.components(separatedBy: "\r\n").filter { !$0.hasPrefix("a=candidate:") && $0 != "a=end-of-candidates" }.joined(separator: "\r\n")
                }
                return result
            }
            let offer = try await sender.offer(), answer = try await receiver.answer(strip(offer))
            sender.localSDPSent(); receiver.localSDPSent(); try await sender.accept(strip(answer))
            let deadline = Date().addingTimeInterval(8)
            while ![LKRTCIceConnectionState.connected, .completed].contains(receiver.connection.iceConnectionState), Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue([LKRTCIceConnectionState.connected, .completed].contains(receiver.connection.iceConnectionState))
            let pixels = try (0..<12).map { try makePixels(seed: UInt32(12345 + $0 * 1000)) }
            feed = Task.detached {
                let clock = ContinuousClock(); var next = clock.now; var index = 0
                while !Task.isCancelled {
                    source.capturer(capture, didCapture: LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixels[index % pixels.count]),
                        rotation: ._0, timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)))
                    index += 1
                    next = max(next.advanced(by: .nanoseconds(33_333_333)), clock.now)
                    do { try await Task.sleep(until: next, clock: clock) } catch { return }
                }
            }
            try await Task.sleep(for: .seconds(2))
            device.resetWindow(); try await Task.sleep(for: .seconds(1))
            XCTAssertGreaterThan(device.window.rms, 0.01, "Reject measurements without real decoded Opus")
            var windows = ReceiveDelayStatistics()
            relay.beginBottleneck()
            let cpuBefore = cpuTime(), started = ProcessInfo.processInfo.systemUptime
            for second in 0..<14 {
                // The candidate yields video after observing the same congestion
                // episode. This is an experimental cap, not a release threshold.
                if mode == .videoYield, second == 4 {
                    let p = video.parameters; p.encodings.first?.maxBitrateBps = 150_000; video.parameters = p
                }
                if second == 5 || second == 8 { Thread.sleep(forTimeInterval: 0.2) }
                let report: LKRTCStatisticsReport = await withCheckedContinuation { completion in receiver.connection.statistics { completion.resume(returning: $0) } }
                let records = report.statistics.values.filter { $0.type == "inbound-rtp" && $0.values["kind"] as? String == "audio" }.compactMap {
                    ReceiveDelayStatistics.record(id: $0.id, time: $0.timestamp_us / 1_000_000, values: $0.values)
                }
                for interval in windows.ingest(records) {
                    func text(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "unavailable" }
                    print("AUDIO_RELIABILITY,mode=\(mode.rawValue),round=\(round),second=\(second),jitter_ms=\(text(interval.jitterMS)),concealed=\(text(interval.concealedFraction))")
                }
                try await Task.sleep(for: .seconds(1))
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            print("AUDIO_RELIABILITY_END,mode=\(mode.rawValue),round=\(round),cpu_percent=\((cpuTime() - cpuBefore) / elapsed * 100),dropped=\(relay.droppedMediaPackets),rms=\(device.window.rms)")
            XCTAssertGreaterThan(device.window.rms, 0.01)
            let final: LKRTCStatisticsReport = await withCheckedContinuation { completion in receiver.connection.statistics { completion.resume(returning: $0) } }
            XCTAssertGreaterThan(final.statistics.values.filter { $0.type == "inbound-rtp" && $0.values["kind"] as? String == "video" }.compactMap { ($0.values["framesDecoded"] as? NSNumber)?.intValue }.max() ?? 0, 10)
            await sender.close(); await receiver.close()
        } catch { await sender.close(); await receiver.close(); throw error }
    }

    private func makePixels(seed: UInt32) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let pixels = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(pixels, []); defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        var random = seed
        for index in 0..<(CVPixelBufferGetBytesPerRow(pixels) * 360) {
            random = random &* 1664525 &+ 1013904223; bytes[index] = UInt8(truncatingIfNeeded: random >> 24)
        }
        return pixels
    }
    private func cpuTime() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
#endif
