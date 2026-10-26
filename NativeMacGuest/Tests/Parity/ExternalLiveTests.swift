import AVFoundation
import AppKit
import ConferenceCore
import CoreImage
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

private enum ExternalLiveFailure: Error { case deadline, mediaAction(String) }

/// Explicitly opt in with NATIVE_DESKTOP_LIVE_TELEMOST_INVITE,
/// NATIVE_DESKTOP_LIVE_TRUECONF_INVITE or NATIVE_DESKTOP_LIVE_ROCK_INVITE.
/// No invitation defaults, UI automation, chat messages or recording are used.
@MainActor final class ExternalLiveTests: XCTestCase {
    private enum Provider: String { case telemost, trueconf, rock }
    private let environment = ProcessInfo.processInfo.environment
    private var evidence: [String: Any] = [:]
    private var deadline = Date.distantPast

    func testTelemostLiveParity() async throws { try await exercise(.telemost) }
    func testTrueConfLiveParity() async throws { try await exercise(.trueconf) }
    func testRockLiveParity() async throws { try await exercise(.rock) }

    func testTelemostLiveSharingParity() async throws { try await exercise(.telemost, microphoneCheck: false) }
    func testTrueConfLiveSharingParity() async throws { try await exercise(.trueconf, microphoneCheck: false) }

