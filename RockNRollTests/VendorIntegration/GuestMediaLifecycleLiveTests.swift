import AVFoundation
import ConferenceCore
import UIKit
import XCTest
import WebRTC
@testable import RockNRoll

@MainActor
final class GuestMediaLifecycleLiveTests: XCTestCase {
    func testNativeSenderCameraContinuesWhileSharing() async throws {
        guard let path = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_NATIVE_SHARE_INVITATION_FILE"] else {
            throw XCTSkip("Requires the coordinated disposable native sender test.")
        }
        executionTimeAllowance = 120
        let target = try JoinTarget.parse(String(contentsOfFile: path, encoding: .utf8))
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow })
        let original = window.rootViewController, container = UIViewController()
        window.rootViewController = container; window.makeKeyAndVisible()
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore())
        var failed = false, left = false
        engine.onEvent = {
            if [.failed, .canceled, .evicted].contains($0) { failed = true }
            if $0 == .left { left = true }
        }
        let camera = LegacyVideoProgress(), share = LegacyVideoProgress()
        var taps: [GuestStreamViews.PinTarget: GuestVideoFrameTap] = [:]
        defer {
            try? Data().write(to: URL(fileURLWithPath: path + ".stop-sharing"))
            taps.values.forEach { $0.invalidate() }; engine.leave(); window.rootViewController = original
        }
        func finish() async {
            engine.leave()
            for _ in 0..<100 where !left { try? await Task.sleep(for: .milliseconds(100)) }
        }
        do {
        try engine.configure(container: container, networkURL: await VendorEndpointResolver.make().resolve(for: target), displayName: "Compatibility camera/share receiver")
        try engine.join(target: target, displayName: "Compatibility camera/share receiver")
        try await wait("legacy receiver media becomes active") { engine.mediaReadyForTesting }
        try await wait("legacy receiver gallery is installed") { engine.streamViewsForTesting.onGalleryPresentation != nil }
        let streams = engine.streamViewsForTesting, previous = engine.streamViewsForTesting.onGalleryPresentation
        var tracedUI = Set<GuestStreamViews.PinTarget>()
        streams.onGalleryPresentation = { items in
            previous?(items)
            let active = Set(items.filter { $0.active && !$0.isLocalCamera && $0.hasVideoSource }.map(\.id))
            for id in taps.keys.filter({ !active.contains($0) }) { taps.removeValue(forKey: id)?.invalidate() }
            for item in items where item.active && !item.isLocalCamera {
                if GuestMediaSubscriptionTrace.enabled, tracedUI.insert(item.id).inserted {
                    print("LEGACY_UI_ID identity=\(GuestMediaSubscriptionTrace.identifier(item.id.participant)) share=\(item.id.isShare) sdkView=\(item.renderer != nil) rtcRenderer=\(item.renderer.flatMap(GuestVideoFrameTap.findRenderer) != nil) directSource=\(item.receiverSource != nil)")
                }
                let matches = item.receiverSource.map { taps[item.id]?.matches($0) == true } ??
                    item.renderer.map { taps[item.id]?.matches($0) == true } ?? false
                guard item.hasVideoSource, !matches else { continue }
                taps.removeValue(forKey: item.id)?.invalidate()
                let counter = item.id.isShare ? share : camera
                if let source = item.receiverSource {
                    taps[item.id] = GuestVideoFrameTap(source: source) { counter.accept($0) }
                } else if let renderer = item.renderer {
                    taps[item.id] = GuestVideoFrameTap(view: renderer) { counter.accept($0) }
                }
            }
        }
        streams.refreshSelection()
        func wait(_ label: String, timeout: TimeInterval = 40, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), !failed, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            guard condition(), !failed else { XCTFail(label); throw NSError(domain: "CompatibilityCameraShare", code: 1) }
        }
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_NATIVE_SHARE_DIRECT_PROBE"] == "1" {
            func retainedTrack() -> RTCVideoTrack? {
                guard let sid = GuestPublishingCodecPolicy.shared.retainedCameraSIDForTesting else { return nil }
                let matches = GuestPeerRegistry.snapshot().filter { $0.connectionState != .closed }.flatMap { peer in
                    peer.transceivers.filter { !$0.isStopped }.compactMap { $0.receiver.track as? RTCVideoTrack }
                }.filter { $0.trackId == sid }
                return matches.count == 1 ? matches.first : nil
            }
            try await wait("exact retained camera receiver exists") { retainedTrack() != nil }
            let track = try XCTUnwrap(retainedTrack()), direct = LegacyDirectVideoProgress()
            let enabled = track.isEnabled
            track.add(direct)
            try await Task.sleep(for: .seconds(5))
            print("LEGACY_DIRECT_DIAGNOSTIC enabled=\(enabled) frames=\(direct.progress.frames) sdkFrames=\(camera.frames) size=\(direct.size)")
            await captureIncomingVideoTrace("direct-diagnostic")
            track.remove(direct)
            XCTAssertEqual(track.isEnabled, enabled)
        }
        try await wait("legacy receiver initially decodes native camera") { camera.frames > 8 }
        await captureIncomingVideoTrace("before-share")
        try Data().write(to: URL(fileURLWithPath: path + ".ready"))
        try await wait("legacy receiver decodes native screen share") {
            FileManager.default.fileExists(atPath: path + ".sharing") && share.frames > 8
        }
        await captureIncomingVideoTrace("after-share")
        for phase in 0..<3 {
            let baseline = camera.frames
            try await Task.sleep(for: .seconds(2))
            XCTAssertGreaterThan(camera.frames, baseline + 5, "Legacy camera stalled while native screen sharing, phase \(phase)")
            print("LEGACY_CAMERA_SHARE phase=\(phase) advancingCamera=\(camera.frames - baseline) shareFrames=\(share.frames)")
        }
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_NATIVE_SHARE_LIFECYCLE"] == "1" {
            let companion = try XCTUnwrap(descendants(window).compactMap { $0 as? PresenterCompanionView }.first)
            companion.setCollapsed(true)
            try await Task.sleep(for: .seconds(1))
            companion.setCollapsed(false)
            let expanded = camera.frames
            try await wait("presenter camera resumes after companion re-expansion", timeout: 10) { camera.frames > expanded + 8 }
            print("LEGACY_CAMERA_REEXPANDED advancingCamera=\(camera.frames - expanded)")
        }
        try Data().write(to: URL(fileURLWithPath: path + ".stop-sharing"))
        try await wait("native sender stops sharing") {
            FileManager.default.fileExists(atPath: path + ".share-stopped")
        }
        let afterSharing = camera.frames
        try await wait("legacy camera keeps decoding after sharing ends") { camera.frames > afterSharing + 8 }
        print("LEGACY_CAMERA_AFTER_SHARE advancingCamera=\(camera.frames - afterSharing)")
        await captureIncomingVideoTrace("after-observation")
        } catch { await captureIncomingVideoTrace("failure"); await finish(); throw error }
        await finish()
    }
    private func captureIncomingVideoTrace(_ phase: String) async {
        guard GuestMediaSubscriptionTrace.enabled else { return }
        var peers: [[String: Any]] = []
        for peer in GuestPeerRegistry.snapshot().filter({ $0.connectionState != .closed }).prefix(4) {
            var row: [String: Any] = ["peer": String(ObjectIdentifier(peer).hashValue), "connection": peer.connectionState.rawValue]
            row["transceivers"] = peer.transceivers.prefix(32).map { transceiver -> [String: Any] in
                var value: [String: Any] = ["direction": transceiver.direction.rawValue, "stopped": transceiver.isStopped]
                var direction: RTCRtpTransceiverDirection = .inactive
                if transceiver.currentDirection(&direction) { value["currentDirection"] = direction.rawValue }
                if let numeric = Int(transceiver.mid) { value["mid"] = numeric }
                if let track = transceiver.receiver.track {
                    value["track"] = GuestMediaSubscriptionTrace.identifier(track.trackId)
                    value["enabled"] = track.isEnabled
                    value["readyState"] = track.readyState.rawValue
                    value["video"] = track.kind == "video"
                }
                return value
            }
            if let sdp = peer.remoteDescription?.sdp { row["remote"] = GuestMediaSubscriptionTrace.videoSections(sdp) }
            if let sdp = peer.localDescription?.sdp { row["local"] = GuestMediaSubscriptionTrace.videoSections(sdp) }
            let report: RTCStatisticsReport = await withCheckedContinuation { completion in
                peer.statistics { completion.resume(returning: $0) }
            }
            row["inbound"] = report.statistics.values.filter {
                $0.type == "inbound-rtp" && ($0.values["kind"] as? String == "video" || $0.values["mediaType"] as? String == "video")
            }.prefix(32).map { statistic -> [String: Any] in
                var value: [String: Any] = ["id": GuestMediaSubscriptionTrace.identifier(statistic.id)]
                for key in ["packetsReceived", "bytesReceived", "framesReceived", "framesDecoded", "framesDropped", "keyFramesDecoded", "frameWidth", "frameHeight", "framesPerSecond", "pliCount", "nackCount"] {
                    if let number = statistic.values[key] as? NSNumber { value[key] = number }
                }
                if let mid = statistic.values["mid"] as? String, let numeric = Int(mid) { value["mid"] = numeric }
                if let track = statistic.values["trackIdentifier"] as? String { value["track"] = GuestMediaSubscriptionTrace.identifier(track) }
                return value
            }
            peers.append(row)
        }
        let result: [String: Any] = ["phase": phase, "uptime": ProcessInfo.processInfo.systemUptime, "peers": peers]
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return }
        print("LEGACY_RTC_TRACE \(text)")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Legacy receive state \(phase)"; attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testMicrophoneTogglesAcrossRooms() async throws {
        #if targetEnvironment(simulator)
        try await exercise(camera: false)
        #else
        throw XCTSkip("The real-camera case also covers microphone; initialize the SDK only once per process")
        #endif
    }
    func testCameraAndMicrophoneTogglesAcrossRooms() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a real camera")
        #else
        try await exercise(camera: true)
        #endif
    }
    private func exercise(camera: Bool) async throws {
        guard let first = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_LIFECYCLE_INVITE"],
              let second = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SECOND_INVITE"] else {
            throw XCTSkip("Requires two authorized guest test rooms")
        }
        for media: AVMediaType in camera ? [.audio, .video] : [.audio] {
            if AVCaptureDevice.authorizationStatus(for: media) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: media)
            }
            guard AVCaptureDevice.authorizationStatus(for: media) == .authorized else {
                throw XCTSkip("Live capture requires \(media.rawValue) permission for this development build")
            }
        }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow })
        let original = window.rootViewController, container = UIViewController()
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        window.rootViewController = container; window.makeKeyAndVisible()
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore())
        var active = false, left = false, failed = false
        engine.onEvent = { event in
            if event == .active { active = true }
            if event == .left { left = true }
            if [.failed, .canceled, .evicted].contains(event) { failed = true }
        }
        defer {
            engine.leave(); window.rootViewController = original
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(45)
            while !condition(), !failed, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            guard !failed, condition() else {
                XCTFail("Timed out: \(label); failed=\(failed)")
                throw NSError(domain: "GuestMediaLifecycle", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out: \(label); failed=\(failed)"])
            }
        }
        func press(_ label: String) throws {
            let button = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == L(label) && isVisible($0) && $0.isEnabled }, label)
            button.sendActions(for: .touchUpInside)
        }
        // Leave before the asynchronous audio preparation creates a call owner.
        let pending = try JoinTarget.parse(first)
        try engine.configure(container: container, networkURL: await VendorEndpointResolver.make().resolve(for: pending), displayName: "Lifecycle QA")
        try engine.join(target: pending, displayName: "Lifecycle QA")
        engine.leave()
        try await wait("pending join retired") { left && !engine.hasJoinStarted }
        // Keep the SDK initialized, as it is when the user follows multiple links.
        for (index, invite) in [first, second, first, second].enumerated() {
            active = false; left = false
            let target = try JoinTarget.parse(invite)
            try engine.configure(container: container,
                networkURL: await VendorEndpointResolver.make().resolve(for: target), displayName: "Lifecycle QA")
            try engine.join(target: target, displayName: "Lifecycle QA")
            try await wait("room \(index) connected") { active && engine.studioForTesting.enableMicrophone != nil }
            let studio = engine.studioForTesting
            print("GUEST_MEDIA_PERMISSION video=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue) audio=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) state=\(UIApplication.shared.applicationState.rawValue)")
            var previousPreview: CameraCapturePreview?
            var previousGeneration: UUID?
            XCTAssertFalse(studio.microphoneOn); XCTAssertFalse(studio.cameraOn)
            for cycle in 0..<6 {
                try press("Unmute microphone")
                if camera { try press("Start video") }
                try await wait("media enabled") { studio.microphoneOn && (!camera || studio.cameraOn) }
                if camera {
                    try await wait("capture running") { GuestCaptureDeviceObserver.currentSource() != nil }
                    let source = try XCTUnwrap(GuestCaptureDeviceObserver.currentSource())
                    let preview = try XCTUnwrap(GuestCaptureDeviceObserver.cameraPreview())
                    XCTAssertTrue(preview.session.isRunning)
                    XCTAssertNotEqual(source.generation, previousGeneration)
                    XCTAssertFalse(preview === previousPreview, "A restarted capture needs a fresh frame feed")
                    previousPreview = preview; previousGeneration = source.generation
                    print("GUEST_MEDIA_CYCLE room=\(index) cycle=\(cycle) source=\(source.generation)")
                }
                try await Task.sleep(for: .milliseconds(400))
                try press("Mute microphone")
                if camera { try press("Stop video") }
                try await wait("media disabled") { !studio.microphoneOn && !studio.cameraOn }
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertFalse(left); XCTAssertFalse(failed)
            }
            // Also exercise leaving with capture still live, before the next join.
            if camera {
                try press("Start video")
                try await wait("camera enabled before Leave") { studio.cameraOn }
            }
            engine.leave()
            try await wait("room \(index) left") { left }
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertNil(GuestCaptureDeviceObserver.currentSource())
            print("GUEST_MEDIA_ROOM_LEFT room=\(index) camera=\(camera)")
        }
    }
    private func isVisible(_ view: UIView) -> Bool {
        var node: UIView? = view
        while let current = node {
            if current.isHidden || current.alpha <= 0.01 { return false }
            node = current.superview
        }
        return view.window != nil
    }
    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

private final class LegacyVideoProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTimestamp: Int64 = -1, count = 0
    var frames: Int { lock.lock(); defer { lock.unlock() }; return count }
    func accept(_ frame: RTCVideoFrame) {
        lock.lock(); defer { lock.unlock() }
        guard frame.timeStampNs > lastTimestamp else { return }
        lastTimestamp = frame.timeStampNs; count += 1
    }
}

private final class LegacyDirectVideoProgress: NSObject, RTCVideoRenderer {
    let progress = LegacyVideoProgress()
    private let lock = NSLock()
    private var dimensions = "none"
    var size: String { lock.lock(); defer { lock.unlock() }; return dimensions }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        progress.accept(frame)
        lock.lock(); dimensions = "\(frame.width)x\(frame.height)"; lock.unlock()
    }
}
