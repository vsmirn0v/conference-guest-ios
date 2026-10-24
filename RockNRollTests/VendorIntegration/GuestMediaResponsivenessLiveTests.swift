import AVFoundation
import ConferenceCore
import ObjectiveC
import UIKit
import WebRTC
import XCTest
@testable import RockNRoll

/// Opt-in: independent synthetic participants must already be publishing.
@MainActor
final class GuestMediaResponsivenessLiveTests: XCTestCase {
    func testMediaControlsWithConcurrentIncomingStreams() async throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_RESPONSIVENESS_INVITE"] else {
            throw XCTSkip("Requires a disposable room with independent media publishers")
        }
        for media: AVMediaType in [.audio, .video] {
            if AVCaptureDevice.authorizationStatus(for: media) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: media)
            }
            guard AVCaptureDevice.authorizationStatus(for: media) == .authorized else {
                throw XCTSkip("Capture permission is needed for the live media-control check")
            }
        }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow })
        let original = window.rootViewController, host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore())
        let pulse = MainQueueLatencyProbe()
        defer { pulse.stop(); engine.leave(); window.rootViewController = original }
        var active = false, ended = false
        engine.onEvent = { event in
            if event == .active { active = true }
            if [.left, .failed, .canceled, .evicted].contains(event) { ended = true }
        }
        func wait(_ name: String, _ predicate: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while !predicate(), !ended, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard predicate(), !ended else {
                throw NSError(domain: "MediaResponsiveness", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out: " + name])
            }
        }
        let target = try JoinTarget.parse(invitation)
        try engine.configure(container: host, networkURL: await VendorEndpointResolver.make().resolve(for: target),
                             displayName: "Media controls QA")
        try engine.join(target: target, displayName: "Media controls QA")
        try await wait("connected media") { active && engine.hasReceivedVideoFrameForTesting }
        let required = Int(ProcessInfo.processInfo.environment["ROCKNROLL_TEST_RESPONSIVENESS_STREAMS"] ?? "1") ?? 1
        func incomingVideos(_ rows: [[String: Any]]) -> Int {
            rows.filter { $0["type"] as? String == "inbound-rtp" && $0["kind"] as? String == "video" &&
                (($0["framesDecoded"] as? NSNumber)?.intValue ?? 0) > 0 }.count
        }
        var before = await GuestMicrophoneProbe.codecEvidenceForTesting()
        let mediaDeadline = ProcessInfo.processInfo.systemUptime + 25
        while incomingVideos(before) < required, !ended, ProcessInfo.processInfo.systemUptime < mediaDeadline {
            try await Task.sleep(for: .seconds(1))
            before = await GuestMicrophoneProbe.codecEvidenceForTesting()
        }
        let inbound = before.filter { $0["type"] as? String == "inbound-rtp" }
        print("MEDIA_LOAD pid=\(getpid()) incomingVideo=\(incomingVideos(before)) incomingAudio=\(inbound.filter { $0["kind"] as? String == "audio" }.count)")
        guard incomingVideos(before) >= required else {
            throw NSError(domain: "MediaResponsiveness", code: 2, userInfo: [NSLocalizedDescriptionKey: "Required incoming load was not established"])
        }
        if let seconds = Double(ProcessInfo.processInfo.environment["ROCKNROLL_TEST_RESPONSIVENESS_MANUAL_SECONDS"] ?? ""), seconds > 0 {
            print("MEDIA_MANUAL_READY seconds=\(min(seconds, 300))")
            try await Task.sleep(for: .seconds(min(seconds, 300)))
            return
        }
        let peers = GuestPeerRegistry.snapshot().filter { $0.connectionState == .connected }
        let churnStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<30 { autoreleasepool { for peer in peers { _ = peer.transceivers.count; _ = peer.receivers.count } } }
        print("MEDIA_RECEIVER_WRAPPERS elapsed_ms=\((ProcessInfo.processInfo.systemUptime - churnStart) * 1000)")
        let packet = expectation(description: "Real receiver observer gets its first-packet callback")
        packet.assertForOverFulfill = false
        let delegate = FirstPacketDelegate(packet)
        let receiver = try XCTUnwrap(peers.flatMap { $0.receivers }.first { $0.track?.kind == "audio" })
        receiver.delegate = delegate
        await fulfillment(of: [packet], timeout: 3)
        receiver.delegate = nil
        pulse.start()
        let studio = engine.studioForTesting
        for cycle in 0..<4 {
            for enabled in [true, false] {
                let micStart = ProcessInfo.processInfo.systemUptime
                engine.setMicrophoneForTesting(enabled)
                let micReturned = ProcessInfo.processInfo.systemUptime
                try await wait("microphone state") { studio.microphoneOn == enabled }
                print("MEDIA_CONTROL cycle=\(cycle) kind=microphone on=\(enabled) synchronous_ms=\((micReturned-micStart)*1000) ready_ms=\((ProcessInfo.processInfo.systemUptime-micStart)*1000)")
                try await Task.sleep(for: .seconds(1))
                let cameraStart = ProcessInfo.processInfo.systemUptime
                engine.setCameraForTesting(enabled)
                let cameraReturned = ProcessInfo.processInfo.systemUptime
                try await wait("camera state") { studio.cameraOn == enabled }
                print("MEDIA_CONTROL cycle=\(cycle) kind=camera on=\(enabled) synchronous_ms=\((cameraReturned-cameraStart)*1000) ready_ms=\((ProcessInfo.processInfo.systemUptime-cameraStart)*1000)")
                try await Task.sleep(for: .seconds(1))
            }
        }
        pulse.stop()
        let after = await GuestMicrophoneProbe.codecEvidenceForTesting()
        func receivedBytes(_ rows: [[String: Any]], kind: String) -> Int64 {
            rows.filter { $0["type"] as? String == "inbound-rtp" && $0["kind"] as? String == kind }
                .reduce(0) { $0 + (($1["bytesReceived"] as? NSNumber)?.int64Value ?? 0) }
        }
        XCTAssertGreaterThan(receivedBytes(after, kind: "audio"), receivedBytes(before, kind: "audio"))
        XCTAssertGreaterThan(receivedBytes(after, kind: "video"), receivedBytes(before, kind: "video"))
        print("MEDIA_MAIN_QUEUE max_ms=\(pulse.maximumDelay * 1000)")
        XCTAssertLessThan(pulse.maximumDelay, 0.5, "Media controls must not block the UI queue")
    }
}

