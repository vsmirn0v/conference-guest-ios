import AppKit
import ConferenceCore
import CoreVideo
import Darwin
import LiveKitWebRTC
import MetalKit
import XCTest
@testable import RockNativeDesktop

/// Opt-in, camera/microphone/network-free qualification of the real signed
/// app's gallery and GPU renderers. Every participant owns an independent RTC
/// source/track, including off-page sources. This excludes codec/network cost.
@MainActor final class LargeRoomPerformanceTests: XCTestCase {
    func testSixParticipantMediaAndControls() async throws { try await qualify(participants: 6) }
    func testTwelveParticipantMediaAndControls() async throws { try await qualify(participants: 12) }
    func testTwentyFourParticipantMediaAndControls() async throws { try await qualify(participants: 24) }

    private func qualify(participants: Int) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NATIVE_DESKTOP_LARGE_ROOM"] == "1" else {
            throw XCTSkip("Set NATIVE_DESKTOP_LARGE_ROOM=1 for the signed-app synthetic RTC/GPU performance workload.")
        }
        let requested = Double(environment["NATIVE_DESKTOP_LARGE_ROOM_SECONDS"] ?? "8") ?? 8
        let seconds = requested.isFinite ? min(60, max(5, requested)) : 8
        let state = try LargeRoomSavedState()
        defer { state.restore() }
        let engine = try await LargeRoomEngine.make(count: participants)
        let model = NativeDesktopMeetingModel(destination: try .verified(URL(string: "https://large-room.invalid/calls/synthetic")!, engine: .guest),
            name: "Synthetic controller", title: "Synthetic large room · \(participants)", engine: engine)
        model.viewMode = .gallery
        let meeting = NativeDesktopMeetingWindow(model: model)
        let heartbeat = LargeRoomHeartbeat()
        heartbeat.start()
        defer { heartbeat.stop(); meeting.close() }
        var evidence: [String: Any] = ["kind": "synthetic-independent-WebRTC-tracks-real-AppKit-Metal",
            "participants": participants, "sourceFPS": 30, "sourceSize": "640x360",
            "CVSources": participants / 2, "I420Sources": participants / 2,
            "network": false, "codecDecode": false, "physicalCapture": false,
            "allOffPageSourcesContinueProducing": true,
            "host": ProcessInfo.processInfo.operatingSystemVersionString,
            "activeProcessors": ProcessInfo.processInfo.activeProcessorCount]
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "Synthetic large room \(participants) performance"; attachment.lifetime = .keepAlways; add(attachment)
                print("NATIVE_DESKTOP_LARGE_ROOM " + String(decoding: data, as: UTF8.self))
            }
        }
        do {
            // Avoid model.connect(): the fixture must never install headset or
            // permission integration. Only the injected engine publishes state.
            let sourcesStarted = uptime
            try await engine.connect(invitation: model.invitation, name: model.displayName, quiet: false)
            meeting.show()
            let native = try XCTUnwrap(NSApp.windows.first { $0.delegate === meeting && !($0 is NSPanel) })
            native.setContentSize(NSSize(width: 1120, height: 740))
            try await wait("First six independent tracks did not reach the GPU") { self.readySinks(native).count == 6 }
            var pageEvidence: [[String: Any]] = []
            for page in 0..<model.galleryPages {
                // Keep the old objects alive through retirement; an address-only
                // set permits allocator reuse to impersonate an old renderer.
                let previousSinks = sinks(native)
                let previous = Set(previousSinks.map(ObjectIdentifier.init))
                let transition = uptime
                model.galleryPage = page
                let expected = Set(engine.people.dropFirst(page * 6).prefix(6).map(\.id))
                let expectedTracks = Set(engine.producers.dropFirst(page * 6).prefix(6).map { $0.track.trackId })
                try await wait("Page \(page + 1) demand/renderers did not settle") {
                    let ready = self.readySinks(native)
                    return engine.lastDemand == expected && ready.count == 6 &&
                        Set(ready.compactMap(\.trackIDForTesting)) == expectedTracks &&
                        (page == 0 || (ready.allSatisfy { !previous.contains(ObjectIdentifier($0)) } &&
                            previousSinks.allSatisfy { $0.preparationEvidenceForTesting["active"] == 0 }))
                }
                let settled = uptime
                if page > 0 { try await verifyRetired(previousSinks) }
                let sinks = self.sinks(native)
                let start = uptime
                try await Task.sleep(nanoseconds: 1_250_000_000)
                let end = uptime
                let windows = sinks.map { $0.presentationWindow(from: start, to: end) }
                for window in windows { assertCadence(window) }
                XCTAssertLessThan(settled - transition, 2, "Page controls must not wait for an obsolete frame backlog")
                pageEvidence.append(["page": page + 1, "transitionSeconds": settled - transition,
                    "demandCount": engine.lastDemand?.count ?? -1, "GPUWindows": windows.map(\.evidence)])
            }
            evidence["pages"] = pageEvidence
            let previousPageSinks = sinks(native)
            let previousPage = Set(previousPageSinks.map(ObjectIdentifier.init))
            model.galleryPage = 0
            try await wait("First page did not remount") {
                let ready = self.readySinks(native)
                return engine.lastDemand == Set(engine.people.prefix(6).map(\.id)) && ready.count == 6 &&
                    Set(ready.compactMap(\.trackIDForTesting)) == Set(engine.producers.prefix(6).map { $0.track.trackId }) &&
                    (participants == 6 || (ready.allSatisfy { !previousPage.contains(ObjectIdentifier($0)) } &&
                        previousPageSinks.allSatisfy { $0.preparationEvidenceForTesting["active"] == 0 }))
            }
            if participants > 6 { try await verifyRetired(previousPageSinks) }
            try await Task.sleep(nanoseconds: 500_000_000)
            let steadySinks = sinks(native), start = uptime, initial = try LargeRoomProcessSample.read()
            var samples: [LargeRoomProcessSample] = [initial], controlLatencies: [Double] = [], peakMounted = 0, ticks = 0
            while uptime - start < seconds {
                engine.publishRosterTick(ticks)
                peakMounted = max(peakMounted, sinks(native).count)
                for sink in sinks(native) {
                    let state = sink.preparationEvidenceForTesting
                    for key in ["pendingInputs", "preparationInFlight", "drawScheduled", "gpuInFlight"] {
                        XCTAssertLessThanOrEqual(state[key] ?? -1, 1, "Unbounded renderer work: \(state)")
                    }
                }
                if ticks.isMultiple(of: 5) {
                    let began = uptime
                    let expectedMicrophone = !model.snapshot.microphoneOn, expectedPlayout = !model.snapshot.playoutOn
                    model.toggleMicrophone(); model.togglePlayout()
                    await model.waitForMediaActionsForTesting()
                    XCTAssertEqual(model.snapshot.microphoneOn, expectedMicrophone)
                    XCTAssertEqual(model.snapshot.playoutOn, expectedPlayout)
                    controlLatencies.append(uptime - began)
                }
                samples.append(try LargeRoomProcessSample.read())
                ticks += 1
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let end = uptime, final = try LargeRoomProcessSample.read()
            let windows = steadySinks.map { $0.presentationWindow(from: start, to: end) }
            for window in windows { assertCadence(window) }
            let cpuPercent = (final.cpuSeconds - initial.cpuSeconds) / (end - start) * 100
            let growthMiB = final.footprintMiB - initial.footprintMiB
            let peakMiB = samples.map(\.footprintMiB).max() ?? 0
            XCTAssertEqual(peakMounted, 6); XCTAssertEqual(engine.maximumDemand, 6)
            XCTAssertLessThan(cpuPercent, 400, "Gallery CPU budget is four fully occupied cores, including every synthetic producer")
            XCTAssertLessThan(peakMiB, 1024, "Synthetic gallery process footprint exceeded 1 GiB")
            XCTAssertLessThan(growthMiB, 96, "Warm steady gallery grew by more than 96 MiB")
            XCTAssertLessThan(controlLatencies.max() ?? .infinity, 0.5, "Media controls exceeded 500 ms")
            evidence["steady"] = ["seconds": end - start, "CPUPercentOneCore100": cpuPercent,
                "initialFootprintMiB": initial.footprintMiB, "finalFootprintMiB": final.footprintMiB,
                "peakFootprintMiB": peakMiB, "footprintGrowthMiB": growthMiB, "peakMountedRenderers": peakMounted,
                "controlLatencySeconds": controlLatencies, "GPUWindows": windows.map(\.evidence)]

            let retired = sinks(native), audioIntent = (model.snapshot.microphoneOn, model.snapshot.playoutOn)
            meeting.close()
            try await wait("Hidden meeting retained video demand/renderers") { engine.lastDemand == [] && self.sinks(native).isEmpty }
            try await verifyRetired(retired)
            XCTAssertEqual(model.snapshot.microphoneOn, audioIntent.0)
            XCTAssertEqual(model.snapshot.playoutOn, audioIntent.1)
            var churnFootprints: [Double] = []
            for _ in 0..<3 {
                meeting.show()
                try await wait("Gallery churn did not remount six fresh renderers") { self.readySinks(native).count == 6 && engine.lastDemand?.count == 6 }
                let old = sinks(native)
                meeting.close()
                try await wait("Gallery churn retained hidden demand") { engine.lastDemand == [] && self.sinks(native).isEmpty }
                try await verifyRetired(old)
                XCTAssertEqual(model.snapshot.microphoneOn, audioIntent.0)
                XCTAssertEqual(model.snapshot.playoutOn, audioIntent.1)
                churnFootprints.append(try LargeRoomProcessSample.read().footprintMiB)
            }
            XCTAssertLessThan((churnFootprints.max() ?? 0) - final.footprintMiB, 128, "Three hide/remount cycles retained more than 128 MiB")
            evidence["postChurnFootprintMiB"] = churnFootprints
            meeting.show()
            try await wait("Final gallery did not remount") { self.readySinks(native).count == 6 }
            let beforeLeave = sinks(native), leaving = uptime
            let clean = await model.leave()
            let sourcesStopped = uptime
            meeting.close()
            XCTAssertTrue(clean); XCTAssertLessThan(uptime - leaving, 2, "Leave must drain the bounded media workload")
            try await verifyRetired(beforeLeave)
            let stoppedCounts = engine.producers.map(\.frames)
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertEqual(engine.producers.map(\.frames), stoppedCounts, "A source survived Leave")
            XCTAssertTrue(stoppedCounts.allSatisfy { $0 > 30 }, "Every independent off-page source must actually produce")
            let sourceFPS = stoppedCounts.map { Double($0) / (sourcesStopped - sourcesStarted) }
            XCTAssertTrue(sourceFPS.allSatisfy { $0 >= 20 }, "The requested 30 fps source load did not sustain 20 fps: \(sourceFPS)")
            let beat = heartbeat.evidence
            XCTAssertGreaterThan(beat.samples, 100)
            XCTAssertLessThan(beat.p95, 0.08, "Main-queue heartbeat p95 exceeded 80 ms")
            XCTAssertLessThan(beat.maximum, 0.5, "Main queue stalled for 500 ms")
            evidence["heartbeat"] = ["samples": beat.samples, "p95Seconds": beat.p95, "maximumSeconds": beat.maximum]
            evidence["producerFrames"] = stoppedCounts
            evidence["producerFPS"] = sourceFPS
            evidence["CVPoolPressureDrops"] = engine.producers.map(\.poolPressureDrops)
            evidence["leaveSeconds"] = uptime - leaving - 0.15
            evidence["completedLifecycle"] = true
        } catch {
            _ = await model.leave(); meeting.close(); evidence["error"] = String(describing: error); throw error
        }
    }
    private var uptime: Double { ProcessInfo.processInfo.systemUptime }
    private func wait(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = uptime + 5
        while uptime < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail(message); throw LargeRoomFailure.failed(message)
    }
    private func sinks(_ window: NSWindow) -> [CompanionVideoSink] {
        func walk(_ view: NSView) -> [CompanionVideoSink] {
            ([(view as? MTKView)?.delegate as? CompanionVideoSink].compactMap { $0 }) + view.subviews.flatMap(walk)
        }
        return window.contentView.map(walk) ?? []
    }
    private func readySinks(_ window: NSWindow) -> [CompanionVideoSink] { sinks(window).filter { $0.frames >= 8 } }
    private func assertCadence(_ window: GuestFrameWindow) {
        XCTAssertTrue(window.complete); XCTAssertGreaterThanOrEqual(window.fps, 12)
        XCTAssertLessThan(window.maximumGap, 0.5, "GPU completion gap exceeded 500 ms")
        XCTAssertLessThan(window.endFrameAge ?? .infinity, 0.25)
    }
    private func verifyRetired(_ sinks: [CompanionVideoSink]) async throws {
        try await wait("Retired renderer did not drain its bounded in-flight work") {
            sinks.allSatisfy { $0.preparationEvidenceForTesting["preparationInFlight"] == 0 && $0.preparationEvidenceForTesting["gpuInFlight"] == 0 }
        }
        let counts = sinks.map(\.frames)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(sinks.map(\.frames), counts)
        for sink in sinks {
            let state = sink.preparationEvidenceForTesting
            XCTAssertEqual(state["active"], 0); XCTAssertEqual(state["pendingInputs"], 0)
            XCTAssertEqual(state["preparedTimestamp"], -1)
        }
    }
}

