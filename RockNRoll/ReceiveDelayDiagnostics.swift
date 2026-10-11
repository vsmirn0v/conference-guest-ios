#if DEBUG
import Foundation
import QuartzCore
import LiveKit

/// Local opt-in measurements. RTP counters are cumulative; only interval
/// deltas are comparable. Missing/reset counters never become zero latency.
struct ReceiveDelayStatistics {
    struct Record { let id: String; let kind: String; let time: Double; let values: [String: Double] }
    struct Interval {
        let id: String; let kind: String; let seconds: Double
        let jitterMS: Double?; let targetMS: Double?; let minimumMS: Double?
        let decodeMS: Double?; let processingMS: Double?
        let concealedFraction: Double?; let accelerationFraction: Double?
        let freezes: Double?; let fps: Double?
    }
    private var previous: [String: Record] = [:]
    mutating func ingest(_ records: [Record]) -> [Interval] {
        let ids = Set(records.map(\.id))
        previous = previous.filter { ids.contains($0.key) }
        return records.compactMap { next in
            let before = previous.updateValue(next, forKey: next.id)
            guard let before, before.kind == next.kind, before.time.isFinite, next.time.isFinite, next.time > before.time else { return nil }
            let seconds = next.time - before.time
            func delta(_ key: String) -> Double? {
                guard let a = before.values[key], let b = next.values[key], a.isFinite, b.isFinite,
                      a >= 0, b >= a else { return nil }
                return b - a
            }
            func ratio(_ total: String, _ count: String, scale: Double = 1) -> Double? {
                guard let numerator = delta(total), let denominator = delta(count), denominator > 0 else { return nil }
                let value = numerator / denominator * scale
                return value.isFinite ? value : nil
            }
            return Interval(id: next.id, kind: next.kind, seconds: seconds,
                jitterMS: ratio("jitterBufferDelay", "jitterBufferEmittedCount", scale: 1000),
                targetMS: ratio("jitterBufferTargetDelay", "jitterBufferEmittedCount", scale: 1000),
                minimumMS: ratio("jitterBufferMinimumDelay", "jitterBufferEmittedCount", scale: 1000),
                decodeMS: ratio("totalDecodeTime", "framesDecoded", scale: 1000),
                processingMS: ratio("totalProcessingDelay", "framesDecoded", scale: 1000),
                concealedFraction: ratio("concealedSamples", "totalSamplesReceived"),
                accelerationFraction: ratio("removedSamplesForAcceleration", "totalSamplesReceived"),
                freezes: delta("freezeCount"), fps: delta("framesDecoded").map { $0 / seconds })
        }
    }
    static func record(id: String, time: Double, values: [String: NSObject]) -> Record? {
        guard let kind = values["kind"] as? String else { return nil }
        return Record(id: id, kind: kind, time: time,
                      values: values.reduce(into: [:]) { result, pair in
                          if let number = pair.value as? NSNumber { result[pair.key] = number.doubleValue }
                      })
    }
}

/// Enabling statistics restarts LiveKit's timer, so do it once per track.
@MainActor
final class RoomReceiveDelaySource {
    private var enabledTracks: Set<ObjectIdentifier> = []
    weak var room: Room?
    init(room: Room) { self.room = room }
    func records() async -> [ReceiveDelayStatistics.Record] {
        guard let room else { return [] }
        var currentTracks: Set<ObjectIdentifier> = []
        var records: [ReceiveDelayStatistics.Record] = []
        for participant in room.remoteParticipants.values {
            for publication in participant.trackPublications.values {
                guard let track = publication.track else { continue }
                let identity = ObjectIdentifier(track); currentTracks.insert(identity)
                if !enabledTracks.contains(identity) { await track.set(reportStatistics: true) }
                for value in track.statistics?.inboundRtpStream ?? [] {
                    var fields: [String: Double] = [:]
                    fields["jitterBufferDelay"] = value.jitterBufferDelay
                    fields["jitterBufferTargetDelay"] = value.jitterBufferTargetDelay
                    fields["jitterBufferMinimumDelay"] = value.jitterBufferMinimumDelay
                    fields["jitterBufferEmittedCount"] = value.jitterBufferEmittedCount.map(Double.init)
                    fields["totalDecodeTime"] = value.totalDecodeTime
                    fields["framesDecoded"] = value.framesDecoded.map(Double.init)
                    fields["totalProcessingDelay"] = value.totalProcessingDelay
                    fields["concealedSamples"] = value.concealedSamples.map(Double.init)
                    fields["removedSamplesForAcceleration"] = value.removedSamplesForAcceleration.map(Double.init)
                    fields["totalSamplesReceived"] = value.totalSamplesReceived.map(Double.init)
                    fields["freezeCount"] = value.freezeCount.map(Double.init)
                    records.append(ReceiveDelayStatistics.Record(id: value.id, kind: value.kind ?? "unknown", time: Double(value.timestamp) / 1_000_000, values: fields))
                }
            }
        }
        enabledTracks = currentTracks
        return records
    }
}