    private func exercise(_ provider: Provider, microphoneCheck: Bool = true) async throws {
        let key = "NATIVE_DESKTOP_LIVE_" + provider.rawValue.uppercased() + "_INVITE"
        guard let invitation = environment[key], !invitation.isEmpty else {
            throw XCTSkip("Set \(key) to opt in to this live provider test.")
        }
        guard let url = URL(string: invitation), url.scheme == "https" else {
            XCTFail("\(key) must contain a complete HTTPS invitation"); return
        }
        let requiredMedia: [AVMediaType] = microphoneCheck ? [.audio, .video] : [.video]
        for media in requiredMedia where AVCaptureDevice.authorizationStatus(for: media) == .notDetermined {
            let _: Bool = try await guestAwait(timeout: 30) { done in
                AVCaptureDevice.requestAccess(for: media) { done(.success($0)) }
            }
        }
        guard requiredMedia.allSatisfy({ AVCaptureDevice.authorizationStatus(for: $0) == .authorized }) else {
            throw XCTSkip("Grant this native app the required capture access before running live media checks (microphone=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue), camera=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)).")
        }
        let cameraKey = "nativeDesktop.cameraID", previousCamera = UserDefaults.standard.object(forKey: cameraKey)
        let selectedID = environment["NATIVE_DESKTOP_LIVE_CAMERA_ID"] ??
            UserDefaults.standard.string(forKey: cameraKey).flatMap { $0.isEmpty ? nil : $0 } ??
            AVCaptureDevice.default(for: .video)?.uniqueID
        guard let selectedID else { throw XCTSkip("No physical camera is available for selected-camera verification.") }
        UserDefaults.standard.set(selectedID, forKey: cameraKey)
        defer {
            if let previousCamera { UserDefaults.standard.set(previousCamera, forKey: cameraKey) }
            else { UserDefaults.standard.removeObject(forKey: cameraKey) }
        }
        let engine: any NativeDesktopMeetingEngine
        switch provider {
        case .telemost: engine = NativeDesktopTelemostEngine()
        case .trueconf: engine = NativeDesktopTrueConfEngine()
        case .rock: engine = NativeDesktopRockEngine(collectStatistics: true)
        }
        let kind: MeetingEngineKind = switch provider {
        case .telemost: .telemost
        case .trueconf: .trueconf
        case .rock: .community
        }
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: kind),
            name: environment["NATIVE_DESKTOP_LIVE_NAME"] ?? "Native Parity Probe",
            title: "External live parity", engine: engine)
        executionTimeAllowance = 180
        let started = Date(); deadline = started.addingTimeInterval(140)
        evidence = ["provider": provider.rawValue, "requestedCameraID": selectedID,
            "facade": "NativeDesktopMeetingModel", "shareSource": "app synthetic canvas",
            "remoteRenderingObserved": false, "limits": ["Local RTP statistics cannot prove remote decoding or rendering."]]
        var cameraProbe: (LKRTCVideoTrack, ExternalLiveFrameCounter)?
        do {
            try await bounded(35) { try await model.connect() }
            try await wait(15) { model.connected }
            try await drain(model, seconds: 5)
            XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertFalse(model.snapshot.cameraOn)
            XCTAssertTrue(model.snapshot.playoutOn)
            evidence["initialConnectedMuted"] = !model.snapshot.microphoneOn && !model.snapshot.cameraOn
            let playout = model.snapshot.playoutOn
            if microphoneCheck {
                model.toggleMicrophone(); try await drain(model, seconds: 12)
                try await wait(8) { model.snapshot.microphoneOn }
                XCTAssertEqual(model.snapshot.playoutOn, playout)
                let playoutWithMicrophone = model.snapshot.playoutOn
                try await Task.sleep(for: .milliseconds(750))
                model.toggleMicrophone(); try await drain(model, seconds: 10)
                try await wait(5) { !model.snapshot.microphoneOn }
                XCTAssertEqual(model.snapshot.playoutOn, playout)
                evidence["microphoneTogglePreservedPlayoutIntent"] = playoutWithMicrophone == playout && model.snapshot.playoutOn == playout
            } else { evidence["microphoneCheck"] = "Not requested; sharing-only acceptance keeps microphone off." }

            model.toggleCamera(); try await drain(model, seconds: 20)
            try await wait(10) { model.snapshot.cameraOn && model.localCamera != nil }
            let cameraID: String?
            if let rock = engine as? NativeDesktopRockEngine { cameraID = rock.liveMediaEvidence.cameraDeviceID }
            else if let session = engine as? NativeDesktopExternalSession {
                cameraID = try await bounded(5) { await session.publisher?.selectedCameraDeviceIDForTesting() }
            }
            else { cameraID = nil }
            evidence["actualCameraID"] = cameraID ?? "unavailable"
            XCTAssertEqual(cameraID, selectedID, "The capture device readback must match the selected camera.")
            let cameraFrames = ExternalLiveFrameCounter()
            if let cameraTrack = model.localCamera {
                try await bounded(5) { await Task.detached { cameraTrack.add(cameraFrames) }.value }
                cameraProbe = (cameraTrack, cameraFrames)
            }
            try await wait(6) { cameraFrames.frames > 0 }
            evidence["cameraFrames"] = cameraFrames.frames
            let cameraBeforeHold = cameraFrames.frames
            try await visualHold(provider, stage: "camera")
            evidence["cameraFramesAfterHold"] = cameraFrames.frames
            if environment["NATIVE_DESKTOP_LIVE_VISUAL_HOLD_SECONDS"] != nil {
                XCTAssertGreaterThan(cameraFrames.frames, cameraBeforeHold, "Physical camera frames must continue during the receiver observation.")
            }
            if let (track, frames) = cameraProbe {
                try await bounded(5) { await Task.detached { track.remove(frames) }.value }; cameraProbe = nil
            }
            model.toggleCamera(); try await drain(model, seconds: 15)
            try await wait(5) { !model.snapshot.cameraOn }

            model.startSharing(presenter: false, canvas: true)
            try await wait(25) { model.error != nil || (model.snapshot.sharing && model.localShare != nil && !model.sharingPending) }
            try await drain(model, seconds: 3)
            try await visualHold(provider, stage: "screen")
            let before = await statistics(engine, screenOnly: true)
            try await Task.sleep(for: .seconds(3))
            let after = await statistics(engine, screenOnly: true)
            let remote = model.participants.filter { !$0.isLocal }.count
            let advanced = total(after, "bytesSent") > total(before, "bytesSent") &&
                total(after, "framesEncoded") > total(before, "framesEncoded")
            evidence["remoteParticipants"] = remote
            evidence["screenBefore"] = before; evidence["screenAfter"] = after
            evidence["localScreenRTPProgress"] = advanced
            evidence["localScreenRTPProgressWithPeerPresent"] = advanced && remote > 0
            if remote == 0 { appendLimit("No remote participant was present; outgoing delivery is unverified.") }
            if !advanced { appendLimit("Public outbound counters did not advance; local publication acceptance alone is insufficient.") }
            if environment["NATIVE_DESKTOP_LIVE_REQUIRE_REMOTE"] == "1" {
                XCTAssertGreaterThan(remote, 0, "A receiving peer is required for this acceptance run.")
                XCTAssertTrue(advanced, "Outbound bytes and encoded frames must advance with the receiving peer present.")
            }
            let shareStopped = try await bounded(15) { await model.stopSharing() }
            XCTAssertTrue(shareStopped)
            try await wait(5) { !model.snapshot.sharing && model.localShare == nil }
            XCTAssertEqual(model.snapshot.playoutOn, playout)
            await model.presenter.open()
            XCTAssertTrue(model.presenter.canStartSharing)
            let document = try ShareEncodingLiveTests.readableShareFixture()
            model.presenter.scene.image = try XCTUnwrap(CIContext().createCGImage(document, from: document.extent))
            model.presenter.scene.backdrop = .warm
            model.presenter.scene.strokes = [[CGPoint(x: 0.1, y: 0.15), CGPoint(x: 0.85, y: 0.15), CGPoint(x: 0.85, y: 0.8)]]
            try await model.presenter.startSharing()
            try await wait(10) { model.presenter.isSharing && model.snapshot.sharing }
            try await visualHold(provider, stage: "presenter")
            let presenterBefore = await statistics(engine, screenOnly: true)
            try await Task.sleep(for: .seconds(2))
            let presenterAfter = await statistics(engine, screenOnly: true)
            evidence["presenterRTPProgress"] = total(presenterAfter, "bytesSent") > total(presenterBefore, "bytesSent") && total(presenterAfter, "framesEncoded") > total(presenterBefore, "framesEncoded")
            if environment["NATIVE_DESKTOP_LIVE_REQUIRE_REMOTE"] == "1" {
                XCTAssertEqual(evidence["presenterRTPProgress"] as? Bool, true)
            }
            try await model.presenter.stopSharing()
            let presenterClosed = await model.presenter.close()
            XCTAssertTrue(presenterClosed); XCTAssertFalse(model.snapshot.sharing)
            model.reconnect(); try await drain(model, seconds: 35)
            try await wait(15) { model.connected }
            XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertFalse(model.snapshot.cameraOn)
            XCTAssertFalse(model.snapshot.sharing); XCTAssertEqual(model.snapshot.playoutOn, playout)
            evidence["reconnectedCaptureOff"] = !model.snapshot.microphoneOn && !model.snapshot.cameraOn && !model.snapshot.sharing
            let clean = try await bounded(15, cleanup: true) { await model.leave() }
            evidence["cleanLeave"] = clean; XCTAssertTrue(clean)
            XCTAssertEqual(model.snapshot.phase, .left)
            XCTAssertNil(model.localCamera); XCTAssertNil(model.localShare)
            evidence["elapsedSeconds"] = Date().timeIntervalSince(started)
            XCTAssertLessThan(Date().timeIntervalSince(started), 180)
            attachEvidence()
        } catch {
            evidence["failure"] = String(describing: error)
            evidence["facadeError"] = model.error ?? "none"
            evidence["facadePhase"] = model.snapshot.phase.rawValue
            if let (track, frames) = cameraProbe {
                try? await bounded(3, cleanup: true) { await Task.detached { track.remove(frames) }.value }
            }
            _ = try? await bounded(15, cleanup: true) { await model.stopSharing() }
            let clean = try? await bounded(20, cleanup: true) { await model.leave() }
            evidence["cleanLeaveAfterFailure"] = clean ?? false
            evidence["elapsedSeconds"] = Date().timeIntervalSince(started)
            attachEvidence(); throw error
        }
    }
    private func drain(_ model: NativeDesktopMeetingModel, seconds: TimeInterval) async throws {
        try await bounded(seconds) { await model.waitForMediaActionsForTesting() }
        XCTAssertNil(model.error, "The app facade must accept and confirm each media action.")
        if let error = model.error { throw ExternalLiveFailure.mediaAction(error) }
    }
    private func visualHold(_ provider: Provider, stage: String) async throws {
        guard let raw = environment["NATIVE_DESKTOP_LIVE_VISUAL_HOLD_SECONDS"], let requested = Double(raw), requested.isFinite else { return }
        let duration = min(20, max(0, requested))
        print("NATIVE_DESKTOP_VISUAL_READY provider=\(provider.rawValue) stage=\(stage) hold=\(duration)")
        if duration > 0 { try await Task.sleep(for: .seconds(duration)) }
    }
    private func bounded<T>(_ seconds: TimeInterval, cleanup: Bool = false,
                            _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let remaining = cleanup ? seconds : min(seconds, deadline.timeIntervalSinceNow)
        guard remaining > 0 else { throw ExternalLiveFailure.deadline }
        let completion = GuestCompletion<T>()
        let task = Task { @MainActor in
            do { completion.finish(.success(try await operation())) }
            catch { completion.finish(.failure(error)) }
        }
        defer { task.cancel() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { completion.install($0, timeout: remaining) }
        }, onCancel: { task.cancel() })
    }
    private func wait(_ seconds: TimeInterval, until predicate: () -> Bool) async throws {
        let end = min(deadline, Date().addingTimeInterval(seconds))
        while !predicate(), Date() < end { try await Task.sleep(for: .milliseconds(100)) }
        guard predicate() else { throw ExternalLiveFailure.deadline }
    }
    private func statistics(_ engine: any NativeDesktopMeetingEngine, screenOnly: Bool) async -> [[String: Any]] {
        if let rock = engine as? NativeDesktopRockEngine {
            return rock.liveMediaEvidence.outbound.filter { !screenOnly || $0["source"] as? String == "screen" }
        }
        guard let session = engine as? NativeDesktopExternalSession, let connection = session.publisher?.connection else { return [] }
        let report: LKRTCStatisticsReport? = try? await bounded(3) {
            try await withCheckedThrowingContinuation { continuation in connection.statistics { continuation.resume(returning: $0) } }
        }
        return report?.statistics.values.compactMap { row -> [String: Any]? in
            guard row.type == "outbound-rtp", (row.values["kind"] ?? row.values["mediaType"]) as? String == "video" else { return nil }
            var value: [String: Any] = ["id": row.id]
            for field in ["bytesSent", "packetsSent", "framesEncoded", "framesSent", "frameWidth", "frameHeight", "framesPerSecond", "mid", "mediaSourceId", "codecId", "qpSum", "targetBitrate", "qualityLimitationReason"] {
                if let fieldValue = row.values[field] { value[field] = fieldValue }
            }
            if let id = row.values["codecId"] as? String, let codec = report?.statistics[id] {
                value["codec"] = codec.values["mimeType"]
            }
            return value
        } ?? []
    }
    private func total(_ rows: [[String: Any]], _ field: String) -> UInt64 {
        rows.reduce(0) { $0 + (($1[field] as? NSNumber)?.uint64Value ?? 0) }
    }
    private func appendLimit(_ value: String) { evidence["limits"] = (evidence["limits"] as? [String] ?? []) + [value] }
    private func attachEvidence() {
        let data = (try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "External native media evidence"; attachment.lifetime = .keepAlways; add(attachment)
        print("NATIVE_DESKTOP_LIVE_EVIDENCE " + String(data: data, encoding: .utf8)!)
    }
}

private final class ExternalLiveFrameCounter: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var frames: Int { lock.lock(); defer { lock.unlock() }; return count }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) { if frame != nil { lock.lock(); count += 1; lock.unlock() } }
}