private enum LargeRoomFailure: Error { case failed(String) }

@MainActor final class NativeVideoVisibilityTests: XCTestCase {
    func testHiddenAndMinimizedPrivatePreviewReleasesOnlyItsRenderer() async throws {
        let producer = try await Task.detached {
            try LargeRoomProducer(factory: LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(),
                decoderFactory: LKRTCDefaultVideoDecoderFactory()), index: 0)
        }.value
        let coordinator = NativeDesktopVideoView.Coordinator(), host = NativeDesktopVideoHost()
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 320, height: 180),
            styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.onVisibilityChanged = { [weak coordinator, weak host] in
            guard let host else { return }; coordinator?.refreshVisibility(host: host)
        }
        coordinator.bind(track: producer.track, mirrored: true, crop: nil, zoom: 1.5, pan: .zero, host: host)
        producer.start()
        defer { host.stopObserving(); coordinator.detach(); window.close() }
        do {
            window.makeKeyAndOrderFront(nil)
            try await ready { (coordinator.sink?.frames ?? 0) >= 3 }
            let first = try XCTUnwrap(coordinator.sink)
            window.orderOut(nil)
            try await ready { coordinator.sink == nil }
            XCTAssertEqual(first.preparationEvidenceForTesting["active"], 0)
            XCTAssertTrue(coordinator.track === producer.track)
            let before = producer.frames
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertGreaterThan(producer.frames, before, "Occlusion must not stop a private or outgoing RTC source")
            window.makeKeyAndOrderFront(nil)
            try await ready { coordinator.sink !== first && (coordinator.sink?.frames ?? 0) >= 3 }
            let second = try XCTUnwrap(coordinator.sink)
            window.miniaturize(nil)
            try await ready { window.isMiniaturized && coordinator.sink == nil }
            XCTAssertEqual(second.preparationEvidenceForTesting["active"], 0)
            window.deminiaturize(nil)
            try await ready { coordinator.sink !== second && (coordinator.sink?.frames ?? 0) >= 3 }
            XCTAssertTrue(coordinator.track === producer.track)
            coordinator.detach(); await producer.stop()
        } catch { coordinator.detach(); await producer.stop(); throw error }
    }
    private func ready(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }; try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Real private-preview visibility/GPU transition timed out"); throw LargeRoomFailure.failed("Preview visibility transition timed out")
    }
}

