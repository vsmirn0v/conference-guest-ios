import AVFoundation
import XCTest
@testable import RockNRoll

@MainActor
final class MicrophoneActivityTests: XCTestCase {
    func testSignalRequiresPublishedAvailabilityAndResetsOnMuteOrHold() async {
        let meter = MicrophoneActivity()
        meter.receive(rms: 0.5)
        XCTAssertFalse(meter.hasSignal)
        meter.setStatus(.on); meter.receive(rms: 0.1)
        XCTAssertTrue(meter.hasSignal); XCTAssertGreaterThan(meter.level, 0)
        meter.setStatus(.muted)
        XCTAssertFalse(meter.hasSignal); XCTAssertEqual(meter.level, 0)
        meter.receive(rms: 0.9); XCTAssertEqual(meter.level, 0)
        meter.setStatus(.on); meter.receive(rms: 0.1)
        meter.setStatus(.unavailable)
        XCTAssertFalse(meter.hasSignal); XCTAssertEqual(meter.level, 0)
        meter.receive(rms: .nan); XCTAssertFalse(meter.hasSignal)
    }
    func testSilenceIsValidAndMissingDataExpires() async throws {
        let meter = MicrophoneActivity(); meter.setStatus(.on)
        meter.receive(rms: 0)
        XCTAssertTrue(meter.hasSignal); XCTAssertEqual(meter.level, 0)
        meter.receive(rms: 0.1)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertFalse(meter.hasSignal); XCTAssertEqual(meter.level, 0)
        XCTAssertEqual(meter.status, .on, "A missing meter must not imply a publication failure")
    }
    func testMicFillProducesVisiblePixelChangesWithoutLayoutChanges() {
        let meter = MicrophoneActivity(); meter.setStatus(.on)
        let view = MicrophoneActivityView(); view.bind(meter)
        view.frame = CGRect(x: 0, y: 0, width: 28, height: 36); view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let quiet = renderer.image { view.layer.render(in: $0.cgContext) }
        for _ in 0..<8 { meter.receive(rms: 1) }
        let loud = renderer.image { view.layer.render(in: $0.cgContext) }
        XCTAssertNotEqual(quiet.pngData(), loud.pngData(), "Mic fill must visibly change with real input level")
        let attachment = XCTAttachment(image: loud); attachment.name = "Microphone full input fill"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testMainCallButtonShowsMicFillAcrossConfigurationUpdatesAndRotation() throws {
        let meter = MicrophoneActivity()
        let button = AlignedCallButton(frame: .zero)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "mic.fill"); config.title = "Mic"
        config.baseForegroundColor = .white; button.configuration = config
        MicrophoneActivityView.install(on: button, model: meter)
        meter.setStatus(.on)
        let toolbar = CallToolbar(items: [button] + (0..<5).map { _ in AlignedCallButton(frame: .zero) })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        let host = UIViewController(); window.rootViewController = host
        host.view.addSubview(toolbar); window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for (size, rail) in [(CGSize(width: 359, height: 68), false), (CGSize(width: 56, height: 347), true), (CGSize(width: 359, height: 68), false)] {
            toolbar.frame = CGRect(origin: .zero, size: size); toolbar.arrange(rail: rail, largeText: false)
            toolbar.layoutIfNeeded(); button.layoutIfNeeded()
            button.configuration?.image = UIImage(systemName: "mic.fill")
            button.configuration?.baseForegroundColor = .orange
            button.setNeedsLayout(); button.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(bounds: button.bounds)
            meter.clear()
            let quiet = renderer.image { button.layer.render(in: $0.cgContext) }
            for _ in 0..<8 { meter.receive(rms: 1) }
            let loud = renderer.image { button.layer.render(in: $0.cgContext) }
            XCTAssertNotEqual(quiet.pngData(), loud.pngData(), "Visible call icon must animate after configuration updates in both layouts")
            let attachment = XCTAttachment(image: loud); attachment.name = rail ? "Landscape call microphone fill" : "Portrait call microphone fill"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
    func testGlyphShowsFirstSampleAndImmediateStatusChange() {
        let meter = MicrophoneActivity()
        let view = MicrophoneActivityView(); view.bind(meter)
        view.frame = CGRect(x: 0, y: 0, width: 26, height: 26); view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let muted = renderer.image { view.layer.render(in: $0.cgContext) }
        meter.setStatus(.on)
        let enabled = renderer.image { view.layer.render(in: $0.cgContext) }
        XCTAssertNotEqual(muted.pngData(), enabled.pngData(), "Status must render even before a level sample")
        meter.receive(rms: 1)
        let first = renderer.image { view.layer.render(in: $0.cgContext) }
        XCTAssertNotEqual(enabled.pngData(), first.pngData(), "The very first sample must fill the glyph")
        meter.setStatus(.muted)
        XCTAssertEqual(muted.pngData(), renderer.image { view.layer.render(in: $0.cgContext) }.pngData())
    }
    func testLogScaleBoundsAndPCMDownmix() throws {
        XCTAssertEqual(MicrophoneActivity.normalized(rms: 0), 0)
        XCTAssertEqual(MicrophoneActivity.normalized(rms: 1), 1)
        XCTAssertEqual(MicrophoneActivity.normalized(rms: 0.01), 1.0 / 3, accuracy: 0.001)
        XCTAssertEqual(MicrophoneActivity.normalized(rms: .infinity), 0)
        let buffer = try makeBuffer(rate: 8_000, frames: 160, value: 0.25)
        let result = expectation(description: "PCM measured")
        let sink = MicrophoneSampleSink { rms in XCTAssertEqual(rms, 0.25, accuracy: 0.001); result.fulfill() }
        sink.receive(buffer)
        wait(for: [result], timeout: 1)
    }
    func testSpeakerCheckIsShortAndPlayableWithoutFiles() throws {
        let player = try AVAudioPlayer(data: SpeakerCheck.tone())
        XCTAssertEqual(player.duration, 0.4, accuracy: 0.001)
    }
    func testPiPLevelUpdatesLeaveVideoAndBadgeGeometryIntact() throws {
        let video = UIView()
        let surface = FloatingVideoContentView(videoContent: video)
        let meter = MicrophoneActivity()
        surface.bindMicrophoneActivity(meter)
        surface.frame = CGRect(x: 0, y: 0, width: 144, height: 81)
        surface.setMicrophoneStatus(.on); surface.layoutIfNeeded()
        let badge = try XCTUnwrap(surface.subviews.first { $0.accessibilityIdentifier == "Floating microphone status" })
        let before = badge.frame
        meter.setStatus(.on)
        for value in [Float(0), 0.001, 0.1, 0.8, 0] { meter.receive(rms: value) }
        XCTAssertEqual(badge.frame, before)
        XCTAssertTrue(video.superview === surface)
        XCTAssertEqual(video.frame, surface.bounds)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: surface.bounds).image { surface.layer.render(in: $0.cgContext) })
        attachment.name = "PiP microphone fill"; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func makeBuffer(rate: Double, frames: AVAudioFrameCount, value: Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.floatChannelData![0].initialize(repeating: value, count: Int(frames))
        return buffer
    }
}

@MainActor
final class PrivateSoundCheckTests: XCTestCase {
    private final class Capture: PrivateMicrophoneCapturing {
        var running = false
        var starts = 0
        var stops = 0
        var onStop: (() -> Void)?
        var continuation: CheckedContinuation<Void, Never>?
        var delayed = false
        func start(standalone: Bool, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
            starts += 1
            if delayed { await withCheckedContinuation { continuation = $0 } }
            try Task.checkCancellation()
            running = true
        }
        func stop() { running = false; stops += 1; let callback = onStop; onStop = nil; callback?() }
    }
    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<100 { if predicate() { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Sound check did not settle")
    }
    func testMeetingCaptureRequiresAnExplicitMuteVerifier() {
        let capture = Capture()
        let check = PrivateSoundCheck(capture: capture)
        check.start(standalone: false)
        XCTAssertEqual(check.state, .failed); XCTAssertEqual(capture.starts, 0)
    }
    func testPrivateCheckAwaitsMuteNeverPublishesAndStopsOnUnmute() async {
        let capture = Capture()
        let model = StudioModel(audioControl: .noiseSuppression, privateMicrophone: capture)
        var mute: CheckedContinuation<Void, Never>?
        var publications = 0
        model.enableMicrophone = { publications += 1 }
        model.soundCheck.verifyMuted = { await withCheckedContinuation { mute = $0 } }
        model.open(.sound); model.testMicrophone()
        await settle { mute != nil }
        XCTAssertEqual(capture.starts, 0)
        mute?.resume()
        await settle { capture.running }
        XCTAssertEqual(publications, 0); XCTAssertFalse(model.microphoneOn)
        model.microphoneOn = true
        XCTAssertFalse(capture.running); XCTAssertEqual(model.soundCheck.state, .idle)
        model.end()
    }
    func testDismissOrHoldDuringPermissionDoesNotStartLate() async {
        for dismiss in [true, false] {
            let capture = Capture(); capture.delayed = true
            let model = StudioModel(audioControl: .noiseSuppression, privateMicrophone: capture)
            model.open(.sound); model.testMicrophone()
            await settle { capture.continuation != nil }
            if dismiss { model.close() } else { model.held = true }
            capture.continuation?.resume()
            await Task.yield(); await Task.yield()
            XCTAssertFalse(capture.running); XCTAssertEqual(model.soundCheck.state, .idle)
            model.end()
        }
    }
    func testRouteChangesAndInterruptionsDiscardPrivateAudio() async {
        let capture = Capture()
        let model = StudioModel(audioControl: .fullProcessing, privateMicrophone: capture)
        model.open(.sound); model.testMicrophone()
        await settle { capture.running }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        XCTAssertFalse(capture.running); XCTAssertEqual(model.soundCheck.state, .idle)
        model.testMicrophone(); await settle { capture.running }
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        XCTAssertFalse(capture.running); XCTAssertEqual(model.soundCheck.state, .idle)
        model.end()
    }
    func testMuteFailureDoesNotCaptureAndBackgroundStopsMeter() async {
        let capture = Capture()
        let model = StudioModel(audioControl: .noiseSuppression, privateMicrophone: capture)
        model.soundCheck.verifyMuted = { throw SoundCheckError.mute }
        model.open(.sound); model.testMicrophone()
        await settle { model.soundCheck.state == .failed }
        XCTAssertEqual(capture.starts, 0)
        model.soundCheck.verifyMuted = nil; model.testMicrophone()
        await settle { capture.running }
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertFalse(capture.running); XCTAssertEqual(model.soundCheck.state, .idle)
        model.end()
    }
    func testRealPrivateInput() async throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PRIVATE_MIC"] == "1" else { throw XCTSkip("Opt-in real capture") }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw XCTSkip("Microphone permission is required") }
        let check = PrivateSoundCheck()
        check.start(standalone: true)
        defer { check.stop() }
        await settle { check.state == .listening || check.state == .failed }
        XCTAssertEqual(check.state, .listening, check.error ?? "")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(check.activity.hasSignal, "No PCM arrived")
        check.stop()
        XCTAssertEqual(check.state, .idle)
    }
    func testStartupRouteConfigurationDoesNotCancelPrivateCapture() async {
        let capture = Capture(); capture.delayed = true
        let check = PrivateSoundCheck(capture: capture)
        check.start(standalone: true)
        await settle { capture.continuation != nil }
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue])
        XCTAssertEqual(check.state, .starting)
        capture.continuation?.resume(); await settle { check.capturing }
        check.stop(); XCTAssertFalse(capture.running)
    }
    func testDeactivationNotificationCannotRecursivelyStopCapture() async {
        let capture = Capture(); let check = PrivateSoundCheck(capture: capture)
        check.start(standalone: true); await settle { check.capturing }
        let before = capture.stops
        capture.onStop = {
            NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
                userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        }
        check.stop()
        XCTAssertEqual(capture.stops, before + 1)
        XCTAssertEqual(check.state, .idle); XCTAssertFalse(capture.running)
    }
}
