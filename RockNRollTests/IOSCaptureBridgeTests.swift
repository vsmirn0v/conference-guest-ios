import ConferenceCore
import CoreVideo
import LiveKitWebRTC
import XCTest
@testable import MeetingEngine
@testable import RockNRoll

@MainActor
final class IOSCaptureBridgeTests: XCTestCase {
    private final class FrameCountingRenderer: NSObject, LKRTCVideoRenderer {
        private let lock = NSLock()
        private(set) var renderedCount = 0
        private(set) var lastDimensions: (Int32, Int32) = (0, 0)

        func setSize(_ size: CGSize) {}

        func renderFrame(_ frame: LKRTCVideoFrame?) {
            guard let frame else { return }
            lock.lock()
            renderedCount += 1
            let rotated = frame.rotation == ._90 || frame.rotation == ._270
            lastDimensions = (
                Int32(rotated ? frame.height : frame.width),
                Int32(rotated ? frame.width : frame.height)
            )
            lock.unlock()
        }

        var snapshot: (count: Int, width: Int32, height: Int32) {
            lock.lock()
            defer { lock.unlock() }
            return (renderedCount, lastDimensions.0, lastDimensions.1)
        }
    }

    @MainActor
    private final class MockShareAdapter: MeetingProviderAdapter {
        let kind: MeetingEngineKind
        let capabilities: MeetingSessionCapabilities
        var connectionIdentity: MeetingConnectionIdentity?
        var snapshot = NativeDesktopExternalSnapshot(phase: .idle)
        var sessionSnapshot = MeetingSessionSnapshot(phase: .idle)
        var incomingVideo: [NativeDesktopExternalVideo] = []
        let factory: LKRTCPeerConnectionFactory?
        var privateAudioLevel: Float? { nil }
        var ownershipDiagnostics: [String: Any] { [:] }
        var microphoneTrackProbe: GuestMicrophoneTrackProbe? { nil }
        var microphoneStartupMilliseconds: [String: Double] { [:] }
        var microphoneReadinessPolicy: (() -> Bool)?
        var localScreenTrack: LKRTCVideoTrack? { receivedScreenTrack }
        let supportsScreenSharePublication: Bool

        var onState: ((NativeDesktopExternalSnapshot) -> Void)?
        var onSessionSnapshot: ((MeetingSessionSnapshot) -> Void)?
        var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
        var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
        var onTitle: ((String) -> Void)?
        var onFeatures: ((GuestMeetingSnapshot) -> Void)?
        var onCapturedMessages: (([GuestMeetingMessage], Bool) -> Void)?
        var onFeatureError: ((Error) -> Void)?

        var startedRelayInfo: GuestCameraInfo?
        var stoppedShareCount = 0
        var receivedScreenTrack: LKRTCVideoTrack?
        var activeRelayCapture: (any GuestCameraCapture)?
        var screenTrackRenderer: FrameCountingRenderer?
        var waitForAttachedScreenFrame = false

        init(kind: MeetingEngineKind, supportsPublication: Bool, factory: LKRTCPeerConnectionFactory) {
            self.kind = kind
            self.supportsScreenSharePublication = supportsPublication
            self.capabilities = supportsPublication ? .guest(supportsScreenShareVP9: true) : .rock()
            self.factory = factory
            self.sessionSnapshot = MeetingSessionSnapshot(phase: .idle, capabilities: self.capabilities)
        }

        func connect(invitation: URL, name: String, quiet: Bool, sessionID: MeetingSessionID) async throws {
            connectionIdentity = MeetingConnectionIdentity(sessionID: sessionID, provider: kind, generation: UUID())
            snapshot.phase = .connected
            sessionSnapshot.phase = .connected
            onState?(snapshot)
            onSessionSnapshot?(sessionSnapshot)
        }

        func reconnect() async throws {}

        func leave() async -> Bool {
            snapshot.phase = .left
            sessionSnapshot.phase = .left
            onState?(snapshot)
            onSessionSnapshot?(sessionSnapshot)
            return true
        }

        func setMicrophone(_ enabled: Bool) async throws {}
        func setCamera(_ enabled: Bool) async throws {}
        func setPlayout(_ enabled: Bool) async throws {}
        func setPlayoutVolume(_ volume: Double) async {}
        func setParticipantVolume(_ volume: Double, participantID: String) async {}
        func configureConcurrentAudio(_ concurrent: Bool) {}
        func setPhysicalInputPermitted(_ permitted: Bool, keepDeviceWarm: Bool) async -> Bool { true }
        func prewarmInput() async -> Bool { true }
        func prepareMutedCaptureForAccessories() async throws {}
        func setMicrophoneReadinessForRecovery(_ enabled: Bool) {}