@MainActor private final class LargeRoomEngine: NativeDesktopMeetingEngine {
    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    var factory: LKRTCPeerConnectionFactory? { nil }
    private(set) var snapshot = NativeDesktopExternalSnapshot()
    private(set) var incomingVideo: [NativeDesktopExternalVideo] = []
    let people: [NativeDesktopParticipant]
    let producers: [LargeRoomProducer]
    private(set) var lastDemand: Set<String>?
    private(set) var maximumDemand = 0
    private init(producers: [LargeRoomProducer]) {
        self.producers = producers
        people = producers.indices.map { .init(id: "synthetic-\($0)", name: "Independent participant \($0 + 1)", cameraOn: true) }
        incomingVideo = producers.enumerated().map {
            .init(id: "synthetic-track-\($0.offset)", participantID: people[$0.offset].id, source: .camera, track: $0.element.track)
        }
    }
    static func make(count: Int) async throws -> LargeRoomEngine {
        let producers = try await Task.detached {
            let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory())
            return try (0..<count).map { try LargeRoomProducer(factory: factory, index: $0) }
        }.value
        return .init(producers: producers)
    }
    func connect(invitation: URL, name: String, quiet: Bool) async throws {
        producers.forEach { $0.start() }
        snapshot = .init(phase: .connected, playoutOn: !quiet, participants: people)
        onVideo?(incomingVideo); onState?(snapshot)
    }
    func publishRosterTick(_ tick: Int) {
        snapshot.participants = people.enumerated().map { index, person in
            var person = person; person.speaking = index == tick % people.count; return person
        }
        onState?(snapshot)
    }
    func reconnect() async throws { onState?(snapshot) }
    func setMicrophone(_ enabled: Bool) async throws { snapshot.microphoneOn = enabled; onState?(snapshot) }
    func setCamera(_ enabled: Bool) async throws { snapshot.cameraOn = enabled; onState?(snapshot) }
    func setPlayout(_ enabled: Bool) async throws { snapshot.playoutOn = enabled; onState?(snapshot) }
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {}
    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?) async throws {
        lastDemand = ids; maximumDemand = max(maximumDemand, ids?.count ?? people.count)
    }
    func leave() async -> Bool {
        for producer in producers { await producer.stop() }
        incomingVideo = []; onVideo?([])
        snapshot = .init(phase: .left, playoutOn: false); onState?(snapshot); return true
    }
}

