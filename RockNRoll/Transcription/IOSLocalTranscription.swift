import Accelerate
import AVFoundation
import Combine
import ConferenceCore
import Foundation
import MeetingEngine
import Speech

/// Ordered speaker timeline for attributing local transcription bursts by timestamp.
struct IOSSpeakingTimeline {
    struct Turn: Equatable {
        let speaker: String?
        let timestamp: Date
    }

    private(set) var turns: [Turn] = []
    private let maxTurns = 128

    mutating func record(speaker: String?, at date: Date = Date()) {
        let clean = speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = clean?.isEmpty == false ? clean : nil
        if turns.last?.speaker == normalized { return }
        turns.append(Turn(speaker: normalized, timestamp: date))
        if turns.count > maxTurns {
            turns.removeFirst(turns.count - maxTurns)
        }
    }

    func speaker(near date: Date) -> String? {
        turns.last(where: { $0.timestamp <= date.addingTimeInterval(0.35) })?.speaker ?? turns.last?.speaker
    }

    mutating func reset() {
        turns.removeAll()
    }
}

/// Converts arbitrary PCM buffers to `16 kHz` mono `Float` samples without locking audio threads.
final class IOSPCM16kConverter {
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private var sourceFormatKey: String?
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let format = buffer.format
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [] }

        if format.sampleRate == 16_000,
           format.channelCount == 1,
           format.commonFormat == .pcmFormatFloat32,
           let channelData = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }

        let key = "\(format.sampleRate)-\(format.channelCount)-\(format.commonFormat.rawValue)-\(format.isInterleaved)"
        if key != sourceFormatKey || converter == nil {
            sourceFormatKey = key
            converter = AVAudioConverter(from: format, to: Self.targetFormat)
        }
        guard let converter else { return [] }

        let ratio = Self.targetFormat.sampleRate / max(1, format.sampleRate)
        let capacity = AVAudioFrameCount(max(64, Int(ceil(Double(frameCount) * ratio)) + 32))
        guard let converted = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            return []
        }

        var fed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil,
              converted.frameLength > 0,
              let channel = converted.floatChannelData?[0] else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }
}

enum IOSTranscriptionState: Equatable {
    case off
    case starting
    case active(IOSListenModel)
    case paused(String)
    case unavailable(String)

    var isRunning: Bool {
        switch self {
        case .starting, .active: return true
        default: return false
        }
    }
}

/// Manages real-time speech transcription for one iOS meeting session across remote participants and local microphone input.
@MainActor
final class IOSMeetingTranscriber: ObservableObject {
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var state: IOSTranscriptionState = .off

    var onSegmentsChanged: (([TranscriptSegment]) -> Void)?

    private let modelStore: IOSListenModelStore
    private let localDisplayName: () -> String
    private let participantNameLookup: (String) -> String?
    private let setOutputDemand: (Bool) async -> Bool

    private var remoteSources: [MeetingAudioSource] = []
    private var taps: [String: (source: MeetingAudioSource, sink: MeetingAudioSink)] = [:]
    private let workerQueue = DispatchQueue(label: "dev.vsmirn0v.conferenceguest.ios-transcription")
    private var pipelines: [String: SpeakerPipeline] = [:]
    private var timeline = IOSSpeakingTimeline()
    private var currentBackend: IOSListenModel?
    private var gigaamRecognizer: CoreMLGigaAMRecognizer?
    private var running = false
    private var segmentOrder = 0
    private var activeUtteranceByStream: [String: TranscriptSegment] = [:]
    private var finalizedSegments: [TranscriptSegment] = []
    private var restartAppleTask: Task<Void, Never>?

    init(
        modelStore: IOSListenModelStore = .shared,
        localDisplayName: @escaping () -> String,
        participantNameLookup: @escaping (String) -> String?,
        setOutputDemand: @escaping (Bool) async -> Bool
    ) {
        self.modelStore = modelStore
        self.localDisplayName = localDisplayName
        self.participantNameLookup = participantNameLookup
        self.setOutputDemand = setOutputDemand
    }

    func updateRemoteSources(_ sources: [MeetingAudioSource]) {
        remoteSources = sources
        guard running else { return }
        syncTaps()
    }

    nonisolated func enqueueLocalAudio(_ buffer: AVAudioPCMBuffer) {
        guard let copy = MeetingAudioSink.copy(buffer) else { return }
        Task { @MainActor [weak self] in
            self?.receiveCopiedLocalAudio(copy)
        }
    }