private final class MainQueueLatencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var pending = false
    private var maximum = 0.0
    var maximumDelay: Double { lock.lock(); defer { lock.unlock() }; return maximum }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "qa.main-queue-latency", qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.pending else { self.lock.unlock(); return }
            self.pending = true; self.lock.unlock()
            let start = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                self.lock.lock()
                let delay = ProcessInfo.processInfo.systemUptime - start
                if delay > 0.2 { print("MEDIA_MAIN_STALL queued_at=\(start) delay_ms=\(delay * 1000) time=\(Date().timeIntervalSince1970)") }
                self.maximum = max(self.maximum, delay)
                self.pending = false; self.lock.unlock()
            }
        }
        self.timer = timer; timer.resume()
    }
    func stop() { timer?.cancel(); timer = nil }
    deinit { timer?.cancel() }
}

private final class FirstPacketDelegate: NSObject, RTCRtpReceiverDelegate {
    let packet: XCTestExpectation
    init(_ packet: XCTestExpectation) { self.packet = packet }
    func rtpReceiver(_ rtpReceiver: RTCRtpReceiver, didReceiveFirstPacketFor mediaType: RTCRtpMediaType) {
        packet.fulfill()
    }
}

/// Observe the shipping guest SDK unchanged. Selected transport is measured,
/// never inferred from candidate.protocol (TURN/TCP candidates still say UDP).
@MainActor final class GuestUDPComparisonLiveTests: XCTestCase {
    func testOriginalSDKTransportAndCadence() async throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_UDP_INVITE"] else {
            throw XCTSkip("Requires an authorized disposable room with a steady generated publisher")
        }
        let requestedPolicy = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_UDP_TRANSPORT"] ?? "auto"
        guard ["auto", "tcp-relay"].contains(requestedPolicy) else { XCTFail("Unsupported comparison transport"); return }
        let tcpOverride: SDKTestTCPRelayOverride?
        if requestedPolicy == "tcp-relay" {
            GuestPeerRegistry.prepare()
            tcpOverride = try SDKTestTCPRelayOverride()
        } else { tcpOverride = nil }
        defer { tcpOverride?.restore() }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        let original = window.rootViewController, host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore())
        var active = false, ended = false
        var taps: [(peer: RTCPeerConnection, track: RTCVideoTrack, tap: SDKCadenceTap)] = []
        func refreshTaps() {
            let current = GuestPeerRegistry.snapshot().filter { $0.connectionState == .connected }.flatMap { peer in
                peer.receivers.compactMap { receiver -> (peer: RTCPeerConnection, track: RTCVideoTrack)? in
                    guard let track = receiver.track as? RTCVideoTrack else { return nil }
                    return (peer, track)
                }
            }
            taps.removeAll { observed in
                // WebRTC returns fresh wrappers; isEqual compares native track identity.
                guard !current.contains(where: { $0.peer === observed.peer && $0.track.isEqual(observed.track) }) else { return false }
                observed.tap.stop(); observed.track.remove(observed.tap)
                return true
            }
            for received in current where !taps.contains(where: { $0.peer === received.peer && $0.track.isEqual(received.track) }) {
                let tap = SDKCadenceTap()
                received.track.add(tap)
                taps.append((received.peer, received.track, tap))
            }
        }
        defer {
            for observed in taps { observed.tap.stop(); observed.track.remove(observed.tap) }
            engine.leave(); window.rootViewController = original
        }
        engine.onEvent = { event in
            if event == .active { active = true }
            if [.left, .failed, .canceled, .evicted].contains(event) { ended = true }
        }
        let target = try JoinTarget.parse(invitation)
        try engine.configure(container: host, networkURL: await VendorEndpointResolver.make().resolve(for: target), displayName: "Original SDK UDP comparison")
        try engine.join(target: target, displayName: "Original SDK UDP comparison")
        let deadline = ProcessInfo.processInfo.systemUptime + 40
        while !ended, ProcessInfo.processInfo.systemUptime < deadline {
            refreshTaps()
            if active && taps.contains(where: { $0.tap.count >= 10 }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(ended); XCTAssertTrue(active)
        guard taps.contains(where: { $0.tap.count >= 10 }) else { XCTFail("Fresh SDK video did not arrive"); return }
        let churn = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_GUEST_UDP_CHURN"] == "1"
        func outgoingCounters() async -> [[String:Any]] {
            var result: [[String:Any]] = []
            for peer in GuestPeerRegistry.snapshot() where peer.connectionState == .connected {
                let report: RTCStatisticsReport = await withCheckedContinuation { done in peer.statistics { done.resume(returning: $0) } }
                for stat in report.statistics.values where stat.type == "outbound-rtp" {
                    result.append(["peer": String(ObjectIdentifier(peer).hashValue), "id": stat.id,
                        "kind": stat.values["kind"] as Any, "packetsSent": stat.values["packetsSent"] ?? 0,
                        "framesEncoded": stat.values["framesEncoded"] ?? 0])
                }
            }
            return result
        }
        if churn {
            engine.setMicrophoneForTesting(true); engine.setCameraForTesting(true)
            try await Task.sleep(for: .seconds(2)) // Initial capture setup; not a measured toggle.
        }
        for index in 0..<12 {
            let captureBefore = churn ? await outgoingCounters() : []
            let cameraOn = churn && index % 4 != 2
            let microphoneOn = churn && index % 4 != 0
            let start = ProcessInfo.processInfo.systemUptime
            if churn {
                engine.setMicrophoneForTesting(microphoneOn)
                engine.setCameraForTesting(cameraOn)
            }
            let controlsReturnedUptime = ProcessInfo.processInfo.systemUptime
            refreshTaps()
            repeat {
                try await Task.sleep(for: .milliseconds(100))
                refreshTaps()
            } while ProcessInfo.processInfo.systemUptime < start + 5
            let end = ProcessInfo.processInfo.systemUptime
            let frames = taps.map { observed -> [String: Any] in
                var row = observed.tap.window(start: start, end: end)
                row["peer"] = String(ObjectIdentifier(observed.peer).hashValue)
                row["track"] = String(ObjectIdentifier(observed.track).hashValue)
                return row
            }
            var snapshots: [[String: Any]] = []
            for peer in GuestPeerRegistry.snapshot() where peer.connectionState == .connected {
                let report: RTCStatisticsReport = await withCheckedContinuation { done in peer.statistics { done.resume(returning: $0) } }
                let pairs = Set(report.statistics.values.filter { $0.type == "transport" }.compactMap { $0.values["selectedCandidatePairId"] as? String })
                let candidateIDs = Set(report.statistics.values.filter { pairs.contains($0.id) }.flatMap {
                    [$0.values["localCandidateId"] as? String, $0.values["remoteCandidateId"] as? String].compactMap { $0 }
                })
                let keys = ["kind", "framesEncoded", "framesSent", "bytesSent", "packetsSent", "framesDecoded", "framesReceived", "framesPerSecond", "frameWidth", "frameHeight", "bytesReceived", "packetsReceived", "packetsLost", "nackCount", "pliCount", "freezeCount", "totalFreezesDuration", "jitterBufferDelay", "jitterBufferEmittedCount", "totalDecodeTime", "codecId", "mimeType", "iceState", "dtlsState", "selectedCandidatePairId", "localCandidateId", "remoteCandidateId", "protocol", "relayProtocol", "candidateType"]
                let rows = report.statistics.values.filter { ["inbound-rtp", "outbound-rtp", "codec", "transport"].contains($0.type) || pairs.contains($0.id) || candidateIDs.contains($0.id) }.map { stat -> [String: Any] in
                    var row: [String: Any] = ["id": stat.id, "type": stat.type, "nativeTimestampUS": stat.timestamp_us]
                    for key in keys { row[key] = stat.values[key] }
                    return row
                }
                let config = peer.configuration
                let urls = config.iceServers.flatMap(\.urlStrings)
                if tcpOverride != nil {
                    XCTAssertEqual(config.iceTransportPolicy, .relay, "SDK changed the requested relay policy")
                    XCTAssertFalse(urls.isEmpty, "No advertised TCP relay was retained")
                    XCTAssertTrue(urls.allSatisfy(SDKTestTCPRelayOverride.isTCPRelay), "SDK changed the TCP-only server configuration")
                    let locals = rows.filter { $0["type"] as? String == "local-candidate" }
                    XCTAssertFalse(locals.isEmpty, "Selected local candidate evidence is missing")
                    XCTAssertTrue(locals.allSatisfy {
                        $0["candidateType"] as? String == "relay" && ["tcp", "tls"].contains($0["relayProtocol"] as? String ?? "")
                    }, "TCP control did not select an advertised TCP/TLS relay")
                }
                snapshots.append(["peer": String(ObjectIdentifier(peer).hashValue), "iceTransportPolicy": config.iceTransportPolicy.rawValue,
                    "tcpCandidatePolicy": config.tcpCandidatePolicy.rawValue,
                    "senders": peer.senders.compactMap { sender -> [String:Any]? in
                        guard let track = sender.track else { return nil }
                        return ["kind": track.kind, "enabled": track.isEnabled]
                    },
                    "turnTCPURLs": urls.filter { $0.contains("?transport=tcp") }.count,
                    "turnUDPURLs": urls.filter { $0.contains("?transport=udp") }.count, "stats": rows])
            }
            let evidence: [String: Any] = ["event": "original-sdk-window", "window": index, "start": start, "end": end,
                "active": active, "ended": ended, "applicationState": UIApplication.shared.applicationState.rawValue,
                "captureChurn": churn, "microphoneIntent": microphoneOn, "cameraIntent": cameraOn,
                "captureBefore": captureBefore, "controlsReturnedUptime": controlsReturnedUptime,
                "cameraAuthorization": AVCaptureDevice.authorizationStatus(for: .video).rawValue,
                "requestedPolicy": requestedPolicy, "factoryControl": tcpOverride?.evidence ?? [:],
                "frames": frames, "peers": snapshots]
            let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
            print("ORIGINAL_SDK_UDP " + String(decoding: data, as: UTF8.self))
            XCTAssertFalse(ended)
        }
        if let tcpOverride { XCTAssertGreaterThan(tcpOverride.evidence["appliedConfigurations"] ?? 0, 0) }
        engine.leave()
        let leaveDeadline = ProcessInfo.processInfo.systemUptime + 15
        while !ended, ProcessInfo.processInfo.systemUptime < leaveDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(ended, "Wait for SDK asynchronous Leave before the test host exits")
    }
}

