#if DEBUG
import AVFoundation
import ConferenceCore
import LiveKit
import XCTest
@testable import RockNRoll

/// Explicit test inputs; the camera is opened only with the opt-in camera source.
@MainActor
final class OutgoingMediaLiveTests: XCTestCase {
    func testMatchedEncoderAndSubscriberDemandExperiment() async throws {
        guard let url = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_OUTGOING_JAM_URL"] else {
            throw XCTSkip("Opt-in live outgoing experiment")
        }
        let target = try JamTarget.parse(url)
        let environment = ProcessInfo.processInfo.environment
        let source = try XCTUnwrap(Input(rawValue: environment["ROCKNROLL_TEST_OUTGOING_SOURCE"] ?? "syntheticCamera"))
        let dimensions = source.dimensions
        let frames = try source == .camera ? [] : (0..<32).map {
            try Pattern.frame($0, width: Int(dimensions.width), height: Int(dimensions.height))
        }
        let seconds = Double(environment["ROCKNROLL_TEST_OUTGOING_SECONDS"] ?? "6") ?? 0
        guard (6...120).contains(seconds) else { throw NSError(domain: "OutgoingExperimentConfiguration", code: 2) }
        let requested = environment["ROCKNROLL_TEST_OUTGOING_PROFILES"]?.split(separator: ",").map(String.init)
            // Keep candidate selection explicit until device measurements are complete.
            ?? [OutgoingRoomExperiment.reference.rawValue, OutgoingRoomExperiment.dynacast.rawValue]
        let profiles = requested.compactMap(OutgoingRoomExperiment.init(rawValue:))
        let phases = environment["ROCKNROLL_TEST_OUTGOING_PHASES"]?.split(separator: ",").map(String.init)
            ?? ["high", "low", "none", "high-return"]
        guard profiles.count == requested.count, !profiles.isEmpty, !phases.isEmpty,
              phases.allSatisfy({ ["high", "low", "none", "high-return"].contains($0) }) else {
            throw NSError(domain: "OutgoingExperimentConfiguration", code: 1)
        }
        for profile in profiles {
            try await run(profile, target: target, frames: frames, phases: phases, input: source, seconds: seconds)
        }
    }

    private enum Input: String {
        case syntheticCamera, syntheticShare, camera
        var dimensions: Dimensions { self == .syntheticShare ? .h1080_169 : .h720_169 }
    }

    private func run(_ profile: OutgoingRoomExperiment, target: JamTarget, frames: [CVPixelBuffer], phases: [String], input: Input, seconds: Double) async throws {
        let sender = Room(roomOptions: profile.options)
        let receiver = Room()
        let dimensions = input.dimensions
        let longSide = max(Int(dimensions.width), Int(dimensions.height))
        let shortSide = min(Int(dimensions.width), Int(dimensions.height))
        let sink = Sink(measureQuality: input != .camera, dimensions: dimensions)
        var observed: VideoTrack?
        var feed: Task<Void, Never>?
        let monitor = OutgoingRoomMonitor()
        do {
            let service = JamService()
            let senderCredentials = try await service.join(target, name: "Outgoing experiment sender")
            let receiverCredentials = try await service.join(target, name: "Outgoing experiment receiver")
            let connect = ConnectOptions(autoSubscribe: false)
            try await sender.connect(url: senderCredentials.serverURL.absoluteString,
                                     token: senderCredentials.participantToken, connectOptions: connect)
            try await receiver.connect(url: receiverCredentials.serverURL.absoluteString,
                                       token: receiverCredentials.participantToken, connectOptions: connect)
            let track: LocalVideoTrack
            if input == .camera {
                track = await LocalVideoTrack.createCameraTrack(name: "Outgoing camera experiment",
                    options: CameraCaptureOptions(position: .front, dimensions: .h720_169, fps: 30), reportStatistics: true)
            } else {
                track = await LocalVideoTrack.createBufferTrack(name: "Synthetic outgoing experiment",
                    source: input == .syntheticShare ? .screenShareVideo : .camera,
                    options: BufferCaptureOptions(dimensions: dimensions, fps: 30), reportStatistics: true)
                let capturer = try XCTUnwrap(track.capturer as? BufferCapturer)
                feed = Task {
                    var index = 0
                    let clock = ContinuousClock()
                    var next = clock.now
                    while !Task.isCancelled {
                        capturer.capture(frames[index % frames.count])
                        index += 1
                        next = max(next.advanced(by: .nanoseconds(33_333_333)), clock.now)
                        try? await Task.sleep(until: next, clock: clock)
                    }
                }
            }
            var publishOptions: VideoPublishOptions?
            if input == .syntheticShare {
                let base = profile.options.defaultVideoPublishOptions
                // Match a 1080p/30 source explicitly; automatic 720p screen presets cap at 5 fps.
                publishOptions = VideoPublishOptions(screenShareEncoding: VideoEncoding(maxBitrate: 5_000_000, maxFps: 30),
                    simulcast: base.simulcast, preferredCodec: base.preferredCodec,
                    degradationPreference: base.degradationPreference)
            }
            let published = try await sender.localParticipant.publish(videoTrack: track, options: publishOptions)
            try await wait {
                receiver.remoteParticipants.values.flatMap(\.videoTracks).contains { $0.sid == published.sid }
            }
            let remote = try XCTUnwrap(receiver.remoteParticipants.values.flatMap(\.videoTracks)
                .first { $0.sid == published.sid } as? RemoteTrackPublication)
            for phase in phases {
                observed?.remove(videoRenderer: sink)
                observed = nil
                sink.reset()
                if phase == "none" {
                    try await remote.set(subscribed: false)
                } else {
                    try await remote.set(subscribed: true)
                    try await wait { remote.track != nil }
                    try await remote.set(videoQuality: phase == "low" ? .low : .high)
                    observed = remote.track as? VideoTrack
                    observed?.add(videoRenderer: sink)
                }
                try await Task.sleep(for: .seconds(4))
                if phase == "high" || phase == "high-return" {
                    try await wait(seconds: 60) {
                        let value = sink.snapshot()
                        return max(value.width, value.height) == longSide && min(value.width, value.height) == shortSide
                    }
                    try await Task.sleep(for: .seconds(4))
                }
                sink.reset()
                print("OUTGOING_PHASE_BEGIN,profile=\(profile.rawValue),phase=\(phase),input=\(input.rawValue),wall_start_s=\(Date().timeIntervalSince1970)")
                monitor.record(track: track)
                let before = processCPU()
                let start = ProcessInfo.processInfo.systemUptime
                let thermalBefore = ProcessInfo.processInfo.thermalState.rawValue
                try await Task.sleep(for: .seconds(seconds))
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let cpu = processCPU() - before
                let decoded = sink.snapshot()
                print("OUTGOING_PHASE_END,profile=\(profile.rawValue),phase=\(phase),input=\(input.rawValue),wall_end_s=\(Date().timeIntervalSince1970),elapsed_s=\(elapsed),process_cpu_percent=\(cpu / elapsed * 100),decoded=\(decoded.count),size=\(decoded.width)x\(decoded.height),luma_psnr_db=\(decoded.psnr),thermal_before=\(thermalBefore),thermal_after=\(ProcessInfo.processInfo.thermalState.rawValue)")
                monitor.record(track: track)
                if profile == .production, phase != "none" {
                    let stats = track.statistics
                    XCTAssertTrue(stats?.outboundRtpStream.contains { value in
                        value.powerEfficientEncoder == true &&
                            stats?.codec.first(where: { $0.id == value.codecId })?.mimeType?.lowercased() == "video/h264"
                    } == true, "Production must negotiate the hardware H.264 path on this supported device")
                }
                if phase != "none" { XCTAssertGreaterThan(decoded.count, 0, "\(profile): \(phase) delivered no video") }
                if phase == "high" || phase == "high-return" {
                    XCTAssertEqual(max(decoded.width, decoded.height), longSide, "Full resolution must return after a demand change")
                    XCTAssertEqual(min(decoded.width, decoded.height), shortSide)
                }
            }
            feed?.cancel()
            observed?.remove(videoRenderer: sink)
            await receiver.disconnect(); await sender.disconnect()
        } catch {
            feed?.cancel()
            observed?.remove(videoRenderer: sink)
            await receiver.disconnect(); await sender.disconnect()
            throw error
        }
    }

    private func wait(seconds: TimeInterval = 15, _ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < end { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(predicate(), "Media publication/subscription did not become ready")
        if !predicate() { throw NSError(domain: "OutgoingExperiment", code: 1) }
    }
    private func processCPU() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) +
            Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }
}

