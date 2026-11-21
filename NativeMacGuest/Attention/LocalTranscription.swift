import AVFoundation
import Combine
import Foundation
import SherpaOnnxKit

/// Who the meeting service says is speaking, over time. A mixed audio stream
/// has no speaker; an utterance is given to the participant whose speaking
/// intervals cover most of it, when that covers at least `minimumShare`.
struct SpeakingTimeline: Equatable {
    static let retention: TimeInterval = 300
    /// Speaking signals arrive late and coarse; intervals are widened by this much.
    static let padding: TimeInterval = 0.5
    static let minimumShare = 0.5
    private(set) var closed: [String: [ClosedRange<Date>]] = [:]
    private(set) var open: [String: Date] = [:]

    mutating func observe(speaking: Set<String>, at time: Date) {
        for id in speaking where open[id] == nil { open[id] = time }
        for (id, start) in open where !speaking.contains(id) {
            closed[id, default: []].append(start...max(start, time)); open[id] = nil
        }
        let cutoff = time.addingTimeInterval(-Self.retention)
        for id in closed.keys { closed[id]?.removeAll { $0.upperBound < cutoff } }
        closed = closed.filter { !$0.value.isEmpty }
    }

    /// The participant who most likely said `start...end`, or nil when no one
    /// clearly did (no signal, or two people equally).
    func speaker(start: Date, end: Date, now: Date = Date()) -> String? {
        let length = end.timeIntervalSince(start)
        guard length > 0 else { return nil }
        var shares: [(String, Double)] = []
        for id in Set(closed.keys).union(open.keys) {
            var ranges = closed[id] ?? []
            if let begun = open[id] { ranges.append(begun...max(begun, now)) }
            let covered = ranges.reduce(0.0) { total, range in
                let from = max(start, range.lowerBound.addingTimeInterval(-Self.padding))
                let to = min(end, range.upperBound.addingTimeInterval(Self.padding))
                return total + max(0, to.timeIntervalSince(from))
            }
            shares.append((id, min(1, covered / length)))
        }
        let ranked = shares.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= Self.minimumShare else { return nil }
        if ranked.count > 1, ranked[1].1 >= best.1 - 0.05 { return nil }
        return best.0
    }
}

/// A listen model ready to run: through sherpa-onnx on the CPU, or as native Core ML
/// (the encoder on the Neural Engine).
enum ListenRecognizerModel: Equatable, Sendable {
    case sherpa(SherpaRecognizerModel)
    case coreMLGigaAM(CoreMLGigaAMModel)
}

enum LocalSpeechRecognizerPhase: Equatable, Sendable {
    case unloaded, loading, loaded, unloading, failed
}

/// The recognizer's public lifecycle. `preparedModel` remains after a successful
/// warm-up even when residency is released, so Ready and Loaded stay distinct.
struct LocalSpeechRecognizerRuntimeSnapshot: Equatable, Sendable {
    var model: ListenRecognizerModel?
    var phase: LocalSpeechRecognizerPhase = .unloaded
    var preparedModel: ListenRecognizerModel?
    var users = 0
    var activeDecodes = 0
    var lastLoadSeconds: TimeInterval = 0
    var error: String?
}

/// One recognizer for every meeting. Utterances run one at a time on a utility
/// queue; when more than `maxPendingSeconds` of speech waits, new speech is
/// dropped and counted instead of falling ever further behind.
final class LocalSpeechRecognizer: @unchecked Sendable {
    static let shared = LocalSpeechRecognizer()
    static let maxPendingSeconds = 90.0
    enum DropReason: String, Sendable {
        case audioBacklog, recognitionBacklog, modelUnavailable, decodeFailure
    }
    let runtime = CurrentValueSubject<LocalSpeechRecognizerRuntimeSnapshot, Never>(.init())
    private let queue = DispatchQueue(label: "attention.listen.recognizer", qos: .utility)
    private let lock = NSLock()
    private var pending = 0.0
    private var recognizer: (([Float]) throws -> String)?
    private var loaded: ListenRecognizerModel?
    private var runtimeState = LocalSpeechRecognizerRuntimeSnapshot()