/// Four CV pool slots or four immutable planar buffers per independent source.
/// The renderer never receives a mutable buffer that the fixture reuses.
private final class LargeRoomProducer: @unchecked Sendable {
    let track: LKRTCVideoTrack
    private let factory: LKRTCPeerConnectionFactory
    private let source: LKRTCVideoSource
    private let capturer: LKRTCVideoCapturer
    private let queue = DispatchQueue(label: "native-large-room.source", qos: .userInitiated)
    private let lock = NSLock()
    private var count = 0, pressure = 0
    var frames: Int { lock.lock(); defer { lock.unlock() }; return count }
    var poolPressureDrops: Int { lock.lock(); defer { lock.unlock() }; return pressure }
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var planar: [LKRTCMutableI420Buffer] = []
    private let index: Int
    init(factory: LKRTCPeerConnectionFactory, index: Int) throws {
        self.factory = factory; self.index = index
        source = factory.videoSource(forScreenCast: true); capturer = LKRTCVideoCapturer(delegate: source)
        track = factory.videoTrack(with: source, trackId: "independent-large-room-\(index)")
        source.adaptOutputFormat(toWidth: 640, height: 360, fps: 30)
        if index.isMultiple(of: 2) {
            let fields: [CFString: Any] = [kCVPixelBufferWidthKey: 640, kCVPixelBufferHeightKey: 360,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [:]]
            guard CVPixelBufferPoolCreate(nil, nil, fields as CFDictionary, &pool) == kCVReturnSuccess else { throw LargeRoomFailure.failed("CV pool allocation failed") }
        } else {
            planar = (0..<4).map { phase in
                let buffer = LKRTCMutableI420Buffer(width: 640, height: 360)
                memset(buffer.mutableDataY, Int32(50 + phase * 35 + index), Int(buffer.strideY) * 360)
                memset(buffer.mutableDataU, Int32(80 + index), Int(buffer.strideU) * 180)
                memset(buffer.mutableDataV, Int32(150 - index), Int(buffer.strideV) * 180)
                return buffer
            }
        }
    }
    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.frame() }; self.timer = timer; timer.resume()
        }
    }
    private func frame() {
        autoreleasepool {
            let buffer: LKRTCVideoFrameBuffer
            if let pool {
                var pixel: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                    [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else {
                    lock.lock(); pressure += 1; lock.unlock(); return
                }
                CVPixelBufferLockBaseAddress(pixel, [])
                if let base = CVPixelBufferGetBaseAddress(pixel) {
                    memset(base, Int32(45 + index + count % 4 * 30), CVPixelBufferGetDataSize(pixel))
                }
                CVPixelBufferUnlockBaseAddress(pixel, [])
                buffer = LKRTCCVPixelBuffer(pixelBuffer: pixel)
            } else { buffer = planar[count % planar.count] }
            source.capturer(capturer, didCapture: LKRTCVideoFrame(buffer: buffer, rotation: ._0,
                timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1e9)))
            lock.lock(); count += 1; lock.unlock()
        }
    }
    func stop() async {
        await withCheckedContinuation { continuation in queue.async {
            self.timer?.cancel(); self.timer = nil; self.pool = nil; self.planar = []; continuation.resume()
        } }
    }
}

