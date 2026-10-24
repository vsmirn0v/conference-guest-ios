import AVFoundation
import AppKit
import ConferenceCore
import Foundation
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

/// Runs inside the signed app test host and its TCC identity. Physical camera
/// recovery requires a separate opt-in; neither test qualifies acoustic quality.
@MainActor final class LiveNativeDesktopTests: XCTestCase {
    func testGuestModelMediaReconnectAndCanvasShare() async throws {
        guard let raw = ProcessInfo.processInfo.environment["NATIVE_DESKTOP_LIVE_GUEST_INVITE"],
              let url = URL(string: raw), !raw.isEmpty else {
            throw XCTSkip("Set NATIVE_DESKTOP_LIVE_GUEST_INVITE to run the live guest app test.")
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("The signed app host needs existing microphone authorization; this test never prompts.")
        }
        executionTimeAllowance = 180
        let deadline = Date().addingTimeInterval(170)
        let invitation = try GuestInvitation.parse(url)
        let peer = NativeGuestEngine(label: "Native parity generated peer", verifyReceivedPixels: false)
        let adapter = NativeDesktopGuestEngine()
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest),
                                             name: "Native parity app", title: "Live native parity", engine: adapter)
        do {
            try await peer.join(invitation)
            try await peer.publishPattern(codec: "h264", audioMuted: false, videoMuted: false)
            try await model.connect()
            XCTAssertTrue(model.snapshot.playoutOn)
            XCTAssertFalse(model.snapshot.microphoneOn)
            XCTAssertFalse(model.snapshot.cameraOn)
            try await wait("initial generated video", deadline: deadline) {
                (adapter.currentNativeEngine?.mediaSnapshot.render["advancingFrames"] as? Int ?? 0) >= 8
            }
            try await requireFixtureReceiver(peer, deadline: deadline)
            try await exerciseSending(model, adapter: adapter, peer: peer, phase: "initial", deadline: deadline)

            model.startSharing(presenter: false, canvas: true)
            try await wait("canvas sharing publication", deadline: deadline) { model.snapshot.sharing && model.localShare != nil && !model.sharingPending }
            try await wait("independent camera and screen RTP", deadline: deadline) {
                guard let native = adapter.currentNativeEngine else { return false }
                let stats = await native.evidence()["stats"] as? [[String: Any]] ?? []
                return stats.filter { $0["target"] as? String == GuestPeerTarget.publisher.rawValue && $0["type"] as? String == "outbound-rtp" &&
                    $0["kind"] as? String == "video" && self.number($0["framesEncoded"]) > 0 }.count >= 2
            }
            await record("sharing", model: model, adapter: adapter, peer: peer)
            let shareStopped = await model.stopSharing()
            XCTAssertTrue(shareStopped)
            XCTAssertTrue(model.snapshot.cameraOn, "Stopping screen sharing must preserve the camera")
            try await exercisePresenterCanvas(model, adapter: adapter, peer: peer, deadline: deadline)

            for index in 1...2 {
                let previous = adapter.currentNativeEngine
                model.reconnect()
                try await wait("reconnect \(index)", timeout: 30, deadline: deadline) {
                    model.connected && adapter.currentNativeEngine != nil && adapter.currentNativeEngine !== previous
                }
                XCTAssertFalse(model.snapshot.microphoneOn, "Reconnect must return with sending muted")
                XCTAssertFalse(model.snapshot.cameraOn)
                XCTAssertTrue(model.snapshot.playoutOn)
                let receiveBaseline = adapter.currentNativeEngine?.mediaSnapshot.render["advancingFrames"] as? Int ?? 0
                try await wait("fresh receive after reconnect \(index)", deadline: deadline) {
                    (adapter.currentNativeEngine?.mediaSnapshot.render["advancingFrames"] as? Int ?? 0) >= receiveBaseline + 5
                }
                try await exerciseSending(model, adapter: adapter, peer: peer, phase: "reconnect-\(index)", deadline: deadline)
            }
            let clean = await model.leave(), peerClean = await peer.leave()
            XCTAssertTrue(clean); XCTAssertTrue(peerClean)
            XCTAssertEqual(model.snapshot.phase, .left)
            XCTAssertNil(model.localCamera); XCTAssertNil(model.localShare)
            XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertFalse(model.snapshot.cameraOn)
        } catch {
            await record("failure", model: model, adapter: adapter, peer: peer)
            let clean = await model.leave(), peerClean = await peer.leave()
            XCTAssertTrue(clean, "App cleanup after failed live acceptance")
            XCTAssertTrue(peerClean, "Generated peer cleanup after failed live acceptance")
            throw error
        }
    }

    private func exercisePresenterCanvas(_ model: NativeDesktopMeetingModel, adapter: NativeDesktopGuestEngine,
                                         peer: NativeGuestEngine, deadline: Date) async throws {
        let camera = model.localCamera, presenter = model.presenter
        let previousScreens = Set(peer.incomingVideo.filter { $0.source == "SCREEN_SHARE" }.map(\.id))
        await presenter.open()
        XCTAssertEqual(presenter.source, .canvas)
        XCTAssertNotNil(presenter.previewTrack)
        var scene = presenter.scene
        scene.backdrop = .warm; scene.layout = .card
        scene.placement = .init(x: 0.61, y: 0.27, width: 0.25, height: 0.53)
        scene.strokes = [[CGPoint(x: 0.06, y: 0.10), CGPoint(x: 0.31, y: 0.14), CGPoint(x: 0.18, y: 0.58)]]
        presenter.scene = scene
        await presenter.setIncludeCamera(true)
        XCTAssertTrue(presenter.includeCamera)
        try await presenter.startSharing()
        try await wait("Presenter canvas publication", deadline: deadline) {
            presenter.isSharing && model.snapshot.sharing && model.localShare != nil &&
                peer.incomingVideo.contains { $0.source == "SCREEN_SHARE" && !previousScreens.contains($0.id) }
        }
        let screen = try XCTUnwrap(peer.incomingVideo.first { $0.source == "SCREEN_SHARE" && !previousScreens.contains($0.id) })
        let frames = GuestFrameCounter(verifyPixels: true), sink = GuestTrackRenderer(counter: frames)
        screen.track.add(sink)
        defer { sink.stop(); screen.track.remove(sink) }
        try await wait("decoded Presenter screen frames", deadline: deadline) {
            self.number(frames.evidence["advancingFrames"]) >= 5
        }
        let before = frames.evidence
        scene.backdrop = .stage
        scene.strokes.append([CGPoint(x: 0.67, y: 0.16), CGPoint(x: 0.87, y: 0.46), CGPoint(x: 0.74, y: 0.83)])
        presenter.scene = scene
        try await wait("Presenter scene edit reaches decoded screen pixels", deadline: deadline) {
            let current = frames.evidence
            return self.number(current["advancingFrames"]) >= self.number(before["advancingFrames"]) + 5 &&
                self.number(current["pixelChanges"]) > self.number(before["pixelChanges"])
        }
        await record("presenter-canvas", model: model, adapter: adapter, peer: peer, extra: [
            "presenter": ["source": presenter.source.rawValue, "includeCamera": presenter.includeCamera,
                          "backdrop": scene.backdrop.rawValue, "strokeCount": scene.strokes.count],
            "decodedScreen": frames.evidence,
            "screenTrack": ["id": screen.id, "participantID": screen.participantID ?? "", "source": screen.source ?? ""],
            "publicationIdentity": adapter.currentNativeEngine?.publicationIdentity ?? [:]
        ])
        try await presenter.stopSharing()
        let clean = await presenter.close(); XCTAssertTrue(clean)
        try await wait("Presenter closes without stopping the ordinary camera", deadline: deadline) {
            !presenter.isSharing && presenter.previewTrack == nil && !model.snapshot.sharing && model.localShare == nil
        }
        XCTAssertTrue(model.snapshot.cameraOn)
        XCTAssertTrue(model.localCamera === camera)
        XCTAssertTrue(NativeDesktopCameraLease.shared.liveTrack === camera)
    }

    func testGuestPresenterCapturesSelectedSyntheticWindow() async throws {
        guard ProcessInfo.processInfo.environment["NATIVE_DESKTOP_LIVE_SCREEN_PICKER"] == "1" else {
            throw XCTSkip("Set NATIVE_DESKTOP_LIVE_SCREEN_PICKER=1 and select only the test's titled synthetic window.")
        }
        guard #available(macOS 14.0, *),
              let raw = ProcessInfo.processInfo.environment["NATIVE_DESKTOP_LIVE_GUEST_INVITE"],
              let url = URL(string: raw), !raw.isEmpty else { throw XCTSkip("macOS 14+ and a live guest invitation are required.") }
        executionTimeAllowance = 180
        let deadline = Date().addingTimeInterval(170)
        let title = "Native guest synthetic window \(UUID().uuidString.prefix(8))"
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 960, height: 540),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        let pattern = NativeGuestSyntheticWindowView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        pattern.autoresizingMask = [.width, .height]; window.contentView = pattern
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        let peer = NativeGuestEngine(label: "Native window generated peer", verifyReceivedPixels: false)
        let adapter = NativeDesktopGuestEngine()
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest),
                                             name: "Native selected window app", title: "Selected synthetic window", quiet: true, engine: adapter)
        do {
            try await peer.join(try GuestInvitation.parse(url))
            try await peer.publishPattern(codec: "h264", audioMuted: true, videoMuted: false)
            try await model.connect()
            try await requireFixtureReceiver(peer, deadline: deadline)
            let presenter = model.presenter
            await presenter.open()
            // The operator must choose this one window in the real system
            // selector. The test never programmatically selects desktop content.
            window.sharingType = .readOnly; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(150))
            print("NATIVE_SCREEN_PICKER_READY title=\(title) windowNumber=\(window.windowNumber) visible=\(window.isVisible) active=\(NSApp.isActive) mode=window")
            await presenter.chooseWindow() // Real window-only selector; deadline is 120 seconds.
            XCTAssertEqual(presenter.source, .screen)
            guard presenter.previewTrack != nil else {
                XCTFail(presenter.error ?? "The synthetic window was not selected")
                throw URLError(.cancelled)
            }
            XCTAssertFalse(presenter.includeCamera)
            try await presenter.startSharing()
            try await wait("selected window screen publication", deadline: deadline) {
                presenter.isSharing && model.snapshot.sharing && peer.incomingVideo.contains { $0.source == "SCREEN_SHARE" }
            }
            let screen = try XCTUnwrap(peer.incomingVideo.first { $0.source == "SCREEN_SHARE" })
            let frames = GuestFrameCounter(verifyPixels: true), sink = GuestTrackRenderer(counter: frames)
            screen.track.add(sink)
            defer { sink.stop(); screen.track.remove(sink) }
            for (index, size) in [CGSize(width: 960, height: 540), CGSize(width: 480, height: 720), CGSize(width: 1000, height: 500)].enumerated() {
                let baseline = frames.evidence
                pattern.phase = index; window.setContentSize(size); pattern.needsDisplay = true; pattern.displayIfNeeded()
                try await wait("selected window aspect \(index)", timeout: 15, deadline: deadline) {
                    let current = frames.evidence
                    let landscape = self.number(current["width"]) > self.number(current["height"])
                    return self.number(current["advancingFrames"]) >= self.number(baseline["advancingFrames"]) + 5 && landscape == (index != 1)
                }
                XCTAssertFalse(model.snapshot.cameraOn)
                let identity = adapter.currentNativeEngine?.publicationIdentity ?? [:]
                XCTAssertNotNil(identity["screen"])
                XCTAssertNotEqual(identity["screen"], identity["video"], "Screen and camera must keep separate native publications")
                await record("selected-window-aspect-\(index)", model: model, adapter: adapter, peer: peer, extra: [
                    "syntheticWindow": ["title": title, "windowNumber": window.windowNumber,
                                        "contentWidth": size.width, "contentHeight": size.height, "phase": index],
                    "decodedScreen": frames.evidence,
                    "screenTrack": ["id": screen.id, "participantID": screen.participantID ?? "", "source": screen.source ?? ""],
                    "publicationIdentity": identity
                ])
            }
            try await presenter.stopSharing()
            let presenterStopped = await presenter.close(); XCTAssertTrue(presenterStopped)
            try await wait("selected window capture and publication stopped", deadline: deadline) {
                !model.snapshot.sharing && model.localShare == nil && presenter.previewTrack == nil
            }
            let clean = await model.leave(), peerClean = await peer.leave()
            XCTAssertTrue(clean); XCTAssertTrue(peerClean)
            XCTAssertEqual(model.snapshot.phase, .left); XCTAssertFalse(model.snapshot.sharing)
            XCTAssertNil(model.localShare); XCTAssertNil(model.localCamera)
        } catch {
            await record("selected-window-failure", model: model, adapter: adapter, peer: peer)
            let clean = await model.leave(), peerClean = await peer.leave()
            XCTAssertTrue(clean); XCTAssertTrue(peerClean)
            throw error
        }
    }

    func testGuestAutomaticRecoveryPreservesPhysicalSending() async throws {
        guard ProcessInfo.processInfo.environment["NATIVE_DESKTOP_LIVE_GUEST_PHYSICAL_RECOVERY"] == "1" else {
            throw XCTSkip("Set NATIVE_DESKTOP_LIVE_GUEST_PHYSICAL_RECOVERY=1 for the physical camera recovery check.")
        }
        guard let raw = ProcessInfo.processInfo.environment["NATIVE_DESKTOP_LIVE_GUEST_INVITE"],
              let url = URL(string: raw), !raw.isEmpty else { throw XCTSkip("A live guest invitation is required.") }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw XCTSkip("The signed app host needs existing microphone and camera authorization; this test never prompts.")
        }
        executionTimeAllowance = 180
        let deadline = Date().addingTimeInterval(120)
        let peer = NativeGuestEngine(label: "Native physical recovery generated peer", verifyReceivedPixels: false)
        let adapter = NativeDesktopGuestEngine()
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest),
                                             name: "Native physical recovery app", title: "Physical automatic recovery", engine: adapter)
        do {
            try await peer.join(try GuestInvitation.parse(url))
            try await peer.publishPattern(codec: "h264", audioMuted: false, videoMuted: false)
            try await model.connect()
            try await requireFixtureReceiver(peer, deadline: deadline)
            let peerBefore = peer.mediaSnapshot
            model.toggleMicrophone(); model.toggleCamera()
            try await wait("physical microphone and camera on", timeout: 25, deadline: deadline) {
                model.connected && model.snapshot.microphoneOn && model.snapshot.cameraOn && model.localCamera != nil
            }
            guard let initial = adapter.currentNativeEngine else { throw URLError(.notConnectedToInternet) }
            let firstDevice = try await verifyPhysicalSending(model, adapter: adapter, native: initial, peer: peer,
                                                            peerBaseline: peerBefore, phase: "physical-before-recovery", deadline: deadline)
            XCTAssertTrue(NativeDesktopCameraLease.shared.liveTrack === model.localCamera,
                          "The physical camera must be published through the live owner")

            // Interrupt only this engine's socket. Do not invoke the explicit
            // reconnect UI action, toggle sending, or mint another headset grant.
            await initial.interruptTransportForTesting()
            try await wait("automatic native engine replacement", timeout: 40, deadline: deadline) {
                model.connected && adapter.currentNativeEngine != nil && adapter.currentNativeEngine !== initial
            }
            XCTAssertTrue(model.snapshot.microphoneOn, "Automatic recovery must preserve the accepted microphone intent")
            XCTAssertTrue(model.snapshot.cameraOn, "Automatic recovery must preserve the accepted camera intent")
            XCTAssertTrue(model.snapshot.playoutOn)
            guard let recovered = adapter.currentNativeEngine else { throw URLError(.notConnectedToInternet) }
            let peerAfterReplacement = peer.mediaSnapshot
            let receiveBaseline = recovered.mediaSnapshot.render["advancingFrames"] as? Int ?? 0
            try await wait("fresh incoming video after automatic recovery", deadline: deadline) {
                (recovered.mediaSnapshot.render["advancingFrames"] as? Int ?? 0) >= receiveBaseline + 5
            }
            let recoveredDevice = try await verifyPhysicalSending(model, adapter: adapter, native: recovered, peer: peer,
                                                                 peerBaseline: peerAfterReplacement,
                                                                 phase: "physical-after-automatic-recovery", deadline: deadline)
            XCTAssertEqual(recoveredDevice, firstDevice, "Automatic replacement must keep the selected physical camera")
            XCTAssertTrue(NativeDesktopCameraLease.shared.liveTrack === model.localCamera,
                          "Automatic recovery must retain the root camera lease and publish the replacement track")
            XCTAssertEqual(LKRTCApplicationCaptureMuted(), 0,
                           "The original authorized headset request must reopen real PCM after confirmed recovery")
            let clean = await model.leave(), peerClean = await peer.leave()
            XCTAssertTrue(clean); XCTAssertTrue(peerClean)
            XCTAssertEqual(model.snapshot.phase, .left)
            XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertFalse(model.snapshot.cameraOn)
            XCTAssertNil(model.localCamera); XCTAssertNil(NativeDesktopCameraLease.shared.liveTrack)
        } catch {
            let device = await adapter.cameraCaptureDevice()
            await record("physical-automatic-recovery-failure", model: model, adapter: adapter, peer: peer, extra: [
                "camera": ["requestedDeviceID": UserDefaults.standard.string(forKey: "nativeDesktop.cameraID") ?? "",
                           "actualDeviceID": device?.uniqueID ?? "", "name": device?.localizedName ?? ""],
                "captureGateMuted": LKRTCApplicationCaptureMuted()
            ])
            let clean = await model.leave(), peerClean = await peer.leave()
            XCTAssertTrue(clean); XCTAssertTrue(peerClean)
            throw error
        }
    }

    private func verifyPhysicalSending(_ model: NativeDesktopMeetingModel, adapter: NativeDesktopGuestEngine,
                                       native: NativeGuestEngine, peer: NativeGuestEngine,
                                       peerBaseline: GuestMediaSnapshot, phase: String, deadline: Date) async throws -> String {
        try await wait("\(phase) fresh physical camera at peer", timeout: 20, deadline: deadline) {
            let newFrames = (peer.mediaSnapshot.render["advancingFrames"] as? Int ?? 0) - (peerBaseline.render["advancingFrames"] as? Int ?? 0)
            return newFrames >= 5 && (native.cameraSnapshot?.advancingPTS ?? 0) >= 5
        }
        try await wait("\(phase) nonzero encoded microphone signal", timeout: 20, deadline: deadline) {
            let rows = await native.evidence()["stats"] as? [[String: Any]] ?? []
            let outgoing = rows.filter { $0["target"] as? String == GuestPeerTarget.publisher.rawValue }
            let sourceEnergy = outgoing.contains { $0["type"] as? String == "media-source" && $0["kind"] as? String == "audio" && self.number($0["totalAudioEnergy"]) > 0 }
            let audioRTP = outgoing.contains { $0["type"] as? String == "outbound-rtp" && $0["kind"] as? String == "audio" && self.number($0["packetsSent"]) > 0 }
            let videoRTP = outgoing.contains { $0["type"] as? String == "outbound-rtp" && $0["kind"] as? String == "video" && self.number($0["framesEncoded"]) >= 5 }
            let freshPeerAudio = peer.mediaSnapshot.audio.since(peerBaseline.audio)
            return sourceEnergy && audioRTP && videoRTP && freshPeerAudio.samples > 0 && freshPeerAudio.energy > 0
        }
        XCTAssertEqual(LKRTCApplicationCaptureMuted(), 0)
        let beforeRender = number((await native.evidence()["physicalPlayoutMeter"] as? [String: Any])?["samples"])
        try await wait("\(phase) hardware output render progress", deadline: deadline) {
            let output = await native.evidence()["physicalPlayoutMeter"] as? [String: Any] ?? [:]
            return self.number(output["samples"]) > beforeRender && self.number(output["energy"]) > 0
        }
        guard let device = await adapter.cameraCaptureDevice(), let camera = native.cameraSnapshot else {
            XCTFail("The physical camera must report its actual capture device")
            throw URLError(.cannotDecodeContentData)
        }
        let selected = UserDefaults.standard.string(forKey: "nativeDesktop.cameraID") ?? ""
        if !selected.isEmpty { XCTAssertEqual(device.uniqueID, selected) }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        await record(phase, model: model, adapter: adapter, peer: peer, extra: [
            "camera": ["requestedDeviceID": selected, "actualDeviceID": device.uniqueID,
                       "name": device.localizedName, "deviceType": device.deviceType.rawValue,
                       "activeFormatWidth": dimensions.width, "activeFormatHeight": dimensions.height,
                       "capturedWidth": camera.width, "capturedHeight": camera.height,
                       "capturedFrames": camera.frames, "advancingPTS": camera.advancingPTS],
            "peerFreshAudio": ["samples": peer.mediaSnapshot.audio.since(peerBaseline.audio).samples,
                               "energy": peer.mediaSnapshot.audio.since(peerBaseline.audio).energy],
            "captureGateMuted": LKRTCApplicationCaptureMuted()
        ])
        return device.uniqueID
    }

    private func exerciseSending(_ model: NativeDesktopMeetingModel, adapter: NativeDesktopGuestEngine,
                                 peer: NativeGuestEngine, phase: String, deadline: Date) async throws {
        guard let native = adapter.currentNativeEngine else { throw URLError(.notConnectedToInternet) }
        native.cameraFactoryForTesting = { NativeDesktopShareCapture(source: $0, canvasOnly: true) }
        let peerBaseline = peer.mediaSnapshot.render["advancingFrames"] as? Int ?? 0
        model.toggleMicrophone(); model.toggleCamera()
        try await wait("\(phase) microphone and generated camera", deadline: deadline) {
            model.snapshot.microphoneOn && model.snapshot.cameraOn && model.localCamera != nil
        }
        try await wait("\(phase) peer receives generated camera", deadline: deadline, fixture: peer) {
            (peer.mediaSnapshot.render["advancingFrames"] as? Int ?? 0) >= peerBaseline + 5
        }
        try await wait("\(phase) outgoing audio and video RTP", deadline: deadline) {
            let rows = await native.evidence()["stats"] as? [[String: Any]] ?? []
            let sent = rows.filter { $0["target"] as? String == GuestPeerTarget.publisher.rawValue && $0["type"] as? String == "outbound-rtp" && self.number($0["packetsSent"]) > 0 }
            return sent.contains { $0["kind"] as? String == "audio" } && sent.contains { $0["kind"] as? String == "video" && self.number($0["framesEncoded"]) > 0 }
        }
        // Borrow the active ADM before its mute mixer. An RTP clock consisting
        // entirely of gate-generated silence cannot satisfy these assertions.
        try await adapter.startPrivateAudioCheck()
        do {
            try await wait("\(phase) physical microphone samples", deadline: deadline) { adapter.privateAudioLevel != nil }
            try await Task.sleep(for: .milliseconds(400))
            let audio = await native.evidence()
            let input = audio["physicalInputMeter"] as? [String: Any] ?? [:]
            let output = audio["physicalPlayoutMeter"] as? [String: Any] ?? [:]
            XCTAssertGreaterThan(number(input["buffers"]), 0)
            XCTAssertGreaterThan(number(input["samples"]), 0)
            XCTAssertGreaterThan(number(input["energy"]), 0, "Physical microphone must deliver actual signal, not only clocked silence")
            XCTAssertGreaterThan(number(output["buffers"]), 0)
            XCTAssertGreaterThan(number(output["energy"]), 0, "The hardware-driven mixer must render nonzero incoming audio")
            await record("\(phase)-unmuted-audio", model: model, adapter: adapter, peer: peer)
            try await adapter.stopPrivateAudioCheck()
        } catch { try? await adapter.stopPrivateAudioCheck(); throw error }
        let renderedBeforeMute = number((await native.evidence()["physicalPlayoutMeter"] as? [String: Any])?["samples"])
        let receiveBaseline = native.mediaSnapshot.render["advancingFrames"] as? Int ?? 0
        model.toggleMicrophone()
        try await wait("\(phase) microphone mute", deadline: deadline) { !model.snapshot.microphoneOn }
        XCTAssertTrue(model.snapshot.playoutOn); XCTAssertTrue(model.snapshot.cameraOn)
        try await wait("\(phase) incoming video while muted", deadline: deadline) {
            (native.mediaSnapshot.render["advancingFrames"] as? Int ?? 0) >= receiveBaseline + 5
        }
        let physical = await native.evidence()["physicalAudio"] as? [String: Any] ?? [:]
        XCTAssertEqual(physical["microphoneMuted"] as? Bool, true)
        XCTAssertEqual(physical["outputAvailable"] as? Bool, true)
        XCTAssertEqual(physical["playoutEnabledRequested"] as? Bool, true)
        let afterMute = await native.evidence()
        let renderedAfterMute = number((afterMute["physicalPlayoutMeter"] as? [String: Any])?["samples"])
        XCTAssertGreaterThan(renderedAfterMute, renderedBeforeMute, "Muting capture must preserve the hardware's output render clock")
        await record(phase, model: model, adapter: adapter, peer: peer)
    }

    private func requireFixtureReceiver(_ peer: NativeGuestEngine, deadline: Date) async throws {
        try await wait("independent generated receiver ICE connection", deadline: deadline, fixture: peer) {
            peer.mediaSnapshot.connected
        }
    }

    private func wait(_ description: String, timeout: TimeInterval = 15, deadline: Date,
                      fixture: NativeGuestEngine? = nil,
                      condition: () async throws -> Bool) async throws {
        let end = min(Date().addingTimeInterval(timeout), deadline)
        while Date() < end {
            if fixture?.mediaSnapshot.failed == true {
                XCTFail("Independent generated receiver transport failed while waiting for \(description)")
                throw GuestPeerError.iceFailed
            }
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTFail("Timed out waiting for \(description)")
        throw URLError(.timedOut)
    }
    private func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
    private func record(_ phase: String, model: NativeDesktopMeetingModel, adapter: NativeDesktopGuestEngine,
                        peer: NativeGuestEngine, extra: [String: Any] = [:]) async {
        // Preserve the stalled operation before refreshSnapshot/statistics enqueue more work.
        let audio = adapter.currentNativeEngine?.systemAudio
        let peerBeforeDiagnostics = peer.mediaSnapshot
        let cachedAudio: [String: Any] = ["state": audio?.snapshot ?? [:],
            "input": audio?.privateInputMeterEvidence ?? [:], "playout": audio?.playoutMeterEvidence ?? [:],
            "captureGateMuted": LKRTCApplicationCaptureMuted(), "phase": phase]
        probeLog("native-live-pre-diagnostics", cachedAudio)
        var evidence = await adapter.currentNativeEngine?.evidence() ?? [:]
        evidence["physicalAudioBeforeDiagnostics"] = cachedAudio
        evidence["fixturePeerBeforeDiagnostics"] = ["connected": peerBeforeDiagnostics.connected,
            "failed": peerBeforeDiagnostics.failed, "render": peerBeforeDiagnostics.render,
            "audioSamples": peerBeforeDiagnostics.audio.samples, "audioEnergy": peerBeforeDiagnostics.audio.energy]
        evidence["fixturePeer"] = await peer.evidence()
        evidence.merge(extra) { _, new in new }
        evidence["phase"] = phase
        evidence["peerReceive"] = peer.mediaSnapshot.render
        evidence["model"] = ["microphoneOn": model.snapshot.microphoneOn, "cameraOn": model.snapshot.cameraOn,
                             "playoutOn": model.snapshot.playoutOn, "sharing": model.snapshot.sharing]
        guard let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "native-live-\(phase)"; attachment.lifetime = .keepAlways; add(attachment)
    }
}