        func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {
            if let existing = receivedScreenTrack, let renderer = screenTrackRenderer {
                existing.remove(renderer)
            }
            screenTrackRenderer = nil
            receivedScreenTrack = track
            if let track, waitForAttachedScreenFrame {
                let renderer = FrameCountingRenderer()
                screenTrackRenderer = renderer
                track.add(renderer)
                for _ in 0..<40 where renderer.snapshot.count == 0 {
                    try await Task.sleep(for: .milliseconds(25))
                }
            }
            snapshot.sharing = track != nil
            sessionSnapshot.effective.sharing = track != nil
        }

        func startScreenShare(_ request: MeetingScreenShareRequest) async throws {
            let relaySource = try XCTUnwrap(factory).videoSource(forScreenCast: true)
            let relay = request.captureFactory(relaySource)
            activeRelayCapture = relay
            startedRelayInfo = try await relay.start()
            snapshot.sharing = true
            sessionSnapshot.effective.sharing = true
        }

        func stopScreenShare() async throws {
            stoppedShareCount += 1
            try? await activeRelayCapture?.stop()
            activeRelayCapture = nil
            receivedScreenTrack = nil
            snapshot.sharing = false
            sessionSnapshot.effective.sharing = false
        }

        func setVideoDemand(_ demand: MeetingEngine.MeetingVideoDemand) async throws {}
        func cameraCaptureDevice() async -> AVCaptureDevice? { nil }
        func startPrivateAudioCheck() async throws {}
        func stopPrivateAudioCheck() async throws {}
        func setLocalAudioSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) {}
        func setTranscriptionAudioHandler(_ handler: (([MeetingAudioSource]) -> Void)?) {}
        func setTranscriptionOutput(_ keep: Bool) async -> Bool { false }
        func setTranscriptionRequested(_ requested: Bool) {}
        func setMicrophoneGate(open: Bool) async -> Bool { true }
        func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool { false }
    }

    override func tearDown() {
        IOSCameraCapture.syntheticModeForTesting = false
        UniversalMeetingEngine.defaultCameraCaptureFactory = nil
        super.tearDown()
    }

    func testIOSCameraCaptureDefaultFactoryDeliveringPortraitAndLandscapeFramesAndFlip() async throws {
        IOSCameraCapture.syntheticModeForTesting = true
        IOSCameraCapture.installAsDefaultFactory()

        let factory = LKRTCPeerConnectionFactory(
            encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory(),
            audioDevice: nil
        )
        let source = factory.videoSource()
        let track = factory.videoTrack(with: source, trackId: "ios-cam-test")
        let renderer = FrameCountingRenderer()
        track.add(renderer)

        let capture = try XCTUnwrap(UniversalMeetingEngine.defaultCameraCaptureFactory?(source) as? IOSCameraCapture)
        let info = try await capture.start()
        XCTAssertEqual(info.width, 1280)
        XCTAssertEqual(info.height, 720)
        XCTAssertEqual(info.fps, 30)
        XCTAssertTrue(info.mirrored)
        XCTAssertEqual(capture.currentPosition, .front)

        let landscapeBuffer = try makePixelBuffer(width: 1280, height: 720)
        capture.injectFrameForTesting(pixelBuffer: landscapeBuffer, rotation: ._0, timestampNs: 1_000_000_000)
        XCTAssertEqual(capture.snapshot().frames, 1)
        XCTAssertEqual(capture.snapshot().advancingPTS, 1)
        XCTAssertEqual(capture.snapshot().width, 1280)
        XCTAssertEqual(capture.snapshot().height, 720)

        // Portrait frame represented via 1280x720 buffer with 90-degree rotation.
        capture.injectFrameForTesting(pixelBuffer: landscapeBuffer, rotation: ._90, timestampNs: 1_033_333_333)
        XCTAssertEqual(capture.snapshot().frames, 2)
        XCTAssertEqual(capture.snapshot().advancingPTS, 2)
        XCTAssertEqual(capture.snapshot().width, 720)
        XCTAssertEqual(capture.snapshot().height, 1280)

        try await capture.flipCamera()
        XCTAssertEqual(capture.currentPosition, .back)

        try await capture.stop()
        XCTAssertEqual(NativeDesktopCameraLease.shared.ownershipDiagnostics["reservation"] as? String, "none")
        track.remove(renderer)
    }

    func testScreenShareCapturePublishesSingleFrameImmediatelyForGuestAndTrackForOtherProviders() async throws {
        let factory = LKRTCPeerConnectionFactory(
            encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory(),
            audioDevice: nil
        )
        let frameBuffer = try makePixelBuffer(width: 1920, height: 1080)

        // 1. Provider with dedicated screen share publication (.guest) resolves start() immediately on a single frame via initialFrame.
        let guestAdapter = MockShareAdapter(kind: .guest, supportsPublication: true, factory: factory)
        let guestSession = MeetingSession(kind: .guest, adapter: guestAdapter)
        let guestURL = try JoinDestination.verified(URL(string: "https://jazz.example.com/share-test")!, engine: .guest).invitationURL
        try await guestSession.connect(invitation: guestURL, name: "Host", quiet: false)

        let guestShare = IOSScreenShareCapture(session: guestSession, preview: LocalSharePreview())
        guestShare.startForTesting()
        guestShare.sendFrameForTesting(frameBuffer, timestamp: 2_000_000_000)
        for _ in 0..<20 where !guestShare.isSharing {
            await guestShare.waitForPublishForTesting()
            await Task.yield()
        }
        XCTAssertTrue(guestShare.isSharing)
        XCTAssertEqual(guestAdapter.startedRelayInfo?.deviceName, "Presenter canvas")
        XCTAssertEqual(guestAdapter.startedRelayInfo?.width, 1920)
        XCTAssertEqual(guestAdapter.startedRelayInfo?.height, 1080)
        XCTAssertEqual(guestAdapter.activeRelayCapture?.snapshot().frames, 1)

        await guestShare.stop()
        XCTAssertFalse(guestShare.isSharing)
        XCTAssertEqual(guestAdapter.stoppedShareCount, 1)
        _ = await guestSession.leave()

        // 2. Track-based provider (.community / .telemost / .trueconf) attaches and clears sender.track directly.
        let rockAdapter = MockShareAdapter(kind: .community, supportsPublication: false, factory: factory)
        let rockSession = MeetingSession(kind: .community, adapter: rockAdapter)
        let rockURL = try JoinDestination.verified(URL(string: "https://rock.glowsoft.ru/jams/test")!, engine: .community).invitationURL
        try await rockSession.connect(invitation: rockURL, name: "Host", quiet: false)

        let rockShare = IOSScreenShareCapture(session: rockSession, preview: LocalSharePreview())
        rockShare.startForTesting()
        rockShare.sendFrameForTesting(frameBuffer, timestamp: 3_000_000_000)
        for _ in 0..<20 where !rockShare.isSharing {
            await rockShare.waitForPublishForTesting()
            await Task.yield()
        }
        XCTAssertTrue(rockShare.isSharing)
        XCTAssertTrue(rockAdapter.receivedScreenTrack === rockShare.screenTrackForTesting)

        await rockShare.stop()
        XCTAssertFalse(rockShare.isSharing)
        XCTAssertNil(rockAdapter.receivedScreenTrack)
        _ = await rockSession.leave()
    }

    func testScreenShareCaptureReplaysStaticFrameForAttachedRendererAndSupportsPresenter() async throws {
        let factory = LKRTCPeerConnectionFactory(
            encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory(),
            audioDevice: nil
        )
        let frameBuffer = try makePixelBuffer(width: 1280, height: 720)

        let rockAdapter = MockShareAdapter(kind: .community, supportsPublication: false, factory: factory)
        rockAdapter.waitForAttachedScreenFrame = true
        let rockSession = MeetingSession(kind: .community, adapter: rockAdapter)
        let rockURL = try JoinDestination.verified(URL(string: "https://rock.glowsoft.ru/jams/static-share")!, engine: .community).invitationURL
        try await rockSession.connect(invitation: rockURL, name: "Host", quiet: false)

        let preview = LocalSharePreview(isMac: false, observeLifecycle: false)
        let capture = IOSScreenShareCapture(session: rockSession, preview: preview)
        capture.startForTesting()
        capture.sendFrameForTesting(frameBuffer, timestamp: 4_000_000_000)
        for _ in 0..<40 where !capture.isSharing {
            await capture.waitForPublishForTesting()
            await Task.yield()
        }
        XCTAssertTrue(capture.isSharing)
        XCTAssertGreaterThanOrEqual(rockAdapter.screenTrackRenderer?.snapshot.count ?? 0, 1)

        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frameBuffer, formatDescriptionOut: &formatDescription), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: 5, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frameBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: try XCTUnwrap(formatDescription), sampleTiming: &timing, sampleBufferOut: &sampleBuffer), noErr)

        try await capture.startComposed(initialSample: try XCTUnwrap(sampleBuffer))
        XCTAssertTrue(capture.isSharing)
        XCTAssertTrue(capture.isComposedSharing)
        XCTAssertEqual(preview.source, .presenter)
        XCTAssertGreaterThanOrEqual(rockAdapter.screenTrackRenderer?.snapshot.count ?? 0, 1)

        await capture.stop()
        XCTAssertFalse(capture.isSharing)
        _ = await rockSession.leave()
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw XCTSkip("CVPixelBufferCreate failed with status \(status)")
        }
        return pixelBuffer
    }
}
