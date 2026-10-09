import ConferenceCore
import AVFoundation
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class MeetingNoticeLiveTests: XCTestCase {
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
        try await Task.sleep(for: .seconds(8))
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
        camera.sendActions(for: .touchUpInside)
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
            (($0["framesEncoded"] as? NSNumber)?.intValue ?? 0) > (initialFrames[$0["id"] as? String ?? ""] ?? 0) + 10
        }, "Presenter must encode fresh frames, not just retain camera counters")
        XCTAssertFalse(ended)
        await studio.presenter.stop()
        if hardware {
            XCTAssertTrue(presenting.contains { $0["mimeType"] as? String == "video/H264" && $0["powerEfficientEncoder"] as? Bool == true &&
                (($0["framesEncoded"] as? NSNumber)?.intValue ?? 0) > (initialFrames[$0["id"] as? String ?? ""] ?? 0) + 10 })
        }
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_RECOVERY"] == "1" {
            camera.sendActions(for: .touchUpInside)
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
