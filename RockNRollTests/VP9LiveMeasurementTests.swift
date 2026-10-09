#if DEBUG
import ConferenceCore
import UIKit
import XCTest
@testable import RockNRoll

/// Real native decoder callbacks require a peer connection, not the Objective-C
/// wrapped-native decoder's placeholder methods. Use the same remote VP9 source.
@MainActor final class VP9LiveMeasurementTests: XCTestCase {
    func testMatchedIncomingDecoderEnergy() async throws {
        guard VP9HardwareDecoder.available, let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TELEMOST_INVITE"],
              ProcessInfo.processInfo.environment["ROCKNROLL_MEASURE_VP9"] == "1" else { throw XCTSkip("Opt-in live physical decoder measurement") }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        let original = window.rootViewController, idle = UIApplication.shared.isIdleTimerDisabled
        let container = UIViewController(); window.rootViewController = container; UIApplication.shared.isIdleTimerDisabled = true
        defer { window.rootViewController = original; UIApplication.shared.isIdleTimerDisabled = idle }
        let modes = ProcessInfo.processInfo.environment["ROCKNROLL_MEASURE_REVERSE"] == "1" ? ["software", "hardware"] : ["hardware", "software"]
        for (index, mode) in modes.enumerated() {
            let engine = TelemostCallEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), chat: ChatStore())
            var active = false, ended = false
            engine.onEvent = { event in switch event { case .active: active = true; case .left, .failed: ended = true; default: break } }
            defer { engine.leave() }
            try engine.join(target: TelemostTarget.parse(invitation), name: "Decoder energy qualification", container: container, quiet: false)
            let deadline = Date().addingTimeInterval(30)
            while !active && !ended && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertTrue(active); XCTAssertFalse(ended)
            try await ready(engine, hardware: true)
            if mode == "software" { NativeVideoDecoderFactory.failForTesting(); try await ready(engine, hardware: false) }
            if index == 0 { print("CODEC_MEASURE_WAIT trace-start"); try await Task.sleep(for: .seconds(8)) }
            else { try await Task.sleep(for: .seconds(8)) }
            let before = try await video(engine, hardware: mode == "hardware")
            let start = ProcessInfo.processInfo.systemUptime, wall = Date().timeIntervalSince1970, cpu = processCPU()
            let thermal = ProcessInfo.processInfo.thermalState.rawValue
            print("CODEC_MEASURE_BEGIN \(mode) wall=\(wall)")
            try await Task.sleep(for: .seconds(12))
            let after = try await video(engine, hardware: mode == "hardware")
            let elapsed = ProcessInfo.processInfo.systemUptime - start, count = number(after, "framesDecoded") - number(before, "framesDecoded")
            let row: [String: Any] = ["mode": mode, "width": number(after, "frameWidth"), "height": number(after, "frameHeight"),
                "frames": count, "elapsed_s": elapsed, "process_cpu_percent": (processCPU() - cpu) / elapsed * 100,
                "mean_decode_ms": (number(after, "totalDecodeTime") - number(before, "totalDecodeTime")) / max(1, count) * 1000,
                "wall_start_s": wall, "wall_end_s": Date().timeIntervalSince1970, "brightness": UIScreen.main.brightness,
                "thermal_before": thermal, "thermal_after": ProcessInfo.processInfo.thermalState.rawValue,
                "hardware": NativeVideoDecoderFactory.evidenceForTesting]
            print("CODEC_MEASURE_END " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: .sortedKeys), as: UTF8.self))
            XCTAssertGreaterThan(count, 100); XCTAssertFalse(ended)
            XCTAssertFalse(engine.microphoneSendingForTesting)
            engine.leave(); try await Task.sleep(for: .milliseconds(500))
        }
    }
    private func ready(_ engine: TelemostCallEngine, hardware: Bool) async throws {
        let end = Date().addingTimeInterval(20)
        while Date() < end {
            if let row = try? await video(engine, hardware: hardware), number(row, "framesDecoded") >= 20 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "DecoderMeasurementReadiness", code: 1)
    }
    private func video(_ engine: TelemostCallEngine, hardware: Bool) async throws -> [String: Any] {
        let rows = await engine.codecEvidenceForTesting()
        guard let row = rows.first(where: { row in
            row["type"] as? String == "inbound-rtp" && row["mimeType"] as? String == "video/VP9" &&
            (hardware ? row["decoderImplementation"] as? String == "VideoToolbox VP9" : (row["decoderImplementation"] as? String)?.hasPrefix("libvpx") == true)
        }) else { throw NSError(domain: "DecoderMeasurementReadiness", code: 2) }
        guard number(row, "frameWidth") == 1280 && number(row, "frameHeight") == 720 else {
            throw NSError(domain: "DecoderMeasurementReadiness", code: 3)
        }
        return row
    }
    private func number(_ row: [String: Any], _ key: String) -> Double { (row[key] as? NSNumber)?.doubleValue ?? 0 }
    private func processCPU() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }
}
#endif
