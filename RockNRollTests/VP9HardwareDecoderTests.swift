import ConferenceCore
import Foundation
import LiveKitWebRTC
import XCTest
@testable import RockNRoll

@MainActor final class VP9HardwareDecoderTests: XCTestCase {
    private func fixtures() throws -> [VP9Fixture] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "vp9-lossless", withExtension: "json"))
        return try JSONDecoder().decode([VP9Fixture].self, from: Data(contentsOf: url))
    }
    func testKeyFrameHeaderRangeDimensionsAndBounds() throws {
        let fixtures = try fixtures()
        for (index, fixture) in fixtures.enumerated() {
            let data = try XCTUnwrap(fixture.frames.first).data
            let format = try XCTUnwrap(VP9VideoFormat.keyFrame(data))
            XCTAssertEqual(format.width, fixture.width); XCTAssertEqual(format.height, fixture.height)
            XCTAssertEqual(format.profile, 0); XCTAssertEqual(format.bitDepth, 8)
            XCTAssertEqual(format.fullRange, index == 1); XCTAssertTrue(format.hardwareCompatible)
            XCTAssertNotNil(format.description())
            for count in 0..<9 { XCTAssertNil(VP9VideoFormat.keyFrame(Data(data.prefix(count)))) }
            XCTAssertNil(VP9VideoFormat.keyFrame(try XCTUnwrap(fixture.frames.last).data))
        }
        XCTAssertFalse(VP9VideoFormat(profile: 2, bitDepth: 10, colorSpace: 2, fullRange: false, width: 640, height: 360).hardwareCompatible)
        XCTAssertFalse(VP9VideoFormat(profile: 0, bitDepth: 8, colorSpace: 2, fullRange: false, width: 65536, height: 65536).hardwareCompatible)
        XCTAssertFalse(VP9VideoFormat(profile: 0, bitDepth: 8, colorSpace: 2, fullRange: false, width: 0, height: 360).hardwareCompatible)
        XCTAssertNil(VP9VideoFormat.keyFrame(Data(repeating: 255, count: 30)))
    }
    func testFallbackPolicyOnlyNotifiesOnceAndRejectsRetiredGeneration() async throws {
        let policy = NativeVideoDecoderPolicy(), current = policy.beginCall()
        let notification = expectation(description: "Single fallback notification")
        notification.assertForOverFulfill = true
        let observation = NotificationCenter.default.addObserver(forName: NativeVideoDecoderPolicy.fallbackNotification, object: policy, queue: .main) { _ in notification.fulfill() }
        defer { NotificationCenter.default.removeObserver(observation) }
        policy.fallBack(generation: UUID()); XCTAssertTrue(policy.snapshot.enabled)
        policy.fallBack(generation: current); policy.fallBack(generation: current)
        XCTAssertFalse(policy.snapshot.enabled)
        await fulfillment(of: [notification], timeout: 2)
        let next = policy.beginCall(); XCTAssertNotEqual(next, current)
        policy.fallBack(generation: current); XCTAssertTrue(policy.snapshot.enabled)
    }
    func testFactoryKeepsExistingCodecsAndSimulatorSoftwarePath() {
        let factory = NativeVideoDecoderFactory()
        XCTAssertEqual(factory.supportedCodecs().map(\.name), LKRTCDefaultVideoDecoderFactory().supportedCodecs().map(\.name))
        XCTAssertFalse(factory.createDecoder(LKRTCVideoCodecInfo(name: "VP9", parameters: ["profile-id": "2"])) is VP9HardwareDecoder)
        #if targetEnvironment(simulator)
        XCTAssertFalse(VP9HardwareDecoder.available)
        let codec = LKRTCVideoCodecInfo(name: "VP9", parameters: ["profile-id": "0"])
        XCTAssertFalse(factory.createDecoder(codec) is VP9HardwareDecoder)
        #endif
    }
    func testNativeFallbackStatusIsStickyAndDoesNotChangeMeetingPolicy() throws {
        let fixture = try XCTUnwrap(try fixtures().first)
        let image = try XCTUnwrap(fixture.frames.first).image(timestamp: 90_000)
        let decoder = VP9HardwareDecoder()
        let policy = NativeVideoDecoderPolicy.shared
        let before = policy.snapshot
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 2), 0)
        decoder.setCallback { _ in }
        let initialStatus = decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0)
        if initialStatus == 0 {
            // Corrupt a delta frame after a valid key frame so VideoToolbox
            // produces a permanent decode error, without touching the meeting.
            image.frameType = .videoFrameDelta; image.buffer = Data(repeating: 255, count: 80)
            XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -13)
        } else { XCTAssertEqual(initialStatus, -13) }
        XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -13)
        XCTAssertEqual(policy.snapshot.generation, before.generation)
        XCTAssertEqual(policy.snapshot.enabled, before.enabled)
        XCTAssertEqual(decoder.release(), 0)
        XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -1)
    }
    /// An opt-in acceptance gate, not a default CI assertion that this hardware
    /// supports SVC. The base-only stream isolates ordinary VP9 from the same
    /// encoder's three-spatial-layer stream, with independent reference pixels.
    func testLayeredHardwareQualification() throws {
        guard VP9HardwareDecoder.available,
              ProcessInfo.processInfo.environment["ROCKNROLL_TEST_VP9_SVC"] == "1" else {
            throw XCTSkip("Opt-in physical hardware SVC qualification")
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "vp9-svc", withExtension: "json"))
        let fixtures = try JSONDecoder().decode([VP9Fixture].self, from: Data(contentsOf: url))
        for fixture in fixtures {
            let core = VideoToolboxVP9Session()
            var exact = 0, failed = 0
            for (index, frame) in fixture.frames.enumerated() {
                switch core.decode(frame.data, keyFrame: frame.key, timestamp: UInt32(index * 9000)) {
                case let .frame(buffer):
                    if let buffer {
                        let decoded = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 0)
                        if VP9Fixture.digest(decoded) == frame.sha256 { exact += 1 }
                    }
                case .failure: failed += 1
                case .waitingForKeyFrame: break
                }
            }
            print("VP9_SVC_QUALIFICATION width=\(fixture.width) height=\(fixture.height) exact=\(exact) required=\(fixture.frames.count) failures=\(failed) hardware=\(core.verifiedHardwareSession)")
            XCTAssertEqual(exact, fixture.frames.count, "All layers must decode correctly before enabling the new SDK decoder")
        }
    }
    func testDecodedPixelsResolutionChangeRTPRotationAndRelease() throws {
        guard VP9HardwareDecoder.available else { throw XCTSkip("Hardware VP9 decoder required") }
        let fixtures = try fixtures()
        var failures = 0, count = 0, expected = "", timestamp: UInt32 = UInt32.max - 3000
        let decoder = VP9HardwareDecoder { failures += 1 }
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 2), 0)
        decoder.setCallback { frame in
            XCTAssertEqual(VP9Fixture.digest(frame), expected)
            XCTAssertEqual(frame.rotation, ._90); XCTAssertEqual(frame.timeStamp, Int32(bitPattern: timestamp))
            count += 1
        }
        for fixture in fixtures {
            for frame in fixture.frames {
                expected = frame.sha256
                XCTAssertEqual(decoder.decode(frame.image(timestamp: timestamp), missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), 0)
                timestamp &+= 6000
            }
        }
        XCTAssertEqual(count, 16); XCTAssertEqual(failures, 0)
        XCTAssertEqual(decoder.evidenceForTesting["verifiedHardwareSession"] as? Bool, true)
        XCTAssertEqual(decoder.release(), 0)
        let image = fixtures[0].frames[0].image(timestamp: 90_000)
        XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -1)
        XCTAssertEqual(count, 16)
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 2), 0)
        var restarted = 0; decoder.setCallback { _ in restarted += 1 }
        XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), 0)
        XCTAssertEqual(restarted, 1)
        // A hardware decode error requests one software recovery, then rejects
        // further frames without emitting callbacks from the failed session.
        image.frameType = .videoFrameDelta; image.buffer = Data(repeating: 255, count: 80)
        XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -1)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -1)
        XCTAssertEqual(failures, 1); XCTAssertEqual(decoder.release(), 0)
    }
    func testPhysicalTelemostHardwareThenAutomaticSoftwareRecovery() async throws {
        guard VP9HardwareDecoder.available,
              let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TELEMOST_INVITE"] else { throw XCTSkip("Hardware and authorized room with a VP9 publisher required") }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        let previous = window.rootViewController, container = UIViewController(); window.rootViewController = container
        defer { window.rootViewController = previous }
        let engine = TelemostCallEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), chat: ChatStore())
        var readyCount = 0, ended = false
        engine.onEvent = { event in switch event { case .active: readyCount += 1; case .left, .failed: ended = true; default: break } }
        defer { engine.leave() }
        try engine.join(target: TelemostTarget.parse(invitation), name: "Hardware VP9 QA", container: container, quiet: false)
        let deadline = Date().addingTimeInterval(45)
        while NativeVideoDecoderFactory.evidenceForTesting.allSatisfy({ ($0["hardwareFrames"] as? Int ?? 0) < 10 }), !ended, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        let hardware = NativeVideoDecoderFactory.evidenceForTesting
        print("VP9_DEVICE_HARDWARE \(hardware)")
        XCTAssertFalse(ended); XCTAssertGreaterThan(readyCount, 0)
        XCTAssertTrue(hardware.contains { ($0["hardwareFrames"] as? Int ?? 0) >= 10 && $0["verifiedHardwareSession"] as? Bool == true })
        func waitForHardware(after previousReady: Int) async throws {
            while !ended && Date() < deadline {
                if readyCount > previousReady && NativeVideoDecoderFactory.evidenceForTesting.contains(where: {
                    ($0["hardwareFrames"] as? Int ?? 0) >= 10 && $0["verifiedHardwareSession"] as? Bool == true
                }) { return }
                try await Task.sleep(for: .milliseconds(200))
            }
            XCTFail("Hardware video did not recover within the bounded test")
        }
        let beforeNetwork = readyCount
        engine.interruptForTesting(); try await waitForHardware(after: beforeNetwork)
        print("VP9_DEVICE_NETWORK_RECOVERY \(NativeVideoDecoderFactory.evidenceForTesting)")
        let beforeHold = readyCount
        try await engine.setTransferHeld(true, restoreSending: true)
        try await Task.sleep(for: .seconds(1))
        try await engine.setTransferHeld(false, restoreSending: true)
        try await waitForHardware(after: beforeHold)
        print("VP9_DEVICE_HOLD_RECOVERY \(NativeVideoDecoderFactory.evidenceForTesting)")
        let beforeFallback = readyCount
        NativeVideoDecoderFactory.failForTesting()
        var recovered = false
        while !ended && !recovered && Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
            let streams = await engine.codecEvidenceForTesting()
            recovered = readyCount > beforeFallback && streams.contains { $0["mimeType"] as? String == "video/VP9" && $0["decoderImplementation"] as? String == "libvpx" && (($0["framesDecoded"] as? NSNumber)?.intValue ?? 0) >= 10 }
            if recovered { print("VP9_DEVICE_SOFTWARE_RECOVERY \(streams)") }
        }
        XCTAssertTrue(recovered); XCTAssertFalse(ended)
        XCTAssertFalse(engine.microphoneSendingForTesting)
    }
}
