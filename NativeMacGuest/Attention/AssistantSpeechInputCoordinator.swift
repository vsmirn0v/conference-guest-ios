import Accelerate
import AppKit
import AVFoundation
import Combine
import ConferenceCore
import Foundation
import MeetingEngine
import Speech

/// Coordinates hands-free "Рок / Rock" wake-word detection, push-to-talk capture, and
/// immediate spoken dictation without spinning up competing audio engines against `SharedAudioEngine`.
@MainActor final class AssistantSpeechInputCoordinator: ObservableObject {
    enum Mode: Equatable {
        case idle
        case wakeListening
        case pushToTalk
        case dictating
    }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var wakeArmed = false
    @Published private(set) var livePartialText = ""
    @Published private(set) var lastHeardCommand: String?
    @Published private(set) var isSpeakingResponse = false
    @Published private(set) var permissionDenied = false

    private weak var attention: AttentionCoordinator?
    private let processor = AudioProcessor()
    private var wakeDetector = AssistantWakeDetector(armWindowSeconds: 5.0)
    private var wakeArmExpiryTask: Task<Void, Never>?
    private var wakeEvalTask: Task<Void, Never>?
    private var pttFallbackEngine: AVAudioEngine?
    private var sharedObserverInstalled = false
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    // Active dictation callbacks
    private var dictationOnPartial: ((String) -> Void)?
    private var dictationOnFinal: ((String) -> Void)?
    private var dictationBuffers: [Float] = []
    private var dictationStartedAt: Date?

    // Active push-to-talk capture state
    private var pttSamples: [Float] = []
    private var pttUsingSharedStream = false

    // Injectable test hooks
    var transcribeOverride: (([Float]) async -> String?)?
    var isTestingEnvironment: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        NSClassFromString("XCTestCase") != nil
    var onWakeTriggered: ((String) async -> Void)?

