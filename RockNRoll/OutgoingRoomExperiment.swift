#if DEBUG
import Foundation
import LiveKit

/// Explicit experiment profiles; default Room and audio options are preserved.
enum OutgoingRoomExperiment: String, CaseIterable {
    case production, reference, dynacast, h264Dynacast, h264TwoLayers, h264SingleLayer

    static var configured: OutgoingRoomExperiment? {
        ProcessInfo.processInfo.environment["ROCKNROLL_OUTGOING_ROOM"].flatMap(Self.init(rawValue:))
    }
    var options: RoomOptions {
        if self == .production { return RoomMediaPolicy.options }
        let hardware = self == .h264Dynacast || self == .h264TwoLayers || self == .h264SingleLayer
        let layers: [VideoParameters] = self == .h264TwoLayers
            ? [VideoParameters(dimensions: .h180_169, encoding: VideoEncoding(maxBitrate: 150_000, maxFps: 15))] : []
        return RoomOptions(defaultVideoPublishOptions: VideoPublishOptions(
            simulcast: self != .h264SingleLayer, simulcastLayers: layers,
            preferredCodec: hardware ? .h264 : nil), dynacast: self != .reference)
    }
}

/// One snapshot per two seconds. All identifiers are local RTP IDs, never invitation data.
@MainActor
final class OutgoingRoomMonitor {
    private var task: Task<Void, Never>?
    private var previous: [String: (time: Double, frames: UInt, encode: Double, bytes: UInt64)] = [:]
    private var enabledTracks: Set<ObjectIdentifier> = []

    func start(room: Room) {
        stop()
        task = Task { [weak self, weak room] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, let room else { return }
                var currentTracks: Set<ObjectIdentifier> = []
                var currentRTP: Set<String> = []
                for publication in room.localParticipant.trackPublications.values {
                    guard let track = publication.track else { continue }
                    let id = ObjectIdentifier(track)
                    currentTracks.insert(id)
                    if !self.enabledTracks.contains(id) { await track.set(reportStatistics: true) }
                    guard !Task.isCancelled else { return }
                    self.record(track: track)
                    currentRTP.formUnion(track.statistics?.outboundRtpStream.map(\.id) ?? [])
                }
                self.enabledTracks = currentTracks
                self.previous = self.previous.filter { currentRTP.contains($0.key) }
            }
        }
    }
    func stop() { task?.cancel(); task = nil; previous.removeAll(); enabledTracks.removeAll() }

    @discardableResult
    func record(track: Track) -> [String] {
        guard let stats = track.statistics else { return [] }
        for source in stats.videoSource {
            print("OUTGOING_CAPTURE,source=\(track.source),size=\(source.width ?? 0)x\(source.height ?? 0),fps=\(source.framesPerSecond ?? 0)")
        }
        return stats.outboundRtpStream.map { value in
            let now = Double(value.timestamp) / 1_000_000
            let frames = value.framesEncoded ?? 0, encode = value.totalEncodeTime ?? 0
            let bytes = value.bytesSent ?? 0
            let before = previous[value.id]
            previous[value.id] = (now, frames, encode, bytes)
            let valid = before.map { now > $0.time && frames >= $0.frames && encode >= $0.encode && bytes >= $0.bytes } ?? false
            let seconds = valid ? now - before!.time : 0
            let deltaFrames = valid ? frames - before!.frames : 0
            let fps = seconds > 0 ? Double(deltaFrames) / seconds : 0
            let encodeMs = deltaFrames > 0 ? (encode - before!.encode) * 1_000 / Double(deltaFrames) : 0
            let bitrate = seconds > 0 ? Double(bytes - before!.bytes) * 8 / seconds : 0
            let codec = stats.codec.first(where: { $0.id == value.codecId })?.mimeType ?? "unknown"
            let text = "OUTGOING_RTP,source=\(track.source),codec=\(codec),rid=\(value.rid ?? "single"),size=\(value.frameWidth ?? 0)x\(value.frameHeight ?? 0),fps=\(fps),encode_ms=\(encodeMs),bitrate=\(bitrate),encoder=\(value.encoderImplementation ?? "unknown"),efficient=\(value.powerEfficientEncoder.map(String.init) ?? "unknown"),limited=\(String(describing: value.qualityLimitationReason))"
            print(text)
            return text
        }
    }
    deinit { task?.cancel() }
}
#endif
