import AVFoundation
import Foundation
import LiveKit
import LiveKitWebRTC
import SherpaOnnxKit

/// One remote audio stream a meeting can transcribe: a WebRTC track (Guest,
/// Telemost, TrueConf) or a LiveKit track (Rock). A mixed stream has no identity.
struct MeetingAudioSource {
    let id: String
    let participantIdentity: String?
    let attach: (MeetingAudioSink) -> Void
    let detach: (MeetingAudioSink) -> Void

    static func webRTC(_ track: LKRTCAudioTrack, identity: String?) -> Self {
        .init(id: track.trackId, participantIdentity: identity, attach: { track.add($0) }, detach: { track.remove($0) })
    }
    static func liveKit(_ track: RemoteAudioTrack, id: String, identity: String?) -> Self {
        .init(id: id, participantIdentity: identity, attach: { track.add(audioRenderer: $0.liveKit) },
              detach: { track.remove(audioRenderer: $0.liveKit) })
    }
}
extension GuestRemoteAudio {
    var source: MeetingAudioSource { .webRTC(track, identity: participantIdentity) }
}

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

/// One recognizer for every meeting. Utterances run one at a time on a utility
/// queue; when more than `maxPendingSeconds` of speech waits, new speech is
/// dropped and counted instead of falling ever further behind.
final class LocalSpeechRecognizer: @unchecked Sendable {
    static let shared = LocalSpeechRecognizer()
    static let maxPendingSeconds = 90.0
    private let queue = DispatchQueue(label: "attention.listen.recognizer", qos: .utility)
    private let lock = NSLock()
    private var pending = 0.0
    private var recognizer: SherpaOfflineRecognizer?
    private var loaded: SherpaRecognizerModel?

    /// Calls `completion` on the recognizer queue: text, or nil when dropped or failed.
    func transcribe(_ samples: [Float], model: SherpaRecognizerModel, completion: @escaping (String?, TimeInterval) -> Void) {
        let seconds = Double(samples.count) / 16_000
        let admitted: Bool = { lock.lock(); defer { lock.unlock() }
            guard pending + seconds <= Self.maxPendingSeconds else { return false }
            pending += seconds; return true }()
        guard admitted else { completion(nil, 0); return }
        queue.async { [self] in
            defer { lock.lock(); pending -= seconds; lock.unlock() }
            if loaded != model {
                recognizer = nil; loaded = nil
                do { recognizer = try SherpaOfflineRecognizer(model); loaded = model }
                catch { probeLog("local-transcription-load-failed", [:]); completion(nil, 0); return }
            }
            let started = ProcessInfo.processInfo.systemUptime
            let text = recognizer?.transcribe(samples)
            completion(text, ProcessInfo.processInfo.systemUptime - started)
        }
    }

