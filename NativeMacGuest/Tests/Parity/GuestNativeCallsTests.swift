import Foundation
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

/// A Guest peer's calls into WebRTC never block the main thread. When WebRTC's
/// threads are stuck (as behind the audio device after AirPods disappear), calls
/// time out while the app stays responsive, and later calls still run in order.
/// Synthetic audio only: no microphone or speaker is opened.
@MainActor final class GuestNativeCallsTests: XCTestCase {
    /// Counts main-queue ticks while `body` runs; a blocked main thread stops them.
    private func mainTicks(during body: () async throws -> Void) async rethrows -> Int {
        var ticks = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated { ticks += 1 }
        }
        defer { timer.invalidate() }
        try await body()
        return ticks
    }

    /// Beta 70: a startup-audio timeout read the audio route on the main thread while
    /// the system audio service held the device lock, and the app froze. The bounded
    /// read gives up, keeps the main thread running and never piles up stuck reads.
    func testStuckAudioRouteReadTimesOutWithoutBlockingMain() async throws {
        let release = DispatchSemaphore(value: 0)
        var answer: [String: Any] = [:]
        let ticks = await mainTicks {
            answer = await GuestAcousticEnvironment.boundedRoute(timeout: 0.3) { _ in release.wait(); return ["read": true] }
        }
        XCTAssertEqual(answer["unavailable"] as? String, "timeout")
        XCTAssertGreaterThan(ticks, 5, "the main thread kept running")
        let busy = await GuestAcousticEnvironment.boundedRoute(timeout: 0.3) { _ in ["read": true] }
        XCTAssertEqual(busy["unavailable"] as? String, "busy", "a second read does not queue behind the stuck one")
        release.signal()
        var fresh: [String: Any] = [:]
        for _ in 0..<50 {
            fresh = await GuestAcousticEnvironment.boundedRoute(timeout: 0.3) { _ in ["read": true] }
            if fresh["read"] != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(fresh["read"] as? Bool, true, "reads resume once the stuck one returns")
    }

    func testBlockedQueueTimesOutWithoutBlockingMainAndKeepsOrder() async throws {
        let calls = GuestNativeCalls(label: "test")
        var order: [String] = []
        let lock = NSLock()
        func record(_ name: String) { lock.lock(); order.append(name); lock.unlock() }
        let release = calls.blockForTesting()
        let started = Date()
        let ticks = try await mainTicks {
            do {
                _ = try await calls.run("late", timeout: 0.4) { record("late"); return 1 }
                XCTFail("A call behind a stuck native thread must time out")
            } catch GuestNativeCallError.timedOut(let name) { XCTAssertEqual(name, "late") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertGreaterThan(ticks, 5, "The main thread kept running while the native queue was stuck")
        calls.post("after") { record("after") }
        release()
        _ = try await calls.run("drain") { 0 }
        lock.lock(); let finished = order; lock.unlock()
        XCTAssertEqual(finished, ["late", "after"], "A timed-out call still runs, before later calls")
        XCTAssertEqual(calls.evidence.timedOut, 1)
    }

    func testStuckPeerKeepsMainResponsiveAndEndsMuted() async throws {
        let audio = GuestSyntheticAudio(); defer { XCTAssertTrue(audio.terminateDevice()) }
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: audio)
        let peer = try await GuestPeer(target: .publisher, factory: factory); defer { peer.close() }
        let microphone = try await peer.prepareAudio(cid: "mic")
        try await peer.attach(microphone, codec: "opus")
        peer.native.timeoutOverrideForTesting = 0.3

        let release = peer.native.blockForTesting()
        let ticks = try await mainTicks {
            let stats = await peer.stats()
            XCTAssertNil(stats, "Stats give up instead of waiting for stuck WebRTC threads")
            do { try await peer.setMuted(false, video: false); XCTFail("Unmute must time out") }
            catch GuestNativeCallError.timedOut {}
            // The privacy barrier is queued behind the pending unmute.
            peer.suppress(video: false)
        }
        XCTAssertGreaterThan(ticks, 10, "The main thread kept running while the peer was stuck")
        release()
        peer.native.timeoutOverrideForTesting = nil
        let enabled = try await peer.native.run("read") { microphone.isEnabled }
        XCTAssertFalse(enabled, "A late unmute cannot outlive a later mute")
        let recovered = await peer.stats()
        XCTAssertNotNil(recovered, "The peer works again once WebRTC recovers")
    }

    /// Telemost and TrueConf share the same rule through their own peer.
    func testStuckExternalPeerKeepsMainResponsiveAndEndsMuted() async throws {
        let audio = GuestSyntheticAudio(); defer { XCTAssertTrue(audio.terminateDevice()) }
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: audio)
        let peer = try await NativeDesktopRTCPeer(target: "PUBLISHER", factory: factory, ice: [])
        let microphone = try XCTUnwrap(peer.microphoneTrack)
        peer.native.timeoutOverrideForTesting = 0.3

        let release = peer.native.blockForTesting()
        let ticks = try await mainTicks {
            do { try await peer.configure(["iceServers": [] as [[String: Any]]]); XCTFail("Configuration must time out") }
            catch GuestNativeCallError.timedOut {}
            peer.setMicrophone(true)
            XCTAssertTrue(peer.microphoneSending)
            peer.setMicrophone(false)
            XCTAssertFalse(peer.microphoneSending)
            let level = await peer.microphoneLevel()
            XCTAssertNil(level)
        }
        XCTAssertGreaterThan(ticks, 10, "The main thread kept running while the peer was stuck")
        release()
        peer.native.timeoutOverrideForTesting = nil
        let enabled = try await peer.native.run("read") { microphone.isEnabled }
        XCTAssertFalse(enabled, "The later mute wins once WebRTC recovers")
        try await peer.configure(["iceServers": [] as [[String: Any]]])
        let closed = await peer.close(); XCTAssertTrue(closed)
    }
}