/// Dedicated test-process control. Forward the installed registry hooks and
/// temporarily alter only advertised ICE endpoints while native creation copies them.
private final class SDKTestTCPRelayOverride {
    private var implementations: [(Method, IMP, IMP)] = []
    private let lock = NSRecursiveLock()
    private var appliedConfigurations = 0
    private var configurationsWithoutTCP = 0

    init() throws {
        let selector = #selector(RTCPeerConnectionFactory.peerConnection(with:constraints:delegate:))
        let verifiedSelector = #selector(RTCPeerConnectionFactory.peerConnection(with:constraints:certificateVerifier:delegate:))
        guard let method = class_getInstanceMethod(RTCPeerConnectionFactory.self, selector),
              let verifiedMethod = class_getInstanceMethod(RTCPeerConnectionFactory.self, verifiedSelector) else {
            throw NSError(domain: "SDKTransportComparison", code: 1)
        }
        typealias Create = @convention(c) (AnyObject, Selector, RTCConfiguration, RTCMediaConstraints, AnyObject?) -> RTCPeerConnection?
        let original = method_getImplementation(method)
        let create = unsafeBitCast(original, to: Create.self)
        let forward: @convention(block) (AnyObject, RTCConfiguration, RTCMediaConstraints, AnyObject?) -> RTCPeerConnection? = { [self] factory, configuration, constraints, delegate in
            withTCPConfiguration(configuration) { create(factory, selector, configuration, constraints, delegate) }
        }
        let replacement = imp_implementationWithBlock(forward)
        implementations.append((method, original, replacement))
        method_setImplementation(method, replacement)

        typealias VerifiedCreate = @convention(c) (AnyObject, Selector, RTCConfiguration, RTCMediaConstraints, AnyObject, AnyObject?) -> RTCPeerConnection?
        let verifiedOriginal = method_getImplementation(verifiedMethod)
        let verifiedCreate = unsafeBitCast(verifiedOriginal, to: VerifiedCreate.self)
        let verifiedForward: @convention(block) (AnyObject, RTCConfiguration, RTCMediaConstraints, AnyObject, AnyObject?) -> RTCPeerConnection? = { [self] factory, configuration, constraints, verifier, delegate in
            withTCPConfiguration(configuration) { verifiedCreate(factory, verifiedSelector, configuration, constraints, verifier, delegate) }
        }
        let verifiedReplacement = imp_implementationWithBlock(verifiedForward)
        implementations.append((verifiedMethod, verifiedOriginal, verifiedReplacement))
        method_setImplementation(verifiedMethod, verifiedReplacement)
    }

