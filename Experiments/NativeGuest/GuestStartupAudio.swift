import Foundation
import AudioToolbox
import LiveKitWebRTC

enum GuestStartupAudioError: Error { case timedOut }

@MainActor enum GuestStartupAudioBudget {
    static func refresh(deadline: TimeInterval, clock: @MainActor () -> TimeInterval,
                        read: @MainActor (TimeInterval) async -> Bool) async -> Bool {
        let remaining = deadline - clock()
        guard remaining > 0, await read(remaining), clock() < deadline else { return false }
        return true
    }
}

struct GuestStartupAudioReport {
    enum Decision: String { case active, soundDisabled, noDemand }
    let configuredUptime: TimeInterval
    let initialSoundIntent: Bool
    var latestSoundIntent: Bool
    var graphReadyUptime: TimeInterval?
    var openUptime: TimeInterval?
    var retiredUptime: TimeInterval?
    var decision: Decision?
#if DEBUG
    var observations: [[String: Any]] = []
    mutating func record(_ value: [String: Any]) {
        observations.append(value)
        if observations.count > 20 { observations.removeFirst(observations.count - 20) }
    }
#endif
    var dictionary: [String: Any] {
        var value: [String: Any] = ["configured": true, "configuredUptime": configuredUptime,
            "closedUptime": configuredUptime, "initialSoundIntent": initialSoundIntent,
            "latestSoundIntent": latestSoundIntent, "witness": "topologyFormatsAndCallbacks"]
        value["graphReadyUptime"] = graphReadyUptime; value["openUptime"] = openUptime
        value["retiredUptime"] = retiredUptime; value["decision"] = decision?.rawValue
#if DEBUG
        value["observations"] = observations
#endif
        return value
    }
}

/// Source gain leaves the receiver enabled and the normal render demand intact.
/// The lock protects metadata only. SDK gain calls may block on signaling.
/// Positive gain is restored only on MainActor; signaling registration can only mute.
final class GuestStartupPlaybackGain: @unchecked Sendable {
    struct Source: Equatable {
        var trackID: String?
        var streamIDs: [String] = []
    }
    struct SourceSnapshot {
        let revision: UInt64
        let sources: [Source]
    }
    private final class Entry {
        let identity: NSObject; let gain: Double; let setGain: (Double) -> Void
        var source: Source
        var active = true
        init(identity: NSObject, source: Source, gain: Double, setGain: @escaping (Double) -> Void) {
            self.identity = identity; self.source = source; self.gain = gain; self.setGain = setGain
        }
    }
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var revision: UInt64 = 0
    private var closed = false
    private var ready = false
    private var sound: Bool
    /// Per-speaker level for a source (0...2). It scales only restored gain:
    /// closed, unready or sound-off entries stay at an exact zero.
    @MainActor var level: ((Source) -> Double)?
    init(sound: Bool) { self.sound = sound }
    var hasSources: Bool { locked { entries.contains(where: \.active) } }
    var sourceSnapshot: SourceSnapshot { locked { .init(revision: revision, sources: entries.filter(\.active).map(\.source)) } }
    var isOpen: Bool { locked { ready && !closed } }
    var soundEnabled: Bool { locked { sound } }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    func register(_ track: LKRTCAudioTrack, streamIDs: [String] = []) {
        register(identity: track, source: .init(trackID: track.trackId, streamIDs: streamIDs),
            gain: { track.source.volume }, setGain: { track.source.volume = $0 })
    }
    func register(identity: NSObject, source: Source = .init(trackID: nil), gain: () -> Double, setGain: @escaping (Double) -> Void) {
        let original = gain() // SDK getter outside the metadata lock.
        while true {
            let snapshot = locked { (entries, revision) }
            let existing = snapshot.0.first { $0.identity.isEqual(identity) }
            let result: (retry: Bool, mute: Bool) = locked {
                guard revision == snapshot.1 else { return (true, false) }
                guard !closed else { return (false, true) }
                if let existing {
                    let reattached = !existing.active
                    if reattached { existing.active = true; revision &+= 1 }
                    if existing.source != source { existing.source = source; revision &+= 1 }
                    return (false, reattached)
                }
                entries.append(Entry(identity: identity, source: source, gain: original, setGain: setGain)); revision &+= 1
                return (false, true)
            }
            if result.retry { continue }
            if result.mute { setGain(0) } // The signaling callback never restores positive gain.
            return
        }
    }
    func remove(_ identity: NSObject) {
        while true {
            let snapshot = locked { (entries, revision) }
            let existing = snapshot.0.first { $0.identity.isEqual(identity) }
            let retry = locked {
                guard revision == snapshot.1 else { return true }
                if let existing, existing.active { existing.active = false; revision &+= 1 }
                return false
            }
            if !retry { return }
        }
    }
    private func desired(_ entry: Entry, level: Double) -> Double {
        locked { !closed && ready && sound && entry.active ? entry.gain * level : 0 }
    }
    @MainActor func reconcile() {
        let current = locked { entries }
        for entry in current {
            let source = locked { entry.source }
            let factor = level.map { $0(source) } ?? 1
            let scale = factor.isFinite ? min(2, max(0, factor)) : 1
            var value = desired(entry, level: scale)
            while true {
                entry.setGain(value) // Never hold the lock across SDK BlockingCall.
                let latest = desired(entry, level: scale)
                if latest == value { break }
                value = latest
            }
        }
    }
    @MainActor func setSound(_ enabled: Bool) {
        locked { sound = enabled }; reconcile()
    }
    @MainActor func hold() {
        locked { ready = false }; reconcile()
    }
    @MainActor func open(expectedSourceRevision: UInt64? = nil, releaseGlobal: (() -> Bool)? = nil) -> Bool {
        let allowed = locked {
            guard !closed, sound, expectedSourceRevision == nil || expectedSourceRevision == revision else { return false }
            ready = true; return true
        }
        guard allowed else { return false }
        reconcile()
        guard locked({ ready && sound && !closed }) else { return false }
        guard releaseGlobal?() != false else { hold(); return false }
        return locked { ready && sound && !closed }
    }
    @MainActor func close() {
        let retired = locked {
            closed = true; ready = false
            revision &+= 1; let retired = entries
            entries.removeAll()
            return retired
        }
        retired.forEach { $0.setGain(0) }
    }
}

