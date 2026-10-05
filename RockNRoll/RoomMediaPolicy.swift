import LiveKit

/// Prefer the platform H.264 encoder and avoid encoding unused simulcast layers.
/// Capture, top-layer bitrate, audio and background policy retain SDK defaults.
enum RoomMediaPolicy {
    static var options: RoomOptions {
        RoomOptions(defaultVideoPublishOptions: videoOptions(preferredCodec: .h264), dynacast: true)
    }

    static func videoOptions(preferredCodec: VideoCodec?) -> VideoPublishOptions {
        VideoPublishOptions(simulcastLayers: [VideoParameters(dimensions: .h180_169,
            encoding: VideoEncoding(maxBitrate: 150_000, maxFps: 15))], preferredCodec: preferredCodec)
    }
}

/// A codec rejection is retried once with normal negotiation, then remembered
/// for this room. Other errors and cancellation never trigger a retry.
@MainActor
final class RoomVideoPublisher {
    private var options: VideoPublishOptions

    init(options: VideoPublishOptions = RoomMediaPolicy.options.defaultVideoPublishOptions) {
        self.options = options
    }

    func perform<T>(_ operation: (VideoPublishOptions) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let requested = options
        do {
            return try await operation(requested)
        } catch let error as LiveKitError where error.type == .codecNotSupported && requested.preferredCodec != nil {
            try Task.checkCancellation()
            // Preserve every encoding/capture policy when removing the preference.
            options = VideoPublishOptions(name: requested.name, encoding: requested.encoding,
                screenShareEncoding: requested.screenShareEncoding, simulcast: requested.simulcast,
                simulcastLayers: requested.simulcastLayers, screenShareSimulcastLayers: requested.screenShareSimulcastLayers,
                preferredCodec: nil, preferredBackupCodec: requested.preferredBackupCodec,
                degradationPreference: requested.degradationPreference, streamName: requested.streamName)
            return try await operation(options)
        }
    }
}