    /// Reports why audio could not be recognized, including bounded-queue overload.
    func transcribe(_ samples: [Float], model: ListenRecognizerModel, completion: @escaping (String?, TimeInterval, DropReason?) -> Void) {
        let seconds = Double(samples.count) / 16_000
        let admitted: Bool = { lock.lock(); defer { lock.unlock() }
            guard pending + seconds <= Self.maxPendingSeconds else { return false }
            pending += seconds; return true }()
        guard admitted else { completion(nil, 0, .recognitionBacklog); return }
        queue.async { [self] in
            defer { lock.lock(); pending -= seconds; lock.unlock() }
            let token = measurementTokenIfLoadNeeded(model)
            guard load(model, measurementToken: token) else { completion(nil, 0, .modelUnavailable); return }
            lock.lock()
            runtimeState.activeDecodes += 1
            let activeSnapshot = runtimeState
            lock.unlock()
            runtime.send(activeSnapshot)
            defer {
                lock.lock()
                runtimeState.activeDecodes = max(0, runtimeState.activeDecodes - 1)
                let finishedSnapshot = runtimeState
                lock.unlock()
                runtime.send(finishedSnapshot)
            }
            let started = ProcessInfo.processInfo.systemUptime
            let text: String?
            do { text = try recognizer?(samples) } catch {
                probeLog("local-transcription-decode-failed", ["error": String(describing: error)]); text = nil
            }
            LocalModelMemoryTracker.shared.refine(.speech)
            completion(text, ProcessInfo.processInfo.systemUptime - started, text == nil ? .decodeFailure : nil)
        }
    }

    private var users = 0
    private var unloadCounter = 0
    /// Times the model was freed, for tests.
    var unloads: Int { lock.lock(); defer { lock.unlock() }; return unloadCounter }

    /// Loads the model ahead of the first utterance (the Neural Engine model takes
    /// seconds to load; the first launch also compiles it).
    func prepare(_ model: ListenRecognizerModel) {
        queue.async { [self] in _ = load(model, measurementToken: measurementTokenIfLoadNeeded(model)) }
    }

    /// Loads the model once, off every meeting's path, then frees it unless a meeting
    /// started transcribing meanwhile. The first Neural Engine load after launch takes
    /// about 12 s (beta 71 log); later loads in the same run take about 0.1 s, so the
    /// first meeting's transcript starts at once without the model holding memory idle.
    func warmUp(_ model: ListenRecognizerModel) {
        queue.async { [self] in
            let started = ProcessInfo.processInfo.systemUptime
            guard load(model, measurementToken: measurementTokenIfLoadNeeded(model)) else { return }
            lock.lock(); let idle = users == 0; lock.unlock()
            probeLog("local-transcription-warmed", ["seconds": ProcessInfo.processInfo.systemUptime - started, "kept": !idle])
            if idle { unloadIfIdle() }
        }
    }

    /// A meeting starts transcribing: the model loads ahead of its first utterance.
    func acquire(_ model: ListenRecognizerModel) {
        lock.lock(); users += 1; runtimeState.users = users; lock.unlock()
        publishRuntime()
        prepare(model)
    }
    /// A meeting stopped. When none transcribes, the model's memory is freed (the Core ML
    /// encoder otherwise stays resident for the app's life, beside the judge's models).
    func release() {
        lock.lock(); users = max(0, users - 1); runtimeState.users = users; let idle = users == 0; lock.unlock()
        publishRuntime()
        if idle { unload() }
    }
    var userCount: Int { lock.lock(); defer { lock.unlock() }; return users }