    static func isTCPRelay(_ text: String) -> Bool {
        guard !text.contains(where: { $0.isWhitespace }), let colon = text.firstIndex(of: ":"),
              ["turn", "turns"].contains(text[..<colon].lowercased()) else { return false }
        let fields = text[text.index(after: colon)...].split(separator: "?", omittingEmptySubsequences: false)
        return fields.count == 2 && !fields[0].isEmpty &&
            !fields[0].contains(where: { "/@#".contains($0) }) && fields[1] == "transport=tcp"
    }

    private func withTCPConfiguration(_ configuration: RTCConfiguration,
                                      create: () -> RTCPeerConnection?) -> RTCPeerConnection? {
        lock.lock(); defer { lock.unlock() }
        let servers = configuration.iceServers.compactMap { server -> RTCIceServer? in
            let urls = server.urlStrings.filter(Self.isTCPRelay)
            guard !urls.isEmpty else { return nil }
            return RTCIceServer(urlStrings: urls, username: server.username, credential: server.credential,
                tlsCertPolicy: server.tlsCertPolicy, hostname: server.hostname,
                tlsAlpnProtocols: server.tlsAlpnProtocols, tlsEllipticCurves: server.tlsEllipticCurves)
        }
        guard !servers.isEmpty else {
            configurationsWithoutTCP += 1
            return create() // The control's runtime assertions reject an unapplied filter.
        }
        let originalServers = configuration.iceServers, originalPolicy = configuration.iceTransportPolicy
        configuration.iceServers = servers; configuration.iceTransportPolicy = .relay
        defer { configuration.iceServers = originalServers; configuration.iceTransportPolicy = originalPolicy }
        appliedConfigurations += 1
        return create()
    }

