import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

@MainActor final class MediaSenderDiagnosticsTests: XCTestCase {
    func testSamplesRealTrackFlagBehindQueuedMute() async throws {
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(),
                                                 decoderFactory: LKRTCDefaultVideoDecoderFactory())
        let track = factory.audioTrack(with: factory.audioSource(with: nil), trackId: "private-fixture-id")
        let native = GuestNativeCalls(label: "diagnostic-test")
        let diagnostics = MediaSenderDiagnostics()
        let probe = native.microphoneTrackProbe(track, isCurrent: { true })
        native.post("enable") { track.isEnabled = true }
        let enabled = await diagnostics.sample([.companion: probe])
        XCTAssertEqual(enabled[.companion]?.reportFields["state"] as? String, "enabled")
        native.post("disable") { track.isEnabled = false }
        let disabled = await diagnostics.sample([.companion: probe])
        let fields = try XCTUnwrap(disabled[.companion]?.reportFields)
        XCTAssertEqual(fields["state"] as? String, "disabled")
        XCTAssertEqual(Set(fields.keys), ["state", "observedUptime"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(fields))
    }

    func testTimedOutProbeKeepsSlotAndOtherReadInSameReportSurvives() async {
        let diagnostics = MediaSenderDiagnostics()
        let other = MediaSenderDiagnostics.Source.meeting(UUID())
        var launches = 0
        var finishDelayed: GuestMicrophoneTrackProbe.Completion?
        let delayed = GuestMicrophoneTrackProbe(isCurrent: { true }) { _, finish in
            launches += 1
            finishDelayed = finish
        }
        let prompt = GuestMicrophoneTrackProbe(isCurrent: { true }) { _, finish in
            finish(.noTrack, ProcessInfo.processInfo.systemUptime)
        }
        let partial = await diagnostics.sample([.companion: delayed, other: prompt], timeout: 0.1)
        XCTAssertNil(partial[.companion])
        XCTAssertEqual(partial[other]?.state, .noTrack)
        let blocked = await diagnostics.sample([.companion: delayed], timeout: 0.1)
        XCTAssertTrue(blocked.isEmpty)
        XCTAssertEqual(launches, 1)
        let independent = await diagnostics.sample([other: prompt], timeout: 0.1)
        XCTAssertEqual(independent[other]?.state, .noTrack)

        finishDelayed?(.enabled, ProcessInfo.processInfo.systemUptime)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var next: [MediaSenderDiagnostics.Source: MediaSenderDiagnostics.Observation] = [:]
        while next.isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
            await Task.yield()
            next = await diagnostics.sample([.companion: prompt], timeout: 0.1)
        }
        XCTAssertEqual(next[.companion]?.state, .noTrack)
    }

    func testBlockedNativeQueueDoesNotRetainRetiredTrack() async throws {
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(),
                                                 decoderFactory: LKRTCDefaultVideoDecoderFactory())
        var track: LKRTCAudioTrack? = factory.audioTrack(with: factory.audioSource(with: nil),
                                                       trackId: "retirement-fixture")
        weak var retired = track
        let native = GuestNativeCalls(label: "diagnostic-retirement-test")
        let release = native.blockForTesting()
        defer { release() }
        let diagnostics = MediaSenderDiagnostics()
        let probe = native.microphoneTrackProbe(track, isCurrent: { true })
        let timedOut = await diagnostics.sample([.companion: probe], timeout: 0.05)
        XCTAssertTrue(timedOut.isEmpty)
        XCTAssertEqual(native.evidence.pending, 2)
        track = nil
        XCTAssertNil(retired, "Queued diagnostics must not retain a track past retirement")
    }

    func testStalledRockQueueDoesNotQueueMoreRockReadsOrHideNativeResults() async {
        let diagnostics = MediaSenderDiagnostics()
        let stalledRock = MediaSenderDiagnostics.Source.meeting(UUID())
        let otherRock = MediaSenderDiagnostics.Source.meeting(UUID())
        var rockLaunches = 0
        var finishStalled: GuestMicrophoneTrackProbe.Completion?
        let stalled = GuestMicrophoneTrackProbe(queue: .rockSDK, isCurrent: { true }) { _, finish in
            rockLaunches += 1
            finishStalled = finish
        }
        let readyRock = GuestMicrophoneTrackProbe(queue: .rockSDK, isCurrent: { true }) { _, finish in
            rockLaunches += 1
            finish(.enabled, ProcessInfo.processInfo.systemUptime)
        }
        let native = GuestMicrophoneTrackProbe(isCurrent: { true }) { _, finish in
            finish(.disabled, ProcessInfo.processInfo.systemUptime)
        }
        let timedOut = await diagnostics.sample([stalledRock: stalled], timeout: 0.05)
        XCTAssertTrue(timedOut.isEmpty)
        let independent = await diagnostics.sample([otherRock: readyRock, .companion: native])
        XCTAssertNil(independent[otherRock])
        XCTAssertEqual(independent[.companion]?.state, .disabled)
        XCTAssertEqual(rockLaunches, 1)
        finishStalled?(.enabled, ProcessInfo.processInfo.systemUptime)
    }

    func testRejectsRetiredConnectionBeforeAndAfterObservation() async throws {
        let diagnostics = MediaSenderDiagnostics()
        var current = true
        let retires = GuestMicrophoneTrackProbe(isCurrent: { current }) { _, finish in
            current = false
            finish(.enabled, ProcessInfo.processInfo.systemUptime)
        }
        let retired = await diagnostics.sample([.companion: retires])
        XCTAssertTrue(retired.isEmpty)

        current = true
        let live = GuestMicrophoneTrackProbe(isCurrent: { current }) { _, finish in
            finish(.enabled, ProcessInfo.processInfo.systemUptime)
        }
        let result = await diagnostics.sample([.companion: live])
        let observation = try XCTUnwrap(result[.companion])
        XCTAssertEqual(observation.reportFields["state"] as? String, "enabled")
        current = false
        XCTAssertEqual(observation.reportFields["state"] as? String, "unavailable")
        XCTAssertNil(observation.reportFields["observedUptime"])
    }
}
