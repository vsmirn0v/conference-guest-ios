#if DEBUG
import AVFoundation
import CoreMedia
import Foundation

/// Numeric timing only: no camera images, names or meeting addresses are saved.
final class PreviewExperimentMetrics: @unchecked Sendable {
    private static let lock = NSLock()
    private static var active: PreviewExperimentMetrics?
    private var captures: [Double] = []
    private var captureAge: [Double] = []
    private var buffers: [UInt: (Double, Double)] = [:]
    private var deliveries: [Double] = []
    private var enqueueAge: [Double] = []
    private var queueAge: [Double] = []
    private var rejected = 0
    private var invalidTimestamps = 0

    static func begin() -> PreviewExperimentMetrics {
        lock.lock(); defer { lock.unlock() }
        let value = PreviewExperimentMetrics(); active = value
        return value
    }
    static func cancel() { lock.lock(); active = nil; lock.unlock() }
    static func capture(timestamp: Int64, pixels: CVPixelBuffer?) {
        lock.lock(); defer { lock.unlock() }
        guard let active else { return }
        let now = ProcessInfo.processInfo.systemUptime, captured = Double(timestamp) / 1e9
        active.captures.append(now)
        if now >= captured, now - captured < 1 { active.captureAge.append((now - captured) * 1000) }
        else { active.invalidTimestamps += 1 }
        if let pixels {
            if active.buffers.count > 512 { active.buffers.removeAll(keepingCapacity: true) }
            active.buffers[UInt(bitPattern: Unmanaged.passUnretained(pixels).toOpaque())] = (captured, now)
        }
    }
    static func delivery(sample: CMSampleBuffer, enqueued: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let active else { return }
        guard enqueued else { active.rejected += 1; return }
        let now = ProcessInfo.processInfo.systemUptime
        active.deliveries.append(now)
        active.queueAge.append((now - CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))) * 1000)
        if let pixels = CMSampleBufferGetImageBuffer(sample),
           let captured = active.buffers[UInt(bitPattern: Unmanaged.passUnretained(pixels).toOpaque())]?.0,
           now >= captured, now - captured < 1 { active.enqueueAge.append((now - captured) * 1000) }
    }
    func finish() -> [String: Any] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if Self.active === self { Self.active = nil }
        func summary(_ values: [Double]) -> [String: Any] {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return ["samples": 0] }
            func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
            return ["samples": sorted.count, "median": percentile(0.5), "p95": percentile(0.95), "p99": percentile(0.99), "maximum": sorted.last!]
        }
        func intervals(_ times: [Double]) -> [Double] { zip(times.dropFirst(), times).map { ($0 - $1) * 1000 } }
        func fps(_ times: [Double]) -> Double { times.count > 1 ? Double(times.count - 1) / (times.last! - times.first!) : 0 }
        return ["capture_fps": fps(captures), "capture_interval_ms": summary(intervals(captures)),
                "capture_callback_age_ms": summary(captureAge), "invalid_capture_timestamps": invalidTimestamps,
                "pip_enqueue_fps": fps(deliveries), "pip_interval_ms": summary(intervals(deliveries)),
                "pip_capture_to_enqueue_ms": summary(enqueueAge), "pip_queue_ms": summary(queueAge),
                "pip_rejected": rejected]
    }
}
#endif