    var evidence: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return ["appliedConfigurations": appliedConfigurations, "configurationsWithoutTCP": configurationsWithoutTCP]
    }

    func restore() {
        for (method, original, replacement) in implementations.reversed() {
            method_setImplementation(method, original)
            imp_removeBlock(replacement)
        }
        implementations.removeAll()
    }
}

private final class SDKCadenceTap: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private let epoch = UUID().uuidString
    private let observedFrom = ProcessInfo.processInfo.systemUptime
    private var active = true
    private var times: [Double] = []
    private var lastTimestamp: Int64?
    var count: Int { lock.lock(); defer { lock.unlock() }; return times.count }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock(); defer { lock.unlock() }
        guard active, lastTimestamp.map({ frame.timeStampNs > $0 }) ?? true else { return }
        lastTimestamp = frame.timeStampNs
        times.append(ProcessInfo.processInfo.systemUptime)
        if times.count > 4096 { times.removeFirst(1024) }
    }
    func stop() { lock.lock(); active = false; lock.unlock() }
    func window(start: Double, end: Double) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let fresh = times.filter { $0 > start && $0 <= end }
        let bounds = [times.last(where: { $0 <= start }) ?? start] + fresh + [end]
        let gap = zip(bounds, bounds.dropFirst()).map { $1 - $0 }.max() ?? (end-start)
        return ["epoch": epoch, "observedFrom": observedFrom, "completeWindow": observedFrom <= start,
            "frames": fresh.count, "fps": Double(fresh.count)/(end-start), "maximumGap": gap,
            "endFrameAge": times.last(where: { $0 <= end }).map { end - $0 } ?? (end-start)]
    }
}