    /// Frees the model's memory. Speech already queued finishes first; a later utterance reloads.
    func unload() {
        queue.async { [self] in
            lock.lock(); let stillIdle = users == 0; lock.unlock()
            guard stillIdle else { return }
            unloadIfIdle()
        }
    }
    var isLoaded: Bool { queue.sync { loaded != nil } }
    var runtimeSnapshot: LocalSpeechRecognizerRuntimeSnapshot { lock.lock(); defer { lock.unlock() }; return runtimeState }

    private func measurementTokenIfLoadNeeded(_ model: ListenRecognizerModel) -> UUID? {
        lock.lock()
        let alreadyLoaded = runtimeState.phase == .loaded && runtimeState.model == model && recognizer != nil
        lock.unlock()
        if alreadyLoaded { return nil }
        return LocalModelMemoryTracker.shared.begin(.speech)
    }

    private func updateRuntime(_ mutate: (inout LocalSpeechRecognizerRuntimeSnapshot) -> Void) {
        lock.lock()
        mutate(&runtimeState)
        let snapshot = runtimeState
        lock.unlock()
        runtime.send(snapshot)
    }

    private func unloadIfIdle() {
        let hadModel = loaded != nil
        if hadModel { probeLog("local-transcription-unloaded", [:]) }
        lock.lock(); unloadCounter += 1; lock.unlock()
        updateRuntime { $0.phase = .unloading }
        recognizer = nil; loaded = nil
        LocalModelMemoryTracker.shared.clear(.speech)
        updateRuntime {
            $0.model = nil
            $0.phase = .unloaded
            $0.lastLoadSeconds = 0
            $0.error = nil
        }
    }

    private func publishRuntime() {
        lock.lock()
        let snapshot = runtimeState
        lock.unlock()
        runtime.send(snapshot)
    }

    /// On the queue. True when `model` is the loaded one.
    private func load(_ model: ListenRecognizerModel, measurementToken: UUID?) -> Bool {
        if loaded == model, recognizer != nil {
            updateRuntime {
                $0.model = model
                $0.phase = .loaded
                $0.lastLoadSeconds = 0
                $0.error = nil
            }
            return true
        }
        recognizer = nil; loaded = nil
        let started = ProcessInfo.processInfo.systemUptime
        do {
            switch model {
            case .sherpa(let configuration):
                let engine = try SherpaOfflineRecognizer(configuration)
                recognizer = { engine.transcribe($0) }
            case .coreMLGigaAM(let configuration):
                let engine = try CoreMLGigaAMRecognizer(configuration)
                recognizer = { try engine.transcribe($0) }
            }
            loaded = model
            let seconds = ProcessInfo.processInfo.systemUptime - started
            updateRuntime {
                $0.model = model
                $0.phase = .loaded
                $0.preparedModel = model
                $0.lastLoadSeconds = seconds
                $0.error = nil
            }
            if let measurementToken {
                LocalModelMemoryTracker.shared.complete(.speech, token: measurementToken, success: true)
            }
            probeLog("local-transcription-loaded", ["engine": model.engineName, "seconds": seconds])
            return true
        } catch {
            let message = String(describing: error)
            updateRuntime {
                $0.model = model
                $0.phase = .failed
                $0.lastLoadSeconds = 0
                $0.error = message
            }
            if let measurementToken {
                LocalModelMemoryTracker.shared.complete(.speech, token: measurementToken, success: false)
            }
            probeLog("local-transcription-load-failed", ["engine": model.engineName, "error": message])
            return false
        }
    }
}

extension ListenRecognizerModel {
    var engineName: String {
        switch self { case .sherpa: "sherpa-onnx"; case .coreMLGigaAM: "coreml" }
    }
}

