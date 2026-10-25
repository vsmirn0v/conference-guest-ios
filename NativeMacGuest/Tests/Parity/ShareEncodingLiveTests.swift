import AppKit
import ConferenceCore
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

/// Disposable synthetic content only: no desktop, camera or microphone capture.
@MainActor final class ShareEncodingLiveTests: XCTestCase {
    func testGuestEfficientAndVP9ContentReachIndependentReceiver() async throws {
        guard ProcessInfo.processInfo.environment["NATIVE_DESKTOP_LIVE_SHARE_ENCODING"] == "1" else {
            throw XCTSkip("Opt in to disposable live sharing codec validation.")
        }
        executionTimeAllowance = 180
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: ShareEncodingPreference.defaultsKey)
        defer {
            if let previous { defaults.set(previous, forKey: ShareEncodingPreference.defaultsKey) }
            else { defaults.removeObject(forKey: ShareEncodingPreference.defaultsKey) }
        }
        let invitation = try await GuestBootstrap.createDisposable(origin: URL(string: "https://salutejazz.ru")!)
        let receiver = NativeGuestEngine(label: "Share codec independent receiver")
        let adapter = NativeDesktopGuestEngine()
        let model = NativeDesktopMeetingModel(destination: try .verified(invitation.invitationURL, engine: .guest),
            name: "Share codec synthetic sender", title: "Share codec validation", engine: adapter)
        var sinks: [(LKRTCVideoTrack, ShareEncodingFrameCounter)] = []
        do {
            try await receiver.join(invitation)
            try await model.connect()
            XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertFalse(model.snapshot.cameraOn)
            try await wait("VP9 server capability") { model.presenter.supportsVP9 }
            // Synthetic concurrent camera exercises the real separate H264
            // sender without accessing the Mac camera or microphone.
            adapter.currentNativeEngine?.cameraCaptureFactory = { NativeDesktopShareCapture(source: $0, canvasOnly: true) }
            try await adapter.setCamera(true)
            try await wait("actual H264 camera RTP") { await self.cameraFrames(adapter) > 5 }
            for preference in [ShareEncodingPreference.efficient, .textDetail, .efficient] {
                let cameraBaseline = await cameraFrames(adapter)
                let workspace = model.presenter
                await workspace.open(); await workspace.chooseCanvas()
                workspace.encodingPreference = preference
                try await workspace.startSharing()
                try await wait("remote shared track") { receiver.incomingVideo.contains { $0.source == "SCREEN_SHARE" } }
                var video = try XCTUnwrap(receiver.incomingVideo.first { $0.source == "SCREEN_SHARE" })
                var counter = ShareEncodingFrameCounter(); video.track.add(counter); sinks.append((video.track, counter))
                try await wait("decoded content frames") { counter.snapshot.frames >= 8 }
                try await wait("measured sender codec") { workspace.encodingReport?.codec == preference.codec }
                let measured = try XCTUnwrap(workspace.encodingReport)
                XCTAssertEqual(measured.codec, preference.codec)
                XCTAssertEqual(workspace.activeEncodingPreference, preference)
                if preference == .textDetail {
                    workspace.encodingPreference = .efficient
                    await workspace.chooseCanvas()
                    XCTAssertNotNil(workspace.contentDraft)
                    try await workspace.applyContentChange()
                    XCTAssertEqual(workspace.activeEncodingPreference, .textDetail)
                    try await wait("VP9 after content replacement") { workspace.encodingReport?.codec == "vp9" }
                    let previousTrack = video.track
                    try await wait("replacement remote shared track") {
                        receiver.incomingVideo.contains { $0.source == "SCREEN_SHARE" && $0.track !== previousTrack }
                    }
                    video = try XCTUnwrap(receiver.incomingVideo.first { $0.source == "SCREEN_SHARE" && $0.track !== previousTrack })
                    counter = ShareEncodingFrameCounter(); video.track.add(counter); sinks.append((video.track, counter))
                    try await wait("replacement decoded VP9 frames") { counter.snapshot.frames >= 8 }
                }
                let state = counter.snapshot
                print("SHARE_ENCODING_LIVE codec=\(measured.codec) implementation=\(measured.implementation.rawValue) decoded=\(state.frames) dimensions=\(state.width)x\(state.height)")
                XCTAssertGreaterThan(state.width, 0); XCTAssertGreaterThan(state.height, 0)
                XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertTrue(model.snapshot.cameraOn)
                try await wait("advancing actual H264 camera alongside content") { await self.cameraFrames(adapter) > cameraBaseline + 5 }
                try await workspace.stopSharing()
                XCTAssertNil(workspace.encodingReport)
                for (track, sink) in sinks { track.remove(sink) }; sinks.removeAll()
                try await wait("remote share retirement") { !receiver.incomingVideo.contains { $0.source == "SCREEN_SHARE" } }
            }
            let senderClean = await model.leave(), receiverClean = await receiver.leave()
            XCTAssertTrue(senderClean); XCTAssertTrue(receiverClean)
        } catch {
            for (track, sink) in sinks { track.remove(sink) }
            _ = await model.leave(); _ = await receiver.leave()
            throw error
        }
    }
    private func cameraFrames(_ adapter: NativeDesktopGuestEngine) async -> Int64 {
        guard let native = adapter.currentNativeEngine, let mid = native.publicationIdentity["mid"],
              let rows = await native.evidence()["stats"] as? [[String: Any]],
              let outbound = rows.first(where: { $0["target"] as? String == "PUBLISHER" &&
                  $0["type"] as? String == "outbound-rtp" && $0["mid"] as? String == mid && $0["kind"] as? String == "video" }),
              let codecID = outbound["codecId"] as? String,
              let mime = rows.first(where: { $0["target"] as? String == "PUBLISHER" && $0["id"] as? String == codecID })?["mimeType"] as? String,
              mime.lowercased() == "video/h264" else { return 0 }
        return (outbound["framesEncoded"] as? NSNumber)?.int64Value ?? 0
    }
    private func wait(_ label: String, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Timed out: \(label)")
        throw NSError(domain: "ShareEncodingLive", code: 1)
    }
}

private final class ShareEncodingFrameCounter: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    struct Snapshot { var frames = 0; var width: Int32 = 0; var height: Int32 = 0 }
    private let lock = NSLock()
    private var value = Snapshot()
    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return value }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        lock.lock(); value.frames += 1; value.width = frame.width; value.height = frame.height; lock.unlock()
    }
}