    init(attention: AttentionCoordinator) {
        self.attention = attention
        processor.onCompletedSegment = { [weak self] samples in
            Task { @MainActor [weak self] in
                await self?.handleCompletedSegment(samples)
            }
        }
        processor.onSamplesChunk = { [weak self] samples in
            Task { @MainActor [weak self] in
                self?.appendCapturedSamples(samples)
            }
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        wakeArmExpiryTask?.cancel()
        wakeEvalTask?.cancel()
        pttFallbackEngine?.inputNode.removeTap(onBus: 0)
        pttFallbackEngine?.stop()
    }

    func startObservingEnvironment() {
        guard !isTestingEnvironment, observers.isEmpty, let attention else { return }
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshState() }
            })
        }
        attention.store.$wakeWordEnabled
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshState() }
            }
            .store(in: &cancellables)
        refreshState()
    }

    func setSpeakingResponse(_ speaking: Bool) {
        guard isSpeakingResponse != speaking else { return }
        isSpeakingResponse = speaking
        if speaking {
            processor.resetVAD()
        }
        refreshState()
    }

    func requestAudioPermissionsIfNeeded() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        permissionDenied = !micOK
        if micOK && ListenModelStore.shared.recognizerModel() == nil && SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await Self.requestSpeechAuthorization()
        }
        refreshState()
        return micOK
    }

    func refreshState() {
        guard let attention, !isTestingEnvironment else { return }
        if mode == .pushToTalk || mode == .dictating { return }

        let meetings = attention.meetings().filter { !$0.isClosed }
        let anyMicUnmuted = meetings.contains { $0.snapshot.microphoneOn }
        let hasLiveMeeting = !meetings.isEmpty
        let appForeground = NSApp?.isActive == true
        let micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        let wantsWake = attention.store.wakeWordEnabled
            && (appForeground || hasLiveMeeting)
            && !anyMicUnmuted
            && !isSpeakingResponse
            && micAuthorized

        if wantsWake {
            beginWakeListening(hasLiveMeeting: hasLiveMeeting)
        } else {
            stopWakeListening()
        }
    }

    private func beginWakeListening(hasLiveMeeting: Bool) {
        if mode != .wakeListening {
            mode = .wakeListening
            processor.resetVAD()
        }
        installSharedObserverIfNeeded()
        Task { @MainActor [weak self] in
            guard let self, self.mode == .wakeListening else { return }
            SharedAudioEngine.shared.setAssistantWakeListening(true)
            let ok = await SharedAudioEngine.shared.ensureMutedAssistantCapture()
            if !ok && !hasLiveMeeting && self.mode == .wakeListening {
                try? await Task.sleep(for: .milliseconds(300))
                if self.mode == .wakeListening, !self.processor.hasRecentSharedAudio {
                    self.startFallbackTapIfNeeded()
                }
            } else if ok {
                self.stopFallbackTap()
            }
        }
    }

    private func stopWakeListening() {
        if mode == .wakeListening {
            mode = .idle
        }
        wakeArmed = false
        wakeDetector.reset()
        wakeArmExpiryTask?.cancel()
        wakeArmExpiryTask = nil
        livePartialText = ""
        if mode == .idle {
            if attention?.store.wakeWordEnabled != true {
                SharedAudioEngine.shared.setAssistantWakeListening(false)
            }
            stopFallbackTap()
            removeSharedObserver()
        }
    }

    // MARK: - Dictation (e.g., Participate Spoken Context)

    func startDictation(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        guard mode != .pushToTalk else { return }
        dictationOnPartial = onPartial
        dictationOnFinal = onFinal
        dictationBuffers = processor.snapshotPreRoll(maxSamples: 8_000)
        dictationStartedAt = Date()
        livePartialText = ""
        mode = .dictating
        processor.resetVAD()

        guard !isTestingEnvironment else { return }
        Task { @MainActor [weak self] in
            guard let self, self.mode == .dictating else { return }
            let granted = await self.requestAudioPermissionsIfNeeded()
            guard granted, self.mode == .dictating else {
                self.stopDictation(commit: false)
                return
            }
            self.installSharedObserverIfNeeded()
            SharedAudioEngine.shared.setAssistantWakeListening(true)
            let sharedOK = await SharedAudioEngine.shared.ensureMutedAssistantCapture()
            if !sharedOK {
                self.startFallbackTapIfNeeded()
            }
        }
    }

    func stopDictation(commit: Bool = true) {
        guard mode == .dictating else { return }
        let samples = dictationBuffers
        let onFinal = dictationOnFinal
        dictationOnPartial = nil
        dictationOnFinal = nil
        dictationBuffers.removeAll()
        dictationStartedAt = nil
        livePartialText = ""
        mode = .idle
        stopFallbackTap()
        refreshState()

        guard commit, samples.count >= 3_200, let onFinal else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let text = await self.transcribeSamples(samples)?.trimmed, !text.isEmpty {
                onFinal(text)
            }
        }
    }

    // MARK: - Push-to-Talk Capture Coordination

    func beginPushToTalkCapture(hasUnmutedMeeting: Bool) -> Bool {
        guard mode != .pushToTalk else { return false }
        if mode == .dictating {
            stopDictation(commit: false)
        }
        pttSamples = processor.snapshotPreRoll(maxSamples: 8_000)
        mode = .pushToTalk
        processor.resetVAD()

        if !hasUnmutedMeeting && processor.hasRecentSharedAudio {
            pttUsingSharedStream = true
            installSharedObserverIfNeeded()
            return true
        }
        pttUsingSharedStream = false
        return startFallbackTapIfNeeded()
    }

    func finishPushToTalkCapture() -> [Float] {
        guard mode == .pushToTalk else { return [] }
        let collected = pttSamples
        pttSamples.removeAll()
        pttUsingSharedStream = false
        stopFallbackTap()
        mode = .idle
        refreshState()
        return collected
    }

    // MARK: - Testing & Recognition Entry Point

    /// Feeds raw 16 kHz mono samples directly through VAD + wake detector for deterministic tests.
    func processSampleChunkForTesting(_ samples16k: [Float]) async {
        appendCapturedSamples(samples16k)
        let segments = processor.appendTestSamples(samples16k)
        for seg in segments {
            await handleCompletedSegment(seg)
        }
    }

    /// Feeds a finalized transcript directly through the wake detector for deterministic tests.
    @discardableResult
    func processTranscriptForTesting(_ text: String, isFinal: Bool = true, now: Date = Date()) async -> AssistantWakeDetector.Outcome {
        let outcome = wakeDetector.consume(transcript: text, isFinal: isFinal, now: now)
        await applyWakeOutcome(outcome)
        return outcome
    }

    private func appendCapturedSamples(_ samples: [Float]) {
        switch mode {
        case .dictating:
            if dictationBuffers.count < 16_000 * 30 {
                dictationBuffers.append(contentsOf: samples)
            }
        case .pushToTalk:
            if pttSamples.count < 16_000 * 30 {
                pttSamples.append(contentsOf: samples)
            }
        case .wakeListening, .idle:
            break
        }
    }

    private func handleCompletedSegment(_ samples: [Float]) async {
        guard samples.count >= 3_200 else { return }
        switch mode {
        case .dictating:
            guard !isSpeakingResponse else { return }
            let onFinal = dictationOnFinal
            stopDictation(commit: false)
            if let text = await transcribeSamples(samples)?.trimmed, !text.isEmpty {
                onFinal?(text)
            }
        case .wakeListening:
            guard !isSpeakingResponse else { return }
            guard let text = await transcribeSamples(samples)?.trimmed, !text.isEmpty else { return }
            let outcome = wakeDetector.consume(transcript: text, isFinal: true, now: Date())
            await applyWakeOutcome(outcome)
        case .pushToTalk, .idle:
            break
        }
    }

    private func applyWakeOutcome(_ outcome: AssistantWakeDetector.Outcome) async {
        switch outcome {
        case .ignored:
            wakeArmed = false
            livePartialText = ""
        case .armed(let until):
            wakeArmed = true
            livePartialText = L("Listening…")
            wakeArmExpiryTask?.cancel()
            let delay = max(0.1, until.timeIntervalSinceNow)
            wakeArmExpiryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                if !self.wakeDetector.isArmed(at: Date()) {
                    self.wakeArmed = false
                    self.livePartialText = ""
                }
            }
        case .triggered(let command):
            wakeArmed = false
            wakeArmExpiryTask?.cancel()
            wakeArmExpiryTask = nil
            livePartialText = command
            lastHeardCommand = command
            if let onWakeTriggered {
                await onWakeTriggered(command)
            } else if let attention {
                await attention.talk.run(command, source: .voiceWake)
            }
        }
    }

    func transcribeSamples(_ samples: [Float]) async -> String? {
        if let transcribeOverride {
            return await transcribeOverride(samples)
        }
        if let model = ListenModelStore.shared.recognizerModel() {
            return await withCheckedContinuation { continuation in
                LocalSpeechRecognizer.shared.transcribe(samples, model: model) { text, _, _ in
                    continuation.resume(returning: text)
                }
            }
        }
        return await Self.transcribeWithAppleSpeech(samples)
    }

    // MARK: - Audio Sources

    private func installSharedObserverIfNeeded() {
        guard !sharedObserverInstalled else { return }
        sharedObserverInstalled = true
        let processor = self.processor
        SharedAudioEngine.shared.setAssistantInputObserver { buffer in
            processor.enqueueShared(buffer)
        }
    }

    private func removeSharedObserver() {
        guard sharedObserverInstalled else { return }
        sharedObserverInstalled = false
        SharedAudioEngine.shared.setAssistantInputObserver(nil)
    }

    @discardableResult
    private func startFallbackTapIfNeeded() -> Bool {
        guard pttFallbackEngine == nil else { return true }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return false }
        let processor = self.processor
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            processor.enqueueLocal(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
            pttFallbackEngine = engine
            return true
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
    }

    private func stopFallbackTap() {
        guard let engine = pttFallbackEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        pttFallbackEngine = nil
    }

    // MARK: - Apple Speech Fallback

    private static func requestSpeechAuthorization() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { result in
                    continuation.resume(returning: result == .authorized)
                }
            }
        @unknown default: return false
        }
    }

    private static func transcribeWithAppleSpeech(_ samples16k: [Float]) async -> String? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return nil }
        let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
        let locale = preferred.lowercased().hasPrefix("ru") ? Locale(identifier: "ru-RU") : Locale(identifier: preferred)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { return nil }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples16k.count)),
              let dst = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples16k.count)
        samples16k.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { dst.update(from: base, count: samples16k.count) }
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.append(buffer)
        request.endAudio()

        return await withCheckedContinuation { continuation in
            var resumed = false
            let lock = NSLock()
            func finish(_ value: String?) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    finish(result.bestTranscription.formattedString)
                } else if error != nil {
                    finish(nil)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                task.cancel()
                finish(nil)
            }
        }
    }
}

