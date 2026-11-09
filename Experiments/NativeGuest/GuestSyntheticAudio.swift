import AudioToolbox
import Foundation
import LiveKitWebRTC

struct GuestAudioSnapshot {
    var samples: Int = 0
    var energy: Double = 0
    var callbacks: Int = 0
    var nonSilentCallbacks: Int = 0
    var firstCallbackUptime: TimeInterval?
    var lastCallbackUptime: TimeInterval?
    var firstNonSilentUptime: TimeInterval?
    var lastNonSilentUptime: TimeInterval?
    var rms: Double { samples > 0 ? sqrt(energy / Double(samples)) : 0 }

    /// Called under the owning meter's lock. Non-silent means finite energy > 0;
    /// this measures PCM arrival, not speech or audibility. No samples are retained.
    mutating func record(samples count: Int, energy value: Double, at now: TimeInterval) {
        samples += count; energy += value
        guard count > 0, now.isFinite else { return }
        callbacks += 1
        firstCallbackUptime = min(firstCallbackUptime ?? now, now)
        lastCallbackUptime = max(lastCallbackUptime ?? now, now)
        guard value.isFinite, value > 0 else { return }
        nonSilentCallbacks += 1
        firstNonSilentUptime = min(firstNonSilentUptime ?? now, now)
        lastNonSilentUptime = max(lastNonSilentUptime ?? now, now)
    }

    func since(_ before: Self) -> Self {
        .init(samples: max(0, samples - before.samples), energy: max(0, energy - before.energy),
            callbacks: max(0, callbacks - before.callbacks), nonSilentCallbacks: max(0, nonSilentCallbacks - before.nonSilentCallbacks),
            firstCallbackUptime: before.callbacks == 0 ? firstCallbackUptime : nil,
            lastCallbackUptime: callbacks > before.callbacks ? lastCallbackUptime : nil,
            firstNonSilentUptime: before.nonSilentCallbacks == 0 ? firstNonSilentUptime : nil,
            lastNonSilentUptime: nonSilentCallbacks > before.nonSilentCallbacks ? lastNonSilentUptime : nil)
    }
}

/// Isolated test ADM: no microphone or speaker access. All mutable state is locked.
final class GuestSyntheticAudio: NSObject, LKRTCAudioDevice, @unchecked Sendable {
    let deviceInputSampleRate = 48_000.0, deviceOutputSampleRate = 48_000.0
    let inputIOBufferDuration = 0.01, outputIOBufferDuration = 0.01
    let inputNumberOfChannels = 1, outputNumberOfChannels = 1
    let inputLatency = 0.0, outputLatency = 0.0
    private let lock = NSLock()
    private var initialized = false, playoutReady = false, recordingReady = false
    private var playing = false, recording = false, stopped = true
    private var worker: Thread?
    private var finished: DispatchSemaphore?
    private var measured = GuestAudioSnapshot()
    #if DEBUG
    private var testSpeech: [Int16]?
    private var testSpeechPlaying = false, testSpeechOffset = 0
    func configureSpeechForTesting(_ samples: [Int16]) -> Bool {
        guard (480...5_760_000).contains(samples.count) else { return false }
        locked { testSpeech = samples; testSpeechOffset = 0; testSpeechPlaying = false }
        return true
    }
    func setSpeechPlayingForTesting(_ enabled: Bool) -> Bool {
        locked {
            guard testSpeech != nil else { return false }
            testSpeechPlaying = enabled
            if enabled { testSpeechOffset = 0 }
            return true
        }
    }
    var speechStateForTesting: [String: Any] {
        locked { ["configured": testSpeech != nil, "playing": testSpeechPlaying, "nextSampleOffset": testSpeechOffset,
                  "sampleRate": 48_000, "clock": "synthetic ADM input sample position"] }
    }
    #endif
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var isInitialized: Bool { locked { initialized } }
    var isPlayoutInitialized: Bool { locked { playoutReady } }
    var isRecordingInitialized: Bool { locked { recordingReady } }
    var isPlaying: Bool { locked { playing } }
    var isRecording: Bool { locked { recording } }
    var snapshot: GuestAudioSnapshot { locked { measured } }

    func initialize(with delegate: LKRTCAudioDeviceDelegate) -> Bool {
        locked {
            guard worker == nil else { return initialized }
            initialized = true; stopped = false
            let done = DispatchSemaphore(value: 0); finished = done
            let thread = Thread { [weak self, delegate] in
                self?.process(delegate); done.signal()
            }
            thread.name = "Native guest synthetic PCM"
            worker = thread; thread.start(); return true
        }
    }
    func terminateDevice() -> Bool {
        let done = locked { stopped = true; playing = false; recording = false; return finished }
        // A broken native callback cannot hang the main test indefinitely.
        guard done == nil || done!.wait(timeout: .now() + 2) == .success else { return false }
        locked { worker = nil; finished = nil; initialized = false; playoutReady = false; recordingReady = false }
        return true
    }
    func initializePlayout() -> Bool { locked { playoutReady = true }; return true }
    func initializeRecording() -> Bool { locked { recordingReady = true }; return true }
    func startPlayout() -> Bool { locked { playing = true }; return true }
    func stopPlayout() -> Bool { locked { playing = false }; return true }
    func startRecording() -> Bool { locked { recording = true }; return true }
    func stopRecording() -> Bool { locked { recording = false }; return true }