struct LargeRoomProcessSample {
    let cpuSeconds: Double
    let footprintMiB: Double
    static func read() throws -> Self {
        var usage = rusage(), info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw LargeRoomFailure.failed("Process CPU sampling failed") }
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw LargeRoomFailure.failed("Physical footprint sampling failed: \(status)") }
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        return .init(cpuSeconds: cpu, footprintMiB: Double(info.phys_footprint) / 1_048_576)
    }
}

final class LargeRoomHeartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var latencies: [Double] = []
    private var timer: DispatchSourceTimer?
    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "native-large-room.heartbeat", qos: .userInteractive))
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            let sent = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { [weak self] in
                let latency = ProcessInfo.processInfo.systemUptime - sent
                guard let self else { return }
                self.lock.lock(); self.latencies.append(latency); self.lock.unlock()
            }
        }
        timer.resume()
    }
    func stop() { timer?.cancel(); timer = nil }
    var evidence: (samples: Int, p95: Double, maximum: Double) {
        lock.lock(); defer { lock.unlock() }
        let sorted = latencies.sorted()
        return (sorted.count, sorted.isEmpty ? .infinity : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], sorted.last ?? .infinity)
    }
}

/// Preserve the app's real local files and window preference around each fixture.
struct LargeRoomSavedState {
    private let frame: Any?
    private let files: [(URL, Data?)]
    init() throws {
        frame = UserDefaults.standard.object(forKey: "NSWindow Frame nativeDesktop.meeting")
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("catch-up.json")
        files = try [url, url.appendingPathExtension("session")].map { ($0, FileManager.default.fileExists(atPath: $0.path) ? try Data(contentsOf: $0) : nil) }
    }
    func restore() {
        if let frame { UserDefaults.standard.set(frame, forKey: "NSWindow Frame nativeDesktop.meeting") }
        else { UserDefaults.standard.removeObject(forKey: "NSWindow Frame nativeDesktop.meeting") }
        for (url, data) in files {
            do {
                if let data { try data.write(to: url, options: .atomic) }
                else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } catch { XCTFail("Could not restore synthetic fixture state: \(error)") }
        }
    }
}
