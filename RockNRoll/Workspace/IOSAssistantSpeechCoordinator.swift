import AVFoundation
import Combine
import ConferenceCore
import Foundation
import MeetingEngine
import Speech
import UIKit

/// Coordinates hands-free "Рок / Rock" wake-word capture, push-to-talk, and immediate
/// spoken dictation on iOS without creating competing audio sessions during active calls.
@MainActor final class IOSAssistantSpeechCoordinator: ObservableObject {
    enum Mode: Equatable {
        case idle
        case wakeListening
        case pushToTalk
        case dictating
    }

    enum PushToTalkStartError: Equatable {
        case alreadyActive
        case microphoneDenied
        case audioBusy
        case audioUnavailable
    }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var wakeArmed = false
    @Published private(set) var livePartialText = ""
    @Published private(set) var lastHeardCommand: String?
    @Published private(set) var isSpeakingResponse = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var blockedMessage: String?
    @Published private(set) var lastStartFailure: PushToTalkStartError?

    private let processor = IOSAssistantAudioProcessor()
    private var wakeDetector = AssistantWakeDetector(armWindowSeconds: 5.0)
    private var wakeArmExpiryTask: Task<Void, Never>?
    private var wakeEvalTask: Task<Void, Never>?
    private var stateGeneration = 0
    private var sharedObserverInstalled = false
    private var activatedForegroundSession = false
    private var foregroundEngine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    private var dictationOnPartial: ((String) -> Void)?
    private var dictationOnFinal: ((String) -> Void)?
    private var dictationSamples: [Float] = []
    private var pttSamples: [Float] = []

    var isForegroundActive: () -> Bool = { UIApplication.shared.applicationState == .active }
    var isInCall: () -> Bool = { false }
    var isAnyMicUnmuted: () -> Bool = { false }
    var isAudioConflictActive: () -> Bool = { false }
    var onWakeCommand: ((String) async -> Void)?

    // Test hooks
    var transcribeOverride: (([Float]) async -> String?)?
    var isTestingEnvironment: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        NSClassFromString("XCTestCase") != nil

