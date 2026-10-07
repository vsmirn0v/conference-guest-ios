import XCTest
import AVFoundation
import LiveKit
import Network
@testable import RockNRoll

@MainActor
final class MediaEnergyTests: XCTestCase {
    func testPressureReducesOnlyOptionalCadenceAndRecoversWithoutOscillation() async throws {
        let budget = MediaEnergyBudget(observeSystem: false, recoveryDelay: 50_000_000)
        XCTAssertEqual(budget.inlineFPS, 30)
        budget.update(lowPower: true, thermal: .nominal)
        XCTAssertEqual(budget.previewFPS, 10)
        budget.update(lowPower: false, thermal: .critical)
        XCTAssertEqual(budget.previewFPS, 5)
        budget.update(lowPower: false, thermal: .nominal)
        XCTAssertEqual(budget.pressure, .severe, "Do not oscillate immediately on thermal changes")
        budget.update(lowPower: true, thermal: .critical)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(budget.pressure, .severe)
        budget.update(lowPower: false, thermal: .nominal)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(budget.previewFPS, 15)
    }
    func testBackgroundMeterDoesNotCalculatePCMUnlessFloatingVideoNeedsIt() throws {
        let meter = MicrophoneActivity(observeLifecycle: false)
        meter.setStatus(.on); meter.receive(rms: 0.2)
        XCTAssertTrue(meter.hasSignal)
        meter.setForeground(false)
        XCTAssertFalse(meter.samplingNeeded); XCTAssertFalse(meter.hasSignal)
        meter.receive(rms: 0.9); XCTAssertEqual(meter.level, 0)
        meter.setFloating(true); meter.receive(rms: 0.3)
        XCTAssertTrue(meter.samplingNeeded); XCTAssertTrue(meter.hasSignal)
        meter.setFloating(false); XCTAssertFalse(meter.hasSignal)
        meter.setForeground(true); XCTAssertTrue(meter.samplingNeeded)
        meter.setStatus(.unavailable); XCTAssertFalse(meter.samplingNeeded)
        let sink = MicrophoneSampleSink { _ in XCTFail("Hidden meter performed PCM work") }
        sink.setEnabled(false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!, frameCapacity: 480))
        buffer.frameLength = 480; sink.receive(buffer)
    }
    func testVideoDemandKeepsPiPStartupGraceAndRetiresClosedVideo() async throws {
        let old = FloatingVideoPreference.enabled; FloatingVideoPreference.enabled = true
        defer { FloatingVideoPreference.enabled = old }
        let demand = MeetingVideoDemand(observeLifecycle: false)
        demand.setForeground(false, graceNanoseconds: 20_000_000)
        XCTAssertTrue(demand.wantsVideo)
        demand.setFloating(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(demand.wantsVideo)
        demand.setFloating(false)
        XCTAssertFalse(demand.wantsVideo)
        demand.setForeground(true); XCTAssertTrue(demand.wantsVideo)
        demand.setForeground(false, graceNanoseconds: 20_000_000)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(demand.wantsVideo)
    }
    func testPiPSinkPrimesOnceThenProcessesOnlyWhenVisibleAndNeverAfterRetirement() async throws {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let frame = VideoFrame(dimensions: .init(width: 160, height: 90), rotation: ._0,
            timeStampNs: 1, buffer: CVPixelVideoBuffer(pixelBuffer: try XCTUnwrap(pixels)))
        var samples = 0
        let sink = RoomFloatingVideoSink { sample, _ in
            XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1); samples += 1
        }
        sink.render(frame: frame)
        for _ in 0..<100 where samples == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(samples, 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        for _ in 0..<30 { sink.render(frame: frame) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(samples, 1, "Idle PiP must not render alongside the main window")
        sink.setWanted(true, fps: 15); sink.render(frame: frame)
        for _ in 0..<100 where samples < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(samples, 2)
        sink.retire(); try await Task.sleep(nanoseconds: 100_000_000); sink.render(frame: frame)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(samples, 2)
    }
    func testConnectionProbeCancellationReturnsImmediatelyAndSuccessUsesEvents() async throws {
        let queue = DispatchQueue(label: "probe-test")
        let probe = MeetingServiceProbe(host: "127.0.0.1", port: 9, queue: queue)
        let task = Task { await probe.run(timeout: 10) }; task.cancel()
        let cancelled = await task.value; XCTAssertFalse(cancelled)
        let ready = expectation(description: "Listener ready")
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { connection in connection.start(queue: queue); connection.cancel() }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: queue); defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 2)
        let successful = await MeetingServiceProbe(host: "127.0.0.1", port: try XCTUnwrap(listener.port).rawValue, queue: queue).run()
        XCTAssertTrue(successful)
    }
}
