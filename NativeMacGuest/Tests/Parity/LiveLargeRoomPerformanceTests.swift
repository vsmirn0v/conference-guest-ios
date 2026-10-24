import AppKit
import AVFoundation
import ConferenceCore
import LiveKitWebRTC
import MetalKit
import XCTest
@testable import RockNativeDesktop

/// Authorized disposable Guest rooms only. Unlike the offline workload, these
/// independent clients encode H.264 and traverse the real SFU before decoding.
/// CPU/footprint include every local encoder peer, never receiver-only cost.
@MainActor final class LiveLargeRoomPerformanceTests: XCTestCase {
    func testSixLiveGuestPublishersAndGallery() async throws { try await qualify(senders: 6) }
    func testTwelveLiveGuestPublishersAndGallery() async throws { try await qualify(senders: 12) }

    private func qualify(senders: Int) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NATIVE_DESKTOP_LIVE_LARGE_ROOM"] == "1",
              let raw = environment["NATIVE_DESKTOP_LIVE_GUEST_INVITE"], !raw.isEmpty,
              let url = URL(string: raw) else {
            throw XCTSkip("Set NATIVE_DESKTOP_LIVE_LARGE_ROOM=1 and an authorized disposable NATIVE_DESKTOP_LIVE_GUEST_INVITE.")
        }
        executionTimeAllowance = 225
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        let invitation = try GuestInvitation.parse(url), saved = try LargeRoomSavedState()
        let accessoryPreference = UserDefaults.standard.object(forKey: "nativeDesktop.headsetMuteControls")
        UserDefaults.standard.set(false, forKey: "nativeDesktop.headsetMuteControls")
        defer {
            saved.restore()
            if let accessoryPreference { UserDefaults.standard.set(accessoryPreference, forKey: "nativeDesktop.headsetMuteControls") }
            else { UserDefaults.standard.removeObject(forKey: "nativeDesktop.headsetMuteControls") }
        }
        let prefix = "Large-\(UUID().uuidString.prefix(8))-"
        let adapter = NativeDesktopGuestEngine()
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest),
            name: prefix + "receiver", title: "Live generated large room · \(senders)", quiet: true, engine: adapter)
        model.viewMode = .gallery
        let meeting = NativeDesktopMeetingWindow(model: model)
        let heartbeat = LargeRoomHeartbeat()
        var peers: [NativeGuestEngine] = [], phases: [[String: Any]] = []
        var cleaned = false
        var evidence: [String: Any] = ["kind": "live-Guest-SFU-generated-H264", "publishers": senders,
            "sourceProfile": "640x360 H264 15fps 400kbps", "maximumSimultaneousVideoSubscriptions": 6,
            "measurementScope": "Combined signed app receiver plus all local synthetic encoder peers",
            "publisherPhysicalCapture": false, "publisherAudioMuted": true,
            "receiverMicrophoneOptIn": environment["NATIVE_DESKTOP_LARGE_ROOM_PHYSICAL_MICROPHONE"] == "1"]
        defer {
            heartbeat.stop(); meeting.close()
            evidence["phases"] = phases; evidence["cleanupCompleted"] = cleaned
            if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "Live Guest \(senders) publishers performance"; attachment.lifetime = .keepAlways; add(attachment)
                print("NATIVE_DESKTOP_LIVE_LARGE_ROOM " + String(decoding: data, as: UTF8.self))
            }
        }
        do {
            for index in 0..<senders {
                let peer = NativeGuestEngine(label: prefix + "sender-\(index)", verifyReceivedPixels: false)
                peers.append(peer)
                // Set before join so admission never temporarily subscribes the
                // publisher to the other publishers' video decoders.
                try await peer.setVisibleParticipantIDs([])
                try await bounded(30, deadline: deadline) {
                    try await peer.join(invitation)
                    try await peer.publishPattern(codec: "h264", camera: false, audioMuted: true, videoMuted: false)
                }
            }
            try await bounded(40, deadline: deadline) { try await model.connect() }
            try await wait("all independent publishers in receiver roster", deadline: deadline) {
                model.participants.filter { !$0.isLocal && $0.name.hasPrefix(prefix) }.count == senders
            }
            XCTAssertEqual(model.participants.filter { !$0.isLocal }.count, senders, "An occupied room cannot provide an isolated performance sample")
            let native = try XCTUnwrap(adapter.currentNativeEngine)
            meeting.show()
            let window = try XCTUnwrap(NSApp.windows.first { $0.delegate === meeting && !($0 is NSPanel) })
            window.setContentSize(NSSize(width: 1120, height: 740))
            heartbeat.start()
            for page in 0..<model.galleryPages {
                let previousSinks = sinks(window)
                let previous = Set(previousSinks.map(ObjectIdentifier.init))
                model.galleryPage = page
                try await wait("gallery page \(page + 1) fresh GPU tracks", deadline: deadline) {
                    let current = self.sinks(window)
                    // Room membership arrives before all RTC mute metadata.
                    // Recompute readiness from the current authoritative roster;
                    // never freeze a transient cameraOn count before awaiting it.
                    let remote = model.galleryParticipants.filter { !$0.isLocal }
                    guard !remote.isEmpty, remote.allSatisfy({ $0.cameraOn == true }) else { return false }
                    let participants = Set(remote.map(\.id))
                    let tracks = Set(model.videos.filter { participants.contains($0.participantID) && $0.source == .camera }.map { $0.track.trackId })
                    return current.count == participants.count && current.allSatisfy { $0.frames >= 8 } &&
                        tracks.count == participants.count && Set(current.compactMap(\.trackIDForTesting)) == tracks &&
                        (page == 0 || (current.allSatisfy { !previous.contains(ObjectIdentifier($0)) } &&
                            previousSinks.allSatisfy { $0.preparationEvidenceForTesting["active"] == 0 }))
                }
                let expected = model.galleryParticipants.filter { !$0.isLocal }.count
                phases.append(try await measure("gallery-page-\(page + 1)", native: native, window: window,
                    expectedGPU: expected, expectedDecoders: expected, publishers: peers, deadline: deadline))
            }
            // A muted local tile can occupy one of the six gallery slots. This
            // separate phase explicitly proves six simultaneous real decoders;
            // its GPU count remains the real number of remote tiles on page 0.
            let previousPageSinks = sinks(window)
            let previousPage = Set(previousPageSinks.map(ObjectIdentifier.init))
            model.galleryPage = 0
            try await wait("first gallery page before explicit six-decoder phase", deadline: deadline) {
                let current = self.sinks(window)
                let remote = model.galleryParticipants.filter { !$0.isLocal }
                guard !remote.isEmpty, remote.allSatisfy({ $0.cameraOn == true }) else { return false }
                let participants = Set(remote.map(\.id))
                let tracks = Set(model.videos.filter { participants.contains($0.participantID) && $0.source == .camera }.map { $0.track.trackId })
                return current.count == participants.count && tracks.count == participants.count &&
                    Set(current.compactMap(\.trackIDForTesting)) == tracks &&
                    current.allSatisfy { $0.frames >= 8 && !previousPage.contains(ObjectIdentifier($0)) } &&
                    previousPageSinks.allSatisfy { $0.preparationEvidenceForTesting["active"] == 0 }
            }
            let remote = model.participants.filter { !$0.isLocal && $0.name.hasPrefix(prefix) }
            let sixIDs = Set(remote.prefix(6).map(\.id))
            try await bounded(10, deadline: deadline) { try await native.setVisibleParticipantIDs(sixIDs) }
            try await wait("six independently subscribed RTC camera tracks", deadline: deadline) {
                native.incomingVideo.filter { $0.source == "CAMERA" && sixIDs.contains($0.participantID ?? "") }.count == 6
            }
            let galleryGPU = model.galleryParticipants.filter { !$0.isLocal && sixIDs.contains($0.id) }.count
            try await wait("six-decoder phase gallery renderers", deadline: deadline) {
                self.sinks(window).count == galleryGPU && self.sinks(window).allSatisfy { $0.frames >= 8 }
            }
            phases.append(try await measure("six-simultaneous-real-decoders", native: native, window: window,
                expectedGPU: galleryGPU, expectedDecoders: 6, publishers: peers, deadline: deadline))

            let focus = try XCTUnwrap(remote.last)
            model.focus(participantID: focus.id, source: .camera)
            try await wait("focused remote camera renderer", deadline: deadline) {
                model.focusedVideo?.participantID == focus.id && self.sinks(window).count == 1 && self.sinks(window).allSatisfy { $0.frames >= 8 }
            }
            phases.append(try await measure("focused-camera", native: native, window: window,
                expectedGPU: 1, expectedDecoders: 1, publishers: peers, deadline: deadline))
            let controls = ProcessInfo.processInfo.systemUptime
            model.togglePlayout(); await model.waitForMediaActionsForTesting()
            XCTAssertTrue(model.snapshot.playoutOn)
            model.togglePlayout(); await model.waitForMediaActionsForTesting()
            XCTAssertFalse(model.snapshot.playoutOn)
            // An explicit mute is always exercised. Real microphone unmute has
            // its own opt-in and requires pre-existing TCC authorization.
            try await bounded(10, deadline: deadline) { try await adapter.setMicrophone(false) }
            if environment["NATIVE_DESKTOP_LARGE_ROOM_PHYSICAL_MICROPHONE"] == "1" {
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw LiveLargeRoomFailure.microphoneNotAuthorized }
                model.toggleMicrophone(); await model.waitForMediaActionsForTesting()
                XCTAssertTrue(model.snapshot.microphoneOn)
                model.toggleMicrophone(); await model.waitForMediaActionsForTesting()
                XCTAssertFalse(model.snapshot.microphoneOn)
            }
            evidence["controlSequenceSeconds"] = ProcessInfo.processInfo.systemUptime - controls
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - controls, 5)

            let retired = sinks(window)
            meeting.close()
            try await wait("hidden viewport unsubscribes every video", deadline: deadline) { native.incomingVideo.isEmpty && self.sinks(window).isEmpty }
            let hiddenBefore = try await stats(native, deadline: deadline)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let hiddenAfter = try await stats(native, deadline: deadline)
            let hiddenDelta = advancingVideo(before: hiddenBefore, after: hiddenAfter, minimumFrames: 1, requireCorrelatedBytes: false)
            evidence["hiddenAdvancingVideoRowsAfterDrain"] = hiddenDelta
            // Permit the bounded decoder/network tail, but never five seconds
            // of hidden work. A second settled interval must remain quiescent.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let hiddenSettled = try await stats(native, deadline: deadline)
            XCTAssertTrue(advancingVideo(before: hiddenAfter, after: hiddenSettled, minimumFrames: 1, requireCorrelatedBytes: false).isEmpty)
            for sink in retired { XCTAssertEqual(sink.preparationEvidenceForTesting["active"], 0) }
            meeting.show()
            try await wait("focused camera resumes after hidden zero-demand", deadline: deadline) {
                self.sinks(window).count == 1 && self.sinks(window).allSatisfy { $0.frames >= 8 }
            }
            phases.append(try await measure("restore-focused-camera", native: native, window: window,
                expectedGPU: 1, expectedDecoders: 1, publishers: peers, deadline: deadline))
            var publishers: [[String: Any]] = []
            for peer in peers {
                let rows = try await stats(peer, deadline: deadline)
                let outbound = rows.filter { $0["target"] as? String == GuestPeerTarget.publisher.rawValue && $0["type"] as? String == "outbound-rtp" && $0["kind"] as? String == "video" }
                XCTAssertTrue(outbound.contains { number($0["framesEncoded"]) >= 30 && number($0["bytesSent"]) > 0 })
                publishers.append(["video": outbound, "receivedVideoTracks": peer.incomingVideo.count])
                XCTAssertTrue(peer.incomingVideo.isEmpty)
            }
            evidence["independentPublishers"] = publishers
            let beat = heartbeat.evidence
            evidence["mainQueueDispatch"] = ["samples": beat.samples, "p95Seconds": beat.p95, "maximumSeconds": beat.maximum]
            XCTAssertLessThan(beat.p95, 0.08); XCTAssertLessThan(beat.maximum, 0.5)
            heartbeat.stop()
            cleaned = await cleanup(model: model, peers: peers)
            meeting.close(); XCTAssertTrue(cleaned)
            try await confirmAbsent(invitation: invitation, prefix: prefix)
            evidence["independentCleanupObserverConfirmedAbsent"] = true
        } catch {
            evidence["errorType"] = String(reflecting: type(of: error))
            let window = NSApp.windows.first { $0.delegate === meeting && !($0 is NSPanel) }
            evidence["failureStateBeforeCleanup"] = readinessEvidence(model: model, window: window)
            if let native = adapter.currentNativeEngine,
               let rows = try? await stats(native, deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 4)) {
                evidence["failureReceiverRTPBeforeCleanup"] = sanitizedRTP(rows)
            }
            cleaned = await cleanup(model: model, peers: peers)
            meeting.close(); XCTAssertTrue(cleaned)
            do { try await confirmAbsent(invitation: invitation, prefix: prefix); evidence["independentCleanupObserverConfirmedAbsent"] = true }
            catch { evidence["independentCleanupObserverConfirmedAbsent"] = false; XCTFail("Independent large-room cleanup observer failed") }
            throw error
        }
    }

    private func measure(_ phase: String, native: NativeGuestEngine, window: NSWindow,
                         expectedGPU: Int, expectedDecoders: Int, publishers: [NativeGuestEngine], deadline: Double) async throws -> [String: Any] {
        let publisherBefore = try await publisherEvidence(publishers, deadline: deadline)
        let before = try await stats(native, deadline: deadline)
        let gpu = sinks(window), start = ProcessInfo.processInfo.systemUptime, initial = try LargeRoomProcessSample.read()
        let sinkBefore = gpu.map(\.preparationEvidenceForTesting)
        var peak = initial.footprintMiB
        while ProcessInfo.processInfo.systemUptime - start < 5 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
            peak = max(peak, try LargeRoomProcessSample.read().footprintMiB)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let end = ProcessInfo.processInfo.systemUptime, final = try LargeRoomProcessSample.read()
        let after = try await stats(native, deadline: deadline)
        let publisherAfter = try await publisherEvidence(publishers, deadline: deadline)
        let rtp = advancingVideo(before: before, after: after, minimumFrames: 20)
        XCTAssertEqual(gpu.count, expectedGPU); XCTAssertEqual(rtp.count, expectedDecoders)
        let windows = gpu.map { $0.presentationWindow(from: start, to: end) }
        let callbackWindows = gpu.map { $0.inputWindowForTesting(from: start, to: end) }
        let stages = gpu.enumerated().map { index, sink -> [String: Any] in
            let after = sink.preparationEvidenceForTesting, before = sinkBefore[index]
            let counters = ["inputCallbacks", "advancingInputs", "preparationAttempts", "preparations", "nativePreparations", "genericPreparations", "replacedInputs", "submittedCommands"]
            return ["trackID": sink.trackIDForTesting ?? "", "callbacks": callbackWindows[index].evidence,
                "GPU": windows[index].evidence, "stageDeltas": Dictionary(uniqueKeysWithValues: counters.map { ($0, (after[$0] ?? 0) - (before[$0] ?? 0)) })]
        }
        for value in windows {
            XCTAssertTrue(value.complete); XCTAssertGreaterThanOrEqual(value.fps, 12)
            XCTAssertLessThan(value.maximumGap, 1); XCTAssertLessThan(value.endFrameAge ?? .infinity, 0.5)
        }
        let cpu = (final.cpuSeconds - initial.cpuSeconds) / (end - start) * 100
        XCTAssertLessThan(cpu, 800, "Combined local publishers plus receiver exceeded eight CPU cores")
        XCTAssertLessThan(peak, 2048, "Combined fixture physical footprint exceeded 2 GiB")
        XCTAssertLessThan(final.footprintMiB - initial.footprintMiB, 128)
        return ["phase": phase, "seconds": end - start, "CPUPercentOneCore100CombinedFixture": cpu,
            "initialFootprintMiBCombinedFixture": initial.footprintMiB, "peakFootprintMiBCombinedFixture": peak,
            "finalFootprintMiBCombinedFixture": final.footprintMiB,
            "expectedGPUCount": expectedGPU, "expectedDecoderCount": expectedDecoders,
            "GPUWindows": windows.map(\.evidence), "advancingInboundVideo": rtp,
            "mediaWindowStartUptime": start, "mediaWindowEndUptime": end, "rendererStages": stages,
            "receiverRTPBefore": sanitizedRTP(before), "receiverRTPAfter": sanitizedRTP(after),
            "publisherEvidenceBefore": publisherBefore, "publisherEvidenceAfter": publisherAfter]
    }
    private func sanitizedRTP(_ rows: [[String: Any]]) -> [[String: Any]] {
        // Keep complete RTP timing/codec counters and opaque transport IDs;
        // candidate addresses, credentials and invitation data are excluded.
        rows.filter { ["inbound-rtp", "outbound-rtp", "remote-inbound-rtp", "codec", "media-source", "transport"].contains($0["type"] as? String ?? "") }
    }
    private func publisherEvidence(_ peers: [NativeGuestEngine], deadline: Double) async throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for (index, peer) in peers.enumerated() {
            let evidence = try await bounded(8, deadline: deadline) { await peer.evidence() }
            result.append(["publisherIndex": index, "statisticsStartedUptime": evidence["statisticsStartedUptime"] ?? NSNull(),
                "statisticsCompletedUptime": evidence["statisticsCompletedUptime"] ?? NSNull(),
                "localVideo": evidence["localVideo"] ?? [:], "RTP": sanitizedRTP(evidence["stats"] as? [[String: Any]] ?? [])])
        }
        return result
    }
    private func readinessEvidence(model: NativeDesktopMeetingModel, window: NSWindow?) -> [String: Any] {
        let now = ProcessInfo.processInfo.systemUptime
        let renderers = window.map(sinks) ?? []
        return ["uptime": now, "page": model.galleryPage, "mode": model.viewMode.rawValue,
            "connected": model.connected, "windowVisible": window?.isVisible ?? false,
            "windowMiniaturized": window?.isMiniaturized ?? false,
            "windowOccluded": window.map { !$0.occlusionState.contains(.visible) } ?? true,
            "gallery": model.galleryParticipants.map { ["id": $0.id, "local": $0.isLocal,
                "cameraOn": $0.cameraOn as Any? ?? NSNull()] },
            "videos": model.videos.map { ["participantID": $0.participantID, "trackID": $0.track.trackId, "source": $0.source.rawValue] },
            "renderers": renderers.map { ["trackID": $0.trackIDForTesting ?? "", "frames": $0.frames,
                "state": $0.preparationEvidenceForTesting, "callbacksLast5s": $0.inputWindowForTesting(from: now - 5, to: now).evidence,
                "GPULast5s": $0.presentationWindow(from: now - 5, to: now).evidence] }]
    }
    private func advancingVideo(before: [[String: Any]], after: [[String: Any]], minimumFrames: Double,
                                requireCorrelatedBytes: Bool = true) -> [[String: Any]] {
        let baseline = Dictionary(before.compactMap { row -> (String, [String: Any])? in
            guard let id = row["id"] as? String else { return nil }; return (id, row)
        }, uniquingKeysWith: { _, last in last })
        return after.compactMap { row in
            guard row["target"] as? String == GuestPeerTarget.subscriber.rawValue, row["type"] as? String == "inbound-rtp", row["kind"] as? String == "video",
                  let id = row["id"] as? String else { return nil }
            let old = baseline[id] ?? [:], frames = number(row["framesDecoded"]) - number(old["framesDecoded"])
            let bytes = number(row["bytesReceived"]) - number(old["bytesReceived"])
            // Active media needs transported bytes AND decoded pictures.
            // Hidden quiescence must reject either independent kind of progress.
            guard requireCorrelatedBytes ? (frames >= minimumFrames && bytes > 0) : (frames > 0 || bytes > 0) else { return nil }
            return ["id": id, "framesDecodedDelta": frames, "bytesReceivedDelta": bytes,
                "packetsReceivedDelta": number(row["packetsReceived"]) - number(old["packetsReceived"]),
                "frameWidth": number(row["frameWidth"]), "frameHeight": number(row["frameHeight"]),
                "freezeCountDelta": number(row["freezeCount"]) - number(old["freezeCount"])]
        }
    }
    private func stats(_ native: NativeGuestEngine, deadline: Double) async throws -> [[String: Any]] {
        try await bounded(8, deadline: deadline) { await native.evidence()["stats"] as? [[String: Any]] ?? [] }
    }
    private func sinks(_ window: NSWindow) -> [CompanionVideoSink] {
        func walk(_ view: NSView) -> [CompanionVideoSink] {
            ([(view as? MTKView)?.delegate as? CompanionVideoSink].compactMap { $0 }) + view.subviews.flatMap(walk)
        }
        return window.contentView.map(walk) ?? []
    }
    private func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
    private func wait(_ message: String, deadline: Double, condition: () -> Bool) async throws {
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + 20)
        while ProcessInfo.processInfo.systemUptime < end {
            if condition() { return }; try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for \(message)"); throw URLError(.timedOut)
    }
    private func bounded<T>(_ seconds: Double, deadline: Double, operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let remaining = min(seconds, deadline - ProcessInfo.processInfo.systemUptime)
        guard remaining > 0 else { throw URLError(.timedOut) }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { @MainActor in try await operation() }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(remaining * 1e9)); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    private func cleanup(model: NativeDesktopMeetingModel, peers: [NativeGuestEngine]) async -> Bool {
        let receiver = Task { await model.leave() }
        let publishers = peers.map { peer in Task { await peer.leave() } }
        var clean = await receiver.value
        for task in publishers { clean = await task.value && clean }
        return clean
    }
    private func confirmAbsent(invitation: GuestInvitation, prefix: String) async throws {
        let observer = NativeGuestEngine(label: "Large-room cleanup observer", verifyReceivedPixels: false)
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        do {
            try await observer.setVisibleParticipantIDs([])
            try await bounded(20, deadline: deadline) { try await observer.join(invitation) }
            try await wait("independent observer confirms no disposable participants", deadline: deadline) {
                observer.meetingSnapshot.participants.contains { $0.isLocal } &&
                    !observer.meetingSnapshot.participants.contains { $0.name.hasPrefix(prefix) }
            }
            let clean = await observer.leave(); XCTAssertTrue(clean)
        } catch { _ = await observer.leave(); throw error }
    }
}

private enum LiveLargeRoomFailure: Error { case microphoneNotAuthorized }