    func receiveLocalAudio(_ buffer: AVAudioPCMBuffer) {
        guard running, let copy = MeetingAudioSink.copy(buffer) else { return }
        receiveCopiedLocalAudio(copy)
    }

    private func receiveCopiedLocalAudio(_ copy: AVAudioPCMBuffer) {
        guard running else { return }
        let speaker = localDisplayName().trimmingCharacters(in: .whitespacesAndNewlines)
        let label = speaker.isEmpty ? L("You") : speaker
        timeline.record(speaker: label)
        feedAudio(streamID: "local", speakerName: label, buffer: copy)
    }

    func start() async -> Bool {
        guard !running else { return true }
        running = true
        state = .starting

        let backend = modelStore.effectiveBackend()
        if backend == .gigaamV3CoreML, let dir = modelStore.installedGigaAMDirectoryIfReady() {
            do {
                let recognizer = try CoreMLGigaAMRecognizer(directory: dir)
                guard running else { return false }
                self.gigaamRecognizer = recognizer
                self.currentBackend = .gigaamV3CoreML
                state = .active(.gigaamV3CoreML)
            } catch {
                // Fall back to Apple Speech if CoreML model fails to compile/open
                self.gigaamRecognizer = nil
                guard await startAppleSpeech() else { return false }
            }
        } else {
            guard await startAppleSpeech() else { return false }
        }

        _ = await setOutputDemand(true)
        syncTaps()
        return running
    }

    func stop() async {
        guard running || state != .off else { return }
        running = false
        restartAppleTask?.cancel()
        restartAppleTask = nil
        detachAllTaps()
        _ = await setOutputDemand(false)
        let activePipelines = pipelines.values
        pipelines.removeAll()
        workerQueue.async {
            for pipeline in activePipelines {
                pipeline.stop()
            }
        }
        activeUtteranceByStream.removeAll()
        currentBackend = nil
        gigaamRecognizer = nil
        state = .off
    }

    func reset() async {
        await stop()
        finalizedSegments.removeAll()
        activeUtteranceByStream.removeAll()
        timeline.reset()
        segments = []
        onSegmentsChanged?([])
    }

    private func startAppleSpeech() async -> Bool {
        let authorized = await Self.requestSpeechAuthorization()
        guard running else { return false }
        guard authorized else {
            running = false
            state = .unavailable(L("Allow Speech Recognition in Settings to transcribe speech on this iPhone."))
            return false
        }
        guard let recognizer = SFSpeechRecognizer(locale: modelStore.language.locale), recognizer.isAvailable else {
            running = false
            state = .unavailable(L("Apple Speech Recognition is unavailable for %@ right now.", modelStore.language.title))
            return false
        }
        self.currentBackend = .appleSpeech
        state = .active(.appleSpeech)
        return true
    }

    private static func requestSpeechAuthorization() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        switch current {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }

    private func syncTaps() {
        let validIDs = Set(remoteSources.map(\.id))
        for (id, entry) in taps where !validIDs.contains(id) {
            entry.source.detach(entry.sink)
            taps.removeValue(forKey: id)
            let closingPipeline = pipelines.removeValue(forKey: id)
            workerQueue.async {
                closingPipeline?.finishAndFlush()
            }
        }
        for source in remoteSources where taps[source.id] == nil {
            let speakerName = resolvedSpeakerName(for: source)
            let sink = MeetingAudioSink(trackID: source.id) { [weak self] id, pcm in
                Task { @MainActor [weak self] in
                    guard let self, self.running else { return }
                    let currentName = self.resolvedSpeakerName(for: source)
                    self.feedAudio(streamID: id, speakerName: currentName, buffer: pcm)
                }
            }
            source.attach(sink)
            taps[source.id] = (source, sink)
            _ = speakerName
        }
    }

    private func detachAllTaps() {
        for (_, entry) in taps {
            entry.source.detach(entry.sink)
        }
        taps.removeAll()
    }

    private func resolvedSpeakerName(for source: MeetingAudioSource) -> String? {
        if let identity = source.participantIdentity {
            if let mapped = participantNameLookup(identity), !mapped.isEmpty {
                return mapped
            }
            return identity
        }
        return nil
    }

