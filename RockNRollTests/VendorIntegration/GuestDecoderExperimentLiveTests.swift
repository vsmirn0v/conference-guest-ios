import ConferenceCore
import UIKit
import XCTest
@testable import RockNRoll

@MainActor final class GuestDecoderExperimentLiveTests: XCTestCase {
    func testHardwareVP9ThenAutomaticSoftwareRecovery() async throws {
        guard VideoToolboxVP9Session.available,
              ProcessInfo.processInfo.environment["ROCKNROLL_EXPERIMENT_HARDWARE_VP9"] == "1",
              let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_CODEC_INVITE"] else {
            throw XCTSkip("Opt-in hardware experiment and authorized room with a VP9 publisher required")
        }
        let target = try JoinTarget.parse(invitation)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        let previous = window.rootViewController, container = UIViewController()
        window.rootViewController = container; window.makeKeyAndVisible()
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore())
        var ready = 0, ended = false
        engine.onEvent = { event in switch event { case .active: ready += 1; case .left, .failed: ended = true; default: break } }
        defer { engine.leave(); window.rootViewController = previous }
        try engine.configure(container: container, networkURL: await VendorEndpointResolver.make().resolve(for: target), displayName: "Decoder QA")
        try engine.join(target: target, displayName: "Decoder QA")
        let deadline = Date().addingTimeInterval(50)
        while !ended, Date() < deadline,
              !VideoDecoderFactoryExperiment.shared.guestEvidence.contains(where: { ($0["hardwareFrames"] as? Int ?? 0) >= 10 }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        let hardware = VideoDecoderFactoryExperiment.shared.guestEvidence
        print("GUEST_VP9_HARDWARE \(hardware)")
        XCTAssertFalse(ended); XCTAssertGreaterThan(ready, 0)
        XCTAssertTrue(hardware.contains { ($0["hardwareFrames"] as? Int ?? 0) >= 10 && $0["verifiedHardwareSession"] as? Bool == true })
        guard !ended, hardware.contains(where: { ($0["hardwareFrames"] as? Int ?? 0) >= 10 }) else { return }
        let before = ready
        VideoDecoderFactoryExperiment.shared.failGuestForTesting()
        var recovered = false
        while !ended && !recovered && Date() < deadline {
            try await Task.sleep(for: .milliseconds(150))
            let stats = await GuestMicrophoneProbe.codecEvidenceForTesting()
            recovered = ready > before && stats.contains { $0["type"] as? String == "inbound-rtp" &&
                $0["mimeType"] as? String == "video/VP9" && $0["decoderImplementation"] as? String == "libvpx" &&
                (($0["framesDecoded"] as? NSNumber)?.intValue ?? 0) >= 10 }
            if recovered { print("GUEST_VP9_SOFTWARE_RECOVERY \(stats)") }
        }
        XCTAssertTrue(recovered); XCTAssertFalse(ended)
    }
}
