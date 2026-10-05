#if DEBUG
import CoreMedia
import CoreVideo
import Foundation
import ReplayKit

/// Opt-in diagnostics only. Retains timings, never frames, URLs, names, or tokens.
final class OutgoingShareExperiment {
    enum Profile: String, Codable { case reference, cap30, cap15 }
    private struct Configuration: Codable { let profile: Profile; let previewAfter: Bool }
    private struct Format: Equatable { let width: Int; let height: Int; let pixelFormat: OSType; let orientation: UInt32 }
    private let profile: Profile
    private let previewAfterSend: Bool
    private let lock = NSLock()
    private var generation = 0
    private var firstArrival: TimeInterval?
    private var lastArrival: TimeInterval?
    private var lastTime: TimeInterval?
    private var format: Format?
    private var receivedCount = 0
    private var forwardedCount = 0
    var received: Int { lock.lock(); defer { lock.unlock() }; return receivedCount }
    var forwarded: Int { lock.lock(); defer { lock.unlock() }; return forwardedCount }
    private var handoffTimes: [Double] = []
    private var sendTimes: [Double] = []
    private var previewTimes: [Double] = []

    static func configured(environment: [String: String] = ProcessInfo.processInfo.environment) -> OutgoingShareExperiment? {
        guard let value = environment["ROCKNROLL_OUTGOING_SHARE"], let profile = Profile(rawValue: value) else { return nil }
        return OutgoingShareExperiment(profile: profile,
            previewAfterSend: environment["ROCKNROLL_OUTGOING_PREVIEW_AFTER_SEND"] == "1")
    }

    private static var broadcastConfigurationURL: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "RTCAppGroupIdentifier") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("outgoing-share-debug-configuration.json")
    }

    // ReplayKit extensions do not inherit the host app's launch environment.
    static func prepareBroadcastConfiguration(environment: [String: String] = ProcessInfo.processInfo.environment,
                                               url: URL? = broadcastConfigurationURL) {
        guard let url else { return }
        guard let experiment = configured(environment: environment) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let configuration = Configuration(profile: experiment.profile, previewAfter: experiment.previewAfterSend)
        if let data = try? JSONEncoder().encode(configuration) { try? data.write(to: url, options: .atomic) }
    }

    static func configuredForBroadcast(environment: [String: String] = ProcessInfo.processInfo.environment,
                                        url: URL? = broadcastConfigurationURL) -> OutgoingShareExperiment? {
        if let direct = configured(environment: environment) { return direct }
        guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_024,
              let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(Configuration.self, from: data) else { return nil }
        return OutgoingShareExperiment(profile: configuration.profile, previewAfterSend: configuration.previewAfter)
    }

    init(profile: Profile, previewAfterSend: Bool = false) {
        self.profile = profile
        self.previewAfterSend = previewAfterSend
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        firstArrival = nil; lastArrival = nil
        lastTime = nil; format = nil; receivedCount = 0; forwardedCount = 0
        handoffTimes.removeAll(keepingCapacity: true)
        sendTimes.removeAll(keepingCapacity: true)
        previewTimes.removeAll(keepingCapacity: true)
    }

    /// No delayed work or retained sample. The first frame and format changes pass immediately.
    @discardableResult
    func deliver(_ sample: CMSampleBuffer, time: TimeInterval = ProcessInfo.processInfo.systemUptime,
                 send: () -> Void, preview: () -> Void) -> Bool {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return false }
        let currentFormat = Format(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
            pixelFormat: CVPixelBufferGetPixelFormatType(pixels),
            orientation: (CMGetAttachment(sample, key: RPVideoSampleOrientationKey as CFString,
                                          attachmentModeOut: nil) as? NSNumber)?.uint32Value ?? 0)
        lock.lock()
        let arrival = ProcessInfo.processInfo.systemUptime
        if firstArrival == nil { firstArrival = arrival }
        lastArrival = arrival
        receivedCount += 1
        let interval: Double = profile == .reference ? 0 : 1 / (profile == .cap30 ? 30 : 15)
        if currentFormat == format, let previous = lastTime, time.isFinite, time >= previous,
           time - previous + 1e-9 < interval { lock.unlock(); return false }
        format = currentFormat; lastTime = time.isFinite ? time : nil
        forwardedCount += 1
        let epoch = generation
        lock.unlock()
        let start = ProcessInfo.processInfo.systemUptime
        var previewDuration = 0.0
        func updatePreview() {
            let before = ProcessInfo.processInfo.systemUptime
            preview()
            previewDuration = (ProcessInfo.processInfo.systemUptime - before) * 1_000
        }
        if !previewAfterSend { updatePreview() }
        let handoff = ProcessInfo.processInfo.systemUptime
        send()
        let sendDuration = (ProcessInfo.processInfo.systemUptime - handoff) * 1_000
        if previewAfterSend { updatePreview() }
        lock.lock(); defer { lock.unlock() }
        guard generation == epoch else { return true }
        // Keep at most 4,096 recent timings; clearing on wrap keeps allocation bounded.
        if handoffTimes.count == 4_096 {
            handoffTimes.removeAll(keepingCapacity: true)
            sendTimes.removeAll(keepingCapacity: true)
            previewTimes.removeAll(keepingCapacity: true)
        }
        handoffTimes.append((handoff - start) * 1_000)
        sendTimes.append(sendDuration); previewTimes.append(previewDuration)
        return true
    }

    var summary: String {
        lock.lock(); defer { lock.unlock() }
        func p95(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        }
        let elapsed = (lastArrival ?? 0) - (firstArrival ?? 0)
        let inputFPS = elapsed > 0 ? Double(max(0, receivedCount - 1)) / elapsed : 0
        return "OUTGOING_SHARE,profile=\(profile.rawValue),previewAfter=\(previewAfterSend),received=\(receivedCount),forwarded=\(forwardedCount),timingSamples=\(handoffTimes.count),handoff_p95_ms=\(p95(handoffTimes)),send_p95_ms=\(p95(sendTimes)),preview_p95_ms=\(p95(previewTimes)),elapsed_s=\(elapsed),input_fps=\(inputFPS)"
    }
}
#endif