    /// Frees the model's memory when no meeting transcribes.
    func unload() { queue.async { [self] in recognizer = nil; loaded = nil } }
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
    }
    /// The speaker key of your own microphone.
    static let localTrackID = "local-microphone"

    private let queue = DispatchQueue(label: "attention.listen.meeting", qos: .utility)
    private let recognizer: LocalSpeechRecognizer
    private let model: SherpaRecognizerModel
    private let vadModel: URL
    private let onLine: @MainActor (Line) -> Void
    // Main actor: attached sinks by source id.
    private var taps: [String: (source: MeetingAudioSource, tap: MeetingAudioSink)] = [:]
    // Queue: per-speaker conversion and detection state.
    private var speakers: [String: Speaker] = [:]
    private var stopped = false
    private var localCapture = false
    private(set) var summary = Summary()

    private final class Speaker {
        let detector: SherpaVoiceActivityDetector
        var converter: AVAudioConverter?
        var inputFormat: AVAudioFormat?
        var origin: Date?
        init(detector: SherpaVoiceActivityDetector) { self.detector = detector }
    }

    init(model: SherpaRecognizerModel, vadModel: URL, recognizer: LocalSpeechRecognizer = .shared,
         onLine: @escaping @MainActor (Line) -> Void) {
        self.model = model; self.vadModel = vadModel; self.recognizer = recognizer; self.onLine = onLine
    }

    /// Attaches to new sources and detaches from sources that ended.
    @MainActor func update(_ sources: [MeetingAudioSource]) {
        let current = Set(sources.map(\.id))
        for (id, entry) in taps where !current.contains(id) {
            entry.source.detach(entry.tap); taps[id] = nil
            queue.async { [self] in finish(id) }
        }
        for source in sources where taps[source.id] == nil {
            let tap = MeetingAudioSink(trackID: source.id) { [weak self] id, buffer in self?.receive(id, buffer) }
            source.attach(tap); taps[source.id] = (source, tap)
        }
    }

    @MainActor func stop() {
        for entry in taps.values { entry.source.detach(entry.tap) }
        taps = [:]
        queue.sync { stopped = true; speakers = [:] }
    }

    @MainActor var trackCount: Int { taps.count }
    var currentSummary: Summary { queue.sync { summary } }

    /// Your microphone is transcribed only while this is on (the meeting confirmed
    /// it unmuted and holds physical input). Turning it off ends the utterance, so
    /// nothing said after muting is transcribed; buffers meanwhile are dropped.
    func setLocalCapture(_ enabled: Bool) {
        queue.async { [self] in
            guard localCapture != enabled else { return }
            localCapture = enabled
            if !enabled { finish(Self.localTrackID) }
        }
    }
    /// Your microphone's buffer, from the engine's input tap. Copies at once.
    func feedLocal(_ buffer: AVAudioPCMBuffer) {
        guard let copy = MeetingAudioSink.copy(buffer) else { return }
        queue.async { [self] in
            guard localCapture else { return }
            receiveOnQueue(Self.localTrackID, copy)
        }
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

    // MARK: Queue

    private func receive(_ trackID: String, _ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in receiveOnQueue(trackID, buffer) }
    }
    private func receiveOnQueue(_ trackID: String, _ buffer: AVAudioPCMBuffer) {
        guard !stopped, let speaker = speaker(trackID), let samples = convert(buffer, speaker) else { return }
        if speaker.origin == nil { speaker.origin = Date().addingTimeInterval(-Double(buffer.frameLength) / buffer.format.sampleRate) }
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
            recognizer.transcribe(segment.samples, model: model) { [weak self] text, decode in
                self?.queue.async { [weak self] in
                    guard let self, !self.stopped else { return }
                    guard let text else { self.summary.droppedSeconds += end.timeIntervalSince(start); return }
                    self.summary.decodeSeconds += decode
                    guard !text.isEmpty else { return }
                    self.summary.lines += 1
                    let line = Line(id: "local-" + UUID().uuidString, trackID: trackID, text: text, start: start, end: end)
                    let deliver = self.onLine
                    DispatchQueue.main.async { MainActor.assumeIsolated { deliver(line) } }
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

/// LiveKit's renderer protocol has its own Objective-C selector; this forwards to the sink.
final class LiveKitAudioSink: NSObject, AudioRenderer, @unchecked Sendable {
    let sink: MeetingAudioSink
    init(_ sink: MeetingAudioSink) { self.sink = sink }
    func render(pcmBuffer: AVAudioPCMBuffer) { sink.render(pcmBuffer: pcmBuffer) }
}

/// A sink on one remote track. It copies each buffer and returns at once: the
/// audio thread never waits for conversion or recognition.
final class MeetingAudioSink: NSObject, LKRTCAudioRenderer, @unchecked Sendable {
    /// The same sink as a LiveKit renderer, one object for add and remove.
    lazy var liveKit = LiveKitAudioSink(self)
    let trackID: String
    let deliver: (String, AVAudioPCMBuffer) -> Void
    init(trackID: String, deliver: @escaping (String, AVAudioPCMBuffer) -> Void) { self.trackID = trackID; self.deliver = deliver }
    func render(pcmBuffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(pcmBuffer) else { return }
        deliver(trackID, copy)
    }
    static func copy(_ pcmBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard pcmBuffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: pcmBuffer.format, frameCapacity: pcmBuffer.frameLength) else { return nil }
        copy.frameLength = pcmBuffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let input = from.mData, let output = to.mData else { continue }
            memcpy(output, input, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}
