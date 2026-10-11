#if DEBUG
import Foundation
import LiveKitWebRTC
import Network
import XCTest
@testable import RockNRoll

/// Real encoded Opus and NetEq playout through a local UDP impairment relay.
/// Opt-in, entirely synthetic PCM, no microphone/session/server changes.
@MainActor
final class ReceiveAudioCatchUpTests: XCTestCase {
    func testAudioCatchUpABThroughIdenticalPacketDelayTrace() async throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_AUDIO_CATCH_UP"] == "1" else {
            throw XCTSkip("Opt-in 50-second synthetic packet-delay comparison")
        }
        for mode in [ReceiveAudioCatchUpExperiment.baseline, .fast] {
            try await run(mode)
        }
    }
    func testConfigurationIsExplicitAndPreservesBufferCapacity() async throws {
        defer { ReceiveAudioCatchUpExperiment.overrideForTesting = nil }
        ReceiveAudioCatchUpExperiment.overrideForTesting = .fast
        let peer = try NativeRTCPeer(target: "CATCH_UP_CONFIGURATION", factory: NativeRTCPeer.makeFactory(), ice: [])
        XCTAssertTrue(peer.connection.configuration.audioJitterBufferFastAccelerate)
        XCTAssertEqual(peer.connection.configuration.audioJitterBufferMaxPackets, LKRTCConfiguration().audioJitterBufferMaxPackets)
        ReceiveAudioCatchUpExperiment.overrideForTesting = nil
        await peer.close()
    }
    private func run(_ mode: ReceiveAudioCatchUpExperiment) async throws {
        _ = LKRTCInitializeSSL()
        let device = MicrophoneFixtureDevice()
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: device)
        ReceiveAudioCatchUpExperiment.overrideForTesting = .baseline
        let sender = try NativeRTCPeer(target: "PUBLISHER", factory: factory, ice: [])
        ReceiveAudioCatchUpExperiment.overrideForTesting = mode
        let receiver = try NativeRTCPeer(target: "SUBSCRIBER", factory: factory, ice: [])
        ReceiveAudioCatchUpExperiment.overrideForTesting = nil
        XCTAssertEqual(receiver.connection.configuration.audioJitterBufferFastAccelerate, mode.fastAccelerate)
        let relay = try AudioPacketDelayRelay()
        let port = try await relay.start()
        sender.onCandidate = { value in Task { @MainActor in try? await relay.add(value, from: 0, to: receiver, port: port) } }
        receiver.onCandidate = { value in Task { @MainActor in try? await relay.add(value, from: 1, to: sender, port: port) } }
        defer { relay.stop(); ReceiveAudioCatchUpExperiment.overrideForTesting = nil }
        do {
            sender.setMicrophone(true, profile: .music)
            func strip(_ value: [String: Any]) -> [String: Any] {
                var result = value
                if let sdp = value["sdp"] as? String {
                    result["sdp"] = sdp.components(separatedBy: "\r\n").filter { !$0.hasPrefix("a=candidate:") && $0 != "a=end-of-candidates" }.joined(separator: "\r\n")
                }
                return result
            }
            let offer = try await sender.offer(), answer = try await receiver.answer(strip(offer))
            sender.localSDPSent(); receiver.localSDPSent(); try await sender.accept(strip(answer))
            let deadline = Date().addingTimeInterval(8)
            while receiver.connection.iceConnectionState != .connected && receiver.connection.iceConnectionState != .completed && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard [LKRTCIceConnectionState.connected, .completed].contains(receiver.connection.iceConnectionState) else {
                XCTFail("Relay baseline did not connect: sender=\(sender.connection.iceConnectionState.rawValue), receiver=\(receiver.connection.iceConnectionState.rawValue)")
                throw NativeRTCError.disconnected
            }
            try await Task.sleep(for: .seconds(2))
            device.resetWindow(); try await Task.sleep(for: .seconds(1))
            XCTAssertGreaterThan(device.window.rms, 0.01, "Reject an A/B comparison without decoded non-silent audio")
            var windows = ReceiveDelayStatistics()
            let start = ProcessInfo.processInfo.systemUptime
            relay.beginTrace()
            for index in 0..<18 {
                let report: LKRTCStatisticsReport = await withCheckedContinuation { continuation in receiver.connection.statistics { continuation.resume(returning: $0) } }
                let records = report.statistics.values.filter { $0.type == "inbound-rtp" && $0.values["kind"] as? String == "audio" }.compactMap {
                    ReceiveDelayStatistics.record(id: $0.id, time: $0.timestamp_us / 1_000_000, values: $0.values)
                }
                for value in windows.ingest(records) {
                    func text(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "unavailable" }
                    print("AUDIO_CATCH_UP,mode=\(mode.rawValue),second=\(index),elapsed=\(ProcessInfo.processInfo.systemUptime - start),jitter_ms=\(text(value.jitterMS)),target_ms=\(text(value.targetMS)),minimum_ms=\(text(value.minimumMS)),concealed=\(text(value.concealedFraction)),accelerated=\(text(value.accelerationFraction))")
                }
                try await Task.sleep(for: .seconds(1))
            }
            XCTAssertGreaterThan(device.window.rms, 0.01)
            XCTAssertGreaterThan(relay.delayedMediaPackets, 10, "The experiment must actually impair encrypted media packets")
            print("AUDIO_CATCH_UP_CONTENT,mode=\(mode.rawValue),samples=\(device.window.samples),rms=\(device.window.rms),delayed=\(relay.delayedMediaPackets)")
            await sender.close(); await receiver.close()
        } catch { await sender.close(); await receiver.close(); throw error }
    }
}