/// Bounded in-memory samples. Callback-to-enqueue is app delay, not optical
/// latency, sender-to-receiver latency or the compositor's display deadline.
final class ReceiveVideoTiming: @unchecked Sendable {
    static let shared = ReceiveVideoTiming()
    static let enabled = ProcessInfo.processInfo.environment["ROCKNROLL_RECEIVE_DELAY"] == "1"
    struct Sample { let queueMS: Double; let conversionMS: Double; let deliveryMS: Double }
    private let lock = NSLock()
    private var samples: [String: [Sample]] = [:]
    func record(label: String, arrival: Double, start: Double, ready: Double, delivered: Double) {
        lock.lock(); defer { lock.unlock() }
        var values = samples[label, default: []]
        if values.count == 512 { values.removeFirst(256) }
        values.append(Sample(queueMS: (start - arrival) * 1000,
                             conversionMS: (ready - start) * 1000,
                             deliveryMS: (delivered - ready) * 1000))
        samples[label] = values
    }
    func snapshot() -> [String: [Sample]] { lock.lock(); defer { lock.unlock() }; return samples }
    func reset() { lock.lock(); samples.removeAll(); lock.unlock() }
}

@MainActor
final class ReceiveDelayMonitor {
    private var task: Task<Void, Never>?
    private var windows = ReceiveDelayStatistics()
    func start(label: String, snapshot: @escaping @MainActor () async -> [ReceiveDelayStatistics.Record]) {
        guard ReceiveVideoTiming.enabled else { return }
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                let records = await snapshot()
                guard let self, !Task.isCancelled else { return }
                for value in self.windows.ingest(records) {
                    func text(_ number: Double?) -> String { number.map { String(format: "%.3f", $0) } ?? "unavailable" }
                    print("RECEIVE_DELAY,engine=\(label),stream=\(value.id),kind=\(value.kind),jitter_ms=\(text(value.jitterMS)),target_ms=\(text(value.targetMS)),minimum_ms=\(text(value.minimumMS)),decode_ms=\(text(value.decodeMS)),processing_ms=\(text(value.processingMS)),concealed=\(text(value.concealedFraction)),accelerated=\(text(value.accelerationFraction)),freezes=\(text(value.freezes)),fps=\(text(value.fps))")
                }
                for (pipeline, samples) in ReceiveVideoTiming.shared.snapshot() where !samples.isEmpty {
                    func p95(_ key: KeyPath<ReceiveVideoTiming.Sample, Double>) -> Double {
                        let sorted = samples.map { $0[keyPath: key] }.sorted()
                        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
                    }
                    print("RECEIVE_APP_DELAY,pipeline=\(pipeline),samples=\(samples.count),queue_p95_ms=\(p95(\.queueMS)),conversion_p95_ms=\(p95(\.conversionMS)),delivery_p95_ms=\(p95(\.deliveryMS))")
                }
            }
        }
    }
    func stop() { task?.cancel(); task = nil; windows = ReceiveDelayStatistics() }
    deinit { task?.cancel() }
}

/// Changes only NetEq's speed-up policy for an explicitly selected experiment.
/// Capacity, minimum delay, concealment and production audio stay untouched.
enum ReceiveAudioCatchUpExperiment: String {
    case baseline, fast
    @MainActor static var overrideForTesting: Self?
    static var configured: Self? {
        ProcessInfo.processInfo.environment["ROCKNROLL_AUDIO_CATCH_UP"].flatMap(Self.init(rawValue:))
    }
    var fastAccelerate: Bool { self == .fast }
}
#endif