private final class Sink: NSObject, VideoRenderer, @unchecked Sendable {
    private let measureQuality: Bool
    private let expectedWidth: Int, expectedHeight: Int
    init(measureQuality: Bool, dimensions: Dimensions) {
        self.measureQuality = measureQuality
        expectedWidth = Int(dimensions.width); expectedHeight = Int(dimensions.height)
    }
    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { .zero }
    private let lock = NSLock()
    private var count = 0, width = 0, height = 0
    private var lastQualityTime = 0.0
    private var quality: [Double] = []

    func render(frame: VideoFrame) {
        lock.lock()
        count += 1; width = Int(frame.dimensions.width); height = Int(frame.dimensions.height)
        let time = ProcessInfo.processInfo.systemUptime
        let sample = measureQuality && width == expectedWidth && height == expectedHeight && time - lastQualityTime >= 1
        if sample { lastQualityTime = time }
        lock.unlock()
        guard sample else { return }
        // Read luma directly. Avoid allocating/converting every decoded frame for the probe.
        if let planar = frame.buffer as? I420VideoBuffer {
            recordQuality(data: planar.dataY, stride: Int(planar.strideY))
        } else if let native = frame.buffer as? CVPixelVideoBuffer {
            let buffer = native.pixelBuffer
            guard CVPixelBufferGetPlaneCount(buffer) == 2,
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
                recordQuality(data: base.assumingMemoryBound(to: UInt8.self), stride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                    fullRange: CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            }
        }
    }
    private func recordQuality(data: UnsafePointer<UInt8>, stride: Int, fullRange: Bool = false) {
        func luma(_ x: Int, _ y: Int) -> Double {
            let value = Double(data[y * stride + x])
            return fullRange ? 16 + value * 219 / 255 : value
        }
        var index = 0
        for bit in 0..<5 { if luma(bit * 64 + 32, 32) > 126 { index |= 1 << bit } }
        var squareError = 0.0, samples = 0.0
        for y in Swift.stride(from: 80, to: expectedHeight, by: 16) {
            for x in Swift.stride(from: 8, to: expectedWidth, by: 16) {
                let difference = luma(x, y) - Double(Pattern.luma(index, x, y))
                squareError += difference * difference; samples += 1
            }
        }
        let psnr = squareError == 0 ? 99 : 10 * log10(255 * 255 * samples / squareError)
        lock.lock(); quality.append(psnr); lock.unlock()
    }
    func reset() { lock.lock(); count = 0; width = 0; height = 0; quality = []; lastQualityTime = 0; lock.unlock() }
    func snapshot() -> (count: Int, width: Int, height: Int, psnr: Double) {
        lock.lock(); defer { lock.unlock() }
        return (count, width, height, quality.isEmpty ? 0 : quality.reduce(0, +) / Double(quality.count))
    }
}

private enum Pattern {
    static func luma(_ index: Int, _ x: Int, _ y: Int) -> UInt8 {
        if y < 64 { return x < 320 && index & (1 << (x / 64)) != 0 ? 220 : 32 }
        if x >= index * 32 && x < index * 32 + 160 && y > 240 && y < 480 { return 220 }
        if x % 64 < 2 || y % 64 < 2 { return 32 }
        return UInt8(40 + (x / 8 + y / 8) % 160)
    }
    static func frame(_ index: Int, width: Int, height: Int) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value) == kCVReturnSuccess,
            let value else { throw NSError(domain: "OutgoingPattern", code: 1) }
        CVPixelBufferLockBaseAddress(value, [])
        let data = CVPixelBufferGetBaseAddressOfPlane(value, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(value, 0)
        for y in 0..<height { for x in 0..<width { data[y * stride + x] = luma(index, x, y) } }
        memset(CVPixelBufferGetBaseAddressOfPlane(value, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(value, 1) * 360)
        CVPixelBufferUnlockBaseAddress(value, [])
        return value
    }
}
#endif
