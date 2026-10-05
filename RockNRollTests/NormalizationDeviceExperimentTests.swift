#if DEBUG
import AVFoundation
import QuartzCore
import UIKit
import WebRTC
import XCTest
@testable import RockNRoll

/// Sustained replay through the real paced processor and sample-buffer display.
@MainActor
final class NormalizationDeviceExperimentTests: XCTestCase {
    private enum Profile: String {
        case cropReference, cropCopy, scaleReference, scaleTransfer
        var scales: Bool { self == .scaleReference || self == .scaleTransfer }
        var converter: GuestVideoConversionExperiment {
            self == .cropCopy ? .nativeCopy : self == .scaleTransfer ? .nativeTransfer : .reference
        }
    }

    func testSustainedNormalizationReplay() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ROCKNROLL_TEST_NORMALIZATION_DEVICE"] == "1" else {
            throw XCTSkip("Opt-in sustained device replay")
        }
        #if targetEnvironment(simulator)
        let physicalPhone = false
        #else
        let physicalPhone = !ProcessInfo.processInfo.isiOSAppOnMac
        #endif
        let seconds = Double(env["ROCKNROLL_TEST_NORMALIZATION_SECONDS"] ?? (physicalPhone ? "30" : "150")) ?? 0
        let defaults = physicalPhone ? "cropReference" : "cropReference,cropCopy,cropCopy,cropReference"
        let requested = (env["ROCKNROLL_TEST_NORMALIZATION_PROFILES"] ?? defaults)
            .split(separator: ",").map(String.init)
        let profiles = requested.compactMap(Profile.init(rawValue:))
        guard (30...600).contains(seconds), profiles.count == requested.count, !profiles.isEmpty else {
            throw NSError(domain: "NormalizationConfiguration", code: 1)
        }
        // Leave setup/cleanup margin within the user's one-minute phone limit.
        guard !physicalPhone || Double(profiles.count) * (seconds + 5) <= 50 else {
            throw NSError(domain: "NormalizationPhoneTimeLimit", code: 1)
        }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow))
        let original = window.rootViewController
        let idleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let host = UIViewController()
        host.view.backgroundColor = .black
        let surface = GuestSampleBufferView()
        surface.frame = host.view.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(surface)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            surface.clear()
            window.rootViewController = original
            UIApplication.shared.isIdleTimerDisabled = idleTimer
        }
        let inputs = try (0..<8).map { try makeBuffer(index: $0) }
        for profile in profiles {
            try await run(profile, inputs: inputs, surface: surface, seconds: seconds)
        }
    }

    private func run(_ profile: Profile, inputs: [CVPixelBuffer], surface: GuestSampleBufferView, seconds: Double) async throws {
        let processor = GuestVideoFrameProcessor(experiment: profile.converter)
        let width = profile.scales ? 960 : 1920, height = profile.scales ? 540 : 1080
        var received = 0, submitted = 0, refused = 0, malformed = 0
        var ages: [Double] = []
        var measuring = false
        processor.onDeliveryForTesting = { timestamp in
            if measuring { ages.append((CACurrentMediaTime() - Double(timestamp) / 1e9) * 1000) }
        }
        processor.onSample = { sample, _, rotation in
            guard let pixels = CMSampleBufferGetImageBuffer(sample),
                  CVPixelBufferGetWidth(pixels) == width, CVPixelBufferGetHeight(pixels) == height else {
                malformed += 1; return
            }
            let accepted = surface.enqueue(sample, rotation: rotation)
            if measuring { received += 1; if !accepted { refused += 1 } }
        }
        processor.setEnabled(true)
        let source = processor.replaceSource()
        processor.setEnabled(true)
        let feed = Task { @MainActor in
            var index = 0
            let clock = ContinuousClock()
            var next = clock.now
            while !Task.isCancelled {
                let native = RTCCVPixelBuffer(pixelBuffer: inputs[index % inputs.count],
                    adaptedWidth: Int32(width), adaptedHeight: Int32(height), cropWidth: 1920, cropHeight: 1080,
                    cropX: 8, cropY: 8)
                processor.submit(RTCVideoFrame(buffer: native, rotation: ._0,
                    timeStampNs: Int64(CACurrentMediaTime() * 1e9)), source: source)
                if measuring { submitted += 1 }
                index += 1
                next = max(next.advanced(by: .nanoseconds(33_333_333)), clock.now)
                try? await Task.sleep(until: next, clock: clock)
            }
        }
        defer { feed.cancel(); processor.setEnabled(false); surface.clear() }
        try await Task.sleep(for: .seconds(5))
        guard UIApplication.shared.applicationState == .active else { throw NSError(domain: "NormalizationForeground", code: 1) }
        if profile.converter != .reference {
            XCTAssertGreaterThan(processor.experimentalNativeConversions, 0, "Candidate silently fell back")
        }
        let before = cpuTime()
        let initialThermal = ProcessInfo.processInfo.thermalState.rawValue
        let nativeBefore = processor.experimentalNativeConversions
        let start = CACurrentMediaTime()
        measuring = true
        print("NORMALIZATION_BEGIN,profile=\(profile.rawValue),wall_start_s=\(Date().timeIntervalSince1970)")
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(seconds))
        while clock.now < end {
            do {
                try await Task.sleep(for: .seconds(min(30, max(0.01, seconds - (CACurrentMediaTime() - start)))))
            } catch {
                print("NORMALIZATION_CANCEL,profile=\(profile.rawValue),elapsed_s=\(CACurrentMediaTime() - start),app_state=\(UIApplication.shared.applicationState.rawValue)")
                throw error
            }
            guard UIApplication.shared.applicationState == .active else { throw NSError(domain: "NormalizationForeground", code: 2) }
            print("NORMALIZATION_PROGRESS,profile=\(profile.rawValue),elapsed_s=\(CACurrentMediaTime() - start),delivered=\(received)")
        }
        let elapsed = CACurrentMediaTime() - start
        let cpu = cpuTime() - before
        measuring = false
        ages.sort()
        let median = ages.isEmpty ? 0 : ages[ages.count / 2]
        let p95 = ages.isEmpty ? 0 : ages[min(ages.count - 1, ages.count * 95 / 100)]
        print("NORMALIZATION_END,profile=\(profile.rawValue),wall_end_s=\(Date().timeIntervalSince1970),elapsed_s=\(elapsed),process_cpu_percent=\(cpu / elapsed * 100),submitted=\(submitted),delivered=\(received),refused=\(refused),malformed=\(malformed),native=\(processor.experimentalNativeConversions - nativeBefore),age_p50_ms=\(median),age_p95_ms=\(p95),thermal_before=\(initialThermal),thermal_after=\(ProcessInfo.processInfo.thermalState.rawValue)")
        XCTAssertEqual(malformed, 0)
        XCTAssertGreaterThan(Double(received) / elapsed, 29, "Output pacing regressed")
        XCTAssertLessThan(Double(refused) / Double(max(1, received)), 0.01, "Display backpressure regressed")
        // The existing newest-frame gate can wait one interval, followed by main
        // queue/display scheduling. Compare candidates against the same baseline.
        XCTAssertLessThan(p95, 66.7, "Frame age exceeded two intervals")
    }

    private func cpuTime() -> Double {
        var r = rusage(); getrusage(RUSAGE_SELF, &r)
        return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
    }

    private func makeBuffer(index: Int) throws -> CVPixelBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1936, 1096, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<1096 {
            for col in 0..<1936 {
                y[row * stride + col] = col > index * 160 && col < index * 160 + 160 && row > 200 && row < 800
                    ? 220 : UInt8(16 + (row / 8 + col / 8) % 220)
            }
        }
        let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<548 { for col in 0..<968 { uv[row * uvStride + col * 2] = 73; uv[row * uvStride + col * 2 + 1] = 193 } }
        return buffer
    }
}
#endif