    private func process(_ delegate: LKRTCAudioDeviceDelegate) {
        var index = 0
        var input = [Int16](repeating: 0, count: 480), output = input
        var deadline = ProcessInfo.processInfo.systemUptime
        while true {
            let state = locked { (stopped, playing, recording) }
            if state.0 { return }
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp(); timestamp.mSampleTime = Double(index); timestamp.mFlags = .sampleTimeValid
            if state.2 {
                #if DEBUG
                let speechConfigured = locked { () -> Bool in
                    guard let speech = testSpeech else { return false }
                    for i in input.indices {
                        input[i] = testSpeechPlaying ? speech[testSpeechOffset] : 0
                        if testSpeechPlaying { testSpeechOffset = (testSpeechOffset + 1) % speech.count }
                    }
                    return true
                }
                if !speechConfigured {
                    for i in input.indices { input[i] = Int16(3_000 * sin(Double(index + i) * 2 * .pi * 440 / 48_000)) }
                }
                #else
                for i in input.indices { input[i] = Int16(3_000 * sin(Double(index + i) * 2 * .pi * 440 / 48_000)) }
                #endif
                input.withUnsafeMutableBytes { bytes in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 960, mData: bytes.baseAddress))
                    _ = delegate.deliverRecordedData(&flags, &timestamp, 0, 480, &list, nil, nil)
                }
            }
            if state.1 {
                output.withUnsafeMutableBytes { bytes in
                    bytes.initializeMemory(as: UInt8.self, repeating: 0)
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 960, mData: bytes.baseAddress))
                    _ = delegate.getPlayoutData(&flags, &timestamp, 0, 480, &list)
                }
                let energy = output.reduce(0.0) { let sample = Double($1) / 32768; return $0 + sample * sample }
                let now = ProcessInfo.processInfo.systemUptime
                locked { measured.record(samples: output.count, energy: energy, at: now) }
            }
            index += 480; deadline += 0.01
            let now = ProcessInfo.processInfo.systemUptime
            if deadline < now - 0.1 { deadline = now }
            Thread.sleep(forTimeInterval: max(0.001, deadline - now))
        }
    }
}

struct GuestMediaSnapshot {
    let render: [String: Any]
    let audio: GuestAudioSnapshot
    let connected: Bool
    let failed: Bool
    func changes(since before: Self) -> Int {
        (render["pixelChanges"] as? Int ?? 0) - (before.render["pixelChanges"] as? Int ?? 0)
    }

    func advancingFrames(since before: Self) -> Int {
        (render["advancingFrames"] as? Int ?? 0) - (before.render["advancingFrames"] as? Int ?? 0)
    }

    enum VideoExpectation {
        case movingPattern
        // A static camera scene need not change pixels. Both capture and receive
        // timestamps must advance within this window; this proves delivery only.
        case nativeCamera(capturedFrames: Int?)
    }

    func hasFreshVideo(since before: Self, expectation: VideoExpectation) -> Bool {
        guard connected, !failed, advancingFrames(since: before) > 10 else { return false }
        switch expectation {
        case .movingPattern: return changes(since: before) > 5
        case .nativeCamera(let frames): return (frames ?? 0) > 10
        }
    }
}

/// A readiness window is valid only for the same pair of native engine objects.
/// Replacing either endpoint starts a new baseline for BOTH directions.
struct GuestVideoReadiness {
    private var localID: ObjectIdentifier
    private var remoteID: ObjectIdentifier
    private(set) var localBaseline: GuestMediaSnapshot
    private(set) var remoteBaseline: GuestMediaSnapshot

    init(localID: ObjectIdentifier, remoteID: ObjectIdentifier,
         local: GuestMediaSnapshot, remote: GuestMediaSnapshot) {
        self.localID = localID; self.remoteID = remoteID
        localBaseline = local; remoteBaseline = remote
    }

    mutating func observe(localID: ObjectIdentifier, remoteID: ObjectIdentifier,
                         local: GuestMediaSnapshot, remote: GuestMediaSnapshot) -> Bool {
        if self.localID != localID || self.remoteID != remoteID {
            self.localID = localID; self.remoteID = remoteID
            localBaseline = local; remoteBaseline = remote
            return false
        }
        return local.hasFreshVideo(since: localBaseline, expectation: .movingPattern) &&
            remote.hasFreshVideo(since: remoteBaseline, expectation: .movingPattern)
    }
}