    private func feedAudio(streamID: String, speakerName: String?, buffer: AVAudioPCMBuffer) {
        let pipeline: SpeakerPipeline
        if let existing = pipelines[streamID] {
            pipeline = existing
            pipeline.updateSpeaker(speakerName)
        } else {
            pipeline = SpeakerPipeline(
                streamID: streamID,
                speakerName: speakerName,
                backend: currentBackend ?? .appleSpeech,
                language: modelStore.language,
                gigaam: gigaamRecognizer,
                workerQueue: workerQueue
            ) { [weak self] stream, speaker, text, isFinal, spokenAt in
                Task { @MainActor [weak self] in
                    self?.handleRecognition(
                        streamID: stream,
                        speaker: speaker,
                        text: text,
                        isFinal: isFinal,
                        spokenAt: spokenAt
                    )
                }
            }
            pipelines[streamID] = pipeline
        }
        if let speakerName {
            timeline.record(speaker: speakerName)
        }
        workerQueue.async {
            pipeline.append(buffer)
        }
    }

    private func handleRecognition(
        streamID: String,
        speaker: String?,
        text: String,
        isFinal: Bool,
        spokenAt: Date
    ) {
        guard running else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            if isFinal {
                activeUtteranceByStream.removeValue(forKey: streamID)
                publishSegments()
            }
            return
        }

        let attributedSpeaker = speaker ?? timeline.speaker(near: spokenAt) ?? L("Participant")
        let stableID: String
        let effectiveTime: Date
        if let active = activeUtteranceByStream[streamID] {
            stableID = active.id
            effectiveTime = active.spokenAt ?? spokenAt
        } else {
            segmentOrder += 1
            stableID = "local-\(streamID)-\(segmentOrder)"
            effectiveTime = spokenAt
        }

        let segment = TranscriptSegment(
            id: stableID,
            speaker: attributedSpeaker,
            text: clean,
            spokenAt: effectiveTime
        )

        if isFinal {
            activeUtteranceByStream.removeValue(forKey: streamID)
            if let existingIndex = finalizedSegments.firstIndex(where: { $0.id == stableID }) {
                finalizedSegments[existingIndex] = segment
            } else {
                finalizedSegments.append(segment)
                if finalizedSegments.count > 400 {
                    finalizedSegments.removeFirst(finalizedSegments.count - 400)
                }
            }
        } else {
            activeUtteranceByStream[streamID] = segment
        }
        publishSegments()
    }

    private func publishSegments() {
        var combined = finalizedSegments
        for partial in activeUtteranceByStream.values.sorted(by: { ($0.spokenAt ?? .distantFuture) < ($1.spokenAt ?? .distantFuture) }) {
            combined.append(partial)
        }
        segments = combined
        onSegmentsChanged?(combined)
    }
}

private final class SpeakerPipeline {
    private let streamID: String
    private var speakerName: String?
    private let backend: IOSListenModel
    private let language: IOSTranscriptionLanguage
    private let gigaam: CoreMLGigaAMRecognizer?
    private let workerQueue: DispatchQueue
    private let onText: (String, String?, String, Bool, Date) -> Void

    private let converter = IOSPCM16kConverter()
    private let vad = IOSVoiceActivityDetector()
    private var stopped = false

    // Apple Speech state (accessed on workerQueue)
    private var speechRecognizer: SFSpeechRecognizer?
    private var appleRequest: SFSpeechAudioBufferRecognitionRequest?
    private var appleTask: SFSpeechRecognitionTask?
    private var appleTaskStartedAt: Date?
    private var lastAppleText = ""

    // CoreML partial throttling
    private var lastPartialAt = Date.distantPast
    private var speechStartedAt: Date?

    init(
        streamID: String,
        speakerName: String?,
        backend: IOSListenModel,
        language: IOSTranscriptionLanguage,
        gigaam: CoreMLGigaAMRecognizer?,
        workerQueue: DispatchQueue,
        onText: @escaping (String, String?, String, Bool, Date) -> Void
    ) {
        self.streamID = streamID
        self.speakerName = speakerName
        self.backend = backend
        self.language = language
        self.gigaam = gigaam
        self.workerQueue = workerQueue
        self.onText = onText
        if backend == .appleSpeech {
            let recognizer = SFSpeechRecognizer(locale: language.locale)
            self.speechRecognizer = recognizer
        }
    }

