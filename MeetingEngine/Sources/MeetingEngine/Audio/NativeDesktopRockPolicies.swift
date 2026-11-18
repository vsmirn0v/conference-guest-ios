import CoreGraphics
import Foundation
import LiveKit

public struct NativeRockRemoteTrack: Equatable {
    public enum Kind { case audio, camera, screen }
    public let id: String
    public let participantID: String
    public let kind: Kind
    public var muted = false
    public var ready = false
    public init(id: String, participantID: String, kind: Kind, muted: Bool = false, ready: Bool = false) {
        self.id = id; self.participantID = participantID; self.kind = kind; self.muted = muted; self.ready = ready
    }
}
public struct NativeRockTrackDemand: Equatable {
    public let subscribed: Bool
    public let ready: Bool
    public let primary: Bool
    public var preferredFPS: UInt { primary ? 30 : 15 }
    public init(subscribed: Bool, ready: Bool, primary: Bool) {
        self.subscribed = subscribed; self.ready = ready; self.primary = primary
    }
}

/// A viewport is a typed set of participant identities; audio never belongs to it.
public enum NativeRockVideoPolicy {
    public static let maximumVideoTracks = 16
    public static func demand(for tracks: [NativeRockRemoteTrack], visible: Set<String>?, focused: String?,
                       playout: Bool, cameras: Bool = true) -> [String: NativeRockTrackDemand] {
        let candidates = tracks.filter {
            $0.kind != .audio && !$0.muted && (cameras || $0.kind == .screen) &&
                (visible == nil || visible!.contains($0.participantID) || $0.participantID == focused)
        }.sorted {
            if ($0.participantID == focused) != ($1.participantID == focused) { return $0.participantID == focused }
            if ($0.kind == .screen) != ($1.kind == .screen) { return $0.kind == .screen }
            return ($0.participantID, $0.id) < ($1.participantID, $1.id)
        }
        let selected = Set(candidates.prefix(maximumVideoTracks).map(\.id))
        return Dictionary(tracks.map { track in
            (track.id, NativeRockTrackDemand(subscribed: track.kind == .audio ? playout : selected.contains(track.id),
                ready: track.kind != .audio && track.ready,
                primary: track.kind != .audio && (track.kind == .screen || track.participantID == focused)))
        }, uniquingKeysWith: { _, last in last })
    }
}

public enum NativeRockScreenPolicy {
    public static let maximumFPS = 30
    public static let maximumBitrate = 18_000_000
    public static let maximumEdge: CGFloat = 3840
    public static let maximumPixels: CGFloat = 3840 * 2160
    /// Keep native geometry under the envelope, and never enlarge or crop it.
    public static func dimensions(_ size: CGSize) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite, size.width >= 2, size.height >= 2 else { return nil }
        let scale = min(1, maximumEdge / max(size.width, size.height), sqrt(maximumPixels / (size.width * size.height)))
        return CGSize(width: max(2, floor(size.width * scale / 2) * 2),
            height: max(2, floor(size.height * scale / 2) * 2))
    }
    public static var publishOptions: VideoPublishOptions {
        VideoPublishOptions(screenShareEncoding: VideoEncoding(maxBitrate: maximumBitrate, maxFps: maximumFPS),
            simulcast: false, preferredCodec: .h264, degradationPreference: .maintainResolution)
    }
}

public enum NativeRockCameraPolicy {
    public static func dimensions(_ native: CGSize) -> CGSize? {
        guard native.width.isFinite, native.height.isFinite, native.width >= 2, native.height >= 2 else { return nil }
        let scale = min(1, 1280 / max(native.width, native.height), 720 / min(native.width, native.height))
        return CGSize(width: max(2, floor(native.width * scale / 2) * 2),
            height: max(2, floor(native.height * scale / 2) * 2))
    }
}

public enum NativeRockAudioPolicy {
    public static func captureOptions(_ profile: GuestAudioProfile) -> AudioCaptureOptions {
        let speech = profile == .speech
        return AudioCaptureOptions(echoCancellation: true, autoGainControl: speech, noiseSuppression: speech,
            echoCancellationMode: speech ? .automatic : .software)
    }
    public static func processingOptions(_ profile: GuestAudioProfile) -> AudioProcessingOptions {
        let capture = captureOptions(profile)
        return AudioProcessingOptions(echoCancellation: capture.echoCancellation, autoGainControl: capture.autoGainControl,
            noiseSuppression: capture.noiseSuppression, highpassFilter: capture.highpassFilter,
            echoCancellationMode: capture.echoCancellationMode, autoGainControlMode: capture.autoGainControlMode,
            noiseSuppressionMode: capture.noiseSuppressionMode, highpassFilterMode: capture.highpassFilterMode)
    }
}