/// Only generated colors/text are eligible for the opt-in system-picker test.
@MainActor private final class NativeGuestSyntheticWindowView: NSView {
    var phase = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.04, green: 0.07, blue: 0.14, alpha: 1).setFill(); NSBezierPath(rect: bounds).fill()
        NSColor.systemRed.setFill(); NSBezierPath(rect: CGRect(x: 0, y: 0, width: bounds.width * 0.34, height: bounds.height * 0.43)).fill()
        NSColor.systemBlue.setFill(); NSBezierPath(rect: CGRect(x: bounds.width * 0.58, y: bounds.height * 0.29, width: bounds.width * 0.42, height: bounds.height * 0.71)).fill()
        NSColor.systemYellow.setFill(); NSBezierPath(ovalIn: CGRect(x: bounds.width * 0.13, y: bounds.height * 0.64, width: 80, height: 80)).fill()
        let text = NSAttributedString(string: "SYNTHETIC WINDOW\nPhase \(phase) · \(Int(bounds.width)) × \(Int(bounds.height))",
                                      attributes: [.font: NSFont.monospacedSystemFont(ofSize: 25, weight: .bold), .foregroundColor: NSColor.white])
        text.draw(in: CGRect(x: 20, y: 20, width: max(1, bounds.width - 40), height: 110))
    }
}