    func updateSpeaker(_ name: String?) {
        workerQueue.async {
            if let name, !name.isEmpty {
                self.speakerName = name
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard !stopped else { return }
        let samples = converter.convert(buffer)
        guard !samples.isEmpty else { return }

        if backend == .appleSpeech {
            processAppleSpeech(samples16k: samples, originalBuffer: buffer)
        } else {
            processCoreMLGigaAM(samples16k: samples)
        }
    }

    func finishAndFlush() {
        guard !stopped else { return }
        stopped = true
        if backend == .appleSpeech {
            finalizeAppleTask()
        } else if let recognizer = gigaam {
            for seg in vad.flush() {
                if let text = try? recognizer.transcribe(samples16k: seg.samples), !text.isEmpty {
                    onText(streamID, speakerName, text, true, speechStartedAt ?? Date())
                }
            }
            speechStartedAt = nil
        }
    }

    func stop() {
        stopped = true
        appleTask?.cancel()
        appleTask = nil
        appleRequest?.endAudio()
        appleRequest = nil
        vad.resetState()
    }

    private func processAppleSpeech(samples16k: [Float], originalBuffer: AVAudioPCMBuffer) {
        let completed = vad.append(samples16k)
        if vad.isSpeechActive {
            if appleRequest == nil {
                startAppleRequest()
            }
            if let appleRequest, let floatBuffer = make16kBuffer(from: samples16k) {
                appleRequest.append(floatBuffer)
            } else if let appleRequest {
                appleRequest.append(originalBuffer)
            }
            if let started = appleTaskStartedAt, Date().timeIntervalSince(started) > 40 {
                rotateAppleRequest()
            }
        } else if !completed.isEmpty {
            // Utterance boundary detected by VAD -> rotate cleanly so final segment is committed.
            if let tailBuffer = make16kBuffer(from: samples16k) {
                appleRequest?.append(tailBuffer)
            }
            finalizeAppleTask()
        }
    }

    private func startAppleRequest() {
        guard let speechRecognizer, speechRecognizer.isAvailable else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if speechRecognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        if #available(iOS 16.0, *) {
            req.addsPunctuation = true
        }
        let startedAt = Date()
        appleRequest = req
        appleTaskStartedAt = startedAt
        lastAppleText = ""

        appleTask = speechRecognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.workerQueue.async {
                guard !self.stopped else { return }
                if let result {
                    let transcript = result.bestTranscription.formattedString
                    self.lastAppleText = transcript
                    self.onText(self.streamID, self.speakerName, transcript, result.isFinal, startedAt)
                    if result.isFinal {
                        self.appleTask = nil
                        self.appleRequest = nil
                        self.appleTaskStartedAt = nil
                        self.lastAppleText = ""
                    }
                } else if error != nil {
                    self.appleTask = nil
                    self.appleRequest = nil
                    self.appleTaskStartedAt = nil
                }
            }
        }
    }

    private func rotateAppleRequest() {
        finalizeAppleTask()
        startAppleRequest()
    }

    private func finalizeAppleTask() {
        appleRequest?.endAudio()
        if appleTask != nil && !lastAppleText.isEmpty {
            onText(streamID, speakerName, lastAppleText, true, appleTaskStartedAt ?? Date())
            lastAppleText = ""
        }
        appleRequest = nil
        appleTask?.finish()
        appleTask = nil
        appleTaskStartedAt = nil
    }

    private func processCoreMLGigaAM(samples16k: [Float]) {
        guard let gigaam else { return }
        let wasActive = vad.isSpeechActive
        let completed = vad.append(samples16k)
        if !wasActive && vad.isSpeechActive {
            speechStartedAt = Date()
        }
        for segment in completed {
            let spokenAt = speechStartedAt ?? Date()
            speechStartedAt = vad.isSpeechActive ? Date() : nil
            if let text = try? gigaam.transcribe(samples16k: segment.samples), !text.isEmpty {
                onText(streamID, speakerName, text, true, spokenAt)
            }
        }
        if vad.isSpeechActive,
           Date().timeIntervalSince(lastPartialAt) >= 2.2,
           let partialSamples = vad.snapshotActiveSamples() {
            lastPartialAt = Date()
            let spokenAt = speechStartedAt ?? Date()
            if let text = try? gigaam.transcribe(samples16k: partialSamples), !text.isEmpty {
                onText(streamID, speakerName, text, false, spokenAt)
            }
        }
    }

    private func make16kBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: IOSPCM16kConverter.targetFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let dst = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { src in
            dst.initialize(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
