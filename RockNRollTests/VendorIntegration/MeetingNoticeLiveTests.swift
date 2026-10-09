import ConferenceCore
import AVFoundation
import UIKit
import WebRTC
import XCTest
@testable import RockNRoll

@MainActor
final class MeetingNoticeLiveTests: XCTestCase {
    func testSustainedCameraPublishingAndHoldRecovery() async throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_CAMERA_INVITE"] else {
            throw XCTSkip("Opt-in authorized camera check")
        }
        let range = CameraRangeEvidence()
        GuestCameraOrientation.observeForTesting { range.check($0, $1) }
        defer { GuestCameraOrientation.observeForTesting(nil) }
        let target = try JoinTarget.parse(invitation)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = try XCTUnwrap(scene.windows.first)
        let original = window.rootViewController, idle = UIApplication.shared.isIdleTimerDisabled
        let container = UIViewController(); window.rootViewController = container; window.makeKeyAndVisible()
        UIApplication.shared.isIdleTimerDisabled = true
        let systemCall = SystemCallCoordinator()
        let callEngine = NativeConferenceEngine(systemCall: systemCall, catchUp: CatchUpStore())
        var active = false, ended = false
        callEngine.onEvent = { event in switch event { case .active: active = true; case .left, .failed: ended = true; default: break } }
        defer { callEngine.leave(); window.rootViewController = original; UIApplication.shared.isIdleTimerDisabled = idle }
        let endpoint = try await VendorEndpointResolver.make().resolve(for: target)
        let name = UserDefaults.standard.string(forKey: "savedDisplayName") ?? "Camera QA"
        try callEngine.configure(container: container, networkURL: endpoint, displayName: name)
        try callEngine.join(target: target, displayName: name)
        let deadline = Date().addingTimeInterval(25)
        while !active && !ended && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(active); guard active && !ended else { return }
        let button = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == L("Start video") })
        button.sendActions(for: .touchUpInside)
        var previous: [String: Int] = [:]
        var previousColors: [String: (inputs: Int, known: Int, callbacks: Int)] = [:]
        let rounds = min(12, max(1, Int(ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_CAMERA_ROUNDS"] ?? "12") ?? 12))
        for round in 0..<rounds {
            try await Task.sleep(for: .seconds(10))
            let streams = await GuestMicrophoneProbe.codecEvidenceForTesting()
            let videos = streams.filter { $0["type"] as? String == "outbound-rtp" && $0["kind"] as? String == "video" &&
                (($0["framesEncoded"] as? NSNumber)?.intValue ?? 0) > 0 }
            XCTAssertFalse(videos.isEmpty)
            for row in videos {
                let id = row["id"] as? String ?? "", frames = (row["framesEncoded"] as? NSNumber)?.intValue ?? 0
                XCTAssertGreaterThan(frames, previous[id, default: 0] + 20)
                previous[id] = frames
                XCTAssertEqual(row["mimeType"] as? String, "video/H264")
                XCTAssertEqual(row["powerEfficientEncoder"] as? Bool, true)
            }
            let colors = GuestH264ColorEncoder.evidenceForTesting()
            XCTAssertTrue(colors.contains { ($0["callbacks"] as? Int ?? 0) > 0 })
            XCTAssertTrue(colors.contains { ($0["knownInputs"] as? Int ?? 0) > 0 }, "Hardware encoder must retain native camera color metadata")
            XCTAssertTrue(colors.contains { ($0["taggedKeyframes"] as? Int ?? 0) > 0 }, "Published keyframes must carry color description")
            for color in colors {
                let id = color["id"] as? String ?? ""
                let current = (inputs: color["inputs"] as? Int ?? 0, known: color["knownInputs"] as? Int ?? 0,
                               callbacks: color["callbacks"] as? Int ?? 0)
                let old = previousColors[id] ?? (inputs: 0, known: 0, callbacks: 0)
                if current.callbacks > old.callbacks {
                    XCTAssertEqual(color["inputType"] as? String, "RTCCVPixelBuffer")
                    XCTAssertEqual(current.known - old.known, current.inputs - old.inputs)
                    let format = (color["inputFormat"] as? NSNumber)?.uint32Value
                    XCTAssertTrue(format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                }
                previousColors[id] = current
            }
            let tracked = callEngine.codecCheckTrackIDsForTesting
            XCTAssertFalse(tracked.isEmpty, "Active H264 publication must keep its watchdog")
            for track in tracked {
                let progress = await GuestMicrophoneProbe.publicationProgress(trackID: track)
                XCTAssertNotNil(progress, "Signalling CID must resolve to the actual live sender and source counters")
                XCTAssertNotNil(GuestCaptureDeviceObserver.rawCaptureProgress(trackID: track), "Camera identity must bind to raw capture before pool backpressure")
            }
            print("CAMERA_PUBLISHING round=\(round) streams=\(videos) colors=\(colors) range=\(range.evidence)")
            XCTAssertFalse(ended)
            if round == 5 {
                systemCall.requestHoldForTesting(true); try await Task.sleep(for: .seconds(2)); systemCall.requestHoldForTesting(false)
                try await Task.sleep(for: .seconds(12)); previous.removeAll()
            }
        }
        XCTAssertGreaterThan(range.verified, 0, "Native rotation must preserve raw Y/U/V distributions")
        XCTAssertEqual(range.mismatched, 0)
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_CAMERA_STALL"] == "1" {
            GuestH264ColorEncoder.dropCallbacksForTesting(true)
            defer { GuestH264ColorEncoder.dropCallbacksForTesting(false) }
            let recoveryDeadline = Date().addingTimeInterval(35)
            var firstRecovered: [String: Int] = [:], recovered = false
            while !recovered && !ended && Date() < recoveryDeadline {
                try await Task.sleep(for: .seconds(2))
                let streams = await GuestMicrophoneProbe.codecEvidenceForTesting()
                for stream in streams where stream["mimeType"] as? String == "video/VP8" && stream["kind"] as? String == "video" {
                    let id = stream["id"] as? String ?? "", frames = (stream["framesEncoded"] as? NSNumber)?.intValue ?? 0
                    if let earlier = firstRecovered[id], frames > earlier + 20 { recovered = true }
                    else if frames > 0 { firstRecovered[id] = frames }
                }
            }
            XCTAssertTrue(recovered, "Sustained lost encoded output must reconnect with working fallback automatically")
            XCTAssertFalse(ended, "Recovery must preserve the meeting view")
            print("CAMERA_STALL_RECOVERY recovered=\(recovered)")
        }
    }
    func testLiveCodecEvidence() async throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_CODEC_INVITE"] else {
            throw XCTSkip("Opt-in authorized codec check")
        }
        let target = try JoinTarget.parse(invitation)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = try XCTUnwrap(scene.windows.first)
        let original = window.rootViewController, idle = UIApplication.shared.isIdleTimerDisabled
        let container = UIViewController(); window.rootViewController = container; window.makeKeyAndVisible()
        UIApplication.shared.isIdleTimerDisabled = true
        let systemCall = SystemCallCoordinator()
        let engine = NativeConferenceEngine(systemCall: systemCall, catchUp: CatchUpStore())
        var active = false, ended = false
        engine.onEvent = { event in switch event { case .active: active = true; case .left, .failed: ended = true; default: break } }
        defer { engine.leave(); window.rootViewController = original; UIApplication.shared.isIdleTimerDisabled = idle }
        let endpoint = try await VendorEndpointResolver.make().resolve(for: target)
        try engine.configure(container: container, networkURL: endpoint, displayName: "Codec QA")
        try engine.join(target: target, displayName: "Codec QA")
        let deadline = Date().addingTimeInterval(25)
        while !active && !ended && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(active); XCTAssertFalse(ended)
        guard active && !ended else { return }
        let camera = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == L("Start video") })
        camera.sendActions(for: .touchUpInside)
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_EARLY_HOLD"] == "1" {
            // Interrupt before the eight-second publisher watchdog expires.
            // A retired/suspended sender must never disable a working codec.
            try await Task.sleep(for: .seconds(2)); systemCall.requestHoldForTesting(true)
            try await Task.sleep(for: .seconds(2)); systemCall.requestHoldForTesting(false)
            try await Task.sleep(for: .seconds(12))
        } else { try await Task.sleep(for: .seconds(8)) }
        let evidence = await GuestMicrophoneProbe.codecEvidenceForTesting()
        let initialFrames = evidence.reduce(into: [String: Int]()) { counts, row in
            if let id = row["id"] as? String, row["type"] as? String == "outbound-rtp" { counts[id] = (row["framesEncoded"] as? NSNumber)?.intValue ?? 0 }
        }
        let data = try JSONSerialization.data(withJSONObject: evidence, options: .sortedKeys)
        print("GUEST_CODEC " + String(decoding: data, as: UTF8.self))
        XCTAssertTrue(evidence.contains { $0["type"] as? String == "outbound-rtp" && $0["kind"] as? String == "video" && (($0["framesEncoded"] as? NSNumber)?.intValue ?? 0) > 10 })
        XCTAssertFalse(ended)
        let hardware = GuestPublishingCodecPolicy.hardwareH264Available
        if hardware {
            XCTAssertTrue(evidence.contains { $0["mimeType"] as? String == "video/H264" && $0["powerEfficientEncoder"] as? Bool == true && (($0["framesEncoded"] as? NSNumber)?.intValue ?? 0) > 10 })
        }
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_ENERGY"] == "1" {
            MediaEnergyBudget.shared.update(lowPower: true, thermal: .nominal)
            defer { MediaEnergyBudget.shared.update(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState) }
            try await Task.sleep(for: .seconds(3))
            let constrained = await GuestMicrophoneProbe.codecEvidenceForTesting()
            print("GUEST_ENERGY_CODEC " + String(decoding: try JSONSerialization.data(withJSONObject: constrained, options: .sortedKeys), as: UTF8.self))
            let device = try XCTUnwrap(GuestCaptureDeviceObserver.currentDevice())
            XCTAssertLessThanOrEqual(1 / CMTimeGetSeconds(device.activeVideoMinFrameDuration), 15.01)
            XCTAssertTrue(constrained.contains { $0["type"] as? String == "outbound-rtp" && $0["kind"] as? String == "video" &&
                (($0["framesEncoded"] as? NSNumber)?.intValue ?? 0) > (initialFrames[$0["id"] as? String ?? ""] ?? 0) + 10 })
        }
        // Recovery replaces the controls; reacquire the current camera button.
        let stopCamera = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == L("Stop video") })
        stopCamera.sendActions(for: .touchUpInside)
        let studio = engine.studioForTesting
        studio.presenter.selectCanvas(); studio.open(.presenter)
        let previewDeadline = Date().addingTimeInterval(4)
        while !studio.presenter.hasPreview && Date() < previewDeadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(studio.presenter.hasPreview)
        await studio.presenter.start()
        let shareDeadline = Date().addingTimeInterval(8)
        while !studio.presenter.running && Date() < shareDeadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(studio.presenter.running)
        for index in 0..<24 {
            studio.presenter.appendAnnotation([CGPoint(x: 0.1, y: Double(index) / 30), CGPoint(x: 0.8, y: Double(index) / 30)])
            try await Task.sleep(for: .milliseconds(250))
        }
        let presenting = await GuestMicrophoneProbe.codecEvidenceForTesting()
        print("GUEST_PRESENTER_CODEC " + String(decoding: try JSONSerialization.data(withJSONObject: presenting, options: .sortedKeys), as: UTF8.self))
        XCTAssertTrue(presenting.contains {
            $0["type"] as? String == "outbound-rtp" && $0["kind"] as? String == "video" &&
            ($0["frameWidth"] as? NSNumber)?.intValue == 1280 && ($0["frameHeight"] as? NSNumber)?.intValue == 720 &&
            (($0["framesEncoded"] as? NSNumber)?.intValue ?? 0) > (initialFrames[$0["id"] as? String ?? ""] ?? 0) + 10
        }, "Presenter must encode fresh frames, not just retain camera counters")
        XCTAssertFalse(ended)
        await studio.presenter.stop()
        if hardware {
            XCTAssertTrue(presenting.contains { $0["mimeType"] as? String == "video/H264" && $0["powerEfficientEncoder"] as? Bool == true &&
                ($0["frameWidth"] as? NSNumber)?.intValue == 1280 && ($0["frameHeight"] as? NSNumber)?.intValue == 720 &&
                (($0["framesEncoded"] as? NSNumber)?.intValue ?? 0) > (initialFrames[$0["id"] as? String ?? ""] ?? 0) + 10 })
        }
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_RECOVERY"] == "1" {
            // Presenter state changes schedule a controls refresh on the main
            // queue. Wait for the camera's ordinary role before interacting.
            let controlDeadline = Date().addingTimeInterval(5)
            while !descendants(window).contains(where: { ($0 as? UIButton)?.accessibilityLabel == L("Start video") }),
                  Date() < controlDeadline { try await Task.sleep(for: .milliseconds(50)) }
            let resumeCamera = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == L("Start video") })
            resumeCamera.sendActions(for: .touchUpInside)
            try await Task.sleep(for: .seconds(3))
            systemCall.requestHoldForTesting(true)
            try await Task.sleep(for: .seconds(2))
            systemCall.requestHoldForTesting(false)
            try await Task.sleep(for: .seconds(12))
            let recovered = await GuestMicrophoneProbe.codecEvidenceForTesting()
            print("GUEST_RECOVERED_CODEC " + String(decoding: try JSONSerialization.data(withJSONObject: recovered, options: .sortedKeys), as: UTF8.self))
            XCTAssertFalse(ended)
            XCTAssertTrue(recovered.contains { $0["type"] as? String == "outbound-rtp" && $0["kind"] as? String == "video" && (($0["framesEncoded"] as? NSNumber)?.intValue ?? 0) > 10 })
            XCTAssertTrue(recovered.contains { $0["type"] as? String == "inbound-rtp" && $0["kind"] as? String == "video" && (($0["framesDecoded"] as? NSNumber)?.intValue ?? 0) > 10 })
            XCTAssertTrue(recovered.contains { $0["type"] as? String == "inbound-rtp" && $0["kind"] as? String == "audio" && (($0["bytesReceived"] as? NSNumber)?.intValue ?? 0) > 0 })
            if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_FALLBACK"] == "1" {
                engine.codecFallbackForTesting()
                try await Task.sleep(for: .seconds(12))
                let fallback = await GuestMicrophoneProbe.codecEvidenceForTesting()
                print("GUEST_FALLBACK_CODEC " + String(decoding: try JSONSerialization.data(withJSONObject: fallback, options: .sortedKeys), as: UTF8.self))
                XCTAssertFalse(ended)
                XCTAssertTrue(fallback.contains { $0["mimeType"] as? String == "video/VP8" && (($0["framesEncoded"] as? NSNumber)?.intValue ?? 0) > 10 })
            }
        }
    }
    func testHeaderInRequestedFavorite() async throws {
        guard let requested = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_NOTICE_FAVORITE"] else {
            throw XCTSkip("Opt-in live favorite meeting check.")
        }
        let favorite = try XCTUnwrap(RoomHistoryStore().rooms.first {
            $0.isStarred && $0.displayTitle.caseInsensitiveCompare(requested) == .orderedSame
        }, "Requested favorite must already exist")
        let target = try JoinTarget.parse(favorite.joinURL.absoluteString)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = try XCTUnwrap(scene.windows.first)
        let original = window.rootViewController
        let container = UIViewController()
        container.view.backgroundColor = .black
        window.rootViewController = container; window.makeKeyAndVisible()
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore())
        defer { engine.leave(); window.rootViewController = original }
        let endpoint = try await VendorEndpointResolver.make().resolve(for: target)
        let name = UserDefaults.standard.string(forKey: "savedDisplayName") ?? "Notice QA"
        try engine.configure(container: container, networkURL: endpoint, displayName: name)
        try engine.join(target: target, displayName: name)
        var header: UIView?
        for _ in 0..<60 {
            header = descendants(window).first { $0.accessibilityIdentifier == "Meeting status" }
            if header?.accessibilityValue?.isEmpty == false { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let identity = try XCTUnwrap(header, "Real meeting header must appear")
        XCTAssertFalse(try XCTUnwrap(identity.accessibilityValue).isEmpty, "Real provider privacy state must be present")
        XCTAssertFalse(descendants(window).contains { $0.accessibilityIdentifier == "Top meeting notices" })
        let viewport = descendants(window).first { $0.accessibilityIdentifier == "Shared screen viewport" }
        if let viewport {
            XCTAssertFalse(identity.convert(identity.bounds, to: window).intersects(viewport.convert(viewport.bounds, to: window)))
        }
        attach(window, name: "Live favorite inline privacy header")
        try await Task.sleep(nanoseconds: 4_500_000_000)
        XCTAssertFalse(try XCTUnwrap(identity.accessibilityValue).isEmpty)
        let more = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }.first {
            $0.menu?.children.contains(where: { $0.title == L("Meeting details") }) == true
        })
        let action = try XCTUnwrap(more.menu?.children.first { $0.title == L("Meeting details") } as? UIAction)
        // The real menu invokes this same header tap target. Do not alter the room.
        XCTAssertEqual(action.title, L("Meeting details"))
        attach(window, name: "Live favorite privacy after notice expiry")
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func attach(_ window: UIWindow, name: String) {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            window.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

/// Check three native frames without retaining images or profiling continuously.
private final class CameraRangeEvidence {
    private let lock = NSLock()
    private var checks = 0, failures = 0
    var verified: Int { lock.lock(); defer { lock.unlock() }; return checks }
    var mismatched: Int { lock.lock(); defer { lock.unlock() }; return failures }
    var evidence: String { lock.lock(); defer { lock.unlock() }; return "verified=\(checks),mismatched=\(failures)" }
    func check(_ source: RTCVideoFrame, _ output: RTCVideoFrame) {
        lock.lock(); defer { lock.unlock() }
        guard checks + failures < 3 else { return }
        guard let original = summary(source), let result = summary(output) else { failures += 1; return }
        if original == result { checks += 1 } else { failures += 1 }
    }
    private func summary(_ frame: RTCVideoFrame) -> [[UInt64]]? {
        guard let native = frame.buffer as? RTCCVPixelBuffer else { return nil }
        let pixels = native.pixelBuffer
        guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let y = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)?.assumingMemoryBound(to: UInt8.self),
              let uv = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        return [plane(y, stride: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0), width: width, height: height),
            plane(uv, stride: CVPixelBufferGetBytesPerRowOfPlane(pixels, 1), width: (width + 1) / 2, height: (height + 1) / 2, step: 2),
            plane(uv.advanced(by: 1), stride: CVPixelBufferGetBytesPerRowOfPlane(pixels, 1), width: (width + 1) / 2, height: (height + 1) / 2, step: 2)]
    }
    private func plane(_ bytes: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int, step: Int = 1) -> [UInt64] {
        var sum: UInt64 = 0, squares: UInt64 = 0
        for row in 0..<height { for column in 0..<width {
            let value = UInt64(bytes[row * stride + column * step]); sum += value; squares += value * value
        } }
        return [UInt64(width * height), sum, squares]
    }
}