    init() {
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
        foregroundEngine?.inputNode.removeTap(onBus: 0)
        foregroundEngine?.stop()
        if sharedObserverInstalled {
            sharedObserverInstalled = false
            Task { @MainActor in
                SharedAudioEngine.shared.setAssistantInputObserver(nil)
            }
        }
        if activatedForegroundSession {
            activatedForegroundSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func startObservingEnvironment() {
        guard !isTestingEnvironment, observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshState() }
            })
        }
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = typeRaw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor [weak self] in
                guard let self else { return }
                if type == .began {
                    self.stopForegroundTap()
                }
                self.refreshState()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshState() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopForegroundTap()
                self.refreshState()
            }
        })
        IOSVoiceStore.shared.$wakeWordEnabled
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshState() }
            }
            .store(in: &cancellables)
        IOSVoicePreviewPlayer.shared.$isPlaying
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
        let granted: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            granted = true
        case .undetermined:
            granted = await AVAudioApplication.requestRecordPermission()
        case .denied:
            granted = false
        @unknown default:
            granted = false
        }
        permissionDenied = !granted
        if granted && IOSListenModelStore.shared.installedGigaAMDirectoryIfReady() == nil
            && SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await Self.requestSpeechAuthorization()
        }
        refreshState()
        return granted
    }

    func refreshState() {
        guard !isTestingEnvironment else { return }
        if mode == .pushToTalk || mode == .dictating { return }

        let inCall = isInCall()
        let micUnmuted = isAnyMicUnmuted()
        let foreground = isForegroundActive()
        let micAuthorized = AVAudioApplication.shared.recordPermission == .granted
        let wantsWake = IOSVoiceStore.shared.wakeWordEnabled
            && foreground
            && !micUnmuted
            && !isSpeakingResponse
            && !IOSVoicePreviewPlayer.shared.isPlaying
            && !isAudioConflictActive()
            && micAuthorized

        if wantsWake {
            beginWakeListening(inCall: inCall)
        } else {
            stopWakeListening()
        }
    }

    private func beginWakeListening(inCall: Bool) {
        if mode != .wakeListening {
            stateGeneration += 1
            mode = .wakeListening
            processor.resetVAD()
        }
        let gen = stateGeneration
        if inCall {
            stopForegroundTap()
            SharedAudioEngine.shared.setAssistantWakeListening(true)
            installSharedObserverIfNeeded()
            Task { @MainActor [weak self] in
                guard let self, self.mode == .wakeListening, self.stateGeneration == gen else { return }
                _ = await SharedAudioEngine.shared.ensureMutedAssistantCapture()
            }
        } else {
            SharedAudioEngine.shared.setAssistantWakeListening(false)
            removeSharedObserver()
            startForegroundTapIfNeeded()
        }
    }

    private func stopWakeListening() {
        stateGeneration += 1
        if mode == .wakeListening {
            mode = .idle
        }
        wakeArmed = false
        wakeDetector.reset()
        wakeArmExpiryTask?.cancel()
        wakeArmExpiryTask = nil
        livePartialText = ""
        if mode == .idle {
            SharedAudioEngine.shared.setAssistantWakeListening(false)
            stopForegroundTap()
            removeSharedObserver()
        }
    }

    // MARK: - Dictation (e.g. Participate Goal)

    func startDictation(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        guard mode != .pushToTalk else { return }
        stateGeneration += 1
        let gen = stateGeneration
        wakeArmed = false
        wakeDetector.reset()
        wakeArmExpiryTask?.cancel()
        wakeArmExpiryTask = nil
        dictationOnPartial = onPartial
        dictationOnFinal = onFinal
        dictationSamples = processor.snapshotPreRoll(maxSamples: 8_000)
        livePartialText = ""
        blockedMessage = nil
        mode = .dictating
        processor.resetVAD()

        guard !isTestingEnvironment else { return }
        if isInCall() && isAnyMicUnmuted() {
            blockedMessage = L("Mute your call microphone to dictate context.")
            stopDictation(commit: false)
            return
        }
        Task { @MainActor [weak self] in
            guard let self, self.mode == .dictating, self.stateGeneration == gen else { return }
            let granted = await self.requestAudioPermissionsIfNeeded()
            guard granted, self.mode == .dictating, self.stateGeneration == gen else {
                self.stopDictation(commit: false)
                return
            }
            if self.isInCall() && self.isAnyMicUnmuted() {
                self.blockedMessage = L("Mute your call microphone to dictate context.")
                self.stopDictation(commit: false)
            } else if self.isInCall() && !self.isAnyMicUnmuted() {
                self.installSharedObserverIfNeeded()
                SharedAudioEngine.shared.setAssistantWakeListening(true)
                let ok = await SharedAudioEngine.shared.ensureMutedAssistantCapture()
                guard self.mode == .dictating, self.stateGeneration == gen else { return }
                if !ok { self.startForegroundTapIfNeeded() }
            } else if !self.isInCall() {
                self.startForegroundTapIfNeeded()
            }
        }
    }

    func stopDictation(commit: Bool = true) {
        guard mode == .dictating else { return }
        stateGeneration += 1
        let samples = dictationSamples
        let onFinal = dictationOnFinal
        dictationOnPartial = nil
        dictationOnFinal = nil
        dictationSamples.removeAll()
        livePartialText = ""
        mode = .idle
        SharedAudioEngine.shared.setAssistantWakeListening(false)
        stopForegroundTap()
        removeSharedObserver()
        refreshState()

        guard commit, samples.count >= 3_200, let onFinal else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let text = await self.transcribeSamples(samples)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                onFinal(text)
            }
        }
    }

    // MARK: - Push-to-Talk Capture

    func beginPushToTalkCapture() async -> Bool {
        guard mode != .pushToTalk else {
            lastStartFailure = .alreadyActive
            return false
        }
        lastStartFailure = nil
        if !isTestingEnvironment {
            let ok = await requestAudioPermissionsIfNeeded()
            guard ok else {
                lastStartFailure = .microphoneDenied
                return false
            }
            if isAudioConflictActive() {
                lastStartFailure = .audioBusy
                return false
            }
        }
        if mode == .dictating {
            stopDictation(commit: false)
        }
        stateGeneration += 1
        let gen = stateGeneration
        wakeArmed = false
        wakeDetector.reset()
        wakeArmExpiryTask?.cancel()
        wakeArmExpiryTask = nil
        pttSamples = processor.snapshotPreRoll(maxSamples: 8_000)
        mode = .pushToTalk
        processor.resetVAD()

        guard !isTestingEnvironment else { return true }
        if isInCall() && !isAnyMicUnmuted() {
            installSharedObserverIfNeeded()
            let sharedOK = await SharedAudioEngine.shared.ensureMutedAssistantCapture()
            guard mode == .pushToTalk, stateGeneration == gen else {
                lastStartFailure = .audioBusy
                return false
            }
            if sharedOK { return true }
        }
        let started = startForegroundTapIfNeeded()
        if !started {
            mode = .idle
            lastStartFailure = isAudioConflictActive() ? .audioBusy : .audioUnavailable
            refreshState()
        }
        return started
    }

    func finishPushToTalkCapture() -> [Float] {
        guard mode == .pushToTalk else { return [] }
        stateGeneration += 1
        let collected = pttSamples
        pttSamples.removeAll()
        stopForegroundTap()
        removeSharedObserver()
        mode = .idle
        refreshState()
        return collected
    }

    // MARK: - Test Injection

    func processSampleChunkForTesting(_ samples16k: [Float]) async {
        appendCapturedSamples(samples16k)
        let segments = processor.appendTestSamples(samples16k)
        for seg in segments {
            await handleCompletedSegment(seg)
        }
    }

    @discardableResult
    func processTranscriptForTesting(_ text: String, isFinal: Bool = true, now: Date = Date()) async -> AssistantWakeDetector.Outcome {
        let outcome = wakeDetector.consume(transcript: text, isFinal: isFinal, now: now)
        await applyWakeOutcome(outcome)
        return outcome
    }

    // MARK: - Private Pipeline

    private func appendCapturedSamples(_ samples: [Float]) {
        switch mode {
        case .dictating:
            if dictationSamples.count < 16_000 * 30 {
                dictationSamples.append(contentsOf: samples)
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
            let partialGen = stateGeneration
            let onFinal = dictationOnFinal
            let accumulated = dictationSamples.count >= 3_200 ? dictationSamples : samples
            guard let text = await transcribeSamples(accumulated)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, mode == .dictating, stateGeneration == partialGen else { return }
            livePartialText = text
            stopDictation(commit: false)
            onFinal?(text)
        case .wakeListening:
            guard !isSpeakingResponse else { return }
            let previous = wakeEvalTask
            let task = Task { @MainActor [weak self] in
                _ = await previous?.value
                guard let self, !Task.isCancelled, self.mode == .wakeListening, !self.isSpeakingResponse else { return }
                guard let text = await self.transcribeSamples(samples)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return }
                guard self.mode == .wakeListening, !self.isSpeakingResponse else { return }
                let outcome = self.wakeDetector.consume(transcript: text, isFinal: true, now: Date())
                await self.applyWakeOutcome(outcome)
            }
            wakeEvalTask = task
            await task.value
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
            await onWakeCommand?(command)
        }
    }

    func transcribeSamples(_ samples: [Float]) async -> String? {
        if let transcribeOverride {
            return await transcribeOverride(samples)
        }
        if let gigaamDir = IOSListenModelStore.shared.installedGigaAMDirectoryIfReady(),
           let recognizer = try? await CoreMLGigaAMRecognizer.shared(directory: gigaamDir) {
            let trimmed = try? await Task.detached(priority: .userInitiated) {
                try recognizer.transcribe(samples16k: samples)
            }.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty { return trimmed }
        }
        return await Self.transcribeWithAppleSpeech(samples)
    }

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
    private func startForegroundTapIfNeeded() -> Bool {
        guard foregroundEngine == nil, !isInCall(), !isAudioConflictActive() else {
            return foregroundEngine != nil
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers]
        )
        try? session.setActive(true)
        activatedForegroundSession = true

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            deactivateForegroundSessionIfNeeded()
            return false
        }

        let processor = self.processor
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            processor.enqueueShared(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
            foregroundEngine = engine
            return true
        } catch {
            input.removeTap(onBus: 0)
            deactivateForegroundSessionIfNeeded()
            return false
        }
    }

    private func stopForegroundTap() {
        guard let engine = foregroundEngine else {
            deactivateForegroundSessionIfNeeded()
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        foregroundEngine = nil
        deactivateForegroundSessionIfNeeded()
    }

    private func deactivateForegroundSessionIfNeeded() {
        guard activatedForegroundSession, !isInCall() else { return }
        activatedForegroundSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private static func transcribeWithAppleSpeech(_ samples: [Float]) async -> String? {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            let ok = await requestSpeechAuthorization()
            guard ok else { return nil }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return nil }
        let locale = IOSListenModelStore.shared.language.locale
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else { return nil }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: IOSPCM16kConverter.targetFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    dst.initialize(from: base, count: samples.count)
                }
            }
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.append(buffer)
        request.endAudio()

        return await withCheckedContinuation { continuation in
            var resumed = false
            var timeoutTask: Task<Void, Never>?
            let lock = NSLock()
            func finish(_ value: String?) {
                lock.lock()
                guard !resumed else {
                    lock.unlock()
                    return
                }
                resumed = true
                let timer = timeoutTask
                timeoutTask = nil
                lock.unlock()
                timer?.cancel()
                continuation.resume(returning: value)
            }
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    finish(result.bestTranscription.formattedString)
                } else if error != nil {
                    finish(nil)
                }
            }
            let timer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                task.cancel()
                finish(nil)
            }
            lock.lock()
            if resumed {
                timer.cancel()
            } else {
                timeoutTask = timer
            }
            lock.unlock()
        }
    }
}