// MARK: - Off-Main-Actor Audio Conversion, Ring Buffer & Energy VAD

private final class AudioProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "assistant.speech.audio", qos: .userInitiated)
    private let lock = NSLock()
    private static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?
    private var sourceFormatKey: String?
    private var preRoll: [Float] = []
    private let maxPreRollSamples = 12_000 // 0.75s
    private var lastSharedUptime: TimeInterval = 0

    // Energy VAD state (20ms frames at 16 kHz)
    private let frameSamples = 320
    private let hangoverFrames = 28 // 560ms
    private let minSpeechFrames = 10 // 200ms
    private let maxSegmentFrames = 1_200 // 24s
    private let leadInFrames = 15 // 300ms
    private let minFloorRMS: Float = 0.006

    private var residual: [Float] = []
    private var vadPreRoll: [[Float]] = []
    private var activeFrames: [[Float]] = []
    private var active = false
    private var silenceFrames = 0
    private var noiseFloorRMS: Float = 0.003

    var onCompletedSegment: (([Float]) -> Void)?
    var onSamplesChunk: (([Float]) -> Void)?

    var hasRecentSharedAudio: Bool {
        lock.withLock {
            ProcessInfo.processInfo.systemUptime - lastSharedUptime < 1.0
        }
    }

    func snapshotPreRoll(maxSamples: Int) -> [Float] {
        lock.withLock {
            if preRoll.count <= maxSamples { return preRoll }
            return Array(preRoll.suffix(maxSamples))
        }
    }

    func resetVAD() {
        queue.async { [self] in
            residual.removeAll()
            vadPreRoll.removeAll()
            activeFrames.removeAll()
            active = false
            silenceFrames = 0
        }
    }

    func enqueueShared(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { lastSharedUptime = ProcessInfo.processInfo.systemUptime }
        enqueue(buffer)
    }

    func enqueueLocal(_ buffer: AVAudioPCMBuffer) {
        enqueue(buffer)
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard let copy = copyPCMBuffer(buffer) else { return }
        queue.async { [self] in
            let samples = convert(copy)
            guard !samples.isEmpty else { return }
            recordPreRoll(samples)
            onSamplesChunk?(samples)
            let segments = appendToVAD(samples)
            for segment in segments {
                onCompletedSegment?(segment)
            }
        }
    }

    func appendTestSamples(_ samples: [Float]) -> [[Float]] {
        queue.sync {
            recordPreRoll(samples)
            return appendToVAD(samples)
        }
    }

    private func recordPreRoll(_ samples: [Float]) {
        lock.withLock {
            preRoll.append(contentsOf: samples)
            if preRoll.count > maxPreRollSamples {
                preRoll.removeFirst(preRoll.count - maxPreRollSamples)
            }
        }
    }

    private func appendToVAD(_ samples: [Float]) -> [[Float]] {
        residual.append(contentsOf: samples)
        var completed: [[Float]] = []
        var offset = 0
        while offset + frameSamples <= residual.count {
            let frame = Array(residual[offset..<(offset + frameSamples)])
            offset += frameSamples
            if let finished = processVADFrame(frame) {
                completed.append(finished)
            }
        }
        if offset > 0 { residual.removeFirst(offset) }
        return completed
    }

    private func processVADFrame(_ frame: [Float]) -> [Float]? {
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))
        let startThreshold = max(minFloorRMS, noiseFloorRMS * 2.8)
        let continueThreshold = max(minFloorRMS * 0.6, noiseFloorRMS * 1.7)

        if !active {
            vadPreRoll.append(frame)
            if vadPreRoll.count > leadInFrames {
                vadPreRoll.removeFirst(vadPreRoll.count - leadInFrames)
            }
            if rms >= startThreshold {
                active = true
                silenceFrames = 0
                activeFrames = vadPreRoll
                vadPreRoll.removeAll()
            } else {
                noiseFloorRMS = 0.96 * noiseFloorRMS + 0.04 * min(rms, minFloorRMS * 3)
            }
            return nil
        }

        activeFrames.append(frame)
        if rms >= continueThreshold {
            silenceFrames = 0
        } else {
            silenceFrames += 1
        }

        if activeFrames.count >= maxSegmentFrames || silenceFrames >= hangoverFrames {
            defer {
                active = false
                silenceFrames = 0
                activeFrames.removeAll()
            }
            let trimSilence = min(silenceFrames, max(0, activeFrames.count - minSpeechFrames))
            let voicedCount = activeFrames.count - trimSilence
            guard voicedCount >= minSpeechFrames else { return nil }
            let keepCount = activeFrames.count - max(0, trimSilence - 4)
            return activeFrames.prefix(keepCount).flatMap { $0 }
        }
        return nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let format = buffer.format
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, format.sampleRate > 0 else { return [] }
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
            converter?.downmix = true
        }
        guard let converter else { return [] }
        let ratio = 16_000.0 / format.sampleRate
        let capacity = AVAudioFrameCount(max(64, Int(ceil(Double(frameCount) * ratio)) + 32))
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true; outStatus.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0, let dst = output.floatChannelData?[0] else {
            return []
        }
        return Array(UnsafeBufferPointer(start: dst, count: Int(output.frameLength)))
    }

    private func copyPCMBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard source.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let srcList = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let dstList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (src, dst) in zip(srcList, dstList) {
            guard let sData = src.mData, let dData = dst.mData else { continue }
            memcpy(dData, sData, Int(min(src.mDataByteSize, dst.mDataByteSize)))
        }
        return copy
    }
}