/// Transcribes one meeting: one tap per remote participant track, resampled to
/// 16 kHz mono, cut into utterances by voice activity per speaker. Audio never
/// leaves memory and nothing is written to disk.
final class MeetingTranscriber: @unchecked Sendable {
    struct Line: Equatable, Sendable {
        let id: String
        let trackID: String
        let text: String
        let start: Date
        let end: Date
    }
    struct Summary: Equatable {
        var utterances = 0, lines = 0; var audioSeconds = 0.0, decodeSeconds = 0.0, droppedSeconds = 0.0
        var microphoneUtterances = 0; var microphoneSeconds = 0.0
        var droppedSecondsByReason: [LocalSpeechRecognizer.DropReason: Double] = [:]
    }
    /// The speaker key of your own microphone.
    static let localTrackID = "local-microphone"

    // All tracks and the microphone share a budget for PCM storage and worker jobs.
    static let maxPendingBuffers = 128
    static let maxPendingBytes = 4 * 1024 * 1024
    private let queue: DispatchQueue
    private let ingressLock = NSLock()
    private let audioCopies = DispatchGroup()
    private var acceptingAudio = true
    private var discardQueuedAudio = false
    private var localCapture = false
    private var microphoneGeneration = 0
    private var pendingBuffers = 0
    private var pendingBytes = 0
    private var droppedInputSeconds = 0.0
    private var pendingGap: DateInterval?
    private let recognizer: LocalSpeechRecognizer
    private let model: ListenRecognizerModel
    private let vadModel: URL
    private let onLine: @MainActor (Line) -> Void
    private let onDropped: (@MainActor (Date, Date, LocalSpeechRecognizer.DropReason) -> Void)?
    private let deliveries = DispatchGroup()
    // Main actor: attached sinks by source id.
    private var taps: [String: (source: MeetingAudioSource, tap: MeetingAudioSink)] = [:]
    @MainActor private var isStopping = false
    // Queue: per-speaker conversion and detection state.
    private var speakers: [String: Speaker] = [:]
    private var stopped = false
    private var finishDeliveries = false
    private var summary = Summary()
    /// Wall clock for line times; replaced in tests.
    var now: () -> Date = Date.init

    private final class Speaker {
        let detector: SherpaVoiceActivityDetector
        var converter: AVAudioConverter?
        var inputFormat: AVAudioFormat?
        var origin: Date?
        /// 16 kHz samples given to the detector so far (its segment indices count these).
        var fed: Int64 = 0
        init(detector: SherpaVoiceActivityDetector) { self.detector = detector }
    }

    init(model: ListenRecognizerModel, vadModel: URL, recognizer: LocalSpeechRecognizer = .shared,
         queue: DispatchQueue = DispatchQueue(label: "attention.listen.meeting", qos: .userInitiated),
         onDropped: (@MainActor (Date, Date, LocalSpeechRecognizer.DropReason) -> Void)? = nil,
         onLine: @escaping @MainActor (Line) -> Void) {
        self.model = model; self.vadModel = vadModel; self.recognizer = recognizer; self.onLine = onLine
        self.onDropped = onDropped; self.queue = queue
    }

    /// Attaches to new sources and detaches from sources that ended.
    @MainActor func update(_ sources: [MeetingAudioSource]) {
        guard !isStopping else { return }
        let current = Set(sources.map(\.id))
        for (id, entry) in taps where !current.contains(id) {
            entry.source.detach(entry.tap); taps[id] = nil
            queue.async { [self] in finish(id) }
        }
        for source in sources where taps[source.id] == nil {
            let tap = MeetingAudioSink(borrowingBuffersFor: source.id) { [weak self] id, buffer in self?.receive(id, buffer) }
            source.attach(tap); taps[source.id] = (source, tap)
        }
    }

    @MainActor func stop(flushing: Bool = false) {
        guard !isStopping else { return }
        isStopping = true
        ingressLock.withLock {
            acceptingAudio = false
            discardQueuedAudio = !flushing
        }
        for entry in taps.values { entry.source.detach(entry.tap) }
        taps = [:]
        // The last in-flight copy can still enqueue work. Keep the group open until
        // the worker flushes that audio and registers every final recognition.
        deliveries.enter()
        audioCopies.notify(queue: queue) { [self] in
            defer { deliveries.leave() }
            stopped = true
            finishDeliveries = flushing
            if flushing { for id in Array(speakers.keys) { finish(id) } }
            else { speakers = [:] }
        }
    }