/// An unmuted publication can be awaiting its subscription response or receiver
/// callback. Physical device callbacks alone do not prove its receive transport.
struct GuestStartupAudioReceiveReadiness {
    let activePublication: Bool
    let sourceRequiresTransport: Bool
    let transportConnected: Bool
    var requiresTransport: Bool { activePublication || sourceRequiresTransport }
    var ready: Bool { !requiresTransport || transportConnected }
}

/// Delivered tap metadata is independent of the SDK's cached configured format.
/// Scalars keep the callback path free of diagnostic dictionary/array allocation.
struct GuestStartupAudioCallback {
    struct Format: Equatable {
        let rate: Double
        let id, flags, bytesPerPacket, framesPerPacket, bytesPerFrame, channels, bits, reserved: UInt32
        init(_ value: AudioStreamBasicDescription) {
            rate = value.mSampleRate; id = value.mFormatID; flags = value.mFormatFlags
            bytesPerPacket = value.mBytesPerPacket; framesPerPacket = value.mFramesPerPacket
            bytesPerFrame = value.mBytesPerFrame; channels = value.mChannelsPerFrame
            bits = value.mBitsPerChannel; reserved = value.mReserved
        }
#if DEBUG
        var signature: [Double] {
            [rate, Double(id), Double(flags), Double(bytesPerPacket), Double(framesPerPacket),
                Double(bytesPerFrame), Double(channels), Double(bits), Double(reserved)]
        }
#endif
    }
    var count: UInt64 = 0
    var frames = 0
    var format: Format?
    var uptime: TimeInterval = 0
    var duration: TimeInterval {
        guard let rate = format?.rate, rate.isFinite, rate > 0, frames > 0 else { return 0 }
        return Double(frames) / rate
    }
    var freshness: TimeInterval { min(0.35, max(0.15, duration + 0.1)) }
    var supportedCadence: Bool {
        guard let format else { return count == 0 }
        return frames > 0 && format.rate.isFinite && format.rate > 0 && format.id > 0 &&
            format.bytesPerFrame > 0 && format.channels > 0 && duration < 0.35
    }
#if DEBUG
    var evidence: [String: Any] {
        ["buffers": count, "frames": frames, "sampleRate": format?.rate ?? 0,
            "channels": format?.channels ?? 0, "uptime": uptime,
            "actualASBD": format?.signature ?? [],
            "duration": duration, "freshness": freshness,
            "age": max(0, ProcessInfo.processInfo.systemUptime - uptime)]
    }
#endif
}