/// Formal ICE candidate fields are rewritten to this local relay. Both peers
/// keep their ICE credentials/DTLS/SRTP intact. Only encrypted RTP/RTCP gets the
/// deterministic delay; STUN and DTLS pass through unchanged.
private final class AudioPacketDelayRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.audio-packet-delay")
    private let listener: NWListener
    private var connections: [Int: NWConnection] = [:]
    private var pending: [Int: [Data]] = [:]
    private var candidatePorts: [UInt16: Int] = [:]
    private var chosen = Set<Int>()
    private var traceStart: Double?
    private var sequence = 0
    private let lock = NSLock()
    private var delayed = 0
    var delayedMediaPackets: Int { lock.lock(); defer { lock.unlock() }; return delayed }
    init() throws { listener = try NWListener(using: .udp, on: .any) }
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            if case .hostPort(_, let port) = connection.endpoint, let side = self.candidatePorts[port.rawValue] {
                print("AUDIO_RELAY_CONNECTION side=\(side) endpoint=\(connection.endpoint)")
                self.connections[side]?.cancel(); self.connections[side] = connection
                for data in self.pending.removeValue(forKey: side) ?? [] { connection.send(content: data, completion: .contentProcessed { _ in }) }
                self.receive(connection, side: side)
            } else { print("AUDIO_RELAY_UNMATCHED endpoint=\(connection.endpoint)"); connection.cancel() }
        }
        return try await withCheckedThrowingContinuation { completion in
            let readiness = RelayReadiness(completion)
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let port = self?.listener.port { readiness.finish(.success(port.rawValue)) }
                else if case .failed(let error) = state { readiness.finish(.failure(error)) }
            }
            listener.start(queue: queue)
        }
    }
    @MainActor func add(_ value: [String: Any], from side: Int, to peer: NativeRTCPeer, port: UInt16) async throws {
        guard let sdp = value["candidate"] as? String else { return }
        var fields = sdp.split(separator: " ").map(String.init)
        guard fields.count >= 8, fields[2].lowercased() == "udp", fields[7] == "host", let originalPort = UInt16(fields[5]),
              !fields[4].contains(":"), fields[1] == "1" else { return }
        let accept = queue.sync { () -> Bool in
            guard !chosen.contains(side) else { return false }
            chosen.insert(side); candidatePorts[originalPort] = side; return true
        }
        guard accept else { return }
        print("AUDIO_RELAY_CANDIDATE side=\(side) port=\(originalPort) address=\(fields[4]) mid=\(String(describing: value["sdpMid"]))")
        // Keep the reachable host interface; WebRTC may exclude loopback pairs.
        fields[5] = String(port)
        var candidate = value; candidate["candidate"] = fields.joined(separator: " ")
        // The production WebSocket serializer normalizes the Int32 MID index.
        // This in-process fixture performs the same numeric normalization.
        candidate["sdpMlineIndex"] = (value["sdpMlineIndex"] as? NSNumber)?.intValue
        try await peer.addCandidate(candidate)
    }
    func beginTrace() { queue.sync { traceStart = ProcessInfo.processInfo.systemUptime; sequence = 0 } }
    func stop() { queue.sync { listener.cancel(); connections.values.forEach { $0.cancel() }; connections.removeAll(); pending.removeAll(); traceStart = nil } }
    private func receive(_ connection: NWConnection, side: Int) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, error == nil else { return }
            if let data, !data.isEmpty {
                let destination = 1 - side
                var delay = 0.0
                if side == 0, data[0] & 0xc0 == 0x80, let start = self.traceStart {
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    self.sequence += 1
                    // 3s clean; 4s increased/jittering delay; then clean again.
                    if elapsed >= 3 && elapsed < 7 {
                        delay = 0.12 + Double(self.sequence % 5) * 0.025
                        self.lock.lock(); self.delayed += 1; self.lock.unlock()
                    }
                }
                self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    if let target = self.connections[destination] { target.send(content: data, completion: .contentProcessed { _ in }) }
                    else if self.pending[destination, default: []].count < 16 { self.pending[destination, default: []].append(data) }
                }
            }
            self.receive(connection, side: side)
        }
    }
}
private final class RelayReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func finish(_ result: Result<UInt16, Error>) {
        lock.lock(); let completion = continuation; continuation = nil; lock.unlock()
        completion?.resume(with: result)
    }
}
#endif