    /// After stop, the group covers the worker flush and every final callback,
    /// including its main-actor journal write.
    func waitForDelivery() async -> Summary {
        await withCheckedContinuation { continuation in
            deliveries.notify(queue: queue) { [self] in
                continuation.resume(returning: summaryIncludingInputDrops)
            }
        }
    }

    @MainActor var trackCount: Int { taps.count }
    var currentSummary: Summary { queue.sync { summaryIncludingInputDrops } }

    private var summaryIncludingInputDrops: Summary {
        var result = summary
        let inputDrops = ingressLock.withLock { droppedInputSeconds }
        result.droppedSeconds += inputDrops
        result.droppedSecondsByReason[.audioBacklog, default: 0] += inputDrops
        return result
    }

    /// Your microphone is transcribed only while this is on (the meeting confirmed
    /// it unmuted and holds physical input). Turning it off ends the utterance, so
    /// nothing said after muting is transcribed; buffers meanwhile are dropped.
    func setLocalCapture(_ enabled: Bool) {
        ingressLock.withLock {
            guard acceptingAudio, localCapture != enabled else { return }
            localCapture = enabled
            microphoneGeneration &+= 1
            if !enabled { queue.async { [self] in finish(Self.localTrackID) } }
        }
    }
    /// Your microphone's borrowed buffer from the engine's input tap.
    func feedLocal(_ buffer: AVAudioPCMBuffer) {
        receive(Self.localTrackID, buffer)
    }

    /// Test entry: 16 kHz mono samples for one speaker, as a track would deliver them.
    func feedForTesting(trackID: String, samples: [Float], end: Bool = false) {
        queue.async { [self] in
            guard let speaker = speaker(trackID) else { return }
            if speaker.origin == nil { speaker.origin = Date() }
            handle(trackID, speaker, speaker.detector.accept(samples))
            if end { handle(trackID, speaker, speaker.detector.flush()) }
        }
    }
    func waitForTesting() { queue.sync {} }

    // MARK: Audio callbacks