struct GuestStartupAudioObservation {
    struct Topology: Equatable {
        let running, inputAvailable, inputEnabled, inputRunning, outputAvailable, outputEnabled: Bool
        let inputFormat, outputFormat: [Double]
        let counters: [Int]
        let inputTapFormat, outputTapFormat: GuestStartupAudioCallback.Format?
        let inputTapFrames, outputTapFrames: Int
    }
    let topology: Topology
    let inputCallbacks, outputCallbacks: UInt64
    let inputCallback, outputCallback: GuestStartupAudioCallback
    init(snapshot: [String: Any], inputCallbacks: UInt64, outputCallbacks: UInt64,
         inputCallback: GuestStartupAudioCallback = .init(), outputCallback: GuestStartupAudioCallback = .init()) {
        func flag(_ key: String) -> Bool { snapshot[key] as? Bool == true }
        topology = .init(running: flag("engineRunning"), inputAvailable: flag("inputAvailable"),
            inputEnabled: flag("inputEnabled"), inputRunning: flag("inputRunning"),
            outputAvailable: flag("outputAvailable"), outputEnabled: flag("outputEnabled"),
            inputFormat: snapshot["inputASBD"] as? [Double] ?? [],
            outputFormat: snapshot["outputASBD"] as? [Double] ?? [],
            counters: ["enginesCreated", "engineStarts", "engineStops", "enginesReleased", "deviceUpdates"].map { snapshot[$0] as? Int ?? 0 },
            inputTapFormat: inputCallback.format, outputTapFormat: outputCallback.format,
            inputTapFrames: inputCallback.frames, outputTapFrames: outputCallback.frames)
        self.inputCallbacks = inputCallbacks; self.outputCallbacks = outputCallbacks
        self.inputCallback = inputCallback; self.outputCallback = outputCallback
    }
    static func valid(_ format: [Double]) -> Bool {
        format.count == 9 && format.allSatisfy(\.isFinite) && format[0] > 0 && format[1] > 0 && format[5] > 0 && format[6] > 0
    }
    func supports(input: Bool, output: Bool = true) -> Bool {
        let t = topology
        return t.running && (!output || (t.outputAvailable && Self.valid(t.outputFormat) && outputCallback.supportedCadence)) &&
            (!input || (t.inputAvailable && t.inputEnabled && t.inputRunning && Self.valid(t.inputFormat) && inputCallback.supportedCadence))
    }
#if DEBUG
    var evidence: [String: Any] {
        let t = topology
        return ["engineRunning": t.running, "inputAvailable": t.inputAvailable,
            "inputEnabled": t.inputEnabled, "inputRunning": t.inputRunning,
            "outputAvailable": t.outputAvailable, "outputEnabled": t.outputEnabled,
            "inputASBD": t.inputFormat, "outputASBD": t.outputFormat, "counters": t.counters,
            "inputCallbacks": inputCallbacks, "outputCallbacks": outputCallbacks,
            "inputTap": inputCallback.evidence, "outputTap": outputCallback.evidence]
    }
#endif
}

/// Silent callbacks count: acoustic energy and remote packet arrival are irrelevant.
struct GuestStartupAudioStability {
    let window: TimeInterval
    private var topology: GuestStartupAudioObservation.Topology?
    private var inputRequired = false
    private var outputRequired = true
    private var since: TimeInterval = 0
    private var input: UInt64 = 0, output: UInt64 = 0
    private var inputAdvanced = false, outputAdvanced = false
    private var inputProgress: TimeInterval = 0, outputProgress: TimeInterval = 0
#if DEBUG
    private(set) var lastDecision = "unobserved"
    func evidence(at now: TimeInterval) -> [String: Any] {
        ["decision": lastDecision, "window": window, "stableSince": since,
            "stableFor": max(0, now - since), "inputRequired": inputRequired,
            "inputAdvanced": inputAdvanced, "outputAdvanced": outputAdvanced,
            "inputProgressAge": max(0, now - inputProgress),
            "outputProgressAge": max(0, now - outputProgress)]
    }
#endif
    init(window: TimeInterval = 0.35) { self.window = window }
    mutating func observe(_ value: GuestStartupAudioObservation, input required: Bool, output requiredOutput: Bool = true, at now: TimeInterval) -> Bool {
        guard value.supports(input: required, output: requiredOutput) else {
#if DEBUG
            lastDecision = "unsupported"
#endif
            topology = nil; return false
        }
        if topology != value.topology || inputRequired != required || outputRequired != requiredOutput || value.inputCallbacks < input || value.outputCallbacks < output {
            topology = value.topology; inputRequired = required; outputRequired = requiredOutput; since = now
            input = value.inputCallbacks; output = value.outputCallbacks
            inputAdvanced = false; outputAdvanced = false; inputProgress = now; outputProgress = now
#if DEBUG
            lastDecision = "topologyOrDemandChanged"
#endif
            return false
        }
        if value.inputCallbacks > input { inputAdvanced = true; inputProgress = now }
        if value.outputCallbacks > output { outputAdvanced = true; outputProgress = now }
        input = value.inputCallbacks; output = value.outputCallbacks
        // One delivered buffer plus two 50ms observer periods, always <=350ms.
        // Progress and the full unchanged-format window remain separate requirements.
        func stale(_ callback: GuestStartupAudioCallback, progress: TimeInterval) -> Bool {
            now >= progress + callback.freshness ||
                (callback.uptime > 0 && now >= callback.uptime + callback.freshness)
        }
        if (requiredOutput && stale(value.outputCallback, progress: outputProgress)) ||
            (required && stale(value.inputCallback, progress: inputProgress)) {
#if DEBUG
            lastDecision = "callbackStale"
#endif
            topology = nil; return false
        }
        let ready = now - since >= window && (!requiredOutput || outputAdvanced) && (!required || inputAdvanced)
#if DEBUG
        lastDecision = ready ? "ready" : "stabilizing"
#endif
        return ready
    }
}
