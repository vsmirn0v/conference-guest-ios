import LiveKit
import XCTest
@testable import RockNRoll

@MainActor
final class RoomMediaPolicyTests: XCTestCase {
    func testProductionUsesQualifiedHardwareProfileAndSinglePeerTransport() {
        let options = RoomMediaPolicy.options, baseline = RoomOptions()
        let video = options.defaultVideoPublishOptions
        XCTAssertTrue(options.dynacast)
        XCTAssertTrue(options.singlePeerConnection)
        XCTAssertTrue(video.simulcast)
        XCTAssertEqual(video.preferredCodec, .h264)
        XCTAssertEqual(video.simulcastLayers, [VideoParameters(dimensions: .h180_169,
            encoding: VideoEncoding(maxBitrate: 150_000, maxFps: 15))])
        XCTAssertEqual(video.encoding, baseline.defaultVideoPublishOptions.encoding)
        XCTAssertEqual(video.screenShareEncoding, baseline.defaultVideoPublishOptions.screenShareEncoding)
        XCTAssertEqual(video.screenShareSimulcastLayers, baseline.defaultVideoPublishOptions.screenShareSimulcastLayers)
        XCTAssertEqual(video.degradationPreference, baseline.defaultVideoPublishOptions.degradationPreference)
        XCTAssertEqual(options.defaultCameraCaptureOptions, baseline.defaultCameraCaptureOptions)
        XCTAssertEqual(options.defaultScreenShareCaptureOptions, baseline.defaultScreenShareCaptureOptions)
        XCTAssertEqual(options.defaultAudioCaptureOptions, baseline.defaultAudioCaptureOptions)
        XCTAssertEqual(options.defaultAudioPublishOptions, baseline.defaultAudioPublishOptions)
        XCTAssertFalse(options.suspendLocalVideoTracksInBackground, "Supported PiP capture must not be explicitly suspended by the SDK")
    }

    func testCodecRejectionRetriesAutomaticallyAndSticksOnlyForThisRoom() async throws {
        let publisher = RoomVideoPublisher()
        var attempted: [VideoCodec?] = []
        let result = try await publisher.perform { options in
            attempted.append(options.preferredCodec)
            if options.preferredCodec != nil { throw LiveKitError(.codecNotSupported) }
            XCTAssertEqual(options.simulcastLayers, RoomMediaPolicy.options.defaultVideoPublishOptions.simulcastLayers)
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(attempted, [.h264, nil])
        try await publisher.perform { options in XCTAssertNil(options.preferredCodec) }
        try await RoomVideoPublisher().perform { options in XCTAssertEqual(options.preferredCodec, .h264) }
    }

    func testPermissionErrorDoesNotRetryOrChangeCodecPreference() async throws {
        let publisher = RoomVideoPublisher()
        var attempts = 0
        do {
            try await publisher.perform { _ in attempts += 1; throw LiveKitError(.insufficientPermissions) }
            XCTFail("Permission failure was hidden")
        } catch let error as LiveKitError { XCTAssertEqual(error.type, .insufficientPermissions) }
        XCTAssertEqual(attempts, 1)
        try await publisher.perform { options in XCTAssertEqual(options.preferredCodec, .h264) }
    }

    func testCodecFallbackPreservesCustomPublishingParameters() async throws {
        let original = VideoPublishOptions(name: "Camera fixture",
            encoding: VideoEncoding(maxBitrate: 900_000, maxFps: 24),
            screenShareEncoding: VideoEncoding(maxBitrate: 3_000_000, maxFps: 20),
            simulcast: false, preferredCodec: .h264, preferredBackupCodec: .vp8, streamName: "fixture")
        try await RoomVideoPublisher(options: original).perform { options in
            if options.preferredCodec != nil { throw LiveKitError(.codecNotSupported) }
            XCTAssertEqual(options.name, original.name)
            XCTAssertEqual(options.encoding, original.encoding)
            XCTAssertEqual(options.screenShareEncoding, original.screenShareEncoding)
            XCTAssertEqual(options.simulcast, original.simulcast)
            XCTAssertEqual(options.simulcastLayers, original.simulcastLayers)
            XCTAssertEqual(options.screenShareSimulcastLayers, original.screenShareSimulcastLayers)
            XCTAssertEqual(options.preferredBackupCodec, original.preferredBackupCodec)
            XCTAssertEqual(options.degradationPreference, original.degradationPreference)
            XCTAssertEqual(options.streamName, original.streamName)
        }
    }

    func testFailedAutomaticRetryIsNotRepeated() async {
        let publisher = RoomVideoPublisher()
        var attempts = 0
        do {
            try await publisher.perform { _ in attempts += 1; throw LiveKitError(.codecNotSupported) }
            XCTFail("Automatic negotiation failure was hidden")
        } catch let error as LiveKitError { XCTAssertEqual(error.type, .codecNotSupported) }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(attempts, 2)
    }

    func testCancelledOperationNeverPublishes() async {
        var attempts = 0
        let task = Task { @MainActor in
            try await RoomVideoPublisher().perform { _ in attempts += 1 }
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancellation was hidden") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(attempts, 0)
    }
}