    private func receive(_ trackID: String, _ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }
        let bytes = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            .reduce(0) { $0 + Int($1.mDataByteSize) }
        let receivedAt = now()
        let isMicrophone = trackID == Self.localTrackID
        let generation: Int? = ingressLock.withLock {
            guard acceptingAudio, !isMicrophone || localCapture else { return nil }
            guard pendingBuffers < Self.maxPendingBuffers, bytes <= Self.maxPendingBytes - pendingBytes else {
                recordInputDrop(seconds: Double(buffer.frameLength) / buffer.format.sampleRate, at: receivedAt)
                return nil
            }
            pendingBuffers += 1; pendingBytes += bytes
            audioCopies.enter()
            return microphoneGeneration
        }
        guard let generation else { return }
        defer { audioCopies.leave() }
        let copy = MeetingAudioSink.copy(buffer)
        ingressLock.withLock {
            // A microphone copy can race a mute and a subsequent unmute.
            guard let copy, !discardQueuedAudio, !isMicrophone || generation == microphoneGeneration else {
                pendingBuffers -= 1; pendingBytes -= bytes
                return
            }
            queue.async { [self] in
                defer { ingressLock.withLock { pendingBuffers -= 1; pendingBytes -= bytes } }
                guard !ingressLock.withLock({ discardQueuedAudio }) else { return }
                receiveOnQueue(trackID, copy, receivedAt: receivedAt)
            }
        }
    }

    /// Called under ingressLock. One pending journal delivery covers a burst
    /// of overflows across all tracks, even while the main actor is busy.
    private func recordInputDrop(seconds: Double, at end: Date) {
        droppedInputSeconds += seconds
        guard let onDropped else { return }
        let start = end.addingTimeInterval(-seconds)
        if let gap = pendingGap {
            pendingGap = DateInterval(start: min(gap.start, start), end: max(gap.end, end))
            return
        }
        pendingGap = DateInterval(start: start, end: end)
        deliveries.enter()
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) { [self] in
            let gap = ingressLock.withLock {
                defer { pendingGap = nil }
                return pendingGap
            }
            if let gap { onDropped(gap.start, gap.end, .audioBacklog) }
            deliveries.leave()
        }
    }

    // MARK: Queue

    private func receiveOnQueue(_ trackID: String, _ buffer: AVAudioPCMBuffer, receivedAt: Date) {
        guard !stopped, let speaker = speaker(trackID), let samples = convert(buffer, speaker) else { return }
        // Sample counts advance only while audio flows; a playout stall (device change,
        // audio service restart) would date every later line early by the gap. Each
        // buffer re-anchors the timeline to the wall clock at its arrival.
        speaker.fed += Int64(samples.count)
        speaker.origin = receivedAt.addingTimeInterval(-Double(speaker.fed) / 16_000)
        let seconds = Double(samples.count) / 16_000
        summary.audioSeconds += seconds
        if trackID == Self.localTrackID { summary.microphoneSeconds += seconds }
        handle(trackID, speaker, speaker.detector.accept(samples))
    }

    private func speaker(_ trackID: String) -> Speaker? {
        if let existing = speakers[trackID] { return existing }
        guard !stopped, let detector = try? SherpaVoiceActivityDetector(model: vadModel) else { return nil }
        let created = Speaker(detector: detector); speakers[trackID] = created
        return created
    }

    private func finish(_ trackID: String) {
        guard let speaker = speakers.removeValue(forKey: trackID) else { return }
        handle(trackID, speaker, speaker.detector.flush())
    }

    private func handle(_ trackID: String, _ speaker: Speaker, _ segments: [SherpaVoiceActivityDetector.Segment]) {
        guard let origin = speaker.origin else { return }
        for segment in segments where !segment.samples.isEmpty {
            let start = origin.addingTimeInterval(Double(segment.start) / 16_000)
            let end = start.addingTimeInterval(Double(segment.samples.count) / 16_000)
            summary.utterances += 1
            if trackID == Self.localTrackID { summary.microphoneUtterances += 1 }
            deliveries.enter()
            let deliveries = deliveries
            recognizer.transcribe(segment.samples, model: model) { [weak self] text, decode, reason in
                guard let self else { deliveries.leave(); return }
                self.queue.async {
                    guard !self.stopped || self.finishDeliveries else { deliveries.leave(); return }
                    guard let text else {
                        let reason = reason ?? .decodeFailure
                        self.summary.droppedSeconds += end.timeIntervalSince(start)
                        self.summary.droppedSecondsByReason[reason, default: 0] += end.timeIntervalSince(start)
                        let dropped = self.onDropped
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { dropped?(start, end, reason) }
                            deliveries.leave()
                        }
                        return
                    }
                    self.summary.decodeSeconds += decode
                    guard !text.isEmpty else { deliveries.leave(); return }
                    self.summary.lines += 1
                    let line = Line(id: "local-" + UUID().uuidString, trackID: trackID, text: text, start: start, end: end)
                    let deliver = self.onLine
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { deliver(line) }
                        deliveries.leave()
                    }
                }
            }
        }
    }

    private static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private func convert(_ buffer: AVAudioPCMBuffer, _ speaker: Speaker) -> [Float]? {
        if speaker.inputFormat != buffer.format {
            speaker.inputFormat = buffer.format
            speaker.converter = AVAudioConverter(from: buffer.format, to: Self.target)
        }
        guard let converter = speaker.converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, let data = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}