private final class IOSAssistantAudioProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ios.assistant.speech.audio", qos: .userInitiated)
    private let lock = NSLock()
    private let converter = IOSPCM16kConverter()
    private var vad = IOSVoiceActivityDetector()
    private var preRoll: [Float] = []
    private let preRollLimit = 24_000

    var onCompletedSegment: (([Float]) -> Void)?
    var onSamplesChunk: (([Float]) -> Void)?

    func resetVAD() {
        lock.lock()
        vad = IOSVoiceActivityDetector()
        lock.unlock()
    }

    func snapshotPreRoll(maxSamples: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        if preRoll.count <= maxSamples { return preRoll }
        return Array(preRoll.suffix(maxSamples))
    }

    func enqueueShared(_ buffer: AVAudioPCMBuffer) {
        let converter = self.converter
        queue.async { [weak self] in
            guard let self else { return }
            let mono16k = converter.convert(buffer)
            guard !mono16k.isEmpty else { return }
            self.ingest(mono16k)
        }
    }

    func appendTestSamples(_ samples16k: [Float]) -> [[Float]] {
        lock.lock()
        defer { lock.unlock() }
        appendPreRollLocked(samples16k)
        return vad.append(samples16k).map(\.samples)
    }

    private func ingest(_ samples: [Float]) {
        onSamplesChunk?(samples)
        let segments: [IOSVoiceActivityDetector.CompletedSegment]
        lock.lock()
        appendPreRollLocked(samples)
        segments = vad.append(samples)
        lock.unlock()
        for segment in segments {
            onCompletedSegment?(segment.samples)
        }
    }

    private func appendPreRollLocked(_ samples: [Float]) {
        preRoll.append(contentsOf: samples)
        if preRoll.count > preRollLimit {
            preRoll.removeFirst(preRoll.count - preRollLimit)
        }
    }
}
